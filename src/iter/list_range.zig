//! The list range reader: one entry per **visible** element of a sequence,
//! with the element's index, its value and the element's width
//! (`rust/automerge/src/iter/list_range.rs`, 442 lines).
//!
//! This is where a document's **visible sequence** comes from, and it is the
//! same three layers [`iter/map_range.zig`](map_range.zig) is built from: the
//! rows ([`ListIter`]), what happened to them ([`ListDiff`]) and what a caller
//! sees ([`ListRange`]).
//!
//! # What an element is, and what contributes one
//!
//! **An insert is an element** and **an element every successor deleted is
//! not**. That is the whole rule, and it is decided by the register the rows
//! share: two rows belong to the same element when the `insert` column's
//! running count is the same at both ([`insert_acc_range`], `op_set.rs:906-908`),
//! and that count is what [`ListEntry.inserts`] carries. A row is a *put* when
//! it hangs by another element ([`elemid_or_key`], `op.rs:1040-1046`), so an
//! overwritten element contributes one element, not two.
//!
//! Two concurrent inserts at the same position are **two elements, adjacent**,
//! and which comes first is the row-order rule and not this reader's choice.
//! **Within a sequence the registers *ascend* by element id** (rule R2,
//! [`op.zig:2215-2222`](../opset/op.zig),
//! [`op.rs:1059-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)
//! is the *map* arm of the same match), **except** at the head, where an
//! insert opening a register is legal when it is anchored to the element the
//! previous row belongs to *or* when its own id sorts before that element —
//! rule R4, [`op.zig:2226-2231`](../opset/op.zig),
//! [`op.rs:1061-1063`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs).
//! So **a later insert at the head is the *earlier* row**, and the larger
//! actor's concurrent splice comes first. The test "two concurrent inserts at
//! the same position stay adjacent" is upstream's
//! `does_not_interleave_sequence_insertions_at_same_position`
//! ([`tests/test.rs:1459-1516`](../../github-automerge-automerge/rust/automerge/tests/test.rs))
//! seen from the reader's side.
//!
//! # The width is the load-bearing part
//!
//! [`ListRangeItem.width`] is the element's width **in the document's text
//! encoding**, and it is read from `index.text` on the register's **last** row.
//! That row is the register's winner — the rows of a register ascend by op id
//! and the winner is the greatest — and upstream says so where it depends on
//! it ([`op_set.rs:748-752`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)):
//!
//! ```text
//! // The `text` index carries an element's width on its `top` op, which is
//! // the element's LAST op, so `advance_prefix` lands on that final op.
//! ```
//!
//! Reading it off the register's *first* row answers `null` for every element
//! whose insert is not also its winner, and a text built from those widths is
//! silently misaligned: every element comes out one unit wide.
//!
//! A block marker inside a text object is **one entry of width one** — it is
//! the object replacement character, U+FFFC, and it does not split into
//! graphemes ([`Op.as_str`](../../opset/op.zig), `op.rs:997-1005`).
//!
//! **The index is upstream's: one per visible element, whatever its width.**
//! `list_range.rs:166-169` and `:178-181` advance `self.index` by one per
//! visible item and by nothing else, and a mark's element — which has width
//! zero — still advances it. The width is a *separate* field for a caller that
//! renders text, and it is not a second index.
//!
//! # Where the index range is resolved
//!
//! [`IndexRange`] is upstream's `RangeBounds<usize>` made concrete
//! ([`normalize_range`], `list_range.rs:359-372`). **The port's shape is
//! [`API.md`](../../API.md)'s**, `struct { start: usize, end: ?usize }` with a
//! null `end` meaning "to the end of the object", and that removes both of
//! upstream's arithmetic traps: `Excluded(0)` as a start bound underflows and
//! `Included(usize::MAX)` as an end bound overflows there.
//!
//! Upstream filters **after** diffing, so `list_range(obj, 900_000..)` still
//! walks every row.
//! So does this, and the reason is the same: the index of an element is not
//! known until the elements before it have been counted.
//!
//! # Imports
//!
//! [`ExIdPromise`], [`OwnedMapRangeItem`]'s sibling [`ExIdPromise`], the clock
//! predicate and the reader's error set come from
//! [`iter/map_range.zig`](map_range.zig): upstream declares `ExIdPromise` and
//! `OpSetOrExId` in `iter/tools.rs:187-244` and uses them from here
//! (`list_range.rs:19,207`), and [`iter/tools.zig`](tools.zig)'s module doc
//! names the map reader as their home because they are `OpSet`-typed and the
//! toolkit is not.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clockmod = @import("../clock.zig");
const column = @import("../hexane/column.zig");
const optypes = @import("../opset/types.zig");
const opcols = @import("../opset/columns.zig");
const opiter = @import("../opset/op_iter.zig");
const opmod = @import("../opset/op.zig");
const opset = @import("../opset/op_set.zig");
const maprange = @import("map_range.zig");
const tools = @import("tools.zig");

const Allocator = std.mem.Allocator;
const ParseError = err.ParseError;

const Action = optypes.Action;
const OwnedValueRef = optypes.OwnedValueRef;
const ScalarValue = optypes.ScalarValue;
const StringTable = opcols.StringTable;
const ValueRef = optypes.ValueRef;

const ActorIdx = types.ActorIdx;
const Clock = clockmod.Clock;
const ClockRange = clockmod.ClockRange;
const ElemId = types.ElemId;
const ExId = types.ExId;
const ObjId = ExId;
const OpId = types.OpId;

const RowRange = tools.RowRange;
const Diff = tools.Diff;
const ExIdPromise = maprange.ExIdPromise;
const ReadError = maprange.ReadError;
const predates = maprange.predates;

// ── The range a caller asks for ─────────────────────────────────────────────

/// A half-open range of element indices, which is upstream's `RangeBounds`
/// made concrete ([`normalize_range`], [`list_range.rs:359-372`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
///
/// **The port's shape is [`API.md`](../../API.md)'s and not upstream's
/// `RangeBounds`**, and the difference is not only spelling: upstream's
/// `Excluded(0)` start underflows and its `Included(usize::MAX)` end overflows.
/// A half-open pair of bounds cannot. `start` is inclusive; a null `end` is
/// the end of the object.
///
/// # An inverted range is empty, and that is deliberate
///
/// **A range with `start > end` contains nothing**, so a caller that gets one
/// — a `end` computed from a filtered count that came out below its `start` —
/// reads **no elements at all**, indistinguishable from an empty object. There
/// is **no error and no diagnostic**, and the cost is a **full walk of the
/// object**: [`ListRange.next`] filters after diffing, as upstream does, so
/// every row is read and every element's index computed before the range is
/// asked about.
///
/// **Why silence rather than a refusal.** The range is a pair of plain
/// integers with no invariant between them, upstream's `RangeBounds` has no
/// ordered form to check, and a half-open window that names nothing is a
/// coherent answer — the same answer an empty object gives. **A caller that
/// wants the other answer has to ask for it**, and the route that validates
/// does: the C bridge's `toRange` returns `error.InvalidRange` for
/// `begin > end`, citing upstream's `format!("Invalid range [{}-{})"`
/// ([`src/c/doc.zig`](../../src/c/doc.zig)), so a C consumer gets a diagnostic
/// where a Zig consumer gets an empty read. **A range whose `start` is past the
/// end of the object is the same case and is likewise silent** — an index no
/// element ever reaches. The test "an empty sequence reads as nothing, and a
/// range past its end reads as nothing" is the behavioural pin: it reads
/// `.{ .start = 2, .end = 1 }` off a three-element list and answers `null`.
pub const IndexRange = struct {
    /// The first index the reader answers, inclusive. Defaults to the head.
    ///
    /// **Not checked against `end`**, so a `start` above `end` is the empty
    /// range described at the type's first section rather than an error.
    start: usize = 0,
    /// One past the last index the reader answers, or null for the end of the
    /// object.
    ///
    /// **Clamped by nothing and checked against nothing**: a value past the
    /// object's length is the same as the end of the object, and a value below
    /// `start` makes the range empty.
    end: ?usize = null,

    /// The whole object: the range `0..`, which is every element.
    ///
    /// **Index zero is not excluded.** `.{ .start = 0 }` is the whole object,
    /// and a caller that wants to skip the first element passes
    /// `.{ .start = 1 }` — upstream's `normalize_range` answers
    /// `list_range(obj, 1..)` the same way (`list_range.rs:359-372`).
    pub fn all() IndexRange {
        return .{};
    }

    /// Whether `index` is in the range. This is upstream's
    /// `Range::contains` at `list_range.rs:351`, which is what decides whether
    /// a diffed element is handed to the caller.
    ///
    /// **False for every index when `start > end`**, which is the half-open
    /// window naming nothing — see the type's first section. A null `end` is
    /// the end of the object and never fails this test.
    pub fn contains(self: IndexRange, index: usize) bool {
        if (index < self.start) return false;
        const end = self.end orelse return true;
        return index < end;
    }
};

// ── What a caller sees ──────────────────────────────────────────────────────

/// One visible element of a sequence ([`ListRangeItem`],
/// [`list_range.rs:14-20`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
///
/// # The borrows, and their windows
///
/// **The value is the op set's, and is valid until the next mutation**: its
/// payload is read out of the value column, which a splice rewrites.
/// [`intoOwned`](ListRangeItem.intoOwned) is the copy for a caller that has to
/// hold one across a mutation.
///
/// Resolving an ID borrows actor bytes until document teardown; `intoOwned`
/// makes an independent copy alongside value payloads.
///
/// **A sequence key is not a payload here.** The map reader's row carries the
/// key out of the string table ([`MapRangeItem`]); this one carries no key,
/// because an element is named by its index.
pub fn ListRangeItem(comptime O: type) type {
    return struct {
        const Self = @This();

        /// Which visible element this is, counting from zero over the visible
        /// elements of the object (`list_range.rs:16`).
        ///
        /// **Counted over the elements the reader sees, not over rows**, and it
        /// is what [`IndexRange`] filters on — which is why the filter is
        /// applied after the diff.
        index: usize,
        /// The element's width in the document's text encoding
        /// (`list_range.rs:16` has no such field; see the module doc).
        ///
        /// Read from `index.text` on the register's **last** row, and zero for a
        /// row with no width there (a mark, or a row that is not the winner).
        width: usize,
        /// The value a reader sees: a scalar, or a reference to an object
        /// (`list_range.rs:17`).
        ///
        /// **Borrowed out of the op set's value column**, so valid until the
        /// next mutation of it; [`intoOwned`](ListRangeItem.intoOwned) is the
        /// copy that outlives one.
        value: ValueRef,
        /// Whether the element's register holds more than one visible value
        /// (`list_range.rs:18`).
        conflict: bool,
        /// The row's id, and the op set that will turn it into an [`ExId`]
        /// (`list_range.rs:19`).
        ///
        /// **Both are borrowed**: the op set has to outlive this promise, and
        /// the resolved [`ExId`] borrows the actor's bytes from it.
        maybe_exid: ExIdPromise(O),

        /// The row's op id, without resolving it
        /// ([`ListRangeItem::op_id`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:23-25`).
        pub fn opId(self: *const Self) OpId {
            return self.maybe_exid.id;
        }

        /// The row's [`ExId`] ([`ListRangeItem::id`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:27-29`).
        ///
        /// **The returned id borrows the op set's actor bytes**, and in a
        /// document those are the document's arena
        /// ([`ExId.Named.actor`](../../src/types.zig), `types.zig:280-288`), so
        /// the op set — and so the document — has to outlive anything the
        /// caller does with the id.
        pub fn id(self: *const Self) ExId {
            return self.maybe_exid.exid();
        }

        /// Copies scalar payloads and resolved ID actor bytes (`list_range.rs:30-37`).
        /// The result survives document teardown. OOM transfers nothing and
        /// leaves this borrowed item untouched.
        pub fn intoOwned(self: Self, gpa: Allocator) !OwnedListRangeItem {
            var id_copy = try self.maybe_exid.exid().dup(gpa);
            errdefer id_copy.deinitOwned(gpa);
            return .{
                .index = self.index,
                .width = self.width,
                .value = try self.value.intoOwned(gpa),
                .conflict = self.conflict,
                .id = id_copy,
            };
        }
    };
}

