const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `zautomerge` is a library. Consumers get the module; no artifact is
    // installed. Executables and the C ABI live in the test and example
    // targets below until the port grows a command-line tool.
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
    const slow_options = b.addOptions();
    slow_options.addOption(bool, "check_slow_paths", true);
    const slow_lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "build_options", .module = slow_options.createModule() }},
        }),
    });
    const run_slow_lib_tests = b.addRunArtifact(slow_lib_tests);

    const slow_path_step = b.step(
        "slow-path",
        "Run the unit tests with -Dslow-path forced on",
    );
    slow_path_step.dependOn(&run_slow_lib_tests.step);

    const lib_tests = b.addTest(.{ .root_module = mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

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
    const run_fixtures_tests = b.addRunArtifact(fixtures_tests);
    run_fixtures_tests.setCwd(b.path("."));
    test_step.dependOn(&run_fixtures_tests.step);

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
    const run_example_tests = b.addRunArtifact(example_tests);
    test_step.dependOn(&run_example_tests.step);

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
    const run_upstream_doc_tests = b.addRunArtifact(upstream_doc_tests);
    test_step.dependOn(&run_upstream_doc_tests.step);

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
    const run_mark_patches_tests = b.addRunArtifact(mark_patches_tests);
    test_step.dependOn(&run_mark_patches_tests.step);

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
    const run_hexane_tests = b.addRunArtifact(hexane_tests);
    test_step.dependOn(&run_hexane_tests.step);

    // The C ABI's Zig tests need libc and a root under src/ so imports stay
    // inside the module. The library test root deliberately links no libc.
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
    const run_c_abi_tests = b.addRunArtifact(c_abi_tests);
    run_c_abi_tests.setCwd(b.path("."));
    test_step.dependOn(&run_c_abi_tests.step);
    const c_abi_step = b.step("c-abi-test", "Run the C ABI's own Zig test sections");
    c_abi_step.dependOn(&run_c_abi_tests.step);

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
    const run_upstream_doc_more_tests = b.addRunArtifact(upstream_doc_more_tests);
    run_upstream_doc_more_tests.setCwd(b.path("."));
    test_step.dependOn(&run_upstream_doc_more_tests.step);

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
    const run_upstream_text_more_tests = b.addRunArtifact(upstream_text_more_tests);
    test_step.dependOn(&run_upstream_text_more_tests.step);
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
    const run_upstream_batch_insert_tests = b.addRunArtifact(upstream_batch_insert_tests);
    test_step.dependOn(&run_upstream_batch_insert_tests.step);

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
    const run_upstream_save_load_orphans_tests = b.addRunArtifact(upstream_save_load_orphans_tests);
    test_step.dependOn(&run_upstream_save_load_orphans_tests.step);

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
    const run_upstream_block_tests = b.addRunArtifact(upstream_block_tests);
    test_step.dependOn(&run_upstream_block_tests.step);

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
    const run_upstream_convert_string_tests = b.addRunArtifact(upstream_convert_string_tests);
    test_step.dependOn(&run_upstream_convert_string_tests.step);

    // `test/upstream_rich_text_fuzz.zig` is `$AUTOMERGE_REF/rust/automerge/
    // tests/rich_text_fuzz_crash.rs` — **8 of its 9** `#[test]` cases, ported
    // case for case and in upstream's order, and the ninth recorded as a gap
    // at its own upstream line (`rescue`, which needs a load that skips
    // mark-order validation and a document-level `hydrate`; the port has
    // neither). Run the same way as every other step above — its own module,
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
    const run_upstream_rich_text_fuzz_tests = b.addRunArtifact(upstream_rich_text_fuzz_tests);
    test_step.dependOn(&run_upstream_rich_text_fuzz_tests.step);

    // `zig build ctest` builds the upstream C conformance suite — the cmocka
    // suite from `rust/automerge-c/test/`, copied verbatim into
    // `test/c/suite/` — against the C ABI, and runs it. This is the only gate
    // that can see an ABI or signature mismatch: the suite is C, compiled
    // against `include/automerge.h` and linked against the library's symbols,
    // so a declaration the library does not export is a link error, a wrong
    // integer width is a silently wrong answer, and a missing
    // `AMresultFree` is a leak the Zig side cannot see. `zig test` cannot do
    // this job at all: `src/c/**` is `extern "C"` over libc and the test
    // binary links none, which is why `src/root.zig:222-226` leaves it out.
    //
    // cmocka is a build-time-only dependency, reached the same way a system
    // library is: with no option the compiler's own default search paths are
    // used, and `-Dcmocka-prefix=<dir>` points at an installation for a
    // platform whose compiler wrapper has no default. Nothing is vendored and
    // no path is hardcoded.
    const cmocka_prefix = b.option([]const u8, "cmocka-prefix", "Directory holding a cmocka installation's include/ and lib/, for a " ++
        "platform whose compiler wrapper has no default search path. Empty " ++
        "means the compiler's defaults.");

    // The library, not the module: the C suite needs real symbols, and
    // `test/c/cabi.zig` is what forces the `export fn`s to be analyzed.
    const cabi_lib = b.addLibrary(.{
        .name = "zautomerge",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/c/cabi.zig"),
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
        // Both spellings, because a prefix that is not `/usr` may put its
        // libraries in either: a distribution package uses `lib64` on
        // 64-bit RPM systems and Nix uses `lib`. A path that does not exist
        // is not an error for a linker search path, so one option covers
        // every layout.
        ctest_exe.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ abs_prefix, "lib" }) });
        ctest_exe.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ abs_prefix, "lib64" }) });
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
    ctest_exe.linkSystemLibrary("cmocka", .{});

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
    });
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
    // cmocka prints one line per case and a `[  PASSED  ] N test(s).` count
    // (`cmocka_run_group_tests`), which is the per-case report this step
    // exists to produce. `main.c` sums the group results, so a non-zero exit
    // is a failing case and must stay a build failure.
    run_ctest.expectExitCode(0);

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
}

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
/// | `clock`             | nothing yet: checked, and read by no test                              |
///
/// `doc`, `change` and `diff` are recorded as the provenance of literals in
/// `src/`, which is why re-recording them changes no test on its own: the
/// check is what says the literals still agree with the reference.
///
/// Every subcommand **not** in this list owns no vector under `test/golden/`
/// and prints to stdout, so it is reachable by name and left alone. **That is
/// the rule and not an enumeration**: the oracle grows a subcommand
/// (`updocprobe` was the last) and a list of names goes stale on the next one,
/// which is how this sentence came to name four of the ten it should have.
/// The ten are `fixtures`, `marks`, `updocprobe`, `feed`, `loadinc`, `third`,
/// `text`, `isolateprobe`, `sample` and `loadhex`
/// (`tools/oracle/src/main.rs`:193-213).
const golden_vectors = [_][]const u8{
    "doc",
    "change",
    "sync",
    "diff",
    "converge",
    "converge-parallel",
    "codec",
    "clock",
};
