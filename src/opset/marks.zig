//! The two mark adapters: a query that hides its mark rows and reports the
//! mark set as it goes, and a query that hides them and reports nothing
//! (`rust/automerge/src/op_set2/op_set/marks.rs`, 88 lines).
//!
//! # What the two are for, and why they are two types
//!
//! A mark is two operations back to back, both with `action = Mark`
//! (`src/marks.zig:57-84`), and neither is a value a reader of a sequence
//! ever wants to see: the begin carries the mark's name and value, the end
//! carries neither, and between them they say *where a mark starts and stops*
//! rather than *what is at this position*. A reader that wants the text has
//! to step over both.
//!
//! What it wants **instead** differs, and that is the whole of this file.
//! [`MarkIter`] steps over the mark rows and keeps folding them into a
//! [`MarkSet`](../../src/marks.zig) as it goes, so `getMarks` answers "what
//! is marked here" for free at the row the walk is standing on
//! (`marks.rs:45-53`). [`NoMarkIter`] steps over the same rows and answers
//! `null` (`marks.rs:80-88`), which is right for a reader that has been handed
//! the mark set some other way: [`insert.zig`](insert.zig)'s `InsertQuery`
//! collects the marks itself and then walks a query that must not fold them a
//! second time.
//!
//! # The fold is only as long as the walk
//!
//! `MarkIter` reports the marks that are open *in the rows it has passed*.
//! A walk that starts after a mark's begin never sees that begin, so it
//! reports no mark on the row the begin would have covered — which is
//! correct for a reader walking an object from its start, and wrong for one
//! that wants the marks at an arbitrary position. `mark_index.richTextAt` is
//! the one for that (`mark_index.zig:296-313`, the index being a prefix
//! column precisely so that a position can be asked about without walking to
//! it), and upstream has exactly the same split: `MarkIter`'s fold is
//! `MarkStateMachine::default` fed row by row (`marks.rs:17-19`, `:29-37`),
//! while `OpSet::calculate_marks_fast` asks the column (`op_set2/op_set.rs:557`).
//! The test "a query over a sub-range and one over the object agree where they
//! overlap" holds both halves of this: the same row, the same value, and the
//! marks present or absent according to the range and nothing else.
//!
//! Upstream writes them as two `struct`s over any
//! `Iterator<Item = Op> + Clone`. The port keeps two types over any
//! [`Shiftable`](../../src/hexane/column.zig) query term and drops the
//! `Clone` bound: nothing in either type copies the inner walk, so the bound
//! buys nothing here, and a walk in this port is not cheaply copyable — the
//! sub-iterators hold decoder state.
//!
//! # Neither adapter changes the rows
//!
//! Given the same inner query, `MarkIter` and `NoMarkIter` yield **exactly**
//! the same rows, in the same order, with the same values. They differ only in
//! what `getMarks` knows at each of them. Upstream's two `next` bodies are the
//! same loop with the fold in one of them (`marks.rs:26-42` against
//! `marks.rs:69-77`), so the port states it as a test rather than as a
//! comment.
//!
//! # A clock is not consulted
//!
//! Neither adapter filters by visibility. Upstream's `MarkIter` folds every
//! mark row the inner walk yields and applies no clock (`marks.rs:26-42`), and
//! `NoMarkIter` drops every one it sees (`marks.rs:69-77`), so both belong
//! *under* a clock-filtering query rather than on top of one.
//! [`insert.zig`](insert.zig) does consult one, because `InsertQuery` is the
//! one op-set reader that must see invisible rows as well as visible ones
//! (`insert.rs:89-90`).
//!
//! # `next` cannot answer "nothing here"
//!
//! A `next` that answered `null` both for "this row carries no mark" and for
//! "the walk is over" would be unusable by a row-at-a-time reader — the trap
//! `mark_index.zig:488-511` documents for the mark index's own cursor. These
//! two cannot fall into it: the only rows they return are non-mark rows, and a
//! mark row is stepped over, so a `null` is always the end of the walk. The
//! accessor that *distinguishes* a row from the end is `shiftNext`, which
//! answers `error.InvalidValue` for a backward range rather than a bare `null`
//! (`op_iter.zig:1655-1663`).
//!
//! # Constructing one allocates nothing
//!
//! [`MarkIter`] owns a [`MarkStateMachine`](../../src/marks.zig), which holds
//! an empty `ArrayList` and an empty `MarkSet` until a mark row arrives
//! (`src/marks.zig:484-517`), and [`MarkIter.deinit`] frees it. A long
//! document's mark buffer is the fold's rather than the caller's.
//! [`NoMarkIter`] owns only the walk it was handed and nothing else, so **it
//! declares no `deinit` at all** and the teardown a caller writes for it is
//! the inner walk's own. The pair is not interchangeable there: the uniform
//! `defer x.deinit()` it invites compiles for one of the two only.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const column = @import("../hexane/column.zig");
const marksmod = @import("../marks.zig");
const opmod = @import("op.zig");
const opcols = @import("columns.zig");
const opiter = @import("op_iter.zig");
const oquery = @import("op_query.zig");

