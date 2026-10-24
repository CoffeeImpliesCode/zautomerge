//! Which rows a read can see, and the two walks that answer it.
//!
//! Upstream `op_set2/op_set/visible.rs`, 275 lines, owns:
//!
//! | what | upstream |
//! |------|----------|
//! | [`VisIter`] and its `Indexed`/`Scan` choice | `:44-48`, `:59-67` |
//! | [`IndexedVisIter`] | `:81-101` |
//! | [`ScanVisIter`] | `:103-157` |
//! | [`VisibleOpIter`] | `:159-193` |
//! | the cheap-column visibility rule, [`isVisible`] | `:120-129` |
//!
//! # The per-op rule is not here
//!
//! Upstream puts `Op::scope_to_clock` and `Op::maybe_scope_to_clock` in this
//! file (`visible.rs:196-265`). The port cannot: `visible.rs:267-275`
//! implements `OpQueryTerm` for [`VisibleOpIter`], so `op_query.zig` imports
//! this module, and in Zig — where a method is a declaration in the file that
//! holds the type, not an inherent impl that creates no dependency — the rule
//! would then be reachable only through a cycle. It is
//! [`op.Op.scopeToClock`] and [`op.Op.maybeScopeToClock`] in
//! [`op.zig`](op.zig) instead, beside [`op.Op.visible`] and
//! [`op.Op.fixCounter`], and [`isVisible`] is the one cheap-column spelling
//! of the same rule that a walk over three columns can afford.
//!
//! # A null clock is a dispatch, not an empty filter
//!
//! [`VisIter.init`] picks the `Indexed` flavour when there is no clock and
//! the `Scan` flavour when there is (`visible.rs:59-67`), and the two are a
//! **performance** choice: the indexed flavour skips through the `visible`
//! index column run at a time, the scan flavour reads `id`, `action` and
//! `succ` row by row. They must answer identically, and
//! `test "both flavours of a visibility walk find the same rows"` is what
//! holds them to that — it drives both over the same op set, under a clock
//! that covers every op, and compares them row for row rather than by count.
//! Upstream makes the same promise in the same place, and keeps it in
//! `TopOps::next`'s assertion that a top op is also visible
//! (`top_op.rs:50`).
//!
//! # Constructing one of these allocates nothing
//!
//! A visibility walk runs for every walk of every object. Every iterator type
//! here is a few column cursors and some numbers
//! ([`column.Column.Iterator`](../../src/hexane/column.zig)), a `Clock` the
//! caller owns, and — for the scan flavour — the caller's successor buffer,
//! which is the rule [`op_iter.SuccIterIter`] already states. The one
//! allocation upstream's `ScanVisIter::new` makes is `clock.clone()`
//! (`visible.rs:112`); the port borrows the clock instead, because a
//! `Clock` is a value the caller already holds and the rule that needs it is
//! a rule about a read, not about who owns the vector. The
//! `test "a visibility walk allocates nothing to construct"` test counts
//! every allocation that goes through a wrapper allocator and expects zero.
//!
//! # What is not here
//!
//! * `impl Default for VisIter` (`visible.rs:50-54`). It exists upstream only
//!   because `SkipIter` is `Default` (`iter/tools.rs:146-152`); the port's
//!   [`top_op.TopOps`] spells the skip in two lines and never needs a
//!   default iterator.
//! * `OpQueryTerm for VisibleOpIter` (`visible.rs:267-275`), which is
//!   `op_query.zig`'s, in the direction the module graph runs.

const std = @import("std");
const err = @import("../error.zig");
const clocks = @import("../clock.zig");
const types = @import("../types.zig");
const column = @import("../hexane/column.zig");
const optypes = @import("types.zig");
const opcols = @import("columns.zig");
const opmod = @import("op.zig");
const op_iter = @import("op_iter.zig");

const Action = optypes.Action;
const ElemId = types.ElemId;
const KeyRef = optypes.KeyRef;
const OpId = types.OpId;
const Op = opmod.Op;
const SuccCursors = opmod.SuccCursors;
const SuccEntry = opmod.SuccEntry;
const StringTable = opcols.StringTable;
const Clock = clocks.Clock;

const ReadOpError = op_iter.ReadOpError;
const RowRange = column.RowRange;
const ParseError = err.ParseError;

/// The running sum of a prefix column at `row`, as an index into the column
/// it is a prefix *of*.
///
/// Upstream reads it inline wherever a flattened cursor has to be placed
/// (`op_set.rs:1301`, `:1280-1281`): the count column is indexed by row and
/// the other three by flattened successor, so the running sum of the counts
/// is what turns one into the other.
fn prefixAt(col: anytype, row: usize) ParseError!usize {
    const sum = try col.getPrefix(row);
    if (sum < 0) return error.InvalidValue;
    return std.math.cast(usize, sum) orelse error.InvalidValue;
}

// ── The rule ───────────────────────────────────────────────────────────────

/// Whether the row the three columns describe is visible within `clock`
/// (`ScanVisIter::is_visible`, `visible.rs:120-129`).
///
/// Three conditions, and all three matter:
///
/// * an increment is never visible on its own (`is_inc`, `:121`) — it has no
///   value of its own, it is an edge into somebody else's counter
///   (`op_set2/op.rs:1148-1156`);
/// * the row must **predate** the clock: the clock covers its own id
///   (`clock.rs:134-136`, which the port spells `Clock.contains`,
///   `clock.zig:107-109`). An op the clock has not seen is not in that past
///   state at all, so it is not visible there;
/// * no successor the clock covers may be a delete (`deleted`, `:123-126`).
///   A successor the clock does *not* cover deletes nothing, which is the
///   whole difference between a scoped read and [`op.Op.visible`], which
///   treats any successor as final.
///
/// **This is upstream's rule, written once.** Upstream writes it twice — here
/// at `visible.rs:120-129` and again in `top_op.rs:352-359`, the same three
/// conditions in a different order — even though `top_op.rs` already imports
/// this module for [`VisIter`] (`top_op.rs:11-17`). The port has one
/// definition, and the per-op rule it has to agree with,
/// [`op.Op.scopeToClock`], is one function too. Two tests hold the three to
/// each other: `test "both flavours of a visibility walk find the same rows"`
/// and `test "the cheap-column rule and the per-op rule agree on every row"`.
pub fn isVisible(id: OpId, action: Action, succ: SuccCursors, clock: Clock) bool {
    var deleted = false;
    var it = succ.withInc();
    while (it.next()) |entry| {
        if (entry.inc == null and clock.contains(entry.id)) {
            deleted = true;
            break;
        }
    }
    return !(deleted or !clock.contains(id) or action == .increment);
}

// ── The indexed flavour ────────────────────────────────────────────────────

/// The skipper over the `visible` index column
/// (`BoolColumnSkipper`, `iter/tools.rs:306-383`), which is a
/// `Column(bool, Bool)` and not the prefix one [`top_op.TopIter`] reads.
const VisibleSkipper = column.BoolColumnSkipper(column.Bool);

