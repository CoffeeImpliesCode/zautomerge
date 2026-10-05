const std = @import("std");
const manifest = @import("build.zig.zon");

const TextIndexing = enum {
    unicode_code_point,
    utf8_code_unit,
    utf16_code_unit,
    grapheme_cluster,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const text_indexing = b.option(
        TextIndexing,
        "text-indexing",
        "Select native text indexing units; defaults to unicode_code_point.",
    ) orelse .unicode_code_point;

    // Published native module and static C artifact share the same core.
    const mod = b.addModule("zautomerge", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `-Dslow-path` is this port's spelling of upstream's
    // `slow_path_assertions` Cargo feature. Upstream declares it twice —
    // `rust/automerge/Cargo.toml:17` forwards it to
    // `rust/hexane/Cargo.toml:17` — and **reads it in the automerge crate
    // only**: the fast/slow seek cross-check (`op_set2/op_set.rs:645-649`),
    // the sequence tree's own check on insert and remove
    // (`sequence_tree.rs:52`, `:114`, `:126`), the successor-order check
    // (`op_set2/change/batch.rs:924-936`) and the indexed-versus-walked
    // marks comparison (`automerge.rs:1587-1591`, `:1939-1943`).
    // **Nothing under `rust/hexane/src` reads it** — the feature is declared
    // and dead there, and `hexane/src/codec.rs` does not read it either, so a
    // plan that says it does is wrong about where the gate lives.
    //
    // A Zig comptime gate has to be a `const`, and the only thing that can set
    // one from a command line is a generated module, so the option arrives as
    // `build_options.check_slow_paths`. **Both files that read it read that
    // module, not a copy of its value**, because a `const
    // check_slow_paths: bool = false` sitting next to it would be a constant
    // with a new name and no new behaviour:
    //
    // - `src/opset/op_set.zig` — the fast/slow `seekOpsByIndex` cross-check,
    //   which is upstream's own gate for the feature.
    // - `src/hexane/btree.zig` — `SlabBTree.assertSound`, the structural
    //   checker P2's gate names.
    //
    // Off by default because both checks are linear in the size of the thing
    // they check, and every `seekOpsByIndex` call site pays for the first one.
    const slow_path = b.option(
        bool,
        "slow-path",
        "Run the fast-path cross-checks and the SlabBTree structural checker " ++
            "that upstream gates behind its slow_path_assertions feature. " ++
            "Linear in the size of the thing checked, so off by default.",
    ) orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "check_slow_paths", slow_path);
    build_options.addOption([]const u8, "package_name", @tagName(manifest.name));
    build_options.addOption([]const u8, "package_version", manifest.version);
    build_options.addOption([]const u8, "text_indexing", @tagName(text_indexing));
    mod.addImport("build_options", build_options.createModule());

    // `zig build slow-path` is the gate P2's text names, and **it builds its
    // own module rather than asking for `-Dslow-path`**, so the step cannot
    // be run in a state where the checker it exists to run is compiled out.
    // A step that only runs the check when the caller remembers a flag is the
    // same dead option as one nothing passes; this one is the command.
    //
    // It runs the library test binary in full, with no filter: a filtered
    // build reports `0 passed` and exits 0 when the filter stops matching,
    // which is a gate that passes by having stopped testing anything.
    //
    // Its root is `src/root.zig` rather than `src/hexane/btree.zig` because
    // the btree cannot be a module root on its own: its own
    // `codec_golden.zig` imports `../error.zig`, which is outside the
    // module path a root in `src/hexane/` would give it.
    //
    // `-Dslow-path` is the wider spelling: it puts the same option in the
    // library module every other step builds, so `zig build test
    // -Dslow-path` runs everything above with the `seekOpsByIndex`
    // cross-check live too.
    // The published module stays pure Zig. Source tests use C-backed
    // allocation, so libc is linked only into these test roots.
    const slow_options = b.addOptions();
    slow_options.addOption(bool, "check_slow_paths", true);
    slow_options.addOption([]const u8, "package_name", @tagName(manifest.name));
    slow_options.addOption([]const u8, "package_version", manifest.version);
    slow_options.addOption([]const u8, "text_indexing", @tagName(text_indexing));
    const slow_lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "build_options", .module = slow_options.createModule() }},
        }),
    });
    const slow_path_step = b.step(
        "slow-path",
        "Run the unit tests with -Dslow-path forced on",
    );
    timedTest(b, slow_lib_tests, "library-slow-path", null, &.{slow_path_step});

    const library_test_root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "build_options", .module = build_options.createModule() }},
    });
    const lib_tests = b.addTest(.{ .root_module = library_test_root });

    const test_step = b.step("test", "Run unit tests");
    timedTest(b, lib_tests, "library", null, &.{test_step});

    // The fixture corpus lives in test/fixtures and the test reads it through
    // a path relative to the build root, which is the process working
    // directory for a build-run step.
    const fixtures_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixtures_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    timedTest(b, fixtures_tests, "fixtures", b.path("."), &.{test_step});

    // The crate-root address-book example, run the way a consumer runs it: a
    // module of its own that imports `zautomerge` by name, so nothing below
    // can reach into a private. It needs no working directory, because it
    // reads no file.
    //
    // **`link_libc` is for the one test at the foot of that file**, the
    // C/Zig map-range cross-check, which reads one document through
    // `AMmapRange` and through `read.mapRange` in the same process — a
    // comparison `test/c/abi_coverage.c` cannot host, because that binary
    // links the C ABI and has no Zig-side reader in it. `src/c/**` is
    // `extern "C"` over libc and its allocator is a `@compileError` without
    // it (`src/c/result.zig:1074-1077`), so the comparison cannot be written
    // without it. Nothing else in that file reaches for a C symbol, and
    // `zig build ctest` remains the gate for the ABI itself.
    const example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/example_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, example_tests, "example", null, &.{test_step});

    // `rust/automerge/tests/test.rs` — the document's own 140-case suite —
    // ported case for case into `test/upstream_doc_test.zig`, and run the way
    // a consumer runs it: a module of its own that imports `zautomerge` by
    // name, for the same reason `example_test` does above. **No working
    // directory is set**, because the file reads no fixture: the four upstream
    // cases that read `tests/fixtures/` are already covered by
    // `test/fixtures_test.zig` and by the fixture table `src/doc.zig` spells
    // out at `src/doc.zig:4889-4892`, and repeating them here would be a second
    // copy of one assertion rather than a port.
    const upstream_doc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_doc_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, upstream_doc_tests, "upstream-doc", null, &.{test_step});

    // Public document consumers embed their Rust-generated vectors.
    const clock_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_clock_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    const clock_test_step = b.step("clock-test", "Check document frontiers against the Rust clock corpus");
    timedTest(b, clock_tests, "upstream-clock", null, &.{ test_step, clock_test_step });

    const metadata_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_metadata_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    const metadata_test_step = b.step("metadata-test", "Check owned change metadata against Rust");
    timedTest(b, metadata_tests, "upstream-metadata", null, &.{ test_step, metadata_test_step });

    // `rust/automerge/tests/test_mark_patches.rs` — a file holding **exactly
    // one** `#[test]` — ported case for case into `test/mark_patches_test.zig`.
    // Its own module, `zautomerge` imported by name, for the same reason as
    // every other test step above: nothing in it may reach into a private, so
    // the file can only use the surface a consumer gets.
    //
    // **No working directory is set**, because the file reads no fixture. It
    // builds its document in memory and nothing below reads a path.
    //
    // **Two test blocks, and one of them is an addition.** The gate counts
    // upstream cases, so the ported case is named for upstream's `#[test]`
    // (`mark_patches_at_end_of_text`) and asserts the same five things; the
    // second block is the hydrate clause, which upstream does not have and
    // which is what pins that the mark's **name and value** survive a replay
    // and that a mirror outlives a mutation of the document it was read from.
    const mark_patches_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/mark_patches_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, mark_patches_tests, "mark-patches", null, &.{test_step});

    // `rust/hexane/src/tests.rs`, ported case for case where the port's public
    // API reaches the case, into `src/hexane/hexane_test.zig`. **Its own step
    // and not one of the 198 in-file test blocks**, for the same reason
    // `upstream_doc_more.zig` is its own file: upstream's `tests.rs` is 193 KB
    // and one agent's worth of work, and it would otherwise be a continuation
    // of a 6,000-line `column.zig` that two writers cannot share.
    //
    // The root is `src/hexane/hexane_test.zig` rather than `src/root.zig`
    // because the file is **about** `src/hexane/`, and `mod` is imported by
    // name for the same reason every other step imports it by name: the file
    // may only use the surface a consumer gets, so nothing below can reach
    // into a private to make a case easier.
    //
    // **No working directory is set**, because the file reads no fixture and
    // no golden vector. **The `-Dslow-path` gate is the other step**: the
    // invariant checker runs there, over a mutation sweep far too long for the
    // default suite, and nothing below is gated on it.
    const hexane_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hexane/hexane_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, hexane_tests, "hexane", null, &.{test_step});

    // The C ABI's Zig tests need libc and a root under src/ so imports stay
    // inside the module. The published `mod` stays pure Zig; its normal and
    // forced-slow in-file test roots link libc for C-backed allocator tests.
    // Filter by module name to avoid a second run of the transitive library
    // tests. Anonymous import-collection tests remain in the filtered binary.
    const c_abi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_abi_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "build_options", .module = build_options.createModule() }},
        }),
        .filters = &.{ "c.doc.", "c.sync." },
    });
    const c_abi_step = b.step("c-abi-test", "Run the C ABI's own Zig test sections");
    timedTest(b, c_abi_tests, "c-abi", b.path("."), &.{ test_step, c_abi_step });

    // `test/upstream_doc_more.zig` is the **remainder** of the same upstream
    // file: the 23 of `tests/test.rs`'s 140 `#[test]` cases that
    // `test/upstream_doc_test.zig` does not have a `test "` for. It is a
    // second file rather than the tail of the first so that two agents editing
    // one 4,900-line file cannot collide, and so that the count in each file
    // is its own. Run the same way — its own module, `zautomerge` imported by
    // name — for the same reason.
    //
    // **A working directory *is* set here**, unlike every other test step
    // above, because this file does read `test/fixtures/`: four of the
    // remainder (`fuzz_crashers`, `overlong_leb`, `load`, `obj_id_64bits`)
    // are upstream's fixture-driven cases, and the corpus is the only copy of
    // those bytes. The note above about `fixtures_test.zig` covering them is
    // wrong about `fixtures_test.zig`: it checks that the manifest and the
    // directory agree and that every file starts with the magic, and it never
    // calls `Document.load` on any of them, so the `expect` column was
    // unenforced until this step existed.
    const upstream_doc_more_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_doc_more.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, upstream_doc_more_tests, "upstream-doc-more", b.path("."), &.{test_step});

    // `test/upstream_text_more.zig` is the **remainder** of the upstream text
    // suites: the three `#[test]` cases in `rust/automerge/tests/text.rs` and
    // `tests/text_encoding.rs` that `src/read.zig` does not carry. It is a
    // second file rather than the tail of `src/read.zig` for two reasons, both
    // stated at the top of the file itself: `src/read.zig`'s 1,400-line
    // fixture section is private to a library module and so is unreachable
    // from a consumer test, and the two files would collide in a writer's
    // hands. Run the same way as every other test step above — its own module,
    // `zautomerge` imported by name.
    //
    // **No working directory is set**, because the file reads no fixture: its
    // one fixture is the pair of hex change chunks the oracle prints, and
    // they are a `const` in the file. The same reasoning as
    // `upstream_doc_more_tests` above: a step that sets a working directory it
    // does not need is a step that breaks the moment a test moves.
    const upstream_text_more_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_text_more.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, upstream_text_more_tests, "upstream-text-more", null, &.{test_step});
    // `test/upstream_batch_insert.zig` is `$AUTOMERGE_REF/rust/automerge/tests/
    // batch_insert.rs` — all 46 of its `#[test]` cases, ported case for case
    // and in upstream's order, and nothing else. It is the **whole** of a file
    // that had no ported case at all, which an audit of the upstream test
    // names named the weakest gate in the port.
    //
    // Run the same way as every other test step above — its own module,
    // `zautomerge` imported by name, **no working directory** because the file
    // reads no fixture. It is a second file rather than the tail of
    // `upstream_doc_test.zig` because that file is large and owned, and
    // because "the batch suite" is honest about being its own thing.
    //
    // **It is the one step whose subject is row order and contiguity**:
    // `BatchInsertion::next_pos` (`inner.rs`:1460-1462) computes each
    // operation's row from the ones before it and `Batch::finish`
    // (`inner.rs`:1514-1519) writes the whole batch with one splice, while a
    // map reader does not sort (`iter/map_range.zig`:1486-1490) — so a wrong
    // order reads back as a different map and a contents-only assertion passes
    // on it. `expectKeys` in that file is the assertion that cannot.
    const upstream_batch_insert_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_batch_insert.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, upstream_batch_insert_tests, "upstream-batch-insert", null, &.{test_step});

    // `test/upstream_save_load_orphans.zig` is `$AUTOMERGE_REF/rust/automerge/
    // tests/test_save_load_orphans.rs` — all 3 of its `#[test]` cases, ported
    // case for case and in upstream's order, and nothing else. It was the
    // second of the upstream files an audit found with no ported case at all.
    //
    // Run the same way as every other step above — its own module,
    // `zautomerge` imported by name, **no working directory** because the
    // file reads no fixture.
    //
    // **This step found a port defect and is now green.** Case 3,
    // `load_incremental_change_without_deps_throws`, asserts
    // `error.MissingDeps`: upstream refuses a change-chunk stream that leaves
    // anything queued when its first chunk was not a document chunk
    // (`automerge.rs`:976-982), and `Document.loadIntoWith` had no such
    // branch. The case was **left failing** rather than relaxed — relaxing it
    // would have deleted the only record that the rule was missing — and the
    // rule is now implemented (`src/doc.zig`, `loadIntoWith`), after which all
    // three cases pass. The diff block at the foot of the file carries the
    // citation, the oracle's record of the reference's own answer, and the
    // `FAIL`-count check that tells a real failure from a run that never
    // started.
    const upstream_save_load_orphans_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_save_load_orphans.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, upstream_save_load_orphans_tests, "upstream-save-load-orphans", null, &.{test_step});

    // `test/upstream_block_tests.zig` is `$AUTOMERGE_REF/rust/automerge/tests/
    // block_tests.rs` — **all nineteen of its `#[test]` cases**, ported case
    // for case and in upstream's order, and nothing else. It is a second file
    // rather than the tail of another one because that upstream file had **no**
    // ported case at all, which an audit named as the weakest gate in the port.
    //
    // Run the same way as every other test step above — its own module,
    // `zautomerge` imported by name, **no working directory** because the file
    // reads no fixture.
    //
    // **It is the one step whose subject is row order inside map-valued block
    // markers.** These cases write `type` / `parents` / `attrs` maps into the
    // objects a text object's block markers name, and a map reader does **not**
    // sort (`iter/map_range.zig`:1486-1490), so rows written in the wrong order
    // read back as a different map and a contents-only assertion passes on it.
    // `expectSameThroughApplyChanges` in that file is the assertion that cannot
    // be fooled: it replays the document through `Document.applyChanges` and
    // compares rows first with `Document.debugCmp` ("row for row and byte for
    // byte", `op_set.rs:69-71`), which raises `error.Invariant` on a divergence
    // before any content comparison can paper over it. **And `expectKeys`, in
    // the same file, asserts a block's keys in *iteration* order**, because
    // `hydrate.Map.eql` looks each register up by key and so is content-only —
    // that assertion was falsified on its own, with the contents held equal and
    // only the order reversed, and it failed in four cases where the content
    // comparison had passed. Every one of the nineteen carries both.
    const upstream_block_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_block_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, upstream_block_tests, "upstream-block", null, &.{test_step});

    // `test/upstream_convert_string.zig` is
    // `$AUTOMERGE_REF/rust/automerge/tests/convert_string_to_text.rs` — **all
    // three** of its `#[test]` cases, ported case for case and in upstream's
    // order. It is a **whole** upstream file that had no ported case at all.
    //
    // Run the same way as every other step above — its own module,
    // `zautomerge` imported by name, **no working directory**, because the file
    // reads no fixture and embeds no bytes.
    //
    // **It is the only step whose subject is text indexing under all four
    // encodings.** Every case loops over `TextEncoding`'s four variants
    // (`types.zig:558-563`), because an index means something different in each
    // and the conversion's one encoding-dependent step is `splice_text`
    // (`automerge.rs:2018`). Upstream's own file does **not** loop —
    // `LoadOptions::new()` fixes `platform_default()` (`automerge.rs:181`) — so
    // the sweep is this file's, and a `"hello"` payload cannot tell the four
    // apart (measured: five units and five operations under all four). What the
    // assertions do separate is the **element sequence**, one element at a time
    // at each element's first index, from a length: under three of the four
    // encodings a unit count and an operation count are different numbers for
    // any non-ASCII character.
    //
    // **And the file carries the recorded gap.** The port has no `LoadOptions`
    // and no `StringMigration`, so the load-with-options door is not exercised
    // here; the migration is driven explicitly instead, on the same manual
    // transaction upstream's `convert_scalar_strings_to_text` opens
    // (`automerge.rs:1973-2024`). The gap is written down at the top of that
    // file and again in its diff block.
    const upstream_convert_string_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_convert_string.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, upstream_convert_string_tests, "upstream-convert-string", null, &.{test_step});

    // `test/upstream_rich_text_fuzz.zig` is `$AUTOMERGE_REF/rust/automerge/
    // tests/rich_text_fuzz_crash.rs` — all nine `#[test]` cases, ported
    // case for case and in upstream's order. Rescue loads without mark-order
    // validation and returns an independently owned hydrated tree. Run the
    // same way as every other step above — its own module,
    // `zautomerge` imported by name, **no `setCwd`** because the file embeds
    // its one fixture with `@embedFile` rather than reading it at runtime.
    //
    // **This is the other half of the totality gate**, and it is not a second
    // copy of `src/storage/totality_test.zig`. That suite mutates bytes of
    // well-formed documents — truncations, bit flips, hostile DEFLATE — so what
    // it proves is that the framing and column decoders are total. Seven of
    // these nine cases build their document **through the writer**, from the
    // operation sequence a fuzzer produced and a human minimised, and the
    // defect was semantic (a mark end before its begin, a `length` counting a
    // conflicted element twice, a zero-width mark leaking into another object,
    // a panic validating op order on sync). A byte mutation cannot reach any of
    // them, because the input is a **valid** document whose *operation order* is
    // what is under test.
    //
    // **A non-zero exit here is a crash finding, not a bug report.** `AGENTS.md`
    // states the rule absolutely — *"never a panic, never an unbounded loop,
    // never an unchecked allocation size"* — and `Document.load` is a library
    // entry point a caller hands bytes from somewhere else, so every case names
    // the refusal it expects (`error.InvalidMarkOrder`,
    // `error.InvalidValueType`) rather than merely observing that something
    // failed.
    const upstream_rich_text_fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/upstream_rich_text_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, upstream_rich_text_fuzz_tests, "upstream-rich-text-fuzz", null, &.{test_step});

    // `test/save_interop_test.zig` is the **permanent** half of the save
    // interoperability gate: it reads `test/golden/save-interop.jsonl` — the
    // records `tools/oracle`'s `save-interop` subcommand recorded from the
    // reference automerge — rebuilds each of the six shared scripts itself,
    // and checks its heads, its change hashes and raw change bodies, and its
    // hydrated document against the reference's answer for the same script,
    // plus the **normalized default-save body** the reference would have
    // written for that script.
    //
    // **A working directory *is* set**, unlike most of the steps above:
    // this file reads `test/golden/save-interop.jsonl`, and that file is the
    // only copy of the reference's answers to those six scripts.
    //
    // **No Cargo and no reference checkout**, which is the whole difference
    // between this step and `conformance` below. `save-interop.jsonl` is a
    // committed file like any other fixture, so `zig build` and
    // `zig build test` need neither the oracle nor the sibling `automerge`
    // checkout. What makes it a gate rather than a pinned answer is what it
    // is pinned **to**: `zig build conformance` regenerates that file from
    // the reference and fails the moment it differs, so a vector cannot drift
    // away from the reference behind this test's back.
    const save_interop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/save_interop_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, save_interop_tests, "save-interop", b.path("."), &.{test_step});

    // Every api-parity vector is replayed by native public consumers, while
    // ordinary conformance independently checks the reference's determinism.
    const api_parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/api_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    timedTest(b, api_parity_tests, "api-parity", null, &.{test_step});

    // `zig build ctest` builds the upstream C conformance suite — the cmocka
    // suite from `rust/automerge-c/test/`, copied verbatim into
    // `test/c/suite/` — against the C ABI, and runs it. It also depends on
    // `abi_check` declared below, and the two are different jobs that fail
    // differently.
    //
    // **The link is a name check.** The suite is C, compiled against
    // `include/automerge.h` and linked against the library's symbols, so a
    // declaration the library does not export is a link error here — and that
    // is the whole of what a link can see. A renamed struct field, a
    // reordered `AMitems`, a widened enum or a flipped signedness all still
    // compile, still link, and then read a value the other side laid out
    // differently: a silently wrong answer rather than a build failure. A
    // missing `AMresultFree` is a leak neither a link nor the Zig side can
    // see at all.
    //
    // **`abi_check` is the shape check.** `test/c/cabi.zig` translates that
    // same header and compares it against the library at comptime, so each of
    // those mismatches is a compile error there instead of a silent answer
    // here. It is a **check-only** artifact: a separate static library that
    // nothing links into the suite, which is linked against `cabi_lib` and so
    // against the production root `src/c/root.zig`. The thing that checks the
    // ABI is never the thing the ABI is checked on.
    //
    // `zig test` can do neither job: `src/c/**` is `extern "C"` over libc and
    // the test binary links none, which is why `src/root.zig:233-237` leaves it
    // out.
    //
    // Without a prefix, pkg-config supplies cmocka's linker metadata when
    // available and the toolchain is the fallback. An explicit prefix selects
    // that installation's headers and existing `lib` or `lib64` directory.
    const cmocka_prefix = b.option(
        []const u8,
        "cmocka-prefix",
        "Prefix holding cmocka's include/ and lib/ or lib64/ directories.",
    );

    // Production root forces C exports without depending on test sources.
    const cabi_lib = b.addLibrary(.{
        .name = "zautomerge",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    // `AMresultFrom` is the C ABI's one variadic function, and Zig 0.16
    // cannot declare one: `export fn f(x: c_int, a: ...)` is a parse error.
    // Upstream writes it in C for the same reason
    // (`rust/automerge-c/src/utils/result.c:5-33`), and so does this port, in
    // `src/c/result_from.c`, which forwards to a private `AMresultFromList`
    // export in `src/c/result.zig`. It belongs to the library, not to the
    // test binary: a C consumer links `libzautomerge` and expects the symbol
    // there.
    cabi_lib.root_module.addCSourceFiles(.{
        .root = b.path("src/c"),
        .files = &.{"result_from.c"},
    });
    cabi_lib.installHeader(b.path("include/automerge.h"), "automerge.h");
    b.installArtifact(cabi_lib);

    // Compile all signature/layout/discriminant checks against the shipped
    // header. The C suite links the production artifact, not this check root.
    const abi_check = b.addLibrary(.{
        .name = "zautomerge-abi-check",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/c/cabi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    abi_check.root_module.addIncludePath(b.path("include"));

    // The manifest is a deferred host-tool import: published packages omit
    // test/, so configuring a normal consumer must not import it here.
    const shared_fixture_generator = b.addExecutable(.{
        .name = "automerge-c-fixture-table",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/c/shared_fixture_table.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{
                .name = "manifest",
                .module = b.createModule(.{
                    .root_source_file = b.path("test/fixtures/manifest.zig"),
                    .target = b.graph.host,
                    .optimize = .ReleaseSafe,
                }),
            }},
        }),
    });
    const run_shared_fixture_generator = b.addRunArtifact(shared_fixture_generator);
    const shared_header = run_shared_fixture_generator.captureStdOut(.{
        .basename = "shared_fixtures.h",
    });
    const cabi_shared_lib = b.addLibrary(.{
        .name = "zautomerge",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    cabi_shared_lib.root_module.addCSourceFiles(.{
        .root = b.path("src/c"),
        .files = &.{"result_from.c"},
    });
    // This dynamic artifact belongs only to the explicit corpus gate; the
    // default package still installs cabi_lib's static artifact and header.
    const shared_consumer = b.addExecutable(.{
        .name = "automerge-c-shared-corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/c/shared_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    shared_consumer.root_module.addIncludePath(b.path("include"));
    shared_consumer.root_module.addIncludePath(shared_header.dirname());
    shared_consumer.root_module.addCSourceFiles(.{
        .files = &.{"test/c/shared_corpus.c"},
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    shared_consumer.root_module.linkLibrary(cabi_shared_lib);
    shared_consumer.step.dependOn(&abi_check.step);
    shared_consumer.each_lib_rpath = true;
    const run_shared_consumer = b.addRunArtifact(shared_consumer);
    run_shared_consumer.setCwd(b.path("."));
    run_shared_consumer.stdio = .inherit;
    const ctest_shared_step = b.step("ctest-shared", "Run the C corpus consumer against the dynamic production ABI");
    ctest_shared_step.dependOn(&run_shared_consumer.step);

    const ctest_exe = b.createModule(.{
        .root_source_file = b.path("test/c/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // The suite includes `<automerge-c/…>`, the reference's split header
    // layout. `test/c/include` holds forwarding headers onto this port's one
    // header; `include` holds that header.
    ctest_exe.addIncludePath(b.path("test/c/include"));
    ctest_exe.addIncludePath(b.path("include"));
    if (cmocka_prefix) |prefix| {
        // Absolute, resolved once, before any of it reaches the module.
        // `addIncludePath`/`addLibraryPath` are consumed at *build* time and a
        // build-time path is taken relative to the build root, so a relative
        // prefix is fine there — and `zig build ctest -Dcmocka-prefix=../…`
        // links and reports success. The `-L` directories are the other half
        // of the same command line and are a different resolution: they are
        // copied verbatim into the linked binary's RUNPATH, and
        // `run_ctest.setCwd` below runs the binary in `test/c/suite`, so a
        // relative prefix becomes a RUNPATH entry resolved against *that*.
        // The binary then dies before `main` with `libcmocka.so.0: cannot
        // open shared object file`, exit 127 — a link that succeeded and a
        // process that never started.
        //
        // `b.path` panics on an absolute sub_path (`Build.zig:1756-1759`) and
        // `b.pathFromRoot` is the low-level spelling of the same join
        // (`Build.zig:1767-1772`), so take the one that accepts either.
        // `pathResolve` is lexical (`fs.path.resolvePosix`, `path.zig:1107`):
        // it collapses `..` against the *build root*, never against the
        // directory `zig build` was invoked from.
        const abs_prefix = if (std.fs.path.isAbsolute(prefix)) prefix else b.pathFromRoot(prefix);
        ctest_exe.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ abs_prefix, "include" }) });
        // Only add library directories that exist. Missing candidates are
        // normal across prefixes; other inspection errors stop configuration.
        const lib_dir = b.pathJoin(&.{ abs_prefix, "lib" });
        const lib64_dir = b.pathJoin(&.{ abs_prefix, "lib64" });
        const has_lib_dir = directoryExistsAbsolute(b, lib_dir);
        const has_lib64_dir = directoryExistsAbsolute(b, lib64_dir);
        if (has_lib_dir) {
            ctest_exe.addLibraryPath(.{ .cwd_relative = lib_dir });
        }
        if (has_lib64_dir) {
            ctest_exe.addLibraryPath(.{ .cwd_relative = lib64_dir });
        }
        if (!has_lib_dir) {
            if (!has_lib64_dir) {
                std.debug.panic(
                    "cmocka prefix '{s}' has no existing lib or lib64 directory",
                    .{abs_prefix},
                );
            }
        }
    }
    ctest_exe.addCSourceFiles(.{
        .root = b.path("test/c/suite"),
        .files = &.{
            "actor_id_tests.c",
            "base_state.c",
            "byte_span_tests.c",
            "cmocka_utils.c",
            "cursor_tests.c",
            "doc_state.c",
            "doc_tests.c",
            "enum_string_tests.c",
            "item_tests.c",
            "list_tests.c",
            "macro_utils.c",
            "map_tests.c",
            "mark_tests.c",
            "str_utils.c",
            "ported_wasm/basic_tests.c",
            "ported_wasm/cursor_tests.c",
            "ported_wasm/suite.c",
            "ported_wasm/sync_tests.c",
        },
    });
    // The driver and this port's own group. They sit beside the suite, not
    // in it, so that `test/c/suite/` is the upstream directory unmodified
    // apart from what `test/c/suite/LICENSE` records. `test/c/main.zig` is
    // the root because Zig 0.16 cannot use a C file as the root of an
    // executable; `test/c/main.c` is upstream's driver with the function
    // renamed for the same reason.
    ctest_exe.addCSourceFiles(.{
        .root = b.path("test/c"),
        .files = &.{
            "abi_coverage.c",
            "main.c",
        },
    });
    ctest_exe.linkLibrary(cabi_lib);
    // An explicit prefix bypasses pkg-config so it cannot select a different
    // installation; otherwise pkg-config may provide the package's link flags.
    ctest_exe.linkSystemLibrary("cmocka", .{
        .use_pkg_config = if (cmocka_prefix == null) .yes else .no,
    });

    // Hoisted out of `addRunArtifact` because the API forces it, not because
    // it reads better. Zig 0.16's `ExecutableOptions` (`Build.zig:770-785`) has
    // no `each_lib_rpath` field — it exists only on `Step.Compile`
    // (`Compile.zig:93`) — so the one-field spelling
    // `b.addExecutable(.{ .each_lib_rpath = true, … })` is a **compile error in
    // the build script**, and a build script that does not compile fails every
    // step, not just this one. Un-hoisting this puts that error back.
    const ctest_bin = b.addExecutable(.{
        .name = "automerge-c-test",
        .root_module = ctest_exe,
        // The header checks must be analyzed even when no C case reaches a
        // given declaration.
    });
    ctest_bin.step.dependOn(&abi_check.step);
    // **This line has no measured effect on Zig 0.16.0 and is not the fix.**
    // `readelf -d` reports the same RUNPATH with this flag set and unset,
    // because the toolchain already copies every `-L` directory into the
    // RUNPATH on its own. It is here so the RUNPATH is a stated requirement
    // rather than a linker's default nobody wrote down — **if a future
    // toolchain changes that default, this is the line that says not to.**
    // Absolute cmocka library paths make the RUNPATH independent of cwd;
    // each_lib_rpath states the requirement for future toolchains.
    //
    // Why the RUNPATH matters at all: `run_ctest.setCwd` below runs the binary
    // in `test/c/suite`, so neither the caller's working directory nor
    // `LD_LIBRARY_PATH` reaches the child, and the suite's `libcmocka.so.0`
    // resolves from the binary's own RUNPATH or not at all.
    ctest_bin.each_lib_rpath = true;
    const run_ctest = b.addRunArtifact(ctest_bin);
    // `doc_tests.c:175` opens "files/brave-ape-49.automerge" relative to the
    // working directory, exactly as upstream's CMake copy step arranges it
    // (`rust/automerge-c/test/CMakeLists.txt:40-45`).
    run_ctest.setCwd(b.path("test/c/suite"));
    // cmocka prints one line per case and a `[  PASSED  ] N test(s).` count.
    // Inherit both streams so failing cases are visible; nonzero child exits
    // still fail the build step.
    run_ctest.stdio = .inherit;

    const ctest_step = b.step("ctest", "Run the upstream C conformance suite against the C ABI");
    ctest_step.dependOn(&run_ctest.step);
    // `zig build conformance` drives the Rust oracle in `tools/oracle` against
    // the reference automerge implementation, once per golden vector, and
    // `zig build conformance -- <name>` drives one subcommand. The oracle is a
    // development tool: it is not reachable from the default step, so
    // `zig build` and `zig build test` need neither cargo nor the reference
    // checkout.
    //
    // Every run step below runs in the build root rather than in whatever
    // directory `zig build` was invoked from. The oracle reads its corpus
    // relative to its working directory (`tools/oracle/src/main.rs:90`), and
    // the manifest path, the golden paths and the checkout the oracle links
    // against are all named relative to the build root: a step that resolves
    // them against the caller's working directory works from the repository
    // root and fails from anywhere else.

    // Mutable because every oracle run below takes `&link_oracle.step` to
    // depend on it: the link has to run *before* the runs, and a build graph
    // orders a step after another only by an edge, not by both being children
    // of the same parent.
    var link_oracle = b.addSystemCommand(&.{"sh"});
    link_oracle.addFileArg(b.path("tools/link-oracle.sh"));
    link_oracle.setCwd(b.path("."));
    link_oracle.setName("link automerge reference");

    // Re-record the vectors rather than check them. A gate must never rewrite
    // a committed expectation on its own: a golden file that a run quietly
    // overwrites is an expectation nothing checks any more. The default
    // regenerates into the build cache and compares, so a vector cannot drift
    // away from the reference without the build failing on the file that
    // drifted.
    const record = b.option(
        bool,
        "conformance-record",
        "Rewrite test/golden/ from the reference instead of checking it against it",
    ) orelse false;

    // The oracle's sink is `File::create`, which does not make its parent, so a
    // tree with no `test/golden/` yet needs one `mkdir -p` before anything can
    // be recorded into it. One step serves every vector, and in the steady
    // state, where nothing is recorded, there is no such step at all.
    var record_dir: ?*std.Build.Step.Run = null;
    if (record and !existsInBuildRoot(b, golden_dir)) {
        const mkdir = b.addSystemCommand(&.{ "mkdir", "-p" });
        mkdir.addFileArg(b.path(golden_dir));
        mkdir.setCwd(b.path("."));
        mkdir.setName(b.fmt("create {s}", .{golden_dir}));
        record_dir = mkdir;
    }

    // No subcommand runs every vector, because that is the gate's own command
    // and the one that has to work. One subcommand naming a vector runs that
    // one. Anything else — a subcommand the step does not own (the rule and the
    // list are both at `golden_vectors`), or a caller's own output file — goes
    // to the oracle unchanged, which is the command line the oracle already
    // implements.
    const args = b.args orelse &.{};
    const one_vector = args.len == 1 and isGoldenVector(args[0]);
    const conformance_step = b.step("conformance", "Check test/golden/ against the automerge reference oracle");
    if (one_vector) {
        conformance_step.dependOn(&addGoldenVector(b, link_oracle, args[0], record, record_dir).step);
    } else if (args.len == 0) {
        for (golden_vectors) |name| {
            conformance_step.dependOn(&addGoldenVector(b, link_oracle, name, record, record_dir).step);
        }
    } else {
        conformance_step.dependOn(&addPassthrough(b, link_oracle, args).step);
    }

    // `zig build save-interop` is the **live** half of the same gate, and it
    // is a step rather than a test because the reference has to answer
    // between the two halves. Nothing in it is committed: the port builds each
    // of the six shared scripts and prints its saves, `tools/oracle`'s
    // `verify-save-interop` loads each of them with the reference automerge,
    // compares what it loaded against the reference's own build of the same
    // script, and prints a re-save of what it loaded, and the port checks
    // **that**. The reverse direction is therefore proved against live bytes
    // and needs no golden file of its own, which is also the only honest way
    // to check it: a compressed save is not a byte-for-byte commitment, so a
    // pinned copy of one would be a fixture that only ever proves it is still
    // itself.
    //
    // **Three processes, ordered by the file that carries the data.** Each
    // stage takes the previous one's output as a `std.Build.LazyPath` —
    // `captureStdOut` (`Run.zig:675`) from the two that print records,
    // `setStdIn` for the one that reads them, `addFileArg` for the last — and
    // each of those calls adds the producing step to the consumer's
    // dependencies (`Run.zig:530`, `Run.zig:354`, `Build.zig:2469-2472`), so
    // the order is a property of the graph rather than a hand-written
    // `dependOn` that a later edit can drop. No output file is spelled out and
    // no stdout is parsed here: the oracle reads stdin because that is what
    // `cargo run` hands the binary it spawns.
    //
    // **No `expectExitCode` and no `stdio` assignment on the two runs whose
    // diagnostics matter**, and that is the load-bearing choice here.
    // `expectExitCode` is only reachable on a run in the checked stdio mode
    // (`addCheck` panics on every other mode, `Run.zig:641-652`), and the
    // checked mode pipes stderr and keeps it — a failure in the checked mode
    // reports the exit code and nothing else (`Run.zig:1433-1496`). What these
    // two runs need is the opposite: their own streams inherited, so a failed
    // oracle or a failed verification prints what it thinks went wrong next
    // to the line saying it failed. A non-zero exit still fails the step,
    // through the term handling every non-checked mode uses
    // (`Run.zig:1509`, `Step.zig:726-729`).
    //
    // Like `conformance`, this step needs cargo and the reference checkout, so
    // it is unreachable from the default step and from `zig build test`.
    const save_interop_bin = b.addExecutable(.{
        .name = "zautomerge-save-interop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/save_interop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });

    // 1. The port's own six saves, as NDJSON on stdout. **No argument** is the
    //    dump mode; `dump` is an accepted synonym and is not spelled here
    //    because the no-argument form is the one the executable's contract
    //    fixes. No `setCwd`, because the executable reads no path: a step that
    //    sets a working directory it does not need breaks the moment the file
    //    moves.
    const dump_saves = b.addRunArtifact(save_interop_bin);
    dump_saves.setName("dump the port's six saves");
    // `trim_whitespace` stays at its `.none` default on purpose. The records
    // are newline-delimited JSON and the trailing newline is part of what the
    // oracle is about to be handed; trimming the file would make the gate
    // check a save that nothing else ever produced.
    const save_requests = dump_saves.captureStdOut(.{ .basename = "save-requests.jsonl" });

    // 2. The reference's answer to those saves. **`has_side_effects` is set
    //    here**, and it is what makes this run inherit its stderr: with the
    //    default stdio, a run that has side effects gets `.inherit` on both
    //    streams, and one that does not gets a pipe the build reads only to
    //    report a failure (`Run.zig:1560-1571`). It also forces the run on
    //    every invocation, which matters because the oracle's own sources are
    //    not a declared build input: without it a cached capture of an older
    //    oracle would be the answer the port is checked against, and the gate
    //    would be checking itself (`Run.zig:707-714`, `Run.zig:926`).
    const verify_with_reference = b.addSystemCommand(&.{"cargo"});
    verify_with_reference.addArgs(&.{ "run", "--quiet", "--manifest-path" });
    verify_with_reference.addFileArg(b.path("tools/oracle/Cargo.toml"));
    verify_with_reference.addArgs(&.{ "--", "verify-save-interop" });
    verify_with_reference.setCwd(b.path("."));
    // The requests go in on stdin, which is how the oracle's other
    // stdin-driven subcommands (`feed`, `loadhex`) are fed, and this is the
    // edge that orders stage 1 before stage 2. `setStdIn` is not the same as
    // inheriting: a run with piped stdin asserts it is not in the `.inherit`
    // stdio mode (`Run.zig:1551-1553`).
    verify_with_reference.setStdIn(.{ .lazy_path = save_requests });
    verify_with_reference.has_side_effects = true;
    verify_with_reference.step.dependOn(&link_oracle.step);
    verify_with_reference.setName("run automerge oracle verify-save-interop");
    const reference_responses = verify_with_reference.captureStdOut(.{
        .basename = "reference-responses.jsonl",
    });

    // 3. The port checks what the reference made of its saves: the same six
    //    scenarios rebuilt on this side, the reference's re-save loaded and
    //    compared, and the response file's own hash, head and change-bytes
    //    claims checked rather than trusted. Its `has_side_effects` is the
    //    same argument as stage 2's, and its input is a reference answer
    //    produced a moment earlier, so it is live by construction; that is
    //    also what puts the checked-case count it reports on stderr in front
    //    of the operator while the step runs, rather than in a cache file
    //    nobody reads.
    const verify_reference_saves = b.addRunArtifact(save_interop_bin);
    verify_reference_saves.addArgs(&.{"verify"});
    verify_reference_saves.addFileArg(reference_responses);
    verify_reference_saves.has_side_effects = true;
    verify_reference_saves.setName("verify the reference's cross-loaded saves");

    const save_interop_step = b.step(
        "save-interop",
        "Check the port's saves against the automerge reference, in both directions",
    );
    save_interop_step.dependOn(&verify_reference_saves.step);

    // `zig build bench` is the performance gate, and it is a separate step
    // rather than another test because it asserts nothing about behaviour: it
    // measures the seven workloads that dominate the suite's wall clock and
    // prints `BENCH <name> <iters> <total_ns> <ns_per_iter>` per workload so
    // two builds can be diffed by machine rather than by eye. Nothing here is
    // filtered, skipped or weakened to make a number look better — the step
    // runs every workload it declares, and the numbers it prints are the only
    // thing it produces.
    //
    // **`-Doptimize` decides what is being measured.** Debug is what the test
    // gate runs and what the per-case cost record in `zig build test` reports;
    // `ReleaseSafe` is what a consumer runs, and it is the mode in which an
    // algorithmic change shows up as a real speedup rather than as a change
    // in how many bounds checks fire. Both are legitimate subjects and they do
    // not give the same answer, so the mode is the caller's choice and is not
    // pinned here.
    //
    // The benchmark is built against the published `zautomerge` module by the
    // name a consumer imports it by, so it cannot reach a private and cannot
    // drift from the public surface without failing to build.
    const bench_bin = b.addExecutable(.{
        .name = "zautomerge-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/zautomerge_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_bin);
    run_bench.has_side_effects = true;
    run_bench.step.dependOn(b.getInstallStep());
    const bench_step = b.step(
        "bench",
        "Measure the seven dominant workloads and print a machine-readable line each",
    );
    bench_step.dependOn(&run_bench.step);

    // Matched public-surface driver uses the system allocator on both engines.
    // Rust lives in the local oracle crate; its build/run recipe is in bench/README.md.
    const matched_bin = b.addExecutable(.{
        .name = "zautomerge-matched-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/matched_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    const run_matched = b.addRunArtifact(matched_bin);
    run_matched.has_side_effects = true;
    if (b.args) |matched_args| {
        run_matched.addArgs(matched_args);
    } else {
        run_matched.addArgs(&.{ "insert-growth", "small" });
    }
    const matched_step = b.step(
        "bench-matched",
        "Measure one deterministic workload matched to Rust Automerge",
    );
    matched_step.dependOn(&run_matched.step);

    // Counter validation is deterministic and needs no PMU permissions.
    const bench_counter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/perf_instructions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const bench_test_step = b.step("bench-test", "Check benchmark counter validity");
    timedTest(b, bench_counter_tests, "bench-counter", null, &.{ test_step, bench_test_step });
}

/// Run one test root under `test/verification_runner.zig` and put that root's
/// case record in front of whoever asked for the root.
///
/// The runner is the compiler's own `std.zig.Server` protocol with one thing
/// added: a file naming every case with the nanoseconds it spent, appended
/// and flushed per case. That is what makes a root which takes forty
/// minutes answer for itself — while it runs, from the file's last line, and
/// afterwards from the summary `report` prints. **Nothing about which cases
/// run changes**: the runner serves the same `builtin.test_functions` table
/// the compiler built, with the same flags, so the build runner's counts,
/// its per-case `--test-timeout` attribution, its leak and `std.log` counts
/// and its `Build Summary: N/M tests passed` line are the ones this project
/// has always read.
///
/// Four decisions in here, three of them about not losing the evidence:
///
/// - The runner is attached to the compile step here rather than passed to
///   each of the sixteen `b.addTest` call sites, because
///   `std.Build.addRunArtifact` reads `test_runner` to choose between the
///   server protocol and an exit code (`Build.zig`:986-1000). A runner
///   attached after that call would leave a `Run` step waiting for a
///   protocol this process never speaks.
/// - The record is declared with `addWriteFiles`, so the file and its
///   directory exist before the runner truncates them, and so `report` reads
///   a real file rather than a path that may be absent — a missing declared
///   input is a build error, and a cross row whose test binary never ran is
///   exactly that case. `run` takes the same `LazyPath` the report does, so
///   the build system renders one path for both, and the `dependOn` below
///   orders `WriteFile` → root → report, which is what stops a `WriteFile`
///   cache miss from truncating a finished record between the two.
/// - `report` is a step **per root** rather than one step for the whole
///   `test` step, so a root that fails still leaves every other root's
///   timings in the log.
/// - It narrows nothing. No filter, no seed, no reduced timeout and no
///   skipped root appears anywhere below; the runner runs every entry of the
///   table it is given, and `report` exits 0 whatever it finds, because a
///   reporting step must never be able to turn a passing run red.
fn timedTest(
    b: *std.Build,
    test_artifact: *std.Build.Step.Compile,
    label: []const u8,
    cwd: ?std.Build.LazyPath,
    steps: []const *std.Build.Step,
) void {
    test_artifact.test_runner = .{ .path = b.path("test/verification_runner.zig"), .mode = .server };

    const run = b.addRunArtifact(test_artifact);
    const record = b.addWriteFiles().add(b.fmt("zautomerge-test-timings-{s}.tsv", .{label}), "");
    run.addPrefixedFileArg("--zautomerge-progress=", record);

    const report = b.addSystemCommand(&.{"sh"});
    report.addArgs(&.{ "-c", timing_report_script, "sh" });
    report.addFileArg(record);
    if (cwd) |dir| {
        // The same working directory `run` gets, because that is what makes
        // the one path the build system rendered resolve to one file in both
        // processes rather than to two files in two directories.
        run.setCwd(dir);
        report.setCwd(dir);
    }
    report.expectExitCode(0);
    report.setName(b.fmt("print {s} case timings", .{label}));
    report.step.dependOn(&run.step);

    for (steps) |step| step.dependOn(&report.step);
}

/// What `timedTest` runs once a root has finished: that root's totals, its
/// slowest cases and the last few cases it reached. `grep` and `tail` keep
/// the log readable when the root was 1730 cases long, and the `exit 0` is
/// what makes a missing record a note rather than a failed step.
const timing_report_script =
    \\f="$1"
    \\if [ ! -f "$f" ]; then
    \\  echo "zautomerge-test-timings: no case record at $f (this root never ran)"
    \\  exit 0
    \\fi
    \\echo "zautomerge-test-timings: $f"
    \\grep '^#' "$f"
    \\echo "zautomerge-test-timings: last cases in the record"
    \\tail -n 5 "$f"
    \\exit 0
;

/// Run one oracle subcommand and either check its vector against the
/// committed copy or record it, per `-Dconformance-record`. `record_dir` is
/// the step that makes `test/golden/`, or null when the directory is already
/// there and nothing is going to be written into it.
///
/// The returned step is the one to depend on: the check depends on the oracle
/// run, and the run depends on the link, so the tail carries the whole chain.
fn addGoldenVector(
    b: *std.Build,
    link: *std.Build.Step.Run,
    name: []const u8,
    record: bool,
    record_dir: ?*std.Build.Step.Run,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"cargo"});
    run.addArgs(&.{ "run", "--quiet", "--manifest-path" });
    run.addFileArg(b.path("tools/oracle/Cargo.toml"));
    run.addArg("--");
    run.addArg(name);
    run.setCwd(b.path("."));
    // The reference checkout is not a declared build input, so this step runs
    // every time and leaves the recompilation question to cargo. Both streams
    // are inherited because the oracle reports its own failure on stderr and
    // through its exit code, and a conformance gate that fails quietly is the
    // failure this whole step exists to prevent.
    run.stdio = .inherit;
    run.step.dependOn(&link.step);

    const rel = goldenRelPath(b, name);
    const golden = b.path(rel);

    if (!record) {
        // Regenerate into the build cache, so what gets compared is what the
        // reference produced now and never a file an earlier run left behind,
        // then compare it with the committed vector. `cmp` says where the two
        // differ and exits non-zero, which fails the step that names the file.
        const generated = run.addOutputFileArg(b.fmt("{s}.jsonl", .{name}));
        const check = b.addSystemCommand(&.{"cmp"});
        check.addFileArg(generated);
        check.addFileArg(golden);
        check.setCwd(b.path("."));
        check.stdio = .inherit;
        check.step.dependOn(&run.step);
        run.setName(b.fmt("run automerge oracle {s}", .{name}));
        check.setName(b.fmt("check {s} against the reference", .{rel}));
        return check;
    }

    if (record_dir) |dir| run.step.dependOn(&dir.step);
    run.addFileArg(golden);
    run.setName(b.fmt("run automerge oracle {s} into {s}", .{ name, rel }));
    return run;
}

/// Hand the caller's own oracle command line to the oracle. Nothing is
/// checked: either the subcommand is one this step does not own, which prints
/// its report to the terminal, or the caller named an output file, which is
/// theirs to compare.
fn addPassthrough(b: *std.Build, link: *std.Build.Step.Run, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"cargo"});
    run.addArgs(&.{ "run", "--quiet", "--manifest-path" });
    run.addFileArg(b.path("tools/oracle/Cargo.toml"));
    run.addArg("--");
    run.addArgs(args);
    run.setCwd(b.path("."));
    run.stdio = .inherit;
    run.setName("run automerge oracle");
    run.step.dependOn(&link.step);
    return run;
}

/// The path of `name`'s committed vector, relative to the build root.
fn goldenRelPath(b: *std.Build, name: []const u8) []const u8 {
    return b.pathJoin(&.{ golden_dir, b.fmt("{s}.jsonl", .{name}) });
}

/// Whether `name` is a subcommand with a vector in `test/golden/`.
fn isGoldenVector(name: []const u8) bool {
    for (golden_vectors) |vector| {
        if (std.mem.eql(u8, name, vector)) return true;
    }
    return false;
}

/// Whether `rel` is in the committed tree. Asked while the build script runs,
/// which is on every `zig build`, so the answer cannot be stale inside one
/// build.
fn existsInBuildRoot(b: *std.Build, rel: []const u8) bool {
    b.build_root.handle.access(b.graph.io, rel, .{}) catch return false;
    return true;
}

/// Opens `path` to confirm it is a directory. Missing or non-directory
/// candidates may be skipped; other I/O errors stop configuration.
fn directoryExistsAbsolute(b: *std.Build, path: []const u8) bool {
    var directory = std.Io.Dir.openDirAbsolute(
        b.graph.io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => std.debug.panic(
            "cannot inspect cmocka library directory '{s}': {s}",
            .{ path, @errorName(err) },
        ),
    };
    directory.close(b.graph.io);
    return true;
}

/// Where the committed vectors live, relative to the build root.
const golden_dir = "test/golden";

/// The oracle subcommands that own a file in `test/golden/`, and what each
/// vector is for. Every subcommand a vector exists for is in this list, because
/// a vector the step cannot regenerate is a vector whose refresh means running
/// cargo by hand, and then the step is decoration rather than a gate.
///
/// | vector              | what depends on it                                                    |
/// | ------------------- | --------------------------------------------------------------------- |
/// | `doc`               | its 446-byte document and column specs are literals in `src/doc.zig`, `src/opset/columns.zig` and `src/storage/document_chunk.zig` |
/// | `change`            | its two change chunks and hashes are literals in `src/doc.zig`; `test/c/abi_coverage.c` takes its first `seq` from line 1 |
/// | `sync`              | read at run time by `src/sync/message.zig` and `src/sync/v1.zig`        |
/// | `diff`              | the scenarios `src/doc.zig` names in its diff tests                     |
/// | `converge`          | read at run time by `src/sync/protocol.zig` and `src/sync/v1.zig`        |
/// | `converge-parallel` | read at run time by `src/sync/protocol.zig`                             |
/// | `codec`             | read at run time by `src/hexane/codec_golden.zig`                      |
/// | `clock`             | embedded by `test/upstream_clock_test.zig`, which checks all subset frontiers and pairwise coverage/merges |
/// | `save-interop`       | read at run time by `test/save_interop_test.zig`, and the six scripts `zig build save-interop` replays against the live oracle |
/// | `hexane-regression` | read at run time by `src/hexane/raw.zig`'s `cross_slab_fuzz_regression`, which replays upstream's seed-799 op list step by step against the port's own run-budget column |
/// | `metadata`          | embedded by `test/upstream_metadata_test.zig`, which checks metadata fields, frontiers and ownership |
///
/// `doc`, `change` and `diff` are recorded as the provenance of literals in
/// `src/`, which is why re-recording them changes no test on its own: the
/// check is what says the literals still agree with the reference.
///
/// `save-interop` is the one vector with a **live** second consumer, and the
/// two directions are deliberately different. This file is the committed half:
/// it is a record of what the reference answers for the six shared scripts,
/// and `zig build conformance` is what says the record is still true. The
/// **reverse** direction — the port's saves loaded by the reference and the
/// reference's re-save loaded by the port — is checked by `zig build
/// save-interop` against `tools/oracle` running now, and reads no committed
/// file at all. That is not a gap in the vector table; a compressed save is
/// not a byte-for-byte commitment, so what the reverse direction has to agree
/// on is the normalized body, the materialized state and the hashes, and
/// those are checked live rather than pinned to bytes a DEFLATE encoder
/// chose.
///
/// Every subcommand **not** in this list owns no vector under `test/golden/`
/// and prints to stdout, so it is reachable by name and left alone. **That is
/// the rule and not an enumeration**: the oracle grows a subcommand
/// (`updocprobe` was the last) and a list of names goes stale on the next one,
/// which is how this sentence came to name four of the eleven it should have.
/// The eleven are `fixtures`, `marks`, `updocprobe`, `feed`, `loadinc`, `third`,
/// `text`, `isolateprobe`, `sample`, `loadhex` and `verify-save-interop`
/// (`tools/oracle/src/main.rs`:193-213). **`verify-save-interop` is the
/// subcommand that most wants a vector and must not have one**: it reads the
/// port's saves on stdin and answers with its own, so what it writes depends on
/// the thing under test rather than on the reference alone, and a committed
/// copy of that answer would be a fixture only the port it was recorded from
/// could pass. `zig build save-interop` runs it live and hands its answer
/// straight back to the port instead.
const golden_vectors = [_][]const u8{
    "doc",
    "change",
    "sync",
    "diff",
    "converge",
    "converge-parallel",
    "codec",
    "clock",
    "save-interop",
    "hexane-regression",
    "metadata",
    "api-parity",
};
