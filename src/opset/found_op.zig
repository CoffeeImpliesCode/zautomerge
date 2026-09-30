//! Grouping a contiguous op stream into registers, and what a group is worth
//! (`rust/automerge/src/op_set2/op_set/found_op.rs`, 77 lines, plus the
//! `OpsFound` it yields, which upstream declares in
//! `op_set2/op_set.rs:1455-1514`).
//!
//! # A group is one register, and the row order is what makes that true
//!
//! [`OpsFoundIter`] takes a stream of rows **already grouped** by
//! [`Op.elemidOrKey`] — the element a row made if it inserts, and its raw key
//! otherwise — and closes a group every time that changes
//! (`found_op.rs:51-57`). The grouping is not something it computes; it is an
//! invariant it *reads*, and the invariant is the second half of the row-order
//! rule (`op.zig:2069-2080`, `op_set2/op.rs:1059-1060`): within one object,
//! rows group by register and the registers ascend. A caller that hands this
//! iterator a stream which is not grouped gets a group per *run* of equal
//! keys, not per register, and nothing here can tell the difference — which is
//! why the tests below build their fixtures and say which row order they are
//! in.
//!
//! # The two filters, and what an empty group means
//!
//! A row joins its group unless it is an increment — an increment is not a
//! stand-alone value (`found_op.rs:12-16`, `:61`) — or unless
//! [`Op.scopeToClock`] says the clock does not have it (`found_op.rs:61`; the
//! rule is `op_set2/op_set/visible.rs:215-222`, `:263`). A register whose rows
//! are **all** filtered out is skipped and never returned at all
//! (`found_op.rs:22-23`, `:71-75`): `next` answering `null` means the stream is
//! spent, never "here is an empty group". That is the distinction a caller
//! would otherwise trip over, and it is the same trap
//! `mark_index.zig:488-511` documents for the mark index's cursor, so it is
//! stated here rather than left to the reader.
//!
//! A group with several rows is a **conflict** for that key: the first row is
//! the winner, because one register's rows are contiguous and ascend strictly
//! in op id (`op.zig:2078-2080`) and an op id orders by counter then actor
//! (`src/types.zig:163-170`). [`OpsFound.resolveAction`] is what turns that
//! into a decision (`op_set2/op_set.rs:1482-1509`).
//!
//! # `range` and `end_pos` are the group's extent, not the caller's
//!
//! Both are written from the rows the group has seen, so they are half-open
//! and they include the rows the filters dropped: `found.range =
//! self.start_pos..(op.pos + 1)` (`found_op.rs:59-60`) runs from the group's
//! *first* row to one past its *last*, whatever those two are. A caller that
//! wants the surviving rows' extent has to narrow [`OpsFound.ops`]; a caller
//! that wants the register's extent in the op set — which is what
//! `OpSet::seek_ops_by_index` checks against the walk's own end position
//! (`op_set2/op_set.rs:618-621`) — wants these.
//!
//! # Constructing one allocates nothing
//!
//! [`OpsFoundIter`] holds a walk, a clock and a `null` group
//! (`found_op.rs:34-42`). The first group is built by the first `next` and it
//! too allocates nothing; only a row that survives both filters allocates, in
//! `ops`. `OpsFound` therefore carries the allocator, and `deinit` gives the
//! bytes back.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clockmod = @import("../clock.zig");
const column = @import("../hexane/column.zig");
const opmod = @import("op.zig");
const opcols = @import("columns.zig");
const opiter = @import("op_iter.zig");
const optypes = @import("types.zig");
const value = @import("../value.zig");

const Allocator = std.mem.Allocator;
const Clock = clockmod.Clock;
const ElemId = types.ElemId;
const KeyRef = optypes.KeyRef;
const Op = opmod.Op;
const OpBuilder = opmod.OpBuilder;
const OpType = value.OpType;
const ParseError = err.ParseError;
const ReadOpError = opiter.ReadOpError;
const ResolvedAction = opmod.ResolvedAction;
const RowRange = column.RowRange;
const SequenceType = types.SequenceType;
const StringTable = opcols.StringTable;
const SuccCursors = opmod.SuccCursors;
const SuccEntry = opmod.SuccEntry;
const TextEncoding = types.TextEncoding;