/// A fully independent list item, owning value payloads and ID actor bytes.
/// Copies share one owner and must not be released twice (`list_range.rs:30-37`).
pub const OwnedListRangeItem = struct {
    /// Which visible element this is.
    index: usize,
    /// The element's width in the document's text encoding. A plain number, so
    /// it outlives the document on its own.
    width: usize,
    /// The value, owned: a copy the caller frees with
    /// [`deinit`](OwnedListRangeItem.deinit) and the same allocator
    /// [`ListRangeItem.intoOwned`] was given.
    value: OwnedValueRef,
    /// Whether the element's register holds more than one visible value.
    conflict: bool,
    /// The resolved ID, including independently owned actor bytes.
    id: ExId,

    /// Releases all owned payloads exactly once with the constructor allocator.
    pub fn deinit(self: *OwnedListRangeItem, gpa: Allocator) void {
        self.value.deinit(gpa);
        self.id.deinitOwned(gpa);
        self.* = undefined;
    }
};

// ── The rows ────────────────────────────────────────────────────────────────

/// One row of a sequence object's range ([`ListEntry`],
/// [`list_range.rs:280-287`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
///
/// **`pub` and named, because a consumer cannot name the alternative.**
/// [`ListIter.shiftNext`] and [`ListIter.seekTo`] return this row, and
/// `pub const Rows` hands a caller a `ListIter`, so a caller that wants to hold
/// one in a struct field or write it in a signature has to spell the type. The
/// map reader's row is published for exactly this reason, as [`MapEntry`]
/// ([`map_range.zig`](map_range.zig)); this is that type, under the name that
/// matches.
///
/// **Not generic over the op set's row type**, and it needs no generic
/// parameter: the four cursors it is read out of are all `OpSet`-independent.
/// The one type here that does need the row type is [`ExIdPromise`], because it
/// holds the op set.
///
/// **`value` is borrowed** out of the op set's value column, valid until the
/// next mutation, and is the one payload here that can outlive the walk only
/// through [`ListRangeItem.intoOwned`].
pub const ListEntry = struct {
    const Self = @This();

    /// How many inserts the `insert` column has counted through this row, and
    /// so **which element the row belongs to** (`list_range.rs:282`).
    inserts: i64,
    /// What the row does.
    action: Action,
    /// The value it puts, borrowed out of the op set's value column and valid
    /// until the next mutation.
    value: ScalarValue,
    /// The row's own id — a counter and an actor *index*, so nothing here
    /// borrows the actor table.
    id: OpId,
    /// The row's position, absolute in the op set. The width read is keyed on
    /// it, which is why the reader carries it.
    pos: usize,

    /// One row (`List::new`, `list_range.rs:289-299`).
    ///
    /// **`pub`, because the walk's own constructors return this type** and a
    /// caller that builds a row by hand has to name it. A row built here has
    /// the same obligations as one read out of the walk: `value` borrows the
    /// caller's own storage and `pos` must be a position in the same op set
    /// the rest of the reader is reading.
    pub fn init(
        inserts: i64,
        action: Action,
        value: ScalarValue,
        id: OpId,
        pos: usize,
    ) ListEntry {
        return .{ .inserts = inserts, .action = action, .value = value, .id = id, .pos = pos };
    }
};

/// A walk of a sequence object's rows, one entry per row ([`ListIter`],
/// [`list_range.rs:261-321`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
///
/// Contiguous reads consume four forward streams. [`tools.takeAt`] selects
/// the partial `next` for zero skips, including the final exhausted sentinel.
///
/// **The insert count is a running sum, not a per-row flag**, and that is what
/// makes two rows one element: the `insert` column is a prefix column, so
/// [`insertAccRange`](../../opset/op_set.zig) answers "how many inserts have
/// there been through this row", and two rows with the same count are in the
/// same element ([`list_range.rs:152-159`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
pub const ListIter = struct {
    /// `id_actor` and `id_ctr`, as one id ([`OpIdIter`], `op_set.rs:1285-1290`).
    id: opiter.OpIdIter,
    /// `insert` as a prefix column: the element each row belongs to
    /// ([`insert_acc_range`], `op_set.rs:906-908`).
    inserts: opcols.BoolPrefixColumn.PrefixIter,
    /// `action` ([`action_iter_range`], `op_set.rs:898-900`).
    action: opiter.ActionIter,
    /// `value_meta` over `value` ([`value_iter_range`], `op_set.rs:1292-1297`).
    value: opiter.ValueIter,

    /// The [`Shiftable`](tools.zig) conformance mark. Naming it instantiates
    /// the comptime check over all eight kernel methods
    /// ([`column.zig:4006-4026`](../hexane/column.zig)), which *is* the check
    /// that this walk can be repositioned.
    pub const shiftable = column.Shiftable(ListIter);

    /// The four cursors ([`ListDiff::new`], `list_range.rs:48-65`).
    pub fn init(
        id: opiter.OpIdIter,
        inserts: opcols.BoolPrefixColumn.PrefixIter,
        action: opiter.ActionIter,
        value: opiter.ValueIter,
    ) ListIter {
        return .{ .id = id, .inserts = inserts, .action = action, .value = value };
    }

    // ── The kernel ─────────────────────────────────────────────────────
    //
    // Eight forwarders, as [`tools.SkipIter`] and [`tools.DiffKernel`] also
    // carry. Upstream implements `Shiftable::shift_next` and
    // `Iterator::next`/`nth` (`list_range.rs:269-278`, `:301-321`); the
    // port's kernel is the eight names of `shift.rs:19-74`.

    /// The row the walk is on ([`pos`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:20-22`).
    pub fn pos(self: *const ListIter) usize {
        return self.id.pos();
    }

    /// One past the last row this walk can reach (`shift.rs:23-25`).
    pub fn maxPos(self: *const ListIter) usize {
        return self.id.maxPos();
    }

    /// Truncates the window at `at`, on all four cursors (`shift.rs:26-27`).
    pub fn setMax(self: *ListIter, at: usize) void {
        self.id.setMax(at);
        self.inserts.setMax(at);
        self.action.setMax(at);
        self.value.setMax(at);
    }

    /// Advances so the next read is the row at `target` (`shift.rs:34-40`).
    pub fn advanceTo(self: *ListIter, target: usize) ReadError!void {
        try self.id.advanceTo(target);
        try self.inserts.advanceTo(target);
        try self.action.advanceTo(target);
        try self.value.advanceTo(target);
    }

    /// Advances past `amount` rows (`shift.rs:42-47`).
    pub fn advanceBy(self: *ListIter, amount: usize) ReadError!void {
        return self.advanceTo(self.pos() +| amount);
    }

    /// Repositions all windows atomically. A typed refusal leaves every
    /// cursor and window unchanged (`column.rs:538-545`).
    pub fn shift(self: *ListIter, rows: RowRange) ReadError!void {
        var staged = self.*;
        try staged.id.shift(rows);
        try staged.inserts.shift(rows);
        try staged.action.shift(rows);
        try staged.value.shift(rows);
        self.* = staged;
    }

    /// Reads one row from the forward streams (`list_range.rs:301-310`).
    /// Exhausted total readers remain partial, just as in `shiftNext`.
    pub fn next(self: *ListIter) ReadError!?ListEntry {
        const actor = try self.id.actor.next();
        const ctr = try self.id.ctr.next();
        const inserts = try self.inserts.next();
        const action = if (self.action.pos() < self.action.maxPos())
            try self.action.tryNext()
        else
            null;
        const value = if (self.value.pos() < self.value.maxPos())
            try self.value.tryNext()
        else
            null;
        if (actor == null or ctr == null or inserts == null or action == null or value == null)
            return null;
        return ListEntry.init(
            inserts.?.total(),
            action.?,
            value.?,
            OpId.init(ctr.?, actor.?),
            self.id.pos() - 1,
        );
    }

    /// Repositions onto `rows` and reads the row at its start
    /// ([`impl Shiftable for ListIter`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:269-278`).
    ///
    /// **All four cursors move before any of them is read**, and the position
    /// is read after the null checks — see
    /// [`MapIter.shiftNext`](map_range.zig) for why the second half matters.
    pub fn shiftNext(self: *ListIter, rows: RowRange) ReadError!?ListEntry {
        const id = try self.id.shiftNext(rows);
        const inserts = try self.inserts.shiftNext(rows);
        const action = try self.action.shiftNext(rows);
        const value = try self.value.shiftNext(rows);
        if (id == null or inserts == null or action == null or value == null) return null;
        return ListEntry.init(inserts.?.total(), action.?, value.?, id.?, self.id.pos() - 1);
    }

    /// Consumes through `at` and reads the row there, or null past the end of
    /// the window ([`seek_to`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:65-74`).
    pub fn seekTo(self: *ListIter, at: usize) ReadError!?ListEntry {
        if (at < self.pos()) return null;
        return self.shiftNext(.{ .start = at, .end = self.maxPos() });
    }
};

comptime {
    // **The [`Shiftable`](map_range.zig) mark is honest, and non-null.**
    // [`column.Shiftable`](../hexane/column.zig) is a comptime check over the
    // eight kernel names (`column.zig:4006-4018`) and *naming the value
    // instantiates it*, so a walk missing one of the eight would not compile.
    //
    // **It is a value and not `tools.SkipIter`'s `?type`
    // ([`tools.zig:666`](tools.zig)) because `ListIter` is unconditionally
    // shiftable.** A `?type` exists for a walk that *may* not carry the
    // kernel — a filter with no positional entry point — and this is not one.
    // Claiming a nullable mark here would say "sometimes", which is not true
    // and would let a caller that checked it be told nothing.
    //
    // The partial `next` is additional to the eight positional kernel methods.
    _ = ListIter.shiftable;
}

