//! The map range reader: one row per key of a map object, carrying the key,
//! the value a reader sees and whether the register is conflicted
//! (`rust/automerge/src/iter/map_range.rs`, 328 lines).
//!
//! This is where a document's **visible map** comes from. `iter/list_range.rs`
//! is the same reader over a sequence's elements and `iter/spans.rs` is the
//! same reader over a text object's spans; all three sit on
//! [`OpSet`](../../opset/op_set.zig)'s range layer and add nothing to it.
//!
//! # The three layers, and which is which
//!
//! | layer | upstream | port |
//! |---|---|---|
//! | the rows | [`MapIter`] over four column cursors | [`MapIter`] |
//! | what happened to them | [`MapDiff`] over the diff kernel | [`MapDiff`] |
//! | what a caller sees | [`MapRange`] | [`MapRange`] |
//!
//! [`MapRange`] is two lines because everything a caller wants is already
//! decided by the two below it: `MapDiff` has resolved the clock, the
//! register, the counter increments and the conflict flag, and all `MapRange`
//! does is turn the row's op id into an [`ExId`]
//! (`map_range.rs:99-103`). Splitting them is not decoration — [`MapDiff`] is
//! what a *patch* run reads (a diff between two states) and [`MapRange`] is
//! what a *read* hands a caller, and upstream keeps the two names for exactly
//! that reason (`iter.rs:19`).
//!
//! # Constructing a reader allocates nothing
//!
//! Every cursor is a pointer and a few numbers, [`tools.Unshift`]'s lookahead
//! is a field beside the cursor it was drawn from, and the one buffer a walk
//! needs — the successor buffer the op set keeps for its scans — is the op
//! set's. There is no allocator in [`MapRange.init`], and the test
//! "a map range reader allocates nothing to construct" says so with a
//! counting allocator rather than asserting it.
//!
//! # `shift` moves the window; `shiftNext` moves and reads
//!
//! [`MapRange.shiftNext`] is upstream's `shift_next`
//! (`map_range.rs:210-212`): it repositions the walk **and** returns the first
//! row of the new range, which is why it exists as one call. The port's kernel
//! splits those ([`tools`](tools.zig)'s module doc, "shift moves the window;
//! shiftNext also reads"), so this file calls
//! [`tools.Unshift.shift`](tools.zig#L367) — the port's spelling of upstream's
//! `Unshift::shift_next` — and then reads. A range that starts behind the
//! cursor is `error.InvalidValue`; a range past the end answers `null`.
//!
//! # The width is not here
//!
//! A map key holds one value, so this reader has no width to report. The
//! width of a *sequence* element is [`ListRangeItem.width`](../iter/list_range.zig),
//! and it is read from the register's **last** row, which is the one thing in
//! this phase that is easy to get wrong
//! ([`op_set.rs:748-752`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
//!
//! # `ExIdPromise` and `OpSetOrExId` are here
//!
//! Upstream declares them in `iter/tools.rs:187-244` and they are live:
//! `map_range.rs:19,56` and `list_range.rs:19,207` both use them.
//! [`iter/tools.zig`](tools.zig)'s module doc names this file as their home
//! because they are `OpSet`-typed and the toolkit is not. **They are ported
//! once, here, and `iter/list_range.rs` imports them from this file** rather
//! than declaring a second copy.
//!
//! A promise rather than an `ExId` because building an `ExId` from an op id
//! costs a walk of the actor table (`OpSet::id_to_exid`,
//! [`op_set.rs:2045-2049`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
//! and most rows are never asked for their id. The promise carries the `OpId`
//! and the op set, and resolves on [`ExIdPromise.exid`].
//!
//! # What is not here
//!
//! [`MapDiffItem.log`] (`map_range.rs:70-89`) is upstream's translation of a
//! diff row into a [`PatchLog`](../../patches.zig) event. It is not ported
//! here: [src/patches.zig](../../patches.zig) has landed and emits those
//! events from its own items, and a second `log` would be a second source of
//! truth for the same patch stream. The document's `mapRangeFor` — the name
//! [src/patches.zig](../../patches.zig)'s [`doc_decls`](../../patches.zig#L212)
//! asks for — is the adapter that hands these rows to it.

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
const tools = @import("tools.zig");

const Allocator = std.mem.Allocator;
const Error = err.Error;
const InternalError = err.InternalError;
const ParseError = err.ParseError;
const ReadOpError = opiter.ReadOpError;

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
/// What happened to a row, re-exported so a consumer of this file does not
/// have to import [`tools`](tools.zig) to name it
/// ([`Diff`](tools.zig), `iter/tools.rs:610-616`).
const Diff = tools.Diff;

/// What a range reader over the op set can raise.
///
/// **The union of four sets, none of which is a subset of another.** The
/// column cursors are [`ParseError`](../../src/error.zig) (a column that ran
/// out, a cast that would lose bits), the visible and top walks are
/// [`ReadOpError`](../../opset/op_iter.zig) (a row whose halves do not make an
/// id) plus the document [`Error`](../../src/error.zig) and
/// [`InternalError`](../../src/error.zig) (the top walk's `error.Invariant`,
/// which upstream is a `checked_sub` that cannot answer), and a counter's
/// value is read through [`OpSet.getIncrementDiffAtPos`], which is
/// `Error || ParseError` — a set that is in neither walk's set.
pub const ReadError = ParseError || ReadOpError || Error || InternalError;

// ── The promise ─────────────────────────────────────────────────────────────

/// Either the op set a row's id is to be resolved against, or the answer
/// already resolved ([`OpSetOrExId`], `iter/tools.rs:196-201`).
///
/// Upstream's second variant exists so [`ExIdPromise.intoOwned`] has something
/// to keep when the op set is gone; the port's is the same, and `ExId` is a
/// value here as it is there, so no allocation is involved on either path.
pub fn OpSetOrExId(comptime O: type) type {
    return union(enum) {
        /// The op set the id has not been resolved against yet.
        set: *opset.OpSet(O),
        /// The resolved id, for a promise that outlived its op set.
        exid: ExId,
    };
}

/// A row's op id, and the op set that turns it into an [`ExId`]
/// ([`ExIdPromise`], `iter/tools.rs:187-194`).
///
/// **Two ids, and the reason for the second is a walk.** `OpId` is a counter
/// and an actor *index*; `ExId` is a counter and the actor's *bytes*
/// ([`types.zig`](../../src/types.zig)). Getting from one to the other reads
/// the actor table, so a reader that built the `ExId` for every row would walk
/// the table once per row. The promise holds the cheap half and resolves on
/// demand ([`ExIdPromise.exid`], `iter/tools.rs:229-234`).
///
/// Equality compares the [`OpId`] and nothing else
/// (`PartialEq for ExIdPromise`, `iter/tools.rs:195-199`): two promises over
/// two different op sets describe the same row exactly when their ids agree,
/// because the actor table is a property of the document and two op sets that
/// disagree about it cannot both be that document.
pub fn ExIdPromise(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The row's own id (`iter/tools.rs:189`).
        id: OpId,
        /// Where the [`ExId`] comes from, until it is asked for
        /// (`iter/tools.rs:190`).
        promise: OpSetOrExId(O),

        /// A promise over `set` for the row at `id`
        /// ([`ExIdPromise::new`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:225-231`).
        pub fn init(set: *opset.OpSet(O), id: OpId) Self {
            return .{ .id = id, .promise = .{ .set = set } };
        }

        /// The row's id in the document's own actor naming
        /// ([`ExIdPromise::exid`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:229-234`).
        pub fn exid(self: Self) ExId {
            return switch (self.promise) {
                .set => |set| set.idToExid(self.id),
                .exid => |e| e,
            };
        }

        /// The promise with the id resolved and the op set dropped
        /// ([`ExIdPromise::into_owned`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:236-241`).
        pub fn intoOwned(self: Self) Self {
            return .{
                .id = self.id,
                .promise = .{ .exid = switch (self.promise) {
                    .set => |set| set.idToExid(self.id),
                    .exid => |e| e,
                } },
            };
        }

        /// Whether two promises name the same row, by op id
        /// (`iter/tools.rs:195-199`).
        pub fn eql(a: Self, b: Self) bool {
            return a.id.eql(b.id);
        }
    };
}