const testing = std.testing;

// ── OpsFound ───────────────────────────────────────────────────────────────

/// The rows one register holds, and the extent of that register in the op set
/// (`OpsFound`, `op_set2/op_set.rs:1455-1461`).
///
/// `ops` owns the row values; each row borrows the columns and the string
/// table of the op set it came from, exactly as every other borrowed [`Op`]
/// does (`op.zig:1600-1609`).
pub const OpsFound = struct {
    /// Where the register sits in its sequence, for a sequence read
    /// (`op_set2/op_set.rs:1457`).
    index: usize,
    /// The rows of the register that survived both filters, in row order — so
    /// ascending in op id, and the first is the winner.
    ops: std.ArrayList(Op),
    /// One past the register's last row, including the rows the filters
    /// dropped (`op_set2/op_set.rs:1459`).
    end_pos: usize,
    /// The register's extent in the op set, `start..end_pos`
    /// (`op_set2/op_set.rs:1460`).
    range: RowRange,

    /// An empty group, over no rows (`OpsFound::default`,
    /// `op_set2/op_set.rs:1455`). Allocates nothing; `gpa` is accepted so a
    /// caller never has to know that, and is not stored.
    pub fn init(gpa: Allocator) OpsFound {
        _ = gpa;
        return .{ .index = 0, .ops = .empty, .end_pos = 0, .range = .{ .start = 0, .end = 0 } };
    }

    /// Frees `ops` and nothing else: the rows themselves own nothing.
    pub fn deinit(self: *OpsFound, gpa: Allocator) void {
        self.ops.deinit(gpa);
        self.* = undefined;
    }

    /// How wide the register is in a sequence, which is the width of its last
    /// surviving row (`width`, `op_set2/op_set.rs:1464-1469`).
    ///
    /// Zero for an empty group, which is upstream's `.unwrap_or(0)`. A width
    /// is one, a text element's width, or zero for a mark
    /// (`op.zig:1817-1822`), so the cast is total.
    pub fn width(self: OpsFound, seq_type: SequenceType, encoding: TextEncoding) usize {
        // The empty case is answered from a bound, so the subtraction below is
        // on a length the analyser can see is non-zero.
        const n = self.ops.items.len;
        if (n == 0) return 0;
        const w = self.ops.items[n - 1].width(seq_type, encoding);
        std.debug.assert(w >= 0);
        return @intCast(w);
    }

    /// What to do about the operation that brought the caller here
    /// (`resolve_action`, `op_set2/op_set.rs:1482-1509`).
    ///
    /// Three cases, and the middle one is the only interesting one. A `put`
    /// that repeats the register's current value and is its *only* row needs
    /// no operation at all (`None`, `:1489-1492`). A `put` that repeats it in
    /// a register with several rows means the losing rows have to be deleted
    /// (`:1493-1501`), which is a conflict resolution rather than a visible
    /// update — the distinction the merge walks' emission order turns on
    /// (`op_set2/op_set.rs:1522-1524`, and `op.zig:190-216` for the type).
    /// Anything else, and a `delete` on an empty register, is a visible update
    /// (`:1504-1508`).
    ///
    /// **This consumes the winner when it reports a conflict**, because the
    /// caller is expected to replace the register with it.
    pub fn resolveAction(self: *OpsFound, original: OpType) ?ResolvedAction {
        if (self.ops.items.len > 0) {
            const last = self.ops.items[self.ops.items.len - 1];
            switch (original) {
                .put => |v| {
                    if (last.action() == .set and last.value().eql(v)) {
                        if (self.ops.items.len == 1) {
                            // There is one operation with the same value as the
                            // incoming action, so nothing needs doing.
                            return null;
                        }
                        // Every op apart from the first lost, and the first is
                        // the winner because the register ascends in op id.
                        _ = self.ops.pop();
                        return .{ .conflict_resolution = .delete };
                    }
                },
                else => {},
            }
        } else if (original == .delete) {
            // A delete on a register with no rows needs no operation.
            return null;
        }
        return .{ .visible_update = original };
    }

    /// The element a sequence row in this register hangs by, or null for a map
    /// key and for an empty group (`elemid`, `op_set2/op_set.rs:1511-1513`).
    ///
    /// Upstream's `.and_then(|o| o.cursor().ok())` drops the error and so does
    /// this: a register whose last row is a map row has no element, and that
    /// is an answer rather than a failure.
    pub fn elemid(self: OpsFound) ?ElemId {
        if (self.ops.items.len == 0) return null;
        const last = self.ops.items[self.ops.items.len - 1];
        return last.cursor() catch null;
    }
};

