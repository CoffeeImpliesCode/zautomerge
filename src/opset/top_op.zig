//! The register winners: which row of each key a read sees as the value.
//!
//! Upstream `op_set2/op_set/top_op.rs`, 360 lines, owns:
//!
//! | what | upstream |
//! |------|----------|
//! | [`TopOps`], the winner iterator | `:18-24`, `:44-65` |
//! | [`TopIter`] and its `Current`/`Scan` flavours | `:143-268` |
//! | [`ScanTopIter`] and [`ScanTopRow`] | `:238-327` |
//!
//! # The winner of a register
//!
//! A register is one map key or one list element, and its ops are
//! contiguous in the op set ([`op.Op.step`], `op_set2/op.rs:1048-1073`).
//! Its winner is its highest-id row that nothing has deleted — the highest
//! row with no successor, which is what `IndexBuilder::flush` marks in the
//! `top` column (`index.rs:170-176`). Every read of a document goes through
//! this: `Automerge::keys`, `list_range`, `map_range`, `spans`, `hydrate`
//! and every patch (`op_set.rs:378`, `automerge.rs:1604`, `:1703`, `:1959`).
//! Get it wrong and the document reads back plausibly.
//!
//! # `Current` and `Scan` again
//!
//! The same dispatch as [`visible.VisIter`], for the same reason: `index.top`
//! answers for the present and only a scan over the cheap columns can answer
//! for a past state. Unscoped, the `Current` flavour reads a boolean column
//! run at a time; scoped, the `Scan` flavour re-derives the winner from
//! visibility under the clock.
//!
//! # The scan flavour's range must be one object
//!
//! Upstream states it and does not enforce it (`top_op.rs:158-160`):
//!
//! > The range must be scoped to a single object: the scan flavor detects
//! > group boundaries from inserts and `key_str` changes alone, which cannot
//! > distinguish equal map keys across an object boundary.
//!
//! The port **enforces** it. The reason upstream gives is the row-order
//! invariant, rule **R2** ([`op.Op.step`], `op_set2/op.rs:1059-1060`,
//! `:1084-1088`): within one object rows group by register, map registers
//! ascend by key string and sequence registers by element id, and a `Map` row
//! and a `Seq` row are **never** adjacent — `KeyRef::order` has no answer for
//! the cross case (`types.rs:584-592`) and `step`'s `_ => false` arm turns
//! that into a rejection. So one object is all-map or all-sequence, and the
//! two boundary rules are exact inside it. Across an object boundary they
//! are not: two objects that both hold key `"a"` look like one group, and
//! the scan refuses that with `error.InvalidIndex` rather than returning
//! one object's winner for the other. The check is [`checkOneObject`], run on
//! the two ends of every range [`ScanTopIter`] is given or shifted onto, and
//! a per-row check behind it. Only the scan flavour can see the boundary —
//! `index.top` carries no object — so only it checks, which is what the test
//! says.
//!
//! # Constructing one of these allocates nothing
//!
//! [`TopScratch`] is the caller's, sized once by [`topScratch`] and freed by
//! [`TopScratch.deinit`]; every other field is a column cursor, a `Clock` the
//! caller owns, or a number. `test "a top walk allocates nothing to
//! construct"` counts every allocation that goes through a wrapper the op set
//! itself was built with.
//!
//! # The two assertions upstream makes
//!
//! [`TopOps.next`] carries both of them (`top_op.rs:50-56`):
//!
//! ```text
//! let skip = self.visible.next().expect("a top op must also be visible");
//! let pos = self.visible_pos + skip;
//! self.visible_pos = pos + 1;
//! assert!(pos <= op.pos, "visible op at {pos} advanced past top op at {}");
//! ```
//!
//! **Both are `InternalError`, not `ParseError`.** They are not properties of
//! the loaded bytes: the `top` and `visible` index columns are derived state
//! and are never loaded from a document — a load rebuilds them
//! (`columns.rs:314`, `storage/document.rs:332-344`) — and `top ⇒ visible` is
//! maintained by the code that writes them, which always clears the pair
//! together (`columns.rs:277-281`, `:300-304`) and asserts it
//! (`columns.rs:114`, `op_set.rs:206`). A violation is this port's index
//! bookkeeping being wrong, which is exactly what
//! [`error.InternalError`](../../src/error.zig) is for
//! (`error.zig:159-179`). The `orelse` arm is additionally guarded by
//! [`op_iter.checkRowLengths`], which [`op_iter.OpIter.init`] calls inside
//! [`TopOps.init`] and which refuses an index column that does not cover
//! every row (`op_iter.zig:1328-1330`); it is kept because the alternative is
//! a silent truncation.
//!
//! # What is not here
//!
//! * `assert_matches_slow` and `SlowTopOpIter` (`top_op.rs:74-141`). They are
//!   `#[cfg(feature = "slow_path_assertions")]` invariant checkers that
//!   drive the same question as `test "the indexed and the scanned top walk
//!   agree"` from the other side, so the property is held here by a test
//!   rather than by a second iterator.
//! * `FixCounters` (`top_op.rs:33`, `op_query.rs:78-84`). Upstream wraps the
//!   row walk in it; its whole body is `op.fix_counter(clock); Some(op)`
//!   (`op_query.rs:98-101`), which is already [`op.Op.fixCounter`], so
//!   [`TopOps.next`] calls it on the row it has just taken. `op_query.zig`
//!   owns the named wrapper for the callers that want one.
//! * `SkipIter` (`top_op.rs:32-35`, `iter/tools.rs:141-182`). Its `next` is
//!   `let skip = self.skip.next()?; if skip == 0 { self.iter.next() } else
//!   { self.iter.nth(skip) }` — and `OpIter.tryNth` is `nth`, port for port
//!   (`op_iter.rs:128-155`, `:191-193`), so [`TopOps.next`] inlines the two
//!   lines rather than wrapping the walk in a second type. **The inline takes
//!   the `nth` arm for a zero skip as well**, where [`tools.SkipIter`] takes
//!   `next` ([`iter/tools.rs:179-183`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
//!   The two answers are the same row — `OpIter.next` and `OpIter.tryNth(0)`
//!   are both partial and both answer null past the end — so this is a
//!   difference in which entry point is called, not in what is read. It is
//!   left as it is because the port's `TopIter` is a *skipper* rather than a
//!   field, and wrapping the pair in `tools.SkipIter` would mean giving
//!   `TopOps` a third borrowed walk for one `next`.

const std = @import("std");
const err = @import("../error.zig");
const clocks = @import("../clock.zig");
const types = @import("../types.zig");
const column = @import("../hexane/column.zig");
const optypes = @import("types.zig");
const opcols = @import("columns.zig");
const opmod = @import("op.zig");
const op_iter = @import("op_iter.zig");
const vis = @import("visible.zig");
const tools = @import("../iter/tools.zig");