const Allocator = std.mem.Allocator;
const ElemId = types.ElemId;
const Error = err.Error;
const MarkSet = marksmod.MarkSet;
const MarkStateMachine = marksmod.MarkStateMachine;
const ObjId = types.ExId;
const Op = opmod.Op;
const OpBuilder = opmod.OpBuilder;
const ParseError = err.ParseError;
const ReadOpError = opiter.ReadOpError;
const RowRange = column.RowRange;
const StringTable = opcols.StringTable;
const SuccEntry = opmod.SuccEntry;

const testing = std.testing;

/// Everything either adapter can raise, named here so a reader of this file
/// does not have to reach into `op_query.zig` for it.
///
/// The fold allocates (`src/marks.zig:543-602`, whose `put` and
/// `state.insert` are the two allocation sites) and the walk reads columns
/// (`op_iter.zig:1674-1692`), so this is the document `Error` over the column
/// layer's `ReadOpError`. It is the query term's error set, declared with the
/// contract rather than here, because `op_query.zig`'s `assertQueryTerm` is
/// what requires a `next` to answer it.
pub const MarkError = oquery.QueryError;

/// A query that hides its mark rows and reports the mark set as it goes
/// (`MarkIter`, `op_set2/op_set/marks.rs:10-43`).
///
/// The set it reports is the [`MarkStateMachine`](../../src/marks.zig)'s, not
/// `mark_index.richTextAt`'s: this folds the rows the walk *passes*, so it is
/// right for a reader that wants the marks at each row as it arrives, and wrong
/// for one that wants the marks at an arbitrary position without walking there.
pub fn MarkIter(comptime I: type) type {
    return struct {
        const Self = @This();

        /// The allocator the fold's buffers belong to. It is named here so
        /// [`deinit`] can be called with nothing.
        gpa: Allocator,
        /// The query being wrapped.
        iter: I,
        /// The marks that are open at the current position.
        marks: MarkStateMachine,

        pub const shiftable = column.Shiftable(Self);

        /// A query over `iter` that folds the mark rows it steps over
        /// (`MarkIter::new`, `marks.rs:17-21`).
        ///
        /// Allocates nothing: the fold is an empty open set and an empty
        /// resolved set, and both are a null capacity
        /// (`src/marks.zig:484-517`).
        pub fn init(gpa: Allocator, iter: I) Self {
            return .{ .gpa = gpa, .iter = iter, .marks = MarkStateMachine.init(gpa) };
        }

        /// Frees the fold's buffers and nothing else: the walk is the
        /// caller's, and its own storage is freed by the caller's own
        /// `deinit`.
        ///
        /// Once only. The free poisons the receiver, so a second call reads
        /// undefined storage, and two copies of a walk that has folded rows
        /// share one fold.
        pub fn deinit(self: *Self) void {
            self.marks.deinit();
            self.gpa = undefined;
            self.* = undefined;
        }

        /// The next non-mark row, with every mark row before it folded in, or
        /// null at the end of the walk (`next`, `marks.rs:26-42`).
        ///
        /// A mark row with a name is a **begin** and opens the mark; a mark
        /// row without one is an **end** and closes the mark its `id.prev()`
        /// opened (`marks.rs:32-36`). Which is which is decided by the name
        /// column alone (`op_set2/types.rs:177-186`, ported as
        /// `value.opTypeFromActionAndValue`), so neither arm looks at the
        /// action's other halves.
        pub fn next(self: *Self) MarkError!?Op {
            while (true) {
                const row = (try self.iter.next()) orelse return null;
                if (row.action() != .mark) return row;
                if (row.markName()) |name| {
                    _ = try self.marks.markBegin(row.id(), .{
                        .name = name,
                        .value = row.value(),
                    });
                } else {
                    _ = try self.marks.markEnd(row.id());
                }
            }
        }

        /// The marks open at the row the walk is standing on, or null when
        /// nothing is marked here (`OpQueryTerm::get_marks`, `marks.rs:46-48`).
        ///
        /// The set is borrowed and is invalidated by the next `next`, because
        /// that is when the fold writes it.
        pub fn getMarks(self: *const Self) ?*const MarkSet {
            return self.marks.current();
        }

        /// The rows still to be walked (`OpQueryTerm::range`, `marks.rs:50-52`).
        pub fn range(self: *const Self) RowRange {
            return self.iter.range();
        }

        /// The row the next `next` returns (the `Shiftable` kernel's read-only
        /// accessor, `column.zig:4000`).
        pub fn pos(self: *const Self) usize {
            return self.iter.pos();
        }

        /// One past the last row this walk can yield (`column.zig:4001`).
        pub fn maxPos(self: *const Self) usize {
            return self.iter.maxPos();
        }

        /// Truncates the walk at `at` (`OpIter.setMax`).
        pub fn setMax(self: *Self, at: usize) void {
            self.iter.setMax(at);
        }

        /// Advances so the next `next` is the row at `target`
        /// (`OpIter.advanceTo`).
        pub fn advanceTo(self: *Self, target: usize) ParseError!void {
            return self.iter.advanceTo(target);
        }

        /// Advances past `amount` rows (`OpIter.advanceBy`).
        pub fn advanceBy(self: *Self, amount: usize) ParseError!void {
            return self.iter.advanceBy(amount);
        }

        /// Moves the walk's window to `rows` — the window only, not the
        /// position (`OpIter.shift`).
        /// A parse refusal leaves the underlying cursor and window unchanged.
        pub fn shift(self: *Self, rows: RowRange) ParseError!void {
            return self.iter.shift(rows);
        }

        /// Repositions the walk onto `rows` and reads the row at its start
        /// (`OpIter.shiftNext`). `error.InvalidValue` when `rows` starts behind
        /// the walk, which is how this adapter keeps "no row there" distinct
        /// from "you asked for the wrong direction".
        pub fn shiftNext(self: *Self, rows: RowRange) MarkError!?Op {
            return self.iter.shiftNext(rows);
        }

        /// Consumes through `at` and reads the row there, or null when `at` is
        /// behind the walk (`OpIter.seekTo`).
        pub fn seekTo(self: *Self, at: usize) MarkError!?Op {
            return self.iter.seekTo(at);
        }
    };
}

