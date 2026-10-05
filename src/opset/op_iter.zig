//! The op set's row iterator: the per-column sub-iterators it holds in step,
//! the errors a bad read raises, and the `try_load` family the document
//! API's `get`, `getAt` and cursor resolution route through.
//!
//! Upstream `op_set2/op_set/op_iter.rs`, 1335 lines, owns:
//!
//! | what | upstream |
//! |------|----------|
//! | [`OpIter`] and its eleven fields | `:19-32` |
//! | [`ReadOpError`] | `:66-78` |
//! | the four `try_load` functions | `:196-265` |
//! | [`OpIdIter`], [`InsertIter`], [`KeyIter`], [`ObjIdIter`], [`MarkInfoIter`], [`ActionIter`], [`ActionValueIter`], [`ValueIter`], [`SuccIterIter`] | `:267-1103` |
//! | [`CtrWalker`], [`SuccWalker`] | `:293-339` |
//!
//! # `OpIter` holds eleven fields, eight of them sub-iterators
//!
//! The struct has eleven fields (`op_iter.rs:20-31`): `pos`, eight
//! sub-iterators, `range` and the op set. The eight sub-iterators hold
//! seventeen column cursors between them, and advancing all seventeen in
//! lockstep is what yields one row.
//!
//! # The lockstep invariant, established at construction
//!
//! Upstream gets "every data column is the same length" from Rust's type
//! system: `OpIter` cannot exist unless [`columns.Columns`] was built whole.
//! Zig has no such guarantee, and upstream checks the property in exactly
//! one place — `validate_top_index` (`op_set2/op_set.rs:177-186`), a debug
//! assertion the survey names as the one spot a port would need `unsafe`
//! for ([survey §Zig mapping notes](../../docs/survey/02-transaction-opset.md)).
//!
//! **The port establishes it instead of asserting it.** [`checkRowLengths`]
//! is O(1) — thirteen `len()` calls, no walk, no allocation — and
//! [`OpIter.init`] calls it, so a column set that cannot be walked as one
//! row per position is `error.UnexpectedEnd` at construction rather than a
//! wrong answer later. [`rowLengthMismatch`] names the offending column so
//! a caller can report it, and `test "every row-indexed column of a spliced
//! op set is the same length"` proves the property holds on a set built by
//! `Columns.splice` and fails when one column is shortened behind it.
//!
//! # The storage behind an `Op` must outlive it
//!
//! This is the other half of upstream's `'a`, and it belongs on the type
//! that hands the `Op` out rather than in a comment elsewhere. Every `Op`
//! [`OpIter.next`] produces points its map key, its `str`/`bytes` payload,
//! its mark name and its successors into storage this file does not own:
//! the column set, the document's string table, and — for the successors —
//! the caller's buffer. The rules are:
//!
//! * the `Columns` the iterator was built from, and the `StringTable` it
//!   was given, must outlive every `Op` it produces;
//! * the successor buffer passed to [`OpIter.init`] must outlive every
//!   `Op` it produces, and only the most recent row's successors are
//!   readable from it — the next `next` overwrites them;
//! * an `Op` cannot outlive a mutation of the op set, exactly as
//!   [`op.Op`] says for itself.
//!
//! # Constructing an iterator allocates nothing
//!
//! [`OpIter.init`] takes no allocator, because it needs none: every
//! column cursor is a pointer and a few numbers (`column.zig:3389-3414`),
//! and the one buffer the walk needs is the caller's. [`CtrWalker`] is the
//! one exception and says so on its own type: the B-tree descent behind
//! `findByRange` is a stack of frames
//! ([`btree.FindByValueRange`](../../src/hexane/btree.zig)) sized to the
//! tree's height, freed by [`CtrWalker.deinit`]. Nothing on the
//! [`OpIter`] path constructs one.
//!
//! # What is not here
//!
//! * `OpIterState`, `OpIdIterState` and the seven other `*IterState`
//!   types, with `suspend` and `try_resume` (`op_iter.rs:33-64`,
//!   `:273-291`, `:414-425`, …). Upstream marks both ends
//!   `#[allow(unused)]` and the port's `Column.Iterator` has no
//!   `suspend`/`IterState` to suspend into, so there is nothing to build
//!   on. `docs/plan.md` §2 drops upstream dead code.
//! * `OpIter`'s `Shiftable` impl. Upstream has none: `Shiftable` is
//!   implemented for the eight sub-iterators, and the op set composes it.
//!   All eight carry the full kernel here ([`assertShiftable`] proves it at
//!   compile time), so a walk can be repositioned into a child object
//!   without allocating.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
// The clock a scoped read is scoped to. `Op.scopeToClock` takes one
// (`op.zig`), and this file's tests drive that rule, so the type is named
// here. It is not a new edge in the module graph: `clock.zig` imports
// `types.zig` and nothing else, and `op.zig` already imports both.
const clocks = @import("../clock.zig");
const btree = @import("../hexane/btree.zig");
const column = @import("../hexane/column.zig");
const rawcol = @import("../hexane/raw.zig");
const optypes = @import("types.zig");
const opcols = @import("columns.zig");
const opmod = @import("op.zig");

const Action = optypes.Action;
const ActorIdx = optypes.ActorIdx;
const KeyRef = optypes.KeyRef;
const ScalarValue = optypes.ScalarValue;
const StringTable = opcols.StringTable;
const ValueMeta = optypes.ValueMeta;

const ElemId = types.ElemId;
const ExId = types.ExId;
const ObjId = ExId;
const OpId = types.OpId;

const MarkData = optypes.MarkData;
const Op = opmod.Op;
const SuccCursors = opmod.SuccCursors;

const SuccEntry = opmod.SuccEntry;
const Clock = clocks.Clock;

const RowRange = column.RowRange;
const ParseError = err.ParseError;

// ── Errors ──────────────────────────────────────────────────────────────────

/// Why a read of the op set did not produce a row
/// (`ReadOpError`, `op_iter.rs:66-78`).
///
/// A lookup that fails is one of these, never a `null` a caller can forget
/// to check: `next` answers `null` for one thing only, the end of the walk.
///
/// The same holds for every `next` in this file, and it is stated here
/// because the trap is easy to fall into one layer down. Each
/// sub-iterator's item type is *total* — `bool`, `Action`, `KeyRef`,
/// `ObjId`, `ScalarValue`, `SuccCursors`, `OpId` — so a row that carries
/// nothing is a value, not a `null`: a row with no mark is
/// `MarkInfo{ .name = null, … }`, a row with no successors is an empty
/// `SuccCursors`, a row that names no property at all is
/// `error.MissingKey`. Only the walk's own end is `null`. The
/// counter-example is one layer down: the mark index's
/// `ValueIter.next` answers `null` both for a row carrying no mark and for
/// the end of the window
/// ([`mark_index.zig:488-496`](mark_index.zig), which says so and is
/// therefore walked run at a time, `op_set2/op_set.rs:981-987`), and
/// nothing here copies that shape.
///
/// Upstream's `MissingValue(&'static str)` names the column that ran out
/// (`op_iter.rs:75`). A Zig error carries no payload, so the name is not
/// here: the sub-iterator that raises it is the only source, and the call
/// site already knows which column it asked for. Upstream's
/// `InvalidValue(#[from] ReadScalarError)` (`op_iter.rs:77`) is
/// `ParseError.InvalidValue` here, which is the same thing — a value's
/// bytes do not decode to its declared type.
pub const ReadOpError = error{
    /// The two halves of an op id are not an op id: one is missing, or the
    /// counter is negative (`op_iter.rs:69`, `:200-205`).
    InvalidOpId,
    /// The three key columns do not name a key (`op_iter.rs:71`).
    InvalidKey,
    /// All three key columns are null, which is not a key
    /// (`op_iter.rs:73`, `:261`).
    MissingKey,
    /// A column ran out before the walk did (`op_iter.rs:75`).
    MissingValue,
} || ParseError;

// ── The `try_load` family ──────────────────────────────────────────────────

/// An op id from its two columns (`OpId::try_load`, `op_iter.rs:196-208`).
///
/// A hit needs both halves and a counter that is not negative; the counter
/// is widened to `u32` here, as upstream's `counter as u64` is to a `u64`.
pub fn tryLoadOpId(actor: ?ActorIdx, ctr: ?i64) ReadOpError!OpId {
    const a = actor orelse return error.InvalidOpId; // :203-205
    const c = ctr orelse return error.InvalidOpId;
    if (c < 0) return error.InvalidOpId; // :202
    return OpId.init(std.math.cast(u32, c) orelse return error.Overflow, a);
}

/// An object id from its two columns (`ObjId::try_load`, `op_iter.rs:210-233`).
///
/// Two readings upstream has and this keeps, because the object columns
/// are what a root row is stored as: both halves null is the root
/// (`:227`), and so is a counter of zero whatever the actor column says
/// (`:217-219`).
pub fn tryLoadObjId(actor: ?ActorIdx, ctr: ?i64) ReadOpError!ObjId {
    if (actor == null and ctr == null) return .root; // :227
    const a = actor orelse return error.InvalidOpId; // :228-230
    const c = ctr orelse return error.InvalidOpId;
    if (c < 0) return error.InvalidOpId; // :226
    if (c == 0) return .root; // :217-219
    return .{ .id = OpId.init(std.math.cast(u32, c) orelse return error.Overflow, a) };
}

/// A sequence anchor from its two columns (`ElemId::try_load`,
/// `op_iter.rs:235-249`).
///
/// The three shapes the two key columns can have, and which of them is
/// which, are tabulated on [`types.ElemId`](../../src/types.zig); they are
/// not repeated here. What this function adds is *why* the three are
/// distinguishable at all. The head is not a bit — it is the value
/// `OpId(0, 0)`, the same sentinel that is the root object's own id
/// (`types.rs:30`, and `head`/`is_head` at `:674-679`), because a counter of
/// zero is not an operation's counter. So `head()` and `fromOpId(OpId(0, 0))`
/// are one anchor and not two, and no constructor can produce an anchor that
/// is almost a head. The only question a caller has to ask of a sequence row
/// is whether its actor column is there.
///
/// The shape that question turns on is the one the counter alone cannot
/// settle: a row with both columns absent is a map key, not a head.
pub fn tryLoadElemId(key_actor: ?ActorIdx, key_counter: ?i64) ReadOpError!?ElemId {
    const c = key_counter orelse {
        // (None, None) => Ok(None), a map key rather than a head  :241
        if (key_actor == null) return null;
        return error.InvalidKey; // :246
    };
    const a = key_actor orelse {
        // (Some(0), None) => the head  :242
        if (c == 0) return ElemId.head();
        return error.InvalidKey;
    };
    // (Some(counter), Some(actor)) if counter > 0  :243-244
    if (c <= 0) return error.InvalidKey;
    return ElemId.fromOpId(OpId.init(std.math.cast(u32, c) orelse return error.Overflow, a));
}

/// A key from its three columns (`KeyRef::try_load`, `op_iter.rs:251-265`).
///
/// A map key and a sequence anchor are exclusive (`:259-260`); both present
/// is a document that claims a row is both (`:262`) and neither is a row
/// with no property at all (`:261`).
pub fn tryLoadKeyRef(
    key_str: ?[]const u8,
    key_actor: ?ActorIdx,
    key_ctr: ?i64,
) ReadOpError!KeyRef {
    const elemid = try tryLoadElemId(key_actor, key_ctr);
    if (key_str) |s| {
        if (elemid != null) return error.InvalidKey; // :262
        return .{ .map = s }; // :259
    }
    if (elemid) |e| return .{ .seq = e }; // :260
    return error.MissingKey; // :261
}

// ── The sub-iterators ──────────────────────────────────────────────────────

/// A mark's name and whether it expands past its span — the two columns
/// read as one, which is what upstream's `(Option<&str>, bool)` item is
/// (`MarkInfoIter::Item`, `op_iter.rs:755`).
pub const MarkInfo = struct {
    /// The interned mark name resolved to bytes, or null for a mark's end
    /// (`op_iter.rs:728`, `op_set2/columns.rs:32`).
    name: ?[]const u8,
    /// The `expand` column (`op_iter.rs:728`).
    expand: bool,
};

/// An action, its value, and the row they were read from
/// (`ActionValueIter::Item`, `op_iter.rs:779`).
pub const ActionValue = struct {
    /// The action column's value.
    action: Action,
    /// The value column's scalar.
    value: ScalarValue,
    /// The row the other two came from: the action cursor's position less
    /// the row it just consumed (`op_iter.rs:785-786`).
    pos: usize,
};

/// The two halves of each row's own id (`OpIdIter`, `op_iter.rs:267-271`).
///
/// Two column cursors held in step, and the whole of the cursor kernel every
/// sub-iterator here carries: `pos`/`maxPos` are the row the cursor stands on
/// and the closed end of its window, `setMax` closes the window,
/// `advanceTo`/`advanceBy` consume forward only, `shift` moves the window onto
/// a range *and* lands the walk on its start, `shiftNext` is `shift` followed
/// by a read, and `seekTo` reads a row forward of the cursor. Nothing here
/// moves backwards — that is the kernel's rule, not a per-type one — and
/// nothing allocates.
pub const OpIdIter = struct {
    /// `id_actor`, the actor half (`op_iter.rs:269`).
    actor: opcols.ActorColumn.Iterator,
    /// `id_ctr`, the counter half, delta coded (`op_iter.rs:270`).
    ctr: opcols.CounterColumn.Iterator,

    /// The compile-time proof that this type carries the whole `Shiftable`
    /// kernel (`column.Shiftable`, `hexane/src/iter/tools.rs:19-74`); it is
    /// what lets a walk be repositioned into a child object without
    /// allocating. [`assertShiftable`] is what makes the mark mean something.
    pub const shiftable = column.Shiftable(OpIdIter);

    /// A cursor over the two id columns, positioned at row 0 with its window
    /// open to the end of both columns.
    ///
    /// The two cursors must be over the same column of the same column set:
    /// they are read in lockstep and `pos` is the first one's, so a mismatched
    /// pair yields a walk whose two halves describe different rows. Every
    /// caller here builds them from one `Columns` and the check that proves
    /// the lengths agree is [`checkRowLengths`].
    pub fn init(
        actor: opcols.ActorColumn.Iterator,
        ctr: opcols.CounterColumn.Iterator,
    ) OpIdIter {
        return .{ .actor = actor, .ctr = ctr };
    }
    /// The row this cursor stands on — that is, how many rows have been
    /// consumed (`Shiftable::pos`, `shift.rs:56-58`). It is the `id_actor`
    /// cursor's position, and the two are kept equal, so it names the row for
    /// both halves.
    pub fn pos(self: *const OpIdIter) usize {
        return self.actor.pos();
    }

    /// The row past the last one this cursor may reach (`Shiftable::max_pos`,
    /// `shift.rs:59-61`): the window's closed end, which `setMax` moves and
    /// the kernel clamps every advance to. A window that has been closed at or
    /// past the end of the column is the column's own length.
    pub fn maxPos(self: *const OpIdIter) usize {
        return self.actor.maxPos();
    }

    /// Closes the window at `at` (`Shiftable::set_max`, `shift.rs:62-66`).
    ///
    /// Only the far end moves: the cursor stays where it is, and an `at`
    /// behind the cursor does not rewind it. `at` past the end of the columns
    /// is clamped to their length. Both cursors move together, because their
    /// windows are one window.
    pub fn setMax(self: *OpIdIter, at: usize) void {
        self.actor.setMax(at);
        self.ctr.setMax(at);
    }

    /// Consumes rows until the cursor stands on `target`
    /// (`Shiftable::advance_to`, `shift.rs:67-72`).
    ///
    /// `target` at or behind the current [`pos`] is a no-op: the walk only
    /// ever moves forward, as upstream's `advance_to` does
    /// (`op_iter.rs:616-623`). A `target` past the window is an
    /// `error.UnexpectedEnd`, which is the one way the kernel reports a walk
    /// asked for a row the columns do not have.
    pub fn advanceTo(self: *OpIdIter, target: usize) ParseError!void {
        try self.actor.advanceTo(target);
        try self.ctr.advanceTo(target);
    }

    /// Consumes `amount` more rows, saturating rather than wrapping
    /// (`Shiftable::advance_by`, `shift.rs:73-76`). The saturation is what
    /// makes `advanceBy` on a cursor near the end of the column land on its
    /// last row instead of behind it.
    pub fn advanceBy(self: *OpIdIter, amount: usize) ParseError!void {
        return self.advanceTo(self.actor.pos() +| amount);
    }

    /// Moves the walk onto `range`: the window follows the range **and** the
    /// walk lands on its start (`Shiftable::shift`, `shift.rs:50-55`), which
    /// upstream's [`Column.Iterator.shift`](../../src/hexane/column.zig) is
    /// `setMax` then `advanceTo` for (`column.rs:542-545`).
    ///
    /// **This reads nothing and answers nothing.** It is `setMax(range.end)`
    /// followed by `advanceTo(range.start)`, so it does move the walk — to the
    /// *first* row of the range — and the caller reads from there with
    /// [`shiftNext`] or [`seekTo`]. Both id cursors move together.
    pub fn shift(self: *OpIdIter, range: RowRange) ParseError!void {
        var actor = self.actor;
        var ctr = self.ctr;
        try actor.shift(range);
        try ctr.shift(range);
        self.actor = actor;
        self.ctr = ctr;
    }

    /// Repositions onto `range` and reads the row at its start
    /// (`Shiftable::shift_next`, `shift.rs:77-86`).
    ///
    /// `shift` then a read, so on return the cursor stands on
    /// `range.start` — not past it — and the next [`maybeTryNext`] answers the
    /// *following* row. `null` means `range.start` is at or past the end of the
    /// window, which is the whole of the end-of-walk answer this method has.
    /// Both halves advance before the answer, so the two cursors stay in step
    /// even when one of them ends first.
    pub fn shiftNext(self: *OpIdIter, range: RowRange) ParseError!?OpId {
        const a = (try self.actor.shiftNext(range)) orelse return null;
        const c = (try self.ctr.shiftNext(range)) orelse return null;
        return OpId.init(c, a);
    }

    /// Reads row `at` and consumes through it (`Shiftable::seek_to`,
    /// `shift.rs:87-96`).
    ///
    /// Forward only, as every seek in the op set is: an `at` behind the
    /// cursor answers `null` and leaves the cursor where it is, which is why
    /// `null` here is "cannot go back" rather than "no such row" — the same
    /// `null` a walk past the end gives. On a non-null answer the cursor
    /// stands on `at`, and the two halves have both consumed through it.
    pub fn seekTo(self: *OpIdIter, at: usize) ParseError!?OpId {
        const a = (try self.actor.seekTo(at)) orelse return null;
        const c = (try self.ctr.seekTo(at)) orelse return null;
        return OpId.init(c, a);
    }

    /// The next row's id, or null at the end of the window
    /// (`maybe_try_next`, `op_iter.rs:350-361`).
    ///
    /// Both cursors advance before the answer, so an id column that ends
    /// early does not leave the other one behind — and a half-present id is
    /// `error.MissingValue` rather than a row with a missing half.
    pub fn maybeTryNext(self: *OpIdIter) ReadOpError!?OpId {
        const actor = try self.actor.next();
        const ctr = try self.ctr.next();
        if (actor == null) return null; // :358
        return OpId.init(ctr orelse return error.MissingValue, actor.?); // :359
    }

    /// The id `n` rows ahead, or null past the end of the window
    /// (`maybe_try_nth`, `op_iter.rs:363-374`).
    pub fn maybeTryNth(self: *OpIdIter, n: usize) ReadOpError!?OpId {
        const actor = try self.actor.nth(n);
        const ctr = try self.ctr.nth(n);
        if (actor == null) return null; // :371
        return OpId.init(ctr orelse return error.MissingValue, actor.?); // :372
    }
};