/// The walk over `index.visible`: the rows a register still has, in order
/// (`IndexedVisIter`, `visible.rs:81-101`).
///
/// This is the fast path. Upstream reads `op_set.cols.index.visible`
/// directly (`visible.rs:87`) and hands the result to a `BoolColumnSkipper`,
/// which turns "skip to the next visible row" into one step per run of the
/// boolean column rather than one per row (`iter/tools.rs:343-352`).
///
/// The column is derived state, never loaded from a document
/// (`columns.rs:314`): a load rebuilds it from the op stream
/// (`index.rs:220-231`), which is why the two flavours can be held to
/// answering the same thing.
///
/// **It is not a [`column.Shiftable`] cursor.** It carries `next` and
/// `shiftNext` and none of the other six the kernel requires
/// (`column.zig:6129-6142`): a skip iterator of *distances* has no position to
/// advance to or seek to. [`VisIter`], the wrapper that holds this walk or the
/// scan one, is not a cursor either, for the same reason.
pub fn IndexedVisIter(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set the walk reads.
        pub const Ops = opcols.Columns(O);

        /// The walk itself: a cursor over the column and three numbers.
        iter: VisibleSkipper,

        /// A walk over the visible rows of `rows` (`IndexedVisIter::new`,
        /// `visible.rs:86-90`).
        ///
        /// `rows` is clamped to the column (`iter_range`,
        /// [`hexane/src/column.rs:1384-1421`]), so a caller holding a stale
        /// range gets a short walk rather than a wrong one. Nothing is
        /// allocated: the skipper is a cursor and three numbers
        /// (`column.zig:4085-4109`).
        pub fn init(cols: *const Ops, rows: RowRange) ParseError!Self {
            const window = column.clampRange(rows, cols.index.visible.len());
            return .{
                .iter = VisibleSkipper.init(try cols.index.visible.iterRange(window), window.end),
            };
        }

        /// The distance from where the walk stands to the next visible row,
        /// or null once the window is walked out
        /// (`Iterator for BoolColumnSkipper`, `iter/tools.rs:355-382`).
        ///
        /// A count, not a position: `0` means the very next row is visible.
        /// The last answer before exhaustion is the distance to the end of
        /// the window, which is what a consumer that pairs this walk with
        /// another one relies on to learn the other has run out
        /// ([`top_op.TopOps.next`]).
        pub fn next(self: *Self) ParseError!?usize {
            return self.iter.next();
        }

        /// Repositions the walk to `rows` and yields the distance to the
        /// first visible row in it (`iter/tools.rs:334-353`).
        pub fn shiftNext(self: *Self, rows: RowRange) ParseError!?usize {
            return self.iter.shiftNext(rows);
        }
    };
}

// ── The scan flavour ───────────────────────────────────────────────────────

/// The walk over `id`, `action` and `succ` that recomputes visibility under
/// a historical clock (`ScanVisIter`, `visible.rs:103-157`).
///
/// This is the path a scoped read takes, because `index.visible` says which
/// rows are visible **now** and a read of a past state needs the answer as it
/// stood then. It costs three column cursors and one successor buffer, and it
/// answers the same rows the indexed walk does whenever the clock covers
/// every op in the range.
pub fn ScanVisIter(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set the walk reads.
        pub const Ops = opcols.Columns(O);

        /// The `Shiftable` conformance mark: this is a multi-column row
        /// cursor, so it carries the full kernel
        /// ([`column.Shiftable`]) and a walk can be repositioned into a
        /// child object without allocating.
        pub const shiftable = column.Shiftable(Self);

        /// The two halves of each row's own id (`visible.rs:106`).
        id: op_iter.OpIdIter,
        /// What the row does (`visible.rs:107`).
        action: op_iter.ActionIter,
        /// The row's successors, and their increments (`visible.rs:108`).
        succ: op_iter.SuccIterIter,
        /// The clock the read is scoped to, borrowed from the caller.
        ///
        /// **`Clock` is stored by value and its slots are the caller's.** The
        /// copy shares the one allocation [`Clock.init`](../../src/clock.zig)
        /// and every row's visibility is judged against it, so the clock must
        /// outlive this walk. That obligation is what "borrowed from the
        /// caller" means here, and nothing in this type pays it.
        clock: Clock,

        /// A walk over the rows of `rows`, scoped to `clock`
        /// (`ScanVisIter::new`, `visible.rs:111-121`).
        ///
        /// `scratch` is the caller's successor buffer; size it with
        /// [`op_iter.maxSuccCount`] and see [`op_iter.SuccIterIter`] for why
        /// it is the caller's. It must hold at least the widest row's
        /// successor count in `rows`.
        ///
        /// The two prefix positions are read before anything moves
        /// (`op_set.rs:1301`, `:1280-1281`): the count column is indexed by
        /// row and the other three by flattened successor.
        pub fn init(
            cols: *const Ops,
            rows: RowRange,
            clock: Clock,
            scratch: []SuccEntry,
        ) ReadOpError!Self {
            const window = column.clampRange(rows, cols.len());
            const succ_start = try prefixAt(&cols.succ_count, window.start);
            return .{
                .id = op_iter.OpIdIter.init(
                    try cols.id_actor.iterRange(window),
                    try cols.id_ctr.iterRange(window),
                ),
                .action = op_iter.ActionIter.init(try cols.action.iterRange(window)),
                .succ = op_iter.SuccIterIter.init(
                    try cols.succ_count.prefixIterRange(window),
                    try cols.succ_actor.iterRange(.{
                        .start = succ_start,
                        .end = cols.succ_actor.len(),
                    }),
                    try cols.succ_ctr.iterRange(.{
                        .start = succ_start,
                        .end = cols.succ_ctr.len(),
                    }),
                    try cols.index.inc.iterRange(.{
                        .start = succ_start,
                        .end = cols.index.inc.len(),
                    }),
                    succ_start,
                    scratch,
                ),
                .clock = clock,
            };
        }

        /// The next row's own id, or null at the end of the window.
        pub fn pos(self: *const Self) usize {
            return self.id.pos();
        }

        /// One past the last row this walk can read.
        pub fn maxPos(self: *const Self) usize {
            return self.id.maxPos();
        }

        /// Truncates the window so iteration stops at `at`.
        pub fn setMax(self: *Self, at: usize) void {
            self.id.setMax(at);
            self.action.setMax(at);
            self.succ.setMax(at);
        }

        /// Advances so the next `next` is the row at `target`. A target at
        /// or behind the cursor is a no-op.
        pub fn advanceTo(self: *Self, target: usize) ParseError!void {
            try self.id.advanceTo(target);
            try self.action.advanceTo(target);
            try self.succ.advanceTo(target);
        }

        /// Advances past `amount` rows.
        pub fn advanceBy(self: *Self, amount: usize) ParseError!void {
            return self.advanceTo(self.pos() +| amount);
        }

        /// Repositions the window to `rows`, leaving the cursor on its start.
        ///
        /// A `ParseError` leaves this cursor unchanged.
        pub fn shift(self: *Self, rows: RowRange) ParseError!void {
            var staged = self.*;
            try staged.id.shift(rows);
            try staged.action.shift(rows);
            try staged.succ.shift(rows);
            self.* = staged;
        }

        /// Repositions onto `rows` and reads the row at its start
        /// (`visible.rs:23-36`).
        ///
        /// The row at `rows.start` is read by the three `shift_next`s and
        /// judged by [`isVisible`]; if it is not visible the walk then runs
        /// on through the rows behind it and the answer is one more than
        /// their count, which is upstream's `skip + 1` (`:33-35`).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadOpError!?usize {
            const id = (try self.id.shiftNext(rows)) orelse return null;
            const action = (try self.action.shiftNext(rows)) orelse return null;
            const succ = (try self.succ.shiftNext(rows)) orelse return null;
            if (isVisible(id, action, succ, self.clock)) return 0;
            return 1 + (try self.next() orelse 0);
        }

        /// Consumes through `at` and reads the row there, or null when `at`
        /// is behind the walk.
        pub fn seekTo(self: *Self, at: usize) ReadOpError!?usize {
            if (at < self.pos()) return null;
            try self.advanceTo(at);
            return self.next();
        }

        /// The next row's visibility, or null at the end of the window
        /// (`ScanVisIter::next_visible`, `visible.rs:131-140`).
        fn nextVisible(self: *Self) ReadOpError!?bool {
            const id = (try self.id.maybeTryNext()) orelse return null;
            const action = try self.action.tryNext();
            const succ = try self.succ.tryNext();
            return isVisible(id, action, succ, self.clock);
        }

        /// The distance to the next visible row, or null once the window is
        /// walked out (`Iterator for ScanVisIter`, `visible.rs:144-157`).
        ///
        /// The last answer is the distance to the end of the window, and it
        /// is a `Some`: a consumer that pairs this walk with another has to
        /// be able to learn that *this* one is done, and
        /// [`top_op.TopOps`] does (`:50`).
        pub fn next(self: *Self) ReadOpError!?usize {
            var skip: usize = 0;
            while (try self.nextVisible()) |vis| {
                if (vis) break;
                skip += 1;
            }
            return skip;
        }
    };
}