// ── NoMarkIter ─────────────────────────────────────────────────────────────

/// A query that hides its mark rows and reports nothing about marks
/// (`NoMarkIter`, `op_set2/op_set/marks.rs:55-88`).
///
/// The same rows as [`MarkIter`], and `getMarks` is null for every one of them
/// (`marks.rs:81-83`).
///
/// **It owns nothing, so it declares no `deinit`.** It holds the walk it was
/// handed and nothing else, and there is no fold here to free. [`MarkIter`] is
/// the adapter in this pair that has a `deinit` of its own, because the fold
/// is what it owns, and a caller composing the two writes one teardown for the
/// pair and it is the inner walk's.
pub fn NoMarkIter(comptime I: type) type {
    return struct {
        const Self = @This();

        /// The query being wrapped.
        iter: I,

        pub const shiftable = column.Shiftable(Self);

        /// A query over `iter` that drops the mark rows (`NoMarkIter::new`,
        /// `marks.rs:61-64`). Allocates nothing: the type *is* the walk.
        pub fn init(iter: I) Self {
            return .{ .iter = iter };
        }

        /// The next non-mark row, or null at the end of the walk (`next`,
        /// `marks.rs:69-77`).
        pub fn next(self: *Self) ReadOpError!?Op {
            while (true) {
                const row = (try self.iter.next()) orelse return null;
                if (row.action() == .mark) continue;
                return row;
            }
        }

        /// Always null: this adapter knows nothing about marks
        /// (`OpQueryTerm::get_marks`, `marks.rs:81-83`).
        pub fn getMarks(self: *const Self) ?*const MarkSet {
            _ = self;
            return null;
        }

        /// The rows still to be walked (`OpQueryTerm::range`, `marks.rs:85-87`).
        pub fn range(self: *const Self) RowRange {
            return self.iter.range();
        }

        /// The row the next `next` returns (`column.zig:4000`).
        pub fn pos(self: *const Self) usize {
            return self.iter.pos();
        }

        /// One past the last row this walk can yield (`column.zig:4001`).
        pub fn maxPos(self: *const Self) usize {
            return self.iter.maxPos();
        }

        /// Truncates the walk at `at` (`OpIter.setMax`).
        pub fn setMax(self: *Self, at: usize) void {
            self.iter.setMax(at);
        }

        /// Advances so the next `next` is the row at `target`
        /// (`OpIter.advanceTo`).
        pub fn advanceTo(self: *Self, target: usize) ParseError!void {
            return self.iter.advanceTo(target);
        }

        /// Advances past `amount` rows (`OpIter.advanceBy`).
        pub fn advanceBy(self: *Self, amount: usize) ParseError!void {
            return self.iter.advanceBy(amount);
        }

        /// Moves the walk's window to `rows` — the window only, not the
        /// position (`OpIter.shift`).
        /// A parse refusal leaves the underlying cursor and window unchanged.
        pub fn shift(self: *Self, rows: RowRange) ParseError!void {
            return self.iter.shift(rows);
        }

        /// Repositions the walk onto `rows` and reads the row at its start
        /// (`OpIter.shiftNext`).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadOpError!?Op {
            return self.iter.shiftNext(rows);
        }

        /// Consumes through `at` and reads the row there, or null when `at` is
        /// behind the walk (`OpIter.seekTo`).
        pub fn seekTo(self: *Self, at: usize) ReadOpError!?Op {
            return self.iter.seekTo(at);
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

/// The text object the tests walk: `"ab"` with a mark named `bold` over the
/// `"b"`, in the row order `Op.step` accepts.
///
/// The mark's two operations carry ids 4 and 5 and sit on rows 2 and 4, which
/// is the pairing rule `src/marks.zig:93-107` states: a mark is two back-to-
/// back inserts, the end's id is the begin's plus one in the same actor, and
/// the end sorts strictly after the begin. `expand` is the only thing `init`
/// varies, and it is the one column the sticky-mark rule reads.
const text_obj: ObjId = .{ .id = .{ .counter = 1, .actor = 0 } };

fn textRows(gpa: Allocator, expand: bool) !std.ArrayList(OpBuilder) {
    var ops: std.ArrayList(OpBuilder) = .empty;
    errdefer {
        for (ops.items) |*o| o.deinit(gpa);
        ops.deinit(gpa);
    }
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 1, .actor = 0 }, .root, .make_text, .fromStr("t"), .null_value, false, false, null, &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 2, .actor = 0 }, text_obj, .set, .fromElemId(ElemId.head()), .{ .str = "a" }, true, false, null, &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 4, .actor = 0 }, text_obj, .mark, .fromElemId(ElemId.fromOpId(.{ .counter = 2, .actor = 0 })), .{ .bool_value = true }, true, expand, "bold", &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 3, .actor = 0 }, text_obj, .set, .fromElemId(ElemId.fromOpId(.{ .counter = 2, .actor = 0 })), .{ .str = "b" }, true, false, null, &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 5, .actor = 0 }, text_obj, .mark, .fromElemId(ElemId.fromOpId(.{ .counter = 3, .actor = 0 })), .null_value, true, expand, null, &.{}));
    return ops;
}