/// The `insert` column (`InsertIter`, `op_iter.rs:409-412`).
///
/// One column cursor, so every kernel method here is a single forward rather
/// than a lockstep pair — including [`InsertIter.shift`], which is the only
/// `shift` on this type that cannot fail. Nothing allocates and nothing moves
/// backwards.
pub const InsertIter = struct {
    /// `insert`: whether the row inserts rather than overwrites
    /// (`op_set2/columns.rs:28`).
    iter: opcols.BoolPrefixColumn.Iterator,

    /// The compile-time proof that this type carries the whole `Shiftable`
    /// kernel; [`assertShiftable`] is what makes the mark mean something.
    pub const shiftable = column.Shiftable(InsertIter);

    /// A cursor over the `insert` column, positioned at row 0 with its window
    /// open to the end of the column.
    pub fn init(iter: opcols.BoolPrefixColumn.Iterator) InsertIter {
        return .{ .iter = iter };
    }

    /// The row this cursor stands on — that is, how many rows have been
    /// consumed (`Shiftable::pos`, `shift.rs:56-58`).
    pub fn pos(self: *const InsertIter) usize {
        return self.iter.pos();
    }

    /// The row past the last one this cursor may reach (`Shiftable::max_pos`,
    /// `shift.rs:59-61`): the window's closed end.
    pub fn maxPos(self: *const InsertIter) usize {
        return self.iter.maxPos();
    }

    /// Closes the window at `at` (`Shiftable::set_max`, `shift.rs:62-66`). The
    /// cursor itself does not move, and an `at` past the end of the column is
    /// clamped to its length.
    pub fn setMax(self: *InsertIter, at: usize) void {
        self.iter.setMax(at);
    }

    /// Consumes rows until the cursor stands on `target`
    /// (`Shiftable::advance_to`, `shift.rs:67-72`). Forward only: a `target`
    /// at or behind the current [`pos`] is a no-op, and one past the window is
    /// `error.UnexpectedEnd`.
    pub fn advanceTo(self: *InsertIter, target: usize) ParseError!void {
        return self.iter.advanceTo(target);
    }

    /// Consumes `amount` more rows, saturating rather than wrapping
    /// (`Shiftable::advance_by`, `shift.rs:73-76`).
    pub fn advanceBy(self: *InsertIter, amount: usize) ParseError!void {
        return self.iter.advanceBy(amount);
    }

    /// Moves the walk onto `range`: the window follows the range **and** the
    /// walk lands on its start (`Shiftable::shift`, `shift.rs:50-55`).
    ///
    /// Returns column parse errors without changing the cursor or its window.
    /// The caller follows it with [`shiftNext`] or [`seekTo`].
    pub fn shift(self: *InsertIter, range: RowRange) ParseError!void {
        var iter = self.iter;
        try iter.shift(range);
        self.iter = iter;
    }

    /// Repositions onto `range` and reads the row at its start
    /// (`Shiftable::shift_next`, `shift.rs:77-86`): `shift` then a read, so
    /// the cursor stands on `range.start` and `null` is a `range.start` at or
    /// past the end of the window.
    pub fn shiftNext(self: *InsertIter, range: RowRange) ParseError!?bool {
        return self.iter.shiftNext(range);
    }

    /// Reads row `at` and consumes through it (`Shiftable::seek_to`,
    /// `shift.rs:87-96`). Forward only: an `at` behind the cursor answers
    /// `null` and leaves it where it is, which is the same `null` a walk past
    /// the end gives.
    pub fn seekTo(self: *InsertIter, at: usize) ParseError!?bool {
        return self.iter.seekTo(at);
    }

    /// The next row's insert flag (`try_next`, `op_iter.rs:432-434`).
    pub fn tryNext(self: *InsertIter) ReadOpError!bool {
        return try self.iter.next() orelse error.MissingValue;
    }

    /// The insert flag `n` rows ahead (`try_nth`, `op_iter.rs:436-438`).
    pub fn tryNth(self: *InsertIter, n: usize) ReadOpError!bool {
        return try self.iter.nth(n) orelse error.MissingValue;
    }
};

/// The three key columns, read as one key (`KeyIter`, `op_iter.rs:463-468`).
///
/// `key_str` is an interned id in this port rather than a `String`
/// (`op_set2/columns.rs:22` is a string column, `plan.md` §5.3 interns it),
/// so this holds the [`StringTable`] that turns an id back into bytes. The
/// table is borrowed and must outlive every key the cursor hands out —
/// the same rule as [`Op`]'s own borrowed key.
///
/// Three column cursors held in step plus the borrowed string table, so the
/// kernel is the [`OpIdIter`] one over three columns rather than two. Every
/// read is `shiftNext`-shaped: the three halves are read in lockstep and
/// assembled by [`tryLoadKeyRef`], which is where a row that is neither a map
/// key nor a sequence anchor is refused.
pub const KeyIter = struct {
    /// `key_str`: the map key, as an interned id (`op_iter.rs:465`).
    key_str: opcols.UintOptColumn.Iterator,
    /// `key_actor`: the sequence anchor's actor (`op_iter.rs:466`).
    key_actor: opcols.ActorOptColumn.Iterator,
    /// `key_ctr`: the sequence anchor's counter (`op_iter.rs:467`).
    key_ctr: opcols.OptCounterColumn.Iterator,
    /// The document's string table, resolving `key_str`.
    strings: StringTable,

    /// The compile-time proof that this type carries the whole `Shiftable`
    /// kernel; [`assertShiftable`] is what makes the mark mean something.
    pub const shiftable = column.Shiftable(KeyIter);

    /// A cursor over the three key columns, positioned at row 0 with the
    /// window open to the end of all three.
    ///
    /// `strings` is borrowed, not copied, and is the one thing here that is
    /// not a column cursor: it must be the table of the document these
    /// columns belong to, and it must outlive every key this hands out.
    pub fn init(
        key_str: opcols.UintOptColumn.Iterator,
        key_actor: opcols.ActorOptColumn.Iterator,
        key_ctr: opcols.OptCounterColumn.Iterator,
        strings: StringTable,
    ) KeyIter {
        return .{
            .key_str = key_str,
            .key_actor = key_actor,
            .key_ctr = key_ctr,
            .strings = strings,
        };
    }

    /// The row this cursor stands on — that is, how many rows have been
    /// consumed (`Shiftable::pos`, `shift.rs:56-58`). It is the `key_str`
    /// cursor's position, and the three are kept equal.
    pub fn pos(self: *const KeyIter) usize {
        return self.key_str.pos();
    }

    /// The row past the last one this cursor may reach (`Shiftable::max_pos`,
    /// `shift.rs:59-61`): the window's closed end.
    pub fn maxPos(self: *const KeyIter) usize {
        return self.key_str.maxPos();
    }

    /// Closes all three windows at `at` (`Shiftable::set_max`,
    /// `shift.rs:62-66`). The cursor does not move and `at` past the end of
    /// the columns is clamped to their length.
    pub fn setMax(self: *KeyIter, at: usize) void {
        self.key_str.setMax(at);
        self.key_actor.setMax(at);
        self.key_ctr.setMax(at);
    }

    /// Consumes rows until the cursor stands on `target`
    /// (`Shiftable::advance_to`, `shift.rs:67-72`). Forward only; a `target`
    /// past the window is `error.UnexpectedEnd`. The three move in the order
    /// `key_str`, `key_actor`, `key_ctr`, so a failure leaves the last one
    /// behind rather than the first.
    pub fn advanceTo(self: *KeyIter, target: usize) ParseError!void {
        try self.key_str.advanceTo(target);
        try self.key_actor.advanceTo(target);
        try self.key_ctr.advanceTo(target);
    }

    /// Consumes `amount` more rows, saturating rather than wrapping
    /// (`Shiftable::advance_by`, `shift.rs:73-76`).
    pub fn advanceBy(self: *KeyIter, amount: usize) ParseError!void {
        return self.advanceTo(self.key_str.pos() +| amount);
    }

    /// Moves the walk onto `range`: the window follows the range **and** the
    /// walk lands on its start (`Shiftable::shift`, `shift.rs:50-55`).
    ///
    /// All three key cursors move together — the window is one window over
    /// three columns. A parse error leaves all cursors and windows unchanged.
    /// The caller follows with [`shiftNext`] or [`seekTo`].
    pub fn shift(self: *KeyIter, range: RowRange) ParseError!void {
        var key_str = self.key_str;
        var key_actor = self.key_actor;
        var key_ctr = self.key_ctr;
        try key_str.shift(range);
        try key_actor.shift(range);
        try key_ctr.shift(range);
        self.key_str = key_str;
        self.key_actor = key_actor;
        self.key_ctr = key_ctr;
    }

    /// Repositions onto `range`, reads the row at its start, and assembles it
    /// into one key (`Shiftable::shift_next`, `shift.rs:77-86`).
    ///
    /// On return the cursor stands on `range.start`, not past it. `null` is a
    /// `range.start` at or past the end of the window; an error is a window
    /// that ran out mid-read or a row the three columns do not make a key out
    /// of — [`tryLoadKeyRef`] is the authority on the second.
    pub fn shiftNext(self: *KeyIter, range: RowRange) ReadOpError!?KeyRef {
        const str_id = (try self.key_str.shiftNext(range)) orelse return null;
        const actor = (try self.key_actor.shiftNext(range)) orelse return null;
        const ctr = (try self.key_ctr.shiftNext(range)) orelse return null;
        return try self.load(str_id, actor, ctr);
    }

    /// Reads row `at`, consumes through it, and assembles it into one key
    /// (`Shiftable::seek_to`, `shift.rs:87-96`).
    ///
    /// Forward only: an `at` behind the cursor answers `null` and leaves it
    /// where it is — the same `null` a walk past the end gives. On a
    /// non-null answer the three key cursors all stand on `at`. The map key
    /// borrows the string table.
    pub fn seekTo(self: *KeyIter, at: usize) ReadOpError!?KeyRef {
        const str_id = (try self.key_str.seekTo(at)) orelse return null;
        const actor = (try self.key_actor.seekTo(at)) orelse return null;
        const ctr = (try self.key_ctr.seekTo(at)) orelse return null;
        return try self.load(str_id, actor, ctr);
    }

    /// The three column values as one key, or the error the family
    /// raises (`try_load`, `op_iter.rs:258-263`).
    fn load(
        self: *const KeyIter,
        str_id: ?u32,
        actor: ?ActorIdx,
        ctr: ?u32,
    ) ReadOpError!KeyRef {
        const key_str: ?[]const u8 = if (str_id) |id|
            self.strings.resolve(self.strings.ctx, id)
        else
            null;
        return tryLoadKeyRef(key_str, actor, if (ctr) |c| @as(i64, c) else null);
    }

    /// The next row's key (`try_next`, `op_iter.rs:508-522`).
    pub fn tryNext(self: *KeyIter) ReadOpError!KeyRef {
        const str_id = try self.key_str.next() orelse return error.MissingValue;
        const actor = try self.key_actor.next() orelse return error.MissingValue;
        const ctr = try self.key_ctr.next() orelse return error.MissingValue;
        return self.load(str_id, actor, ctr);
    }

    /// The key `n` rows ahead (`try_nth`, `op_iter.rs:524-538`).
    pub fn tryNth(self: *KeyIter, n: usize) ReadOpError!KeyRef {
        const str_id = try self.key_str.nth(n) orelse return error.MissingValue;
        const actor = try self.key_actor.nth(n) orelse return error.MissingValue;
        const ctr = try self.key_ctr.nth(n) orelse return error.MissingValue;
        return self.load(str_id, actor, ctr);
    }
};

/// The two object columns, read as one object id
/// (`ObjIdIter`, `op_iter.rs:570-574`).
///
/// Two column cursors held in step, with the kernel [`OpIdIter`] has, plus
/// [`seekToValue`](ObjIdIter.seekToValue) — which is the one method on this
/// type that is not a step of the walk but a search, and the one that leaves
/// both cursors on an answer. Every read is assembled by
/// [`tryLoadObjId`], where "both halves null" and "a counter of zero" are the
/// two shapes of the root.
pub const ObjIdIter = struct {
    /// `obj_actor`: the parent object's actor, null at the root
    /// (`op_set2/columns.rs:20`).
    obj_actor: opcols.ActorOptColumn.Iterator,
    /// `obj_ctr`: the parent object's counter, null at the root
    /// (`op_set2/columns.rs:21`).
    obj_ctr: opcols.UintOptColumn.Iterator,

    /// The compile-time proof that this type carries the whole `Shiftable`
    /// kernel; [`assertShiftable`] is what makes the mark mean something.
    pub const shiftable = column.Shiftable(ObjIdIter);

    /// A cursor over the two object columns, positioned at row 0 with the
    /// window open to the end of both.
    pub fn init(
        obj_actor: opcols.ActorOptColumn.Iterator,
        obj_ctr: opcols.UintOptColumn.Iterator,
    ) ObjIdIter {
        return .{ .obj_actor = obj_actor, .obj_ctr = obj_ctr };
    }

    /// The row this cursor stands on — that is, how many rows have been
    /// consumed (`Shiftable::pos`, `shift.rs:56-58`). It is the `obj_actor`
    /// cursor's position, and the two are kept equal.
    pub fn pos(self: *const ObjIdIter) usize {
        return self.obj_actor.pos();
    }

    /// The row past the last one this cursor may reach (`Shiftable::max_pos`,
    /// `shift.rs:59-61`): the window's closed end.
    pub fn maxPos(self: *const ObjIdIter) usize {
        return self.obj_actor.maxPos();
    }

    /// Closes both windows at `at` (`Shiftable::set_max`, `shift.rs:62-66`).
    /// The cursor does not move and `at` past the end of the columns is
    /// clamped to their length.
    pub fn setMax(self: *ObjIdIter, at: usize) void {
        self.obj_actor.setMax(at);
        self.obj_ctr.setMax(at);
    }

    /// Consumes rows until the cursor stands on `target`
    /// (`Shiftable::advance_to`, `shift.rs:67-72`). Forward only; a `target`
    /// past the window is `error.UnexpectedEnd`.
    pub fn advanceTo(self: *ObjIdIter, target: usize) ParseError!void {
        try self.obj_actor.advanceTo(target);
        try self.obj_ctr.advanceTo(target);
    }

    /// Consumes `amount` more rows, saturating rather than wrapping
    /// (`Shiftable::advance_by`, `shift.rs:73-76`).
    pub fn advanceBy(self: *ObjIdIter, amount: usize) ParseError!void {
        return self.advanceTo(self.obj_actor.pos() +| amount);
    }

    /// Moves the walk onto `range`: the window follows the range **and** the
    /// walk lands on its start (`Shiftable::shift`, `shift.rs:50-55`).
    ///
    /// Both object cursors move together. A parse error leaves both cursors
    /// and windows unchanged. The caller follows with [`shiftNext`] or [`seekTo`].
    pub fn shift(self: *ObjIdIter, range: RowRange) ParseError!void {
        var obj_actor = self.obj_actor;
        var obj_ctr = self.obj_ctr;
        try obj_actor.shift(range);
        try obj_ctr.shift(range);
        self.obj_actor = obj_actor;
        self.obj_ctr = obj_ctr;
    }

    /// Repositions onto `range`, reads the row at its start, and assembles it
    /// into one object id (`Shiftable::shift_next`, `shift.rs:77-86`).
    ///
    /// On return the cursor stands on `range.start`, not past it. `null` is a
    /// `range.start` at or past the end of the window; an error is a window
    /// that ran out mid-read or a row the two columns do not make an object id
    /// out of, which [`tryLoadObjId`] decides.
    pub fn shiftNext(self: *ObjIdIter, range: RowRange) ReadOpError!?ObjId {
        const actor = (try self.obj_actor.shiftNext(range)) orelse return null;
        const ctr = (try self.obj_ctr.shiftNext(range)) orelse return null;
        return try tryLoadObjId(actor, if (ctr) |c| @as(i64, c) else null);
    }

    /// Reads row `at`, consumes through it, and assembles it into one object
    /// id (`Shiftable::seek_to`, `shift.rs:87-96`).
    ///
    /// Forward only: an `at` behind the cursor answers `null` and leaves it
    /// where it is — the same `null` a walk past the end gives. On a
    /// non-null answer both object cursors stand on `at`. It does not move
    /// the window, so it reads whatever the window already allows.
    pub fn seekTo(self: *ObjIdIter, at: usize) ReadOpError!?ObjId {
        const actor = (try self.obj_actor.seekTo(at)) orelse return null;
        const ctr = (try self.obj_ctr.seekTo(at)) orelse return null;
        return try tryLoadObjId(actor, if (ctr) |c| @as(i64, c) else null);
    }

    /// The rows of `obj`, as a contiguous range, with this cursor left on
    /// the first of them (`seek_to_value`, `op_iter.rs:616-623`).
    ///
    /// Upstream seeks the counter column over everything, then the actor
    /// column over the counter column's answer, then moves the counter
    /// cursor onto the actor column's answer. Two columns that both sort by
    /// object are what make an object's rows a contiguous run
    /// ([`opcols.Columns.scopeToValue`](columns.zig)), which is one of the
    /// two halves of the row-order invariant.
    ///
    /// The two runs are found on throwaway cursors and both real cursors
    /// are then moved onto the answer, because what this method owes its
    /// caller is that *both* object columns stand on `range.start` when it
    /// returns, and one column's seek moves only its own cursor. Upstream
    /// owes the same property and reaches it the same way: two
    /// `Iter::seek_to_value` calls, each of which scans a clone narrowed to
    /// the range and advances the original (`column.rs:927-933`), then one
    /// more `advance_to` for the counter column (`op_iter.rs:616-623`).
    ///
    /// Scanning on probes is also belt-and-braces against a class of defect
    /// this column layer once had: a value scan that *consumed* the run it
    /// had found, which made the `advanceTo` that followed a no-op and left
    /// the cursor at the row behind the answer. That class is fixed and
    /// pinned upstream of here — `Iterator.scanToValue` now consumes the
    /// real cursor through the hit with one indexed jump
    /// ([`column.zig:3826-3850`](../../src/hexane/column.zig)) and
    /// `Iterator.seekToValue` scans a checkpoint copy and advances the
    /// original ([`column.zig:3852-3872`](../../src/hexane/column.zig)), by
    /// `test "a value's rows are found across every slab"`
    /// ([`column.zig:5546`](../../src/hexane/column.zig)) — and the guard
    /// stays because "both cursors are on the run's first row when this
    /// returns" is a property the next reader has to be able to read off
    /// the one function that owes it.
    ///
    /// Repositioning only moves forward, as upstream's `advance_to` does, so
    /// a seek to an object before the one the cursor stands on leaves it
    /// where it is. Every seek in the op set is forward.
    ///
    /// Only the root or an op-set-resolved `.id` may reach these resident
    /// columns. Named IDs require the op set's authoritative actor table;
    /// without it, even a u32 counter and cached actor hint are insufficient.
    /// They return `error.InvalidValue` before either cursor or window changes.
    pub fn seekToValue(self: *ObjIdIter, obj: ObjId) ParseError!RowRange {
        const id: ?OpId = switch (obj) {
            .root => null,
            .id => |value| value,
            .named => return error.InvalidValue,
        };
        const all = RowRange{ .start = 0, .end = std.math.maxInt(usize) };
        var ctr_probe = try rangedCursor(self.obj_ctr.col, all);
        const cr = try ctr_probe.sortedScanToValue(if (id) |value| value.counter else null);
        var actor_probe = try rangedCursor(self.obj_actor.col, cr);
        const range = try actor_probe.sortedScanToValue(if (id) |value| value.actor else null);
        // op_iter.rs:622 — the counter cursor is moved onto the actor
        // column's answer; the actor cursor is already there, and upstream
        // reaches both through the same `advance_to`.
        self.obj_ctr.setMax(all.end);
        try self.obj_ctr.advanceTo(range.start);
        self.obj_actor.setMax(all.end);
        try self.obj_actor.advanceTo(range.start);
        return range;
    }

    /// The next row's object id (`try_next`, `op_iter.rs:625-635`).
    pub fn tryNext(self: *ObjIdIter) ReadOpError!ObjId {
        const actor = try self.obj_actor.next() orelse return error.MissingValue;
        const ctr = try self.obj_ctr.next() orelse return error.MissingValue;
        return tryLoadObjId(actor, if (ctr) |c| @as(i64, c) else null);
    }

    /// The object id `n` rows ahead (`try_nth`, `op_iter.rs:637-647`).
    pub fn tryNth(self: *ObjIdIter, n: usize) ReadOpError!ObjId {
        const actor = try self.obj_actor.nth(n) orelse return error.MissingValue;
        const ctr = try self.obj_ctr.nth(n) orelse return error.MissingValue;
        return tryLoadObjId(actor, if (ctr) |c| @as(i64, c) else null);
    }
};