// ── The choice between them ────────────────────────────────────────────────

/// Which rows are visible in a range, by whichever of the two walks the
/// clock selects (`VisIter`, `visible.rs:44-48`, `:59-79`).
///
/// **The choice is a performance dispatch and nothing else.** A null clock
/// takes the indexed walk and a clock takes the scan walk, because
/// `index.visible` is the answer for the present and only the three cheap
/// columns can answer for a past state. Both walks must produce the same
/// rows for the same clock, and the test that says so compares them row for
/// row.
///
/// Upstream boxes the scan variant (`visible.rs:46`); the port's union is
/// already inline, and [`ScanVisIter`] is three column cursors and a
/// `Clock` value, so there is nothing to box and nothing to allocate.
///
/// **The union is not a [`column.Shiftable`] cursor either.** It carries
/// `next` and `shiftNext` and none of the other six the kernel requires
/// (`column.zig:6129-6142`), so a consumer cannot reposition it the way its
/// own [`Scan`] arm can. [`ScanVisIter`] carries the full kernel because it
/// is a multi-column *row* cursor, while this is a wrapper over a skip
/// iterator, whose unit is a distance rather than a row.
pub fn VisIter(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set the walk reads.
        pub const Ops = opcols.Columns(O);

        /// The fast path, over the `visible` index column.
        pub const Indexed = IndexedVisIter(O);
        /// The scoped path, over `id`, `action` and `succ`.
        pub const Scan = ScanVisIter(O);

        inner: union(enum) {
            indexed: Indexed,
            scan: Scan,
        },

        /// The walk to use for a read scoped to `clock`
        /// (`VisIter::new`, `visible.rs:59-67`).
        ///
        /// `scratch` is the scan walk's successor buffer and is not read by
        /// the indexed one; see [`ScanVisIter.init`]. `rows` is clamped to
        /// the column set here, once, so a caller that has clamped already
        /// pays for it once and a caller that has not gets a short walk.
        pub fn init(
            cols: *const Ops,
            clock: ?Clock,
            rows: RowRange,
            scratch: []SuccEntry,
        ) ReadOpError!Self {
            const window = column.clampRange(rows, cols.len());
            if (clock) |c| {
                return .{ .inner = .{ .scan = try Scan.init(cols, window, c, scratch) } };
            }
            return .{ .inner = .{ .indexed = try Indexed.init(cols, window) } };
        }

        /// The distance to the next visible row, or null once the window is
        /// walked out (`Iterator for VisIter`, `visible.rs:71-79`).
        pub fn next(self: *Self) ReadOpError!?usize {
            return switch (self.inner) {
                .indexed => |*i| i.next(),
                .scan => |*s| s.next(),
            };
        }

        /// Repositions the walk to `rows` and yields the distance to the
        /// first visible row in it (`Shiftable for VisIter`, `visible.rs:16-21`).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadOpError!?usize {
            return switch (self.inner) {
                .indexed => |*i| i.shiftNext(rows),
                .scan => |*s| s.shiftNext(rows),
            };
        }
    };
}

// ── Filtering an op walk ───────────────────────────────────────────────────

/// The visible rows of any op walk, each with its counter rewritten to what
/// the clock saw (`VisibleOpIter`, `visible.rs:159-193`).
///
/// This is the op-shaped spelling of the same answer [`VisIter`] gives in
/// row positions: it reads the rows themselves rather than an index column,
/// so it costs a full row walk and is the path a caller takes when it wants
/// the ops, not the offsets. The op set's own `visible` accessor is the
/// indexed one (`op_query.rs:29-33`) and this is what upstream tests
/// against it (`op_set.rs:2030-2045`).
///
/// Upstream's bound is `I: OpQueryTerm<'a> + Clone` (`visible.rs:165-169`),
/// because the query term it wraps has to be cloneable to be handed a
/// `visible` wrapper. The port's `next` consumes `self.iter` and keeps
/// nothing, so the bound is just "an iterator of rows": `OpIter(O)` is the
/// one in the slice, and `op_query.zig` gives the term its own
/// `OpQueryTerm` impl in the direction the module graph runs.
pub fn VisibleOpIter(comptime I: type) type {
    return struct {
        const Self = @This();

        /// The clock the read is scoped to, borrowed from the caller. Null
        /// means "the present", and it is the unscoped answer, not an empty
        /// one: [`op.Op.scopeToClock`] documents why.
        ///
        /// **`Clock` is stored by value and its slots are the caller's.** The
        /// copy shares the one allocation [`Clock.init`](../../src/clock.zig)
        /// and [`next`] reads it on every row, so the clock must outlive this
        /// filter. This type owns nothing and declares no `deinit`: the walk it
        /// holds is the caller's, and its teardown is that walk's own.
        clock: ?Clock,
        /// The walk this filters.
        iter: I,

        /// A filter over `iter`, scoped to `clock`
        /// (`VisibleOpIter::new`, `visible.rs:165-169`).
        pub fn init(iter: I, clock: ?Clock) Self {
            return .{ .iter = iter, .clock = clock };
        }

        /// The next visible row, or null at the end of the walk
        /// (`visible.rs:180-192`).
        ///
        /// Two filters, in upstream's order. An increment is skipped outright
        /// (`:181-183`) — it is not a row a reader can see, and the `top`
        /// index never marks one. Everything else is handed to
        /// [`op.Op.scopeToClock`], which rewrites a counter's value to the
        /// total the clock saw and answers whether the row is in view.
        pub fn next(self: *Self) ReadOpError!?Op {
            while (try self.iter.next()) |row| {
                // `scope_to_clock` rewrites a counter's value, so it takes
                // the row by pointer (`visible.rs:215-222`); the walk hands
                // it out by value, so this is the copy it rewrites.
                var op = row;
                if (op.isInc()) continue;
                if (op.scopeToClock(self.clock)) return op;
            }
            return null;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A row as a fixture declares it: the op-type accessors
/// [`opcols.Columns`] calls, and nothing else. The same shape `columns.zig`
/// and `op_iter.zig` use for their own tests, because a test that drives a
/// column set is a statement about the columns and not about a view.
const Row = struct {
    op_id: OpId = .root,
    parent: ?OpId = null,
    act: Action = .set,
    anchor: KeyRef = .fromStr(""),
    does_insert: bool = false,
    does_expand: bool = false,
    is_visible: bool = true,
    is_top: bool = true,
    units: i64 = 1,
    v: optypes.ScalarValue = .null_value,
    name: ?[]const u8 = null,
    mark: ?i64 = null,
    succs: []const OpId = &.{},
    incs: []const ?i64 = &.{},

    pub fn id(self: Row) OpId {
        return self.op_id;
    }

    pub fn obj(self: Row) ?OpId {
        return self.parent;
    }

    pub fn action(self: Row) Action {
        return self.act;
    }

    pub fn key(self: Row) KeyRef {
        return self.anchor;
    }

    pub fn insert(self: Row) bool {
        return self.does_insert;
    }

    pub fn expand(self: Row) bool {
        return self.does_expand;
    }

    pub fn visible(self: Row) bool {
        return self.is_visible;
    }

    pub fn top(self: Row) bool {
        return self.is_top;
    }

    pub fn width(self: Row, _: types.SequenceType, _: types.TextEncoding) i64 {
        return self.units;
    }

    pub fn value(self: Row) optypes.ScalarValue {
        return self.v;
    }

    pub fn metaValue(self: Row) optypes.ValueMeta {
        return optypes.metaOf(self.v);
    }

    pub fn markName(self: Row) ?[]const u8 {
        return self.name;
    }

    pub fn markIndex(self: Row) ?i64 {
        return self.mark;
    }

    pub fn succCount(self: Row) usize {
        return self.succs.len;
    }

    pub fn succAt(self: Row, i: usize) OpId {
        return self.succs[i];
    }

    pub fn succIncCount(self: Row) usize {
        return self.incs.len;
    }

    pub fn succIncAt(self: Row, i: usize) ?i64 {
        return self.incs[i];
    }
};

/// A string table for the tests: the strings it has been given, in the order
/// they were first asked for, which is what makes an interned id stable.
const Table = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn init(gpa: std.mem.Allocator) Table {
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

    fn intern(ctx: *anyopaque, text: []const u8, gpa: std.mem.Allocator) ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(ctx));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, text)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, text));
        return id;
    }
};