/// A string table for the tests: the strings it has been given, in the order
/// they were first asked for, which is what makes an interned id stable.
const Table = struct {
    gpa: Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn init(gpa: Allocator) Table {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Table) void {
        for (self.items.items) |item| self.gpa.free(item);
        self.items.deinit(self.gpa);
    }

    fn asTable(self: *Table) StringTable {
        return .{ .ctx = self, .resolve = resolve, .intern = intern };
    }

    fn resolve(ctx: *const anyopaque, id: u32) []const u8 {
        const self: *const Table = @ptrCast(@alignCast(ctx));
        return self.items.items[id];
    }

    fn intern(ctx: *const anyopaque, text: []const u8, gpa: Allocator) ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(@constCast(ctx)));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, text)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, text));
        return id;
    }
};

/// A spliced op set plus the table its strings are interned in and a
/// successor buffer sized for it. The `Op`s a walk of it produces borrow all
/// three, so the fixture outlives every one of them.
const Fixture = struct {
    gpa: Allocator,
    cols: opcols.Columns(OpBuilder),
    table: Table,
    succ: []SuccEntry,
    rows: usize,

    fn init(gpa: Allocator, expand: bool) !Fixture {
        var table = Table.init(gpa);
        errdefer table.deinit();
        var cols = try opcols.Columns(OpBuilder).init(gpa);
        errdefer cols.deinit();
        var ops = try textRows(gpa, expand);
        defer {
            for (ops.items) |*o| o.deinit(gpa);
            ops.deinit(gpa);
        }
        const written = try cols.splice(gpa, 0, ops.items, .unicode_code_point, table.asTable());
        return .{
            .gpa = gpa,
            .cols = cols,
            .table = table,
            .succ = try gpa.alloc(SuccEntry, try opiter.maxSuccCount(OpBuilder, &cols, .{ .start = 0, .end = written })),
            .rows = written,
        };
    }

    fn deinit(self: *Fixture) void {
        self.gpa.free(self.succ);
        self.table.deinit();
        self.cols.deinit();
        self.* = undefined;
    }

    /// A walk over rows `from..to` of the op set. The tests use the object's
    /// own range, `1..rows`, and sub-ranges of it, so this is the one place
    /// the ranges are spelled.
    fn walk(self: *Fixture, from: usize, to: usize) ParseError!opiter.OpIter(OpBuilder) {
        return opiter.OpIter(OpBuilder).init(
            &self.cols,
            self.table.asTable(),
            .{ .start = from, .end = to },
            self.succ,
        );
    }
};