/// The two mark columns, read as one mark's name and expansion
/// (`MarkInfoIter`, `op_iter.rs:677-681`).
///
/// Two column cursors held in step plus the borrowed string table, with the
/// kernel [`OpIdIter`] has. The asymmetry worth knowing before reading the
/// methods: `expand` is read as **false** when the column runs out and the
/// name is what makes a row a row, so a missing `expand` is never an error —
/// upstream's rule (`op_iter.rs:704-708`, `:729`), kept here on every read.
pub const MarkInfoIter = struct {
    /// `mark_name`, an interned id (`op_set2/columns.rs:32`).
    name: opcols.UintOptColumn.Iterator,
    /// `expand` (`op_set2/columns.rs:33`).
    expand: opcols.BoolColumn.Iterator,
    /// The document's string table, resolving `mark_name`.
    strings: StringTable,

    /// The compile-time proof that this type carries the whole `Shiftable`
    /// kernel; [`assertShiftable`] is what makes the mark mean something.
    pub const shiftable = column.Shiftable(MarkInfoIter);

    /// A cursor over the two mark columns, positioned at row 0 with the window
    /// open to the end of both.
    ///
    /// `strings` is borrowed and must be the document's own table: it is
    /// where every mark name this hands out comes from.
    pub fn init(
        name: opcols.UintOptColumn.Iterator,
        expand: opcols.BoolColumn.Iterator,
        strings: StringTable,
    ) MarkInfoIter {
        return .{ .name = name, .expand = expand, .strings = strings };
    }

    /// The row this cursor stands on — that is, how many rows have been
    /// consumed (`Shiftable::pos`, `shift.rs:56-58`). It is the `expand`
    /// cursor's position, and the two are kept equal.
    pub fn pos(self: *const MarkInfoIter) usize {
        return self.expand.pos();
    }

    /// The row past the last one this cursor may reach (`Shiftable::max_pos`,
    /// `shift.rs:59-61`): the window's closed end.
    pub fn maxPos(self: *const MarkInfoIter) usize {
        return self.expand.maxPos();
    }

    /// Closes both windows at `at` (`Shiftable::set_max`, `shift.rs:62-66`).
    /// The cursor does not move and `at` past the end of the columns is
    /// clamped to their length.
    pub fn setMax(self: *MarkInfoIter, at: usize) void {
        self.name.setMax(at);
        self.expand.setMax(at);
    }

    /// Consumes rows until the cursor stands on `target`
    /// (`Shiftable::advance_to`, `shift.rs:67-72`). Forward only; a `target`
    /// past the window is `error.UnexpectedEnd`.
    pub fn advanceTo(self: *MarkInfoIter, target: usize) ParseError!void {
        try self.name.advanceTo(target);
        try self.expand.advanceTo(target);
    }

    /// Consumes `amount` more rows, saturating rather than wrapping
    /// (`Shiftable::advance_by`, `shift.rs:73-76`).
    pub fn advanceBy(self: *MarkInfoIter, amount: usize) ParseError!void {
        return self.advanceTo(self.expand.pos() +| amount);
    }

    /// Moves the walk onto `range`: the window follows the range **and** the
    /// walk lands on its start (`Shiftable::shift`, `shift.rs:50-55`; the
    /// kernel's own `shift`, `column.rs:542-545`).
    ///
    /// Both mark cursors move together. A parse error leaves both cursors
    /// and windows unchanged.
    pub fn shift(self: *MarkInfoIter, range: RowRange) ParseError!void {
        var name = self.name;
        var expand = self.expand;
        try name.shift(range);
        try expand.shift(range);
        self.name = name;
        self.expand = expand;
    }

    /// Repositions onto `range` and reads the row at its start
    /// (`shift_next`, `op_iter.rs:704-708`).
    ///
    /// Upstream swallows a missing `expand` as false and only the missing
    /// name is an error: a row with no `expand` column entry is a row that
    /// does not expand, and the name column is the one that must be there for
    /// the row to be a row. On return the cursor stands on `range.start`, not
    /// past it, and `null` is a `range.start` at or past the end of the
    /// window. The name is borrowed from the string table.
    pub fn shiftNext(self: *MarkInfoIter, range: RowRange) ReadOpError!?MarkInfo {
        const expand = (try self.expand.shiftNext(range)) orelse false;
        const name = (try self.name.shiftNext(range)) orelse return null;
        return .{ .name = if (name) |id| self.strings.resolve(self.strings.ctx, id) else null, .expand = expand };
    }

    /// Reads row `at`, consumes through it, and returns the mark's name and
    /// expansion (`Shiftable::seek_to`, `shift.rs:87-96`).
    ///
    /// Forward only: an `at` behind the cursor answers `null` and leaves it
    /// where it is, which is the same `null` a walk past the end gives. A
    /// missing `expand` is false rather than an error, on the terms
    /// [`shiftNext`](MarkInfoIter.shiftNext) gives; the name is borrowed from
    /// the string table.
    pub fn seekTo(self: *MarkInfoIter, at: usize) ReadOpError!?MarkInfo {
        const expand = (try self.expand.seekTo(at)) orelse false;
        const name = (try self.name.seekTo(at)) orelse return null;
        return .{ .name = if (name) |id| self.strings.resolve(self.strings.ctx, id) else null, .expand = expand };
    }

    /// The next row's mark name and expansion (`try_next`,
    /// `op_iter.rs:728-735`).
    pub fn tryNext(self: *MarkInfoIter) ReadOpError!MarkInfo {
        const expand = (try self.expand.next()) orelse false; // :729
        const name = try self.name.next() orelse return error.MissingValue; // :733
        return .{
            .name = if (name) |id| self.strings.resolve(self.strings.ctx, id) else null,
            .expand = expand,
        };
    }

    /// The mark `n` rows ahead (`try_nth`, `op_iter.rs:737-744`).
    pub fn tryNth(self: *MarkInfoIter, n: usize) ReadOpError!MarkInfo {
        const expand = (try self.expand.nth(n)) orelse false; // :738
        const name = try self.name.nth(n) orelse return error.MissingValue; // :742
        return .{
            .name = if (name) |id| self.strings.resolve(self.strings.ctx, id) else null,
            .expand = expand,
        };
    }
};

/// The action column (`ActionIter`, `op_iter.rs:807-810`).
///
/// The column holds each action's wire code (`op_set2/columns.rs:29`); the
/// decoder is [`optypes.actionFromCode`], so an action code outside the
/// eight is `error.InvalidAction` rather than a row.
///
/// One column cursor and the [`InsertIter`] kernel, with one thing the kernel
/// does not have: the read methods *decode*, so their error set includes
/// `ParseError`. `error.InvalidAction` therefore means "the column holds a
/// code that is not one of the eight", which is a corrupt document rather
/// than a walk off the end.
pub const ActionIter = struct {
    /// `action`, one wire code per row.
    iter: opcols.ActionColumn.Iterator,

    /// The compile-time proof that this type carries the whole `Shiftable`
    /// kernel; [`assertShiftable`] is what makes the mark mean something.
    pub const shiftable = column.Shiftable(ActionIter);

    /// A cursor over the action column, positioned at row 0 with its window
    /// open to the end of the column.
    pub fn init(iter: opcols.ActionColumn.Iterator) ActionIter {
        return .{ .iter = iter };
    }

    /// The row this cursor stands on — that is, how many rows have been
    /// consumed (`Shiftable::pos`, `shift.rs:56-58`).
    pub fn pos(self: *const ActionIter) usize {
        return self.iter.pos();
    }

    /// The row past the last one this cursor may reach (`Shiftable::max_pos`,
    /// `shift.rs:59-61`): the window's closed end.
    pub fn maxPos(self: *const ActionIter) usize {
        return self.iter.maxPos();
    }

    /// Closes the window at `at` (`Shiftable::set_max`, `shift.rs:62-66`). The
    /// cursor does not move and `at` past the end of the column is clamped to
    /// its length.
    pub fn setMax(self: *ActionIter, at: usize) void {
        self.iter.setMax(at);
    }

    /// Consumes rows until the cursor stands on `target`
    /// (`Shiftable::advance_to`, `shift.rs:67-72`). Forward only; a `target`
    /// at or behind the current [`pos`] is a no-op, and one past the window is
    /// `error.UnexpectedEnd`. It reads nothing, so it cannot raise
    /// `error.InvalidAction`.
    pub fn advanceTo(self: *ActionIter, target: usize) ParseError!void {
        return self.iter.advanceTo(target);
    }

    /// Consumes `amount` more rows, saturating rather than wrapping
    /// (`Shiftable::advance_by`, `shift.rs:73-76`).
    pub fn advanceBy(self: *ActionIter, amount: usize) ParseError!void {
        return self.iter.advanceBy(amount);
    }

    /// Moves the walk onto `range`: the window follows the range **and** the
    /// walk lands on its start (`Shiftable::shift`, `shift.rs:50-55`).
    ///
    /// Does not decode the action, so it cannot raise `error.InvalidAction`.
    /// Column parse errors leave the cursor and window unchanged.
    /// The caller follows it with [`shiftNext`] or [`seekTo`].
    pub fn shift(self: *ActionIter, range: RowRange) ParseError!void {
        var iter = self.iter;
        try iter.shift(range);
        self.iter = iter;
    }

    /// Repositions onto `range`, reads the row at its start and decodes its
    /// code (`Shiftable::shift_next`, `shift.rs:77-86`).
    ///
    /// On return the cursor stands on `range.start`, not past it. `null` is a
    /// `range.start` at or past the end of the window; `error.InvalidAction`
    /// is a row whose code is not one of the eight.
    pub fn shiftNext(self: *ActionIter, range: RowRange) ParseError!?Action {
        const code = (try self.iter.shiftNext(range)) orelse return null;
        return try optypes.actionFromCode(code);
    }

    /// Reads row `at`, consumes through it, and decodes its code
    /// (`Shiftable::seek_to`, `shift.rs:87-96`).
    ///
    /// Forward only: an `at` behind the cursor answers `null` and leaves it
    /// where it is, which is the same `null` a walk past the end gives. On a
    /// non-null answer the cursor stands on `at`.
    pub fn seekTo(self: *ActionIter, at: usize) ParseError!?Action {
        const code = (try self.iter.seekTo(at)) orelse return null;
        return try optypes.actionFromCode(code);
    }

    /// The next row's action (`try_next`, `op_iter.rs:838-840`).
    pub fn tryNext(self: *ActionIter) ReadOpError!Action {
        return optypes.actionFromCode(
            try self.iter.next() orelse return error.MissingValue,
        );
    }

    /// The action `n` rows ahead (`try_nth`, `op_iter.rs:842-844`).
    pub fn tryNth(self: *ActionIter, n: usize) ReadOpError!Action {
        return optypes.actionFromCode(
            try self.iter.nth(n) orelse return error.MissingValue,
        );
    }
};

/// The metadata column over the raw value column, read as one value
/// (`ValueIter`, `op_iter.rs:865-869`).
///
/// The two cursors are indexed in different spaces — `value_meta` by row,
/// the raw column by byte — and the metadata word is what joins them: its
/// length is the row's width in the value arena (`op_set2/meta.rs:40-42`),
/// and the running sum of the lengths is a row's offset in it.
///
/// Sequential reads consume the raw cursor in place. Jumps and shifts align it
/// from the metadata cursor's codec-defined prefix before the next read.
/// `setMax` changes only the row window and does not move either cursor.
///
/// The values handed out borrow the raw column, so the `RawColumn` must
/// outlive every [`ScalarValue`] this produces.
///
/// **Row space and byte space are different spaces.** [`pos`] and
/// [`maxPos`](ValueIter.maxPos) are rows; metadata prefixes are byte offsets.
/// A rebased cursor adds its checked `base` before using a prefix as an offset.
pub const ValueIter = struct {
    /// `value_meta`, one length-and-type word per row
    /// (`op_set2/columns.rs:30`).
    meta: opcols.MetaColumn.PrefixIter,
    /// `value`, the payload arena, positioned at the row's offset
    /// (`op_set2/columns.rs:31`).
    raw: rawcol.RawColumnIter,

    /// The compile-time proof that this type carries the whole `Shiftable`
    /// kernel; [`assertShiftable`] is what makes the mark mean something.
    pub const shiftable = column.Shiftable(ValueIter);
    /// A cursor over the metadata and raw columns, both at row 0 / byte 0,
    /// with the metadata window open to the end of the column.
    ///
    /// `raw` must be a cursor over the *same* document's value column; the
    /// byte offset this works in is the metadata column's own running sum, so
    /// a `raw` from another document would read another document's bytes.
    pub fn init(meta: opcols.MetaColumn.PrefixIter, raw: rawcol.RawColumnIter) ValueIter {
        return .{ .meta = meta, .raw = raw };
    }

    /// The **row** this cursor stands on — that is, how many rows have been
    /// consumed (`Shiftable::pos`, `shift.rs:56-58`). It is the metadata
    /// cursor's position, and it is a row, not a byte offset.
    pub fn pos(self: *const ValueIter) usize {
        return self.meta.pos();
    }

    /// The row past the last one this cursor may reach (`Shiftable::max_pos`,
    /// `shift.rs:59-61`): the window's closed end, in rows. A row behind it
    /// whose bytes the raw cursor has not been placed on can still be read by
    /// [`tryNext`](ValueIter.tryNext) — the read places the byte cursor
    /// itself.
    pub fn maxPos(self: *const ValueIter) usize {
        return self.meta.maxPos();
    }

    /// Closes the metadata window at `at` (`Shiftable::set_max`,
    /// `shift.rs:62-66`), in rows.
    ///
    /// Only the row window moves; the raw cursor retains the next row's offset.
    /// The cursor does not rewind, and `at` past the column is clamped.
    pub fn setMax(self: *ValueIter, at: usize) void {
        self.meta.setMax(at);
    }

    /// Moves the row cursor onto `target` and the byte cursor onto that
    /// row's offset (`Shiftable::advance_to`, `shift.rs:67-72`).
    ///
    /// Reads nothing and returns no value: the byte placement is bookkeeping
    /// so that a later read starts from the right place. A target behind the
    /// cursor is a no-op, as everywhere else in the kernel, and `target` past
    /// the window is `error.UnexpectedEnd`. The offset is the checked absolute
    /// inclusive prefix of the last row skipped.
    pub fn advanceTo(self: *ValueIter, target: usize) ParseError!void {
        const at = self.meta.pos();
        if (target <= at) return;
        const pv = (try self.meta.nth(target - at - 1)) orelse return error.UnexpectedEnd;
        try self.raw.seekTo(try absolutePrefix(pv.total(), self.meta.base));
    }

    /// Consumes `amount` more rows, saturating rather than wrapping
    /// (`Shiftable::advance_by`, `shift.rs:73-76`), placing the byte cursor
    /// on the row it lands on exactly as [`advanceTo`] does.
    pub fn advanceBy(self: *ValueIter, amount: usize) ParseError!void {
        return self.advanceTo(self.meta.pos() +| amount);
    }

    /// Moves the walk onto `range`: the window follows the range **and** the
    /// walk lands on its start (`Shiftable::shift`, `shift.rs:50-55`).
    ///
    /// Both cursors move together. Staging leaves them unchanged on a typed
    /// refusal, and a following sequential read starts at the new row's bytes.
    pub fn shift(self: *ValueIter, range: RowRange) ParseError!void {
        var meta = self.meta;
        var raw = self.raw;
        try meta.shift(range);
        try raw.seekTo(try absolutePrefix(meta.sum, meta.base));
        self.meta = meta;
        self.raw = raw;
    }

    /// Repositions onto `range` and reads the row at its start
    /// (`shift_next`, `op_iter.rs:888-896`).
    ///
    /// `shift` then a read, so the byte cursor is placed on `range.start` and
    /// the cursor stands there — the next [`tryNext`](ValueIter.tryNext)
    /// answers the *following* row. `null` is a `range.start` at or past the
    /// end of the window. The value borrows the raw column.
    pub fn shiftNext(self: *ValueIter, range: RowRange) ReadOpError!?ScalarValue {
        const pv = (try self.meta.shiftNext(range)) orelse return null;
        const meta = ValueMeta.fromRaw(pv.value);
        try self.raw.seekTo(try absolutePrefix(pv.prefix(), self.meta.base));
        return try optypes.fromRaw(meta, try self.raw.take(try meta.length()));
    }

    /// Reads row `at` and consumes through it (`Shiftable::seek_to`,
    /// `shift.rs:87-96`).
    ///
    /// Forward only: an `at` behind the cursor answers `null` and leaves it
    /// where it is, which is the same `null` a walk past the end gives. It is
    /// built on [`tryNth`] rather than on a seek of the raw cursor, so it
    /// re-places the byte cursor on the row it reads — which is the point: a
    /// jump has to re-seek, a step does not.
    ///
    /// [`tryNth`] is total, so a row past the end is `error.MissingValue` and
    /// the `null` here comes from the backwards check alone.
    pub fn seekTo(self: *ValueIter, at: usize) ReadOpError!?ScalarValue {
        if (at < self.meta.pos()) return null;
        return try self.tryNth(at - self.meta.pos());
    }

    /// The next row's value (`try_next`, `op_iter.rs:906-915`).
    ///
    /// Total: a row this cursor cannot read is `error.MissingValue`, never a
    /// `null` the caller has to remember to check. It does **not** re-seek the
    /// byte cursor, because it does not jump — the invariant is that the byte
    /// cursor stands where the previous read left it, which holds from
    /// construction (byte 0 is row 0's offset) through any number of steps,
    /// and any jump goes through [`tryNth`] or [`shiftNext`], which do seek.
    /// The value borrows the raw column.
    pub fn tryNext(self: *ValueIter) ReadOpError!ScalarValue {
        const pv = (try self.meta.next()) orelse return error.MissingValue;
        const meta = ValueMeta.fromRaw(pv.value);
        return try optypes.fromRaw(meta, try self.raw.take(try meta.length()));
    }

    /// The value `n` rows ahead (`try_nth`, `op_iter.rs:917-930`).
    ///
    /// The metadata cursor jumps and the raw cursor is re-placed on the row it
    /// lands on, rather than walking both: the same answer, without reading
    /// the rows in between. `n == 0` is [`tryNext`]. A value's type and width
    /// come from the metadata word, so the bytes taken are exactly what it
    /// declares and a payload the raw column cannot supply is an error rather
    /// than a short read. The value borrows the raw column.
    pub fn tryNth(self: *ValueIter, n: usize) ReadOpError!ScalarValue {
        if (n == 0) return self.tryNext();
        const pv = (try self.meta.nth(n)) orelse return error.MissingValue;
        const meta = ValueMeta.fromRaw(pv.value);
        try self.raw.seekTo(try absolutePrefix(pv.prefix(), self.meta.base));
        return try optypes.fromRaw(meta, try self.raw.take(try meta.length()));
    }
};

/// The successor columns, read as one row's successors
/// (`SuccIterIter`, `op_iter.rs:953-959`).
///
/// `succ_count` is indexed by row and the other three by flattened
/// successor, so the running sum of the counts is what turns one into the
/// other. Upstream gets it by cloning three column cursors positioned at
/// the row and advancing them past the row's successors
/// (`op_iter.rs:1037-1046`); this port materialises the entries instead,
/// because [`opmod.SuccCursors`] holds a span rather than three cursors,
/// and so carries the flattened position itself.
///
/// `scratch` is the caller's. It must hold at least the widest row's
/// successor count in the walked range — [`maxSuccCount`] answers that — and
/// the [`SuccCursors`] it produces borrow it, so it must outlive the walk.
/// A row with more successors than the buffer is `error.TooLarge` rather
/// than a short read, for the reason [`opmod.loadSuccWindow`] gives: a
/// truncated read silently drops successors and hides a delete.
///
/// **Two spaces here, and the kernel only walks one of them.** [`pos`] and
/// [`maxPos`](SuccIterIter.maxPos) are rows; [`flat`] is a flattened
/// successor position. The four cursors are moved together — `advanceTo`,
/// `shiftNext` and [`tryNth`](SuccIterIter.tryNth) all re-place the three
/// flattened ones from `succ_count`'s own prefix sum — so the invariant a
/// caller can rely on is that a cursor returned from any read method has its
/// three flattened cursors sitting where the span it borrows begins.
pub const SuccIterIter = struct {
    /// `succ_count`, one count per row (`op_set2/columns.rs:24`).
    count: opcols.CountColumn.PrefixIter,
    /// `succ_actor`, the actor half, flattened (`op_set2/columns.rs:25`).
    actor: opcols.ActorColumn.Iterator,
    /// `succ_ctr`, the counter half, flattened (`op_set2/columns.rs:26`).
    ctr: opcols.CounterColumn.Iterator,
    /// `index.inc`, the increment each successor carries, flattened
    /// (`op_set2/columns.rs:42`).
    incs: opcols.IncColumn.Iterator,
    /// The flattened position the next row's first successor sits at.
    /// Upstream carries it as the three cursors' own `pos`
    /// (`op_iter.rs:998-1002`).
    flat: usize,
    /// The caller's successor buffer, reused for every row.
    scratch: []SuccEntry,

    /// The compile-time proof that this type carries the whole `Shiftable`
    /// kernel; [`assertShiftable`] is what makes the mark mean something.
    pub const shiftable = column.Shiftable(SuccIterIter);
    /// A cursor over the count column and the three flattened successor
    /// columns, positioned at row 0 / flattened `flat`.
    ///
    /// `flat` is a caller-supplied starting point in flattened successor
    /// coordinates — it is what a scoped walk passes when it enters a child
    /// object partway through the flattened columns — and it must agree with
    /// where the three cursors actually are, because it is the only record of
    /// that they are in step. `scratch` is the caller's buffer and must
    /// outlive the walk and every [`SuccCursors`] it produces.
    pub fn init(
        count: opcols.CountColumn.PrefixIter,
        actor: opcols.ActorColumn.Iterator,
        ctr: opcols.CounterColumn.Iterator,
        incs: opcols.IncColumn.Iterator,
        flat: usize,
        scratch: []SuccEntry,
    ) SuccIterIter {
        return .{
            .count = count,
            .actor = actor,
            .ctr = ctr,
            .incs = incs,
            .flat = flat,
            .scratch = scratch,
        };
    }

    /// Moves the three flattened cursors onto `want`. It never moves back:
    /// a `want` behind the cursor means the count column and the successor
    /// columns disagree about how many successors came before, which
    /// upstream's subtraction (`op_iter.rs:1061-1062`) answers with a
    /// debug panic and this answers with an error.
    fn advanceFlat(self: *SuccIterIter, want: usize) ParseError!void {
        if (want < self.flat) return error.InvalidValue;
        const d = want - self.flat;
        try self.actor.advanceBy(d);
        try self.ctr.advanceBy(d);
        try self.incs.advanceBy(d);
        self.flat = want;
    }

    /// Reads the next `n` successors into `scratch` and returns a cursor
    /// over them, the streaming form of [`opmod.loadSuccWindow`].
    fn window(self: *SuccIterIter, n: u32) ReadOpError!SuccCursors {
        const want: usize = @intCast(n);
        if (want > self.scratch.len) return error.TooLarge;
        const start = self.flat;
        for (0..want) |i| {
            const a = (try self.actor.next()) orelse return error.InvalidValue;
            const c = (try self.ctr.next()) orelse return error.InvalidValue;
            const inc = (try self.incs.next()) orelse return error.InvalidValue;
            self.scratch[i] = .{ .id = OpId.init(c, a), .inc = inc };
        }
        self.flat = std.math.add(usize, start, want) catch return error.Overflow;
        return SuccCursors.fromSpan(self.scratch[0..want], start);
    }

    /// The **row** this cursor stands on — that is, how many rows have been
    /// consumed (`Shiftable::pos`, `shift.rs:56-58`). It is the count
    /// cursor's position, and it is a row rather than the flattened
    /// successor position [`flat`] carries.
    pub fn pos(self: *const SuccIterIter) usize {
        return self.count.pos();
    }

    /// The row past the last one this cursor may reach (`Shiftable::max_pos`,
    /// `shift.rs:59-61`): the window's closed end, in rows. The flattened
    /// columns have no window of their own: they are consumed exactly as far
    /// as the counts say.
    pub fn maxPos(self: *const SuccIterIter) usize {
        return self.count.maxPos();
    }

    /// Closes the count column's window at `at` (`Shiftable::set_max`,
    /// `shift.rs:62-66`), in rows.
    ///
    /// Only the row window changes; the flattened cursors keep the next row's
    /// successor position.
    pub fn setMax(self: *SuccIterIter, at: usize) void {
        self.count.setMax(at);
    }

    /// Moves the count cursor onto `target` and the three flattened cursors
    /// past every successor of every row before it (`Shiftable::advance_to`,
    /// `shift.rs:67-72`).
    ///
    /// Reads nothing and returns no value: the flattened cursors are placed
    /// from `succ_count`'s own prefix sum at `target`, which is what makes
    /// the next read read the right successors. Forward only — a `target` at
    /// or behind the current row is a no-op, and one past the window is
    /// `error.UnexpectedEnd`.
    pub fn advanceTo(self: *SuccIterIter, target: usize) ParseError!void {
        const at = self.count.pos();
        if (target <= at) return;
        const pv = (try self.count.nth(target - at - 1)) orelse return error.UnexpectedEnd;
        try self.advanceFlat(try absolutePrefix(pv.total(), self.count.base));
    }

    /// Consumes `amount` more rows, saturating rather than wrapping
    /// (`Shiftable::advance_by`, `shift.rs:73-76`), placing the flattened
    /// cursors exactly as [`advanceTo`] does.
    pub fn advanceBy(self: *SuccIterIter, amount: usize) ParseError!void {
        return self.advanceTo(self.count.pos() +| amount);
    }

    /// Moves the walk onto `range`: the window follows the range **and** the
    /// walk lands on its start (`Shiftable::shift`, `shift.rs:50-55`).
    ///
    /// Count and flattened cursors move together. Staging leaves the walk
    /// unchanged on refusal and keeps a following sequential read aligned.
    pub fn shift(self: *SuccIterIter, range: RowRange) ParseError!void {
        var staged = self.*;
        try staged.count.shift(range);
        try staged.advanceFlat(try absolutePrefix(staged.count.sum, staged.count.base));
        self.* = staged;
    }

    /// Repositions onto `range` and reads the successors of the row at its
    /// start (`shift_next`, `op_iter.rs:992-1013`).
    ///
    /// On return the three flattened cursors stand at `range.start`'s own
    /// successor offset and the cursor returned borrows `scratch`. `null` is
    /// a `range.start` at or past the end of the window; `error.TooLarge` is
    /// a row with more successors than `scratch` holds, which is a refusal
    /// rather than a truncated read for the reason the type doc gives.
    pub fn shiftNext(self: *SuccIterIter, range: RowRange) ReadOpError!?SuccCursors {
        const pv = (try self.count.shiftNext(range)) orelse return null;
        const start = try absolutePrefix(pv.prefix(), self.count.base);
        try self.actor.advanceTo(start);
        try self.ctr.advanceTo(start);
        try self.incs.advanceTo(start);
        self.flat = start;
        return try self.window(pv.value);
    }

    /// Reads the successors of row `at` and consumes through it
    /// (`Shiftable::seek_to`, `shift.rs:87-96`).
    ///
    /// Forward only: an `at` behind the cursor answers `null` and leaves it
    /// where it is, which is the same `null` a walk past the end gives. This
    /// is [`tryNth`](SuccIterIter.tryNth) rather than a seek on the
    /// flattened cursors, so it re-places them from the count column's sum.
    pub fn seekTo(self: *SuccIterIter, at: usize) ReadOpError!?SuccCursors {
        if (at < self.count.pos()) return null;
        return try self.tryNth(at - self.count.pos());
    }

    /// The next row's successors (`try_next`, `op_iter.rs:1029-1049`).
    ///
    /// Total: a row this cursor cannot read is `error.MissingValue`, never a
    /// `null`. It does not re-place the flattened cursors — it steps them,
    /// which is the same answer at a lower cost, because a step has already
    /// left them where the next row's successors begin. The returned cursor
    /// borrows `scratch`, so only the most recent row's successors are
    /// readable from it.
    pub fn tryNext(self: *SuccIterIter) ReadOpError!SuccCursors {
        const pv = (try self.count.next()) orelse return error.MissingValue; // :1031-1035
        return try self.window(pv.value);
    }

    /// The successors of the row `n` rows ahead (`try_nth`,
    /// `op_iter.rs:1051-1081`).
    ///
    /// The count cursor jumps and the three flattened cursors are moved past
    /// the successors of every row before this one, which the count's own
    /// prefix sum names; `n == 0` is [`tryNext`](SuccIterIter.tryNext). A
    /// jump backwards is refused rather than attempted: the flattened
    /// cursors only move forward, so a `n` that would need them to go back is
    /// a document whose counts and successors disagree.
    pub fn tryNth(self: *SuccIterIter, n: usize) ReadOpError!SuccCursors {
        if (n == 0) return self.tryNext();
        const pv = (try self.count.nth(n)) orelse return error.MissingValue; // :1055-1058
        // :1059-1066 — the flattened cursors are moved past the successors
        // of every row before this one, which the count's own running sum
        // names.
        try self.advanceFlat(try absolutePrefix(pv.prefix(), self.count.base));
        return try self.window(pv.value);
    }
};