// ── OpsFoundIter ───────────────────────────────────────────────────────────

/// A query that groups a contiguous, already-grouped op stream by register and
/// filters each group by action and by clock (`OpsFoundIter`,
/// `op_set2/op_set/found_op.rs:24-31`).
///
/// The `Shiftable` surface is the `pos`/`maxPos`/`setMax`/`advanceTo`/
/// `advanceBy`/`shift`/`shiftNext`/`seekTo` set, forwarded to the walk;
/// upstream has no such thing, and the port gives every walk in the crate one
/// (`op_iter.zig:1582-1672`).
///
/// It is **not** a query term in `op_query.zig`'s sense and has no `range`: it
/// yields groups rather than rows, so `OpQuery::range` — the range of *rows* a
/// query covers, which is what builds a clock-filtering skipper
/// (`op_set2/op_set/op_query.rs:43`) — has no answer for it. Upstream agrees:
/// the `OpQueryTerm` impls are for `OpIter`, `SkipIter`, `FixCounters`,
/// `MarkIter`, `NoMarkIter` and `VisibleOpIter`, and this is not one of them.
pub fn OpsFoundIter(comptime I: type) type {
    return struct {
        const Self = @This();

        /// The allocator every group this hands out was built with.
        gpa: Allocator,
        /// The walk, over a stream that is already grouped.
        iter: I,
        /// The first row of the group being collected (`start_pos`,
        /// `found_op.rs:27`).
        start_pos: usize,
        /// The clock rows are filtered against, or null for the document's
        /// current state (`found_op.rs:28`).
        clock: ?Clock,
        /// The register of the row just seen (`last_key`, `found_op.rs:29`).
        last_key: ?KeyRef,
        /// The group being collected, or null before the first row and between
        /// groups (`found`, `found_op.rs:30`).
        found: ?OpsFound,

        pub const shiftable = column.Shiftable(Self);

        /// A grouper over `iter`, filtering against `c` (`OpsFoundIter::new`,
        /// `found_op.rs:34-42`). Allocates nothing: the walk is the caller's
        /// and the first group is built by the first `next` rather than here.
        pub fn init(gpa: Allocator, iter: I, c: ?Clock) Self {
            return .{
                .gpa = gpa,
                .iter = iter,
                .start_pos = 0,
                .clock = c,
                .last_key = null,
                .found = null,
            };
        }

        /// Frees the group still being collected, and nothing else.
        pub fn deinit(self: *Self) void {
            if (self.found) |*group| group.deinit(self.gpa);
            self.found = null;
        }

        /// The next register that has a row left in it, or null at the end of
        /// the walk (`next`, `found_op.rs:48-76`).
        ///
        /// A register whose rows were all filtered out is dropped rather than
        /// handed back empty, so a `null` is always the end of the walk (the
        /// module documentation's second section).
        ///
        /// **The order inside the loop is upstream's and is load bearing.** The
        /// row that changed the register is added to the *new* group before
        /// the *old* one is handed back (`found_op.rs:58-68`), and it has to
        /// be: that row is the first row of the new register, so returning
        /// before appending it would drop the first row of every register but
        /// the first. Upstream's `result` carries the ended group across the
        /// append for exactly that reason, and so does this.
        pub fn next(self: *Self) ReadOpError!?OpsFound {
            var result: ?OpsFound = null;
            while (try self.iter.next()) |row| {
                var op = row;
                const key = op.elemidOrKey();
                if (self.last_key == null or !self.last_key.?.eql(key)) {
                    // `result = self.found.take()` (`found_op.rs:53`) *moves*
                    // the ended group out and `self.found = Some(default)`
                    // (`:55`) puts a fresh one in its place, so exactly one of
                    // the two owns `ops` at every point. The empty group this
                    // displaces had nothing appended to it — a group with a row
                    // in it is returned below — so it needs no free.
                    result = self.found;
                    self.found = OpsFound.init(self.gpa);
                    self.last_key = key;
                    self.start_pos = op.pos;
                }
                const group = &self.found.?;
                group.end_pos = op.pos + 1;
                group.range = .{ .start = self.start_pos, .end = op.pos + 1 };
                if (op.action() != .increment and op.scopeToClock(self.clock)) {
                    try group.ops.append(self.gpa, op);
                }
                // `found_op.rs:65-68`: the group that just ended is handed back
                // as soon as it is known to be non-empty.
                if (result) |ended| {
                    if (ended.ops.items.len > 0) return ended;
                }
            }
            // `found_op.rs:70-75`: the last group, and nothing if it is empty.
            const found = self.found orelse return null;
            self.found = null;
            if (found.ops.items.len == 0) {
                var empty = found;
                empty.deinit(self.gpa);
                return null;
            }
            return found;
        }

        /// The row the next `next` reads (`column.zig:4000`).
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
        pub fn shift(self: *Self, rows: RowRange) void {
            self.iter.shift(rows);
        }

        /// Repositions the walk onto `rows` and reads the row at its start
        /// (`OpIter.shiftNext`).
        ///
        /// A half-collected group is stale afterwards, and a group is not a row
        /// cursor and cannot be rewound: a caller that repositions part-way
        /// through a register should start a new iterator.
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

    fn intern(ctx: *const anyopaque, bytes: []const u8, gpa: Allocator) ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(@constCast(ctx)));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, bytes)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, bytes));
        return id;
    }
};