/// One visible element of a sequence, with what happened to it
/// ([`ListDiffItem`], [`list_range.rs:193-203`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
pub fn ListDiffItem(comptime O: type) type {
    return struct {
        const Self = @This();

        /// What happened to the element between the two states
        /// (`list_range.rs:195`).
        diff: Diff,
        /// The value as the *after* state sees it (`list_range.rs:196`).
        ///
        /// **A counter's total is folded with wrapping arithmetic**, the same
        /// rule [`Op.fixCounter`](../opset/op.zig) materialises it with: a
        /// counter is an `i64` and its increments are summed modulo 2^64, so a
        /// counter that overflows the width wraps rather than trapping. `inc`
        /// below is folded the same way.
        value: ValueRef,
        /// The net counter change over the range, or zero (`list_range.rs:197`).
        ///
        /// **`after - before`, folded with the same wrapping subtraction**
        /// ([`Op.fixCounter`](../opset/op.zig)): each side is a sum of the
        /// increments its clock covers, and their difference wraps on the width
        /// too. Increments that are all positive make this a plain difference;
        /// a decrement, or a clock pair that is not nested, is where the wrap
        /// shows. Zero on every non-counter row.
        inc: i64,
        /// Which visible element this is (`list_range.rs:198`).
        index: usize,
        /// Whether the element's register is conflicted *after* it
        /// (`list_range.rs:199`).
        conflict: bool,
        /// Whether this element is a put rather than an insert, which a patch
        /// needs and a read does not (`list_range.rs:200`).
        update: bool,
        /// Whether this element newly exposes a value that was shadowed
        /// (`list_range.rs:201`).
        expose: bool,
        /// The winning row's own id (`list_range.rs:202`).
        id: OpId,
        /// The winning row's position, absolute in the op set.
        ///
        /// **The one field upstream's `ListDiffItem` does not have**, and it
        /// is here for the width: `index.text` is read on the element's last
        /// row ([`op_set.rs:748-752`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
        /// so the reader has to know where the row it is reporting sits. The
        /// map reader's `MapDiffItem` already carries the same field for the
        /// same reason it carries `pos` at all (`map_range.rs:50`).
        pos: usize,

        /// The element as a reader's item
        /// ([`ListDiffItem::export`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:206-214`).
        ///
        /// **Fallible, and upstream's is not**: the width is a read of
        /// `index.text` on the element's last row, and upstream has no width
        /// to read. `rows` is the object's row range, which is what bounds it,
        /// and `elems` is the walk that finds the element's last row.
        ///
        /// `elems` and `widths` are caller-held borrowed cursors reused across
        /// elements. Neither owns storage, and mutation invalidates both.
        pub fn exportItem(
            self: Self,
            set: *opset.OpSet(O),
            elems: *opset.OpSet(O).ElemCursor,
            widths: *opcols.TextColumn.Iterator,
            rows: RowRange,
        ) ReadError!?ListRangeItem(O) {
            return .{
                .index = self.index,
                .width = try elementWidth(O, set, elems, widths, self.pos, rows.end),
                .value = self.value,
                .conflict = self.conflict,
                .maybe_exid = ExIdPromise(O).init(set, self.id),
            };
        }

        /// Records that this element exposes something, promotes a `Same` to an
        /// `Add` when it does, and marks it a put
        /// ([`ListDiffItem::update`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:246-251`).
        pub fn updateItem(self: *Self, expose: bool) void {
            self.expose = self.expose or expose;
            if (self.expose and self.diff == .same) self.diff = .add;
            self.update = true;
        }
    };
}

/// The counters a [`ListDiff`] keeps across one element's rows
/// ([`ListState`], [`list_range.rs:80-111`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
///
/// Upstream's struct so that the five counters are reset in one assignment
/// rather than five, and this keeps that: a new element is a new `ListState`
/// and the old one is dropped whole. **It is not generic over the op set's
/// row type** because it holds no rows and no op set; the one thing that
/// builds a [`ListDiffItem`] is [`listStateDiffItem`], which is.
const ListState = struct {
    /// How many of the element's rows the *before* state saw.
    num_old: usize = 0,
    /// How many of the element's rows the *after* state saw.
    num_new: usize = 0,
    /// Whether the element's register is conflicted, as at the row in hand.
    conflict: bool = false,
    /// Whether the row in hand exposes a value that was shadowed.
    expose: bool = false,
    /// The net counter change over the range, or zero.
    inc: i64 = 0,
};

/// The element as a diff item
/// ([`ListState::diff_item`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:88-111`).
///
/// **A function and not a method**, because the diff item is generic over the
/// op set's row type — it carries an [`ExIdPromise`] — and [`ListState`] is
/// not. See [`mapEntryDiffItem`](map_range.zig) for the same decision in the
/// map reader.
///
/// Two promotions happen here, once, so every caller gets them:
///
/// * `expose` promotes a `Same` to an `Add` (`list_range.rs:96-98`);
/// * `update` is "an insert that is really a put" — the element was in the
///   before state and this is its winning row, so a patch must say it is a
///   put and not an insert (`list_range.rs:100`). A read does not use it.
fn listStateDiffItem(
    comptime O: type,
    state: ListState,
    pos: usize,
    id: OpId,
    value: ValueRef,
    index: usize,
    diff_in: Diff,
) ListDiffItem(O) {
    const diff: Diff = if (state.expose and diff_in == .same) .add else diff_in;
    return .{
        .diff = diff,
        .value = value,
        .inc = state.inc,
        .index = index,
        .conflict = state.conflict,
        .update = diff == .add and state.num_old > 0,
        .expose = state.expose,
        .id = id,
        .pos = pos,
    };
}

/// A sequence object's rows tagged with what happened to each element
/// ([`ListDiff`], [`list_range.rs:40-191`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
///
/// The grouping is the same as the map reader's and for the same reason: an
/// element's rows are contiguous (rule **R3**, `op.rs:1056-1057`) and the
/// lookahead's `peek` decides whether the row in hand ends its element
/// ([`list_range.rs:152-159`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
pub fn ListDiff(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The op set the rows are read from, and the one an exported id is
        /// resolved against.
        op_set: *opset.OpSet(O),
        /// The lookahead over the diff, so the next row can be asked about
        /// without reading it (`list_range.rs:43`).
        iter: tools.Unshift(Walk),
        /// Which visible element the next `next` is (`list_range.rs:44`).
        ///
        /// **Counted over visible elements, not rows**: a mark's element has
        /// width zero and still advances it (`list_range.rs:166-169`). Reset to
        /// zero by [`shiftNext`](ListDiff.shiftNext), because the next range is
        /// a different object whose first element is element zero.
        index: usize = 0,
        /// Which two states, or which one, the diff is between
        /// (`list_range.rs:45`).
        ///
        /// **A borrowed copy of the caller's clocks.** [`ClockRange`] holds up
        /// to two [`Clock`](../../src/clock.zig) values, each a `[]u32` plus the
        /// allocator that allocated it, and this walk reads through them on
        /// every row. **This type never frees them**, so the caller's clocks
        /// have to outlive the reader; a `Clock.deinit` while a diff built from
        /// it is still being read leaves the reader walking released counters.
        clock: ClockRange,
        /// The object's rows, which is what bounds the width lookup
        /// ([`OpSet.elemidAt`](../../opset/op_set.zig)).
        ///
        /// **Clamped once here and re-clamped at every shift** — its `end` half
        /// is what keeps the width read inside the object, which is why
        /// [`shiftNext`](ListDiff.shiftNext) re-clamps where the map reader's
        /// [`MapRange.shiftNext`](map_range.zig) does not.
        rows: RowRange,

        /// The walk this instantiation is
        /// ([`ListDiff::new`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:48-65`).
        pub const Walk = tools.DiffKernel(ListEntry, ListIter, opset.OpSet(O).Visible);
        /// The rows the walk reads, one per visible row.
        pub const Rows = ListIter;

        /// The diff over `rows`, between the states `over` names
        /// ([`ListDiff::new`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:49-65`).
        ///
        /// **The window is clamped once, here**; see
        /// [`MapDiff.init`](map_range.zig) for why.
        ///
        /// **`set` and `over` are both borrowed.** The op set has to outlive
        /// the reader, and so do the clocks inside `over`: this stores the
        /// `ClockRange` by value and never frees it, so **a `Clock.deinit`
        /// while this reader is still being walked leaves it reading released
        /// counters** (see the `clock` field). A read of the present is
        /// `.{ .current = null }`, which holds no clock and so nothing to keep
        /// alive.
        pub fn init(set: *opset.OpSet(O), rows: RowRange, over: ClockRange) ReadError!Self {
            const window = column.clampRange(rows, set.len());
            const walk = Walk.init(
                ListIter.init(
                    try set.idIterRange(window),
                    try set.insertAccRange(window),
                    try set.actionIterRange(window),
                    try set.valueIterRange(window),
                ),
                try maprange.VisibleDiffSkipper(O).init(set, over, window),
            );
            return .{
                .op_set = set,
                .iter = try tools.Unshift(Walk).init(walk),
                .clock = over,
                .rows = window,
            };
        }

        /// Repositions the walk onto `rows` and reads the first element in it
        /// ([`ListDiff::shift_next`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:76-78`).
        ///
        /// **The index goes back to zero**, because the next range is a
        /// different object and its first element is its element zero.
        pub fn shiftNext(self: *Self, rows: RowRange) ReadError!?ListDiffItem(O) {
            try self.iter.shift(rows);
            self.index = 0;
            self.rows = column.clampRange(rows, self.op_set.len());
            return self.next();
        }

        /// The next visible element, with what happened to it
        /// ([`Iterator::next` for `ListDiff`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:113-191`).
        pub fn next(self: *Self) ReadError!?ListDiffItem(O) {
            const set = self.op_set;
            var last_is_same = false;
            var last_visible: ?ListDiffItem(O) = null;
            var state: ListState = .{};

            while (try self.iter.next()) |entry| {
                const diff = entry.diff;
                const list = entry.item;
                switch (diff) {
                    .del => {
                        state.num_old += 1;
                        state.expose = last_is_same;
                    },
                    .same => {
                        last_is_same = true;
                        state.num_old += 1;
                        state.num_new += 1;
                        state.expose = false;
                    },
                    .add => {
                        last_is_same = false;
                        state.num_new += 1;
                        state.expose = predates(self.clock, list.id);
                    },
                }

                // `list_range.rs:135-141`, the same counter arithmetic the map
                // reader does at `map_range.rs:255-265` — including the
                // wrapping: `-%` and `+%`, modulo 2^64 on the `i64`, which is
                // how [`Op.fixCounter`](../opset/op.zig) materialises a counter
                // and how the map reader folds the same two sums. Upstream adds
                // and subtracts with checked operators, which trap on an
                // overflow in a checked build; a counter whose increments
                // overflow the width is a corrupt document, and a read is not
                // where that should be reported.
                var value: ValueRef = undefined;
                switch (list.value) {
                    .counter => |c| {
                        const d = try set.getIncrementDiffAtPos(list.pos, self.clock);
                        state.inc = d.after -% d.before;
                        value = ValueRef.fromActionValue(
                            list.action,
                            .{ .counter = ScalarValue.Counter.init(c.current +% d.after) },
                        );
                    },
                    else => {
                        state.inc = 0;
                        value = ValueRef.fromActionValue(list.action, list.value);
                    },
                }

                // `list_range.rs:150`, which is `map_range.rs:260` verbatim.
                const old_conflict = diff == .same and state.num_old > 1;
                state.conflict = state.num_new > 1 and !old_conflict;

                // `list_range.rs:152-159`. The next row is the same element —
                // same `insert` running count — so this one is not the last of
                // its register.
                if (self.iter.peek()) |ahead| {
                    if (ahead.item.inserts == list.inserts) {
                        if (diff.isVisible() and ahead.diff.isDel()) {
                            last_visible = listStateDiffItem(O, state, list.pos, list.id, value, self.index, diff);
                        }
                        continue;
                    }
                }

                if (last_visible) |held| {
                    var last = held;
                    last_visible = null;
                    const newly_visible = last.diff == .same;
                    last.updateItem(state.expose or newly_visible);
                    // The deletion hands the register to this row, and the
                    // conflict flag it reports is the count *after* the
                    // deletion (`list_range.rs:163-166`).
                    last.conflict = state.num_new > 1;
                    if (last.diff.isVisible()) self.index += 1;
                    return last;
                }

                var item = listStateDiffItem(O, state, list.pos, list.id, value, self.index, diff);
                // `list_range.rs:170-179`: the value is unchanged and the
                // conflict flag changed, so the element is still emitted.
                if (diff == .same and state.num_old > 1 and state.num_new == 1) item.updateItem(true);
                if (item.diff.isVisible()) self.index += 1;
                return item;
            }
            return null;
        }
    };
}