/// An allocator that counts what goes through it, so a test can assert that
/// constructing something asked for nothing. The same shape
/// `op_iter.zig:1979-2026` uses, and the same reason: a counting allocator
/// cannot tell a constructor that allocated from one that did not by any other
/// means, because both return a perfectly usable value.
const Counting = struct {
    inner: Allocator,
    count: usize = 0,

    fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, ra: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.inner.rawAlloc(len, ra, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        ra: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, ra, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, ra: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, ra, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        ra: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, ra, new_len, ret_addr);
    }
};

/// How many rows a walk of the whole object yields. Four rows in, two out: the
/// mark's begin and end are never returned by either adapter.
const yielded = 2;

test "the two adapters yield the same rows and differ only in what they know" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    var with = MarkIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(1, fix.rows));
    defer with.deinit();
    var without = NoMarkIter(opiter.OpIter(OpBuilder)).init(try fix.walk(1, fix.rows));

    var seen: usize = 0;
    while (try with.next()) |a| {
        const b = (try without.next()).?;
        // The rows themselves: same id, same position, same action, same value.
        // If either adapter dropped, reordered or rewrote a row, one of these
        // four would disagree, and there is nothing else it could break.
        try testing.expectEqual(a.id(), b.id());
        try testing.expectEqual(a.pos, b.pos);
        try testing.expectEqual(a.action(), b.action());
        try testing.expect(a.value().eql(b.value()));
        seen += 1;
    }
    try testing.expectEqual(@as(usize, yielded), seen);
    // And neither has more: both walks are spent at the same time.
    try testing.expect((try without.next()) == null);
    try testing.expectEqual(fix.rows, with.pos());
    try testing.expectEqual(fix.rows, without.pos());
}