const Action = optypes.Action;
const ElemId = types.ElemId;
const Allocator = std.mem.Allocator;
const KeyRef = optypes.KeyRef;
const OpId = types.OpId;
const ObjId = types.ExId;
const Op = opmod.Op;
const StringTable = opcols.StringTable;
const SuccEntry = opmod.SuccEntry;
const Clock = clocks.Clock;

const RowRange = column.RowRange;
const ParseError = err.ParseError;

/// What a top-op walk can fail with: a column read
/// ([`op_iter.ReadOpError`], which carries [`ParseError`]), a range that is
/// not one object's ([`error.Error`]), or an invariant this walk maintains
/// ([`error.InternalError`]).
const TopError = op_iter.ReadOpError || err.Error || err.InternalError;

/// The running sum of a prefix column at `row`, as an index into the column
/// it is a prefix *of* — see [`visible`]'s own copy, and upstream's inline
/// use at `op_set.rs:1301`.
fn prefixAt(col: anytype, row: usize) ParseError!usize {
    const sum = try col.getPrefix(row);
    if (sum < 0) return error.InvalidValue;
    return std.math.cast(usize, sum) orelse error.InvalidValue;
}

// ── One row, reduced to what topness needs ─────────────────────────────────

/// One op reduced to what topness needs: where its group starts and whether
/// it is visible (`ScanTopRow`, `top_op.rs:320-327`).
///
/// `key_str` is the interned id the port's string table gives rather than
/// the bytes upstream holds (`plan.md` §5.3 interns `key_str`), and the two
/// are the same test: two ids are equal exactly when the strings they name
/// are, because a table interns each string once. The group boundary
/// comparison is therefore unchanged.
pub const ScanTopRow = struct {
    /// The row, as an absolute position in the op set (`top_op.rs:322`).
    pos: usize,
    /// The `insert` column: a row that opens a group (`top_op.rs:323`).
    insert: bool,
    /// The interned `key_str` the group boundary is detected from
    /// (`top_op.rs:324`).
    key_str: ?u32,
    /// Whether the row is visible under the walk's clock
    /// (`top_op.rs:325`, and the rule at `:352-359`).
    visible: bool,
};

// ── The scan flavour ───────────────────────────────────────────────────────

/// The object the row at `at` names, from the two object columns
/// (`ObjIdIter::try_next`, `op_iter.rs:625-635`).
///
/// Through the cursor rather than the columns, because a nullable column's
/// `get` answers `ParseError!(??T)` and unpicking that by hand is the kind
/// of thing that goes wrong quietly. Both halves null is the root, and so is
/// a counter of zero whatever the actor column says
/// (`op_iter.zig:217-219`, `:227`).
fn objectAt(
    comptime C: type,
    cols: *const C,
    window: RowRange,
    at: usize,
) TopError!ObjId {
    var probe = op_iter.ObjIdIter.init(
        try cols.obj_actor.iterRange(window),
        try cols.obj_ctr.iterRange(window),
    );
    // `advanceTo` leaves the cursor *on* `at`, so `tryNth(0)` reads it.
    try probe.advanceTo(at - window.start);
    return probe.tryNth(0);
}

/// That `window` is one object's rows, or `error.InvalidIndex`.
///
/// The precondition [`TopIter`]'s scan flavour carries
/// (`top_op.rs:158-160`), enforced at the two ends of the range rather than
/// on the first row that crosses a boundary, so a caller is told where it
/// made the mistake instead of part-way through an answer.
///
/// Two reads and no walk, because the two ends agreeing is *exactly* the
/// range being one object: object ids strictly ascend and an object's rows
/// are contiguous — rule **R1**, `op_set2/op.rs:1049-1054` — and the two
/// object columns sorting by object is what makes them so
/// (`op_set.rs:1246-1250`). An empty range is one object's vacuously.
fn checkOneObject(
    comptime C: type,
    cols: *const C,
    window: RowRange,
) TopError!void {
    if (window.end <= window.start) return;
    const first = try objectAt(C, cols, window, window.start);
    const last = try objectAt(C, cols, window, window.end - 1);
    if (!last.eql(first)) return error.InvalidIndex;
}