/// The width of the element the row at `pos` belongs to, in the op set's text
/// encoding, read through `elems`.
///
/// **Read from the element's *last* row, and that is the whole point**
/// ([`op_set.rs:748-752`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)):
/// `index.text` carries a width only on a `top` row
/// ([`columns.rs:466-471`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs)),
/// the `top` row of a register is its **last** row, and
/// [`OpSet.elemidAt`](../../opset/op_set.zig) is what finds it
/// ([`op_set.rs:793-828`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
///
/// Nothing is recomputed: the width is the op set's own answer, read at the
/// row it wrote it on. A row with no width — a mark, a row that is not a
/// winner — is zero.
///
/// Both cursors are borrowed and held across ascending elements. `elems`
/// resolves the complete register, including invisible rows; `widths` then
/// consumes the text-index column forwards to that register's last row.
/// A backwards or repeated request rebuilds only the width cursor.
fn elementWidth(
    comptime O: type,
    set: *opset.OpSet(O),
    elems: *opset.OpSet(O).ElemCursor,
    widths: *opcols.TextColumn.Iterator,
    pos: usize,
    end: usize,
) ReadError!usize {
    const elem = (try elems.at(pos, end)) orelse return 0;
    if (elem.last_pos < widths.pos()) {
        widths.* = try set.cols.index.text.iterRange(.{ .start = elem.last_pos, .end = end });
    } else {
        widths.setMax(end);
    }
    const cell = (if (elem.last_pos == widths.pos())
        try widths.next()
    else
        try widths.seekTo(elem.last_pos)) orelse return 0;
    const width = cell orelse return 0;
    return std.math.cast(usize, width) orelse error.Overflow;
}

/// The diff kernel a list range is built on: one row per visible row, tagged
/// with what happened to it ([`tools.DiffKernel`], `iter/tools.rs:528-608`).
///
/// **The kernel's row type is [`ListEntry`], published for the reason the map
/// reader's [`MapEntry`](map_range.zig) is.** It is the same declaration as
/// [`ListDiff.Walk`], at the same two type parameters; this is the name a
/// caller reaches for when it wants the kernel without a diff around it.
pub fn ListWalk(comptime O: type) type {
    return tools.DiffKernel(ListEntry, ListIter, opset.OpSet(O).Visible);
}

/// A sequence object's visible elements, one at a time ([`ListRange`],
/// [`list_range.rs:255-357`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)).
///
/// Constructing one allocates nothing: four row streams, an element cursor,
/// a forward text-width cursor, a skipper and lookahead, all borrowed from
/// storage the op set already holds.
///
/// **It owns nothing and has no `deinit`.** Everything it holds is borrowed —
/// the op set and the clock behind [`ListDiff`] — and the walks read the op set's
/// shared successor buffer, so a second reader over one op set needs its own
/// buffer sized with
/// [`opiter.maxSuccCount`](../opset/op_iter.zig) (the same rule
/// [iter/doc.zig](doc.zig) states for the readers built here).
pub fn ListRange(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The diff this reader is a view of, and so where its borrowed clocks
        /// are kept.
        iter: ListDiff(O),
        /// Which indices the caller asked for (`list_range.rs:258`).
        ///
        /// **Kept as given and never re-validated.** An inverted range is the
        /// empty read [`IndexRange`] documents, not an error — see its first
        /// section.
        range: IndexRange,
        /// Borrowed complete-register resolver, held across elements.
        /// It includes invisible rows and permits backward requests by
        /// rebuilding its cursors. Mutation invalidates the borrow.
        elems: opset.OpSet(O).ElemCursor,
        /// Borrowed forward text-index stream; widths are read on the complete
        /// register's last row, not necessarily its last visible row.
        widths: opcols.TextColumn.Iterator,

        /// The reader over the object's `rows`, as the states `clock` names see
        /// them, restricted to `range`
        /// ([`ListRange::new`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:324-335`).
        ///
        /// **`clock` is borrowed, and `null` is the present.** It is a
        /// [`Clock`] by value — a `[]u32` plus the allocator that allocated it
        /// ([`Clock.init`](../../src/clock.zig)) — and the reader reads through
        /// it on every row, so **the caller's clock has to outlive the reader**:
        /// a `Clock.deinit` while this reader is still being walked leaves it
        /// reading released counters. `null` sees every operation the op set
        /// holds; a non-null clock bounds the read to the operations it covers.
        ///
        /// **`range` is not checked here either** — it is stored and applied by
        /// [`next`](ListRange.next) after the diff, which is the only place an
        /// element's index is known.
        pub fn init(
            set: *opset.OpSet(O),
            obj_rows: RowRange,
            clock: ?Clock,
            range: IndexRange,
        ) ReadError!Self {
            return .{
                .iter = try ListDiff(O).init(set, obj_rows, .{ .current = clock }),
                .range = range,
                .elems = try set.elemCursor(),
                .widths = try set.cols.index.text.iterRange(column.clampRange(obj_rows, set.len())),
            };
        }

        /// The next element in the requested range, as a reader sees it
        /// ([`Iterator::next` for `ListRange`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:345-357`).
        ///
        /// **The filter is after the diff**, as upstream's is: an element's
        /// index is only known once the elements before it have been counted,
        /// so a range that starts past the end of the object still walks every
        /// row.
        ///
        /// **Three things follow from that, and they are the ones a caller
        /// gets wrong.** An element outside `range` is *skipped*, not a reason to
        /// stop; an **inverted** range therefore walks the whole object and
        /// answers `null` ([`IndexRange`]'s first section); and the element this
        /// returns is **borrowed** — see [`ListRangeItem`]'s first section for
        /// the two borrows it carries and which of them survives a mutation.
        ///
        /// **Null is the end of the object's elements**, and an element every
        /// row of which has been deleted is not an element and yields nothing.
        pub fn next(self: *Self) ReadError!?ListRangeItem(O) {
            while (true) {
                const item = (try self.iter.next()) orelse return null;
                if (!self.range.contains(item.index)) continue;
                return item.exportItem(self.iter.op_set, &self.elems, &self.widths, self.iter.rows);
            }
        }

        /// Repositions the reader onto `rows` and reads the first element in
        /// the requested range
        /// ([`ListRange::shift_next`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs), `list_range.rs:337-342`).
        ///
        /// **The index goes back to zero and the window is re-clamped**, because
        /// the next range is a different object whose first element is element
        /// zero, and because `rows.end` is what bounds the width read. This is
        /// the same pair of steps [`ListDiff.shiftNext`] takes, and the map
        /// reader's [`MapRange.shiftNext`](map_range.zig) needs only the first
        /// because it has no width to bound.
        ///
        /// The width cursors are held across forward object shifts. The next
        /// width read extends the text-index window and advances to the complete
        /// register's last row. They own no persistent or authoritative cache.
        ///
        /// **A range that starts behind the reader is `error.InvalidValue`**, and
        /// that is upstream's rule and not this port's: the four row cursors are
        /// a hexane `shift`, which is `set_max` plus `advance_to` and never
        /// rewinds ([`Unshift.shift`](tools.zig), `tools.zig:387-398`;
        /// `shift.rs:272-274`), and `shift_next` asserts the same
        /// (`column.rs:629-633`). A range past the end answers `null`.
        pub fn shiftNext(self: *Self, rows: RowRange) ReadError!?ListRangeItem(O) {
            try self.iter.iter.shift(rows);
            self.iter.index = 0;
            self.iter.rows = column.clampRange(rows, self.iter.op_set.len());
            return self.next();
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The concrete op set the fixtures are read through, and why it is
/// [`opmod.Op`] and not [`opmod.ChangeOp`]: `Op` borrows its row's successors
/// and its value, so a fixture is an array of `Op` values over its own spans
/// and needs no allocator, and the index columns come from
/// [`OpSet.rebuildIndex`](../../opset/op_set.zig) rather than from the rows
/// ([`op_set.zig:695-700`](../../opset/op_set.zig)). `Op.top` is `Op.visible`
/// ([`op.zig:1869-1871`](../../opset/op.zig)), so a splice would mark every
/// visible row a winner and a conflicted fixture could not be written.
const Set = opset.OpSet(opmod.Op);

/// The encoding every fixture is built with, so a width is a count of code
/// points and not a count of bytes.
const encoding: types.TextEncoding = .unicode_code_point;

/// The document's actors, **sorted**: an actor index is a position in this
/// table ([`types.zig`](../../src/types.zig)).
const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };
const actor_b: types.ActorId = .{ .bytes = "bbbbbbbb" };

fn opId(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

fn made(ctr: u32, actor: ActorIdx) ObjId {
    return .{ .id = opId(ctr, actor) };
}

/// A sequence row anchored to the element at `id` ([`ElemId::from_op_id`],
/// [`types.rs:652-654`](../../github-automerge-automerge/rust/automerge/src/types.rs)).
fn anchored(id: OpId) optypes.KeyRef {
    return .{ .seq = ElemId.fromOpId(id) };
}

/// The head of a sequence: the element id that means "inserted at the front"
/// ([`ElemId::head`], `types.rs:657-659`).
fn head() optypes.KeyRef {
    return .{ .seq = ElemId.head() };
}

/// A row as the columns spell it. Every borrowed payload — the key, the value
/// and the successor span — belongs to the fixture, which outlives the op set.
fn row(
    id: OpId,
    obj: ObjId,
    key: optypes.KeyRef,
    insert: bool,
    act: Action,
    val: ScalarValue,
    succs: []const opmod.SuccEntry,
) opmod.Op {
    return opmod.Op.init(
        0,
        false,
        id,
        act,
        obj,
        key,
        insert,
        val,
        false,
        null,
        opmod.SuccCursors.fromSpan(succs, 0),
    );
}

/// A delete: a successor edge and not a row
/// ([`Op.del`](../../opset/op.zig), `op.rs:1158-1172`).
const del_of_b = [_]opmod.SuccEntry{.{ .id = opId(5, 0), .inc = null }};

/// The string table a fixture's op set borrows. **Heap-allocated, and that is
/// an ownership rule rather than a convenience** ([`op_set.zig`](../../opset/op_set.zig)'s
/// `documentSet`): the op set borrows the table, so it has to sit at one
/// address for as long as the set does.
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
        try self.items.ensureUnusedCapacity(gpa, 1);
        self.items.appendAssumeCapacity(try gpa.dupe(u8, text));
        return id;
    }
};