/// The action and value columns read as one pair
/// (`ActionValueIter`, `op_iter.rs:766-770`).
///
/// Not one of the eight [`OpIter`] holds: upstream builds it where a
/// reader wants an action and its value and nothing else — the mark and
/// successor builders of the change decoder, and the conflict resolver.
///
/// It composes rather than re-implements: [`ActionIter`] and [`ValueIter`]
/// are stored whole, [`pos`] is the action cursor's, and every method here
/// moves both and reads through them. A shift stages action, metadata and raw
/// placement together; sequential reads then consume aligned streams, while
/// nonzero jumps reposition from the codec-defined absolute byte prefix.
pub const ActionValueIter = struct {
    /// The action column.
    action: ActionIter,
    /// The metadata and raw value columns.
    value: ValueIter,

    /// The compile-time proof that this type carries the whole `Shiftable`
    /// kernel; [`assertShiftable`] is what makes the mark mean something.
    pub const shiftable = column.Shiftable(ActionValueIter);
    /// A cursor over the action column and the value columns, both at row 0
    /// with their windows open to the end.
    ///
    /// `action` and `value` must be over the same document: the pair is read
    /// as one row, and `ActionValue.pos` is the action cursor's position less
    /// the row it just consumed.
    pub fn init(action: ActionIter, value: ValueIter) ActionValueIter {
        return .{ .action = action, .value = value };
    }

    /// The next row's action, value and position
    /// (`Iterator::next`, `op_iter.rs:781-787`).
    ///
    /// Total, as every other sub-iterator's advance is: a row this cursor
    /// cannot read is `error.MissingValue`, not a `null` a caller has to
    /// remember to check. `shiftNext` keeps the optional, because a window
    /// can legitimately be past the end.
    pub fn tryNext(self: *ActionValueIter) ReadOpError!ActionValue {
        const a = try self.action.tryNext();
        const v = try self.value.tryNext();
        return .{ .action = a, .value = v, .pos = self.action.iter.pos() - 1 };
    }

    /// The row this cursor stands on — that is, how many rows have been
    /// consumed (`Shiftable::pos`, `shift.rs:56-58`). It is the action
    /// cursor's position; the value cursor is kept in step with it.
    pub fn pos(self: *const ActionValueIter) usize {
        return self.action.pos();
    }

    /// The row past the last one this cursor may reach (`Shiftable::max_pos`,
    /// `shift.rs:59-61`): the action window's closed end. The value window is
    /// the same window, kept equal.
    pub fn maxPos(self: *const ActionValueIter) usize {
        return self.action.maxPos();
    }

    /// Closes both windows at `at` (`Shiftable::set_max`, `shift.rs:62-66`),
    /// in rows. Neither cursor rewinds and `at` past the end of the columns
    /// is clamped to their length; the value side moves only its row window,
    /// which [`ValueIter.setMax`] says why is sound.
    pub fn setMax(self: *ActionValueIter, at: usize) void {
        self.action.setMax(at);
        self.value.setMax(at);
    }

    /// Moves the action cursor onto `target` and the value cursor with it
    /// (`Shiftable::advance_to`, `shift.rs:67-72`).
    ///
    /// Reads nothing and returns no value. Forward only, and a failure on the
    /// action side leaves the value side behind it, which is why the action
    /// moves first.
    pub fn advanceTo(self: *ActionValueIter, target: usize) ParseError!void {
        try self.action.advanceTo(target);
        try self.value.advanceTo(target);
    }

    /// Consumes `amount` more rows, saturating rather than wrapping
    /// (`Shiftable::advance_by`, `shift.rs:73-76`).
    pub fn advanceBy(self: *ActionValueIter, amount: usize) ParseError!void {
        return self.advanceTo(self.action.pos() +| amount);
    }

    /// Moves the walk onto `range`: the window follows the range **and** the
    /// walk lands on its start (`Shiftable::shift`, `shift.rs:50-55`).
    ///
    /// The action and value windows move together, including raw placement.
    /// A typed refusal leaves all three cursor states unchanged.
    pub fn shift(self: *ActionValueIter, range: RowRange) ParseError!void {
        var action = self.action;
        var value = self.value;
        try action.shift(range);
        try value.shift(range);
        self.action = action;
        self.value = value;
    }

    /// Repositions onto `range` and reads the row at its start
    /// (`shift_next`, `op_iter.rs:798-805`).
    ///
    /// `ActionValue.pos` is the row just read, which after a `shift` is
    /// `range.start`. `null` is a `range.start` at or past the end of the
    /// window; an error is a window that ran out mid-row, a code that is not
    /// one of the eight, or a value whose bytes the raw column cannot
    /// supply. The value borrows the raw column.
    pub fn shiftNext(self: *ActionValueIter, range: RowRange) ReadOpError!?ActionValue {
        const a = (try self.action.shiftNext(range)) orelse return null;
        const v = (try self.value.shiftNext(range)) orelse return null;
        return .{ .action = a, .value = v, .pos = self.action.iter.pos() - 1 };
    }

    /// Reads row `at` and consumes through it, returning the action and the
    /// value (`Shiftable::seek_to`, `shift.rs:87-96`).
    ///
    /// Forward only: an `at` behind the cursor answers `null` and leaves it
    /// where it is, which is the same `null` a walk past the end gives. Past
    /// the end it is `error.MissingValue` rather than `null`, because both
    /// `tryNth`s are total — they carry no optional — so this method follows
    /// [`ValueIter.seekTo`] and gets its `null` from the backwards check
    /// alone. It is built from `tryNth` on both sides rather than from a raw
    /// seek, so the value side re-places the byte cursor on the row it reads.
    /// The value borrows the raw column.
    pub fn seekTo(self: *ActionValueIter, at: usize) ReadOpError!?ActionValue {
        if (at < self.action.pos()) return null;
        const n = at - self.action.pos();
        const a = try self.action.tryNth(n);
        const v = try self.value.tryNth(n);
        return .{ .action = a, .value = v, .pos = self.action.iter.pos() - 1 };
    }
};

// ── The two walkers ────────────────────────────────────────────────────────

/// The rows of a delta-coded counter column whose realized value lies in
/// `[lo, hi)` (`CtrWalker`, `op_iter.rs:293-312`).
///
/// **This is the one iterator here that allocates.** The B-tree descent
/// that prunes the column to the slabs whose value range overlaps is a
/// stack of frames sized to the tree's height
/// ([`btree.FindByValueRange`](../../src/hexane/btree.zig)), taken by
/// [`init`] and released by [`deinit`]. It is not on the [`OpIter`] path:
/// `OpIter` never constructs one, and the two callers that do
/// ([`SuccWalker`], and upstream's `OpSet::iter_ctr_range`,
/// `op_set.rs:830-834`) each construct exactly one and free it.
///
/// `range` is a range of *rows* and is used as a range of *values*:
/// upstream spells it `col.find_by_range(range.start as u32..range.end as
/// u32)` (`op_iter.rs:299`), and that is what makes `CtrWalker::new(id_ctr,
/// 3..5)` the rows whose id counter is 3 or 4. The name says rows because
/// that is what the caller has; the walk is over values.
pub const CtrWalker = struct {
    /// The column walked (`op_iter.rs:294`).
    col: *const opcols.CounterColumn,
    /// The low end of the value range, exclusive.
    lo: i64,
    /// The high end of the value range, exclusive.
    hi: i64,
    /// The slabs whose value range overlaps, in slab order.
    outer: btree.FindByValueRange,
    /// The candidate slab being scanned, or null while a new one is fetched.
    scan: ?opcols.CounterColumn.Iterator,
    /// The row `scan`'s next value belongs to.
    next_row: usize,
    /// The cursor the candidates are scanned with, kept between slabs so
    /// the walk is one forward pass. See [`CtrWalker.next`].
    carried: ?opcols.CounterColumn.Iterator,

    /// A walker over the values in `range` (`new`, `op_iter.rs:297-302`).
    ///
    /// `hi <= lo` is the empty walk upstream gets from
    /// `FindByRange::new` (`hexane/src/delta/indexed.rs:205-218`), and it
    /// is answered without touching the allocator.
    pub fn init(col: *const opcols.CounterColumn, range: RowRange) ParseError!CtrWalker {
        const lo: i64 = @intCast(range.start);
        const hi: i64 = @intCast(range.end);
        if (hi <= lo) {
            return .{
                .col = col,
                .lo = lo,
                .hi = hi,
                .outer = emptySlabWalk(col),
                .scan = null,
                .next_row = 0,
                .carried = null,
            };
        }
        // The B-tree's range is closed and the caller's is half-open.
        const outer = col.findByRange(lo, hi - 1) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidIndex => return error.UnexpectedEnd,
            error.Overflow => return error.Overflow,
        };
        return .{
            .col = col,
            .lo = lo,
            .hi = hi,
            .outer = outer,
            .scan = null,
            .next_row = 0,
            .carried = null,
        };
    }

    /// Frees the descent's stack. The column is untouched.
    pub fn deinit(self: *CtrWalker) void {
        self.outer.deinit();
        self.* = undefined;
    }

    /// The next row whose value is in `[lo, hi)` (`Iterator::next`,
    /// `op_iter.rs:306-308`).
    ///
    /// A candidate slab is scanned row by row. Upstream scans it run at a
    /// time with arithmetic over repeat runs
    /// (`hexane/src/delta/indexed.rs:242-257`); the port reads every value
    /// in the candidate, because its `nextRun` on a delta column realizes
    /// every value and rewinds at each run boundary
    /// ([`column.zig:3625-3659`](../../src/hexane/column.zig)) — which is
    /// the same rows in the same order, and the pruning that makes the walk
    /// cheap is unchanged.
    pub fn next(self: *CtrWalker) ParseError!?usize {
        while (true) {
            if (self.scan) |*it| {
                const v = (try it.next()) orelse {
                    self.scan = null;
                    continue;
                };
                const row = self.next_row;
                self.next_row += 1;
                const wide: i64 = @intCast(v);
                if (wide >= self.lo and wide < self.hi) return row;
                continue;
            }
            const hit = (try self.outer.next()) orelse return null;
            const slab = self.col.slabAt(hit.slab) orelse continue;
            const from = hit.items_before;
            const to = from + slab.len;
            if (self.carried) |*it| {
                // The hits come in ascending slab order, so the cursor
                // from the previous candidate only ever moves forward and
                // the whole walk is one pass over the column.
                it.setMax(to);
                try it.advanceTo(from);
                self.scan = it.*;
            } else {
                self.scan = try rangedCursor(self.col, .{ .start = from, .end = to });
                self.carried = self.scan;
            }
            self.next_row = from;
        }
    }
};

/// A closed slab walk over nothing, which costs no allocation
/// (`FindByRange::default`, `hexane/src/delta/indexed.rs:190-200`).
fn emptySlabWalk(col: *const opcols.CounterColumn) btree.FindByValueRange {
    return .{ .tree = &col.tree, .lo = 0, .hi = 0, .stack = .empty };
}

/// The rows that own a successor in a counter range
/// (`SuccWalker`, `op_iter.rs:314-339`).
///
/// A [`CtrWalker`] over `succ_ctr` answers *successor positions*; this
/// turns each into the row that owns it, by walking `succ_count`'s running
/// sum forward by however many successors separate them. Positions arrive
/// in ascending order, so `acc` — the number of successors already passed
/// — is the whole state, and the lookup never moves backwards.
///
/// **Allocates**: it holds a [`CtrWalker`], so [`deinit`] releases the
/// descent's stack.
pub fn SuccWalker(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The number of successors passed so far (`op_iter.rs:315`).
        acc: usize,
        /// `succ_count` over the whole column, so its sums are absolute
        /// (`op_iter.rs:323`).
        count: *const opcols.CountColumn,
        /// The [`CtrWalker`] over `succ_ctr` with its first position already
        /// drawn, which is what `Peekable<CtrWalker>` is upstream
        /// (`op_iter.rs:317`).
        ctr: column.Unshift(CtrWalker),

        /// A walker over the rows owning a successor counted in `range`
        /// (`new`, `op_iter.rs:320-326`).
        pub fn init(cols: *const opcols.Columns(O), range: RowRange) ParseError!Self {
            const ctr = try CtrWalker.init(&cols.succ_ctr, range);
            return .{
                .acc = 0,
                .count = &cols.succ_count,
                .ctr = try column.Unshift(CtrWalker).init(ctr),
            };
        }

        /// Frees the descent's stack, which [`column.Unshift`] holds beside
        /// the lookahead it has already drawn.
        pub fn deinit(self: *Self) void {
            self.ctr.inner.deinit();
            self.* = undefined;
        }

        /// The next row owning a successor in the range, or null at the end
        /// (`Iterator::next`, `op_iter.rs:330-338`).
        ///
        /// Upstream advances a `PrefixIter` over `succ_count` by
        /// `advance_prefix` and reads the landed row's running sum off it
        /// (`op_iter.rs:334-337`). The port asks the *column* for the same
        /// two numbers — `getIndexForPrefix` and `getPrefix`, which is what
        /// `advancePrefix` descends to
        /// ([`column.zig:2309-2322`](../../src/hexane/column.zig)) — and
        /// checks the answer against both prefix sums before it is
        /// believed, so a column that disagrees with itself is
        /// `error.InvalidValue` rather than a wrong row.
        ///
        /// The indexed answer is checked against both bounding prefixes so every
        /// flattened successor consumed is owned by the count row returned.
        ///
        /// Three index lookups per yielded row; upstream notes its own
        /// `advance_prefix` is an index lookup too
        /// ([`prefix.rs:997-1002`](../../github-automerge-automerge/rust/hexane/src/prefix.rs)).
        pub fn next(self: *Self) ParseError!?usize {
            // Positions the count has already passed are of no further use.
            while (self.ctr.peek()) |head| {
                if (head >= self.acc) break;
                _ = try self.ctr.next();
            }
            const head = self.ctr.peek() orelse return null;
            const want = std.math.cast(i64, head) orelse return error.Overflow;
            // The row that owns flattened successor `head` is the one
            // before the first row whose exclusive prefix reaches
            // `head + 1`. A first row of `len() + 1` means the owner is the
            // last row, which is what `getIndexForPrefix` answers with for
            // a target equal to the grand total.
            const at = @min(try self.count.getIndexForPrefix(std.math.add(i64, want, 1) catch
                return error.Overflow), self.count.len());
            if (at == 0) return null;
            const row = at - 1;
            const before = try self.count.getPrefix(row);
            const through = try self.count.getPrefix(row + 1);
            if (before > want or through <= want) return error.InvalidValue;
            self.acc = std.math.cast(usize, through) orelse return error.Overflow;
            return row;
        }
    };
}

// ── The walk itself ────────────────────────────────────────────────────────

/// The name of the first row-indexed column of `cols` that does not hold
/// exactly `cols.len()` rows, or null when every one of them does.
///
/// The lockstep invariant the eleven fields of [`OpIter`] rest on, as a
/// predicate rather than an assertion. `cols.len()` is `id_actor.len()`
/// ([`columns.zig`](columns.zig)), so the first name it can answer is
/// `id_ctr`; the thirteen data columns listed here are the ones
/// [`OpIter.init`] reads, and the five index columns are the ones upstream's
/// single check covers with it (`op_set2/op_set.rs:183-186`).
pub fn rowLengthMismatch(comptime O: type, cols: *const opcols.Columns(O)) ?[]const u8 {
    const Entry = struct { name: []const u8, len: usize };
    const rows = cols.len();
    const lens = [_]Entry{
        .{ .name = "id_ctr", .len = cols.id_ctr.len() },
        .{ .name = "obj_actor", .len = cols.obj_actor.len() },
        .{ .name = "obj_ctr", .len = cols.obj_ctr.len() },
        .{ .name = "key_actor", .len = cols.key_actor.len() },
        .{ .name = "key_ctr", .len = cols.key_ctr.len() },
        .{ .name = "key_str", .len = cols.key_str.len() },
        .{ .name = "succ_count", .len = cols.succ_count.len() },
        .{ .name = "insert", .len = cols.insert.len() },
        .{ .name = "action", .len = cols.action.len() },
        .{ .name = "value_meta", .len = cols.value_meta.len() },
        .{ .name = "mark_name", .len = cols.mark_name.len() },
        .{ .name = "expand", .len = cols.expand.len() },
        .{ .name = "index.text", .len = cols.index.text.len() },
        .{ .name = "index.top", .len = cols.index.top.len() },
        .{ .name = "index.visible", .len = cols.index.visible.len() },
        .{ .name = "index.mark", .len = cols.index.mark.len() },
    };
    for (lens) |entry| {
        if (entry.len != rows) return entry.name;
    }
    return null;
}