const Cols = opcols.Columns(Row);

/// A spliced op set plus the table its strings are interned in. Freed by
/// `deinit`; the `Op`s a walk of it produces borrow both, and so does the
/// successor buffer it hands out.
const Fixture = struct {
    cols: Cols,
    table: Table,

    fn init(gpa: std.mem.Allocator, rows: []const Row) !Fixture {
        var table = Table.init(gpa);
        errdefer table.deinit();
        var cols = try Cols.init(gpa);
        errdefer cols.deinit();
        const n = try cols.splice(gpa, 0, rows, .unicode_code_point, table.asTable());
        if (n != rows.len) return error.TestUnexpectedResult;
        return .{ .cols = cols, .table = table };
    }

    /// A fixture spliced in phases, one `Columns.splice` per phase, which is
    /// how a document is built anyway: a local op lands as its own splice
    /// (`transaction/inner.rs:396`), so a column ends up with the slab
    /// layout a series of appends gives it rather than one encoder pass.
    fn initPhased(gpa: std.mem.Allocator, phases: []const []const Row) !Fixture {
        var table = Table.init(gpa);
        errdefer table.deinit();
        var cols = try Cols.init(gpa);
        errdefer cols.deinit();
        var at: usize = 0;
        for (phases) |phase| {
            const n = try cols.splice(gpa, at, phase, .unicode_code_point, table.asTable());
            if (n != phase.len) return error.TestUnexpectedResult;
            at += n;
        }
        return .{ .cols = cols, .table = table };
    }

    fn deinit(self: *Fixture) void {
        self.cols.deinit();
        self.table.deinit();
    }

    fn strings(self: *Fixture) StringTable {
        return self.table.asTable();
    }
};

/// An allocator that counts what goes through it, so a test can assert that
/// a walk asked for nothing.
const Counting = struct {
    inner: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .free = free,
        .remap = remap,
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

/// The object the list in [`doc`] lives in, made by the op at row 9.
const list_obj: OpId = .{ .counter = 6, .actor = 0 };

/// Eighteen rows over two objects, laid out the way the row-order invariant
/// demands. Read the test that uses it for what each register is for; the
/// comments here name the register and the row.
///
/// The root map's registers, in ascending key order: `a`, `b`, `c`, `d`,
/// `list`, `n`. Object `L`'s registers: element `8@0` and element `11@0`.
const doc = [_]Row{
    // ── Register "a": one put, then two concurrent ones that both survive.
    // Both successors of the first row are deletes as far as the index is
    // concerned, and both survivors are visible with no successors at all,
    // so this register has a live conflict (`op_set.rs:206-212`).
    .{ .op_id = .{ .counter = 1, .actor = 0 }, .anchor = .fromStr("a"), .v = .{ .int = 1 }, .is_visible = false, .is_top = false, .succs = &.{ .{ .counter = 1, .actor = 1 }, .{ .counter = 2, .actor = 0 } }, .incs = &.{ null, null } },
    .{ .op_id = .{ .counter = 1, .actor = 1 }, .anchor = .fromStr("a"), .v = .{ .int = 10 }, .is_top = false },
    .{ .op_id = .{ .counter = 2, .actor = 0 }, .anchor = .fromStr("a"), .v = .{ .int = 2 } },
    // ── Register "b": a single winner and nothing else.
    .{ .op_id = .{ .counter = 3, .actor = 0 }, .anchor = .fromStr("b"), .v = .{ .str = "b0" } },
    // ── Register "c": both rows deleted, so the register has no visible row
    // and no top op. `validate_top_index` allows a group in exactly that
    // state — its `first_top` and `last_vis` are both null, so the
    // `assert_eq!(first_top, last_vis)` at the group boundary passes
    // (`op_set.rs:196-206`).
    .{ .op_id = .{ .counter = 2, .actor = 1 }, .anchor = .fromStr("c"), .v = .{ .str = "c0" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 3, .actor = 1 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 3, .actor = 1 }, .anchor = .fromStr("c"), .v = .{ .str = "c1" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 4, .actor = 1 }}, .incs = &.{null} },
    // ── Register "d": three puts, one actor, so a clock that stops after
    // the first sees a different winner than one that sees all three.
    .{ .op_id = .{ .counter = 1, .actor = 2 }, .anchor = .fromStr("d"), .v = .{ .str = "d0" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 2, .actor = 2 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 2, .actor = 2 }, .anchor = .fromStr("d"), .v = .{ .str = "d1" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 3, .actor = 2 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 3, .actor = 2 }, .anchor = .fromStr("d"), .v = .{ .str = "d2" } },
    // ── Register "list": the op that makes object L, and so the only row
    // of the root that names a non-root object.
    .{ .op_id = .{ .counter = 6, .actor = 0 }, .anchor = .fromStr("list"), .act = .make_list },
    // ── Register "n": a counter and the increment that raises it. The
    // increment is a row, an increment is never visible, and the counter is
    // both top and visible (`index.rs:178-194`, `:170-176`).
    .{ .op_id = .{ .counter = 4, .actor = 0 }, .anchor = .fromStr("n"), .v = .{ .counter = .init(5) }, .succs = &.{.{ .counter = 7, .actor = 0 }}, .incs = &.{@as(?i64, 2)} },
    .{ .op_id = .{ .counter = 7, .actor = 0 }, .anchor = .fromStr("n"), .act = .increment, .v = .{ .int = 2 }, .is_visible = false, .is_top = false, .units = 0 },
    // ── Object L, element 8@0: an insert, then two overwrites, each
    // superseding the row before it, so the last of the three is the
    // element's only visible row and its winner.
    .{ .op_id = .{ .counter = 8, .actor = 0 }, .parent = list_obj, .anchor = .fromElemId(.head()), .does_insert = true, .v = .{ .str = "x" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 9, .actor = 0 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 9, .actor = 0 }, .parent = list_obj, .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 8, .actor = 0 })), .v = .{ .str = "y" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 10, .actor = 0 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 10, .actor = 0 }, .parent = list_obj, .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 8, .actor = 0 })), .v = .{ .str = "z" } },
    // ── Object L, element 11@0: an insert and two overwrites, every one of
    // them deleted, so the register has no top op — and it is the last
    // register of the last object, which is what makes the top walk run to
    // the end of its range.
    .{ .op_id = .{ .counter = 11, .actor = 0 }, .parent = list_obj, .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 8, .actor = 0 })), .does_insert = true, .v = .{ .str = "w" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 12, .actor = 0 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 12, .actor = 0 }, .parent = list_obj, .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 11, .actor = 0 })), .v = .{ .str = "v" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 13, .actor = 0 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 13, .actor = 0 }, .parent = list_obj, .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 11, .actor = 0 })), .v = .{ .str = "u" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 14, .actor = 0 }}, .incs = &.{null} },
};

/// The root map's rows: everything before object L.
const root_rows: RowRange = .{ .start = 0, .end = 12 };
/// Object L's rows.
const list_rows: RowRange = .{ .start = 12, .end = doc.len };
/// The whole op set.
const all_rows: RowRange = .{ .start = 0, .end = doc.len };