/// An op set and the table it borrows, built together.
const Fixture = struct {
    gpa: Allocator,
    table: Table,
    set: Set,

    fn build(gpa: Allocator, actors: []const types.ActorId, rows: []const opmod.Op) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .table = .init(gpa), .set = undefined };
        self.set = Set.fromActors(gpa, actors, encoding, self.table.asTable()) catch |e| {
            self.table.deinit();
            return e;
        };
        // **The table is a second owner and this is its error path.** `destroy`
        // frees it beside the op set, and an error between the two — a refused
        // `splice`, an index the op set will not rebuild
        // ([`OpSet.rebuildIndex`](../../opset/op_set.zig)) — has to free it too,
        // or a fixture that fails on its rows leaks the key strings `splice`
        // interned before it refused. **Declared before the op set's own
        // `errdefer` so it runs after it**: the op set borrows the table, so the
        // borrower goes first.
        errdefer self.table.deinit();
        errdefer self.set.deinit();
        _ = try self.set.splice(0, rows);
        try self.set.rebuildIndex();
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.set.deinit();
        self.table.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// A clock over every operation up to and including `cutoff`.
fn clockUpTo(gpa: Allocator, cutoff: u32) !Clock {
    var c = try Clock.init(gpa, 1);
    _ = c.include(0, cutoff);
    return c;
}

/// Whether two values are the same value, **by content**.
///
/// **`expectEqual` on a [`ValueRef`] compares the pointers of the slices
/// inside it**, so a test that used it would pass on any two string values and
/// fail on none. [`ScalarValue.eql`] is the content comparison.
fn expectValue(got: ValueRef, want: ValueRef) !void {
    if (std.meta.activeTag(got) != std.meta.activeTag(want)) {
        std.debug.print("value is a {s}, expected a {s}\n", .{
            @tagName(std.meta.activeTag(got)),
            @tagName(std.meta.activeTag(want)),
        });
        return error.TestExpectedEqual;
    }
    switch (want) {
        .object => |o| try testing.expectEqual(o, got.object),
        .scalar => |s| try testing.expect(s.eql(got.scalar)),
    }
}

/// The whole sequence, read at the present, as the indices, widths and values
/// a caller sees.
fn readAll(
    set: *Set,
    obj: ObjId,
    gpa: Allocator,
    clock: ?Clock,
) !std.ArrayList(ListRangeItem(opmod.Op)) {
    var out: std.ArrayList(ListRangeItem(opmod.Op)) = .empty;
    errdefer out.deinit(gpa);
    var range = try ListRange(opmod.Op).init(
        set,
        try set.scopeToObj(obj),
        clock,
        .all(),
    );
    while (try range.next()) |item| try out.append(gpa, item);
    return out;
}

test "a list whose middle element is deleted has the indices after it shift down" {
    const gpa = testing.allocator;
    // Three elements appended, so each anchors to the one before it and the
    // rows ascend in id (rule R3). The delete of the middle element is a
    // successor edge on its insert row, not a row of its own
    // ([`Op.del`](../../opset/op.zig), `op.rs:1158-1172`).
    const list = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .str = "a" }, &.{}),
        row(opId(3, 0), list, anchored(opId(2, 0)), true, .set, .{ .str = "b" }, &del_of_b),
        row(opId(4, 0), list, anchored(opId(3, 0)), true, .set, .{ .str = "c" }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, list, gpa, null);
    defer got.deinit(gpa);

    // **The index, not the position in the list.** The element that used to be
    // at index 1 is gone, and "c" is at index 1 rather than 2. An index that
    // does not shift down is the bug this reader exists to avoid.
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqual(@as(usize, 0), got.items[0].index);
    try expectValue(got.items[0].value, .{ .scalar = .{ .str = "a" } });
    try testing.expectEqual(opId(2, 0), got.items[0].opId());
    try testing.expectEqual(@as(usize, 1), got.items[1].index);
    try expectValue(got.items[1].value, .{ .scalar = .{ .str = "c" } });
    try testing.expectEqual(opId(4, 0), got.items[1].opId());

    // The indices are **contiguous and in order**: 0 then 1, with nothing
    // between them and nothing skipped.
    for (got.items, 0..) |item, i| try testing.expectEqual(i, item.index);
}

test "a hidden scalar in the middle of a list shifts every index after it" {
    const gpa = testing.allocator;
    // Four elements, two of them scalars, with the *second* deleted. The
    // point is that a deleted **scalar** hides exactly like a deleted
    // container: the index is a property of the visible element, not of the
    // value's type.
    const list = made(1, 0);
    const del = [_]opmod.SuccEntry{.{ .id = opId(6, 0), .inc = null }};
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .int = 10 }, &.{}),
        row(opId(3, 0), list, anchored(opId(2, 0)), true, .set, .{ .int = 20 }, &del),
        row(opId(4, 0), list, anchored(opId(3, 0)), true, .set, .{ .int = 30 }, &.{}),
        row(opId(5, 0), list, anchored(opId(4, 0)), true, .set, .{ .int = 40 }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, list, gpa, null);
    defer got.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), got.items.len);
    const want: [3]i64 = .{ 10, 30, 40 };
    for (got.items, 0..) |item, i| {
        // The index shifts down by one for everything after the hole, and the
        // hole itself is not a visible element.
        try testing.expectEqual(i, item.index);
        try expectValue(item.value, .{ .scalar = .{ .int = want[i] } });
    }
}

test "a text element's width is its grapheme width, counted by hand" {
    const gpa = testing.allocator;
    // One text object with two elements. **"héllo" is five code points and
    // six bytes** — h, é, l, l, o — and the document's encoding is
    // `unicode_code_point`, so its width is five. The literal five below is
    // counted by hand and not taken from the implementation: a reader that
    // measured bytes would say six, and one that measured UTF-16 units would
    // say five for this string and six for anything with an astral character.
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, &.{}),
        row(opId(2, 0), text, head(), true, .set, .{ .str = "héllo" }, &.{}),
        row(opId(3, 0), text, anchored(opId(2, 0)), true, .set, .{ .str = "xy" }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, text, gpa, null);
    defer got.deinit(gpa);

    // **One entry per element, and the width is the element's own.** Two
    // elements, two entries: the multi-code-point value is not split into five
    // and the two-code-point one is not split into two.
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try expectValue(got.items[0].value, .{ .scalar = .{ .str = "héllo" } });
    try testing.expectEqual(@as(usize, 5), got.items[0].width);
    try testing.expectEqual(@as(usize, 0), got.items[0].index);
    try expectValue(got.items[1].value, .{ .scalar = .{ .str = "xy" } });
    try testing.expectEqual(@as(usize, 2), got.items[1].width);
    try testing.expectEqual(@as(usize, 1), got.items[1].index);

    // The widths add up to the object's length **in the document's encoding**,
    // which is the op set's own answer
    // ([`OpSet.seqLength`](../../opset/op_set.zig), `op_set.rs:429-459`).
    const total: usize = got.items[0].width + got.items[1].width;
    try testing.expectEqual(try doc.set.seqLength(text, encoding, null), total);
    try testing.expectEqual(@as(usize, 7), total);
}

test "a block marker in a text is one entry of width one" {
    const gpa = testing.allocator;
    // A text object holding a block, then two code points. The block is the
    // object replacement character, U+FFFC, which is one unit wide
    // ([`Op.as_str`](../../opset/op.zig), `op.rs:997-1005`), so it is **one
    // entry of width one and not a run of graphemes**.
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, &.{}),
        row(opId(2, 0), text, head(), true, .make_map, .null_value, &.{}),
        row(opId(3, 0), text, anchored(opId(2, 0)), true, .set, .{ .str = "ab" }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, text, gpa, null);
    defer got.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), got.items.len);
    try expectValue(got.items[0].value, .{ .object = .map });
    try testing.expectEqual(@as(usize, 1), got.items[0].width);
    try expectValue(got.items[1].value, .{ .scalar = .{ .str = "ab" } });
    try testing.expectEqual(@as(usize, 2), got.items[1].width);
}

test "two concurrent inserts at the same position stay adjacent" {
    const gpa = testing.allocator;
    // Upstream's `does_not_interleave_sequence_insertions_at_same_position`
    // ([`tests/test.rs:1459-1516`](../../github-automerge-automerge/rust/automerge/tests/test.rs)),
    // from the reader's side. One actor makes the list, then both splice five
    // elements at position 0 concurrently.
    //
    // **Row order at the head is the rule, and the rule is R4: descending.**
    // An insert opening a register is legal when it is anchored to the element
    // the previous row belongs to, *or* when its own id sorts before that
    // element — and the head is the only place the second reading is the whole
    // rule, because there is no element to anchor to
    // ([`op.zig:2226-2231`](../opset/op.zig),
    // [`op.rs:1061-1063`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs);
    // the `Seq` arm is `(KeyRef::Seq(e1), KeyRef::Seq(e2)) if self.insert =>
    // { e1 == e2 || ElemId(self.id) < *e2 }`). The map arm of that same match
    // is [`op.rs:1059-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)
    // and says registers **ascend** — the opposite direction, and a different
    // rule.
    //
    // So the larger actor's five rows come first, and within each actor the
    // elements ascend because they anchor to each other. **The reader does not
    // sort**, so this fixture's order is the answer order and the two together
    // are the assertion.
    const list = made(1, 0);
    const doc = try Fixture.build(gpa, &.{ actor_a, actor_b }, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 1), list, head(), true, .set, .{ .str = "to" }, &.{}),
        row(opId(3, 1), list, anchored(opId(2, 1)), true, .set, .{ .str = "do" }, &.{}),
        row(opId(4, 1), list, anchored(opId(3, 1)), true, .set, .{ .str = "is" }, &.{}),
        row(opId(5, 1), list, anchored(opId(4, 1)), true, .set, .{ .str = "to" }, &.{}),
        row(opId(6, 1), list, anchored(opId(5, 1)), true, .set, .{ .str = "be" }, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .str = "to" }, &.{}),
        row(opId(3, 0), list, anchored(opId(2, 0)), true, .set, .{ .str = "be" }, &.{}),
        row(opId(4, 0), list, anchored(opId(3, 0)), true, .set, .{ .str = "is" }, &.{}),
        row(opId(5, 0), list, anchored(opId(4, 0)), true, .set, .{ .str = "to" }, &.{}),
        row(opId(6, 0), list, anchored(opId(5, 0)), true, .set, .{ .str = "do" }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, list, gpa, null);
    defer got.deinit(gpa);

    // **Both splices are here, all ten elements, contiguous and in row order.**
    // Upstream's answer is `to do is to be | to be is to do`, the larger
    // actor's first.
    const want = [_][]const u8{
        "to", "do", "is", "to", "be",
        "to", "be", "is", "to", "do",
    };
    // **The id of each element, in the same order.** The first five are the
    // larger actor's rows and the last five the smaller actor's, and the
    // counters run 2..6 in each, so the answer is tied to the row it came
    // from and not only to its position in the list.
    const want_ids = [_]OpId{
        opId(2, 1), opId(3, 1), opId(4, 1), opId(5, 1), opId(6, 1),
        opId(2, 0), opId(3, 0), opId(4, 0), opId(5, 0), opId(6, 0),
    };
    try testing.expectEqual(@as(usize, want.len), got.items.len);
    for (got.items, 0..) |item, i| {
        // Contiguous: the index of the i-th element is i. An interleaved read
        // would show 0, 5, 1, 6, 2, 7, 3, 8, 4, 9 or some other order, and the
        // values would not match this list.
        try testing.expectEqual(i, item.index);
        try expectValue(item.value, .{ .scalar = .{ .str = want[i] } });
        // And the id at each index is the row that produced it, so the
        // position in the answer is tied to the row it came from.
        try testing.expectEqual(want_ids[i], item.opId());
    }
}