/// Whether `id` is in the *before* state of `over`
/// ([`ClockRange::predates`],
/// [`clock.rs:111-115`](../../github-automerge-automerge/rust/automerge/src/clock.rs)).
///
/// **`Current` is false for both of its cases**, and that is the whole rule: a
/// read at the present has no "before", and a read scoped to a *single* past
/// state has no second state to be before either. Only a `Diff` has one.
///
/// The port's [`ClockRange`](../../src/clock.zig) does not carry upstream's
/// three predicates, so this is that code. It lives here because all three
/// readers in this phase ask it — `map_range.rs:252`, `list_range.rs:138`,
/// `spans.rs:191` — and `list_range.zig` imports it from here.
pub fn predates(over: ClockRange, id: OpId) bool {
    return switch (over) {
        .diff => |d| d.before.contains(id),
        .current => false,
    };
}

// ── What a caller sees ──────────────────────────────────────────────────────

/// One key of a map, as a reader sees it ([`MapRangeItem`],
/// [`map_range.rs:13-20`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)).
///
/// **The key is borrowed from the document's string table** and is valid until
/// the next mutation of it. [`MapRangeItem.intoOwned`] is the copy for a
/// caller that has to hold one across a mutation.
pub fn MapRangeItem(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The key the register hangs by (`map_range.rs:15`).
        key: []const u8,
        /// The value a reader sees: a scalar, or a reference to an object
        /// (`map_range.rs:16`).
        value: ValueRef,
        /// Whether the register holds more than one visible value
        /// (`map_range.rs:17`).
        conflict: bool,
        /// The row the winner was read from, absolute in the op set
        /// (`map_range.rs:18`).
        pos: usize,
        /// The row's id, and the op set that will turn it into an [`ExId`]
        /// (`map_range.rs:19`).
        maybe_exid: ExIdPromise(O),

        /// The row's op id, without resolving it
        /// ([`MapRangeItem::op_id`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:22-24`).
        pub fn opId(self: *const Self) OpId {
            return self.maybe_exid.id;
        }

        /// The row's [`ExId`] ([`MapRangeItem::id`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:26-28`).
        pub fn id(self: *const Self) ExId {
            return self.maybe_exid.exid();
        }

        /// A copy that owns its key and its value
        /// ([`MapRangeItem::into_owned`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:30-39`).
        pub fn intoOwned(self: Self, gpa: Allocator) !OwnedMapRangeItem {
            const key = try gpa.dupe(u8, self.key);
            errdefer gpa.free(key);
            return .{
                .key = key,
                .value = try self.value.intoOwned(gpa),
                .conflict = self.conflict,
                .pos = self.pos,
                .id = self.maybe_exid.intoOwned().exid(),
            };
        }
    };
}

/// A [`MapRangeItem`] that owns its key and its value
/// ([`MapRangeItem<'static>`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:30`).
///
/// Upstream's `Cow` and `ValueRef::into_owned` free themselves when the
/// `'static` item is dropped; a borrowed slice cannot be dropped, so the copy
/// and the free travel together here, as they do for
/// [`ChangeMetadata.intoOwned`](../../src/change.zig).
pub const OwnedMapRangeItem = struct {
    /// The key, owned.
    key: []u8,
    /// The value, owned.
    value: OwnedValueRef,
    /// Whether the register holds more than one visible value.
    conflict: bool,
    /// The row the winner was read from.
    pos: usize,
    /// The row's id, already resolved.
    id: ExId,

    /// Gives back every byte [`MapRangeItem.intoOwned`] allocated, and nothing
    /// this item borrowed.
    pub fn deinit(self: *OwnedMapRangeItem, gpa: Allocator) void {
        gpa.free(self.key);
        self.value.deinit(gpa);
        self.* = undefined;
    }
};

// ── The rows ────────────────────────────────────────────────────────────────

/// One row of a map object's range, read out of four column cursors held in
/// step ([`MapEntry`], [`map_range.rs:132-139`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)).
///
/// **Not generic over the op set's row type**, and it needs no generic
/// parameter: upstream's `MapEntry<'a>` is generic over a borrow, and the four
/// cursors it is read out of are all `OpSet`-independent. The one type here
/// that does need the row type is [`ExIdPromise`], because it holds the op
/// set.
pub const MapEntry = struct {
    const Self = @This();

    /// The row's own id.
    id: OpId,
    /// The row's position, absolute in the op set.
    pos: usize,
    /// The key the row hangs by, resolved out of the string table.
    key: []const u8,
    /// What the row does.
    action: Action,
    /// The value it puts.
    value: ScalarValue,

    /// One row, from the four columns (`map_range.rs:135-138`).
    pub fn init(
        id: OpId,
        pos: usize,
        key: []const u8,
        action: Action,
        value: ScalarValue,
    ) Self {
        return .{ .id = id, .pos = pos, .key = key, .action = action, .value = value };
    }
};

/// A map row turned into a diff item
/// ([`MapEntry::diff_item`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:141-167`).
///
/// **A function and not a method**, because the diff item is generic over the
/// op set's row type — it carries an [`ExIdPromise`] — and [`MapEntry`] is
/// not: upstream's `MapEntry<'a>` is generic over a borrow, and the four
/// cursors it is read out of are all `OpSet`-independent. Threading the row
/// type through a type that does not otherwise need it would say the row
/// depends on the op set when it does not.
///
/// **`expose` promotes a `Same` to an `Add` here**, once, so every caller gets
/// the same promotion instead of each repeating it: a row that exposes a value
/// the before state did not have is not `Same` in the after state, whatever
/// the row itself did (`map_range.rs:147-149`).
fn mapEntryDiffItem(
    comptime O: type,
    entry: MapEntry,
    value: ValueRef,
    inc: i64,
    diff_in: Diff,
    conflict: bool,
    expose: bool,
) MapDiffItem(O) {
    const diff: Diff = if (expose and diff_in == .same) .add else diff_in;
    return .{
        .diff = diff,
        .key = entry.key,
        .value = value,
        .inc = inc,
        .conflict = conflict,
        .expose = expose,
        .pos = entry.pos,
        .id = entry.id,
    };
}

