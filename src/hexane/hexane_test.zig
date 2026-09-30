//! Two properties of `rust/hexane/src/tests.rs` that have no upstream name, and
//! so live here rather than beside the case-for-case transcription.
//!
//! ## Why the named cases are not here any more
//!
//! This file once carried 31 blocks, 29 of which kept an upstream name and
//! were **a second copy of cases that `src/hexane/column.zig` already carried**
//! — the two files ported one upstream file between them and the coverage
//! count was inflated by 29. Those 29 were deleted on 2026-10-01; the
//! case-for-case transcription now lives in one place, `column.zig`, whose
//! block is named `Upstream `hexane/src/tests.rs`, ported case for case`.
//!
//! The two blocks that survive are the two that upstream has **no name for**:
//! they assert a property the port's own budget and mutation path carry, and
//! neither is a transcription of an upstream `#[test]`.
//!
//! ## What upstream's file does and does not reach
//!
//! Upstream's file has 286 `#[test]` functions carrying 284 distinct names —
//! `splice_and_nullable` and `u64_column_roundtrip_and_wire_divergence` each
//! appear twice, once per codec parameter. The three shapes
//! [`column.zig`](column.zig) leaves out, and none of them is a gap in
//! behaviour:
//!
//! * **`Column::with_max_segments(n)`** — the port has the knob
//!   (`Column.initWithBudget`, with `fromValues` and
//!   `LoadOpts.withMaxSegments` beside it), so a case that tunes the slab
//!   budget tunes it. **The budget is asserted below** as well, against
//!   `default_max_segments`: an *override* and the *invariant* are two
//!   different things, and only the second is this file's business.
//! * **`proptest` cases** — upstream draws them; a port pins the seeds, and one
//!   randomised case replaces the pair: [`splice_matches_a_model`] below.
//! * **`String` and `Vec<u8>` columns** — a byte payload is a value type here
//!   too: `Rle`/`RleOption` over `[]const u8` and `RleUtf8` over the same,
//!   nullable in each form, so a column of text is a `Column` with a bytes
//!   value type and not only a raw column ([`raw.zig`](raw.zig)).
//!
//! **The arena is [`testing.allocator`]**, so every column and every decoded
//! slice below is checked for a leak.

const std = @import("std");

const colmod = @import("zautomerge").hexane.column;
const testing = std.testing;

/// **The leak arbiter for the whole file.** One allocator, named once.
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;

/// The RLE column: integers stored as run lengths (`column.rs:406-437`).
const RleU64 = colmod.Column(u64, colmod.Rle(u64));
/// The nullable RLE column, where a run carries no value at all
/// (`column.rs:439-437`, the `repeat` and `absent` kinds).
const OptU64 = colmod.Column(?u64, colmod.RleOption(u64));
/// The boolean column: alternating run counts and no value bytes
/// ([`bool.zig`](bool.zig)).
const BoolCol = colmod.Column(bool, colmod.Bool);
/// The prefix column: values are run lengths and the column answers prefix
/// sums over them ([`prefix.zig`](prefix.zig)).
const PrefixU64 = colmod.Column(u64, colmod.Prefix(u64));
/// The delta column: values are differences from the running sum
/// ([`delta.zig`](delta.zig)).
const DeltaU64 = colmod.Column(u64, colmod.Delta(u64));

// ── The slab budget ────────────────────────────────────────────────────────────

test "slab_segments_stay_inside_the_budget" {
    // **`column.rs:21`'s budget, observed.** `slab_splitting` upstream tunes the
    // budget to 4 through a constructor argument the port does not have; this
    // asserts the budget the port *does* have is honoured, and it is the one
    // property every other case here silently rests on: a column whose slab held
    // more runs than the budget would encode differently from the reference's.
    var col = try build(gpa, RleU64, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    defer col.deinit();
    // Twenty alternating values are twenty runs, so they cannot fit in one
    // slab whatever the budget is.
    for (0..20) |i| try col.append(gpa, if (i % 2 == 0) @as(u64, 1) else @as(u64, 2));
    const segs = try col.slabSegments(gpa);
    defer gpa.free(segs);
    for (segs) |n| {
        try testing.expect(n <= colmod.default_max_segments or n == 1);
    }
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 30), got.len);
    // The twenty appended values alternate, and they start at index 10.
    try testing.expectEqual(@as(u64, 1), got[10]);
    try testing.expectEqual(@as(u64, 2), got[11]);
    try testing.expectEqual(@as(u64, 1), got[28]);
    try testing.expectEqual(@as(u64, 2), got[29]);
}