test "a clock changes what a sequence reads, and the earlier read is a prefix" {
    const gpa = testing.allocator;
    // Three elements, the middle one deleted at the present. The unscoped
    // read is ["a", "c"]; a clock that stops before the second element was
    // inserted sees only ["a"].
    const list = made(1, 0);
    const del = [_]opmod.SuccEntry{.{ .id = opId(5, 0), .inc = null }};
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .str = "a" }, &.{}),
        row(opId(3, 0), list, anchored(opId(2, 0)), true, .set, .{ .str = "b" }, &del),
        row(opId(4, 0), list, anchored(opId(3, 0)), true, .set, .{ .str = "c" }, &.{}),
    });
    defer doc.destroy();

    var unscoped = try readAll(&doc.set, list, gpa, null);
    defer unscoped.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), unscoped.items.len);
    try expectValue(unscoped.items[0].value, .{ .scalar = .{ .str = "a" } });
    try expectValue(unscoped.items[1].value, .{ .scalar = .{ .str = "c" } });

    var c = try clockUpTo(gpa, 2);
    defer c.deinit();
    var scoped = try readAll(&doc.set, list, gpa, c);
    defer scoped.deinit(gpa);

    // **The two reads differ**, and the scoped one is a strict prefix of the
    // unscoped one: the same element, the same value and the same id at every
    // index the scoped read reaches, and nothing beyond.
    try testing.expect(scoped.items.len < unscoped.items.len);
    for (scoped.items, 0..) |item, i| {
        try testing.expectEqual(i, item.index);
        try testing.expectEqual(unscoped.items[i].index, item.index);
        try testing.expectEqual(unscoped.items[i].opId(), item.opId());
        try expectValue(unscoped.items[i].value, item.value);
        try testing.expectEqual(unscoped.items[i].width, item.width);
    }
}

test "an empty sequence reads as nothing, and a range past its end reads as nothing" {
    const gpa = testing.allocator;
    const empty = made(1, 0);
    const three = made(2, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "e" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(3, 0), three, head(), true, .set, .{ .str = "a" }, &.{}),
        row(opId(4, 0), three, anchored(opId(3, 0)), true, .set, .{ .str = "b" }, &.{}),
        row(opId(5, 0), three, anchored(opId(4, 0)), true, .set, .{ .str = "c" }, &.{}),
    });
    defer doc.destroy();

    // An object with no rows at all: an empty range, and an empty read.
    {
        const rows = try doc.set.scopeToObj(empty);
        try testing.expectEqual(@as(usize, 0), rows.end - rows.start);
        var got = try readAll(&doc.set, empty, gpa, null);
        defer got.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), got.items.len);
    }

    // A range that starts and ends mid-element: indices 1 to 2 of three
    // elements is the middle one, and the *index* it answers is the real one
    // rather than an offset into the range.
    {
        var range = try ListRange(opmod.Op).init(
            &doc.set,
            try doc.set.scopeToObj(three),
            null,
            .{ .start = 1, .end = 2 },
        );
        const item = (try range.next()) orelse return error.TestExpectedItem;
        try testing.expectEqual(@as(usize, 1), item.index);
        try expectValue(item.value, .{ .scalar = .{ .str = "b" } });
        try testing.expect((try range.next()) == null);
    }
    {
        var range = try ListRange(opmod.Op).init(
            &doc.set,
            try doc.set.scopeToObj(three),
            null,
            .{ .start = 1 },
        );
        var seen: usize = 0;
        while (try range.next()) |item| {
            try testing.expectEqual(seen + 1, item.index);
            seen += 1;
        }
        try testing.expectEqual(@as(usize, 2), seen);
    }
    // A range that starts past the end, and a range that is empty because its
    // end is behind its start. Both are defined answers, not corners.
    {
        var past = try ListRange(opmod.Op).init(
            &doc.set,
            try doc.set.scopeToObj(three),
            null,
            .{ .start = 9, .end = null },
        );
        try testing.expect((try past.next()) == null);
    }
    {
        var none = try ListRange(opmod.Op).init(
            &doc.set,
            try doc.set.scopeToObj(three),
            null,
            .{ .start = 2, .end = 1 },
        );
        try testing.expect((try none.next()) == null);
    }
}

test "a half-open index range is the shape the C binding builds, and `end - 1` is the last element it answers" {
    const gpa = testing.allocator;
    const list = made(1, 0);
    // **`test_get_range_values`'s list**
    // ([`automerge-c/test/list_tests.c:233-241`](../../github-automerge-automerge/rust/automerge-c/test/list_tests.c)):
    // eight elements named `First`…`Eighth`, which is what the case's
    // `AMlistRange(doc1, list, 1, 6, NULL)` counts **five** of and its
    // `AMlistRange(doc1, list, 0, SIZE_MAX, NULL)` counts **eight** of.
    //
    // **The C list binding needed no change and this is why**: its header
    // documents `end` as "At least one past the last pos in a range of indices"
    // ([`automerge-c/src/doc/list.rs:603`](../../github-automerge-automerge/rust/automerge-c/src/doc/list.rs)),
    // and [`IndexRange`] is already exactly that — `contains` is `index < end`.
    // The map side had no such arm, which is why the map reader is the one that
    // changed.
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .str = "First" }, &.{}),
        row(opId(3, 0), list, anchored(opId(2, 0)), true, .set, .{ .str = "Second" }, &.{}),
        row(opId(4, 0), list, anchored(opId(3, 0)), true, .set, .{ .str = "Third" }, &.{}),
        row(opId(5, 0), list, anchored(opId(4, 0)), true, .set, .{ .str = "Fourth" }, &.{}),
        row(opId(6, 0), list, anchored(opId(5, 0)), true, .set, .{ .str = "Fifth" }, &.{}),
        row(opId(7, 0), list, anchored(opId(6, 0)), true, .set, .{ .str = "Sixth" }, &.{}),
        row(opId(8, 0), list, anchored(opId(7, 0)), true, .set, .{ .str = "Seventh" }, &.{}),
        row(opId(9, 0), list, anchored(opId(8, 0)), true, .set, .{ .str = "Eighth" }, &.{}),
    });
    defer doc.destroy();

    const Case = struct {
        range: IndexRange,
        want: []const usize,
        what: []const u8,
    };
    const cases = [_]Case{
        // **The whole list**, and the C case's `0..SIZE_MAX` beside it. **The
        // end is a `usize` and not a key**, so a `SIZE_MAX` end cannot
        // overflow the way upstream's `Included(usize::MAX)` does in `normalize_range`.
        .{ .range = .{ .start = 0, .end = 8 }, .want = &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, .what = "the whole list" },
        .{
            .range = .{ .start = 0, .end = std.math.maxInt(usize) },
            .want = &.{ 0, 1, 2, 3, 4, 5, 6, 7 },
            .what = "AMlistRange(0, SIZE_MAX)",
        },
        // **The C case's partial range**: `1..6` is five elements, and the
        // indices it answers are the real ones rather than an offset into the
        // range.
        .{ .range = .{ .start = 1, .end = 6 }, .want = &.{ 1, 2, 3, 4, 5 }, .what = "AMlistRange(1, 6)" },
        // **`begin == end` gives nothing**, and **`begin > end` gives nothing**.
        // A `Range` carries no rows under `start >= end`, and so does this.
        .{ .range = .{ .start = 3, .end = 3 }, .want = &.{}, .what = "begin == end" },
        .{ .range = .{ .start = 6, .end = 1 }, .want = &.{}, .what = "begin > end" },
        // **`end - 1` is the last element it answers**: with `end` at 6 the
        // range stops after 5, and
        .{
            .range = .{ .start = 0, .end = 6 },
            .want = &.{ 0, 1, 2, 3, 4, 5 },
            .what = "end - 1",
        },
        // **and `end` itself is not in it**: the same range with `end` at 7
        // answers 6 as well, which is the only difference between the two.
        .{
            .range = .{ .start = 0, .end = 7 },
            .want = &.{ 0, 1, 2, 3, 4, 5, 6 },
            .what = "end",
        },
        // **An unbounded end is the end of the object**, and a start at the
        // last index is that one element.
        .{ .range = .{ .start = 7 }, .want = &.{7}, .what = "the last element" },
    };
    for (cases) |c| {
        var walk = try ListRange(opmod.Op).init(
            &doc.set,
            try doc.set.scopeToObj(list),
            null,
            c.range,
        );
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(gpa);
        while (try walk.next()) |item| try got.append(gpa, item.index);
        testing.expectEqual(c.want.len, got.items.len) catch |e| {
            std.debug.print("`{s}`: wanted {d} elements, got {d}\n", .{
                c.what, c.want.len, got.items.len,
            });
            return e;
        };
        for (c.want, got.items) |want, seen| try testing.expectEqual(want, seen);
    }
}