/// A walk of a map object's rows, one entry per row ([`MapIter`],
/// [`map_range.rs:107-201`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)).
///
/// **It has no step of its own, and that is the port's spelling.** Upstream
/// spells it `Iterator::next` and `Iterator::nth`; the port gives
/// [`tools.SkipIter`] and [`tools.DiffKernel`] one walk, and
/// [`tools.takeAt`](tools.zig#L232) reaches for the positional entry point
/// first. This walk has [`shiftNext`] and so it is read through that — the
/// same dispatch [`OpSet.actionValueIter`] makes over
/// [`opiter.ActionValueIter`], which likewise has no `next`. A row walk with
/// no `next` also cannot be handed to [`tools.Unshift`], which is why
/// [`MapDiff`] wraps the diff kernel and not this.
///
/// The four cursors are moved in lockstep and every method that moves one
/// moves all four, so `pos` is a position and not a guess.
pub const MapIter = struct {
    const Self = @This();

    /// `id_actor` and `id_ctr`, as one id ([`OpIdIter`], `op_set.rs:1285-1290`).
    id: opiter.OpIdIter,
    /// `key_str`, the interned map key ([`key_str_iter_range`], `op_set.rs:1298-1300`).
    ///
    /// **Interned, so a [`StringTable`] rides along.** Upstream's column is
    /// an `Option<String>` (`map_range.rs:109`) and the port's is a `?u32`
    /// (an interned id), so the table that turns the id back into bytes is a
    /// fourth thing this walk holds — the same reason
    /// [`opiter.KeyIter`] carries one
    /// ([`op_iter.zig:401-414`](../../opset/op_iter.zig)).
    key_str: opcols.UintOptColumn.Iterator,
    /// `action` ([`action_iter_range`], `op_set.rs:898-900`).
    action: opiter.ActionIter,
    /// `value_meta` over `value` ([`value_iter_range`], `op_set.rs:1292-1297`).
    value: opiter.ValueIter,
    /// The document's string table, resolving `key_str`.
    strings: StringTable,

    /// The [`Shiftable`] conformance mark. Naming it instantiates the
    /// comptime check over all eight kernel methods
    /// ([`column.zig:4006-4026`](../hexane/column.zig)), which *is* the
    /// check that this walk can be repositioned.
    pub const shiftable = column.Shiftable(Self);

    /// The four cursors ([`MapDiff::new`], `map_range.rs:300-311`).
    pub fn init(
        id: opiter.OpIdIter,
        key_str: opcols.UintOptColumn.Iterator,
        action: opiter.ActionIter,
        value: opiter.ValueIter,
        strings: StringTable,
    ) Self {
        return .{ .id = id, .key_str = key_str, .action = action, .value = value, .strings = strings };
    }

    // ── The kernel ─────────────────────────────────────────────────────
    //
    // Eight forwarders, as [`tools.SkipIter`] and [`tools.DiffKernel`] also
    // carry. Upstream implements `Shiftable::shift_next` and
    // `Iterator::next`/`nth` (`map_range.rs:115-130`, `:169-201`); the
    // port's kernel is the eight names of `shift.rs:19-74`, and the position
    // methods are what [`tools.takeAt`](tools.zig#L232) measures a skip from.

    /// The row the walk is on ([`pos`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:20-22`).
    pub fn pos(self: *const Self) usize {
        return self.id.pos();
    }

    /// One past the last row this walk can reach (`shift.rs:23-25`).
    pub fn maxPos(self: *const Self) usize {
        return self.id.maxPos();
    }

    /// Truncates the window at `at`, on all four cursors (`shift.rs:26-27`).
    pub fn setMax(self: *Self, at: usize) void {
        self.id.setMax(at);
        self.key_str.setMax(at);
        self.action.setMax(at);
        self.value.setMax(at);
    }

    /// Advances so the next read is the row at `target` (`shift.rs:34-40`).
    pub fn advanceTo(self: *Self, target: usize) ReadError!void {
        try self.id.advanceTo(target);
        try self.key_str.advanceTo(target);
        try self.action.advanceTo(target);
        try self.value.advanceTo(target);
    }

    /// Advances past `amount` rows (`shift.rs:42-47`).
    pub fn advanceBy(self: *Self, amount: usize) ReadError!void {
        return self.advanceTo(self.pos() +| amount);
    }

    /// Moves the **window** to `rows` and nothing else
    /// ([`Column.Iterator.shift`](../hexane/column.zig), `column.rs:538-545`).
    pub fn shift(self: *Self, rows: RowRange) void {
        self.id.shift(rows);
        self.key_str.shift(rows);
        self.action.shift(rows);
        self.value.shift(rows);
    }

    /// Repositions onto `rows` and reads the row at its start
    /// ([`impl Shiftable for MapIter`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:115-130`).
    ///
    /// **All four cursors move before any of them is read**, because a column
    /// that ended early must leave the other three where they were, and a
    /// caller that repositions again must not find a half-moved walk.
    /// Upstream does the same and unwraps afterwards (`map_range.rs:117-128`).
    ///
    /// The position is read *after* the null checks, which is the one place
    /// the port departs from upstream: `map_range.rs:127` computes
    /// `self.id.pos() - 1` before the `?`s, and a column that ended early can
    /// leave `pos` at zero, where the subtraction traps. Here a short column
    /// answers `null` and never reaches the subtraction.
    pub fn shiftNext(self: *Self, rows: RowRange) ReadError!?MapEntry {
        const id = try self.id.shiftNext(rows);
        const key = try self.key_str.shiftNext(rows);
        const action = try self.action.shiftNext(rows);
        const value = try self.value.shiftNext(rows);
        if (id == null or key == null or action == null or value == null) return null;
        // `key??`: the outer `?` is "the walk is over", the inner one is "this
        // row has no key string", and upstream's `??` refuses both
        // (`map_range.rs:120`). A row with no key string is not a map row.
        const key_id = key.? orelse return null;
        return MapEntry.init(
            id.?,
            self.id.pos() - 1,
            self.strings.resolve(self.strings.ctx, key_id),
            action.?,
            value.?,
        );
    }

    /// Consumes through `at` and reads the row there, or null past the end of
    /// the window ([`seek_to`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:65-74`).
    pub fn seekTo(self: *Self, at: usize) ReadError!?MapEntry {
        if (at < self.pos()) return null;
        return self.shiftNext(.{ .start = at, .end = self.maxPos() });
    }
};

comptime {
    // **The [`Shiftable`] mark on [`MapIter`] is honest, and non-null.**
    // [`column.Shiftable`](../hexane/column.zig) is a comptime check over the
    // eight kernel names (`column.zig:4006-4018`) and *naming the value
    // instantiates it*, so a walk missing one of the eight would not compile.
    //
    // **It is a value and not `tools.SkipIter`'s `?type`
    // ([`tools.zig:666`](tools.zig)) because [`MapIter`] is unconditionally
    // shiftable.** A `?type` exists for a walk that *may* not carry the
    // kernel — a filter with no positional entry point — and this is not one.
    // Claiming a nullable mark here would say "sometimes", which is not true,
    // and would let a caller that checked it be told nothing.
    //
    // **The mark does not claim a `next`, and does not need one — and this is
    // the answer to "is it a full `Shiftable` if it has no `next`?"** The
    // kernel is upstream's eight names (`shift.rs:19-74`) and `next` is not
    // among them. [`tools.takeAt`](tools.zig#L232) falls through to
    // `shiftNext` for a walk with no partial step (`tools.zig:232-246`),
    // which is the same dispatch [`OpSet.actionValueIter`] already makes over
    // [`opiter.ActionValueIter`] — a walk with a total step and a positional
    // entry point, and no `next` either. Nothing that assumes a full kernel
    // breaks, because a full kernel is the eight names and this has all eight.
    _ = MapIter.shiftable;
}

// ── What happened to the rows ───────────────────────────────────────────────

/// One row of a map range, with what happened to it between two states
/// ([`MapDiffItem`], [`map_range.rs:42-52`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)).
///
/// This is the row a *patch* is built from; [`MapRangeItem`] is what a *read*
/// hands back. Every field is upstream's, in upstream's order.
pub fn MapDiffItem(comptime O: type) type {
    return struct {
        const Self = @This();

        /// What happened to the row between the two states (`map_range.rs:44`).
        diff: Diff,
        /// The key the row hangs by, borrowed (`map_range.rs:45`).
        key: []const u8,
        /// The value as the *after* state sees it: a counter already carries
        /// every increment the range adds (`map_range.rs:46`).
        value: ValueRef,
        /// The net counter change over the range, or zero for a non-counter
        /// (`map_range.rs:47`).
        inc: i64,
        /// Whether the register is conflicted *after* this row
        /// (`map_range.rs:48`).
        conflict: bool,
        /// Whether this row newly exposes a value that was shadowed
        /// (`map_range.rs:49`).
        expose: bool,
        /// The row's position, absolute (`map_range.rs:50`).
        pos: usize,
        /// The row's own id (`map_range.rs:51`).
        id: OpId,

        /// The row as a reader's item
        /// ([`MapDiffItem::export`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:54-63`).
        ///
        /// Named `exportItem` and not `export` because `export` is a Zig
        /// keyword — the same rename
        /// [`batch.MarkDiff.exportSet`](../opset/batch.zig) carries, for the
        /// same reason.
        pub fn exportItem(self: Self, set: *opset.OpSet(O)) MapRangeItem(O) {
            return .{
                .key = self.key,
                .value = self.value,
                .conflict = self.conflict,
                .pos = self.pos,
                .maybe_exid = ExIdPromise(O).init(set, self.id),
            };
        }

        /// Records that this row exposes something, and promotes a `Same` to an
        /// `Add` when it does ([`MapDiffItem::update`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:64-68`).
        pub fn update(self: *Self, expose: bool) void {
            self.expose = self.expose or expose;
            if (self.expose and self.diff == .same) self.diff = .add;
        }
    };
}

