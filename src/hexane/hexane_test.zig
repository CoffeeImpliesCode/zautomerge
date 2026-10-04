//! Seven cases of `rust/hexane/src/tests.rs`, and the one property upstream has
//! no name for.
//!
//! ## Why the other named cases are not here
//!
//! This file once carried 31 blocks, 29 of which kept an upstream name and
//! were **a second copy of cases that `src/hexane/column.zig` already carried**
//! — the two files ported one upstream file between them and the coverage
//! count was inflated by 29. Those 29 were deleted on 2026-10-01, and the rest
//! of the case-for-case transcription lives in one place, `column.zig`, whose
//! block is named `Upstream `hexane/src/tests.rs`, ported case for case`.
//!
//! ## Why these seven are here anyway
//!
//! Each of the seven is an upstream case whose **fixture or input sweep is the
//! case**, and each was reachable in the port only as something narrower:
//!
//! * **`fuzz_bool_splice_exhaustive`** and
//!   **`fuzz_option_u64_splice_exhaustive`** ([`tests.rs`:2853-2907](../github-automerge-automerge/rust/hexane/src/tests.rs)
//!   and [`:2909-2965`](../github-automerge-automerge/rust/hexane/src/tests.rs))
//!   put nine `(delete, insert)` shapes at **every position** a two-hundred-row
//!   column admits, on a run budget of eight. `column.zig`'s
//!   `random splices agree with a plain array` **draws** its positions, which
//!   is a different statement: it holds that a drawn splice is right, not that
//!   every one of them is.
//! * **`fuzz_slab_merge_invariant`** ([`tests.rs`:4056-4086](../github-automerge-automerge/rust/hexane/src/tests.rs))
//!   drives a hundred thousand inserts and removes past one predicate — no
//!   undersized slab left beside a neighbour the pair would fit inside —
//!   checked **after every operation**, with the generator written out rather
//!   than drawn. `column.zig` holds the same predicate
//!   (`Column.mergeableNeighbours`, over a seed sweep of splices); the case is
//!   the scale and the fixed state it starts from.
//! * **`splice_runs_with_ranges`** ([`tests.rs`:1256-1274](../github-automerge-automerge/rust/hexane/src/tests.rs))
//!   feeds one column's `runs().ranges([…])` into another's `splice_runs`.
//!   Every part of that pipeline exists here — `Iterator.runs`, `Runs.ranges`,
//!   `Column.spliceRuns` — and what the case holds is that the **adapter**
//!   carries the second and third window, which is only true if the chain
//!   runs and a hand-concatenated window list does not.
//! * **`splice_runs_from_another_columns_iter`**
//!   ([`tests.rs`:1148-1157](../github-automerge-automerge/rust/hexane/src/tests.rs))
//!   builds the *other* column and clips its run list, and **the clip is the
//!   subject**: a window opening one row inside a three-row repeat has to
//!   splice `7 × 2` and not `7 × 3`. The port held the shape at the slab level
//!   with the window's four values written out by hand, which asserts the
//!   expected answer rather than the derivation that produces it.
//! * **`fuzz_splice_ops`** and **`fuzz_sequential_splice_uint`**
//!   ([`tests.rs`:818-866](../github-automerge-automerge/rust/hexane/src/tests.rs))
//!   are the two `proptest` cases, transcribed **under their own names and
//!   their own draw ranges** — five hundred cases each, a case being `1..=19`
//!   splice operations or `1..=79` values at a start out of `0..=49` — with
//!   only the generator behind them pinned. **The port folded both into one
//!   randomised sweep** (`splice_matches_a_model`, deleted), which drew a fresh
//!   position per operation: a four-value splice, a monotone insert walk and a
//!   run of removes at one fixed position were each unreachable from it, and
//!   one case is not two.
//!
//! ## What upstream's file does and does not reach
//!
//! **How many of upstream's cases carry a declaration, and which, is
//! `docs/hexane-cases.json`'s to record**: a per-case tally kept beside the
//! code is a second instrument, it drifts as cases are added, and the port
//! renames ported cases into English, so a count of upstream *names*
//! under-reports what is actually asserted.
//!
//! Two shapes in upstream's file have **no case name to transcribe**, so the
//! case-for-case block has nothing to say about them. Neither is a gap in
//! behaviour, and each is reachable in the port today:
//!
//! * **`Column::with_max_segments(n)`** — the budget is a runtime value on
//!   every constructor that takes one: `Column.initWithBudget`,
//!   `Column.fromValues`, `Column.Encoder.maxSegments`, and
//!   `LoadOpts.withMaxSegments` beside them. So a case that tunes the slab
//!   budget tunes it, and the tuned cases are `column.zig`'s. **The default is
//!   asserted below** as well, against `default_max_segments`: an *override*
//!   and the *invariant* are two different things, and only the second is this
//!   file's business.
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
    // budget to 4 through a constructor argument; the port has that argument
    // too — `Column.fromValues`, `Column.Encoder.maxSegments` and
    // `LoadOpts.withMaxSegments` each take the budget as a runtime value — and
    // the tuned cases are `column.zig`'s. **What is asserted here is the
    // default**, because an override and the invariant are different things,
    // and a column whose slab held more runs than the budget would encode
    // differently from the reference's.
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