/// The rows of `range` that are visible under `clock`, read one at a time
/// through [`op.Op.scopeToClock`] — the answer with no skip arithmetic in it
/// at all, and the oracle the two walks are compared against.
///
/// The per-op rule rather than [`isVisible`], deliberately: it reads a
/// materialised row instead of three column cursors, so it is a third
/// implementation of the same rule and not the cheap-column one restated.
/// Upstream's own oracle for a scoped read is the per-op rule
/// (`visible.rs:167-169`, `OpSet::iter_range` handing `VisibleOpIter` a
/// plain `OpIter`).
fn perRowVisible(
    fx: *Fixture,
    range: RowRange,
    clock: ?Clock,
    scratch: []SuccEntry,
    gpa: std.mem.Allocator,
) !std.ArrayList(usize) {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    var walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), range, scratch);
    while (try walk.next()) |row| {
        // `scopeToClock` takes the row by pointer because it rewrites a
        // counter's value (`visible.rs:215-222`) and the walk hands rows
        // out as `*const Op`; the copy is the one `VisibleOpIter.next`
        // makes for the same reason (`:488`).
        var op = row;
        if (op.isInc()) continue;
        if (op.scopeToClock(clock)) try out.append(gpa, op.pos);
    }
    return out;
}

/// The visible rows of `range`, as absolute positions, from a walk that
/// answers with skip counts. A `null` answer ends the list; the final skip
/// to the end of the window is a real answer and is not counted as a row.
fn positionsFromSkips(
    gpa: std.mem.Allocator,
    comptime W: type,
    walk: *W,
    range: RowRange,
) !std.ArrayList(usize) {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    var at = range.start;
    while (try walk.next()) |skip| {
        at += skip;
        if (at >= range.end) break;
        try out.append(gpa, at);
        at += 1;
    }
    return out;
}

/// The rows of `col` whose value is `true`, read one at a time.
fn bruteTrue(
    gpa: std.mem.Allocator,
    col: *const opcols.BoolColumn,
    range: RowRange,
) !std.ArrayList(usize) {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    var it = try col.iterRange(range);
    var at = range.start;
    while (try it.next()) |v| {
        if (v) try out.append(gpa, at);
        at += 1;
    }
    return out;
}

/// A clock that covers every op in `rows` — every row *and* every
/// successor id any of them names.
///
/// This is the one clock under which the indexed walk and the scan walk are
/// required to agree: `index.visible` says a row has no deleting successor,
/// and a clock that covers all of them says the same thing. A clock built
/// from the rows' own ids alone would not do — a delete op is never stored
/// as a row (`columns.rs:423-427`), so its id appears in no row's `id`
/// column, and a clock built that way would not cover it and the scan walk
/// would report a deleted row as alive.
fn coveringClock(gpa: std.mem.Allocator, rows: []const Row) !Clock {
    var c = try Clock.init(gpa, 3);
    errdefer c.deinit();
    for (rows) |r| {
        const id = r.id();
        _ = c.include(id.actor, id.counter);
        for (0..r.succCount()) |k| {
            const succ = r.succAt(k);
            _ = c.include(succ.actor, succ.counter);
        }
    }
    return c;
}

/// A clock that stops part-way: all of actor 0's ops up to its sixth, actor
/// 1's first two, and actor 2's first.
///
/// Over [`doc`] that is what makes a scoped read answer differently from an
/// unscoped one. Actor 1's second op survives — the op that deletes it,
/// `4@1`, is not in the clock — so register "c" is alive again. Actor 2's
/// second and third ops are not in it, so register "d" falls back to its
/// first put. And every op in object L is `8@0` or later, which is past
/// actor 0's sixth, so the clock sees an object that had not been made.
fn partialClock(gpa: std.mem.Allocator) !Clock {
    var c = try Clock.init(gpa, 3);
    errdefer c.deinit();
    _ = c.include(0, 6);
    _ = c.include(1, 2);
    _ = c.include(2, 1);
    return c;
}

fn expectPositions(got: []const usize, want: []const usize) !void {
    if (got.len != want.len) {
        std.debug.print("got {d} rows {any}\nwant {d} rows {any}\n", .{
            got.len, got, want.len, want,
        });
        return error.TestUnexpectedResult;
    }
    for (got, want) |g, w| try testing.expectEqual(w, g);
}

test "the fixture is in row order, so the walks it drives are reading a real op set" {
    // Every other test here would pass on a fixture whose rows are out of
    // order, because a walk over rows does not care what order they are in.
    // `Op.step` is the row-order invariant in executable form
    // (`op_set2/op.rs:1048-1073`; `op.zig`), and the op set checks it after
    // every apply (`batch.rs:949`) and on every loaded document
    // (`storage/document.rs:332-344`).
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var scratch: [4]SuccEntry = undefined;
    var walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), all_rows, &scratch);

    var stepper = opmod.OpStepper.initial();
    var seen: usize = 0;
    while (try walk.next()) |op| {
        if (!op.step(&stepper)) {
            std.debug.print("row {d} does not follow the one before it\n", .{op.pos});
            return error.TestUnexpectedResult;
        }
        seen += 1;
    }
    try testing.expectEqual(doc.len, seen);
}

test "both flavours of a visibility walk find the same rows" {
    // The load-bearing property of `VisIter`: the choice between the two
    // flavours is a performance dispatch, so under a clock that covers
    // every op they must answer identically. Compared row for row, against
    // each other and against the index column read one row at a time.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var clock = try coveringClock(gpa, &doc);
    defer clock.deinit();
    var scratch: [4]SuccEntry = undefined;

    var indexed = try IndexedVisIter(Row).init(&fx.cols, all_rows);
    var scan = try ScanVisIter(Row).init(&fx.cols, all_rows, clock, &scratch);
    var from_indexed = try positionsFromSkips(gpa, IndexedVisIter(Row), &indexed, all_rows);
    defer from_indexed.deinit(gpa);
    var from_scan = try positionsFromSkips(gpa, ScanVisIter(Row), &scan, all_rows);
    defer from_scan.deinit(gpa);
    var from_column = try bruteTrue(gpa, &fx.cols.index.visible, all_rows);
    defer from_column.deinit(gpa);

    try expectPositions(from_indexed.items, from_scan.items);
    try expectPositions(from_indexed.items, from_column.items);
    // And the answer is not trivially "every row" or "no rows", so the
    // comparison above is comparing something.
    try testing.expect(from_indexed.items.len > 1);
    try testing.expect(from_indexed.items.len < doc.len);
}