/// The name of the first successor-indexed column of `cols` that
/// disagrees with `cols.subLen()`, or with the sum of `succ_count`, or null
/// when they all agree.
///
/// The same lockstep hazard one level down: [`SuccIterIter`] advances three
/// flattened cursors together and reads a count that says how many
/// successors came before, so a `succ_count` that does not sum to the
/// length of the flattened pair is a document the walk cannot read. Also
/// reports the value arena being shorter than the metadata column's grand
/// total, which [`ValueIter`] would run off the end of.
pub fn succLengthMismatch(comptime O: type, cols: *const opcols.Columns(O)) ?[]const u8 {
    const Entry = struct { name: []const u8, len: usize };
    const succs = cols.subLen();
    const lens = [_]Entry{
        .{ .name = "succ_actor", .len = cols.succ_actor.len() },
        .{ .name = "succ_ctr", .len = cols.succ_ctr.len() },
        .{ .name = "index.inc", .len = cols.index.inc.len() },
    };
    for (lens) |entry| {
        if (entry.len != succs) return entry.name;
    }
    // columns.rs:297-300 — the flattened pair is the sum of the counts.
    const total = cols.succ_count.getPrefix(cols.len()) catch return "succ_count";
    if (total < 0 or @as(usize, @intCast(total)) != succs) return "succ_count";
    const bytes = cols.value_meta.getPrefix(cols.len()) catch return "value_meta";
    if (bytes < 0 or @as(usize, @intCast(bytes)) > cols.value.len()) return "value";
    return null;
}

/// Establishes the lockstep invariant [`OpIter`] rests on, or says which
/// column broke it.
///
/// Thirteen `len()` calls and two prefix lookups: O(1), no walk, no
/// allocation. [`OpIter.init`] calls it, so a column set that cannot be
/// read as one row per position is refused where it is built rather than
/// producing a wrong row later. `error.UnexpectedEnd` is the same answer
/// [`columns.zig`](columns.zig)'s loader gives a column that ends before
/// the rows do, which is exactly what a short column is.
pub fn checkRowLengths(comptime O: type, cols: *const opcols.Columns(O)) ParseError!void {
    if (rowLengthMismatch(O, cols) != null) return error.UnexpectedEnd;
    if (succLengthMismatch(O, cols) != null) return error.UnexpectedEnd;
}

/// The widest row's successor count in `range`: the successor buffer a
/// walk of `range` needs.
///
/// One pass over `succ_count`, and no more than the walk itself costs.
pub fn maxSuccCount(comptime O: type, cols: *const opcols.Columns(O), range: RowRange) ParseError!usize {
    var it = try cols.succ_count.iterRange(range);
    var most: usize = 0;
    while (try it.next()) |n| most = @max(most, @as(usize, n));
    return most;
}

/// The op set's rows, one [`Op`] at a time (`OpIter`, `op_iter.rs:19-32`).
///
/// The eleven fields are `pos`, the eight sub-iterators, the window, and
/// the op set. `next` advances all eight together and hands back one row
/// read out of them, in the order upstream reads
/// (`op_iter.rs:99-126`): id, key, insert, action, object, value, mark,
/// successors.
///
/// **The storage behind an `Op` must outlive it.** See the module
/// documentation: the column set and the string table are borrowed, and so
/// is the successor buffer, whose contents the next `next` overwrites.
///
/// The range is a row range and costs nothing extra: every sub-iterator is
/// built over it and the column layer positions each cursor as it is
/// constructed ([`Column.iterRange`](../../src/hexane/column.zig)).
pub fn OpIter(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set the sub-iterators read.
        pub const Ops = opcols.Columns(O);

        /// The row the next `next` returns (`op_iter.rs:21`). Named `row`
        /// so [`pos`] can be the `Shiftable` kernel's accessor, as it is on
        /// `RawColumnIter` ([`raw.zig:859-867`](../../src/hexane/raw.zig))
        /// and on `SuccCursors` ([`op.zig:299-302`](op.zig)).
        row: usize,
        /// The two halves of each row's own id (`op_iter.rs:22`).
        id: OpIdIter,
        /// The parent object (`op_iter.rs:23`).
        obj: ObjIdIter,
        /// The map key or sequence anchor (`op_iter.rs:24`).
        key: KeyIter,
        /// The row's successors (`op_iter.rs:25`).
        succ: SuccIterIter,
        /// Whether the row inserts (`op_iter.rs:26`).
        insert: InsertIter,
        /// What the row does (`op_iter.rs:27`).
        action: ActionIter,
        /// What it carries (`op_iter.rs:28`).
        value: ValueIter,
        /// Its mark's name and expansion (`op_iter.rs:29`).
        marks: MarkInfoIter,
        /// The rows this walk covers (`op_iter.rs:30`; the port's `window`,
        /// because [`range`] is the accessor that reads it).
        window: RowRange,
        /// The op set behind them (`op_iter.rs:31`).
        cols: *const Ops,

        /// A walk over the rows of `range` (`OpSet::iter_range`,
        /// `op_set.rs:1317-1341`).
        ///
        /// `range` is clamped to the column set, as `iter_range` clamps
        /// each end ([`hexane/src/column.rs:1384-1421`]), so a caller
        /// holding a stale range gets a short walk rather than a wrong one.
        ///
        /// `succ_scratch` is the caller's buffer for the successors; size
        /// it with [`maxSuccCount`] and see [`SuccIterIter`]. It is the
        /// only storage this constructor needs and it is not this
        /// constructor's to own.
        ///
        /// `error.UnexpectedEnd` when the column set cannot be walked as
        /// one row per position — see [`checkRowLengths`], which is what
        /// establishes the lockstep invariant the eight sub-iterators rest
        /// on.
        pub fn init(
            cols: *const Ops,
            strings: StringTable,
            rows: RowRange,
            succ_scratch: []SuccEntry,
        ) ParseError!Self {
            try checkRowLengths(O, cols);
            const window = column.clampRange(rows, cols.len());
            // op_set.rs:1297-1298 and :1280-1281 — the two prefix positions
            // are read first, because the successor and value cursors are
            // windows into columns indexed by them.
            const succ_start = try prefixAt(&cols.succ_count, window.start);
            const value_start = try prefixAt(&cols.value_meta, window.start);
            return .{
                .row = window.start,
                .id = OpIdIter.init(
                    try rangedCursor(&cols.id_actor, window),
                    try rangedCursor(&cols.id_ctr, window),
                ),
                .obj = ObjIdIter.init(
                    try rangedCursor(&cols.obj_actor, window),
                    try rangedCursor(&cols.obj_ctr, window),
                ),
                .key = KeyIter.init(
                    try rangedCursor(&cols.key_str, window),
                    try rangedCursor(&cols.key_actor, window),
                    try rangedCursor(&cols.key_ctr, window),
                    strings,
                ),
                .succ = SuccIterIter.init(
                    try rangedPrefix(&cols.succ_count, window),
                    try rangedCursor(&cols.succ_actor, .{ .start = succ_start, .end = cols.succ_actor.len() }),
                    try rangedCursor(&cols.succ_ctr, .{ .start = succ_start, .end = cols.succ_ctr.len() }),
                    try rangedCursor(&cols.index.inc, .{ .start = succ_start, .end = cols.index.inc.len() }),
                    succ_start,
                    succ_scratch,
                ),
                .insert = InsertIter.init(try rangedCursor(&cols.insert, window)),
                .action = ActionIter.init(try rangedCursor(&cols.action, window)),
                .value = ValueIter.init(
                    try rangedPrefix(&cols.value_meta, window),
                    try cols.value.iteratorAt(value_start),
                ),
                .marks = MarkInfoIter.init(
                    try rangedCursor(&cols.mark_name, window),
                    try rangedCursor(&cols.expand, window),
                    strings,
                ),
                .window = window,
                .cols = cols,
            };
        }

        /// The column set behind the walk. Held so that the storage an
        /// [`Op`] borrows has an owner the reader can see.
        pub fn columns(self: *const Self) *const Ops {
            return self.cols;
        }

        /// The rows still to be walked (`range`, `op_iter.rs:87-89`).
        pub fn range(self: *const Self) RowRange {
            return .{ .start = self.row, .end = self.endPos() };
        }

        /// One past the last row this walk can yield (`end_pos`,
        /// `op_iter.rs:91-93`).
        pub fn endPos(self: *const Self) usize {
            return self.id.actor.maxPos();
        }

        /// The row the next `next` returns (`pos`, `op_iter.rs:95-97`;
        /// [`Column.Iterator.pos`](../../src/hexane/column.zig)).
        pub fn pos(self: *const Self) usize {
            return self.row;
        }

        /// How many rows are left (`ExactSizeIterator::len`,
        /// `op_iter.rs:81-83`).
        pub fn len(self: *const Self) usize {
            return self.endPos() - self.row;
        }

        /// The `Shiftable` conformance mark for the walk itself. Its
        /// instantiation *is* the check.
        pub const shiftable = column.Shiftable(Self);

        /// One past the last row this walk can yield, the kernel's name for
        /// [`endPos`] ([`Column.Iterator.maxPos`](../../src/hexane/column.zig)).
        pub fn maxPos(self: *const Self) usize {
            return self.endPos();
        }

        /// Truncates the walk at `at`
        /// ([`Column.Iterator.setMax`](../../src/hexane/column.zig)).
        ///
        /// Forwarded to all eight sub-iterators, which is what keeps them in
        /// step; the row this walk reports is not moved, so a walk truncated
        /// behind itself reports a position it can no longer read — the
        /// same as any other cursor's window.
        pub fn setMax(self: *Self, at: usize) void {
            self.id.setMax(at);
            self.obj.setMax(at);
            self.key.setMax(at);
            self.succ.setMax(at);
            self.insert.setMax(at);
            self.action.setMax(at);
            self.value.setMax(at);
            self.marks.setMax(at);
        }

        /// Advances so the next `next` is the row at `target`, moving all
        /// eight sub-iterators in step
        /// ([`Column.Iterator.advanceTo`](../../src/hexane/column.zig)).
        ///
        /// A target behind the walk is a no-op, so a shift into a range the
        /// cursor already sits in is harmless. The byte and flattened
        /// cursors inside [`ValueIter`] and [`SuccIterIter`] follow, which
        /// is what makes a reposition land on the right payload and the
        /// right successors.
        pub fn advanceTo(self: *Self, target: usize) ParseError!void {
            if (target <= self.row) return;
            try self.id.advanceTo(target);
            try self.obj.advanceTo(target);
            try self.key.advanceTo(target);
            try self.succ.advanceTo(target);
            try self.insert.advanceTo(target);
            try self.action.advanceTo(target);
            try self.value.advanceTo(target);
            try self.marks.advanceTo(target);
            self.row = target;
        }

        /// Advances past `amount` rows.
        pub fn advanceBy(self: *Self, amount: usize) ParseError!void {
            return self.advanceTo(self.row +| amount);
        }

        /// Repositions all eight sub-iterators onto `rows`: the window ends
        /// at `rows.end`, and the next read is at `rows.start` unless the
        /// forward-only walk has already passed it. This adapter follows the
        /// column shift contract (`hexane/src/column.rs:537-545`).
        ///
        /// A parse error leaves the walk, every cursor, and their windows
        /// unchanged. The checkpoint borrows the same columns and successor
        /// scratch; repositioning does not write that scratch.
        ///
        /// [`window`] is the range the walk was *constructed* over and does
        /// not change; [`range`] is the effective one and does.
        pub fn shift(self: *Self, rows: RowRange) ParseError!void {
            var shifted = self.*;
            shifted.setMax(rows.end);
            try shifted.advanceTo(rows.start);
            self.* = shifted;
        }

        /// Repositions the walk onto `range` and reads the row at its start
        /// ([`Iter::shift_next`, `column.rs:968-975`](../../github-automerge-automerge/rust/hexane/src/column.rs)).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadOpError!?Op {
            if (rows.start < self.row) return error.InvalidValue;
            self.setMax(rows.end);
            try self.advanceTo(rows.start);
            return self.next();
        }

        /// Consumes through `at` and reads the row there, or null when `at`
        /// is behind the walk
        /// ([`Iter::seek_to`, `column.rs:978-985`](../../github-automerge-automerge/rust/hexane/src/column.rs)).
        pub fn seekTo(self: *Self, at: usize) ReadOpError!?Op {
            if (at < self.row) return null;
            try self.advanceTo(at);
            return self.next();
        }

        /// The next row, or null at the end of the walk (`try_next`,
        /// `op_iter.rs:99-126`).
        ///
        /// `conflict` is false for every row a plain walk produces: only
        /// the top-op scan sets it (`op_set2/op_set/top_op.rs:62`), and it
        /// is not this iterator (`op_iter.rs:111`).
        pub fn next(self: *Self) ReadOpError!?Op {
            const id = (try self.id.maybeTryNext()) orelse return null;
            const key = try self.key.tryNext();
            const is_insert = try self.insert.tryNext();
            const action = try self.action.tryNext();
            const obj = try self.obj.tryNext();
            const value = try self.value.tryNext();
            const mark = try self.marks.tryNext();
            const succ = try self.succ.tryNext();
            const row = self.row;
            self.row += 1;
            return Op.init(row, false, id, action, obj, key, is_insert, value, mark.expand, mark.name, succ);
        }

        /// The row `n` rows ahead, consuming everything up to and including
        /// it (`try_nth`, `op_iter.rs:128-155`).
        ///
        /// Upstream's `Iterator::nth` is `self.try_nth(n).unwrap()`
        /// (`op_iter.rs:191-193`) — it panics on a read error and answers
        /// `None` past the end. The port answers `null` past the end *and*
        /// checks it **before** advancing anything, so a walk asked for a
        /// row it does not have is left exactly where it was. There is no
        /// call site of `OpIter::nth` in the op set (`op_set.rs:690` is
        /// the one `nth` in that file, and it is on the `insert` column's
        /// own cursor), so nothing depends on the panicking half; the
        /// error a genuine read failure raises is returned rather than
        /// unwrapped, per `AGENTS.md`.
        pub fn tryNth(self: *Self, n: usize) ReadOpError!?Op {
            if (n >= self.len()) return null;
            const id = (try self.id.maybeTryNth(n)) orelse return null;
            const key = try self.key.tryNth(n);
            const is_insert = try self.insert.tryNth(n);
            const action = try self.action.tryNth(n);
            const obj = try self.obj.tryNth(n);
            const value = try self.value.tryNth(n);
            const mark = try self.marks.tryNth(n);
            const succ = try self.succ.tryNth(n);
            const row = self.row + n;
            self.row += n + 1;
            return Op.init(row, false, id, action, obj, key, is_insert, value, mark.expand, mark.name, succ);
        }
    };
}

/// A prefix column's running sum at `row`, as an index into the column it
/// is a prefix *of* (`get_prefix`, `op_set2/op_set.rs:1297-1298`).
fn prefixAt(col: anytype, row: usize) ParseError!usize {
    const sum = try col.getPrefix(row);
    if (sum < 0) return error.Overflow;
    return std.math.cast(usize, sum) orelse error.Overflow;
}

/// Converts a codec prefix to absolute coordinates, including rebased windows.
fn absolutePrefix(sum: i64, base: i64) ParseError!usize {
    const absolute = std.math.add(i64, sum, base) catch return error.Overflow;
    if (absolute < 0) return error.Overflow;
    return std.math.cast(usize, absolute) orelse error.Overflow;
}

/// A cursor over the rows of `range` in `col`, clamped to the column
/// (`Column::iter_range`, [`hexane/src/column.rs:1384-1421`]).
///
/// Going through the public path — the whole-column cursor, the window
/// trimmed to `range.end`, then advanced onto `range.start` — rather than
/// through `iterRange` is belt-and-braces against a class of defect this
/// column layer once had: a windowed cursor that *spent its own window*
/// while positioning itself, so a range starting inside a slab lost
/// `start` rows from the window (a walk over `1..3` yielded one row, not
/// two) and, when the window was shorter than the offset, underflowed.
/// `Column.iterRange` no longer does that: it places the cursor on
/// `window.start` and walks the decoder onto the same row without touching
/// `items_left` ([`column.zig:1752-1798`](../../src/hexane/column.zig)),
/// which is the shape upstream's `iter_range` has — it advances
/// `decoder.nth(offset - 1)`, touching the decoder and nothing else
/// ([`column.rs:1406-1419`](../../github-automerge-automerge/rust/hexane/src/column.rs))
/// — and it is pinned by `test "a window that starts inside a slab
/// positions on the window's start"`
/// ([`column.zig:5236`](../../src/hexane/column.zig)) and `test "a row
/// cursor positions through every way a window is moved"`
/// ([`column.zig:5378`](../../src/hexane/column.zig)).
///
/// The guard stays because the property is worth stating where the cursors
/// this file builds are built: the cursor leaves here standing on
/// `window.start` with a window `window.end - window.start` long, which is
/// what upstream's `iter_range` leaves and what every sub-iterator that
/// takes it assumes. A range starting at zero needs no positioning, and one
/// starting at or past the end takes `iterRange`'s own unpositioned path,
/// which answers the same.
fn rangedCursor(col: anytype, range: RowRange) ParseError!@TypeOf(col.*).Iterator {
    const window = column.clampRange(range, col.len());
    if (window.start == 0 or window.start >= col.len()) return col.iterRange(window);
    var it = try col.iterator();
    it.setMax(window.end);
    try it.advanceTo(window.start);
    return it;
}

/// A cursor over the rows of `range` in a prefix column, with its running
/// sums already rebased on `range.start`
/// (`PrefixColumn::iter_range`, [`hexane/src/prefix.rs:668-676`]).
///
/// It goes through [`rangedCursor`] rather than `prefixIterRange` for the
/// same reason and with the same guard, so the defect class and the fix are
/// stated once, there. What it adds is the rebasing: the sums a cursor over
/// a sub-range reports are relative to that range's start, so `base` is the
/// column's absolute prefix at `window.start` and `sum` starts at zero —
/// which is why [`ValueIter`] and [`SuccIterIter`] add `base` back before
/// using a sum as an absolute index.
fn rangedPrefix(col: anytype, range: RowRange) ParseError!@TypeOf(col.*).PrefixIter {
    const window = column.clampRange(range, col.len());
    return .{
        .col = col,
        .inner = try rangedCursor(col, window),
        .sum = 0,
        .base = try col.getPrefix(window.start),
    };
}

/// Fails to compile unless every sub-iterator [`OpIter`] holds carries the
/// full `Shiftable` kernel (`hexane/src/iter/tools.rs:19-74`).
///
/// The instantiation *is* the check, as it is for the column layer's own
/// cursors ([`column.zig`](../../src/hexane/column.zig)); a per-type
/// `shiftable` mark would only fire if something referenced it, so this is
/// what a test calls to make it mean something.
pub fn assertShiftable() void {
    inline for (.{
        OpIdIter,        InsertIter, KeyIter,   ObjIdIter,
        MarkInfoIter,    ActionIter, ValueIter, SuccIterIter,
        ActionValueIter,
    }) |I| {
        _ = column.Shiftable(I);
    }
}

/// The same check for a walk: every sub-iterator *and* [`OpIter`] itself
/// carry the full kernel, so a reader that wraps a walk in its own cursor —
/// `MarkIter`, `OpsFoundIter`, `InsertQuery` — can be marked
/// `column.Shiftable(ThatCursor)` with the real inner and not a stand-in.
///
/// Separate from [`assertShiftable`] because `OpIter` is generic in the op
/// type and the sub-iterators are not, so a caller picks one and the other
/// needs no parameter.
pub fn assertShiftableFor(comptime O: type) void {
    assertShiftable();
    _ = column.Shiftable(OpIter(O));
}

// ── The tests' op type and string table ────────────────────────────────────

const testing = std.testing;

/// A row held by value, with the accessors `Columns.splice` calls and
/// nothing else, so a test that splices is a statement about the columns
/// rather than about a view. The same shape `columns.zig` uses for its own
/// tests.
///
/// Every accessor below is a plain field read with the `OpLike` name
/// [`Columns(O).splice`](columns.zig) looks the row up by. This is a test
/// fixture and is **not** a second implementation of anything: `visible`,
/// `top` and `markIndex` are whatever the test put in the row rather than
/// anything derived, which is the point — a test that splices a row and reads
/// it back is checking that the columns preserved it, not that the port can
/// recompute it. `succs` and `incs` are borrowed from the test's table and
/// must outlive the splice.
const Row = struct {
    op_id: OpId = .root,
    parent: ?OpId = null,
    act: Action = .set,
    anchor: KeyRef = .fromStr(""),
    does_insert: bool = false,
    does_expand: bool = false,
    is_visible: bool = true,
    is_top: bool = true,
    units: i64 = 0,
    v: ScalarValue = .null_value,
    name: ?[]const u8 = null,
    mark: ?i64 = null,
    succs: []const OpId = &.{},
    incs: []const ?i64 = &.{},

    /// The row's own id, as the fixture stores it.
    pub fn id(self: Row) OpId {
        return self.op_id;
    }

    /// The parent object, or null for a root row.
    pub fn obj(self: Row) ?OpId {
        return self.parent;
    }

    /// The action, as the fixture stores it.
    pub fn action(self: Row) Action {
        return self.act;
    }

    /// The map key or sequence anchor the row hangs by.
    pub fn key(self: Row) KeyRef {
        return self.anchor;
    }

    /// Whether the row inserts rather than overwrites.
    pub fn insert(self: Row) bool {
        return self.does_insert;
    }

    /// Whether a mark's expansion passes its end.
    pub fn expand(self: Row) bool {
        return self.does_expand;
    }

    /// Whether the row is visible, as the test said it would be.
    pub fn visible(self: Row) bool {
        return self.is_visible;
    }

    /// Whether the row wins its register, as the test said it would.
    pub fn top(self: Row) bool {
        return self.is_top;
    }

    /// The width the test gave the row. The sequence type and the text
    /// encoding are ignored: a fixture states its width, it does not compute
    /// one.
    pub fn width(self: Row, _: types.SequenceType, _: types.TextEncoding) i64 {
        return self.units;
    }

    /// The scalar the row carries.
    pub fn value(self: Row) ScalarValue {
        return self.v;
    }

    /// The metadata word `value` would occupy in the value column.
    pub fn metaValue(self: Row) ValueMeta {
        return optypes.metaOf(self.v);
    }

    /// The mark's name, or null for a row that is not a mark. Borrowed from
    /// the test's table.
    pub fn markName(self: Row) ?[]const u8 {
        return self.name;
    }

    /// The mark-index word, or null for a row that is not a mark. Stated by
    /// the test rather than computed, for the reason the type doc gives.
    pub fn markIndex(self: Row) ?i64 {
        return self.mark;
    }

    /// How many successors the row has: `succs.len`.
    pub fn succCount(self: Row) usize {
        return self.succs.len;
    }

    /// The `i`-th successor's id. `i` is the caller's to keep below
    /// [`succCount`](Row.succCount); this is a fixture, not a parser.
    pub fn succAt(self: Row, i: usize) OpId {
        return self.succs[i];
    }

    /// How many successors carry an increment: `incs.len`.
    pub fn succIncCount(self: Row) usize {
        return self.incs.len;
    }

    /// The `i`-th successor's increment, or null for one that deletes it.
    /// `i` is the caller's to keep below
    /// [`succIncCount`](Row.succIncCount).
    pub fn succIncAt(self: Row, i: usize) ?i64 {
        return self.incs[i];
    }
};