// ── The two proptest cases, under their own names ────────────────────────────

/// How many cases upstream draws
/// ([`ProptestConfig::with_cases(500)`](../github-automerge-automerge/rust/hexane/src/tests.rs):815).
const proptest_cases = 500;

/// The generator behind them. **`proptest` is not a dependency and upstream
/// draws its cases**, so a port pins one seed per case rather than dropping the
/// cases for being drawn: case `k` is `.init(proptest_seed_base + k)`, so the
/// same sweep is walked on every run and a failure is re-runnable from the
/// case number its report carries.
const proptest_seed_base = 0xF1CE_5EED;

/// Upstream's `nullable_uint_value`
/// ([`tests.rs`:807-812](../github-automerge-automerge/rust/hexane/src/tests.rs)):
/// `None` with weight **three** against `Some(v)` with weight **seven**, `v`
/// drawn from `0..4`. **Three in ten draws are therefore absent**, which is
/// upstream's ratio and not a coin flip: an absent run rides in the run header
/// and separates two runs without merging with either, and that is the shape
/// both cases below are about.
fn drawNullableValue(rand: std.Random) ?u64 {
    if (rand.intRangeAtMost(u8, 0, 9) < 3) return null;
    return rand.intRangeAtMost(u64, 0, 3);
}

/// One operation's check: the values against the plain array, then the column's
/// own structural invariants — upstream's `assert_col`
/// ([`tests.rs`:80-94](../github-automerge-automerge/rust/hexane/src/tests.rs))
/// without its encoding half, which [`expectCanonical`] holds at the points
/// upstream calls it.
///
/// **After every operation, not only at the end of a case.** A randomised case
/// that only checks its final state is a case that can pass through a hundred
/// wrong intermediate states, and an intermediate state is what a splice bug
/// is.
fn expectSpliceStep(
    col: *const OptU64,
    model: *const std.ArrayList(?u64),
    context: []const u8,
) !void {
    try expectColumn(OptU64, gpa, col, model.items, context);
    try validateColumn(OptU64, col, context);
}

/// The coordinates a failure is re-run from: the case's own number and the
/// operation inside it.
fn proptestLine(buf: []u8, name: []const u8, case: usize, op: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s} case={d} op={d}", .{ name, case, op }) catch "unprintable coordinates";
}

test "fuzz_splice_ops" {
    // **Upstream's `fuzz_splice_ops`**
    // ([`tests.rs`:818-838](../github-automerge-automerge/rust/hexane/src/tests.rs)),
    // one case per draw and [`proptest_cases`] cases.
    //
    // **Every draw is upstream's draw.** A case is a vector of `1..20`
    // operations, so **one to nineteen of them** (`:820-824`); each operation
    // draws a raw position from `0..1000`, a raw delete from `0..10` and a
    // vector of `0..5` nullable values, so **up to four inserts in one
    // operation** (`:821-822`). **Four is a width a draw per operation does not
    // reach**, which is why the case and a randomised sweep are two things.
    //
    // **The raw position is reduced modulo the model, not clipped**
    // (`tests.rs:830`): `idx = pos_raw % (len + 1)`, so a wide draw lands
    // somewhere else on every operation, and an empty model takes position
    // zero whatever the draw said. **The delete is the only clamped quantity**
    // (`:831`), against `len - min(idx, len)`.
    //
    // **The column is the nullable RLE one** (`Column::<Option<u64>>::new`,
    // `tests.rs:826`), and the values are [`drawNullableValue`] — `None` at
    // three in ten, `Some(0..=3)` at seven in ten.
    for (0..proptest_cases) |case| {
        var prng: std.Random.DefaultPrng = .init(proptest_seed_base +% @as(u64, @intCast(case)));
        const rand = prng.random();
        const op_count = rand.intRangeAtMost(usize, 1, 19);

        var col = try OptU64.init(gpa);
        defer col.deinit();
        var model: std.ArrayList(?u64) = .empty;
        defer model.deinit(gpa);

        for (0..op_count) |op| {
            const pos_raw = rand.intRangeAtMost(usize, 0, 999);
            const del_raw = rand.intRangeAtMost(usize, 0, 9);
            const ins_count = rand.intRangeAtMost(usize, 0, 4);
            var inserted: [4]?u64 = undefined;
            for (inserted[0..ins_count]) |*v| v.* = drawNullableValue(rand);

            const idx = if (model.items.len == 0) 0 else pos_raw % (model.items.len + 1);
            const del = @min(del_raw, model.items.len - @min(idx, model.items.len));
            try col.splice(gpa, idx, del, inserted[0..ins_count]);
            try model.replaceRange(gpa, idx, del, inserted[0..ins_count]);

            var line: [96]u8 = undefined;
            try expectSpliceStep(&col, &model, proptestLine(&line, "fuzz_splice_ops", case, op));
        }

        // Upstream's one `assert_col` (`tests.rs:836`), whose last line is the
        // `validate_encoding` the port holds in [`expectCanonical`] — and in
        // [`validateColumn`] after every operation above.
        var line: [96]u8 = undefined;
        try expectCanonical(OptU64, gpa, &col, model.items, proptestLine(&line, "fuzz_splice_ops end", case, op_count));
    }
}

