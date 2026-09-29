//! The fixture corpus and the outcome each file must produce.
//!
//! Every file listed here is a verbatim copy of an upstream artefact, taken
//! from one of three places in `../github-automerge-automerge`:
//!
//! - `rust/automerge/tests/fixtures/` — 9 wire-format regression files.
//! - `rust/automerge/tests/fuzz-crashers/` — 8 `cargo fuzz` crash artefacts.
//! - `interop/exemplar` — the cross-implementation conformance document,
//!   copied here as `interop-exemplar` so the corpus stays flat.
//!
//! The `expect` column is what a load must do. For the 8 crashers it comes
//! from `rust/automerge/tests/test.rs:2210-2219`, which asserts
//! `Automerge::load` returns `Err` for every file in `tests/fuzz-crashers/`.
//! For the 9 wire-format files it comes from the tests named in each `note`;
//! three of those nine assert `Err`, and two more are permissive upstream but
//! error in the reference, so they are recorded as `load_err` here. A load
//! that succeeds where this says `load_err` is a bug, and a load that fails
//! where this says `load_ok` is a bug.

const std = @import("std");

/// One file in the corpus, and what loading it must do.
pub const Fixture = struct {
    /// What loading this file must do.
    pub const Expect = enum { load_ok, load_err };
    /// The file name under test/fixtures/.
    name: []const u8,
    expect: Expect,
    /// One line describing why this file exists, from the upstream test that
    /// uses it.
    note: []const u8,
};

/// The corpus, sorted by name. `test/fixtures_test.zig` asserts that this
/// list and the directory agree in both directions.
pub const fixtures: []const Fixture = &.{
    .{
        .name = "64bit_obj_id_change.automerge",
        .expect = .load_err,
        .note = "A change whose opId counter is 2^42, which truncates to 0 in 32 bits and would collide with ROOT. " ++
            "Upstream accepts either outcome (tests/test.rs:2259); the reference reports \"invalid change columns: counter too large\".",
    },
    .{
        .name = "64bit_obj_id_doc.automerge",
        .expect = .load_err,
        .note = "The same out-of-range opId, carried in a document chunk instead of a change chunk. " ++
            "Upstream accepts either outcome (tests/test.rs:2265); the reference reports \"delta value out of domain\".",
    },
    .{
        .name = "action-is-48.automerge",
        .expect = .load_err,
        .note = "cargo fuzz artifact: a change op whose action index is 48, outside the Action enum. Must error, not crash (tests/test.rs:2210-2219).",
    },
    .{
        .name = "broken_zero_width_mark.automerge",
        .expect = .load_err,
        .note = "A Text object whose mark end precedes its mark begin. Load must fail with \"invalid mark operation order\" (tests/rich_text_fuzz_crash.rs:222-229).",
    },
    .{
        .name = "counter_value_has_incorrect_meta.automerge",
        .expect = .load_err,
        .note = "The value metadata says 2 bytes but the LEB is 1 byte long with an extra 0 (tests/test.rs:2228-2229).",
    },
    .{
        .name = "counter_value_is_ok.automerge",
        .expect = .load_ok,
        .note = "The well-formed counterpart of the two above: one counter value with a correct 1-byte LEB (tests/test.rs:2232-2233, also src/automerge/current_state.rs:526-533).",
    },
    .{
        .name = "counter_value_is_overlong.automerge",
        .expect = .load_err,
        .note = "The counter LEB is overlong: 2 bytes where 1 would have sufficed (tests/test.rs:2230-2231).",
    },
    .{
        .name = "crash-da39a3ee5e6b4b0d3255bfef95601890afd80709",
        .expect = .load_err,
        .note = "cargo fuzz artifact: the 10-byte empty document chunk magic, checksum, type 0, length 0. The name is the SHA-256 of the empty string (tests/test.rs:2210-2219).",
    },
    .{
        .name = "incorrect_max_op.automerge",
        .expect = .load_err,
        .note = "cargo fuzz artifact: the max_op column disagrees with the heads derived from the ops (\"mismatching heads\") (tests/test.rs:2210-2219).",
    },
    .{
        .name = "interop-exemplar",
        .expect = .load_ok,
        .note = "Copy of upstream interop/exemplar, the only cross-implementation conformance document; its expected export is pinned in interop/README.md:23-40.",
    },
    .{
        .name = "invalid_deflate_stream.automerge",
        .expect = .load_err,
        .note = "cargo fuzz artifact: a document chunk whose DEFLATE payload does not inflate (tests/test.rs:2210-2219).",
    },
    .{
        .name = "missing_actor.automerge",
        .expect = .load_err,
        .note = "cargo fuzz artifact: the actor column names an actor the actor table does not contain (tests/test.rs:2210-2219).",
    },
    .{
        .name = "overflow_in_length.automerge",
        .expect = .load_err,
        .note = "cargo fuzz artifact: a length column value large enough to overflow its row, leaving the columns out of normalized order (tests/test.rs:2210-2219).",
    },
    .{
        .name = "too_many_deps.automerge",
        .expect = .load_err,
        .note = "cargo fuzz artifact: a dependency count above the cap the change format allows (tests/test.rs:2210-2219).",
    },
    .{
        .name = "too_many_ops.automerge",
        .expect = .load_err,
        .note = "cargo fuzz artifact: an operation count above the cap, overflowing the op column (\"u32 overflow\") (tests/test.rs:2210-2219).",
    },
    .{
        .name = "two_change_chunks.automerge",
        .expect = .load_ok,
        .note = "Two concatenated change chunks; after load ROOT.a is a map whose .a is the string \"b\" (tests/test.rs:2237-2244).",
    },
    .{
        .name = "two_change_chunks_compressed.automerge",
        .expect = .load_ok,
        .note = "The same document with the second change chunk DEFLATE-compressed (tests/test.rs:2245).",
    },
    .{
        .name = "two_change_chunks_out_of_order.automerge",
        .expect = .load_ok,
        .note = "The same two change chunks, in the other order, so a load must order them by dependency (tests/test.rs:2246).",
    },
};

test "every fixture name is a plain file name with no path separator" {
    for (fixtures) |f| {
        try std.testing.expect(std.mem.indexOfScalar(u8, f.name, '/') == null);
        try std.testing.expect(f.name.len > 0);
        try std.testing.expect(!std.mem.startsWith(u8, f.name, "."));
    }
}