/// The six cheap columns [`TopIter`]'s scan flavour reads, one row at a
/// time (`ScanTopIter`, `top_op.rs:238-327`).
///
/// `insert` and `key_str` find the group boundaries, `id`/`action`/`succ`
/// decide visibility under the clock, and `obj` enforces the single-object
/// precondition. Nothing here reads a value, a mark or a key anchor, which
/// is the whole cost argument for the scan: a scoped read must not decode
/// the payloads.
pub fn ScanTopIter(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set the walk reads.
        pub const Ops = opcols.Columns(O);

        /// The `Shiftable` conformance mark: this is a multi-column row
        /// cursor, so it carries the full kernel ([`column.Shiftable`]) and
        /// the object step of a walk can be repositioned into a child object
        /// without allocating.
        pub const shiftable = column.Shiftable(Self);

        /// The column set the walk reads, for the single-object check a
        /// shift has to redo.
        cols: *const Ops,
        /// The clock the read is scoped to, borrowed from the caller.
        clock: Clock,
        /// The object the range's first row named, and every row after it
        /// must name the same one. Null until the first row is read, and
        /// null again after a shift, which is the object step.
        owner: ?ObjId,
        /// The two halves of each row's own id (`top_op.rs:244`).
        id: op_iter.OpIdIter,
        /// `key_str`, the interned map key (`top_op.rs:243`).
        key_str: opcols.UintOptColumn.Iterator,
        /// `insert` (`top_op.rs:245`).
        insert: op_iter.InsertIter,
        /// `action` (`top_op.rs:246`).
        action: op_iter.ActionIter,
        /// `obj_actor`/`obj_ctr`, which the single-object check reads
        /// (`op_set.rs:1246-1250`: the two columns that sort by object are
        /// what make an object's rows contiguous).
        obj: op_iter.ObjIdIter,
        /// `succ_count` and the three flattened successor columns
        /// (`top_op.rs:247`).
        succ: op_iter.SuccIterIter,

        /// A walk over the rows of `rows`, scoped to `clock`
        /// (`ScanTopIter::new`, `top_op.rs:258-268`).
        ///
        /// `scratch` is the caller's successor buffer; size it with
        /// [`op_iter.maxSuccCount`] and see [`op_iter.SuccIterIter`]. The
        /// two prefix positions are read before anything moves
        /// (`op_set.rs:1301`, `:1280-1281`).
        ///
        /// `error.InvalidIndex` when `rows` is not one object's — see
        /// [`checkOneObject`], which is the enforcement of the precondition
        /// at `top_op.rs:158-160`.
        pub fn init(
            cols: *const Ops,
            rows: RowRange,
            clock: Clock,
            scratch: []SuccEntry,
        ) TopError!Self {
            const window = column.clampRange(rows, cols.len());
            try checkOneObject(Ops, cols, window);
            const succ_start = try prefixAt(&cols.succ_count, window.start);
            return .{
                .cols = cols,
                .clock = clock,
                .owner = null,
                .id = op_iter.OpIdIter.init(
                    try cols.id_actor.iterRange(window),
                    try cols.id_ctr.iterRange(window),
                ),
                .key_str = try cols.key_str.iterRange(window),
                .insert = op_iter.InsertIter.init(try cols.insert.iterRange(window)),
                .action = op_iter.ActionIter.init(try cols.action.iterRange(window)),
                .obj = op_iter.ObjIdIter.init(
                    try cols.obj_actor.iterRange(window),
                    try cols.obj_ctr.iterRange(window),
                ),
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
            };
        }

        /// The row the next `next` returns.
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
            self.key_str.setMax(at);
            self.insert.setMax(at);
            self.action.setMax(at);
            self.obj.setMax(at);
            self.succ.setMax(at);
        }

        /// Advances so the next `next` is the row at `target`. A target at
        /// or behind the cursor is a no-op.
        pub fn advanceTo(self: *Self, target: usize) ParseError!void {
            try self.id.advanceTo(target);
            try self.key_str.advanceTo(target);
            try self.insert.advanceTo(target);
            try self.action.advanceTo(target);
            try self.obj.advanceTo(target);
            try self.succ.advanceTo(target);
        }

        /// Advances past `amount` rows.
        pub fn advanceBy(self: *Self, amount: usize) ParseError!void {
            return self.advanceTo(self.pos() +| amount);
        }

        /// Repositions the window to `rows`, leaving the cursor on its start.
        pub fn shift(self: *Self, rows: RowRange) void {
            self.id.shift(rows);
            self.key_str.shift(rows);
            self.insert.shift(rows);
            self.action.shift(rows);
            self.obj.shift(rows);
            self.succ.shift(rows);
        }

        /// Repositions onto `rows` and reads the row at its start
        /// (`top_op.rs:317-327`).
        ///
        /// A `rows` that starts behind the cursor cannot be served —
        /// repositioning only moves forward (`shift.rs:14-18`) — so it is
        /// `error.InvalidValue`, checked *before* anything moves so a refused
        /// shift leaves the walk where it was.
        pub fn shiftNext(self: *Self, rows: RowRange) TopError!?ScanTopRow {
            if (rows.start < self.pos()) return error.InvalidValue;
            // The precondition is per *range*, not per walk: stepping from
            // one object to the next is what the shift is for, so the check
            // is redone on the new range and the remembered object is
            // dropped. A new range that spans two objects is refused the
            // same way a constructor refuses one.
            try checkOneObject(Ops, self.cols, rows);
            self.owner = null;
            const at = rows.start;
            const id = (try self.id.shiftNext(rows)) orelse return null;
            const key_str = (try self.key_str.shiftNext(rows)) orelse return null;
            const insert = (try self.insert.shiftNext(rows)) orelse return null;
            const action = (try self.action.shiftNext(rows)) orelse return null;
            const obj = (try self.obj.shiftNext(rows)) orelse return null;
            const succ = (try self.succ.shiftNext(rows)) orelse return null;
            try self.checkOwner(obj);
            return self.row(at, id, key_str, insert, action, succ);
        }

        /// Consumes through `at` and reads the row there, or null when `at`
        /// is behind the walk.
        pub fn seekTo(self: *Self, at: usize) TopError!?ScanTopRow {
            if (at < self.pos()) return null;
            try self.advanceTo(at);
            return self.next();
        }

        /// The next row, or null at the end of the window
        /// (`Iterator for ScanTopIter`, `top_op.rs:330-341`).
        ///
        /// A row that names a different object from the first is
        /// `error.InvalidIndex`: the range is not scoped to one object, which
        /// the group boundary rules below cannot survive
        /// (`top_op.rs:158-160`).
        pub fn next(self: *Self) TopError!?ScanTopRow {
            const at = self.pos();
            const id = (try self.id.maybeTryNext()) orelse return null;
            const key_str = (try self.key_str.next()) orelse return error.MissingValue;
            const insert = try self.insert.tryNext();
            const action = try self.action.tryNext();
            const obj = try self.obj.tryNext();
            const succ = try self.succ.tryNext();
            try self.checkOwner(obj);
            return self.row(at, id, key_str, insert, action, succ);
        }

        /// The row the six column values make, judged against the clock
        /// (`ScanTopIter::row`, `top_op.rs:293-310`).
        fn row(
            self: *const Self,
            at: usize,
            id: OpId,
            key_str: ?u32,
            insert: bool,
            action: Action,
            succ: opmod.SuccCursors,
        ) ScanTopRow {
            return .{
                .pos = at,
                .insert = insert,
                .key_str = key_str,
                .visible = vis.isVisible(id, action, succ, self.clock),
            };
        }

        /// Records the first row's object and refuses any other
        /// (`error.InvalidIndex`).
        ///
        /// The check is here rather than at construction because it is
        /// O(1) per row and the cost of a wrong answer is one object's
        /// winner standing for another's. The error is
        /// `Error.InvalidIndex` — the document API's "this position does not
        /// address the object it was scoped to" — because a range is only
        /// ever built by `OpSet::scope_to_obj`
        /// (`op_set.rs:1085-1087`, `:1246-1250`), so a multi-object range is
        /// a caller's mistake about a range, not a property of the bytes.
        fn checkOwner(self: *Self, obj: ObjId) err.Error!void {
            if (self.owner) |want| {
                if (!obj.eql(want)) return error.InvalidIndex;
                return;
            }
            self.owner = obj;
        }
    };
}

/// Whether `row` continues the group `group` began with
/// (`iter.next_if(|r| !r.insert && r.key_str == group_key)`,
/// `top_op.rs:250`).
///
/// **The predicate [`tools.PeekShift.nextIf`] is handed, and the reason it is
/// a named function is the one that type documents**: Zig cannot hand a
/// capture to a function pointer, and what decides a group boundary is
/// `!insert && key_str == group_key` — a value beside the row, not a closure
/// over it.
fn continuesGroup(row: ScanTopRow, group: ?u32) bool {
    return !row.insert and row.key_str == group;
}

// ── The two flavours ───────────────────────────────────────────────────────