// ── 15. The randomised splice, which replaces upstream's two proptest cases ─

test "splice_matches_a_model" {
    // **Upstream's `fuzz_splice_ops` and `fuzz_sequential_splice_uint`**
    // ([`tests.rs`:818-866](../github-automerge-automerge/rust/hexane/src/tests.rs)), which
    // `proptest` draws and this port pins.
    //
    // **Why the seeds are written down and not drawn.** A proptest failure is
    // reproducible from `proptest-regressions/tests.txt`; a random one is not.
    // The seeds are constants, so a failure here is re-runnable from the line
    // that failed, and the four of them are chosen to cover the three shapes
    // that matter: a column that grows past its first slab, one that shrinks
    // back below it, and one whose null runs split and coalesce.
    const seeds = [_]u64{ 0xC0FFEE, 0x5EED, 0xABCD, 0x1234_5678 };
    for (seeds) |seed| {
        try oneSweep(seed);
    }
}

/// One randomised run: `steps` splices, each compared against a `Vec` model
/// **after every single step** rather than only at the end.
fn oneSweep(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();

    var col = try OptU64.init(gpa);
    defer col.deinit();
    var model: std.ArrayList(?u64) = .empty;
    defer model.deinit(gpa);

    var step: usize = 0;
    while (step < 120) : (step += 1) {
        const len = model.items.len;
        const at = if (len == 0) 0 else rand.intRangeAtMost(usize, 0, len);
        const del = if (at >= len) 0 else rand.intRangeAtMost(usize, 0, len - at);
        const inserted = rand.intRangeAtMost(usize, 0, 3);
        var values: [3]?u64 = undefined;
        for (values[0..inserted]) |*v| {
            v.* = if (rand.boolean()) null else @as(?u64, rand.intRangeAtMost(u64, 0, 4));
        }
        try col.splice(gpa, at, del, values[0..inserted]);
        try model.replaceRange(gpa, at, del, values[0..inserted]);

        const got = try col.toSlice(gpa);
        defer gpa.free(got);
        if (got.len != model.items.len) {
            std.debug.print("seed {x} step {d}: the column holds {d} value(s), the model {d}\n", .{
                seed,
                step,
                got.len,
                model.items.len,
            });
            return error.TestExpectedEqual;
        }
        for (got, model.items, 0..) |v, w, i| {
            if (v != w) {
                std.debug.print("seed {x} step {d}: value {d} is {any}, the model says {any}\n", .{
                    seed,
                    step,
                    i,
                    v,
                    w,
                });
                return error.TestExpectedEqual;
            }
        }
        if (col.len() != model.items.len) {
            std.debug.print("seed {x} step {d}: len() says {d}, the model says {d}\n", .{
                seed,
                step,
                col.len(),
                model.items.len,
            });
            return error.TestExpectedEqual;
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// A column holding `values`, in order
/// ([`v1_build`](../github-automerge-automerge/rust/hexane/src/tests.rs):11-18).
///
/// **`extend` and not a loop of `append`**: each call would be a separate
/// splice, and the case under test is the *build*, so one splice is what
/// upstream's loop of `insert(i, v)` amounts to.
fn build(a: Allocator, comptime Col: type, values: []const Col.Value) !Col {
    var col = try Col.init(a);
    errdefer col.deinit();
    try col.extend(a, values);
    return col;
}

/// A column's values, compared with `want` **element by element**
/// ([`assert_col`](../github-automerge-automerge/rust/hexane/src/tests.rs):80-94).
///
/// Upstream's `assert_col` also asserts that the encoding is canonical, which
/// the port holds through the codec round trips in `test/golden/codec.jsonl`;
/// what is left here is the contents. **The element loop and not a length**,
/// because a column whose values came back permuted has the right length, and
/// a splice that re-anchored a delta against the wrong row is that shape.
fn expectColumn(comptime Col: type, a: Allocator, col: *const Col, want: []const Col.Value) !void {
    const got = try col.toSlice(a);
    defer a.free(got);
    if (got.len != want.len) {
        std.debug.print("the column holds {d} value(s), want {d}\n", .{ got.len, want.len });
        return error.TestExpectedEqual;
    }
    for (got, 0..) |v, i| {
        if (v != want[i]) {
            std.debug.print("value {d} is {any}, want {any}\n", .{ i, v, want[i] });
            return error.TestExpectedEqual;
        }
    }
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **The named transcription of `rust/hexane/src/tests.rs` is in
//   `src/hexane/column.zig`**, in the block headed `Upstream
//   `hexane/src/tests.rs`, ported case for case`, and it keeps every upstream
//   name so a coverage count is legible against the reference file. **This
//   file holds the two properties upstream has no name for** — the run budget
//   and the randomised splice — so that one upstream file is ported in one
//   place rather than two.
//
// * **29 blocks were removed from this file on 2026-10-01** because they were a
//   second copy of named cases `column.zig` already carried. Two files
//   transcribing one upstream file is what `batch_insert.rs` did the same day,
//   and the coverage number was inflated by exactly the overlap.
//
// * **`Column::with_max_segments(n)` has a counterpart, and the budget a
//   column builds under is asserted here too.** The knob is
//   `Column.initWithBudget` ([`column.zig`](column.zig)), with `fromValues`
//   and `LoadOpts.withMaxSegments` beside it, and a budget below two is
//   refused where upstream asserts. `slab_segments_stay_inside_the_budget`
//   still asserts the *invariant* against `default_max_segments`, because an
//   override and the invariant are different things.
//
// * **Upstream's incremental loader is here, and so are the three cases that
//   drive it.** `RleEncoding::load_iter` with `LoadIterApi::try_next_run` and
//   `LoadIterApi::finalize` (`encoding.rs:540-546`, `column.rs:1156-1170`) is
//   [`Column.loadIter`](column.zig), and `load_iter_partial_consume_then_error`,
//   `load_roundtrip_proptest_streaming` and
//   `load_accumulates_prefix_weights_partial_consume` are transcribed beside
//   it there — the proptest ones over a fixed sweep of their axes rather than
//   a generator. `LoadOpts.length` and `LoadOpts.fill` are there too
//   ([`column.zig`](column.zig), `Column.LoadOpts`), so the two *stateful*
//   load options are covered as well.
//
// * **`proptest` is not a dependency and the seeds are constants.**
//   `fuzz_splice_ops` and `fuzz_sequential_splice_uint` are one case here,
//   `splice_matches_a_model`, over four fixed seeds, and it compares against a
//   `Vec` model **after every step** rather than at the end. **A randomised case
//   that only checks its final state is a case that can pass through a hundred
//   wrong intermediate states**, which is the whole of what a splice bug looks
//   like.
//
// * **`from_values`, `FromIterator` and the `GetEq` bounds are transcription
//   sugar, not behaviour.** What they test is a column's contents, and
//   [`build`] plus [`expectColumn`] are that; the port spells the construction
//   as `init` + `extend` because `Column` has no `FromIterator`.
//
// * **`Rle`, `RleOption`, `Prefix`, `Delta` and `Bool` are the five codecs the
//   port exposes**, and each case names the one upstream's type parameter
//   selects. `Column<T, E>` is a two-parameter generic here
//   ([`column.zig`](column.zig)) where upstream is a trait bound
//   (`column.rs:39-56`), because upstream's per-type dispatch is a type-level
//   map and the port's is a comptime switch.
//
// * **A `String` or `Vec<u8>` column is a `Column` here, with a bytes value
//   type.** Upstream's `ColumnValueRef for String` and `for Vec<u8>`
//   (`lib.rs:681-750`) pack a length-prefixed byte string; so does
//   `Rle`/`RleOption` over `[]const u8`, and `RleUtf8` adds the UTF-8 check
//   upstream's `String` arm has, in both the plain and the nullable form.