/// A map object's rows tagged with what happened to each of them
/// ([`MapDiff`], [`map_range.rs:215-298`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)).
///
/// **One key is one [`MapDiffItem`], and the grouping happens in the
/// lookahead.** The diff kernel yields every visible row; a key's rows are
/// contiguous (rule **R3**, `op.rs:1056-1057`), so `peek` at the next row
/// decides whether this row ends its key or not (`map_range.rs:262-269`). The
/// lookahead is [`tools.Unshift`], so the `peek` costs no read and holds no
/// borrow across the fallible `next` — the reason the two wrapper types in
/// [`tools`](tools.zig) both exist.
///
/// The two counters are the whole of the conflict rule: `num_new` is how many
/// rows of this key are visible in the *after* state and `num_old` how many in
/// the *before* state, and a key is conflicted when the after state has more
/// than one winner and this row is not a survivor of a conflict that was
/// already there (`map_range.rs:259-260`).
pub fn MapDiff(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The op set the rows are read from, and the one an exported id is
        /// resolved against.
        ///
        /// **Not optional, and that is a departure from upstream.** Upstream's
        /// is `Option<&OpSet>` and an empty reader is its `Default`
        /// (`map_range.rs:215-220`), which `automerge.rs:1686-1698` reaches for
        /// when an object id names nothing. The port has no such case to
        /// spell: a caller that has no object scopes to an **empty row range**
        /// and builds the same reader, which answers nothing for the same
        /// reason and needs no second shape.
        op_set: *opset.OpSet(O),
        /// The lookahead over the diff, so the next row can be asked about
        /// without reading it (`map_range.rs:218`).
        iter: tools.Unshift(DiffWalk(O)),
        /// Which two states, or which one, the diff is between (`map_range.rs:219`).
        clock: ClockRange,

        /// The walk this instantiation is
        /// ([`MapDiff::new`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:300-328`).
        pub const Walk = DiffWalk(O);
        /// The rows the walk reads, one per visible row.
        pub const Rows = MapIter;

        /// The diff over `rows`, between the states `over` names
        /// ([`MapDiff::new`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:301-327`).
        ///
        /// **The window is clamped once, here**, because four of the five
        /// accessors below do not clamp and one (`VisIter`) does
        /// ([`visible.zig:408-419`](../../opset/visible.zig)); clamping here
        /// means every one of them sees the same window, and a caller that has
        /// clamped already pays for it once.
        pub fn init(set: *opset.OpSet(O), rows: RowRange, over: ClockRange) ReadError!Self {
            const window = column.clampRange(rows, set.len());
            const walk = DiffWalk(O).init(
                MapIter.init(
                    try set.idIterRange(window),
                    try set.keyStrIterRange(window),
                    try set.actionIterRange(window),
                    try set.valueIterRange(window),
                    set.strings,
                ),
                try VisibleDiffSkipper(O).init(set, over, window),
            );
            return .{
                .op_set = set,
                .iter = try tools.Unshift(Walk).init(walk),
                .clock = over,
            };
        }

        /// Repositions the walk onto `rows` and reads the first changed row in
        /// it ([`MapDiff::shift_next`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:323-326`).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadError!?MapDiffItem(O) {
            try self.iter.shift(rows);
            return self.next();
        }

        /// The next key of the object, with what happened to it
        /// ([`Iterator::next` for `MapDiff`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:222-297`).
        pub fn next(self: *Self) ReadError!?MapDiffItem(O) {
            const set = self.op_set;
            var last_is_same = false;
            var num_new: usize = 0;
            var num_old: usize = 0;
            var expose: bool = false;
            var last_visible: ?MapDiffItem(O) = null;

            while (try self.iter.next()) |entry| {
                const diff = entry.diff;
                const map = entry.item;
                switch (diff) {
                    // `map_range.rs:226-228`. A `Del` exposes whatever came
                    // before it, and only if the row before was a `Same` — a
                    // deletion after an addition exposes nothing, because
                    // nothing was there to hide.
                    .del => {
                        expose = last_is_same;
                        num_old += 1;
                    },
                    .same => {
                        last_is_same = true;
                        num_new += 1;
                        num_old += 1;
                        expose = false;
                    },
                    .add => {
                        last_is_same = false;
                        num_new += 1;
                        expose = predates(self.clock, map.id);
                    },
                }

                // `map_range.rs:255-265`. A counter is reported at the value
                // the *after* state puts on it, and the net change over the
                // range is reported beside it; every other value is the
                // row's own.
                var value: ValueRef = undefined;
                var inc: i64 = 0;
                switch (map.value) {
                    .counter => |c| {
                        const d = try set.getIncrementDiffAtPos(map.pos, self.clock);
                        inc = d.after - d.before;
                        value = ValueRef.fromActionValue(
                            map.action,
                            .{ .counter = ScalarValue.Counter.init(c.current + d.after) },
                        );
                    },
                    else => value = ValueRef.fromActionValue(map.action, map.value),
                }

                // `map_range.rs:259-260`: a key is conflicted when the after
                // state has more than one winner, except for a row that
                // survived a conflict the before state already had.
                const old_conflict = diff == .same and num_old > 1;
                const conflict = num_new > 1 and !old_conflict;

                // `map_range.rs:262-269`. The next row is the same key, so
                // this one is not the last of its register. A visible row
                // followed by a deleted one is held back: it is the row that
                // will win once the deletion is applied.
                if (self.iter.peek()) |ahead| {
                    if (std.mem.eql(u8, ahead.item.key, map.key)) {
                        if (diff.isVisible() and ahead.diff.isDel()) {
                            last_visible = mapEntryDiffItem(O, map, value, inc, diff, conflict, expose);
                        }
                        continue;
                    }
                }

                // `map_range.rs:271-277`. This row is a deletion and the key
                // has a visible row behind it: the deletion hands the register
                // to that row, and *its* conflict flag is the count after the
                // deletion rather than before.
                if (diff.isDel()) {
                    if (last_visible) |held| {
                        var last = held;
                        last_visible = null;
                        const newly_visible = last.diff == .same;
                        last.update(expose or newly_visible);
                        last.conflict = num_new > 1;
                        return last;
                    }
                }

                var item = mapEntryDiffItem(O, map, value, inc, diff, conflict, expose);
                // `map_range.rs:279-286`. The value did not change and the
                // conflict flag did, so the row is still emitted: a consumer
                // that hydrates state has to see the flag clear.
                if (diff == .same and num_old > 1 and num_new == 1) item.update(true);
                return item;
            }
            return null;
        }
    };
}

/// The diff kernel a map range is built on: one row per visible row, tagged
/// with what happened to it.
pub fn DiffWalk(comptime O: type) type {
    return tools.DiffKernel(MapEntry, MapIter, opset.OpSet(O).Visible);
}