test "fuzz_sequential_splice_uint" {
    // **Upstream's `fuzz_sequential_splice_uint`**
    // ([`tests.rs`:840-864](../github-automerge-automerge/rust/hexane/src/tests.rs)),
    // [`proptest_cases`] cases of **`1..=79` values at a start of `0..=49`**
    // (`:842-843`).
    //
    // **The two phases walk the column in opposite directions, and the pair of
    // directions is the case** (`:839`, "the hot path for splice-like usage"):
    //
    // * the **insert phase is monotone** — value `i` goes to
    //   `min(start_pos + i, len)` (`:849`), so the index advances one step at a
    //   time and re-clamps to the end every time the column is shorter than the
    //   walk. An append at the tail, over and over, against a b-tree that
    //   re-anchors on every one.
    // * the **delete phase takes one fixed position** — `values.len() / 2`
    //   removes at `min(start_pos, len - 1)` (`:855-860`) — so the index stands
    //   still while the column shrinks beneath it.
    //
    // **Neither phase is reachable by drawing a position per operation**, which
    // is what `fuzz_splice_ops` above does and what a randomised splice is;
    // and the two together are the shape [`splice_runs_matches_per_item_splice`]
    // is not, because that one contrasts bulk against incremental at a fixed
    // pair of coordinates.
    //
    // **The delete count is a `min` of the draw and the rows behind the
    // position** (`:856`), and the loop stops on an empty model (`:858`), so a
    // case whose deletes outrun its rows stops rather than underflowing.
    // **`assert_col` runs twice** — after the inserts (`:853`) and after the
    // deletes (`:863`) — and both are held here.
    for (0..proptest_cases) |case| {
        var prng: std.Random.DefaultPrng = .init(proptest_seed_base +% @as(u64, @intCast(case)));
        const rand = prng.random();
        const value_count = rand.intRangeAtMost(usize, 1, 79);
        const start_pos = rand.intRangeAtMost(usize, 0, 49);
        var values: [79]?u64 = undefined;
        for (values[0..value_count]) |*v| v.* = drawNullableValue(rand);

        var col = try OptU64.init(gpa);
        defer col.deinit();
        var model: std.ArrayList(?u64) = .empty;
        defer model.deinit(gpa);

        for (values[0..value_count], 0..) |v, i| {
            const idx = @min(start_pos + i, model.items.len);
            try col.splice(gpa, idx, 0, &[_]?u64{v});
            try model.insert(gpa, idx, v);
            var line: [96]u8 = undefined;
            try expectSpliceStep(&col, &model, proptestLine(&line, "sequential insert", case, i));
        }

        // Upstream's first `assert_col` (`tests.rs:853`).
        var ins_line: [96]u8 = undefined;
        try expectCanonical(OptU64, gpa, &col, model.items, proptestLine(&ins_line, "sequential inserts", case, value_count));

        const del_pos = @min(start_pos, model.items.len -| 1);
        const del_count = @min(value_count / 2, model.items.len - del_pos);
        for (0..del_count) |step| {
            if (model.items.len == 0) break;
            const idx = @min(del_pos, model.items.len - 1);
            try col.removeN(gpa, idx, 1);
            _ = model.orderedRemove(idx);
            var line: [96]u8 = undefined;
            try expectSpliceStep(&col, &model, proptestLine(&line, "sequential remove", case, step));
        }

        // Upstream's second `assert_col` (`tests.rs:863`).
        var end_line: [96]u8 = undefined;
        try expectCanonical(OptU64, gpa, &col, model.items, proptestLine(&end_line, "sequential removes", case, del_count));
    }
}

// ── The exhaustive position sweeps ────────────────────────────────────────────

/// Upstream's nine `(delete, insert)` shapes — the same nine in both
/// exhaustive cases ([`tests.rs`:2861-2871](../github-automerge-automerge/rust/hexane/src/tests.rs)
/// and [`:2920-2930`](../github-automerge-automerge/rust/hexane/src/tests.rs)).
/// Three inserts, three deletes and three replacements, each at one, ten and
/// a hundred rows: the axis that matters is that **the delete and the insert
/// scale independently**, so a shape is a pair and not a "size".
const splice_shapes = [_][2]usize{
    .{ 0, 1 },
    .{ 0, 10 },
    .{ 0, 100 },
    .{ 1, 0 },
    .{ 10, 0 },
    .{ 100, 0 },
    .{ 1, 1 },
    .{ 10, 10 },
    .{ 100, 100 },
};