/// A string table for the tests: the strings it has been given, in the
/// order they were first asked for.
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

    fn intern(ctx: *const anyopaque, text: []const u8, gpa: std.mem.Allocator) ParseError!u32 {
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

/// A spliced op set plus the table its strings are interned in. Freed by
/// `deinit`; the `Op`s a walk of it produces borrow both.
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

    fn deinit(self: *Fixture) void {
        self.cols.deinit();
        self.table.deinit();
    }

    fn strings(self: *Fixture) StringTable {
        return self.table.asTable();
    }
};

/// An allocator that counts what goes through it, so a test can assert
/// that a walk asked for nothing.
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

/// Six rows that put a value in every column a row has: a parent, a string
/// key, a payload, a width, an insert, a mark name, an expansion, a
/// successor and an increment — and, in the last two rows, both shapes of
/// the three key columns, a head and an ordinary element, so a reader has
/// something to tell apart.
const rich: [6]Row = .{
    // The root map: no parent, a string key, no value.
    .{ .op_id = .{ .counter = 1, .actor = 0 }, .act = .make_map, .anchor = .fromStr("map") },
    // An insert into it, anchored to a sequence, carrying a payload.
    .{
        .op_id = .{ .counter = 2, .actor = 0 },
        .parent = .{ .counter = 1, .actor = 0 },
        .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 1, .actor = 0 })),
        .does_insert = true,
        .units = 1,
        .v = .{ .str = "x" },
    },
    // A mark over the same element, with a name and an expansion, hidden
    // and not top.  Its `index.mark` entry is left empty: that column is
    // one of the five derived index columns the walk never reads, and it is
    // the mark index's own word.
    .{
        .op_id = .{ .counter = 3, .actor = 1 },
        .parent = .{ .counter = 1, .actor = 0 },
        .act = .mark,
        .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 2, .actor = 0 })),
        .does_expand = true,
        .is_visible = false,
        .is_top = false,
        .name = "em",
    },
    // An overwrite of the first element by a second actor, with two
    // successors: the one it replaces and an increment of its own.
    .{
        .op_id = .{ .counter = 1, .actor = 1 },
        .parent = .{ .counter = 1, .actor = 0 },
        .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 1, .actor = 0 })),
        .units = 1,
        .v = .{ .str = "yz" },
        .succs = &.{ .{ .counter = 2, .actor = 0 }, .{ .counter = 1, .actor = 1 } },
        .incs = &.{ null, @as(?i64, 5) },
    },
    // The front of that sequence: an insert anchored to the head, which is
    // the one anchor with an absent actor and a *present* zero counter
    // (`op_set2/types.rs:616-628`, `types.rs:663-674`). It is the only
    // anchor that a reader cannot rebuild from a counter, because
    // `(absent, absent)` is a map key (`op_iter.rs:239-241`) and
    // `(absent, 0)` is the head (`:242`).
    .{
        .op_id = .{ .counter = 4, .actor = 0 },
        .parent = .{ .counter = 1, .actor = 0 },
        .anchor = .fromElemId(ElemId.head()),
        .does_insert = true,
        .units = 1,
        .v = .{ .str = "p" },
    },
    // And a second element, anchored to that row's own id: the ordinary
    // anchor, with both halves present, which is what makes the head above
    // a case rather than a constant.
    .{
        .op_id = .{ .counter = 5, .actor = 0 },
        .parent = .{ .counter = 1, .actor = 0 },
        .anchor = .fromElemId(ElemId.fromOpId(.{ .counter = 4, .actor = 0 })),
        .does_insert = true,
        .units = 1,
        .v = .{ .str = "q" },
    },
};

// ── The tests ──────────────────────────────────────────────────────────────

test "a walk over a real op set visits every row exactly once, in row order" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    var scratch: [4]SuccEntry = undefined;
    var it = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = cols.len() }, &scratch);

    var row: usize = 0;
    while (try it.next()) |got| {
        try testing.expectEqual(row, got.pos);
        try testing.expectEqual(false, got.conflict);
        const want = rich[row];
        try testing.expectEqual(want.id(), got.id());
        try testing.expectEqual(want.obj(), got.obj());
        try testing.expect(want.key().eql(got.key()));
        try testing.expectEqual(want.action(), got.action());
        try testing.expectEqual(want.insert(), got.insert());
        try testing.expect(want.value().eql(got.value()));
        try testing.expectEqual(want.expand(), got.expand());
        try testing.expectEqualSlices(u8, want.markName() orelse "", got.markName() orelse "");
        try testing.expectEqual(want.succCount(), got.succCount());
        var s = got.succ();
        var k: usize = 0;
        while (s.next()) |succ| {
            try testing.expectEqual(want.succAt(k), succ);
            k += 1;
        }
        try testing.expectEqual(want.succCount(), k);
        row += 1;
    }
    try testing.expectEqual(rich.len, row);
}

test "a ranged walk visits exactly the rows in its range" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    var scratch: [4]SuccEntry = undefined;
    var it = try OpIter(Row).init(cols, fx.strings(), .{ .start = 1, .end = 3 }, &scratch);

    var row: usize = 1;
    while (try it.next()) |got| {
        try testing.expectEqual(row, got.pos);
        try testing.expectEqual(rich[row].id(), got.id());
        row += 1;
    }
    try testing.expectEqual(@as(usize, 3), row);
    // And the walk reports the range it has left, not the one it was given.
    try testing.expectEqual(3, it.pos());
    try testing.expectEqual(3, it.endPos());
    try testing.expectEqual(@as(usize, 0), it.len());
    try testing.expectEqual(RowRange{ .start = 3, .end = 3 }, it.range());
}

test "a walk stops cleanly at the end of its range and at the end of the column" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    var scratch: [4]SuccEntry = undefined;

    // A range ending before the column does.
    var short = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = 2 }, &scratch);
    try testing.expect((try short.next()) != null);
    try testing.expect((try short.next()) != null);
    try testing.expectEqual(@as(?Op, null), try short.next());
    // A spent walk stays spent.
    try testing.expectEqual(@as(?Op, null), try short.next());
    try testing.expectEqual(@as(usize, 2), short.pos());

    // A range past the column is clamped, so the walk ends at the column.
    var past = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = 99 }, &scratch);
    var seen: usize = 0;
    while (try past.next()) |_| seen += 1;
    try testing.expectEqual(rich.len, seen);
    try testing.expectEqual(@as(?Op, null), try past.next());

    // An empty range yields nothing at all.
    var empty = try OpIter(Row).init(cols, fx.strings(), .{ .start = 2, .end = 2 }, &scratch);
    try testing.expectEqual(@as(?Op, null), try empty.next());
    try testing.expectEqual(@as(usize, 0), empty.len());
}

test "tryNth past the end answers null and leaves the walk where it was" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    var scratch: [4]SuccEntry = undefined;
    var it = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = cols.len() }, &scratch);

    try testing.expectEqual(@as(?Op, null), try it.tryNth(rich.len));
    try testing.expectEqual(@as(?Op, null), try it.tryNth(99));
    try testing.expectEqual(@as(usize, 0), it.pos());
    try testing.expectEqual(rich.len, it.len());

    // And a jump in range consumes everything up to and including its row.
    const got = (try it.tryNth(2)).?;
    try testing.expectEqual(@as(usize, 2), got.pos);
    try testing.expectEqual(rich[2].id(), got.id());
    try testing.expectEqual(@as(usize, 3), it.pos());
    const after = (try it.next()).?;
    try testing.expectEqual(rich[3].id(), after.id());
    try testing.expectEqual(@as(usize, 4), it.pos());
}

test "every sub-iterator advances over the same rows as the walk" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    const whole = RowRange{ .start = 0, .end = cols.len() };
    var scratch: [4]SuccEntry = undefined;
    const strings = fx.strings();

    var walk = try OpIter(Row).init(cols, strings, whole, &scratch);
    var ids = OpIdIter.init(try cols.id_actor.iterRange(whole), try cols.id_ctr.iterRange(whole));
    var inserts = InsertIter.init(try cols.insert.iterRange(whole));
    var keys = KeyIter.init(
        try cols.key_str.iterRange(whole),
        try cols.key_actor.iterRange(whole),
        try cols.key_ctr.iterRange(whole),
        strings,
    );
    var objs = ObjIdIter.init(try cols.obj_actor.iterRange(whole), try cols.obj_ctr.iterRange(whole));
    var marks = MarkInfoIter.init(
        try cols.mark_name.iterRange(whole),
        try cols.expand.iterRange(whole),
        strings,
    );
    var actions = ActionIter.init(try cols.action.iterRange(whole));
    var values = ValueIter.init(
        try cols.value_meta.prefixIterRange(whole),
        try cols.value.iteratorAt(0),
    );
    var succs = SuccIterIter.init(
        try cols.succ_count.prefixIterRange(whole),
        try cols.succ_actor.iterRange(.{ .start = 0, .end = cols.succ_actor.len() }),
        try cols.succ_ctr.iterRange(.{ .start = 0, .end = cols.succ_ctr.len() }),
        try cols.index.inc.iterRange(.{ .start = 0, .end = cols.index.inc.len() }),
        0,
        &scratch,
    );
    var both = ActionValueIter.init(
        ActionIter.init(try cols.action.iterRange(whole)),
        ValueIter.init(
            try cols.value_meta.prefixIterRange(whole),
            try cols.value.iteratorAt(0),
        ),
    );

    var row: usize = 0;
    while (try walk.next()) |got| {
        try testing.expectEqual(got.id(), (try ids.maybeTryNext()).?);
        try testing.expectEqual(got.insert(), try inserts.tryNext());
        try testing.expect(got.key().eql(try keys.tryNext()));
        try testing.expect(got.objId().eql(try objs.tryNext()));
        const mark = try marks.tryNext();
        try testing.expectEqual(got.markName(), mark.name);
        try testing.expectEqual(got.expand(), mark.expand);
        try testing.expectEqual(got.action(), try actions.tryNext());
        try testing.expect(got.value().eql(try values.tryNext()));
        try testing.expectEqual(got.succCount(), (try succs.tryNext()).len());
        const pair = try both.tryNext();
        try testing.expectEqual(got.pos, pair.pos);
        try testing.expectEqual(got.action(), pair.action);
        try testing.expect(got.value().eql(pair.value));
        row += 1;
    }
    try testing.expectEqual(rich.len, row);

    // Each is spent at the same row the walk is.
    try testing.expectEqual(@as(?OpId, null), try ids.maybeTryNext());
    try testing.expectError(error.MissingValue, objs.tryNext());
    try testing.expectError(error.MissingValue, inserts.tryNext());
    try testing.expectError(error.MissingValue, actions.tryNext());
    try testing.expectError(error.MissingValue, keys.tryNext());
    try testing.expectError(error.MissingValue, marks.tryNext());
    try testing.expectError(error.MissingValue, values.tryNext());
    try testing.expectError(error.MissingValue, succs.tryNext());
    try testing.expectError(error.MissingValue, both.tryNext());
}

test "a short successor buffer is refused rather than truncated" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    // Row 3 has two successors; a one-entry buffer cannot hold them. It is
    // the widest row, not the last one — the two head-anchored rows behind
    // it have none.
    var one: [1]SuccEntry = undefined;
    var it = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = cols.len() }, &one);
    var seen: usize = 0;
    while (true) {
        const got = it.next() catch |e| {
            try testing.expectEqual(error.TooLarge, e);
            break;
        };
        if (got == null) break;
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);

    // Sized by the helper the walk is meant to use, it reads every row.
    var wide: [4]SuccEntry = undefined;
    try testing.expectEqual(@as(usize, 2), try maxSuccCount(Row, cols, .{ .start = 0, .end = cols.len() }));
    var ok = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = cols.len() }, &wide);
    var all: usize = 0;
    while (try ok.next()) |_| all += 1;
    try testing.expectEqual(rich.len, all);
}

test "a successor buffer of exactly the widest row reads every row" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    const whole = RowRange{ .start = 0, .end = cols.len() };

    // The width boundary from both sides. `maxSuccCount` is the exact size a
    // buffer needs and not one entry less: the test above refuses one entry
    // less, and this pins that the number it hands out is itself enough —
    // which is the property the type doc leans on when it says the buffer
    // must hold "at least the widest row's successor count".
    try testing.expectEqual(@as(usize, 2), try maxSuccCount(Row, cols, whole));
    var exact: [2]SuccEntry = undefined;
    var ok = try OpIter(Row).init(cols, fx.strings(), whole, &exact);
    var rows: usize = 0;
    while (try ok.next()) |_| rows += 1;
    try testing.expectEqual(rich.len, rows);

    // And one entry short is still refused, at the same row the wider
    // buffer walks past: the refusal is about the width, not about being
    // the last row.
    var one_short: [1]SuccEntry = undefined;
    var refused = try OpIter(Row).init(cols, fx.strings(), whole, &one_short);
    var seen: usize = 0;
    while (true) {
        const got = refused.next() catch |e| {
            try testing.expectEqual(error.TooLarge, e);
            break;
        };
        if (got == null) break;
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "a value takes exactly the width its word declares, and one byte more is refused" {
    const gpa = testing.allocator;

    // `(length << 4) | tag`: the byte length is the word's **high** bits and
    // the type is the low nibble (`op_set2/meta.rs:19-43`), so the word alone
    // decides how many bytes the read takes — and `+ 1` does not make it one
    // byte longer.
    const word = optypes.metaOf(.{ .str = "ab" });

    var raw = try rawcol.RawColumn.init(gpa);
    defer raw.deinit();
    try raw.spliceSlice(0, 0, "ab");
    try testing.expectEqual(@as(usize, 2), raw.len());

    // Exactly what the arena holds reads, and the row past it is a missing
    // value rather than an empty string.
    var meta = try opcols.MetaColumn.init(gpa);
    defer meta.deinit();
    try meta.extend(gpa, &.{word.raw});
    var exact = ValueIter.init(try meta.prefixIter(), raw.iterator());
    try testing.expectEqualStrings("ab", (try exact.tryNext()).str);
    try testing.expectError(error.MissingValue, exact.tryNext());

    // One byte more than the arena holds is `error.InvalidValue`, not a short
    // read: the value is refused rather than silently truncated, which is
    // what `take` promises and what `try meta.length()` has to hand it. The
    // word has to be *wider at the same tag* — `+ (1 << 4)` — because
    // `+ 1` would leave the length at two and hand the same two bytes to
    // `fromRaw` under the next type up (`meta.rs:23-38`).
    var wide_meta = try opcols.MetaColumn.init(gpa);
    defer wide_meta.deinit();
    try wide_meta.extend(gpa, &.{word.raw + (@as(u64, 1) << 4)});
    var wide = ValueIter.init(try wide_meta.prefixIter(), raw.iterator());
    try testing.expectError(error.InvalidValue, wide.tryNext());
}

test "the successors a walk hands out are the ones loadSuccWindow reads" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    const succ_cols: opmod.SuccColumns = .{
        .count = &cols.succ_count,
        .actor = &cols.succ_actor,
        .counter = &cols.succ_ctr,
        .increment = &cols.index.inc,
    };
    var scratch: [4]SuccEntry = undefined;
    var it = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = cols.len() }, &scratch);
    while (try it.next()) |got| {
        var window: [4]SuccEntry = undefined;
        const want = try opmod.loadSuccWindow(&succ_cols, got.pos, &window);
        try testing.expectEqual(want.len(), got.succCount());
        try testing.expectEqual(want.pos(), got.succ().pos());
        var a = want;
        var b = got.succ();
        while (a.next()) |one| try testing.expectEqual(one, b.next().?);
    }
}

test "every row-indexed column of a spliced op set is the same length" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;

    // The property holds on a set built by splice, in both index spaces.
    try testing.expectEqual(@as(?[]const u8, null), rowLengthMismatch(Row, cols));
    try testing.expectEqual(@as(?[]const u8, null), succLengthMismatch(Row, cols));
    try checkRowLengths(Row, cols);
    try testing.expectEqual(rich.len, cols.len());

    // A column set that cannot be walked as one row per position is
    // refused, and the predicate names the column that broke it.
    try cols.expand.splice(gpa, 2, 1, &.{});
    try testing.expectEqualStrings("expand", rowLengthMismatch(Row, cols).?);
    try testing.expectError(error.UnexpectedEnd, checkRowLengths(Row, cols));
    var scratch: [4]SuccEntry = undefined;
    try testing.expectError(
        error.UnexpectedEnd,
        OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = cols.len() }, &scratch),
    );
}

test "a successor column that disagrees with succ_count is refused" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    try testing.expectEqual(@as(?[]const u8, null), succLengthMismatch(Row, cols));
    try cols.succ_ctr.splice(gpa, 0, 1, &.{});
    try testing.expectEqualStrings("succ_ctr", succLengthMismatch(Row, cols).?);
    try testing.expectError(error.UnexpectedEnd, checkRowLengths(Row, cols));
}

test "try_load answers a hit and every kind of miss" {
    // OpId: both halves, no negative counter.  op_iter.rs:196-208
    try testing.expectEqual(OpId.init(4, 2), try tryLoadOpId(2, 4));
    try testing.expectError(error.InvalidOpId, tryLoadOpId(null, 4));
    try testing.expectError(error.InvalidOpId, tryLoadOpId(2, null));
    try testing.expectError(error.InvalidOpId, tryLoadOpId(2, -1));

    // ObjId: a counter of zero and a pair of nulls are both the root.
    //  op_iter.rs:210-233
    try testing.expectEqual(ObjId{ .id = OpId.init(4, 2) }, try tryLoadObjId(2, 4));
    try testing.expect((try tryLoadObjId(null, null)).isRoot());
    try testing.expect((try tryLoadObjId(7, 0)).isRoot());
    try testing.expectError(error.InvalidOpId, tryLoadObjId(2, null));
    try testing.expectError(error.InvalidOpId, tryLoadObjId(null, 4));
    try testing.expectError(error.InvalidOpId, tryLoadObjId(2, -1));

    // ElemId: null counter, the head, and a positive counter.
    //  op_iter.rs:235-249
    try testing.expectEqual(@as(?ElemId, null), try tryLoadElemId(null, null));
    try testing.expectEqual(ElemId.head(), (try tryLoadElemId(null, 0)).?);
    try testing.expectEqual(ElemId.fromOpId(OpId.init(4, 2)), (try tryLoadElemId(2, 4)).?);
    try testing.expectError(error.InvalidKey, tryLoadElemId(2, null));
    try testing.expectError(error.InvalidKey, tryLoadElemId(null, 4));
    try testing.expectError(error.InvalidKey, tryLoadElemId(2, 0));
    try testing.expectError(error.InvalidKey, tryLoadElemId(2, -1));

    // KeyRef: exactly one of a map key and a sequence anchor.
    //  op_iter.rs:251-265
    try testing.expect(KeyRef.fromStr("k").eql(try tryLoadKeyRef("k", null, null)));
    try testing.expect(KeyRef.fromElemId(ElemId.fromOpId(OpId.init(4, 2))).eql(try tryLoadKeyRef(null, 2, 4)));
    try testing.expectError(error.MissingKey, tryLoadKeyRef(null, null, null));
    try testing.expectError(error.InvalidKey, tryLoadKeyRef("k", 2, 4));
    try testing.expectError(error.InvalidKey, tryLoadKeyRef("k", 2, 0));
}

/// The keys `range`'s rows read as out of the **stored** columns, through
/// [`KeyIter`] — the production path from `Columns.splice`'s bytes to a
/// reader's [`KeyRef`].
///
/// `KeyIter` is the only way a read reaches the three key columns
/// (`KeyIter`, `op_iter.rs:463-468`), and the one conversion it makes is
/// `?u32` → `?i64` in `load` (`op_iter.rs:508-522`). Everything below the
/// splice and above that widening — the nullable delta encoding of a
/// *present* zero, the `ActorOptColumn`'s absent actor — is crossed here and
/// nowhere else, so a test that only hands `tryLoadKeyRef` the pair `KeyRef`
/// itself produced never reaches any of it.
fn storedKeys(
    gpa: std.mem.Allocator,
    cols: *const Cols,
    strings: StringTable,
    range: RowRange,
) !std.ArrayList(KeyRef) {
    var out: std.ArrayList(KeyRef) = .empty;
    errdefer out.deinit(gpa);
    var keys = KeyIter.init(
        try cols.key_str.iterRange(range),
        try cols.key_actor.iterRange(range),
        try cols.key_ctr.iterRange(range),
        strings,
    );
    // Counted, not `while (try …)`: `tryNext` answers `error.MissingValue`
    // at the end of the window, never `null` (`ReadOpError`).
    var i: usize = range.start;
    while (i < range.end) : (i += 1) try out.append(gpa, try keys.tryNext());
    return out;
}