/// An allocator that counts what goes through it, so a test can assert that
/// constructing something asked for nothing. The same shape
/// `op_iter.zig:1979-2026` uses, written for the same reason.
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

    fn free(ctx: *anyopaque, memory: []u8, ra: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, ra, ret_addr);
    }
};

/// A map with two registers and nothing else: the root map's key `"a"` set
/// once, and its key `"b"` set twice, so `"a"` is one row and `"b"` is a
/// conflict. The rows are in `Op.step`'s order — the map keys ascend, so `"a"`
/// precedes `"b"` (`op.zig:2069-2080`) — and inside `"b"` the two rows ascend
/// in op id, so the first is the winner.
fn mapRows(gpa: Allocator) !std.ArrayList(OpBuilder) {
    var ops: std.ArrayList(OpBuilder) = .empty;
    errdefer {
        for (ops.items) |*o| o.deinit(gpa);
        ops.deinit(gpa);
    }
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 1, .actor = 0 }, .root, .make_map, .fromStr("m"), .null_value, false, false, null, &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 1, .actor = 0 }, .root, .set, .fromStr("a"), .{ .int = 1 }, false, false, null, &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 2, .actor = 0 }, .root, .set, .fromStr("b"), .{ .int = 2 }, false, false, null, &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 3, .actor = 0 }, .root, .set, .fromStr("b"), .{ .int = 3 }, false, false, null, &.{}));
    return ops;
}