test "fuzz_bool_splice_exhaustive" {
    // **`tests.rs:2853-2907`.** Two hundred booleans in a column built at a
    // run budget of **eight**, and each of the nine shapes applied at **every
    // position that shape admits** — two hundred and one positions for a pure
    // insert, one hundred and one for a delete of a hundred, and so on.
    //
    // **A fresh base at every position.** Upstream holds one column and
    // `clone()`s it per position; this rebuilds it from the same values
    // through the same constructor, which is the same column, so no splice
    // can be standing on the last one's work. A shared column would make each
    // case assert its predecessor too, and a failure would not say which
    // position it was.
    //
    // **The generator is pinned where upstream draws it** (`rand::rng()`):
    // a failure here is re-runnable from this test's name, where upstream's
    // needs a seed file it has not got. **The sampling domain is upstream's** —
    // one bit a row — so about half the column is single-row runs and the
    // budget of eight cuts it into many small slabs.
    var prng: std.Random.DefaultPrng = .init(0xB015_5EED);
    const rand = prng.random();
    var initial: [200]bool = undefined;
    for (&initial) |*v| v.* = rand.boolean();
    try exhaustiveSplices(BoolCol, &initial, 8, &.{ false, true }, 0xB015_5EED);
}

test "fuzz_option_u64_splice_exhaustive" {
    // **`tests.rs:2909-2965`.** The same sweep over a nullable column, and
    // the same budget of eight.
    //
    // **The domain is upstream's five choices, not a full range**: `None`,
    // `1`, `2`, `3`, `4`. That is the shape the case is about — an absent run
    // rides in the run header and carries no value, so it separates two runs
    // without merging with either, and a domain of arbitrary `u64`s would
    // never produce one. One row in five is absent, so the absent runs are
    // long enough to be cut across and spliced into.
    //
    // Upstream wraps each splice in `catch_unwind` and re-panics with the
    // coordinates. **A Zig test failure already carries them** — the helpers
    // below print the shape, the position and the delete — so there is nothing
    // to catch and nothing to re-print.
    const choices = [_]?u64{ null, 1, 2, 3, 4 };
    var prng: std.Random.DefaultPrng = .init(0x0B7E_C710);
    const rand = prng.random();
    var initial: [200]?u64 = undefined;
    for (&initial) |*v| v.* = choices[rand.intRangeAtMost(usize, 0, choices.len - 1)];
    try exhaustiveSplices(OptU64, &initial, 8, &choices, 0x0B7E_C710);
}

/// Upstream's two exhaustive sweeps, over one column of `initial` values on a
/// run budget of `budget` runs a slab
/// ([`tests.rs`:2853-2907](../github-automerge-automerge/rust/hexane/src/tests.rs),
/// [`:2909-2965`](../github-automerge-automerge/rust/hexane/src/tests.rs)).
///
/// `domain` is the pool the inserted values are drawn from, so each case keeps
/// upstream's sampling domain rather than this file's idea of one: two booleans
/// for the boolean column, and upstream's five nullable choices for the other.
///
/// `seed` is the case's own, and the generator is built here rather than handed
/// in, so **one call site per case and one pinned seed per call site**.
///
/// **Three things are held after every splice**, and the third is the one a
/// content comparison cannot see:
///
/// * the structural invariants ([`validateColumn`], this port's
///   `validate_column` / `validate_rle_column` / `validate_bool_column`);
/// * the values against a plain array, because **self-consistency is not
///   correctness** — a slab that duplicated a run is entirely self-consistent,
///   which is upstream's own remark at `:2889-2890`;
/// * the canonical wire form — encode, load, encode — because a column that
///   decodes to the right values is not yet a column whose bytes are the
///   reference's.
fn exhaustiveSplices(
    comptime Col: type,
    initial: []const Col.Value,
    budget: usize,
    domain: []const Col.Value,
    seed: u64,
) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    var new_vals: [100]Col.Value = undefined;
    var model: std.ArrayList(Col.Value) = .empty;
    defer model.deinit(gpa);

    for (splice_shapes) |shape| {
        const del_count = shape[0];
        const ins_count = shape[1];

        // The base, built and validated once per shape: a delete of `n` can
        // stand in front of `len - n` rows, and the last position is one past
        // that. A pure insert deletes nothing, so it has one position more.
        var base = try Col.fromValues(gpa, initial, budget);
        defer base.deinit();
        try validateColumn(Col, &base, "the base column");
        // The premise of the case: a budget of eight over two hundred random
        // values is *many* slabs, or the sweep would be walking one of them
        // and the shape of the base would not be what the case is about.
        // Pinned rather than assumed, because a fixture that quietly stopped
        // cutting would still pass every comparison below it.
        if (base.slabCount() < 4) {
            std.debug.print("a {d}-row column at a budget of {d} is {d} slab(s)\n", .{
                base.len(),
                budget,
                base.slabCount(),
            });
            return error.TestUnexpectedResult;
        }
        try expectColumn(Col, gpa, &base, initial, "the base column");
        const max_pos = if (del_count == 0) base.len() + 1 else base.len() - del_count + 1;

        var pos: usize = 0;
        while (pos < max_pos) : (pos += 1) {
            for (new_vals[0..ins_count]) |*v| {
                v.* = domain[rand.intRangeAtMost(usize, 0, domain.len - 1)];
            }
            // A fresh base per position, validated only after the splice: the
            // column is the one `base` already was, before the splice at all.
            var col = try Col.fromValues(gpa, initial, budget);
            defer col.deinit();

            const del = @min(del_count, col.len() - pos);
            try col.splice(gpa, pos, del, new_vals[0..ins_count]);

            model.clearRetainingCapacity();
            try model.appendSlice(gpa, initial);
            try model.replaceRange(gpa, pos, del, new_vals[0..ins_count]);

            var line: [128]u8 = undefined;
            const where = spliceLine(&line, del_count, ins_count, pos, del);
            try validateColumn(Col, &col, where);
            try expectColumn(Col, gpa, &col, model.items, where);
            try expectCanonical(Col, gpa, &col, model.items, where);
        }
    }
}