/// Where the winners are in a range: a `Skipper` which yields runs of
/// non-top ops, so a walk can jump from one register's winner to the next
/// (`TopIter`, `top_op.rs:143-268`).
///
/// Like [`vis.VisIter`] it comes in two flavours. `Current` reads the `top`
/// index column directly (`top_op.rs:212-215`); `Scan` recomputes topness
/// under a historical [`Clock`] from the cheap columns only
/// (`top_op.rs:208-211`).
///
/// **`Scan`'s range must be scoped to a single object**, and this type's
/// module doc says why with the row-order invariant as the reason. `Scan`
/// enforces it; `Current` cannot, because a boolean column carries no
/// object, and does not need to: it finds every top row in whatever range it
/// is given, and a range that spans two objects answers with both objects'
/// winners, which is a defined answer rather than a wrong one.
pub fn TopIter(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set the walk reads.
        pub const Ops = opcols.Columns(O);

        /// The scan flavour, one row at a time.
        pub const Scan = ScanTopIter(O);
        /// The scan flavour behind a lookahead, because the row that terminates
        /// one group is the first row of the next
        /// (`top_op.rs:169-171`; [`tools.PeekShift`](../../iter/tools.zig)).
        ///
        /// **Why not [`column.Unshift`](../hexane/column.zig), which is the same
        /// shape.** That type's reads are `ParseError` throughout, because its
        /// only user is `CtrWalker`, whose reads really are `ParseError` and
        /// nothing else. A scan of the top walk raises `ReadOpError` as well —
        /// a column that ran out before the walk did — and
        /// `Error.InvalidIndex` on top of that, so it cannot sit behind a
        /// `ParseError`-shaped wrapper, and widening `Unshift` would put an
        /// op-set error set in a hexane type. `tools.PeekShift` infers the set
        /// from the walk it wraps ([`tools.ErrorOf`](../iter/tools.zig)), so
        /// `TopError` arrives without anyone naming it.
        pub const Peek = tools.PeekShift(Scan);

        /// The skipper over the `top` index column, which is a *prefix*
        /// column and not the plain one [`visible.VisIter`] reads
        /// (`columns.rs:40`).
        const Current = column.BoolColumnSkipper(opcols.BoolPrefixCodec);

        /// The rows this walk covers, clamped to the op set
        /// (`iter_range`, `hexane/src/column.rs:1384-1421`).
        rows: RowRange,
        /// The row after the last winner found, which every skip is measured
        /// from (`top_op.rs:146`, `:261-263`).
        cursor: usize,
        /// Whether the walk has been walked out, so `next` answers null
        /// rather than the final skip again (`top_op.rs:147`, `:224-226`).
        spent: bool,
        inner: union(enum) {
            current: Current,
            scan: Peek,
        },

        /// The winners of `rows`, as skips (`TopIter::new`,
        /// `top_op.rs:178-196`).
        ///
        /// `scratch` is the scan flavour's successor buffer and is not read
        /// by `Current`; see [`ScanTopIter.init`]. `rows` is clamped to the
        /// op set once, here, because the final skip is arithmetic on it.
        pub fn init(
            cols: *const Ops,
            clock: ?Clock,
            rows: RowRange,
            scratch: []SuccEntry,
        ) TopError!Self {
            const window = column.clampRange(rows, cols.len());
            if (clock) |c| {
                return .{
                    .rows = window,
                    .cursor = window.start,
                    .spent = false,
                    // `PeekShift.init` reads nothing, so it cannot fail and
                    // needs no `try` of its own; the first read is the `next`
                    // below, which is where upstream's lazy `peek` puts it
                    // (`iter/tools.rs:78-80`).
                    .inner = .{ .scan = Peek.init(try Scan.init(cols, window, c, scratch)) },
                };
            }
            return .{
                .rows = window,
                .cursor = window.start,
                .spent = false,
                .inner = .{ .current = Current.init(try cols.index.top.iterRange(window), window.end) },
            };
        }

        /// The distance to the next winner, or null once the range is walked
        /// out (`Iterator for TopIter`, `top_op.rs:217-268`).
        ///
        /// The last answer before exhaustion is the distance to the end of
        /// the range, and it is a `Some`: a consumer pairing this walk with
        /// another has to be able to learn that *this* one is done
        /// ([`TopOps.next`]).
        ///
        /// A winner cannot be behind `cursor`, because `cursor` is the row
        /// after the previous winner and the rows ascend (rule **R3**,
        /// `op_set2/op.rs:1056-1057`). Upstream's `pos.checked_sub(cursor)?`
        /// (`top_op.rs:262`) cannot answer in that case either; the port
        /// raises `error.Invariant` rather than dropping the winner, because
        /// dropping one is the failure mode a silent `null` would hide.
        pub fn next(self: *Self) TopError!?usize {
            if (self.spent) return null;
            switch (self.inner) {
                .current => |*c| return try c.next(),
                .scan => |*s| {
                    while (true) {
                        const first = (try s.next()) orelse {
                            self.spent = true;
                            const skip = self.rows.end -| self.cursor;
                            self.cursor = self.rows.end +| 1;
                            return skip;
                        };
                        // a group is one map key or one list element; its ops
                        // are contiguous, and the next group starts at the
                        // next insert op (list element or mark) or `key_str`
                        // change (map key) — `top_op.rs:246-257`, and the
                        // single-object precondition is what makes those two
                        // rules exact.
                        const group = first.key_str;
                        var top: ?usize = if (first.visible) first.pos else null;
                        while (try s.nextIf(group, continuesGroup)) |row| {
                            if (row.visible) top = row.pos;
                        }
                        if (top) |pos| {
                            if (pos < self.cursor) return error.Invariant;
                            const skip = pos - self.cursor;
                            self.cursor = pos + 1;
                            return skip;
                        }
                    }
                },
            }
        }

        /// Repositions the walk to `rows` and yields the distance to the
        /// first winner in it (`Shiftable for TopIter`, `top_op.rs:194-215`).
        ///
        /// A `Skipper` is an iterator of skips, not a row cursor
        /// (`iter/tools.rs:60-62`), so it carries `shiftNext` and not the
        /// full kernel — the same shape as the boolean skipper it is built
        /// from (`column.zig:4085-4155`).
        pub fn shiftNext(self: *Self, rows: RowRange) TopError!?usize {
            self.cursor = rows.start;
            self.rows = rows;
            self.spent = false;
            switch (self.inner) {
                .current => |*c| return try c.shiftNext(rows),
                .scan => |*s| {
                    try s.shift(rows);
                    if (try s.peek() != null) return try self.next();
                    self.spent = true;
                    return rows.end -| rows.start;
                },
            }
        }
    };
}

// ── The successor buffers ──────────────────────────────────────────────────

/// The three successor buffers [`TopOps`] needs, all the caller's
/// (`top_op.rs:30-35`: a row walk, a [`vis.VisIter`] and a [`TopIter`], each
/// holding a [`op_iter.SuccIterIter`]).
///
/// They are three and not one because the three walks are alive at the same
/// time and each `SuccCursors` borrows the buffer it was read into. The row
/// walk's is the one that must not be shared with anything at all: the
/// [`Op`] [`TopOps.next`] hands back points its successors there, so it has
/// to stay valid and unoverwritten until the caller asks for the next row —
/// the rule [`op_iter.OpIter`] states for the buffer it is given.
///
/// Every buffer must hold at least [`op_iter.maxSuccCount`] entries. Size
/// them with [`topScratch`] and free them with [`TopScratch.deinit`].
pub const TopScratch = struct {
    /// For the row walk's successors.
    rows: []SuccEntry,
    /// For the visibility walk's.
    visible: []SuccEntry,
    /// For the top walk's. Unread unscoped, when that walk is `Current`.
    top: []SuccEntry,

    /// Frees the three buffers.
    pub fn deinit(self: TopScratch, gpa: Allocator) void {
        gpa.free(self.rows);
        gpa.free(self.visible);
        gpa.free(self.top);
    }
};