/// A spliced op set plus the table its strings are interned in and a successor
/// buffer sized for it.
const Fixture = struct {
    gpa: Allocator,
    cols: opcols.Columns(OpBuilder),
    table: Table,
    succ: []SuccEntry,
    rows: usize,

    fn init(gpa: Allocator) !Fixture {
        var table = Table.init(gpa);
        errdefer table.deinit();
        var cols = try opcols.Columns(OpBuilder).init(gpa);
        errdefer cols.deinit();
        var ops = try mapRows(gpa);
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

    /// A walk over rows `from..to` of the op set. Row 0 is the `make_map`, so
    /// the map's own registers are `1..rows`.
    fn walk(self: *Fixture, from: usize, to: usize) ParseError!opiter.OpIter(OpBuilder) {
        return opiter.OpIter(OpBuilder).init(
            &self.cols,
            self.table.asTable(),
            .{ .start = from, .end = to },
            self.succ,
        );
    }
};

test "one register is one group and its rows ascend in op id" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa);
    defer fix.deinit();

    // The rows arrive in document order and the grouper closes a group on
    // each change of register, so two registers come out. The order inside a
    // group is the property a caller relies on when it reads `ops.items[0]` as
    // the winner, so it is asserted rather than assumed.
    var it = OpsFoundIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(1, fix.rows), null);
    defer it.deinit();

    var groups: usize = 0;
    while (try it.next()) |group_value| {
        var group = group_value;
        defer group.deinit(gpa);
        groups += 1;
        var i: usize = 1;
        while (i < group.ops.items.len) : (i += 1) {
            try testing.expectEqual(
                std.math.Order.lt,
                group.ops.items[i - 1].id().order(group.ops.items[i].id()),
            );
        }
    }
    try testing.expectEqual(@as(usize, 2), groups);
}

test "a group of one row and a group of two rows are told apart" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa);
    defer fix.deinit();

    var it = OpsFoundIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(1, fix.rows), null);
    defer it.deinit();

    // The first register, `"a"`: one row, and the group ends one past it.
    var single = (try it.next()).?;
    try testing.expectEqual(@as(usize, 1), single.ops.items.len);
    try testing.expectEqual(@as(usize, 1), single.range.start);
    try testing.expectEqual(@as(usize, 2), single.range.end);
    try testing.expectEqual(@as(usize, 2), single.end_pos);
    try testing.expectEqualStrings("a", single.ops.items[0].keyStr().?);
    single.deinit(gpa);

    // The second, `"b"`: a conflict, two rows, and the first is the winner.
    var conflict = (try it.next()).?;
    try testing.expectEqual(@as(usize, 2), conflict.ops.items.len);
    try testing.expectEqual(@as(usize, 2), conflict.range.start);
    try testing.expectEqual(@as(usize, 4), conflict.range.end);
    try testing.expectEqual(@as(usize, 4), conflict.end_pos);
    try testing.expectEqualStrings("b", conflict.ops.items[0].keyStr().?);
    try testing.expect(conflict.ops.items[0].value().eql(.{ .int = 2 }));
    try testing.expect(conflict.ops.items[1].value().eql(.{ .int = 3 }));

    // A `put` of the register's *current* value — which is its last row's, not
    // its first's (`op_set2/op_set.rs:1486-1488`) — is a conflict resolution
    // rather than a visible update: the incoming put is a no-op, so the other
    // row of the register is what has to go, and it is the one popped
    // (`:1493-1501`).
    const action = conflict.resolveAction(.{ .put = .{ .int = 3 } }).?;
    try testing.expect(action == .conflict_resolution);
    // The popped row was the one that matched, so what is left is the first
    // row — which the caller then treats as the winner.
    try testing.expectEqual(@as(usize, 1), conflict.ops.items.len);
    try testing.expect(conflict.ops.items[0].value().eql(.{ .int = 2 }));
    conflict.deinit(gpa);

    try testing.expect((try it.next()) == null);
}

test "an increment is not a value and its register is dropped" {
    const gpa = testing.allocator;
    var cols = try opcols.Columns(OpBuilder).init(gpa);
    defer cols.deinit();
    var table = Table.init(gpa);
    defer table.deinit();
    const succ = try gpa.alloc(SuccEntry, 0);
    defer gpa.free(succ);

    // A register whose only row is an increment. The filter is
    // `op.action != Action::Increment` (`found_op.rs:61`), so the register is
    // dropped entirely rather than returned empty (`found_op.rs:22-23`).
    var inc = try OpBuilder.init(gpa, .{ .counter = 1, .actor = 0 }, .root, .increment, .fromStr("n"), .{ .counter = .init(0) }, false, false, null, &.{});
    defer inc.deinit(gpa);
    const written = try cols.splice(gpa, 0, &.{inc}, .unicode_code_point, table.asTable());
    try testing.expectEqual(@as(usize, 1), written);

    var it = OpsFoundIter(opiter.OpIter(OpBuilder)).init(gpa, try opiter.OpIter(OpBuilder).init(&cols, table.asTable(), .{
        .start = 0,
        .end = written,
    }, succ), null);
    defer it.deinit();
    // Null, and it means the stream is spent: there is no empty group, and no
    // second call that would tell the difference.
    try testing.expect((try it.next()) == null);
    try testing.expect((try it.next()) == null);
}