/// A clock covering every op in `rows` and every successor they name.
///
/// The same rule `coveringClock` states on the visibility side
/// (`visible.zig:855-865`): a delete is never a row
/// (`columns.rs:423-427`), so a clock built from the rows' own ids alone
/// would not cover it.
fn coveringClockOf(gpa: std.mem.Allocator, rows: []const Row) !Clock {
    var c = try Clock.init(gpa, 2);
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

test "an anchor read back from the two key columns is the head it was written as" {
    // A `KeyRef` writes its two key columns as `KeyRef::actor` and
    // `KeyRef::icounter` (`op_set2/change/collector.rs:406-407`), and those
    // two answers are not each other: a head has no actor
    // (`types.rs:668-674`) and a counter of zero (`types.rs:663-666`). So the
    // round trip is: hand the two columns back to `tryLoadKeyRef` and ask
    // whether the answer is the anchor that produced them.
    const roundTrip = struct {
        fn go(key: KeyRef) !KeyRef {
            const counter = key.icounter() orelse return error.TestUnexpectedResult;
            return try tryLoadKeyRef(null, key.actor(), counter);
        }
    }.go;

    // The head: absent actor, zero counter, back as the head.
    const head_key = KeyRef.fromElemId(ElemId.head());
    try testing.expectEqual(@as(?ActorIdx, null), head_key.actor());
    try testing.expectEqual(@as(?i64, 0), head_key.icounter().?);
    try testing.expect((try roundTrip(head_key)).elemid().?.isHead());
    // A writer that put an actor against the head's zero counter would not
    // have written a head at all: the reader refuses that pair
    // (`op_iter.rs:243-246`), which is the failure this type exists to remove.
    try testing.expectError(error.InvalidKey, tryLoadKeyRef(null, 0, 0));

    // A normal element: its own actor and counter, back as itself. The round
    // trip is the identity on every anchor that is not the head.
    const elems = [_]ElemId{
        ElemId.fromOpId(OpId.init(1, 0)),
        ElemId.fromOpId(OpId.init(4, 2)),
        ElemId.fromOpId(OpId.init(std.math.maxInt(u32), std.math.maxInt(ActorIdx))),
    };
    for (elems) |elem| {
        const back = try roundTrip(KeyRef.fromElemId(elem));
        try testing.expect(back.eql(KeyRef.fromElemId(elem)));
        try testing.expectEqual(@as(?ActorIdx, elem.actor()), back.actor());
        try testing.expectEqual(@as(?i64, elem.icounter()), back.icounter().?);
        try testing.expect(!back.elemid().?.isHead());
    }

    // The same round trip, this time through the columns.
    //
    // Everything above hands `tryLoadKeyRef` the pair `KeyRef` itself
    // produced, so it proves the two literals agree and nothing else. The
    // bytes a document actually stores go through `Columns.splice`
    // (`columns.zig:429-435`) and come back out through `KeyIter`
    // (`op_iter.rs:463-468`), and the only step between is its `?u32` →
    // `?i64` widening. So the rest of this test walks rows that were
    // spliced, not literals.
    //
    // **The invariant this establishes:** a head survives storage. The head
    // is the one anchor whose counter is a *present* zero
    // (`columns.zig:2425` pins the stored pair as `null` and `0`), and
    // `key_ctr` is a nullable delta column, so a present zero and an absent
    // value have to stay distinguishable through the splice and back. If
    // they did not, the head row would read back as `(absent, absent)` —
    // a map key (`op_iter.rs:241`) — and a `key_actor` that filled an absent
    // actor with a zero would make it `(0, 0)`, which the reader refuses
    // outright (`:246`).
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    const whole = RowRange{ .start = 0, .end = cols.len() };
    // The two rows [`rich`] added for this: the head-anchored insert and
    // the element anchored to it.
    const head_row = 4;
    const second_row = 5;
    const head = KeyRef.fromElemId(ElemId.head());
    const second = KeyRef.fromElemId(ElemId.fromOpId(rich[head_row].id()));
    // The fixture says what it says, before anything is read back.
    try testing.expect(head.eql(rich[head_row].key()));
    try testing.expectEqual(@as(?ActorIdx, null), rich[head_row].key().actor());
    try testing.expectEqual(@as(?i64, 0), rich[head_row].key().icounter().?);
    try testing.expect(second.eql(rich[second_row].key()));

    // With no clock at all: the keys, out of the three stored columns.
    {
        var keys = try storedKeys(gpa, cols, fx.strings(), whole);
        defer keys.deinit(gpa);
        try testing.expectEqual(rich.len, keys.items.len);
        // The head, read as the head and as nothing else.
        try testing.expect(head.eql(keys.items[head_row]));
        try testing.expect(keys.items[head_row].elemid().?.isHead());
        try testing.expectEqual(@as(?ActorIdx, null), keys.items[head_row].actor());
        try testing.expectEqual(@as(?i64, 0), keys.items[head_row].icounter().?);
        // The element behind it, read as its own id.
        try testing.expect(second.eql(keys.items[second_row]));
        try testing.expectEqual(
            ElemId.fromOpId(rich[head_row].id()),
            keys.items[second_row].elemid().?,
        );
        try testing.expect(!keys.items[second_row].elemid().?.isHead());
        // And the head is not what every row reads as: the map key at row 0
        // is still a map key, and an ordinary element is still an element,
        // so a reader that answered "head" for all three would fail here.
        try testing.expect(KeyRef.fromStr("map").eql(keys.items[0]));
        try testing.expectEqual(@as(?ElemId, null), keys.items[0].elemid());
    }

    // Under a clock, and with none, a walk over the same rows must read the
    // same keys: scoping changes a row's counter and whether it is in view
    // (`visible.rs:196-222`), never what it is anchored to. The head is the
    // case that says so, because a scoped read of a list's front element is
    // the one read a cursor asks for.
    {
        var clock = try coveringClockOf(gpa, &rich);
        defer clock.deinit();
        var keys = try storedKeys(gpa, cols, fx.strings(), whole);
        defer keys.deinit(gpa);
        var scratch: [4]SuccEntry = undefined;
        const covers = [_]?Clock{ null, clock };
        for (covers) |maybe| {
            var walk = try OpIter(Row).init(cols, fx.strings(), whole, &scratch);
            var row: usize = 0;
            var saw_head = false;
            var saw_second = false;
            while (try walk.next()) |got| {
                // `OpIter` reads the same three columns `KeyIter` does, and
                // the scoped rule takes the row by pointer because it
                // rewrites a counter's value (`visible.rs:215-222`), so the
                // walk's own copy is what the rule sees.
                var op = got;
                const in_view = op.scopeToClock(maybe);
                try testing.expect(keys.items[row].eql(op.key()));
                if (row == head_row) {
                    saw_head = true;
                    try testing.expect(head.eql(op.key()));
                    try testing.expect(op.key().elemid().?.isHead());
                    // And the row is in view both ways: a clock cannot hide
                    // the front of a list it has already seen, and that is
                    // the only thing a scoped read does to it besides
                    // folding a counter.
                    try testing.expect(in_view);
                }
                if (row == second_row) {
                    saw_second = true;
                    try testing.expect(second.eql(op.key()));
                }
                row += 1;
            }
            try testing.expectEqual(rich.len, row);
            try testing.expect(saw_head);
            try testing.expect(saw_second);
        }
    }

    // And the narrow part of it, which is where a second bridge defect
    // would show: the stored pair itself, and the one conversion made on
    // it. A `key_ctr` that came back absent where the writer stored a
    // present zero answers `null` from `tryLoadElemId` — a map key — and a
    // counter lost in the widening is a counter no anchor matches.
    {
        // `Column.get` answers `null` past the end of the column, so the
        // row's own value is the inner optional.
        const want_actor = (try cols.key_actor.get(head_row)).?;
        const want_ctr = (try cols.key_ctr.get(head_row)).?;
        try testing.expectEqual(@as(?ActorIdx, null), want_actor);
        try testing.expectEqual(@as(?u32, 0), want_ctr.?);
        try testing.expectEqual(
            @as(?ElemId, ElemId.head()),
            try tryLoadElemId(want_actor, if (want_ctr) |c| @as(i64, c) else null),
        );
    }
}

test "ObjIdIter.seekToValue refuses unresolved named IDs without changing either cursor" {
    // Actor bytes must be resolved by the op set before a resident-column seek.
    const gpa = testing.allocator;
    var actor_col = try opcols.ActorOptColumn.init(gpa);
    defer actor_col.deinit();
    try actor_col.extend(gpa, &.{ null, 1 });
    var ctr_col = try opcols.UintOptColumn.init(gpa);
    defer ctr_col.deinit();
    try ctr_col.extend(gpa, &.{ null, 1 });

    var it = ObjIdIter.init(try actor_col.iterator(), try ctr_col.iterator());
    try it.shift(.{ .start = 1, .end = 2 });
    const named_ids = [_]ObjId{
        ObjId.withActor(OpId.init(1, 0), types.ActorId.init("unresolved")),
        .{ .named = .{
            .op = .{ .counter = @as(u64, std.math.maxInt(u32)) + 1, .actor = 1 },
            .actor = types.ActorId.init("unresolved"),
        } },
        .{ .named = .{
            .op = .{ .counter = std.math.maxInt(u64), .actor = 1 },
            .actor = types.ActorId.init("unresolved"),
        } },
    };
    for (named_ids) |obj| {
        try testing.expectError(error.InvalidValue, it.seekToValue(obj));
        try testing.expectEqual(@as(usize, 1), it.obj_actor.pos());
        try testing.expectEqual(@as(usize, 1), it.obj_ctr.pos());
        try testing.expectEqual(@as(usize, 2), it.obj_actor.maxPos());
        try testing.expectEqual(@as(usize, 2), it.obj_ctr.maxPos());
    }
    try testing.expect((try it.tryNext()).eql(.{ .id = OpId.init(1, 1) }));
}

test "ObjIdIter.seekToValue finds each object's rows and leaves the cursor on them" {
    const gpa = testing.allocator;
    const r = ObjId.root;
    const o11 = ObjId{ .id = OpId.init(1, 1) };
    const o12 = ObjId{ .id = OpId.init(1, 2) };
    const o21 = ObjId{ .id = OpId.init(2, 1) };
    const o22 = ObjId{ .id = OpId.init(2, 2) };
    const o31 = ObjId{ .id = OpId.init(3, 1) };
    const o32 = ObjId{ .id = OpId.init(3, 2) };
    const objs = [_]ObjId{ r, r, r, r, o11, o11, o12, o21, o21, o21, o22, o22, o32, o32 };
    const actors = try gpa.alloc(?ActorIdx, objs.len);
    defer gpa.free(actors);
    const ctrs = try gpa.alloc(?u32, objs.len);
    defer gpa.free(ctrs);
    for (objs, 0..) |o, i| {
        actors[i] = o.actor();
        ctrs[i] = if (o.opId()) |id| id.counter else null;
    }
    var actor_col = try opcols.ActorOptColumn.init(gpa);
    defer actor_col.deinit();
    try actor_col.extend(gpa, actors);
    var ctr_col = try opcols.UintOptColumn.init(gpa);
    defer ctr_col.deinit();
    try ctr_col.extend(gpa, ctrs);

    // Seek each element and read it.  op_iter.rs:1246-1282
    var it = ObjIdIter.init(try actor_col.iterator(), try ctr_col.iterator());
    const steps = [_]struct { obj: ObjId, range: RowRange, count: usize }{
        .{ .obj = r, .range = .{ .start = 0, .end = 4 }, .count = 4 },
        .{ .obj = o11, .range = .{ .start = 4, .end = 6 }, .count = 2 },
        .{ .obj = o12, .range = .{ .start = 6, .end = 7 }, .count = 1 },
        .{ .obj = o21, .range = .{ .start = 7, .end = 10 }, .count = 3 },
        .{ .obj = o22, .range = .{ .start = 10, .end = 12 }, .count = 2 },
        .{ .obj = o31, .range = .{ .start = 12, .end = 12 }, .count = 0 },
        .{ .obj = o32, .range = .{ .start = 12, .end = 14 }, .count = 2 },
    };
    for (steps) |step| {
        try testing.expectEqual(step.range, try it.seekToValue(step.obj));
        try testing.expectEqual(step.range.start, it.pos());
        var read: usize = 0;
        while (read < step.count) : (read += 1) {
            try testing.expect((try it.tryNext()).eql(step.obj));
        }
    }

    // Seek each element and do not read it.  op_iter.rs:1284-1306
    it = ObjIdIter.init(try actor_col.iterator(), try ctr_col.iterator());
    for (steps) |step| {
        try testing.expectEqual(step.range, try it.seekToValue(step.obj));
        try testing.expectEqual(step.range.start, it.pos());
    }

    // Seek only odd items, then only even ones.  op_iter.rs:1308-1333
    it = ObjIdIter.init(try actor_col.iterator(), try ctr_col.iterator());
    for ([_]usize{ 1, 3, 5 }) |i| {
        try testing.expectEqual(steps[i].range, try it.seekToValue(steps[i].obj));
        try testing.expectEqual(steps[i].range.start, it.pos());
    }
    it = ObjIdIter.init(try actor_col.iterator(), try ctr_col.iterator());
    for ([_]usize{ 0, 2, 4, 6 }) |i| {
        try testing.expectEqual(steps[i].range, try it.seekToValue(steps[i].obj));
        try testing.expectEqual(steps[i].range.start, it.pos());
    }
}

/// The merged document upstream's `skip_op_ids` builds
/// (`op_iter.rs:1113-1224`), as the thirteen rows the op set actually holds.
///
/// Actor 0 sets `key1`..`key9`, deletes `key5` and `key7` and overwrites
/// `key3` twice; actor 1 overwrites `key5`; actor 2 deletes `key5`; actor 3
/// overwrites `key5` again. The two deletes are ops with no row —
/// `Columns.splice` drops them (`columns.rs:423-427`) — and they survive
/// only as successor edges, which is why `key5`'s row carries three
/// successors all of counter 10 and `key3`'s first row carries 12.
const merged: [13]Row = .{
    .{ .op_id = .{ .counter = 1, .actor = 0 }, .anchor = .fromStr("key1"), .v = .{ .str = "v1" } },
    .{ .op_id = .{ .counter = 2, .actor = 0 }, .anchor = .fromStr("key2"), .v = .{ .str = "v2" } },
    .{
        .op_id = .{ .counter = 3, .actor = 0 },
        .anchor = .fromStr("key3"),
        .v = .{ .str = "v3" },
        .succs = &.{.{ .counter = 12, .actor = 0 }},
        .incs = &.{null},
    },
    .{
        .op_id = .{ .counter = 12, .actor = 0 },
        .anchor = .fromStr("key3"),
        .v = .{ .str = "val12" },
        .succs = &.{.{ .counter = 13, .actor = 0 }},
        .incs = &.{null},
    },
    .{ .op_id = .{ .counter = 13, .actor = 0 }, .anchor = .fromStr("key3"), .v = .{ .str = "val13" } },
    .{ .op_id = .{ .counter = 4, .actor = 0 }, .anchor = .fromStr("key4"), .v = .{ .str = "v4" } },
    .{
        .op_id = .{ .counter = 5, .actor = 0 },
        .anchor = .fromStr("key5"),
        .v = .{ .str = "v5" },
        .succs = &.{
            .{ .counter = 10, .actor = 0 },
            .{ .counter = 10, .actor = 2 },
            .{ .counter = 10, .actor = 3 },
        },
        .incs = &.{ null, null, null },
    },
    .{ .op_id = .{ .counter = 10, .actor = 1 }, .anchor = .fromStr("key5"), .v = .{ .str = "val10B" } },
    .{ .op_id = .{ .counter = 10, .actor = 3 }, .anchor = .fromStr("key5"), .v = .{ .str = "val10D" } },
    .{ .op_id = .{ .counter = 6, .actor = 0 }, .anchor = .fromStr("key6"), .v = .{ .str = "v6" } },
    .{
        .op_id = .{ .counter = 7, .actor = 0 },
        .anchor = .fromStr("key7"),
        .v = .{ .str = "v7" },
        .succs = &.{.{ .counter = 11, .actor = 0 }},
        .incs = &.{null},
    },
    .{ .op_id = .{ .counter = 8, .actor = 0 }, .anchor = .fromStr("key8"), .v = .{ .str = "v8" } },
    .{ .op_id = .{ .counter = 9, .actor = 0 }, .anchor = .fromStr("key9"), .v = .{ .str = "v9" } },
};

test "CtrWalker and SuccWalker over a merged document" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &merged);
    defer fx.deinit();
    const cols = &fx.cols;

    // CtrWalker::new(id_ctr, r)  —  op_iter.rs:1164-1177
    const ctr_cases = [_]struct { range: RowRange, want: []const OpId }{
        .{ .range = .{ .start = 3, .end = 5 }, .want = &.{ OpId.init(3, 0), OpId.init(4, 0) } },
        .{
            .range = .{ .start = 0, .end = 4 },
            .want = &.{ OpId.init(1, 0), OpId.init(2, 0), OpId.init(3, 0) },
        },
        .{
            .range = .{ .start = 9, .end = 20 },
            .want = &.{
                OpId.init(12, 0), OpId.init(13, 0), OpId.init(10, 1),
                OpId.init(10, 3), OpId.init(9, 0),
            },
        },
    };
    for (ctr_cases) |case| {
        var walker = try CtrWalker.init(&cols.id_ctr, case.range);
        defer walker.deinit();
        var got: usize = 0;
        while (try walker.next()) |row| {
            try testing.expect(got < case.want.len);
            try testing.expectEqual(case.want[got], merged[row].id());
            got += 1;
        }
        try testing.expectEqual(case.want.len, got);
    }

    // SuccWalker::new(doc.ops(), r)  —  op_iter.rs:1179-1211
    const succ_cases = [_]struct { range: RowRange, want: []const OpId }{
        .{
            .range = .{ .start = 10, .end = 12 },
            .want = &.{ OpId.init(5, 0), OpId.init(7, 0) },
        },
        .{
            .range = .{ .start = 10, .end = 13 },
            .want = &.{ OpId.init(3, 0), OpId.init(5, 0), OpId.init(7, 0) },
        },
        .{
            .range = .{ .start = 10, .end = 99 },
            .want = &.{ OpId.init(3, 0), OpId.init(12, 0), OpId.init(5, 0), OpId.init(7, 0) },
        },
        .{
            .range = .{ .start = 0, .end = 99 },
            .want = &.{ OpId.init(3, 0), OpId.init(12, 0), OpId.init(5, 0), OpId.init(7, 0) },
        },
    };
    for (succ_cases) |case| {
        var walker = try SuccWalker(Row).init(cols, case.range);
        defer walker.deinit();
        var got: usize = 0;
        while (try walker.next()) |row| {
            try testing.expect(got < case.want.len);
            try testing.expectEqual(case.want[got], merged[row].id());
            got += 1;
        }
        try testing.expectEqual(case.want.len, got);
    }

    // An empty range is the empty walk, and costs no allocation.  op_iter.rs:210-218
    var none = try CtrWalker.init(&cols.id_ctr, .{ .start = 4, .end = 4 });
    defer none.deinit();
    try testing.expectEqual(@as(?usize, null), try none.next());
}

test "a sub-iterator can be repositioned into a child object" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &merged);
    defer fx.deinit();
    const cols = &fx.cols;
    const whole = RowRange{ .start = 0, .end = cols.len() };
    var scratch: [4]SuccEntry = undefined;

    // A walk built over the whole set, repositioned onto one object's rows.
    var objs = ObjIdIter.init(try cols.obj_actor.iterRange(whole), try cols.obj_ctr.iterRange(whole));
    const range = try objs.seekToValue(ObjId.root);
    try testing.expectEqual(RowRange{ .start = 0, .end = merged.len }, range);

    var ids = OpIdIter.init(try cols.id_actor.iterator(), try cols.id_ctr.iterator());
    const first = (try ids.shiftNext(.{ .start = 2, .end = 7 })).?;
    try testing.expectEqual(OpId.init(3, 0), first);
    try testing.expectEqual(@as(usize, 3), ids.pos());
    try testing.expectEqual(OpId.init(12, 0), (try ids.maybeTryNext()).?);
    // Repositioning forward, into a later window.
    const moved = (try ids.shiftNext(.{ .start = 12, .end = 13 })).?;
    try testing.expectEqual(OpId.init(9, 0), moved);
    try testing.expectEqual(@as(usize, 13), ids.pos());
    // And backward, which repositioning cannot serve.
    try testing.expectError(error.InvalidValue, ids.shiftNext(.{ .start = 0, .end = 1 }));

    // The same through the row-level sub-iterators, which carry the whole
    // kernel rather than only the shift.
    var keys = KeyIter.init(
        try cols.key_str.iterator(),
        try cols.key_actor.iterator(),
        try cols.key_ctr.iterator(),
        fx.strings(),
    );
    try testing.expectEqualStrings("key1", (try keys.shiftNext(.{ .start = 0, .end = 1 })).?.keyStr().?);
    try testing.expectEqual(@as(usize, 1), keys.pos());
    try testing.expectEqual(@as(usize, 1), keys.maxPos());
    keys.setMax(5);
    try testing.expectEqual(@as(usize, 5), keys.maxPos());
    try keys.advanceBy(1);
    try testing.expectEqual(@as(usize, 2), keys.pos());
    try testing.expectEqualStrings("key3", (try keys.seekTo(3)).?.keyStr().?);

    var values = ValueIter.init(try cols.value_meta.prefixIter(), cols.value.iterator());
    const v0 = (try values.shiftNext(.{ .start = 0, .end = cols.len() })).?;
    try testing.expectEqualStrings("v1", v0.str);
    try testing.expectEqual(@as(usize, 1), values.pos());
    // `advanceTo(4)` leaves the next read on row 4, and the byte cursor
    // has to be on that row's offset for the read to be the right bytes.
    try values.advanceTo(4);
    try testing.expectEqual(@as(usize, 4), values.pos());
    try testing.expectEqualStrings("val13", (try values.tryNext()).str);
    try testing.expectEqual(@as(usize, 5), values.pos());

    var succs = SuccIterIter.init(
        try cols.succ_count.prefixIter(),
        try cols.succ_actor.iterator(),
        try cols.succ_ctr.iterator(),
        try cols.index.inc.iterator(),
        0,
        &scratch,
    );
    // Row 2 owns the flattened successor 0, row 3 the one at 1.  The
    // window is [2, 4), so row 3 is still inside it after the shift.
    try testing.expectEqual(@as(usize, 1), (try succs.shiftNext(.{ .start = 2, .end = 4 })).?.len());
    try testing.expectEqual(@as(usize, 3), succs.pos());
    try testing.expectEqual(@as(usize, 1), (try succs.tryNext()).len());
    try testing.expectEqual(@as(usize, 4), succs.pos());

    assertShiftable();
}