/// Three successor buffers, each as wide as the widest row of `rows` needs
/// (`op_iter.maxSuccCount`, `op_iter.rs:1391`).
///
/// One pass over `succ_count` and three allocations. The walk constructors
/// take none, which is what `test "a top walk allocates nothing to
/// construct"` measures.
///
/// The op type comes first because the column set is what determines it,
/// which is the order [`op_iter.maxSuccCount`] takes too
/// (`op_iter.zig:1386`); the allocator is the first *runtime* parameter.
pub fn topScratch(
    comptime O: type,
    gpa: Allocator,
    cols: *const opcols.Columns(O),
    rows: RowRange,
) ParseError!TopScratch {
    const n = try op_iter.maxSuccCount(O, cols, rows);
    const rows_buf = try gpa.alloc(SuccEntry, n);
    errdefer gpa.free(rows_buf);
    const visible_buf = try gpa.alloc(SuccEntry, n);
    errdefer gpa.free(visible_buf);
    const top_buf = try gpa.alloc(SuccEntry, n);
    errdefer gpa.free(top_buf);
    return .{ .rows = rows_buf, .visible = visible_buf, .top = top_buf };
}

// ── The winner iterator ────────────────────────────────────────────────────

/// The winners of an object's registers, in row order, each with its
/// counter rewritten and its conflict flag set (`TopOps`, `top_op.rs:18-24`,
/// `:44-65`).
///
/// A skip iterator finds the winners and a row walk materialises them; the
/// two are kept in step by construction, and the two upstream assertions in
/// [`next`] are the check that they stayed in step.
pub fn TopOps(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set the walk reads.
        pub const Ops = opcols.Columns(O);

        /// The rows, one at a time (`top_op.rs:29`).
        walk: op_iter.OpIter(O),
        /// Where the winners are (`top_op.rs:28`).
        top: TopIter(O),
        /// Where the visible rows are, for the conflict flag and for the
        /// assertion that a winner is visible (`top_op.rs:30`).
        visible: vis.VisIter(O),
        /// The row the next visible skip is measured from (`top_op.rs:31`).
        visible_pos: usize,
        /// The clock the read is scoped to, borrowed from the caller.
        clock: ?Clock,

        /// A walk over the winners of `rows`
        /// (`TopOps::new`, `top_op.rs:26-42`).
        ///
        /// `rows` is clamped to the op set once, here, and the clamped value
        /// is what all three walks are built over, so they cannot disagree
        /// about where the range ends. `scratch` is the caller's three
        /// successor buffers; see [`TopScratch`].
        pub fn init(
            cols: *const Ops,
            strings: StringTable,
            rows: RowRange,
            clock: ?Clock,
            scratch: TopScratch,
        ) TopError!Self {
            const window = column.clampRange(rows, cols.len());
            return .{
                .walk = try op_iter.OpIter(O).init(cols, strings, window, scratch.rows),
                .top = try TopIter(O).init(cols, clock, window, scratch.top),
                .visible = try vis.VisIter(O).init(cols, clock, window, scratch.visible),
                .visible_pos = window.start,
                .clock = clock,
            };
        }

        /// The next register's winner, or null at the end of the range
        /// (`Iterator for TopOps`, `top_op.rs:44-65`).
        ///
        /// Three steps in upstream's order. The top walk says where the next
        /// winner is and the row walk reads that row, with the counter
        /// folded in by [`op.Op.fixCounter`] — `FixCounters`
        /// (`op_query.rs:78-84`). Then the visible walk is advanced until it
        /// reaches that row, and every visible row it stepped over inside
        /// the register is a conflict the winner lost to, which is what
        /// `op.conflict` says (`op_set.rs:62`, read by `hydrate.rs:254`).
        ///
        /// Two upstream assertions guard the pairing, and both are
        /// `error.Invariant`; this type's module doc argues why they are not
        /// `ParseError` and why neither is a silent wrong answer.
        pub fn next(self: *Self) TopError!?Op {
            // `SkipIter::next` (`iter/tools.rs:174-182`): ask the skipper
            // where the next winner is, then step the row walk onto it.
            // `OpIter.tryNth` is upstream's `nth` (`op_iter.rs:191-193`),
            // which answers null past the end of the walk — so a final skip
            // that lands past the last row is the end of the range and not
            // an error.
            const skip = (try self.top.next()) orelse return null;
            var op = (try self.walk.tryNth(skip)) orelse return null;
            op.fixCounter(self.clock);
            var conflict = false;
            while (true) {
                const skipped = (try self.visible.next()) orelse return error.Invariant;
                const pos = self.visible_pos + skipped;
                self.visible_pos = pos + 1;
                if (pos > op.pos) return error.Invariant;
                if (pos == op.pos) break;
                conflict = true;
            }
            op.conflict = conflict;
            return op;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A row as a fixture declares it: the op-type accessors
/// [`opcols.Columns`] calls, and nothing else. The same shape
/// `columns.zig`, `op_iter.zig` and `visible.zig` each use for their own
/// tests.
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

const Cols = opcols.Columns(Row);

/// A spliced op set plus the table its strings are interned in.
const Fixture = struct {
    cols: Cols,
    table: Table,

    fn init(gpa: Allocator, rows: []const Row) !Fixture {
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
    inner: Allocator,
    count: usize = 0,

    fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
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
/// demands. The root map's registers, in ascending key order: `a`, `b`, `c`,
/// `d`, `list`, `n`. Object `L`'s registers: element `8@0` and element
/// `11@0`.
///
/// The same fixture as `visible.zig`'s, for the same reason: the two files
/// answer different questions about the same op set, and a reader that
/// wants both has to be able to believe both.
const doc = [_]Row{
    // ── Register "a": one put, then two concurrent ones that both survive.
    // Both are visible with no successors, so the register has a live
    // conflict and its winner is the higher id.
    .{ .op_id = .{ .counter = 1, .actor = 0 }, .anchor = .fromStr("a"), .v = .{ .int = 1 }, .is_visible = false, .is_top = false, .succs = &.{ .{ .counter = 1, .actor = 1 }, .{ .counter = 2, .actor = 0 } }, .incs = &.{ null, null } },
    .{ .op_id = .{ .counter = 1, .actor = 1 }, .anchor = .fromStr("a"), .v = .{ .int = 10 }, .is_top = false },
    .{ .op_id = .{ .counter = 2, .actor = 0 }, .anchor = .fromStr("a"), .v = .{ .int = 2 } },
    // ── Register "b": a single winner and nothing else.
    .{ .op_id = .{ .counter = 3, .actor = 0 }, .anchor = .fromStr("b"), .v = .{ .str = "b0" } },
    // ── Register "c": both rows deleted, so the register has no visible row
    // and no winner. `validate_top_index` allows a group in exactly that
    // state — its `first_top` and `last_vis` are both null, so the
    // `assert_eq!(first_top, last_vis)` at the group boundary passes
    // (`op_set.rs:196-206`).
    .{ .op_id = .{ .counter = 2, .actor = 1 }, .anchor = .fromStr("c"), .v = .{ .str = "c0" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 3, .actor = 1 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 3, .actor = 1 }, .anchor = .fromStr("c"), .v = .{ .str = "c1" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 4, .actor = 1 }}, .incs = &.{null} },
    // ── Register "d": three puts by one actor, so a clock that stops after
    // the first sees a different winner than one that sees all three.
    .{ .op_id = .{ .counter = 1, .actor = 2 }, .anchor = .fromStr("d"), .v = .{ .str = "d0" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 2, .actor = 2 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 2, .actor = 2 }, .anchor = .fromStr("d"), .v = .{ .str = "d1" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 3, .actor = 2 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 3, .actor = 2 }, .anchor = .fromStr("d"), .v = .{ .str = "d2" } },
    // ── Register "list": the op that makes object L.
    .{ .op_id = .{ .counter = 6, .actor = 0 }, .anchor = .fromStr("list"), .act = .make_list },
    // ── Register "n": a counter and the increment that raises it. The
    // counter is both top and visible; the increment is neither.
    .{ .op_id = .{ .counter = 4, .actor = 0 }, .anchor = .fromStr("n"), .v = .{ .counter = .init(5) }, .succs = &.{.{ .counter = 7, .actor = 0 }}, .incs = &.{@as(?i64, 2)} },
    .{ .op_id = .{ .counter = 7, .actor = 0 }, .anchor = .fromStr("n"), .act = .increment, .v = .{ .int = 2 }, .is_visible = false, .is_top = false, .units = 0 },
    // ── Object L, element 8@0: an insert, then two overwrites, each
    // superseding the row before it, so the last of the three is the
    // element's only visible row and its winner.
    .{ .op_id = .{ .counter = 8, .actor = 0 }, .parent = list_obj, .anchor = .fromElemId(.head()), .does_insert = true, .v = .{ .str = "x" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 9, .actor = 0 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 9, .actor = 0 }, .parent = list_obj, .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 8, .actor = 0 })), .v = .{ .str = "y" }, .is_visible = false, .is_top = false, .succs = &.{.{ .counter = 10, .actor = 0 }}, .incs = &.{null} },
    .{ .op_id = .{ .counter = 10, .actor = 0 }, .parent = list_obj, .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 8, .actor = 0 })), .v = .{ .str = "z" } },
    // ── Object L, element 11@0: an insert and two overwrites, every one of
    // them deleted, so the register has no winner — and it is the last
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