test "a clock that covers nothing filters every register out" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa);
    defer fix.deinit();

    // A clock that names no actor at all: `Clock.contains` is false for every
    // id (`clock.zig:104-109`), so no row predates it and `Op.scopeToClock` is
    // false for all of them (`visible.rs:215-222`, `:263`). This is the "a
    // filter that excludes everything" case, and the answer must be null
    // rather than two empty groups.
    const no_actors = Clock.initEmpty(gpa);
    var it = OpsFoundIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(1, fix.rows), no_actors);
    defer it.deinit();
    try testing.expect((try it.next()) == null);
    try testing.expect((try it.next()) == null);
}

test "a clock that covers one row of a register leaves the group one row" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa);
    defer fix.deinit();

    // A clock at counter 2 from actor 0 has the `"a"` row and the first `"b"`
    // row, and not the second. The `"b"` group survives with one row instead
    // of two, and its extent is unchanged — `range` is the register's extent
    // rather than the surviving rows' (the module documentation's third
    // section).
    var half = try Clock.init(gpa, 1);
    defer half.deinit();
    _ = half.include(0, 2);

    var it = OpsFoundIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(1, fix.rows), half);
    defer it.deinit();

    var first = (try it.next()).?;
    try testing.expectEqual(@as(usize, 1), first.ops.items.len);
    try testing.expectEqualStrings("a", first.ops.items[0].keyStr().?);
    first.deinit(gpa);

    var second = (try it.next()).?;
    try testing.expectEqual(@as(usize, 1), second.ops.items.len);
    try testing.expectEqualStrings("b", second.ops.items[0].keyStr().?);
    try testing.expectEqual(@as(usize, 2), second.range.start);
    try testing.expectEqual(@as(usize, 4), second.range.end);
    second.deinit(gpa);

    try testing.expect((try it.next()) == null);
}

test "a range that ends mid-register closes the group where it was cut" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa);
    defer fix.deinit();

    // A walk that stops after the first row of the `"b"` register. The group
    // is still a group — one row, at the same position — and a walk ending
    // inside a register is the boundary case `found_op.rs:70-75` handles.
    var it = OpsFoundIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(1, 3), null);
    defer it.deinit();

    var first = (try it.next()).?;
    try testing.expectEqualStrings("a", first.ops.items[0].keyStr().?);
    first.deinit(gpa);

    var cut = (try it.next()).?;
    try testing.expectEqual(@as(usize, 1), cut.ops.items.len);
    try testing.expectEqualStrings("b", cut.ops.items[0].keyStr().?);
    try testing.expectEqual(@as(usize, 2), cut.range.start);
    // `end_pos` is one past the last row the group *saw*, not one past the
    // register's last row, which is why it is 3 and not 4.
    try testing.expectEqual(@as(usize, 3), cut.end_pos);
    try testing.expectEqual(@as(usize, 3), cut.range.end);
    cut.deinit(gpa);

    try testing.expect((try it.next()) == null);
}

test "a range that starts mid-register reports the range it was given" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa);
    defer fix.deinit();

    // A walk that starts at the register's own first row gets the register:
    // two rows, `start_pos` 2.
    var tail = OpsFoundIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(2, fix.rows), null);
    defer tail.deinit();
    var b = (try tail.next()).?;
    try testing.expectEqual(@as(usize, 2), b.ops.items.len);
    try testing.expectEqual(@as(usize, 2), b.range.start);
    b.deinit(gpa);

    // A walk that starts on the register's *second* row gets one row and a
    // `start_pos` of 3. That is the honest answer for a stream that is not
    // grouped from the start, and the reason the "already grouped"
    // precondition is load bearing (the module documentation's first section).
    var mid = OpsFoundIter(opiter.OpIter(OpBuilder)).init(gpa, try fix.walk(3, fix.rows), null);
    defer mid.deinit();
    var only_second = (try mid.next()).?;
    try testing.expectEqual(@as(usize, 1), only_second.ops.items.len);
    try testing.expectEqual(@as(usize, 3), only_second.range.start);
    try testing.expectEqual(@as(usize, 4), only_second.range.end);
    only_second.deinit(gpa);
    try testing.expect((try mid.next()) == null);
}