test "MarkIter reports the marks at each row and NoMarkIter reports none" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // The mark spans the `"b"`, so the first value row is outside it and the
    // second is inside. That difference is the only thing the fold buys
    // (`marks.rs:26-42`).
    var with = MarkIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(1, fix.rows));
    defer with.deinit();
    var without = NoMarkIter(opiter.OpIter(OpBuilder)).init(try fix.walk(1, fix.rows));

    const first = (try with.next()).?;
    try testing.expectEqualStrings("a", first.asStr());
    try testing.expectEqual(@as(usize, 1), first.pos);
    try testing.expectEqual(@as(?*const MarkSet, null), with.getMarks());
    _ = try without.next();

    const second = (try with.next()).?;
    try testing.expectEqualStrings("b", second.asStr());
    const set = with.getMarks().?;
    try testing.expectEqual(@as(usize, 1), set.numMarks());
    var it = set.iter();
    const entry = it.next().?;
    try testing.expectEqualStrings("bold", entry.name);
    try testing.expect(entry.value.eql(.{ .bool_value = true }));
    // The same row, seen by the adapter that folds nothing: no marks, and not
    // an empty set either — a null, which is what the type says.
    _ = try without.next();
    try testing.expectEqual(@as(?*const MarkSet, null), without.getMarks());

    // The mark ends on the last row of the object, so nothing is open past
    // the last value row: the name leaves the set rather than lingering
    // (`src/marks.zig:577-602`).
    try testing.expect((try with.next()) == null);
    try testing.expectEqual(@as(?*const MarkSet, null), with.getMarks());
}

test "the fold reads the name column, not the expand flag" {
    const gpa = testing.allocator;
    // The same rows with `expand` off. The mark is still a mark and still
    // opens and closes at the same rows: `expand` is a column the sticky-mark
    // rule reads, and nothing in either adapter's `next` does.
    var off = try Fixture.init(gpa, false);
    defer off.deinit();
    var on = try Fixture.init(gpa, true);
    defer on.deinit();

    var a = MarkIter(opiter.OpIter(OpBuilder)).init(gpa, try off.walk(1, off.rows));
    defer a.deinit();
    var b = MarkIter(opiter.OpIter(OpBuilder)).init(gpa, try on.walk(1, on.rows));
    defer b.deinit();

    while (try a.next()) |row_a| {
        const row_b = (try b.next()).?;
        try testing.expectEqual(row_a.id(), row_b.id());
        const set_a = a.getMarks();
        const set_b = b.getMarks();
        try testing.expectEqual(set_a == null, set_b == null);
        if (set_a) |sa| {
            try testing.expectEqual(sa.numMarks(), set_b.?.numMarks());
            var ia = sa.iter();
            const ia_entry = ia.next().?;
            var ib = set_b.?.iter();
            const ib_entry = ib.next().?;
            try testing.expectEqualStrings(ia_entry.name, ib_entry.name);
        }
    }
    try testing.expect((try b.next()) == null);
}

test "an empty op set is an empty query and the end is the only null" {
    const gpa = testing.allocator;
    var cols = try opcols.Columns(OpBuilder).init(gpa);
    defer cols.deinit();
    var table = Table.init(gpa);
    defer table.deinit();
    const succ = try gpa.alloc(SuccEntry, 0);
    defer gpa.free(succ);

    // No rows at all, so the range clamps to nothing (`iterRange` clamps both
    // ends). Neither adapter invents a row, and neither claims a mark is open.
    const walk = try opiter.OpIter(OpBuilder).init(&cols, table.asTable(), .{
        .start = 0,
        .end = 0,
    }, succ);
    var with = MarkIter(opiter.OpIter(OpBuilder)).init(gpa, walk);
    defer with.deinit();
    var without = NoMarkIter(opiter.OpIter(OpBuilder)).init(try opiter.OpIter(OpBuilder).init(&cols, table.asTable(), .{
        .start = 0,
        .end = 0,
    }, succ));

    try testing.expect((try with.next()) == null);
    try testing.expect((try without.next()) == null);
    try testing.expectEqual(@as(?*const MarkSet, null), with.getMarks());
    try testing.expectEqual(@as(?*const MarkSet, null), without.getMarks());
    try testing.expectEqual(@as(usize, 0), with.pos());
    try testing.expectEqual(@as(usize, 0), with.maxPos());
    try testing.expectEqual(@as(usize, 0), with.range().start);
    try testing.expectEqual(@as(usize, 0), with.range().end);
}