test "an unscoped walk and a scoped walk over the same op set answer differently" {
    // `VisIter::new` sends a null clock to the indexed walk and a clock to
    // the scan (`visible.rs:59-67`), and the two are not the same question.
    // A clock that stops after actor 2's first op and actor 1's first op
    // un-deletes register "c" and moves register "d"'s winner up the
    // register.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var clock = try partialClock(gpa);
    defer clock.deinit();
    var scratch: [4]SuccEntry = undefined;

    var unscoped = try VisIter(Row).init(&fx.cols, null, root_rows, &scratch);
    var scoped = try VisIter(Row).init(&fx.cols, clock, root_rows, &scratch);
    // The dispatch itself: a null clock is the indexed walk and a clock is
    // the scan, and this is what "load-bearing" means.
    try testing.expect(switch (unscoped.inner) {
        .indexed => true,
        .scan => false,
    });
    try testing.expect(switch (scoped.inner) {
        .indexed => false,
        .scan => true,
    });

    var now = try positionsFromSkips(gpa, VisIter(Row), &unscoped, root_rows);
    defer now.deinit(gpa);
    var then = try positionsFromSkips(gpa, VisIter(Row), &scoped, root_rows);
    defer then.deinit(gpa);

    // The present: registers "a" (both survivors), "b", "d", "list" and the
    // counter "n". Register "c" is entirely deleted, so it contributes
    // nothing.
    try expectPositions(now.items, &.{ 1, 2, 3, 8, 9, 10 });
    // The past: "c" is alive because its deleting successors are not in the
    // clock, "d"'s winner is its first put because the later two are not in
    // the clock, and the counter is alive but the increment is not in it.
    try expectPositions(then.items, &.{ 1, 2, 3, 4, 6, 9, 10 });
    // And the two really are different, which is the point of the pair.
    if (std.mem.eql(usize, now.items, then.items)) {
        std.debug.print("a scoped read answered the same as an unscoped one\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "the cheap-column rule and the per-op rule agree on every row" {
    // `isVisible` and `Op.scopeToClock` are the same rule written twice — one
    // over three cheap columns, one over a materialised row. If they ever
    // disagree the document reads back plausibly and wrong, so this checks
    // them against each other row by row, under both clocks, over the whole
    // op set, and not only over the rows that happen to be visible.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var full = try coveringClock(gpa, &doc);
    defer full.deinit();
    var partial = try partialClock(gpa);
    defer partial.deinit();
    var scratch: [4]SuccEntry = undefined;

    const scoped = [_]Clock{ full, partial };
    const as_maybe = [_]?Clock{ full, partial };
    for (scoped, as_maybe) |c, maybe_c| {
        var walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), all_rows, &scratch);
        var scan = try ScanVisIter(Row).init(&fx.cols, all_rows, c, &scratch);
        for (0..doc.len) |i| {
            const cheap = (try scan.nextVisible()) orelse {
                std.debug.print("the scan ran out at row {d} of {d}\n", .{ i, doc.len });
                return error.TestUnexpectedResult;
            };
            const op = (try walk.next()) orelse {
                std.debug.print("the walk ran out at row {d} of {d}\n", .{ i, doc.len });
                return error.TestUnexpectedResult;
            };
            const want = if (op.isInc()) false else op.maybeScopeToClock(maybe_c).visible();
            if (cheap != want) {
                std.debug.print("row {d} (id {d}@{d}): cheap {any}, per-op {any}\n", .{
                    op.pos, op.id().counter, op.id().actor, cheap, want,
                });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "VisibleOpIter skips increments and rows the clock does not cover" {
    // `visible.rs:180-192`: skip an increment outright, then hand the row to
    // the scoped rule. Over the whole op set, so the object boundary is
    // crossed too.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var scratch: [4]SuccEntry = undefined;

    {
        const walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), all_rows, &scratch);
        var ids: std.ArrayList(usize) = .empty;
        defer ids.deinit(gpa);
        var out = VisibleOpIter(op_iter.OpIter(Row)).init(walk, null);
        while (try out.next()) |op| try ids.append(gpa, packedId(op.id()));
        // Every visible row, as `counter * 4 + actor` so that two rows with
        // the same counter and different actors cannot be confused for one
        // another. Both survivors of register "a" are here, so the filter is
        // not dropping conflicts; the increment at `7@0` is not.
        try expectPositions(ids.items, &.{ 5, 8, 12, 14, 24, 16, 40 });
    }
    {
        var clock = try partialClock(gpa);
        defer clock.deinit();
        const walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), all_rows, &scratch);
        var ids: std.ArrayList(usize) = .empty;
        defer ids.deinit(gpa);
        var out = VisibleOpIter(op_iter.OpIter(Row)).init(walk, clock);
        while (try out.next()) |op| try ids.append(gpa, packedId(op.id()));
        // Register "c" is alive again (`2@1`) and register "d" has fallen
        // back to its first put (`1@2`), while `3@2` is not in the clock. And
        // no row of object L appears at all: the clock stops at actor 0's
        // sixth op and every op in L is `8@0` or later, so a scoped read of
        // a list that had not been made yet sees an empty list.
        try expectPositions(ids.items, &.{ 5, 8, 12, 9, 6, 24, 16 });
    }
}

/// An op id as one integer, `counter * 4 + actor`, so a test can compare a
/// list of ids with a list literal and still tell two actors apart. Every id
/// in these fixtures is below `2^30`, so the packing cannot collide.
fn packedId(id: OpId) usize {
    return @as(usize, id.counter) * 4 + @as(usize, id.actor);
}

test "a scoped read rewrites a counter to the total its clock saw" {
    // `scope_to_clock` folds the increments the clock covers into the row's
    // value (`visible.rs:196-213`, `:215-222`; `op.zig`), so the same row
    // reads 7 in the present and 5 in a past state that predates the
    // increment. Both rows are the register's top op, so
    // `VisibleOpIter` is what surfaces them.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var clock = try partialClock(gpa);
    defer clock.deinit();
    var scratch: [4]SuccEntry = undefined;

    // The present: 5 + 2.
    {
        const walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), root_rows, &scratch);
        var out = VisibleOpIter(op_iter.OpIter(Row)).init(walk, null);
        var saw = false;
        while (try out.next()) |op| {
            if (op.id().counter != 4 or op.id().actor != 0) continue;
            try testing.expectEqual(@as(i64, 7), op.value().counter.current);
            saw = true;
        }
        try testing.expect(saw);
    }
    // The past: the increment at 7@0 is not in the clock, so it stays 5.
    {
        const walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), root_rows, &scratch);
        var out = VisibleOpIter(op_iter.OpIter(Row)).init(walk, clock);
        var saw = false;
        while (try out.next()) |op| {
            if (op.id().counter != 4 or op.id().actor != 0) continue;
            try testing.expectEqual(@as(i64, 5), op.value().counter.current);
            saw = true;
        }
        try testing.expect(saw);
    }
    // And the fold is the one `fixCounter` does: on a row nothing has
    // rewritten yet, the two agree unscoped and scoped. `fixCounter` is the
    // same walk with the deleted arm ignored, and they share it
    // (`op.zig`, `foldSuccIncs`), so this is a check that the sharing holds
    // and not that two sums match.
    {
        var scratch2: [4]SuccEntry = undefined;
        var walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), root_rows, &scratch2);
        const covers = [_]?Clock{ null, clock };
        for (covers) |c| {
            while (try walk.next()) |op| {
                if (op.id().counter != 4 or op.id().actor != 0) continue;
                var folded = op;
                folded.fixCounter(c);
                const want = op.maybeScopeToClock(c).counter_value orelse return error.TestUnexpectedResult;
                try testing.expectEqual(want, folded.value().counter.current);
            }
            walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), root_rows, &scratch2);
        }
    }
}

test "a visibility walk allocates nothing to construct" {
    // `plan.md` §3: an iterator is a value, and this slice's walks are paid
    // for on every walk of every object. The instrument is the op set's own
    // allocator: the columns are built through a counting wrapper, so any
    // allocation a walk constructor makes — a re-encoded slab, a copied
    // window — shows up in the count. Upstream's `ScanVisIter::new` clones
    // the clock (`visible.rs:112`); the port borrows it, so a scan walk here
    // is one fewer allocation than it would be there.
    const gpa = testing.allocator;
    var counter = Counting{ .inner = gpa };
    var fx = try Fixture.init(counter.allocator(), &doc);
    defer fx.deinit();
    var clock = try coveringClock(counter.allocator(), &doc);
    defer clock.deinit();
    var scratch: [4]SuccEntry = undefined;

    const built = counter.count;

    var indexed = try IndexedVisIter(Row).init(&fx.cols, all_rows);
    var scan = try ScanVisIter(Row).init(&fx.cols, all_rows, clock, &scratch);
    var vis = try VisIter(Row).init(&fx.cols, clock, all_rows, &scratch);
    const walk = try op_iter.OpIter(Row).init(&fx.cols, fx.strings(), all_rows, &scratch);
    var ops = VisibleOpIter(op_iter.OpIter(Row)).init(walk, clock);
    try testing.expectEqual(built, counter.count);

    // And nothing on the way through the walk allocates either: the successor
    // buffer is the caller's, which is the rule `SuccIterIter` states and the
    // reason that type takes a slice rather than an allocator.
    try testing.expectEqual(@as(?usize, 1), try indexed.next());
    try testing.expectEqual(@as(?usize, 1), try scan.next());
    try testing.expectEqual(@as(?usize, 1), try vis.next());
    try testing.expect((try ops.next()) != null);
    try testing.expectEqual(built, counter.count);
}