test "a list range reader allocates nothing to construct or to read" {
    // `FailingAllocator` with no `fail_index` never fails and counts every
    // byte its inner allocator hands out, so it is a counter and a real
    // allocator at once ([parents.zig:1095-1096](../../opset/parents.zig)). It
    // is the **op set's** allocator, which is the only allocator a walk can
    // reach.
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counter.allocator();

    const list = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .str = "a" }, &.{}),
        row(opId(3, 0), list, anchored(opId(2, 0)), true, .set, .{ .str = "bb" }, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(list);

    // Warm the op set: it sizes its own successor buffer the first time a walk
    // needs one, and that allocation belongs to the op set.
    {
        var warm = try ListRange(opmod.Op).init(&doc.set, rows, null, .all());
        while (try warm.next()) |_| {}
    }

    const before = counter.allocated_bytes;
    var range = try ListRange(opmod.Op).init(&doc.set, rows, null, .all());
    try testing.expectEqual(before, counter.allocated_bytes);

    var seen: usize = 0;
    while (try range.next()) |item| {
        seen += 1;
        try testing.expect(item.value == .scalar);
        try testing.expectEqual(if (item.index == 0) @as(usize, 1) else @as(usize, 2), item.width);
    }
    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqual(before, counter.allocated_bytes);
}

test "a sequence walk moves one element cursor across elements, and answers what a fresh one answers" {
    const gpa = testing.allocator;
    // **One element of the object is two rows long**: the third element's
    // register is an insert and a put, so the width read has to land on the
    // put and not the insert. That is the case where a cursor asked for the
    // wrong row answers a *plausible* wrong width rather than an error, so it
    // is what makes this test worth writing.
    //
    // **It is a text object, not a list**, and that is load-bearing: a list
    // element is one unit wide under every encoding whatever its value
    // ([`Op.width`](../../opset/op.zig), `op.zig:2178-2181`), so on a list
    // every width is 1 and a reader that read the wrong row would still be
    // right. The widths below are 1, 2 and 4 — the third element's insert says
    // `"xx"` and the put that supersedes it says `"yyyy"`, and only the put is
    // `top` ([`index.zig`](../../opset/index.zig), `index.zig:718-720`), so a
    // reader that read the element's **first** row answers 2 where the right
    // answer is 4.
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, &.{}),
        row(opId(2, 0), text, head(), true, .set, .{ .str = "a" }, &.{}),
        row(opId(3, 0), text, anchored(opId(2, 0)), true, .set, .{ .str = "bb" }, &.{}),
        // Element two, written twice: the insert and the put that wins it.
        row(opId(4, 0), text, anchored(opId(3, 0)), true, .set, .{ .str = "xx" }, &.{}),
        row(opId(5, 0), text, anchored(opId(4, 0)), false, .set, .{ .str = "yyyy" }, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(text);

    // **The walk the reader now makes**: one cursor, held, moved. It is the
    // width read's own cursor and the reader never exposes it, so what is
    // checked here is the answer and the fact that it is stable — see the
    // equality against the per-element walk below.
    var walk = try ListRange(opmod.Op).init(&doc.set, rows, null, .all());
    var widths: [3]usize = undefined;
    var seen: usize = 0;
    while (try walk.next()) |item| {
        try testing.expect(seen < widths.len);
        widths[seen] = item.width;
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 4 }, &widths);

    // **The same walk with a fresh cursor per element**, which is what
    // `OpSet.elemidAt` does internally and what the reader used to do. This is
    // the witness for the change being answer-preserving: it is the only
    // statement here that says the two are the same, and it is checked against
    // the widths above rather than against literals, so a reader that moved
    // its cursor wrongly fails here and not on a hard-coded number.
    //
    // The three elements' registers start at rows `+0`, `+1` and `+2`, so the
    // rows asked for are `rows.start`, `+1` and `+2`. The third element's
    // register is **two** rows, which is why the last offset is 2 and not 3 —
    // `+3` is the put inside that same register and `elemidAt` on it names the
    // element `+2` already named, so asking there would test nothing new.
    const first_row_of = [_]usize{ 0, 1, 2 };
    for (first_row_of, widths) |offset, want| {
        const elem = try doc.set.elemidAt(rows.start + offset, rows.end);
        try testing.expect(elem != null);
        const cell = (try doc.set.cols.index.text.get(elem.?.last_pos)) orelse return error.TestExpectedEqual;
        const width = cell orelse return error.TestExpectedEqual;
        try testing.expectEqual(want, @as(usize, width));
    }

    // **The cursor the reader holds is placed and ahead of the row it last
    // answered**, which is the property that makes the next element's read a
    // move rather than a rebuild. `isPlaced` is false only before the first
    // successful read and after a refusal, so a walk that got this far and
    // then rebuilt would still report true — so this pins the *placement*,
    // and the widths above pin the answer.
    try testing.expect(walk.elems.isPlaced());
    try testing.expect(walk.elems.pos() >= rows.start);

    // **A shift onto rows behind the reader is refused**, and the element
    // cursor is what makes holding one across a shift safe rather than a way to
    // read a stale row. The reader's row cursors are hexane shifts, which are
    // `set_max` plus `advance_to` and never rewind
    // ([`Unshift.shift`](tools.zig), `tools.zig:387-398`, `shift.rs:272-274`),
    // and upstream's `shift_next` asserts the rule this port refuses with
    // (`column.rs:629-633`, `assert!(range.start >= self.pos)`).
    //
    // **Read forward to the end first**, so the window below is behind the
    // reader **because** the walk was exhausted and not by accident of where it
    // stopped. **The third element's register is the two rows at
    // `rows.start + 2` and `rows.start + 3`** — the insert and the put that
    // supersedes it — so the window covers both of them and sits two registers
    // behind where the reader stands. The error is what says so; a reader that
    // answered it would be answering rows it has already passed, and the width
    // it would report is the whole thing this test is about.
    var shifted = try ListRange(opmod.Op).init(&doc.set, rows, null, .all());
    while (try shifted.next()) |_| {}
    try testing.expectError(error.InvalidValue, shifted.shiftNext(.{
        .start = rows.start + 2,
        .end = rows.start + 4,
    }));
    //
    // **A window ahead of the reader is refused on this fixture too, and that is
    // upstream's shape rather than this port's**: `BoolColumnSkipper.next`
    // consumes the **whole run** of visible rows it lands in
    // ([`BoolColumnSkipper.next`](../../hexane/column.zig), `iter/tools.rs:355-368`),
    // and every row of this object is visible, so one read leaves the visible
    // cursor at the end of the op set and nothing inside the object can be
    // shifted onto. It is recorded here so the next reader of this test does not
    // look for a successful shift here: the only window that answers is an empty
    // one past the last row.

    // **The width read behind where the cursor stands answers what a fresh one
    // answers**, which is the promise that lets the cursor be held at all:
    // `seek` moves the five forwards and rebuilds them for a row behind them,
    // and the two paths differ in what they read on the way to the row and not
    // in what they answer ([`ElemWalk.at`](../../opset/op_set.zig),
    // `op_set.zig:5892-5900`, `:5938-5962`).
    //
    // **The rows read are the first element's**, two registers behind where the
    // exhausted walk left the five — that walk last answered the third element,
    // whose register opens at `rows.start + 2` — so this takes `seek`'s
    // **rebuild** arm. The answer is the width the fresh `elemidAt` walk gave for
    // offset 0: one, the width of `"a"`, and not the width of whichever row a
    // cursor left in place would have answered.
    const rebuilt = (try walk.elems.at(rows.start, rows.end)) orelse return error.TestExpectedEqual;
    try testing.expectEqual(rows.start, rebuilt.last_pos);
    const cell = (try doc.set.cols.index.text.get(rebuilt.last_pos)) orelse return error.TestExpectedEqual;
    const width = cell orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 1), @as(usize, width));

    // **And the answer that shift would have had is the answer a fresh cursor
    // gives**, which is the point of the rebuild arm above: had the window been
    // servable, the put that wins the third element carries the width of
    // `"yyyy"`, four code points, on the **last** row of the register, and its
    // insert says `"xx"`, so a width read that landed on the first row of the
    // register would answer 2. That is the width the fresh walk above reported
    // for offset 2, and it is the one this reader reported while walking.
}

test "an owned list item frees every byte it copied" {
    const gpa = testing.allocator;
    const list = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .str = "a" }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, list, gpa, null);
    defer got.deinit(gpa);

    var owned = try got.items[0].intoOwned(gpa);
    defer owned.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), owned.index);
    try testing.expectEqual(@as(usize, 1), owned.width);
    try expectValue(owned.value.value, .{ .scalar = .{ .str = "a" } });
    try testing.expectEqual(opId(2, 0), owned.id.opId().?);
}

test "a five-element list with one register written twice reads five elements, the later value, and a conflict only there" {
    const gpa = testing.allocator;
    // Upstream's `list_range_conflict` (`list_range.rs:407-441`), case for
    // case: two actors write index 3 concurrently, the documents merge, and
    // the reader reports five elements with `[false, false, false, true,
    // false]` for conflict and the **later** operation's value at index 3.
    // Upstream reaches that shape with a fork and a merge; a fixture writes
    // the merged op set directly, which is the same rows.
    //
    // **The register an insert belongs to is its own element id**
    // ([`Op.elemid_or_key`](../../opset/op.zig), `op.rs:1041-1047`), not the
    // element it hangs by — so register `(5, 0)` holds the insert that made
    // element 3 *and* the two puts aimed at element 3, while register
    // `(6, 0)` holds only the insert that made element 4. That is why the
    // fifth insert's row is written **after** the two puts and not in counter
    // order: registers ascend by key
    // ([`op.rs:1059-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
    // and the reader does not sort, so the order written here is the order the
    // answers come back in.
    const list = made(1, 0);
    const doc = try Fixture.build(gpa, &.{ actor_a, actor_b }, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .int = 1 }, &.{}),
        row(opId(3, 0), list, anchored(opId(2, 0)), true, .set, .{ .int = 2 }, &.{}),
        row(opId(4, 0), list, anchored(opId(3, 0)), true, .set, .{ .int = 3 }, &.{}),
        // Element 3: the insert, then the two concurrent writes to it.
        row(opId(5, 0), list, anchored(opId(4, 0)), true, .set, .{ .int = 4 }, &.{}),
        row(opId(7, 0), list, anchored(opId(5, 0)), false, .set, .{ .int = 10 }, &.{}),
        row(opId(8, 1), list, anchored(opId(5, 0)), false, .set, .{ .int = 11 }, &.{}),
        // Element 4, whose own register is the last one in the object.
        row(opId(6, 0), list, anchored(opId(5, 0)), true, .set, .{ .int = 5 }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, list, gpa, null);
    defer got.deinit(gpa);

    // **Five elements, not four and not six.** A conflicted register is one
    // element, and a reader that counted rows would report six.
    try testing.expectEqual(@as(usize, 5), got.items.len);
    // The values, **in order** — an order-blind check would pass on a read
    // that shuffled them, and the reader does not sort.
    const want = [_]i64{ 1, 2, 3, 11, 5 };
    // The conflict flags, **in order**: one true, at index 3, and nowhere
    // else (`list_range.rs:150`).
    const want_conflict = [_]bool{ false, false, false, true, false };
    for (got.items, 0..) |item, i| {
        try testing.expectEqual(i, item.index);
        try expectValue(item.value, .{ .scalar = .{ .int = want[i] } });
        try testing.expectEqual(want_conflict[i], item.conflict);
    }
    // **The winner is the later operation of the register**, which is the row
    // the reader reported and not the one that came first in it.
    try testing.expectEqual(opId(8, 1), got.items[3].opId());
}