// ── The merge policy, after every operation ───────────────────────────────────

test "fuzz_slab_merge_invariant" {
    // **`tests.rs:4056-4086`.** Two hundred trials of five hundred inserts and
    // removes, with the merge policy checked **after every single one of the
    // hundred thousand operations**.
    //
    // **The generator is written out, not drawn**: upstream's `xorshift` from
    // a fixed state of `98765`, with the same three shifts, so the port walks
    // the same sequence and a failure is the same failure. `xorshift` below is
    // that function, and the draws are made in upstream's order — including
    // the one that is *not* made while the column is empty, which is what
    // keeps the two sequences the same sequence.
    //
    // **The values are `xorshift % 20`**, so a few hundred rows carry enough
    // distinct values to fill slabs and then some: the invariant is about
    // undersized neighbours, and it only has teeth once the column is several
    // slabs long.
    //
    // **The array is checked too**, which upstream does not do here: the
    // predicate is about the layout, and a column can satisfy it while
    // holding the wrong rows. One insert and one remove per operation, on the
    // model the positions are drawn against.
    var rng: u64 = 98765;
    for (0..200) |trial| {
        var col = try RleU64.init(gpa);
        defer col.deinit();
        // Upstream's predicate reads `DEFAULT_MAX_SEG` and builds its column
        // with `Column::<u64>::new()`, so the two are the same question only
        // while the column is on the default budget. Said here rather than
        // assumed by `expectSlabMergePolicy`.
        try testing.expectEqual(colmod.default_max_segments, col.maxSegmentsOf());
        var model: std.ArrayList(u64) = .empty;
        defer model.deinit(gpa);

        for (0..500) |op| {
            const len = model.items.len;
            const r = xorshift(&rng);
            if (len == 0 or r % 3 != 0) {
                const pos = if (len == 0) 0 else @as(usize, @intCast(xorshift(&rng))) % (len + 1);
                const val = xorshift(&rng) % 20;
                try col.splice(gpa, pos, 0, &.{val});
                try model.insert(gpa, pos, val);
            } else {
                const pos = @as(usize, @intCast(xorshift(&rng))) % len;
                try col.removeN(gpa, pos, 1);
                _ = model.orderedRemove(pos);
            }
            var line: [96]u8 = undefined;
            const where = trialLine(&line, trial, op);
            try expectSlabMergePolicy(RleU64, &col, where);
            try expectColumn(RleU64, gpa, &col, model.items, where);
        }
    }
}

// ── Copying a range chain, run at a time ─────────────────────────────────────

test "splice_runs_with_ranges" {
    // **`tests.rs:1256-1274`.** Three disjoint windows of a sixty-value column,
    // spliced between `100` and `200` — and the windows arrive through the
    // pipeline upstream names, which is the whole case:
    // `col2.iter().runs().ranges([…])` into `col1.splice_runs(1, 0, …)`.
    //
    // **Through the adapters, not beside them.** Here that is
    // `Column.iterator()`, `.runs()`, `Runs.ranges(windows)` and
    // `Column.spliceRuns`, in that order, and the run list handed to the splice
    // is the one the adapter collected. Writing the three stretches out by
    // hand would produce the same rows and would not touch the chaining that
    // has to carry the remainder of one window into the next.
    //
    // **Runs of seven over sixty rows** (`i / 7`), so a window boundary lands
    // inside a run and the run has to be clipped rather than dropped whole.
    var values: [60]u64 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i / 7);
    const windows = [_]colmod.RowRange{
        .{ .start = 2, .end = 5 },
        .{ .start = 10, .end = 15 },
        .{ .start = 31, .end = 50 },
    };

    var col2 = try RleU64.fromValues(gpa, &values, colmod.default_max_segments);
    defer col2.deinit();
    var col1 = try RleU64.fromValues(gpa, &.{ 100, 200 }, colmod.default_max_segments);
    defer col1.deinit();

    {
        var it = try col2.iterator();
        var run_cursor = it.runs();
        var chain = run_cursor.ranges(&windows);
        const spliced = try chain.collect(gpa);
        defer gpa.free(spliced);
        try col1.spliceRuns(gpa, 1, 0, spliced);
    }

    var want: std.ArrayList(u64) = .empty;
    defer want.deinit(gpa);
    try want.append(gpa, 100);
    for (windows) |w| try want.appendSlice(gpa, values[w.start..w.end]);
    try want.append(gpa, 200);
    try validateColumn(RleU64, &col1, "spliceRuns(ranges)");
    try expectColumn(RleU64, gpa, &col1, want.items, "spliceRuns(ranges)");
    // The spliced rows arrive as runs and are held as runs, and the column
    // that takes them still answers with the values — so a run list is an
    // encoding of the rows, not a second and different column.
    try expectCanonical(RleU64, gpa, &col1, want.items, "spliceRuns(ranges)");
}