/// A clock that covers every op in `rows` — every row *and* every successor
/// id any of them names, since a delete op is never stored as a row
/// (`columns.rs:423-427`).
fn coveringClock(gpa: Allocator, rows: []const Row) !Clock {
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
/// 1's first two, and actor 2's first. Under it register "c" is alive,
/// register "d" resolves to its first put, and object L has not been made.
fn partialClock(gpa: Allocator) !Clock {
    var c = try Clock.init(gpa, 3);
    errdefer c.deinit();
    _ = c.include(0, 6);
    _ = c.include(1, 2);
    _ = c.include(2, 1);
    return c;
}

/// An op id as one integer, `counter * 4 + actor`, so a test can compare a
/// list of ids with a list literal and still tell two actors apart.
fn packedId(id: OpId) usize {
    return @as(usize, id.counter) * 4 + @as(usize, id.actor);
}

/// The winners a [`TopOps`] walk yields, as `counter * 4 + actor`, and
/// whether each won a conflict.
const Yield = struct {
    id: usize,
    conflict: bool,
};

fn collect(gpa: Allocator, out: *std.ArrayList(Yield), walk: *TopOps(Row)) !void {
    while (try walk.next()) |op| {
        try out.append(gpa, .{ .id = packedId(op.id()), .conflict = op.conflict });
    }
}

/// Two `usize` slices, element by element, with a message that says which
/// element and what both held. `expectEqualSlices` would do, but the walk
/// answers are long and a bare index is useless without the values.
fn expectSlices(got: []const usize, want: []const usize) !void {
    if (got.len != want.len) {
        std.debug.print("got {d} values {any}\nwant {d} values {any}\n", .{
            got.len, got, want.len, want,
        });
        return error.TestUnexpectedResult;
    }
    for (got, want, 0..) |g, w, i| {
        if (g != w) {
            std.debug.print("value {d}: got {d}, want {d}\n", .{ i, g, w });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectYields(got: []const Yield, want: []const Yield) !void {
    if (got.len != want.len) {
        std.debug.print("got {d} winners, want {d}\n", .{ got.len, want.len });
        for (got, 0..) |g, i| {
            std.debug.print("  {d}: id {d} (ctr {d}@{d}) conflict {any}\n", .{
                i, g.id, g.id / 4, g.id % 4, g.conflict,
            });
        }
        return error.TestUnexpectedResult;
    }
    for (got, want, 0..) |g, w, i| {
        if (g.id != w.id or g.conflict != w.conflict) {
            std.debug.print("winner {d}: got id {d} (ctr {d}@{d}) conflict {any}, want id {d} conflict {any}\n", .{
                i, g.id, g.id / 4, g.id % 4, g.conflict, w.id, w.conflict,
            });
            return error.TestUnexpectedResult;
        }
    }
}

/// The winners of a range, as skip counts turned into absolute positions, so
/// the two flavours of [`TopIter`] can be compared as position lists rather
/// than as skip counts. A `null` ends the list; the final skip to the end of
/// the range is a real answer and is not a position.
fn topPositions(
    gpa: Allocator,
    comptime T: type,
    walk: *T,
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

test "a register's winner is its highest-id visible row" {
    // The property every map lookup, list element, text span and patch
    // depends on. Over the root map: register "a" has three rows and two
    // live survivors, so its winner is the highest of them and it is flagged
    // as a conflict; "b" is a single row; "c" has no live row at all and
    // contributes nothing; "d" resolves to its last put; "list" and the
    // counter "n" each contribute their one row.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var scratch = try topScratch(Row, gpa, &fx.cols, root_rows);
    defer scratch.deinit(gpa);

    var walk = try TopOps(Row).init(&fx.cols, fx.strings(), root_rows, null, scratch);
    var got: std.ArrayList(Yield) = .empty;
    defer got.deinit(gpa);
    try collect(gpa, &got, &walk);
    try expectYields(got.items, &.{
        // "a": 2@0 beats 1@1 because ids order by counter first
        // (`types.rs:439-443`), and 1@1 is still alive, so it is a conflict.
        .{ .id = 8, .conflict = true },
        .{ .id = 12, .conflict = false },
        // "c" is absent: every row is deleted.
        // "d": 3@2.
        .{ .id = 14, .conflict = false },
        // "list": 6@0.
        .{ .id = 24, .conflict = false },
        // "n": the counter, folded to 5 + 2 by `fix_counter`.
        .{ .id = 16, .conflict = false },
    });

    // The counter is the one row whose value the walk rewrites, and it is
    // rewritten to the total the clock saw.
    var walk2 = try TopOps(Row).init(&fx.cols, fx.strings(), root_rows, null, scratch);
    var saw = false;
    while (try walk2.next()) |op| {
        if (op.id().counter != 4 or op.id().actor != 0) continue;
        try testing.expectEqual(@as(i64, 7), op.value().counter.current);
        saw = true;
    }
    try testing.expect(saw);
}

test "a register whose rows are all deleted contributes no top op" {
    // Register "c" and the list's last element both have every row deleted,
    // so neither has a winner: `validate_top_index` allows a group with no
    // top row exactly when it has no visible row (`op_set.rs:196-206`).
    // The map case and the sequence case are separate rows of the same
    // fixture because they fail differently — a map register in the middle
    // of the range, and a sequence register at the very end of it, which is
    // where the top walk runs out of winners.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var scratch = try topScratch(Row, gpa, &fx.cols, list_rows);
    defer scratch.deinit(gpa);

    // The list: element 8@0 contributes its last overwrite and element
    // 11@0 contributes nothing, which is the whole of that object's read.
    var walk = try TopOps(Row).init(&fx.cols, fx.strings(), list_rows, null, scratch);
    var got: std.ArrayList(Yield) = .empty;
    defer got.deinit(gpa);
    try collect(gpa, &got, &walk);
    try expectYields(got.items, &.{
        .{ .id = 40, .conflict = false },
    });

    // And neither surviving element reports a conflict, which is what says
    // the deleted element did not leave a survivor behind.
    for (got.items) |y| try testing.expectEqual(false, y.conflict);
}

test "the indexed and the scanned top walk agree when the clock covers everything" {
    // The `Current`/`Scan` choice is a performance dispatch, so under a
    // clock that covers every op the two must find the same winners in the
    // same order. Compared as positions over both objects, and through
    // `TopOps` so the rows and the conflict flags are compared too.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var clock = try coveringClock(gpa, &doc);
    defer clock.deinit();

    for ([_]RowRange{ root_rows, list_rows }) |range| {
        var scratch = try topScratch(Row, gpa, &fx.cols, range);
        defer scratch.deinit(gpa);
        var current = try TopIter(Row).init(&fx.cols, null, range, scratch.top);
        var scan = try TopIter(Row).init(&fx.cols, clock, range, scratch.top);
        var from_current = try topPositions(gpa, TopIter(Row), &current, range);
        defer from_current.deinit(gpa);
        var from_scan = try topPositions(gpa, TopIter(Row), &scan, range);
        defer from_scan.deinit(gpa);
        try testing.expectEqualSlices(usize, from_current.items, from_scan.items);
        try testing.expect(from_current.items.len > 0);

        var indexed = try TopOps(Row).init(&fx.cols, fx.strings(), range, null, scratch);
        var scanned = try TopOps(Row).init(&fx.cols, fx.strings(), range, clock, scratch);
        var a: std.ArrayList(Yield) = .empty;
        defer a.deinit(gpa);
        var b: std.ArrayList(Yield) = .empty;
        defer b.deinit(gpa);
        try collect(gpa, &a, &indexed);
        try collect(gpa, &b, &scanned);
        try expectYields(a.items, b.items);
    }
}

test "a scoped top walk reads the winner the clock saw" {
    // The scan flavour's whole reason to exist. Under a clock that stops
    // after actor 1's second op and actor 2's first: register "c" is alive
    // and its winner is its first row, register "d" falls back to its first
    // put, and the counter's increment is not in the clock so the counter
    // reads 5 rather than 7.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var clock = try partialClock(gpa);
    defer clock.deinit();
    var scratch = try topScratch(Row, gpa, &fx.cols, root_rows);
    defer scratch.deinit(gpa);

    var walk = try TopOps(Row).init(&fx.cols, fx.strings(), root_rows, clock, scratch);
    var got: std.ArrayList(Yield) = .empty;
    defer got.deinit(gpa);
    var counter_value: i64 = 0;
    var saw_counter = false;
    while (try walk.next()) |op| {
        try got.append(gpa, .{ .id = packedId(op.id()), .conflict = op.conflict });
        if (op.id().counter == 4 and op.id().actor == 0) {
            counter_value = op.value().counter.current;
            saw_counter = true;
        }
    }
    try expectYields(got.items, &.{
        .{ .id = 8, .conflict = true },
        .{ .id = 12, .conflict = false },
        // "c" is alive again, and 2@1 is its only live row.
        .{ .id = 9, .conflict = false },
        // "d" falls back to its first put.
        .{ .id = 6, .conflict = false },
        .{ .id = 24, .conflict = false },
        .{ .id = 16, .conflict = false },
    });
    try testing.expect(saw_counter);
    try testing.expectEqual(@as(i64, 5), counter_value);
}

test "a range spanning more than one object is refused by the scan" {
    // The precondition at `top_op.rs:158-160`, enforced. The reason is the
    // row-order invariant's rule **R2**: a `Map` row and a `Seq` row can
    // never be adjacent in one object, so one object is all-map or all
    // sequence, and the two group-boundary rules — the next insert, or a
    // `key_str` change — are exact inside it. Across a boundary they are
    // not: rows 9 and 0 of this op set have `key_str` null and `"a"`
    // respectively, and the two objects hold one register each, so a scan
    // that ignored the boundary would answer with one object's winner
    // standing for the other.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var clock = try coveringClock(gpa, &doc);
    defer clock.deinit();
    var scratch = try topScratch(Row, gpa, &fx.cols, root_rows);
    defer scratch.deinit(gpa);
    const whole: RowRange = .{ .start = 0, .end = doc.len };

    try testing.expectError(
        error.InvalidIndex,
        TopIter(Row).init(&fx.cols, clock, whole, scratch.top),
    );
    try testing.expectError(
        error.InvalidIndex,
        TopOps(Row).init(&fx.cols, fx.strings(), whole, clock, scratch),
    );
    // A range inside one object is fine, and one that stops at the boundary
    // is fine: the check is on the second row of a range, not on its first.
    _ = try TopIter(Row).init(&fx.cols, clock, root_rows, scratch.top);
    _ = try TopIter(Row).init(&fx.cols, clock, list_rows, scratch.top);
    // And the indexed flavour is not the thing being refused: it reads a
    // boolean column that carries no object, so it cannot tell, and its
    // answer over a two-object range is both objects' winners rather than
    // one object's winner twice.
    var indexed = try TopIter(Row).init(&fx.cols, null, whole, scratch.top);
    var positions = try topPositions(gpa, TopIter(Row), &indexed, whole);
    defer positions.deinit(gpa);
    try testing.expectEqualSlices(usize, &.{ 2, 3, 8, 9, 10, 14 }, positions.items);
}

test "a top walk shifts into a later object and refuses to shift back" {
    // The shift is what lets a walk step into a child object mid-flight
    // without allocating, so it has to both work and refuse. Repositioning
    // only moves forward (`shift.rs:14-18`), and both flavours inherit that:
    // the `Current` one from the column cursor underneath it
    // (`column.zig:3601-3606`) and the `Scan` one from
    // `ScanTopIter.shiftNext`'s own check.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &doc);
    defer fx.deinit();
    var clock = try coveringClock(gpa, &doc);
    defer clock.deinit();
    var scratch = try topScratch(Row, gpa, &fx.cols, root_rows);
    defer scratch.deinit(gpa);

    // Both flavours, into object L — which is the object step, and the
    // precondition is per *range*, so crossing into the next object is what
    // the shift is for. The root's first winner is row 2, so the first skip
    // is 2; object L's only winner is row 14, so the shift answers 2 — the
    // two rows before it are not winners — and the walk is then out of
    // winners for the rest of the range, which is the skip to its end.
    {
        var walk = try TopIter(Row).init(&fx.cols, null, root_rows, scratch.top);
        try testing.expectEqual(@as(?usize, 2), try walk.next());
        try testing.expectEqual(@as(?usize, 2), try walk.shiftNext(list_rows));
        try testing.expectEqual(@as(?usize, 3), try walk.next());
        try testing.expect((try walk.next()) == null);
        try testing.expectError(error.InvalidValue, walk.shiftNext(root_rows));
    }
    // The scanned walk, the same shape, and it is the shape that has to
    // re-check the object across a shift.
    {
        var walk = try TopIter(Row).init(&fx.cols, clock, root_rows, scratch.top);
        try testing.expectEqual(@as(?usize, 2), try walk.next());
        try testing.expectEqual(@as(?usize, 2), try walk.shiftNext(list_rows));
        try testing.expectEqual(@as(?usize, 3), try walk.next());
        try testing.expect((try walk.next()) == null);
        try testing.expectError(error.InvalidValue, walk.shiftNext(root_rows));
    }
    // And the winners the row walk materialises are the ones the two blocks
    // above found, which is what `TopOps` is: a skip walk plus a row walk.
    {
        var walk = try TopOps(Row).init(&fx.cols, fx.strings(), root_rows, null, scratch);
        try testing.expectEqual(@as(usize, 2), (try walk.next()).?.pos);
        try testing.expectEqual(@as(usize, 3), (try walk.next()).?.pos);
        try testing.expectEqual(@as(usize, 8), (try walk.next()).?.pos);
        try testing.expectEqual(@as(usize, 9), (try walk.next()).?.pos);
        try testing.expectEqual(@as(usize, 10), (try walk.next()).?.pos);
        try testing.expect((try walk.next()) == null);
    }
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
    // The indexed flavour steps over the `top` column run at a time
    // (`iter/tools.rs:343-352`) and keeps its own `cursor` beside the column
    // cursor (`column.zig:4085-4136`). A slab boundary is the one place that
    // arithmetic can go wrong: `nextRun` answers with a count, the walk turns
    // it into a skip, and the next call has to be measured from where the
    // count left it. So the fixture is a column spread over several slabs,
    // and the walk is compared against an oracle that reads the values one
    // row at a time — as the *raw skip sequence*, because a position list is
    // unchanged by a skip that is one too small and the next one too large.
    //
    // **What this test is not.** Upstream's `nextRun` has a cross-slab merge
    // for a run that spans two slabs (`column.rs:591-616`; the port's
    // `nextRunMax`, `column.zig:3641-3659`), and that case cannot be built
    // through `Columns.splice`: the slab budget counts *segments*
    // (`column.zig:3070`), a segment is a run (`slab.zig:85-91`), and
    // `splitToBudget` cuts at a segment boundary, so a run of any length is
    // one segment and is never divided. [`boundaryInsideRun`] is the check
    // for the other side of that, and it runs as the premise below.
    const gpa = testing.allocator;
    var phases = try slabFixture(gpa);
    defer phases.deinit(gpa);
    const all: RowRange = .{ .start = 0, .end = phases.rows.items.len };

    var fx = try Fixture.init(gpa, phases.rows.items);
    defer fx.deinit();
    var clock = try coveringClock(gpa, phases.rows.items);
    defer clock.deinit();
    var scratch = try topScratch(Row, gpa, &fx.cols, all);
    defer scratch.deinit(gpa);

    // The premise: the column is spread over several slabs, and no slab
    // boundary falls inside a run.
    try testing.expect(fx.cols.index.top.slabCount() > 1);
    try testing.expect(try boundaryInsideRun(&fx.cols.index.top) == null);
    // The successors the column holds are the ones the fixture declared.
    // This is the premise that makes the comparisons below mean anything: a
    // row's `succs` written as `&.{id}` inside a loop is a pointer to that
    // iteration's stack frame, and `coveringClock` is built from the same
    // rows but read later, so the splice and the clock can pick up
    // *different* values out of that slot. The result is a **nondeterministic**
    // disagreement, not a stable wrong answer — which is what made this look
    // like a bug in the scan flavour for as long as it did. Comparing walks
    // against each other cannot catch it, because they are built from the
    // same wrong bytes; comparing them against the ids the fixture declared
    // can. [`Phases.oneSucc`] is the fix, and these three lines are the
    // check on the fix.
    try testing.expectEqual(
        @as(u32, 1001),
        (try fx.cols.succ_ctr.get(0)).?,
    );
    try testing.expectEqual(
        @as(u32, 1400),
        (try fx.cols.succ_ctr.get(399)).?,
    );
    try testing.expectEqual(
        @as(u32, 402),
        (try fx.cols.succ_ctr.get(400)).?,
    );

    var oracle = try skipOracle(gpa, &fx.cols.index.top, all);
    defer oracle.deinit(gpa);
    var current = try TopIter(Row).init(&fx.cols, null, all, scratch.top);
    var skips = try rawSkips(gpa, TopIter(Row), &current);
    defer skips.deinit(gpa);
    try expectSlices(skips.items, oracle.items);

    // And both flavours still find the same winners over the same slabs,
    // which is 600 rows and 500 successors — the one place the scan
    // flavour's successor cursor is exercised across a slab boundary too,
    // and what caught a row's `succs` being a pointer to a loop's stack
    // frame (see the `Phases` successor arena).
    var current2 = try TopIter(Row).init(&fx.cols, null, all, scratch.top);
    var scan = try TopIter(Row).init(&fx.cols, clock, all, scratch.top);
    var from_current = try topPositions(gpa, TopIter(Row), &current2, all);
    defer from_current.deinit(gpa);
    var from_scan = try topPositions(gpa, TopIter(Row), &scan, all);
    defer from_scan.deinit(gpa);
    try testing.expectEqualSlices(usize, from_current.items, from_scan.items);
    try testing.expectEqual(@as(usize, 100), from_current.items.len);
    // Every winner is past the block of deleted rows the cut runs through.
    try testing.expect(from_current.items[0] > deletedRows);
}