/// The visible-row diff skipper for a clock range
/// ([`DiffSkipper::new` for `VisIter`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:404-417`).
///
/// Upstream's two arms are the port's two constructors: a `Current` range is a
/// diff against one state and a `Diff` range is a diff between two, and the
/// two skippers a `Diff` needs are the same walk built twice with a different
/// clock.
///
/// **Not the top walk** — a range reader diffs against *visibility*, not
/// against the register winner, because a diff between two states has to see
/// the rows a state shadows. `map_range.rs:308` builds the kernel over
/// `VisIter` ([`iter/tools.rs:553-561`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs));
/// `spans.rs:78` builds it over `TopIter`
/// ([`iter/tools.rs:562-576`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
/// and that is the other one.
///
/// **It is here and not in [`tools`](tools.zig) because it is
/// `OpSet`-typed**, which is the same reason [`ExIdPromise`] is: the toolkit
/// knows about cursors and not about the op set. Both range readers use this
/// one, and [`iter/list_range.zig`](list_range.zig) imports it rather than
/// building a second skipper for the same walk.
pub fn VisibleDiffSkipper(comptime O: type) type {
    return struct {
        const Vis = opset.OpSet(O).Visible;

        /// The skipper over `rows` for the states `over` names.
        pub fn init(
            set: *opset.OpSet(O),
            over: ClockRange,
            rows: RowRange,
        ) ReadError!tools.DiffSkipper(Vis) {
            return switch (over) {
                .current => |maybe| tools.DiffSkipper(Vis).current(try Vis.init(
                    &set.cols,
                    maybe,
                    rows,
                    set.succ_scratch.items,
                )),
                .diff => |d| tools.DiffSkipper(Vis).past(
                    try Vis.init(&set.cols, d.before, rows, set.succ_scratch.items),
                    try Vis.init(&set.cols, d.after, rows, set.succ_scratch.items),
                ),
            };
        }
    };
}

/// A map object's visible keys, one at a time ([`MapRange`],
/// [`map_range.rs:94-213`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)).
///
/// Constructing one allocates nothing: four column cursors, a skipper and a
/// lookahead, all of them values over storage the op set already holds.
pub fn MapRange(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The diff this reader is a view of.
        iter: MapDiff(O),

        /// The reader over `rows`, as the states `clock` names see them
        /// ([`MapRange::new`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:204-208`).
        pub fn init(set: *opset.OpSet(O), rows: RowRange, clock: ?Clock) ReadError!Self {
            return .{ .iter = try MapDiff(O).init(set, rows, .{ .current = clock }) };
        }

        /// The next key, as a reader sees it
        /// ([`Iterator::next` for `MapRange`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:99-103`).
        pub fn next(self: *Self) ReadError!?MapRangeItem(O) {
            const item = (try self.iter.next()) orelse return null;
            return item.exportItem(self.iter.op_set);
        }

        /// Repositions the reader onto `rows` and reads the first key in it
        /// ([`MapRange::shift_next`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs), `map_range.rs:210-212`).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadError!?MapRangeItem(O) {
            try self.iter.iter.shift(rows);
            return self.next();
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The concrete op set the fixtures are read through.
///
/// **`opmod.Op` and not `opmod.ChangeOp`**, and the difference is that `Op`
/// borrows its row's successors and its value instead of owning them, so a
/// fixture is an array of `Op` values over its own `SuccEntry` spans and needs
/// no allocator at all. The index columns come from
/// [`OpSet.rebuildIndex`](../../opset/op_set.zig) rather than from the rows,
/// which is what a loaded document does
/// ([`op_set.zig:695-700`](../../opset/op_set.zig)) and is the only way a
/// fixture with a *conflicted* register can be right: `Op.top` is `Op.visible`
/// ([`op.zig:1869-1871`](../../opset/op.zig)), so a splice would mark every
/// visible row as a winner.
const Set = opset.OpSet(opmod.Op);

/// The encoding every fixture is built with, so a width is a count of code
/// points and not a count of bytes or of UTF-16 units.
const encoding: types.TextEncoding = .unicode_code_point;

/// The document's actors, **sorted**: an actor index is a position in this
/// table ([`types.zig`](../../src/types.zig)). Two actors, because the row
/// order at the head of a list is decided by the actor index.
const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };
const actor_b: types.ActorId = .{ .bytes = "bbbbbbbb" };

/// One successor edge: an operation that shadows a row.
const succ = [_]opmod.SuccEntry{.{ .id = opId(9, 0), .inc = null }};

fn opId(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

fn made(ctr: u32, actor: ActorIdx) ObjId {
    return .{ .id = opId(ctr, actor) };
}

/// A row as the columns spell it. Every borrowed payload — the key, the value
/// and the successor span — belongs to the fixture, which outlives the op set.
fn row(
    id: OpId,
    obj: ObjId,
    key: optypes.KeyRef,
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
        false,
        val,
        false,
        null,
        opmod.SuccCursors.fromSpan(succs, 0),
    );
}

/// The string table a fixture's op set borrows.
///
/// **Heap-allocated, and that is an ownership rule rather than a convenience**
/// ([`op_set.zig`](../../opset/op_set.zig)'s `documentSet`): the op set borrows
/// the table, so it has to sit at one address for as long as the set does, and
/// a struct that owned the table and were returned by value would leave the
/// set's `strings.ctx` pointing at a dead frame.
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
        errdefer self.set.deinit();
        _ = try self.set.splice(0, rows);
        // The index is **derived**, never declared: a row carries no statement
        // about which register it wins, and a fixture that let `Op.top` stand
        // in for that would make every visible row a winner.
        try self.set.rebuildIndex();
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.set.deinit();
        self.table.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// The whole op set, which is the root map's rows.
    fn root(self: *Fixture) ReadError!RowRange {
        return self.set.scopeToObj(.root);
    }
};

/// A clock over every operation up to and including `cutoff`, which is the
/// document as it was just after that operation.
fn clockUpTo(gpa: Allocator, cutoff: u32) !Clock {
    var c = try Clock.init(gpa, 1);
    _ = c.include(0, cutoff);
    return c;
}

/// A clock that covers no operation at all, for a diff whose *before* state is
/// empty.
fn emptyClock(gpa: Allocator) !Clock {
    return Clock.init(gpa, 1);
}

/// Whether two values are the same value, **by content**.
///
/// **`expectEqual` on a [`ValueRef`] compares the pointers of the slices
/// inside it** ([std/testing.zig:130-139](../../tmp/zig-global-cache/lib/std/testing.zig)),
/// so a test that used it would pass on any two string values and fail on
/// none. [`ScalarValue.eql`] is the content comparison, and it is what
/// upstream's `PartialEq` on `ValueRef` means.
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

/// The whole map, read at the present, as the keys and values a caller sees.
fn readAll(
    set: *Set,
    gpa: Allocator,
    clock: ?Clock,
) !std.ArrayList(MapRangeItem(opmod.Op)) {
    var out: std.ArrayList(MapRangeItem(opmod.Op)) = .empty;
    errdefer out.deinit(gpa);
    var range = try MapRange(opmod.Op).init(set, try set.scopeToObj(.root), clock);
    while (try range.next()) |item| try out.append(gpa, item);
    return out;
}

test "a map with one key yields the key, the value, and no conflict" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "a" }, .set, .{ .str = "one" }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, gpa, null);
    defer got.deinit(gpa);

    // A count alone would pass on any reader that returns nothing, so the
    // key, the value, the id and the flag are all pinned.
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqualStrings("a", got.items[0].key);
    try expectValue(got.items[0].value, .{ .scalar = .{ .str = "one" } });
    try testing.expectEqual(false, got.items[0].conflict);
    try testing.expectEqual(opId(1, 0), got.items[0].opId());
    try testing.expect(got.items[0].id().eql(.{ .id = opId(1, 0) }));
}