/// Rows for the slab-boundary fixture, plus the map keys and the successor
/// ids they borrow.
///
/// The keys have to outlive the splice, which copies them into the
/// document's string table but reads them from the row first
/// (`columns.zig:1254-1257`), so they are owned here and freed by
/// [`Phases.deinit`].
///
/// The successor ids are owned here for the same reason and one more: a
/// row's `succs` is a *slice*, and `&.{id}` written inside a loop is a
/// pointer to that iteration's stack frame, which the next iteration
/// overwrites. Every deleted row would then name the same successor — the
/// last one written — and the `succ_ctr` column would be spliced from ids
/// no row declared. The ids go in a buffer allocated once, at its final
/// size, which is never reallocated, so a slice into it is valid for the
/// life of the fixture. The 18-row [`doc`] does not need this: its
/// `succs` are comptime-known, so `&.{…}` is a constant and not a frame.
const Phases = struct {
    rows: std.ArrayList(Row),
    keys: std.ArrayList([]u8),
    /// One slot per row that has a successor, handed out in row order.
    succ_ids: []OpId,
    /// The next free slot of `succ_ids`.
    succ_at: usize,

    fn deinit(self: *Phases, gpa: std.mem.Allocator) void {
        for (self.keys.items) |k| gpa.free(k);
        self.keys.deinit(gpa);
        gpa.free(self.succ_ids);
        self.rows.deinit(gpa);
    }

    /// A one-element successor list owned by `succ_ids`.
    ///
    /// A fixture that asks for more slots than it declared is
    /// `error.TestUnexpectedResult` rather than a slice past the end.
    fn oneSucc(self: *Phases, id: OpId) ![]const OpId {
        if (self.succ_at >= self.succ_ids.len) return error.TestUnexpectedResult;
        const slot = self.succ_ids[self.succ_at..][0..1];
        slot[0] = id;
        self.succ_at += 1;
        return slot;
    }
};

/// A zero-padded map key, so the keys ascend as byte strings — which is what
/// rule R2 asks of a map's registers (`op_set2/op.rs:1059-1060`) — and owned
/// by `keys`.
fn phaseKey(
    gpa: std.mem.Allocator,
    keys: *std.ArrayList([]u8),
    index: usize,
) ![]const u8 {
    const key = try std.fmt.allocPrint(gpa, "k{d:0>3}", .{index});
    errdefer gpa.free(key);
    try keys.append(gpa, key);
    return key;
}

/// `regs` map registers of two rows each: the first put superseded by the
/// second, which wins. `top` and `visible` are `false, true` per register,
/// so every row is a run of its own. The rows are returned; their keys and
/// their successor ids go into `phases`, which owns both.
fn alternatingRegisters(
    gpa: std.mem.Allocator,
    phases: *Phases,
    first_ctr: usize,
    key_base: usize,
    regs: usize,
) !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(gpa);
    var next: usize = first_ctr;
    for (0..regs) |i| {
        const key = try phaseKey(gpa, &phases.keys, key_base + i);
        const a: OpId = .{ .counter = @intCast(next), .actor = 0 };
        const b: OpId = .{ .counter = @intCast(next + 1), .actor = 0 };
        next += 2;
        try rows.append(gpa, .{
            .op_id = a,
            .anchor = .fromStr(key),
            .v = .{ .int = @intCast(i) },
            .is_visible = false,
            .is_top = false,
            .succs = try phases.oneSucc(b),
            .incs = &.{null},
        });
        try rows.append(gpa, .{
            .op_id = b,
            .anchor = .fromStr(key),
            .v = .{ .int = @intCast(i) },
        });
    }
    return rows;
}

/// The op set for the slab-boundary fixture.
///
/// One splice, and that is the whole point of the shape. A slab holds about
/// `slab.default_max_segments` (64) segments — one per value here — and a
/// splice that carries more than the budget cuts at it
/// (`hexane/slab.zig:85-91`; `column.zig:3103`), so a bulk write spreads the
/// column over several slabs. A series of small appends does not: the probe
/// lands in the last slab and nothing is cut, which is why this is one
/// `Columns.splice` and not 300. The bulk path is real — a batched insert
/// writes a whole change's rows at once (`transaction/inner.rs:1517`).
///
/// The first [`deletedRows`] rows are 400 map registers of one row each, and
/// every one of them deleted, so `top` and `visible` are `false` for 400 rows
/// running: one run several slabs long, so however the cut falls it falls
/// inside it. A register whose only row is deleted is legal — that is the
/// group `validate_top_index` allows with `first_top` and `last_vis` both
/// null (`op_set.rs:196-206`) — and it is a shape a document really has:
/// hundreds of keys each written once and then deleted.
///
/// After them come [`alternatingRegs`] ordinary registers of two rows, so the
/// walk has winners to find behind the boundary as well as in front of it.
fn slabFixture(gpa: std.mem.Allocator) !Phases {
    var keys: std.ArrayList([]u8) = .empty;
    errdefer {
        for (keys.items) |k| gpa.free(k);
        keys.deinit(gpa);
    }
    // One successor for each deleted row and one for each alternating
    // register: `Columns.splice` flattens them in row order
    // (`columns.zig:1014-1025`), so this is exactly the number of ids the
    // fixture hands out.
    const succ_ids = try gpa.alloc(OpId, deletedRows + alternatingRegs);
    errdefer gpa.free(succ_ids);
    var phases: Phases = .{
        .rows = .empty,
        .keys = keys,
        .succ_ids = succ_ids,
        .succ_at = 0,
    };
    errdefer phases.rows.deinit(gpa);
    for (0..deletedRows) |i| {
        try phases.rows.append(gpa, .{
            .op_id = .{ .counter = @intCast(1 + i), .actor = 0 },
            .anchor = .fromStr(try phaseKey(gpa, &phases.keys, i)),
            .v = .{ .int = @intCast(i) },
            .is_visible = false,
            .is_top = false,
            // Deleted by an op that is not a row, which is what a delete is
            // (`columns.rs:423-427`).
            .succs = try phases.oneSucc(.{ .counter = @intCast(1001 + i), .actor = 0 }),
            .incs = &.{null},
        });
    }
    var rest = try alternatingRegisters(gpa, &phases, 1 + deletedRows, deletedRows, alternatingRegs);
    defer rest.deinit(gpa);
    try phases.rows.appendSlice(gpa, rest.items);
    return phases;
}

/// How many leading rows the fixture makes invisible, which is what makes the
/// run long enough to be longer than a slab whatever the cut is.
const deletedRows: usize = 400;

/// How many two-row registers follow them.
const alternatingRegs: usize = 100;

/// The first slab boundary of `col` that falls strictly inside a run of equal
/// values, or null when there is none.
///
/// The case `Column.Iterator.nextRun` has to step across rather than stop at
/// (`column.rs:591-616`; the port's `nextRunMax`, `column.zig:3641-3659`):
/// the layout is only canonical *inside* a slab, so the same value can sit on
/// both sides of a boundary and has to come back as one run with one count.
fn boundaryInsideRun(col: anytype) ParseError!?usize {
    var before: usize = 0;
    for (0..col.slabCount() -| 1) |i| {
        before += col.slabAt(i).?.len;
        const left = (try col.get(before - 1)) orelse continue;
        const right = (try col.get(before)) orelse continue;
        if (left == right) return before;
    }
    return null;
}

/// That the run holding `at` is a run of at least `count` rows, which is what
/// the cross-slab merge in `nextRun` buys: without it the run the boundary
/// cuts comes back as two runs of one, and the count is wrong.
fn runHolds(col: anytype, at: usize, count: usize) ParseError!bool {
    var start: usize = 0;
    var it = try col.iterRange(.{ .start = 0, .end = col.len() });
    while (try it.nextRun()) |run| {
        if (at >= start and at < start + run.count) return run.count >= count;
        start += run.count;
    }
    return false;
}