test "a walk is repositionable into a later window" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &merged);
    defer fx.deinit();
    const cols = &fx.cols;
    var scratch: [4]SuccEntry = undefined;
    var it = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = cols.len() }, &scratch);

    // The kernel's three questions, then the two defaults built on them.
    try testing.expectEqual(@as(usize, 0), it.pos());
    try testing.expectEqual(merged.len, it.maxPos());
    it.setMax(5);
    try testing.expectEqual(@as(usize, 5), it.maxPos());
    try testing.expectEqual(@as(usize, 5), it.len());
    try testing.expectEqual(RowRange{ .start = 0, .end = 5 }, it.range());

    // A seek reads the row at the target, and leaves the walk after it.
    const at3 = (try it.seekTo(3)).?;
    try testing.expectEqual(@as(usize, 3), at3.pos);
    try testing.expectEqual(OpId.init(12, 0), at3.id());
    try testing.expectEqualStrings("val12", at3.value().str);
    try testing.expectEqual(@as(usize, 4), it.pos());
    // A target behind the walk cannot be served.
    try testing.expectEqual(@as(?Op, null), try it.seekTo(0));

    // A failed reposition preserves the original row and all cursor windows.
    try testing.expectError(error.UnexpectedEnd, it.shift(.{
        .start = cols.len() + 1,
        .end = cols.len() + 2,
    }));
    try testing.expectEqual(@as(usize, 4), it.pos());
    try testing.expectEqual(@as(usize, 5), it.maxPos());
    try testing.expectEqual(@as(usize, 4), it.id.pos());
    try testing.expectEqual(@as(usize, 4), it.obj.pos());
    try testing.expectEqual(@as(usize, 4), it.key.pos());
    try testing.expectEqual(@as(usize, 4), it.succ.pos());
    try testing.expectEqual(@as(usize, 4), it.insert.pos());
    try testing.expectEqual(@as(usize, 4), it.action.pos());
    try testing.expectEqual(@as(usize, 4), it.value.pos());
    try testing.expectEqual(@as(usize, 4), it.marks.pos());

    // A reposition followed by an ordinary read yields the requested row,
    // including its payload and successors, not the row before the window.
    try it.shift(.{ .start = 6, .end = 9 });
    const at6 = (try it.next()).?;
    try testing.expectEqual(@as(usize, 6), at6.pos);
    try testing.expectEqual(OpId.init(5, 0), at6.id());
    try testing.expectEqualStrings("v5", at6.value().str);
    try testing.expectEqual(@as(usize, 3), at6.succCount());
    var s = at6.succ();
    try testing.expectEqual(OpId.init(10, 0), s.next().?);
    try testing.expectEqual(OpId.init(10, 2), s.next().?);
    try testing.expectEqual(OpId.init(10, 3), s.next().?);
    try testing.expectEqual(@as(?OpId, null), s.next());

    // `shiftNext` is a reposition and a read, and refuses a backward one.
    const jumped = (try it.shiftNext(.{ .start = 10, .end = 11 })).?;
    try testing.expectEqual(@as(usize, 10), jumped.pos);
    try testing.expectEqual(OpId.init(7, 0), jumped.id());
    try testing.expectEqualStrings("v7", jumped.value().str);
    try testing.expectEqual(@as(usize, 1), jumped.succCount());
    try testing.expectEqual(@as(usize, 11), it.pos());
    try testing.expectError(error.InvalidValue, it.shiftNext(.{ .start = 0, .end = 1 }));

    // A truncated walk stops where it was told to, not at the column end.
    var cut = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = cols.len() }, &scratch);
    try cut.shift(.{ .start = 0, .end = 2 });
    var seen: usize = 0;
    while (try cut.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 2), seen);
    // A truncated walk is *over*, not broken: the id cursor runs out first
    // and the walk answers null, the way any other cursor's end does.
    try testing.expectEqual(@as(?Op, null), try cut.next());

    assertShiftableFor(Row);
}

test "constructing and walking an op set iterator touches no allocator" {
    const gpa = testing.allocator;
    // The columns carry the allocator they were built with and hand it back
    // through `Column.allocator`, so a cursor that allocated would go
    // through this counter. Nothing a walk does takes an allocator of its
    // own — that is the property, and it is why `OpIter.init` has no
    // `Allocator` parameter — so a count that does not move is the whole
    // of what is observable at runtime.
    var counting = Counting{ .inner = gpa };
    const watched = counting.allocator();
    var fx = try Fixture.init(watched, &merged);
    defer fx.deinit();
    const cols = &fx.cols;
    var scratch: [4]SuccEntry = undefined;
    const before = counting.count;

    var it = try OpIter(Row).init(cols, fx.strings(), .{ .start = 0, .end = cols.len() }, &scratch);
    var seen: usize = 0;
    while (try it.next()) |_| seen += 1;
    try testing.expectEqual(merged.len, seen);

    // A sub-iterator, positioned from scratch and then repositioned
    // mid-flight into a later window.
    var ids = OpIdIter.init(try cols.id_actor.iterator(), try cols.id_ctr.iterator());
    try testing.expectEqual(OpId.init(1, 0), (try ids.shiftNext(.{ .start = 0, .end = 1 })).?);
    try testing.expectEqual(OpId.init(9, 0), (try ids.shiftNext(.{ .start = 12, .end = 13 })).?);

    try testing.expectEqual(before, counting.count);
}

test "the walkers' allocations are released" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &merged);
    defer fx.deinit();
    const cols = &fx.cols;
    // `testing.allocator` reports a leak, so walking both walkers to the
    // end and deinit-ing them is the assertion.
    var ctr = try CtrWalker.init(&cols.id_ctr, .{ .start = 9, .end = 20 });
    while (try ctr.next()) |_| {}
    ctr.deinit();
    var succ = try SuccWalker(Row).init(cols, .{ .start = 10, .end = 99 });
    while (try succ.next()) |_| {}
    succ.deinit();
}

//  Six of the eight sub-iterators' `seekTo` and `shiftNext` declared a
//  return type of `! ?T` and returned a `!T`. That is not a coercion — an
//  error union does not narrow into an optional payload — so each was a
//  type error. Nothing here called them, and [`assertShiftable`] does not
//  catch them either: it builds `column.Shiftable(I)`, whose instantiation
//  resolves the *type* and leaves every method body unanalyzed. A consumer
//  that wraps a sub-iterator and forwards the kernel is what finally forced
//  the analysis, which is how the first of the six was found. This test is
//  that consumer: it calls the kernel of all eight, so every body is
//  analyzed, and it pins the contract rather than the shape — a `shiftNext`
//  onto a one-row window leaves each of the eight standing on that row,
//  with the window one row long, holding the value that row carries.
test "every sub-iterator's kernel lands a shift on the row it names" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &rich);
    defer fx.deinit();
    const cols = &fx.cols;
    const whole = RowRange{ .start = 0, .end = cols.len() };
    const one = RowRange{ .start = 2, .end = 3 };
    const strings = fx.strings();
    var scratch: [4]SuccEntry = undefined;

    var ids = OpIdIter.init(try cols.id_actor.iterRange(whole), try cols.id_ctr.iterRange(whole));
    try testing.expectEqual(rich[2].id(), (try ids.shiftNext(one)).?);
    try testing.expectEqual(@as(usize, 3), ids.pos());
    try testing.expectEqual(@as(usize, 3), ids.maxPos());

    var inserts = InsertIter.init(try cols.insert.iterRange(whole));
    try testing.expectEqual(rich[2].insert(), (try inserts.shiftNext(one)).?);
    try testing.expectEqual(@as(usize, 3), inserts.pos());
    try testing.expectEqual(@as(usize, 3), inserts.maxPos());

    var actions = ActionIter.init(try cols.action.iterRange(whole));
    try testing.expectEqual(rich[2].action(), (try actions.shiftNext(one)).?);
    try testing.expectEqual(@as(usize, 3), actions.pos());
    try testing.expectEqual(@as(usize, 3), actions.maxPos());

    var keys = KeyIter.init(
        try cols.key_str.iterRange(whole),
        try cols.key_actor.iterRange(whole),
        try cols.key_ctr.iterRange(whole),
        strings,
    );
    try testing.expect(rich[2].key().eql((try keys.shiftNext(one)).?));
    try testing.expectEqual(@as(usize, 3), keys.pos());
    try testing.expectEqual(@as(usize, 3), keys.maxPos());

    var objs = ObjIdIter.init(try cols.obj_actor.iterRange(whole), try cols.obj_ctr.iterRange(whole));
    const want_obj = ObjId{ .id = rich[2].obj().? };
    try testing.expect(want_obj.eql((try objs.shiftNext(one)).?));
    try testing.expectEqual(@as(usize, 3), objs.pos());
    try testing.expectEqual(@as(usize, 3), objs.maxPos());

    var marks = MarkInfoIter.init(
        try cols.mark_name.iterRange(whole),
        try cols.expand.iterRange(whole),
        strings,
    );
    const got_mark = (try marks.shiftNext(one)).?;
    try testing.expectEqualStrings(rich[2].markName().?, got_mark.name.?);
    try testing.expectEqual(rich[2].expand(), got_mark.expand);
    try testing.expectEqual(@as(usize, 3), marks.pos());
    try testing.expectEqual(@as(usize, 3), marks.maxPos());

    var values = ValueIter.init(
        try cols.value_meta.prefixIterRange(whole),
        try cols.value.iteratorAt(0),
    );
    try testing.expect((try values.shiftNext(one)).?.eql(rich[2].value()));
    try testing.expectEqual(@as(usize, 3), values.pos());
    try testing.expectEqual(@as(usize, 3), values.maxPos());

    var succs = SuccIterIter.init(
        try cols.succ_count.prefixIterRange(whole),
        try cols.succ_actor.iterRange(.{ .start = 0, .end = cols.succ_actor.len() }),
        try cols.succ_ctr.iterRange(.{ .start = 0, .end = cols.succ_ctr.len() }),
        try cols.index.inc.iterRange(.{ .start = 0, .end = cols.index.inc.len() }),
        0,
        &scratch,
    );
    try testing.expectEqual(rich[2].succCount(), (try succs.shiftNext(one)).?.len());
    try testing.expectEqual(@as(usize, 3), succs.pos());
    try testing.expectEqual(@as(usize, 3), succs.maxPos());
}

test "value and successor jumps preserve rebased offsets and shifted streams" {
    // Every range begins after nonzero payload and successor prefixes.
    const gpa = testing.allocator;
    const rows = [_]Row{
        .{ .op_id = OpId.init(1, 0), .v = .{ .str = "prefix" }, .succs = &.{OpId.init(10, 0)}, .incs = &.{null} },
        .{ .op_id = OpId.init(2, 0), .v = .null_value },
        .{ .op_id = OpId.init(3, 0), .v = .{ .str = "two" }, .succs = &.{ OpId.init(11, 0), OpId.init(12, 0) }, .incs = &.{ null, 4 } },
        .{ .op_id = OpId.init(4, 0), .v = .{ .int = -129 } },
        .{ .op_id = OpId.init(5, 0), .v = .{ .str = "tail" }, .succs = &.{OpId.init(13, 0)}, .incs = &.{null} },
    };
    var fx = try Fixture.init(gpa, &rows);
    defer fx.deinit();
    const cols = &fx.cols;
    const range = RowRange{ .start = 1, .end = rows.len };
    var values = ValueIter.init(
        try rangedPrefix(&cols.value_meta, range),
        try cols.value.iteratorAt(try prefixAt(&cols.value_meta, range.start)),
    );
    try testing.expect(rows[2].v.eql(try values.tryNth(1)));
    try testing.expect(rows[3].v.eql(try values.tryNext()));
    try testing.expect(rows[4].v.eql((try values.shiftNext(.{ .start = 4, .end = 5 })).?));
    try testing.expectError(error.MissingValue, values.tryNext());

    var shifted = ValueIter.init(try cols.value_meta.prefixIter(), cols.value.iterator());
    try shifted.shift(.{ .start = 2, .end = 4 });
    try testing.expect(rows[2].v.eql(try shifted.tryNext()));
    try testing.expect(rows[3].v.eql(try shifted.tryNext()));
    try testing.expectError(error.MissingValue, shifted.tryNext());
    var pair = ActionValueIter.init(
        ActionIter.init(try cols.action.iterator()),
        ValueIter.init(try cols.value_meta.prefixIter(), cols.value.iterator()),
    );
    try pair.shift(.{ .start = 2, .end = 4 });
    try testing.expect(rows[2].v.eql((try pair.tryNext()).value));
    try testing.expect(rows[3].v.eql((try pair.tryNext()).value));

    var scratch: [2]SuccEntry = undefined;
    const flat = try prefixAt(&cols.succ_count, range.start);
    var succs = SuccIterIter.init(
        try rangedPrefix(&cols.succ_count, range),
        try cols.succ_actor.iterRange(.{ .start = flat, .end = cols.succ_actor.len() }),
        try cols.succ_ctr.iterRange(.{ .start = flat, .end = cols.succ_ctr.len() }),
        try cols.index.inc.iterRange(.{ .start = flat, .end = cols.index.inc.len() }),
        flat,
        &scratch,
    );
    var got = try succs.tryNth(1);
    try testing.expectEqual(@as(usize, 1), got.pos());
    try testing.expectEqual(@as(usize, 2), got.len());
    try testing.expectEqual(OpId.init(11, 0), got.next().?);
    try testing.expectEqual(OpId.init(12, 0), got.next().?);
    try testing.expectEqual(@as(usize, 0), (try succs.tryNext()).len());
    const tail = (try succs.shiftNext(.{ .start = 4, .end = 5 })).?;
    try testing.expectEqual(@as(usize, 3), tail.pos());
    try testing.expectEqual(@as(usize, 1), tail.len());
    try testing.expectError(error.MissingValue, succs.tryNext());
}

test "rebased value and successor reads agree across bounded slabs" {
    const gpa = testing.allocator;
    var rows: [48]Row = undefined;
    var words: [rows.len]u64 = undefined;
    var counts: [rows.len]u32 = undefined;
    const successors = [_]OpId{ OpId.init(100, 0), OpId.init(101, 0) };
    const increments = [_]?i64{ null, 7 };
    for (&rows, &words, &counts, 0..) |*r, *word, *count, i| {
        const value: ScalarValue = switch (i % 4) {
            0 => .null_value,
            1 => .{ .str = "a" },
            2 => .{ .str = "three" },
            3 => .{ .int = -129 },
            else => unreachable,
        };
        const n = i % 3;
        r.* = .{
            .op_id = OpId.init(@intCast(i + 1), 0),
            .v = value,
            .succs = successors[0..n],
            .incs = increments[0..n],
        };
        word.* = optypes.metaOf(value).raw;
        count.* = @intCast(n);
    }
    var fx = try Fixture.init(gpa, &rows);
    defer fx.deinit();
    const meta = blk: {
        var prepared = try opcols.MetaColumn.initWithBudget(gpa, 2);
        errdefer prepared.deinit();
        try prepared.extend(gpa, &words);
        break :blk prepared;
    };
    fx.cols.value_meta.deinit();
    fx.cols.value_meta = meta;
    const count_col = blk: {
        var prepared = try opcols.CountColumn.initWithBudget(gpa, 2);
        errdefer prepared.deinit();
        try prepared.extend(gpa, &counts);
        break :blk prepared;
    };
    fx.cols.succ_count.deinit();
    fx.cols.succ_count = count_col;
    const range = RowRange{ .start = 5, .end = rows.len };
    var values = ValueIter.init(
        try rangedPrefix(&fx.cols.value_meta, range),
        try fx.cols.value.iteratorAt(try prefixAt(&fx.cols.value_meta, range.start)),
    );
    var positional = values;
    for (range.start..range.end) |i| {
        try testing.expect(rows[i].v.eql(try values.tryNext()));
        try testing.expect(rows[i].v.eql((try positional.shiftNext(.{
            .start = i,
            .end = range.end,
        })).?));
    }
    try testing.expectError(error.MissingValue, values.tryNext());
    var jumped = ValueIter.init(
        try rangedPrefix(&fx.cols.value_meta, range),
        try fx.cols.value.iteratorAt(try prefixAt(&fx.cols.value_meta, range.start)),
    );
    try testing.expect(rows[range.start].v.eql(try jumped.tryNext()));
    jumped.meta.resetPrefix();
    try testing.expect(rows[37].v.eql(try jumped.tryNth(37 - range.start - 1)));
    try testing.expect(rows[38].v.eql(try jumped.tryNext()));

    var scratch: [2]SuccEntry = undefined;
    const flat = try prefixAt(&fx.cols.succ_count, range.start);
    var succs = SuccIterIter.init(
        try rangedPrefix(&fx.cols.succ_count, range),
        try fx.cols.succ_actor.iterRange(.{ .start = flat, .end = fx.cols.succ_actor.len() }),
        try fx.cols.succ_ctr.iterRange(.{ .start = flat, .end = fx.cols.succ_ctr.len() }),
        try fx.cols.index.inc.iterRange(.{ .start = flat, .end = fx.cols.index.inc.len() }),
        flat,
        &scratch,
    );
    var got = try succs.tryNth(37 - range.start);
    try testing.expectEqual(try prefixAt(&fx.cols.succ_count, 37), got.pos());
    try testing.expectEqual(@as(usize, counts[37]), got.len());
    for (successors[0..counts[37]]) |id| try testing.expectEqual(id, got.next().?);
    succs.count.resetPrefix();
    try succs.shift(.{ .start = 40, .end = rows.len });
    var shifted = try succs.tryNext();
    try testing.expectEqual(try prefixAt(&fx.cols.succ_count, 40), shifted.pos());
    try testing.expectEqual(@as(usize, counts[40]), shifted.len());
    for (successors[0..counts[40]]) |id| try testing.expectEqual(id, shifted.next().?);
}

test "value jumps retain raw bounds and failed shifts retain the unread row" {
    const gpa = testing.allocator;
    var raw = try rawcol.RawColumn.init(gpa);
    defer raw.deinit();
    try raw.spliceSlice(0, 0, "abc");
    var meta = try opcols.MetaColumn.init(gpa);
    defer meta.deinit();
    try meta.extend(gpa, &.{
        optypes.metaOf(.{ .str = "abc" }).raw,
        optypes.metaOf(.{ .str = "def" }).raw,
        optypes.metaOf(.{ .str = "g" }).raw,
    });
    var jumped = ValueIter.init(try meta.prefixIter(), raw.iterator());
    try testing.expectError(error.InvalidValue, jumped.tryNth(1));
    var positional = ValueIter.init(try meta.prefixIter(), raw.iterator());
    try testing.expectError(error.InvalidValue, positional.shiftNext(.{ .start = 1, .end = 3 }));
    var shifted = ValueIter.init(try meta.prefixIter(), raw.iterator());
    try testing.expectError(error.InvalidValue, shifted.shift(.{ .start = 2, .end = 3 }));
    try testing.expectEqual(@as(usize, 0), shifted.pos());
    try testing.expectEqualStrings("abc", (try shifted.tryNext()).str);
    try testing.expectError(error.InvalidValue, shifted.tryNext());
}

test "successor positional and nth reads reject short flattened columns" {
    const gpa = testing.allocator;
    var count = try opcols.CountColumn.init(gpa);
    defer count.deinit();
    try count.extend(gpa, &.{ 1, 2 });
    var actor = try opcols.ActorColumn.init(gpa);
    defer actor.deinit();
    try actor.extend(gpa, &.{0});
    var ctr = try opcols.CounterColumn.init(gpa);
    defer ctr.deinit();
    try ctr.extend(gpa, &.{10});
    var inc = try opcols.IncColumn.init(gpa);
    defer inc.deinit();
    try inc.extend(gpa, &.{null});
    var scratch: [2]SuccEntry = undefined;
    var jumped = SuccIterIter.init(
        try count.prefixIter(),
        try actor.iterator(),
        try ctr.iterator(),
        try inc.iterator(),
        0,
        &scratch,
    );
    var positional = jumped;
    try testing.expectError(error.InvalidValue, jumped.tryNth(1));
    try testing.expectError(error.InvalidValue, positional.shiftNext(.{ .start = 1, .end = 2 }));
    var shifted = SuccIterIter.init(
        try count.prefixIter(),
        try actor.iterator(),
        try ctr.iterator(),
        try inc.iterator(),
        0,
        &scratch,
    );
    try shifted.shift(.{ .start = 1, .end = 2 });
    try testing.expectError(error.InvalidValue, shifted.tryNext());
}