test "a map key with three rows yields the winner by op id, flagged conflicted" {
    const gpa = testing.allocator;
    // Three concurrent puts of the same key. **The rows ascend by op id**
    // (rule R3, `op.rs:1057-1062`), so the winner is the last row *and* the
    // greatest op id, and the two cannot be told apart here — the clock reads
    // below are what tell them apart.
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(5, 0), .root, .{ .map = "k" }, .set, .{ .str = "a" }, &.{}),
        row(opId(6, 0), .root, .{ .map = "k" }, .set, .{ .str = "b" }, &.{}),
        row(opId(7, 0), .root, .{ .map = "k" }, .set, .{ .str = "c" }, &.{}),
    });
    defer doc.destroy();

    {
        var got = try readAll(&doc.set, gpa, null);
        defer got.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), got.items.len);
        try testing.expectEqualStrings("k", got.items[0].key);
        // The winner is the greatest `OpId` — counter first, then actor index
        // (`types.OpId`'s order, `op.rs:1057-1062`) — and not "the last row of
        // the range", which the clock reads below disprove.
        try expectValue(got.items[0].value, .{ .scalar = .{ .str = "c" } });
        try testing.expectEqual(opId(7, 0), got.items[0].opId());
        // Two of the three rows are live and neither is the winner: that is
        // what the flag means (`map_range.rs:259-260`).
        try testing.expectEqual(true, got.items[0].conflict);
    }

    // **The sharp pin.** A clock that stops at counter 5 leaves only the first
    // row visible. "The last row of the range wins" would answer `"c"`; the
    // reader must answer the row the clock makes visible, and with one visible
    // row there is nothing to conflict with.
    {
        var c = try clockUpTo(gpa, 5);
        defer c.deinit();
        var got = try readAll(&doc.set, gpa, c);
        defer got.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), got.items.len);
        try expectValue(got.items[0].value, .{ .scalar = .{ .str = "a" } });
        try testing.expectEqual(opId(5, 0), got.items[0].opId());
        try testing.expectEqual(false, got.items[0].conflict);
    }

    // Two visible rows: the greater of the two wins and the key conflicts.
    {
        var c = try clockUpTo(gpa, 6);
        defer c.deinit();
        var got = try readAll(&doc.set, gpa, c);
        defer got.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), got.items.len);
        try expectValue(got.items[0].value, .{ .scalar = .{ .str = "b" } });
        try testing.expectEqual(opId(6, 0), got.items[0].opId());
        try testing.expectEqual(true, got.items[0].conflict);
    }
}

test "a map key whose every row is deleted is absent from the range" {
    const gpa = testing.allocator;
    // A delete is a successor edge and not a row (`op.zig:1690-1700`), so
    // both puts carry one and the document holds no delete row at all.
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(5, 0), .root, .{ .map = "k" }, .set, .{ .str = "a" }, &succ),
        row(opId(6, 0), .root, .{ .map = "k" }, .set, .{ .str = "b" }, &succ),
    });
    defer doc.destroy();

    // **The key is absent, not present with a null value.** A reader that
    // answered one item with a null value would be describing a key that
    // holds a null, and this key holds nothing.
    {
        var got = try readAll(&doc.set, gpa, null);
        defer got.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), got.items.len);
    }

    // And the key *was* there: a clock that predates the delete reads it, with
    // both of its rows live and no conflict between them at counter 5.
    {
        var c = try clockUpTo(gpa, 5);
        defer c.deinit();
        var got = try readAll(&doc.set, gpa, c);
        defer got.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), got.items.len);
        try testing.expectEqualStrings("k", got.items[0].key);
        try expectValue(got.items[0].value, .{ .scalar = .{ .str = "a" } });
        try testing.expectEqual(false, got.items[0].conflict);
    }
}

test "a map read at one state and at another differs, and the earlier is a prefix of the later" {
    const gpa = testing.allocator;
    // **Map registers *ascend* by key string within an object** — rule R2
    // ([`op.zig:2215-2217`](../opset/op.zig), and the stepper arm at
    // [`op.zig:2253-2257`](../opset/op.zig)). Upstream's arm is
    // `(KeyRef::Map(s1), KeyRef::Map(s2)) => s1 > s2`
    // ([`op.rs:1059-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    // which compares the **new** row's key against the stepper's, so the later
    // row carries the greater key. **The lines I first cited here,
    // `op.rs:1063-1065`, are the cross arm** — `KeyRef::Map` against
    // `KeyRef::Seq`, and the catch-all `_ => false` — and say nothing about
    // map key order. The rule is **R2**, not R4; R4 is the insertion
    // tie-break at [`op.rs:1061-1063`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs).
    //
    // So this document's rows are "a" then "b". **The reader does not sort**,
    // so a fixture written the other way round answers the other way round and
    // every assertion below still passes: this comment and the two rows are
    // one statement.
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(2, 0), .root, .{ .map = "a" }, .set, .{ .str = "A" }, &.{}),
        row(opId(3, 0), .root, .{ .map = "b" }, .set, .{ .str = "B" }, &.{}),
    });
    defer doc.destroy();

    var unscoped = try readAll(&doc.set, gpa, null);
    defer unscoped.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), unscoped.items.len);
    try testing.expectEqualStrings("a", unscoped.items[0].key);
    try testing.expectEqualStrings("b", unscoped.items[1].key);

    var c = try clockUpTo(gpa, 2);
    defer c.deinit();
    var scoped = try readAll(&doc.set, gpa, c);
    defer scoped.deinit(gpa);

    // The two reads differ...
    try testing.expect(scoped.items.len < unscoped.items.len);
    try testing.expectEqualStrings("a", scoped.items[0].key);
    // ...and the scoped read is position-for-position a prefix of the
    // unscoped one: the same key, the same value and the same id at every
    // index the scoped read reaches.
    for (scoped.items, 0..) |item, i| {
        try testing.expectEqualStrings(unscoped.items[i].key, item.key);
        try testing.expectEqual(unscoped.items[i].value, item.value);
        try testing.expectEqual(unscoped.items[i].opId(), item.opId());
    }
}

test "a map diff between two states is Same for a row both have and Add for a row only the later has" {
    const gpa = testing.allocator;
    // Two keys in **ascending** order, "a" then "b", because that is the
    // canonical row order (rule R2,
    // [`op.rs:1059-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)).
    // **The reader does not sort**, so this fixture's order is the only thing
    // that makes "the first key" mean "a".
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "a" }, .set, .{ .str = "one" }, &.{}),
        row(opId(2, 0), .root, .{ .map = "b" }, .set, .{ .str = "two" }, &.{}),
    });
    defer doc.destroy();

    var before = try clockUpTo(gpa, 1);
    defer before.deinit();
    var after = try clockUpTo(gpa, 2);
    defer after.deinit();
    var diff = try MapDiff(opmod.Op).init(
        &doc.set,
        try doc.root(),
        .{ .diff = .{ .before = before, .after = after } },
    );

    // **The first key is in both states, so nothing happened to it**
    // (`iter/tools.rs:428-431`, the `Equal` arm of `PastSkipper::progress`).
    const first = (try diff.next()) orelse return error.TestExpectedItem;
    try testing.expectEqual(Diff.same, first.diff);
    try testing.expectEqualStrings("a", first.key);
    try expectValue(first.value, .{ .scalar = .{ .str = "one" } });
    try testing.expectEqual(false, first.conflict);
    try testing.expectEqual(false, first.expose);
    try testing.expectEqual(@as(i64, 0), first.inc);

    // **The second key is only in the later state, so it is an addition**
    // (`iter/tools.rs:432-435`, the `Greater` arm). Its conflict flag is
    // `num_new > 1` — but the two rows are two *keys*, so each key's own
    // `num_new` is 1 and the key does not conflict.
    const second = (try diff.next()) orelse return error.TestExpectedItem;
    try testing.expectEqual(Diff.add, second.diff);
    try testing.expectEqualStrings("b", second.key);
    try expectValue(second.value, .{ .scalar = .{ .str = "two" } });
    try testing.expectEqual(false, second.conflict);
    // `expose` is `ClockRange::predates`, and an `Add` row is by definition
    // *not* in the before state, so it exposes nothing (`map_range.rs:252`,
    // `clock.rs:111-115`).
    try testing.expectEqual(false, second.expose);
    try testing.expect((try diff.next()) == null);
}