test "an element's counter wraps rather than trapping when its total overflows i64" {
    const gpa = testing.allocator;
    const list = made(1, 0);
    // **The stored value is `i64`'s maximum and the covered increment is one**,
    // so `current + after` is one past the width — the same overflow the map
    // reader folds, and the same answer. Upstream adds with a checked operator
    // (`list_range.rs:135-141`) and traps there in a checked build; this folds
    // the total the way [`Op.fixCounter`](../opset/op.zig) materialises one,
    // modulo 2^64, so a corrupt counter cannot stop the process.
    const bumped = [_]opmod.SuccEntry{.{ .id = opId(3, 0), .inc = 1 }};
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(
            opId(2, 0),
            list,
            head(),
            true,
            .set,
            .{ .counter = ScalarValue.Counter.init(std.math.maxInt(i64)) },
            &bumped,
        ),
        // **The increment is a row of its own**, the same shape the map
        // reader's fixture has and for the same reason: the index only takes
        // one off the counter's successor count when the increment's own
        // operation is processed (`index.rs:196-203`), and that count is what
        // `IndexBuilder.flush` scans for the register's winner. An edge with
        // no row behind it would leave the element a row no register wins.
        row(opId(3, 0), list, anchored(opId(2, 0)), false, .increment, .{ .int = 1 }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, list, gpa, null);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try expectValue(got.items[0].value, .{
        .scalar = .{ .counter = ScalarValue.Counter.init(std.math.minInt(i64)) },
    });
}

test "an element's net counter change wraps when the diff's two clocks are concurrent" {
    const gpa = testing.allocator;
    const list = made(1, 0);
    // **Two concurrent increments on one element's counter** — one at `i64`'s
    // maximum and one at -2 — and a diff whose two states do not nest: the
    // before state has seen the first, the after state the second. That is what
    // a diff of two concurrent heads is, and `-2 - (2^63 - 1)` is one past the
    // bottom of the width. Each side is summed one edge at a time without
    // overflowing, so the wrap is this subtraction's and not the sums'.
    const concurrent = [_]opmod.SuccEntry{
        .{ .id = opId(3, 0), .inc = std.math.maxInt(i64) },
        .{ .id = opId(4, 1), .inc = -2 },
    };
    const doc = try Fixture.build(gpa, &.{ actor_a, actor_b }, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(
            opId(2, 0),
            list,
            head(),
            true,
            .set,
            .{ .counter = ScalarValue.Counter.init(0) },
            &concurrent,
        ),
        // **The two increments, one row per edge.** A row aiming at `seq(2, 0)`
        // without inserting is the *same register* as the insert that made
        // that element — a register is named by the element it hangs by, not
        // by the id of the row ([`Op.elemidOrKey`](../opset/op.zig),
        // `op.rs:1040-1046`) — which is what makes these this element's
        // increments rather than elements of their own.
        row(opId(3, 0), list, anchored(opId(2, 0)), false, .increment, .{ .int = std.math.maxInt(i64) }, &.{}),
        row(opId(4, 1), list, anchored(opId(2, 0)), false, .increment, .{ .int = -2 }, &.{}),
    });
    defer doc.destroy();

    var before = try Clock.init(gpa, 2);
    defer before.deinit();
    _ = before.include(0, 3);
    var after = try Clock.init(gpa, 2);
    defer after.deinit();
    _ = after.include(1, 4);

    var diff = try ListDiff(opmod.Op).init(&doc.set, try doc.set.scopeToObj(list), .{
        .diff = .{ .before = before, .after = after },
    });
    const item = (try diff.next()) orelse return error.TestExpectedItem;

    // **The after clock has not seen actor 0 at all**, so the element is gone
    // from the after state and the row is tagged as its removal; a diff still
    // reports the counter it carried.
    try testing.expectEqual(Diff.del, item.diff);
    // `-(2^63) - 1` has the same bits as `2^63 - 1`.
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), item.inc);
    try expectValue(item.value, .{ .scalar = .{ .counter = ScalarValue.Counter.init(-2) } });
    try testing.expect((try diff.next()) == null);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`list_range_conflict` is ported, and it was the one `#[test]` in
//   upstream's file with no port beside it.** Upstream is
//   [`list_range.rs:407-441`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs):
//   two actors write index 3 concurrently, the documents merge, and the read
//   is five elements with conflict `[false, false, false, true, false]` and
//   the **later** operation's value at index 3. The new test "a five-element
//   list with one register written twice reads five elements, the later
//   value, and a conflict only there" writes the merged op set directly,
//   which is the same rows, and asserts the same five values, the same five
//   flags **in that order**, and the winner's op id.
//
// * **A register is named by the *insert's own* element id, not by the
//   element it hangs by, and the fixture's row order is not counter order
//   because of it.** [`Op.elemid_or_key`](../../opset/op.zig) is
//   [`op.rs:1041-1047`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):
//   `if self.insert { KeyRef::Seq(ElemId(self.id)) } else { self.key }`. So
//   the fifth insert's register is `(6, 0)` and the register `(5, 0)` holds
//   the insert that made element 3 **and** the two puts aimed at element 3.
//   `insert_acc` is a `PrefixColumn<bool>` over the per-row `insert` flag
//   ([`columns.rs:28`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs),
//   [`op_set.rs:902-904`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
//   so the running total separates those two elements and the fixture's fifth
//   insert row has to be written **last**. Getting that wrong groups element
//   4 with element 3's puts and the read comes back with four elements.
//
// * **`ListDiff.shiftNext`'s index reset had no test until `doc.zig`'s
//   `DiffIter` test drove the list arm twice.**
//   [`list_range.rs:77`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)
//   is `self.index = 0;`, and it is a line the map reader does not have.
//   Deleting it left all twelve tests here green; it is
//   `doc.zig`'s "the document diff reads the root's rows and then descends
//   into each child, in order" that fails, with `expected 0, found 2` at
//   `doc.zig:1702` — the second list's first element reported as index 2. **A
//   single list child would not catch it**, which is why that test has two.
//
// * **`IndexRange` is half-open and four-arm `RangeBounds` is not.**
//   Upstream's `normalize_range` ([`list_range.rs:359-372`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs))
//   is `Excluded(0) as a start bound underflows and `Included(usize::MAX)` as
//   an end bound overflows`; the port's `struct { start: usize, end: ?usize }`
//   removes both. That is a deliberate shape change driven by `API.md`, so
//   `list_range_bounds`'s `..`, `..=3` and `1..=3` arms have no port
//   equivalent, and the case is covered by the eight shapes of "a half-open
//   index range is the shape the C binding builds" instead.

test "API parity owned list result survives document destruction" {
    const gpa = testing.allocator;
    const list = made(1, 0);
    var owned = blk: {
        const actor_bytes = try gpa.dupe(u8, &.{ 0, 255, 128 });
        defer gpa.free(actor_bytes);
        const doc = try Fixture.build(gpa, &.{types.ActorId.init(actor_bytes)}, &.{
            row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
            row(opId(2, 0), list, head(), true, .set, .{ .str = "a" }, &.{}),
        });
        defer doc.destroy();
        var got = try readAll(&doc.set, list, gpa, null);
        defer got.deinit(gpa);
        break :blk try got.items[0].intoOwned(gpa);
    };
    defer owned.deinit(gpa);
    try expectValue(owned.value.value, .{ .scalar = .{ .str = "a" } });
    try testing.expectEqualSlices(u8, &.{ 0, 255, 128 }, owned.id.actorBytes().?.bytes);
}

test "API parity failed list reposition preserves the next unread element and index" {
    const gpa = testing.allocator;
    const list = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .str = "a" }, &.{}),
        row(opId(3, 0), list, anchored(opId(2, 0)), true, .set, .{ .str = "b" }, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(list);
    var range = try ListRange(opmod.Op).init(&doc.set, rows, null, .all());
    try testing.expectEqual(@as(usize, 0), (try range.next()).?.index);
    try testing.expectError(error.InvalidValue, range.shiftNext(rows));
    const next = (try range.next()).?;
    try testing.expectEqual(@as(usize, 1), next.index);
    try expectValue(next.value, .{ .scalar = .{ .str = "b" } });
    try testing.expect((try range.next()) == null);
}

test "list row steps match positional reads and retain complete invisible register widths" {
    const gpa = testing.allocator;
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, &.{}),
        row(opId(2, 0), text, head(), true, .set, .{ .str = "old" }, &.{.{ .id = opId(3, 0), .inc = null }}),
        row(opId(3, 0), text, anchored(opId(2, 0)), false, .set, .{ .str = "wider" }, &.{}),
        row(opId(4, 0), text, anchored(opId(2, 0)), true, .set, .{ .str = "x" }, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(text);
    var forward = ListIter.init(
        try doc.set.idIterRange(rows),
        try doc.set.insertAccRange(rows),
        try doc.set.actionIterRange(rows),
        try doc.set.valueIterRange(rows),
    );
    var positional = forward;
    var shifted = forward;
    try shifted.shift(.{ .start = rows.start + 1, .end = rows.end });
    try testing.expectEqualStrings("wider", (try shifted.next()).?.value.str);
    try testing.expectEqualStrings("x", (try shifted.next()).?.value.str);
    try testing.expect((try shifted.next()) == null);
    for (rows.start..rows.end) |pos| {
        const got = (try forward.next()).?;
        const want = (try positional.shiftNext(.{ .start = pos, .end = rows.end })).?;
        try testing.expectEqual(want.id, got.id);
        try testing.expectEqual(want.pos, got.pos);
        try testing.expectEqual(want.inserts, got.inserts);
        try testing.expectEqual(want.action, got.action);
        try testing.expect(want.value.eql(got.value));
    }
    try testing.expect((try forward.next()) == null);
    try testing.expect((try forward.next()) == null);
    var clock = try clockUpTo(gpa, 2);
    defer clock.deinit();
    var historical = try ListRange(opmod.Op).init(&doc.set, rows, clock, .all());
    const item = (try historical.next()).?;
    try expectValue(item.value, .{ .scalar = .{ .str = "old" } });
    // The later invisible row completes this register and holds its current width.
    try testing.expectEqual(@as(usize, 5), item.width);
    try testing.expect((try historical.next()) == null);
}

test "short list row streams return partial exhaustion" {
    const gpa = testing.allocator;
    const list = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(2, 0), list, head(), true, .set, .{ .str = "payload" }, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(list);
    for (0..5) |short_column| {
        var iter = ListIter.init(
            try doc.set.idIterRange(rows),
            try doc.set.insertAccRange(rows),
            try doc.set.actionIterRange(rows),
            try doc.set.valueIterRange(rows),
        );
        switch (short_column) {
            0 => iter.id.actor.setMax(rows.start),
            1 => iter.id.ctr.setMax(rows.start),
            2 => iter.inserts.setMax(rows.start),
            3 => iter.action.setMax(rows.start),
            4 => iter.value.setMax(rows.start),
            else => unreachable,
        }
        try testing.expect((try iter.next()) == null);
        try testing.expect((try iter.next()) == null);
    }
}