test "an empty op set groups into nothing" {
    const gpa = testing.allocator;
    var cols = try opcols.Columns(OpBuilder).init(gpa);
    defer cols.deinit();
    var table = Table.init(gpa);
    defer table.deinit();
    const succ = try gpa.alloc(SuccEntry, 0);
    defer gpa.free(succ);

    var it = OpsFoundIter(opiter.OpIter(OpBuilder)).init(gpa, try opiter.OpIter(OpBuilder).init(&cols, table.asTable(), .{
        .start = 0,
        .end = 0,
    }, succ), null);
    defer it.deinit();
    try testing.expect((try it.next()) == null);
    try testing.expect((try it.next()) == null);
    try testing.expectEqual(@as(usize, 0), it.pos());
    try testing.expectEqual(@as(usize, 0), it.maxPos());
}

test "constructing the iterator allocates nothing" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa);
    defer fix.deinit();

    // The walk is built first and from the real allocator, so the only thing
    // that can move the count is the constructor.
    var counting: Counting = .{ .inner = gpa };
    var it = OpsFoundIter(opiter.OpIter(OpBuilder)).init(counting.allocator(), try fix.walk(1, fix.rows), null);
    defer it.deinit();
    try testing.expectEqual(@as(usize, 0), counting.count);

    // The first group is built by the first `next` and is empty, so it does
    // not allocate either; the first row that survives both filters does.
    var group = (try it.next()).?;
    defer group.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), group.ops.items.len);
    try testing.expect(counting.count > 0);
}

test "the grouper is a Shiftable cursor" {
    // The instantiation is the check: `column.Shiftable` fails to compile on
    // a missing one of its eight methods.
    comptime _ = OpsFoundIter(opiter.OpIter(OpBuilder)).shiftable;
}

test "resolveAction and width say what a single-row register needs" {
    const gpa = testing.allocator;
    var found = OpsFound.init(gpa);
    defer found.deinit(gpa);
    try found.ops.append(gpa, Op.init(0, false, .{ .counter = 1, .actor = 0 }, .set, .root, .fromStr("k"), false, .{ .int = 7 }, false, null, SuccCursors.none()));

    // A `put` of the register's own value where the register has one row: no
    // operation needs writing at all (`op_set2/op_set.rs:1489-1492`).
    try testing.expect(found.resolveAction(.{ .put = .{ .int = 7 } }) == null);
    // A `put` of a different value is a visible update.
    try testing.expect((found.resolveAction(.{ .put = .{ .int = 8 } }) orelse unreachable) == .visible_update);
    // A delete of a register that has a row is a visible update too.
    try testing.expect(found.resolveAction(.delete) != null);

    // A delete of an empty register is nothing to do (`op_set2/op_set.rs:1504-1507`),
    // and a `put` of one is a visible update because it falls through.
    var empty = OpsFound.init(gpa);
    defer empty.deinit(gpa);
    try testing.expect(empty.resolveAction(.delete) == null);
    try testing.expect(empty.resolveAction(.{ .put = .{ .int = 1 } }) != null);

    // `elemid` is the last row's cursor, and a map row has none
    // (`op_set2/op_set.rs:1511-1513`).
    try testing.expect(found.elemid() == null);
    try testing.expect(empty.elemid() == null);
    // The width is the last row's, and an empty register's is zero
    // (`op_set2/op_set.rs:1464-1469`).
    try testing.expectEqual(@as(usize, 1), found.width(.list, .unicode_code_point));
    try testing.expectEqual(@as(usize, 0), empty.width(.list, .unicode_code_point));
}