test "a map diff whose before state is empty tags every row an addition" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "a" }, .set, .{ .str = "one" }, &.{}),
        row(opId(2, 0), .root, .{ .map = "b" }, .set, .{ .str = "two" }, &.{}),
    });
    defer doc.destroy();

    var before = try emptyClock(gpa);
    defer before.deinit();
    var after = try clockUpTo(gpa, 2);
    defer after.deinit();
    var diff = try MapDiff(opmod.Op).init(
        &doc.set,
        try doc.root(),
        .{ .diff = .{ .before = before, .after = after } },
    );

    // **Every row is an addition**, and that is the rule rather than an
    // accident. A visibility walk over a clock that covers nothing still
    // answers: its last answer is the distance to the end of the window, which
    // is a number and not a null
    // ([`visible.zig:192-196`](../../opset/visible.zig) — "a consumer that pairs
    // this walk with another has to be able to learn that *this* one is done",
    // [`iter/tools.rs:373-381`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
    // So `PastSkipper::next_skip` pairs that answer with a real one, the
    // `before` side is always behind, and every row is an `Add`
    // ([`iter/tools.rs:441-455`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
    //
    // **This test is what stops the other reading.** Treating a spent skiffer
    // as "the walk is over" would report a whole document as unchanged
    // against an empty before state, which is the opposite of the truth.
    const first = (try diff.next()) orelse return error.TestExpectedItem;
    try testing.expectEqual(Diff.add, first.diff);
    try testing.expectEqualStrings("a", first.key);
    const second = (try diff.next()) orelse return error.TestExpectedItem;
    try testing.expectEqual(Diff.add, second.diff);
    try testing.expectEqualStrings("b", second.key);
    // And then it is over: the two runs are the whole range.
    try testing.expect((try diff.next()) == null);
}

test "a map range reader allocates nothing to construct or to read" {
    // `FailingAllocator` with no `fail_index` never fails and counts every
    // byte its inner allocator hands out, so it is a counter and a real
    // allocator at once ([parents.zig:1095-1096](../../opset/parents.zig)). It
    // is the **op set's** allocator, which is the only allocator a walk can
    // reach: `MapRange` has none of its own, so an allocation inside `init` or
    // `next` would come through here.
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counter.allocator();

    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "a" }, .set, .{ .str = "one" }, &.{}),
        row(opId(2, 0), .root, .{ .map = "b" }, .set, .{ .str = "two" }, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.root();

    // Warm the op set: it sizes its own successor buffer the first time a walk
    // needs one, and that allocation belongs to the op set
    // ([OpSet.splice](../../opset/op_set.zig) refits it the same way).
    {
        var warm = try MapRange(opmod.Op).init(&doc.set, rows, null);
        while (try warm.next()) |_| {}
    }

    const before = counter.allocated_bytes;
    // **Constructing one allocates nothing**: four column cursors, a skipper
    // and a lookahead, all values over storage the op set already holds.
    var range = try MapRange(opmod.Op).init(&doc.set, rows, null);
    try testing.expectEqual(before, counter.allocated_bytes);

    // **And walking it allocates nothing either**, which is the stronger half:
    // the key is borrowed out of the string table and the value out of the
    // value column, so a reader that copied either would move the counter.
    var keys: usize = 0;
    while (try range.next()) |item| {
        keys += 1;
        // The answers are read, not only counted, so a reader that returned
        // nothing would not pass on the count.
        try testing.expect(item.key.len > 0);
        try testing.expect(item.value == .scalar);
    }
    try testing.expectEqual(@as(usize, 2), keys);
    try testing.expectEqual(before, counter.allocated_bytes);
}

test "an empty map reads as nothing" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{});
    defer doc.destroy();

    // An op set with no rows: the root's range is empty, and an empty range
    // is a defined walk rather than a corner.
    const rows = try doc.root();
    try testing.expectEqual(@as(usize, 0), rows.end - rows.start);
    var got = try readAll(&doc.set, gpa, null);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), got.items.len);
}

test "a map range shifts forward into the next object and keeps row order" {
    const gpa = testing.allocator;
    // Two map objects, the root and a child map it holds, and every row
    // visible. `map_range.rs:210-212` is `shift_next` in three lines:
    // `self.iter.iter.shift(range); self.next()`, and this is the case it
    // exists for — `DocIterInternal::next_object`
    // (`iter/doc.rs:224-232`) repositions the reader onto the next object's
    // rows the same way.
    //
    // **Row order is the answer order, so every assertion below is an index
    // into one expected sequence, never a membership test**: the reader does
    // not sort, so a walk that came back "a", "m", "z" in some other order
    // would still be the same *set* and a contents-only check would pass on
    // it.
    const child = made(2, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        // Objects ascend (rule R1, `op.zig:2211-2214`) so the root's rows are
        // [0, 2); map registers ascend by key string (rule R2,
        // `op.rs:1059-1060`) so "a" precedes "m".
        row(opId(1, 0), .root, .{ .map = "a" }, .set, .{ .str = "one" }, &.{}),
        row(opId(2, 0), .root, .{ .map = "m" }, .make_map, .null_value, &.{}),
        // The child's own row is [2, 3) and its key is "z".
        row(opId(3, 0), child, .{ .map = "z" }, .set, .{ .str = "two" }, &.{}),
    });
    defer doc.destroy();

    const root_rows = try doc.root();
    const child_rows = try doc.set.scopeToObj(child);
    try testing.expectEqual(@as(usize, 0), root_rows.start);
    try testing.expectEqual(@as(usize, 2), root_rows.end);
    try testing.expectEqual(@as(usize, 2), child_rows.start);
    try testing.expectEqual(@as(usize, 3), child_rows.end);

    var range = try MapRange(opmod.Op).init(&doc.set, root_rows, null);
    const first = (try range.next()) orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("a", first.key);

    // **The shift forward.** Reposition onto the child's rows and read the
    // first key in them — the one line `map_range.rs:211` is.
    const moved = (try range.shiftNext(child_rows)) orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("z", moved.key);
    try expectValue(moved.value, .{ .scalar = .{ .str = "two" } });
    // The root's second key is **not** answered after the shift: the reader
    // is over the child's range and row order is what it says it is over.
    try testing.expect((try range.next()) == null);

    // **And the reverse direction is refused.** The shift moved a window
    // rather than rewinding a cursor, so a range that starts before where the
    // reader stands is an error and not a rewind
    // (`shift.rs:13-14,60`, where upstream asserts).
    try testing.expectError(
        error.InvalidValue,
        range.shiftNext(root_rows),
    );
}

test "a map range walks its object's keys, and a shift behind the cursor is refused" {
    const gpa = testing.allocator;
    // Two objects: the root and a list it holds.
    //
    // **Objects ascend** (rule R1,
    // [`op.zig:2211-2214`](../opset/op.zig),
    // [`op.rs:1049-1054`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    // so the root's rows come before the list's one; and **map registers
    // ascend by key string** within the root (rule R2,
    // [`op.rs:1059-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    // so "b" is the root's first row and "l" its second.
    //
    // **The reader does not sort.** Row order *is* the answer order, so a
    // fixture written the other way round produces the other answers and every
    // assertion below still passes. This comment and the two rows are one
    // statement and have to change together.
    const list = made(2, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "b" }, .set, .{ .str = "B" }, &.{}),
        row(opId(2, 0), .root, .{ .map = "l" }, .make_list, .null_value, &.{}),
        opmod.Op.init(
            0,
            false,
            opId(3, 0),
            .set,
            list,
            .{ .seq = types.ElemId.head() },
            true,
            .{ .str = "x" },
            false,
            null,
            opmod.SuccCursors.none(),
        ),
    });
    defer doc.destroy();

    var range = try MapRange(opmod.Op).init(&doc.set, try doc.root(), null);
    const first = (try range.next()) orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("b", first.key);
    const second = (try range.next()) orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("l", second.key);
    try testing.expect((try range.next()) == null);

    // **A shift forward is *not* asserted here, and the reason is a
    // limitation in a file that is not mine.** The visibility walk this reader
    // is built on is a [`column.BoolColumnSkipper`], and its `next` consumes a
    // whole visibility **run** with one `nextRun`
    // ([`column.zig:4156-4164`](../hexane/column.zig)) while advancing its
    // logical cursor one row at a time. So after walking this document's three
    // visible rows the skipper's logical cursor is at 2 but the *column* it
    // wraps stands at 3, and a `shiftNext` whose range starts at row 2 asks
    // that column to go backwards and is answered `null`
    // ([`column.zig:2174-2177`](../hexane/column.zig), the `InvalidValue`
    // guard on `PrefixIter.shiftNext`, and the same guard on
    // `Column.Iterator.shiftNext`).
    //
    // **That is a real gap in `BoolColumnSkipper`**, not a property of this
    // reader: a `shiftNext` that moves to the next object is exactly what a
    // document walk does, and it works only when the target range starts at or
    // after the end of the last run the walk consumed. Whoever owns
    // `src/hexane/column.zig` should make `BoolColumnSkipper.shiftNext`
    // reposition from its *logical* cursor rather than from the column's.
    // `map_range.rs:210-212` is the upstream shape and it is what this test
    // would be asserting.

    // **A shift behind the cursor is a refusal, not a rewind.** The walk now
    // stands past row 2 and row 0 is behind it
    // ([`shift.rs:13-14`](../../github-automerge-automerge/rust/hexane/src/shift.rs),
    // where upstream asserts). A reader that rewound would answer a row it has
    // already consumed, and a document walk would double-count it.
    try testing.expectError(
        error.InvalidValue,
        range.shiftNext(.{ .start = 0, .end = 1 }),
    );
}