test "a query over a sub-range and one over the object agree where they overlap" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // Both flavours are the same generic type at two ranges, so a caller can
    // hold either: the property that matters is that the overlapping rows are
    // the same rows, not what the interface is called.
    const With = MarkIter(opiter.OpIter(OpBuilder));
    const Without = NoMarkIter(opiter.OpIter(OpBuilder));

    // The whole object, with the fold.
    var all = With.init(gpa, try fix.walk(1, fix.rows));
    defer all.deinit();
    var all_rows: [yielded]Op = undefined;
    var n: usize = 0;
    while (try all.next()) |row| : (n += 1) all_rows[n] = row;
    try testing.expectEqual(@as(usize, yielded), n);

    // A range that begins and ends on a mark row: row 2 is the mark's begin
    // and row 3 is the text it marks, so this range holds one of each. The
    // mark-aware adapter folds the begin and reports the marked row with the
    // mark open; the other drops the begin and reports the same row with
    // nothing. Same row, different knowledge — the file's whole claim.
    var narrow_marks = With.init(gpa, try fix.walk(2, 4));
    defer narrow_marks.deinit();
    const only = (try narrow_marks.next()).?;
    try testing.expectEqualStrings("b", only.asStr());
    try testing.expectEqual(@as(usize, 1), narrow_marks.getMarks().?.numMarks());
    try testing.expect((try narrow_marks.next()) == null);

    // A range that ends before the marked row, so its only row is the mark's
    // own begin and neither adapter has a value to report. The range is not
    // empty; the *result* is, and that is the distinction worth pinning.
    var narrow = Without.init(try fix.walk(2, 3));
    try testing.expect((try narrow.next()) == null);
    var narrow_folding = With.init(gpa, try fix.walk(2, 3));
    defer narrow_folding.deinit();
    try testing.expect((try narrow_folding.next()) == null);

    // A sub-range starting on a value row: its one row is the same row the
    // whole-object walk handed out, at the same position with the same value.
    var tail = Without.init(try fix.walk(3, fix.rows));
    const tail_row = (try tail.next()).?;
    try testing.expectEqual(all_rows[1].id(), tail_row.id());
    try testing.expectEqual(all_rows[1].pos, tail_row.pos);
    try testing.expect(all_rows[1].value().eql(tail_row.value()));
    try testing.expect((try tail.next()) == null);

    // And the mark-aware adapter over the *same* sub-range hands back the same
    // row and reports **no** mark, because the mark's begin is on row 2 and
    // this range starts on row 3: the fold only sees the rows the walk passes
    // (`marks.rs:26-42`), which is why the set it reports is not
    // `mark_index.richTextAt`'s and why a reader wanting the marks at a
    // position it has not walked to wants that instead. The module
    // documentation says so; this is the test that holds it to it.
    var tail_marks = With.init(gpa, try fix.walk(3, fix.rows));
    defer tail_marks.deinit();
    const same_row = (try tail_marks.next()).?;
    try testing.expectEqual(all_rows[1].id(), same_row.id());
    try testing.expectEqual(all_rows[1].pos, same_row.pos);
    try testing.expectEqual(@as(?*const MarkSet, null), tail_marks.getMarks());
    // The mark's end is on row 4 and is in the range, so it is folded and
    // changes nothing: an end with no open mark is dropped
    // (`src/marks.zig:577-581`).
    try testing.expect((try tail_marks.next()) == null);
}