test "splice_runs_from_another_columns_iter" {
    // **`tests.rs:1148-1157`.** A three-row column, a six-row one, and the
    // second's **clipped** run list spliced into the first at position one:
    // `col1.splice_runs(1, 0, col2.iter_range(1..5).runs())`.
    //
    // **The clip is the case.** The window opens **one row inside the
    // three-row repeat of `7`s**, so the window's first run is `7 × 2` and not
    // `7 × 3`, and the expected `[1, 7, 7, 8, 9, 2, 3]` is what that clip
    // buys. **The port holds the derivation rather than the answer**: the
    // source is built from `[7,7,7,8,9,9]`, the window is taken off *it*, and
    // the run list the splice consumes is the one `iterRange(..).runs()`
    // collected. A window written out by hand would assert the expected answer
    // instead, and a run cursor that dropped the clipped row — or carried the
    // whole repeat across the edge — would pass it.
    //
    // **Runs, not values.** `Runs.next` yields `(value, count)` and the count
    // is the repeat length, so a run crossing the window's edge is shortened at
    // the edge by `Runs.setMax` against the window, and nothing re-measures the
    // source. That is the difference between `iterRange(1..5)` and an
    // `iterator()` over the whole column, and it is why this is a case of its
    //   own rather than a shape of `splice_runs_with_ranges` above.
    const window = colmod.RowRange{ .start = 1, .end = 5 };
    var col2 = try RleU64.fromValues(gpa, &.{ 7, 7, 7, 8, 9, 9 }, colmod.default_max_segments);
    defer col2.deinit();
    var col1 = try RleU64.fromValues(gpa, &.{ 1, 2, 3 }, colmod.default_max_segments);
    defer col1.deinit();

    {
        var it = try col2.iterRange(window);
        var run_cursor = it.runs();
        var clipped: std.ArrayList(colmod.RunOf(u64)) = .empty;
        defer clipped.deinit(gpa);
        while (try run_cursor.next()) |r| try clipped.append(gpa, r);

        // **The clip, read off the run list itself.** The source holds `7 × 3`;
        // the window may take `7 × 2`, and those differ by exactly one row.
        // Asserting the runs and not just the spliced values says which of the
        // two a failure produced.
        const want_runs = [_]colmod.RunOf(u64){
            .{ .value = 7, .count = 2 },
            .{ .value = 8, .count = 1 },
            .{ .value = 9, .count = 1 },
        };
        try testing.expectEqual(want_runs.len, clipped.items.len);
        for (want_runs, clipped.items) |want, got| {
            try testing.expectEqual(want.value, got.value);
            try testing.expectEqual(want.count, got.count);
        }
        // Four rows out of a four-row window, counted off the runs rather than
        // off the column the splice has not touched yet.
        try testing.expectEqual(window.end - window.start, clipped.items[0].count + clipped.items[1].count + clipped.items[2].count);
        // The source is untouched by taking a window off it: its own run list
        // still opens on the three-row repeat the window clipped, which is the
        // difference between `7 × 3` here and `7 × 2` there.
        var whole = try col2.iterator();
        var whole_runs = whole.runs();
        const first_run = (try whole_runs.next()).?;
        if (first_run.value != 7 or first_run.count != 3) {
            std.debug.print("the source opens on {any}, a three-row repeat of 7 is what it holds\n", .{first_run});
            return error.TestExpectedEqual;
        }

        try col1.spliceRuns(gpa, 1, 0, clipped.items);
    }

    try validateColumn(RleU64, &col1, "spliceRuns(iterRange(1..5).runs())");
    try expectColumn(RleU64, gpa, &col1, &.{ 1, 7, 7, 8, 9, 2, 3 }, "spliceRuns(iterRange(1..5).runs())");
    // A run list is an encoding of the rows and not a second kind of column:
    // the column that takes it answers with the values and re-encodes to the
    // same bytes after a load.
    try expectCanonical(RleU64, gpa, &col1, &.{ 1, 7, 7, 8, 9, 2, 3 }, "spliceRuns(iterRange(1..5).runs())");
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
/// the port holds through [`expectCanonical`] here and through the codec round
/// trips in `test/golden/codec.jsonl`; what is left here is the contents.
/// **The element loop and not a length**, because a column whose values came
/// back permuted has the right length, and a splice that re-anchored a delta
/// against the wrong row is that shape.
///
/// `context` is the case's own coordinates. A sweep runs thousands of these
/// comparisons, and a report that cannot say which one failed is a report that
/// has to be re-run to become useful.
fn expectColumn(
    comptime Col: type,
    a: Allocator,
    col: *const Col,
    want: []const Col.Value,
    context: []const u8,
) !void {
    if (col.len() != want.len) {
        std.debug.print("{s}: the column holds {d} value(s), the model {d}\n", .{ context, col.len(), want.len });
        return error.TestExpectedEqual;
    }
    const got = try col.toSlice(a);
    defer a.free(got);
    if (got.len != want.len) {
        std.debug.print("{s}: the column decodes to {d} value(s), the model {d}\n", .{ context, got.len, want.len });
        return error.TestExpectedEqual;
    }
    for (got, 0..) |v, i| {
        if (v != want[i]) {
            std.debug.print("{s}: value {d} is {any}, the model says {any}\n", .{ context, i, v, want[i] });
            return error.TestExpectedEqual;
        }
    }
}

/// A column's wire form, loaded back into a fresh column: the same values, and
/// the same bytes again — **canonical**, which is upstream's `save()` being
/// handed to `Column::load` and compared byte for byte in the cases that pin
/// it (`tests.rs:1251`).
///
/// A load cuts its slabs at half the budget, so the second encode holding the
/// first encode's bytes is also that **the cut is invisible in the wire form**:
/// two columns that hold the same rows and encode differently are not the same
/// column, whatever their values say.
fn expectCanonical(
    comptime Col: type,
    a: Allocator,
    col: *const Col,
    want: []const Col.Value,
    context: []const u8,
) !void {
    const bytes = col.encode(a) catch |err| {
        std.debug.print("{s}: encode refused canonical output: {s}\n", .{ context, @errorName(err) });
        return err;
    };
    defer a.free(bytes);
    var back = try Col.load(a, bytes);
    defer back.deinit();
    try expectColumn(Col, a, &back, want, context);
    const again = try back.encode(a);
    defer a.free(again);
    if (!std.mem.eql(u8, bytes, again)) {
        std.debug.print("{s}: the wire form is not canonical — {d} byte(s) in, {d} byte(s) out\n", .{
            context,
            bytes.len,
            again.len,
        });
        return error.TestExpectedEqual;
    }
}

/// Upstream's `validate_column`, `validate_rle_column` and
/// `validate_bool_column` ([`tests.rs`:2800-2851](../github-automerge-automerge/rust/hexane/src/tests.rs)),
/// as one check: every slab inside the budget, each slab's cached length, run
/// count and tail agreeing with a fresh measure of its own bytes, the column
/// length the sum of its slabs, and the index in step with the slab list.
///
/// **One check for upstream's three arms.** Its RLE arm adds the tail
/// comparison on top of the shared arm, and its boolean arm is the shared arm;
/// `checkInvariants` re-measures every slab and compares the tail as part of
/// it, so the port's single check is the stricter of the two and answers for
/// both codecs.
///
/// **The merge policy is not in here.** Upstream keeps it out of
/// `validate_column` too — it is a separate assertion over the slab list, and
/// it is [`expectSlabMergePolicy`] below.
fn validateColumn(comptime Col: type, col: *const Col, context: []const u8) !void {
    if (try col.checkInvariants()) |v| {
        if (v.detail_len != 0) {
            std.debug.print("{s}: {s}: {s} ({s}, at {d})\n", .{ context, @typeName(Col), v.what, v.detail(), v.at });
        } else {
            std.debug.print("{s}: {s}: {s} (at {d})\n", .{ context, @typeName(Col), v.what, v.at });
        }
        return error.TestUnexpectedResult;
    }
}

/// Upstream's `check_slab_merge_invariant`
/// ([`tests.rs`:4022-4054](../github-automerge-automerge/rust/hexane/src/tests.rs)):
/// **no slab under a quarter of the budget may sit beside a neighbour the pair
/// would still fit inside** — checked on *both* sides of every such slab, and
/// the report names which side.
///
/// **The budget is the constant, not the column's own.** Upstream reads
/// `DEFAULT_MAX_SEG` and the case builds its column with the default budget,
/// so a column under some other budget is not this predicate's business; the
/// port reads [`colmod.default_max_segments`] and says so. `Column.mergeableNeighbours`
/// states the same rule over the column's own budget — the two are one
/// predicate with one knob between them, and which knob is in force is what
/// upstream's constant records.
fn expectSlabMergePolicy(comptime Col: type, col: *const Col, context: []const u8) !void {
    const segs = try col.slabSegments(gpa);
    defer gpa.free(segs);
    const max_runs = colmod.default_max_segments;
    const min_runs = max_runs / 4;
    for (segs, 0..) |n, i| {
        if (n >= min_runs) continue;
        if (i > 0 and n + segs[i - 1] <= max_runs) {
            std.debug.print("{s}: slab[{d}] holds {d} run(s) and its left neighbour {d} — mergeable ({d} + {d} = {d} <= {d}) but not merged\n", .{
                context,
                i,
                n,
                segs[i - 1],
                n,
                segs[i - 1],
                n + segs[i - 1],
                max_runs,
            });
            return error.TestUnexpectedResult;
        }
        if (i + 1 < segs.len and n + segs[i + 1] <= max_runs) {
            std.debug.print("{s}: slab[{d}] holds {d} run(s) and its right neighbour {d} — mergeable ({d} + {d} = {d} <= {d}) but not merged\n", .{
                context,
                i,
                n,
                segs[i + 1],
                n,
                segs[i + 1],
                n + segs[i + 1],
                max_runs,
            });
            return error.TestUnexpectedResult;
        }
    }
}

/// Upstream's `xorshift` ([`tests.rs`:4090-4095](../github-automerge-automerge/rust/hexane/src/tests.rs)),
/// which `fuzz_slab_merge_invariant` inlines as a closure over the same three
/// shifts. **The generator is written out because the case is about it**: the
/// seed is in the test, the sequence is this function's, and a failure is
/// re-runnable without a seed file.
fn xorshift(state: *u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return state.*;
}

/// The coordinates of one splice, in the words upstream's assertion messages
/// use them (`tests.rs:2896`, `:2959`): the shape and the position are what
/// make a failure re-runnable, so they are what the report carries.
fn spliceLine(buf: []u8, del_count: usize, ins_count: usize, pos: usize, del: usize) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "del_count={d} ins_count={d} pos={d} del={d}",
        .{ del_count, ins_count, pos, del },
    ) catch "unprintable coordinates";
}