/// The exact sequence of skips a walk over `range` must produce, read out
/// of `col` one row at a time and with no skip arithmetic in it at all.
///
/// This is the oracle the skippers are held to, and it is compared as the
/// raw sequence rather than as the positions it leads to: a position list is
/// unchanged by a skip that is one too small and the next one too large, so
/// it cannot see a walk whose `cursor` is out by a run's length — which is
/// the only thing a slab boundary can break, because `nextRun` hands the
/// caller a count and the caller owns the arithmetic
/// (`iter/tools.rs:343-352`).
fn skipOracle(
    gpa: std.mem.Allocator,
    col: anytype,
    range: RowRange,
) !std.ArrayList(usize) {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    var at = range.start;
    // Whether the last answer stood on a `true`, which is what decides
    // whether one more answer follows it: a skipper always answers once
    // more after its last `true`, with the distance to the end of the
    // window, which is zero when it is already there
    // (`iter/tools.rs:373-381`).
    var on_true = false;
    while (at < range.end) {
        var skip: usize = 0;
        while (at < range.end) : (skip += 1) {
            const v = (try col.get(at)) orelse return error.InvalidValue;
            if (v) break;
            at += 1;
        }
        try out.append(gpa, skip);
        if (at >= range.end) {
            on_true = false;
            break;
        }
        at += 1;
        on_true = true;
    }
    if (on_true) try out.append(gpa, 0);
    return out;
}

/// The skips `walk` produces, unturned into anything.
fn rawSkips(
    gpa: std.mem.Allocator,
    comptime W: type,
    walk: *W,
) !std.ArrayList(usize) {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    while (try walk.next()) |skip| try out.append(gpa, skip);
    return out;
}

test "a walk over a column spread over several slabs reports the walk's own skips" {
    // The indexed walk steps over the `visible` column run at a time
    // (`iter/tools.rs:343-352`) and keeps its own `cursor` and `range_end`
    // beside the column cursor (`column.zig:4085-4136`). A slab boundary is
    // the one place that arithmetic can go wrong: `nextRun` answers with a
    // count, the walk turns it into a skip, and the next call has to be
    // measured from where the count left it. So the fixture is a column
    // spread over several slabs, and the walk is compared against an oracle
    // that reads the values one row at a time — as the *raw skip sequence*,
    // because a position list is unchanged by a skip that is one too small
    // and the next one too large.
    //
    // The same fixture also holds the two flavours of the visibility walk
    // to each other, because the dispatch between them
    // (`VisIter::new`, `visible.rs:59-67`) is a performance choice and the
    // two must answer the same rows — the property
    // `test "both flavours of a visibility walk find the same rows"` states
    // on the 18-row fixture. At this size the check is worth more, not
    // less: the 400 deleted rows each carry one successor the clock covers,
    // so a scan walk that read those successors as empty would report all
    // 600 rows visible where the index column reports 100, and the only
    // thing that would catch it is a scan walk over a successor column
    // long enough to be interesting.
    //
    // **What this test is not.** Upstream's `nextRun` has a cross-slab merge
    // for a run that spans two slabs (`column.rs:591-616`; the port's
    // `nextRunMax`, `column.zig:3641-3659`), and that case cannot be built
    // through `Columns.splice`: the slab budget counts *segments*
    // (`column.zig:3070`), a segment is a run (`slab.zig:85-91`), and
    // `splitToBudget` cuts at a segment boundary. A run of any length is
    // therefore one segment and is never divided — measured, not assumed:
    // 200, 400, 600 and 1000 leading `false`s all give a first slab of
    // `falses + 63` rows and 64 segments, with the cut past the run.
    // [`boundaryInsideRun`] is the check for the other side of that, and it
    // runs as the premise below.
    const gpa = testing.allocator;
    var phases = try slabFixture(gpa);
    defer phases.deinit(gpa);
    const all: RowRange = .{ .start = 0, .end = phases.rows.items.len };

    var fx = try Fixture.init(gpa, phases.rows.items);
    defer fx.deinit();
    var clock = try coveringClock(gpa, phases.rows.items);
    defer clock.deinit();
    // Sized the way `SuccIterIter` says to size it: the widest row's
    // successor count over the walked range, which here is one, because
    // every row that has a successor has exactly one.
    var scratch: [1]SuccEntry = undefined;
    try testing.expectEqual(@as(usize, 1), try op_iter.maxSuccCount(Row, &fx.cols, all));

    // The premise: the column is spread over several slabs, and no slab
    // boundary falls inside a run.
    try testing.expect(fx.cols.index.visible.slabCount() > 1);
    try testing.expect(fx.cols.index.top.slabCount() > 1);
    try testing.expect(try boundaryInsideRun(&fx.cols.index.visible) == null);
    // And the fixture really does carry the deletes the second half rests
    // on: `deletedRows + alternatingRegs` successors, distinct, in row
    // order. Without this the scan walk and the clock could be built from
    // one set of ids and the columns from another and still agree with each
    // other, which is exactly what a `&.{id}` in a loop does — it hands
    // every row a pointer to the same reused stack slot, so the splice and
    // the clock see whatever was written there last.
    try testing.expectEqual(deletedRows + alternatingRegs, fx.cols.succ_ctr.len());
    try testing.expectEqual(@as(i64, @intCast(1001)), (try fx.cols.succ_ctr.get(0)).?);
    try testing.expectEqual(@as(i64, @intCast(1001 + deletedRows - 1)), (try fx.cols.succ_ctr.get(deletedRows - 1)).?);
    try testing.expectEqual(@as(i64, @intCast(2 + deletedRows)), (try fx.cols.succ_ctr.get(deletedRows)).?);

    var oracle = try skipOracle(gpa, &fx.cols.index.visible, all);
    defer oracle.deinit(gpa);
    var indexed = try IndexedVisIter(Row).init(&fx.cols, all);
    var skips = try rawSkips(gpa, IndexedVisIter(Row), &indexed);
    defer skips.deinit(gpa);
    try expectPositions(skips.items, oracle.items);

    // And the rows it finds are the rows the column holds, read one at a
    // time — the same rows the scan walk finds, and the same rows the
    // per-op rule finds one row at a time with no skip arithmetic in it at
    // all. Three independent answers, compared row for row.
    var indexed2 = try IndexedVisIter(Row).init(&fx.cols, all);
    var from_indexed = try positionsFromSkips(gpa, IndexedVisIter(Row), &indexed2, all);
    defer from_indexed.deinit(gpa);
    var from_column = try bruteTrue(gpa, &fx.cols.index.visible, all);
    defer from_column.deinit(gpa);
    var scan = try ScanVisIter(Row).init(&fx.cols, all, clock, &scratch);
    var from_scan = try positionsFromSkips(gpa, ScanVisIter(Row), &scan, all);
    defer from_scan.deinit(gpa);
    var from_per_row = try perRowVisible(&fx, all, clock, &scratch, gpa);
    defer from_per_row.deinit(gpa);

    try expectPositions(from_indexed.items, from_column.items);
    try expectPositions(from_indexed.items, from_scan.items);
    try expectPositions(from_indexed.items, from_per_row.items);
    // One winner per surviving register, and none of the 400 deleted ones.
    // This is the count the scan walk has to reach and not pass: all 600
    // visible is what a scan walk answers when its successor cursor comes
    // back empty, and the deleted rows are the only thing in the fixture
    // that can tell the two apart.
    try testing.expectEqual(@as(usize, 100), from_indexed.items.len);
    try testing.expectEqual(@as(usize, 100), from_scan.items.len);
    // And the 400 rows the cut runs through are not winners: the boundary is
    // inside the block of deleted rows, so every winner is past it.
    try testing.expect(from_indexed.items[0] > deletedRows);
}