test "constructing either adapter allocates nothing" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // A counting allocator is the instrument: a constructor that allocated
    // would move the count, and one that did not leaves it at zero. The walk
    // is built first and from the real allocator, so the count can only move
    // because of the adapter.
    var counting: Counting = .{ .inner = gpa };

    // `NoMarkIter` is the walk and nothing else, so it cannot allocate at all.
    const without = NoMarkIter(opiter.OpIter(OpBuilder)).init(try fix.walk(1, fix.rows));
    try testing.expectEqual(@as(usize, 0), counting.count);
    try testing.expectEqual(@as(?*const MarkSet, null), without.getMarks());

    // `MarkIter` owns a fold, and the fold is two empty collections, so it
    // allocates nothing either — what it holds was already the caller's.
    var with = MarkIter(opiter.OpIter(OpBuilder)).init(counting.allocator(), try fix.walk(1, fix.rows));
    try testing.expectEqual(@as(usize, 0), counting.count);
    try testing.expectEqual(@as(?*const MarkSet, null), with.getMarks());

    // And the first mark row *does* allocate, so the assertion above is about
    // the constructor and not about a count that never moves. Row 1 is the
    // `"a"` and row 2 is the mark's begin, so the second `next` is what opens
    // the mark, and the third is the row the mark is on.
    _ = try with.next();
    try testing.expectEqual(@as(usize, 0), counting.count);
    try testing.expect((try with.next()) != null);
    try testing.expect(counting.count > 0);
    try testing.expectEqual(@as(usize, 1), with.getMarks().?.numMarks());
    with.deinit();
}

test "both adapters are query terms and Shiftable cursors" {
    // The instantiations are the checks: `assertQueryTerm` fails to compile on
    // a missing or mis-signed method, and `column.Shiftable` fails to compile
    // on a missing one of its eight.
    comptime oquery.assertQueryTerm(MarkIter(opiter.OpIter(OpBuilder)));
    comptime oquery.assertQueryTerm(NoMarkIter(opiter.OpIter(OpBuilder)));
    comptime _ = MarkIter(opiter.OpIter(OpBuilder)).shiftable;
    comptime _ = NoMarkIter(opiter.OpIter(OpBuilder)).shiftable;
}

test "a Shiftable adapter repositions into a later window" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    var with = MarkIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(1, fix.rows));
    defer with.deinit();

    // Step over the first value row; the mark's begin is folded in on the way.
    _ = try with.next();
    try testing.expectEqual(@as(usize, 2), with.pos());

    // A `seekTo` behind the walk answers null, not an error, and leaves the
    // walk where it stands.
    try testing.expect((try with.seekTo(1)) == null);
    try testing.expectEqual(@as(usize, 2), with.pos());

    // `shiftNext` is the accessor that lands *on* a row, which `shift` alone
    // cannot do: its signature is `void`, so it can only move the window.
    // Row 4 is the mark's end, and folding it leaves nothing open.
    const end = (try with.shiftNext(.{ .start = 4, .end = fix.rows })).?;
    try testing.expectEqual(@as(usize, 4), end.pos);
    try testing.expectEqual(@as(usize, 5), with.pos());
    try testing.expectEqual(@as(?*const MarkSet, null), with.getMarks());

    // A backward range is an error rather than a bare null, so a caller can
    // tell "no row there" from "you asked for the wrong direction"
    // (`op_iter.zig:1658-1659`).
    try testing.expectError(error.InvalidValue, with.shiftNext(.{ .start = 1, .end = 2 }));

    // `shift` moves the *window* and leaves the position alone, and it can
    // only widen the window forward: `Column.Iterator.setMax` is
    // `items_left = if (at > self.at) at - self.at else 0`
    // (`hexane/column.zig:3459-3461`), so a range ending behind the walk
    // leaves the walk spent rather than rewinding it. That is why the
    // accessor that lands on a row is `shiftNext` and not `shift`.
    var fresh = MarkIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(1, fix.rows));
    defer fresh.deinit();
    try fresh.shift(.{ .start = 0, .end = 3 });
    try testing.expectEqual(@as(usize, 3), fresh.maxPos());
    try testing.expectEqualStrings("a", (try fresh.next()).?.asStr());
    // Row 2 is the mark's begin, which neither adapter returns, so the walk
    // yields nothing more.
    try testing.expect((try fresh.next()) == null);
    try testing.expectEqual(@as(usize, 3), fresh.pos());
}