/// The coordinates of one operation of the merge-policy sweep
/// (`tests.rs:4083`), in the words its own assertion message uses.
fn trialLine(buf: []u8, trial: usize, op: usize) []const u8 {
    return std.fmt.bufPrint(buf, "trial={d} op={d}", .{ trial, op }) catch "unprintable coordinates";
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **The bulk of the named transcription of `rust/hexane/src/tests.rs` is in
//   `src/hexane/column.zig`**, in the block headed `Upstream
//   `hexane/src/tests.rs`, ported case for case`. **This file holds the one
//   property upstream has no name for** — the run budget — **and the cases
//   whose fixture or input sweep is the case**, named above:
//
//   | upstream | here | what this file adds |
//   |---|---|---|
//   | `fuzz_bool_splice_exhaustive` (`:2853-2907`) | same name | every position, at a budget of eight, on a fresh base |
//   | `fuzz_option_u64_splice_exhaustive` (`:2909-2965`) | same name | the same, over upstream's five nullable choices |
//   | `fuzz_slab_merge_invariant` (`:4056-4086`) | same name | 200 × 500 operations, the predicate after each one, written out |
//   | `splice_runs_with_ranges` (`:1256-1274`) | same name | `runs().ranges()` into `Column.spliceRuns`, not a hand-built window list |
//   | `splice_runs_from_another_columns_iter` (`:1148-1157`) | same name | the clip, out of `iterRange(1..5).runs()`, not a written-out window |
//   | `fuzz_splice_ops` (`:818-838`) | same name | 500 drawn cases of splice ops, the model checked after every operation |
//   | `fuzz_sequential_splice_uint` (`:840-864`) | same name | 500 drawn cases of a monotone insert walk and a fixed-position remove run |
//
// * **`rand::rng()` is pinned here.** Upstream's two exhaustive cases draw
//   their generator, so this file draws from a fixed seed and keeps upstream's
//   sampling domain: one bit a row for the boolean column, and `None`, `1`,
//   `2`, `3`, `4` for the nullable one. **A random case is not a reproducible
//   case**, and upstream has no `proptest-regressions` file to make one.
//
// * **The merge rule is stated twice upstream, and the two statements differ
//   in one knob.** The production rule is `canMerge` (`column.rs:1782-1797`)
//   and the test-side restatement is `check_slab_merge_invariant`
//   (`tests.rs:4022-4054`); the port's are `Column.mergeableNeighbours` and
//   [`expectSlabMergePolicy`]. **Upstream's test reads `DEFAULT_MAX_SEG` while
//   upstream's production rule reads the column's budget**, and the case is
//   built at the default, so over this sweep the two are the same question.
//   `fuzz_slab_merge_invariant` asserts the budget out loud rather than
//   leaving that equivalence to the reader.
//
// * **`Shiftable::ranges` is `colmod.Ranges(I)` over any cursor with `pos`,
//   `setMax` and `shift`** ([`column.zig`](column.zig)), and `Column.iterator`,
//   `.runs()` and `.ranges(windows)` are the three adapters upstream's
//   `iter().runs().ranges([…])` names. `splice_runs_with_ranges` runs that
//   chain into `Column.spliceRuns`; **a window list concatenated by hand would
//   produce the same rows and would not test the chaining.**
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
// * **`proptest` is not a dependency, and its generator is replaced by pinned
//   seeds rather than by dropping the cases.** `fuzz_splice_ops` and
//   `fuzz_sequential_splice_uint` keep their upstream names, their upstream
//   draw ranges (a case is `1..=19` operations, each a position out of
//   `0..=999`, a delete out of `0..=9` and up to four nullable values; or
//   `1..=79` values at a start out of `0..=49`) and upstream's
//   `with_cases(500)`. **What is pinned is the generator behind them and
//   nothing else** — a case is drawn from its own number, so a failure is
//   re-runnable from the line that failed. **The model is compared after every
//   operation**, not only at the points upstream calls `assert_col`: a
//   randomised case that only checks its final state is a case that can pass
//   through a hundred wrong intermediate states, which is the whole of what a
//   splice bug looks like.
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