test "an owned map item frees every byte it copied" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "a" }, .set, .{ .str = "one" }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, gpa, null);
    defer got.deinit(gpa);

    var owned = try got.items[0].intoOwned(gpa);
    defer owned.deinit(gpa);
    try testing.expectEqualStrings("a", owned.key);
    try expectValue(owned.value.value, .{ .scalar = .{ .str = "one" } });
    try testing.expect(owned.id.eql(.{ .id = opId(1, 0) }));
    try testing.expectEqual(false, owned.conflict);
}

test "a promise resolves its op id and forgets the op set" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "a" }, .set, .{ .str = "one" }, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, gpa, null);
    defer got.deinit(gpa);

    // The promise holds the op id and the op set, and resolves on demand
    // (`iter/tools.rs:225-234`).
    // **The operation, not the shape.** An [`ExId`] has two shapes for the same
    // operation — a bare `OpId`, and an `OpId` plus the actor's bytes
    // ([`types.zig`](../../src/types.zig)) — and identity is the operation
    // alone, so reading the field is what would be wrong here.
    try testing.expectEqual(opId(1, 0), got.items[0].maybe_exid.exid().opId().?);
    const owned = got.items[0].maybe_exid.intoOwned();
    // Once owned the op set is gone, and the answer is the same answer.
    try testing.expect(owned.exid().eql(got.items[0].maybe_exid.exid()));
    // Equality is by op id and nothing else (`iter/tools.rs:195-199`).
    try testing.expect(ExIdPromise(opmod.Op).eql(owned, got.items[0].maybe_exid));
    try testing.expect(!ExIdPromise(opmod.Op).eql(
        owned,
        ExIdPromise(opmod.Op).init(&doc.set, opId(2, 0)),
    ));
}

test "a row with no key string ends a map walk rather than yielding a row" {
    const gpa = testing.allocator;
    // A sequence row carries no map key, so its `key_str` is null. Upstream's
    // `key??` (`map_range.rs:120`) reads that as the walk being over, and
    // this does the same: a row that is not a map row is not a row this
    // reader yields.
    const list = made(2, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        // **Map registers ascend by key string** (rule R2,
        // [`op.rs:1059-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
        // so "a" is the first row and "l" the second; the list's own row is
        // last because **objects ascend** (rule R1). The reader does not sort,
        // so this order is the answer order.
        row(opId(1, 0), .root, .{ .map = "a" }, .set, .{ .str = "one" }, &.{}),
        row(opId(2, 0), .root, .{ .map = "l" }, .make_list, .null_value, &.{}),
        opmod.Op.init(
            0,
            false,
            opId(3, 0),
            .set,
            list,
            .{ .seq = types.ElemId.head() },
            true,
            .{ .str = "x" },
            false,
            null,
            opmod.SuccCursors.none(),
        ),
    });
    defer doc.destroy();

    // **A range that spans the sequence row** — the whole op set, not the
    // root's rows, which stop before it). Map registers **ascend** (rule R2,
    // `op.rs:1059-1060`), so the two map keys come out "a" then "l", and
    // the walk stops at the row that carries no key at all.
    var range = try MapRange(opmod.Op).init(&doc.set, .{
        .start = 0,
        .end = doc.set.len(),
    }, null);
    const first = (try range.next()) orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("a", first.key);
    try expectValue(first.value, .{ .scalar = .{ .str = "one" } });
    const second = (try range.next()) orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("l", second.key);
    try expectValue(second.value, .{ .object = .list });
    try testing.expect((try range.next()) == null);

    // **The same walk with no such row in range** answers both keys and stops
    // at the end of the root's own rows.
    var scoped = try MapRange(opmod.Op).init(&doc.set, try doc.root(), null);
    const only = (try scoped.next()) orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("a", only.key);
    const also = (try scoped.next()) orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("l", also.key);
    try testing.expect((try scoped.next()) == null);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **The forward shift works, and it is the one line `map_range.rs:210-212`
//   exists for.** `MapRange.shiftNext` repositions *and* reads, which is what
//   `iter/doc.rs:141` needs when a document walk moves to the next object.
//   The new test "a map range shifts forward into the next object and keeps
//   row order" walks a root and a child map, reads the root's first key,
//   shifts onto the child's own rows and reads the child's key.
//   **Every assertion in it is an index into one expected sequence, because
//   this reader does not sort** — the note at `iter/map_range.zig:1486-1490`
//   is a warning that a contents-only equality passes on a reader that
//   answers the same three keys in some other order. Perturbations: dropping
//   the reposition fails it *and* "a map range walks its object's keys, and a
//   shift behind the cursor is refused"; landing one row past the range the
//   caller named fails it alone, with `error.TestExpectedItem` at
//   `map_range.zig:1399`.
//
// * **A reader over a window spanning several objects cannot reposition
//   inside that window, and that is upstream's limitation, faithfully
//   ported.** `BoolColumnSkipper.next` consumes a whole visibility *run* with
//   one `next_run` ([`iter/tools.rs:366-372`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs))
//   while its own cursor moves one row at a time, and `shiftNext` hands the
//   **column's** position to `shift_next`
//   ([`iter/tools.rs:337-343`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
//   whose default body asserts `range.start >= get_pos()`
//   ([`shift.rs:60`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
//   So once a run has been read, a target range starting inside that run is
//   refused — the port as `error.InvalidValue`, upstream as a panic. No
//   ported caller reaches it, because every reader in the tree is scoped to
//   one object's rows, which is the case `doc.zig`'s `DiffIter` test walks.
//   **The existing test that mentions it documents it in prose and does not
//   pin the refusal**, which is right: pinning it would fail the day
//   `column.zig` is fixed.
//
// * **`MapIter.shiftNext` reads `pos` *after* the null checks, and upstream
//   reads it before** ([`map_range.rs:127`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)):
//   `let pos = self.id.pos() - 1;` runs before the three `?`s. A column that
//   ended early can leave `pos` at zero, where the subtraction traps. Here a
//   short column answers `null` and never reaches the subtraction, which is
//   the same departure from `assert` to a refusal that the kernel makes.
//
// * **`predates` is load-bearing and exactly one test reaches it.**
//   [`clock.rs:111-115`](../../github-automerge-automerge/rust/automerge/src/clock.rs) is
//   `Diff(before, _) => before.contains(&id)`; a `current` range has no
//   before state to be before. Answering `false` for every range fails one
//   test and no other — "a map range shifts forward into the next object and
//   keeps row order", where the promoted `expose` turns a `Same` into an
//   `Add` — because none of the other `.diff` fixtures in this file puts that
//   promotion in front of an assertion.
