//! The handle an iteration runs against, and the two walks over a document's
//! objects (`rust/automerge/src/iter/doc.rs`).
//!
//! # What this file owns
//!
//! | | upstream | port |
//! |---|---|---|
//! | the handle a document walk runs against | `&Automerge` ([`DocIter::new`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs), `iter/doc.rs:42-50`) | [`Doc`] |
//! | the walk over the objects, narrowed to a clock | `OpSet::obj_id_iter` ([`op_set.rs:1344-1346`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)) | [`ObjIdIter`] |
//! | the recursive walk over a document's **items** | `DocIter` ([`iter/doc.rs:19-50`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs), walked at `iter/doc.rs:288-315`) | [`DocIter`] |
//! | the recursive walk over the objects a **diff** touched | `DiffIter` ([`iter/doc.rs:66-76`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs), walked at `iter/doc.rs:306-315`) | [`DiffIter`] |
//! | which of the three readers an object is read with | `IterType` (`iter/doc.rs:274-289`) | [`IterType`] |
//!
//! [`Doc`] is `Automerge` as far as this directory can see: the op set and
//! the text encoding, which are **the only two things `iter/doc.rs` ever
//! reaches the document for** — `doc.ops()` and `doc.text_encoding()` at
//! `iter/doc.rs:44,100,186`, and nothing else. The load, save, commit and
//! transaction surface is not here and does not belong here; a caller with a
//! document builds a [`Doc`] over its op set and hands that to the walks.
//!
//! **What the document layer hands over** is therefore exactly
//! `Doc.init(self.ops(), self.textEncoding())` and nothing else:
//! `src/doc.zig` builds the handle, and every reader in this directory takes
//! it or the two things it holds. Nothing here imports a document.
//!
//! # `ObjIdIter` is not `opiter.ObjIdIter`
//!
//! It is **not** [`opiter.ObjIdIter`](../opset/op_iter.zig) re-exported, and
//! the difference is three things, each of which has an answer the other type
//! does not:
//!
//! * **A unit.** `opiter.ObjIdIter` answers one row per step
//!   ([`op_iter.zig:620-624`](../opset/op_iter.zig), `op_iter.rs:625-635`) and
//!   its whole job upstream is to find one object's rows
//!   ([`seekToValue`](../opset/op_iter.zig), `op_iter.rs:616-623`) — **upstream
//!   uses that seek and nothing else** ([`iter/doc.rs:147,244`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)).
//!   A document walk wants **one object per step**, and an object's rows are a
//!   contiguous run of equal values (rule **R1**,
//!   [`op.zig:2211-2214`](../opset/op.zig), `op_set2/op.rs:1049-1054`), so a
//!   step is a read plus that seek plus consuming the run it finds. It is the
//!   same seek, not a second way of answering where an object ends.
//! * **A clock.** A `Clock` narrows which objects exist, which is the one
//!   question a row cursor over the object columns cannot answer. See the
//!   next section.
//! * **The text encoding.** It is on the [`Doc`] handle, because the
//!   consumer of it is the spans reader and not this walk — upstream passes
//!   `doc.text_encoding()` to `SpansInternal::new` and to nothing in
//!   `DocIterInternal` (`iter/doc.rs:186`).
//!
//! So it is a distinct type, and it is a wrapper: it holds an
//! `opiter.ObjIdIter` and forwards every position and window operation to
//! it. It recomputes nothing that [`OpSet.scopeToObj`](../opset/op_set.zig)
//! or [`opiter.ObjIdIter.seekToValue`] already answers, and it is not
//! generic over the op set's row type, because nothing in it is: the two
//! object columns are `OpSet`-independent (which is why
//! `opiter.ObjIdIter` is not generic either, `op_iter.zig:508-510`).
//!
//! # The clock is the whole of the narrowing
//!
//! **An object's id is the id of the operation that created it** — the op
//! set indexes objects under their creating op's own id
//! ([`OpSet.spliceObjects`](../opset/op_set.zig), `op_set.zig:1287-1291`),
//! and [`Op.objInfo`](../opset/op.zig) is what says a row creates one
//! (`op.zig:1751-1757`). So the object is in the state `clock` names exactly
//! when the clock covers that operation, and that is the one test
//! [`ObjIdIter.covers`] makes.
//!
//! Upstream never asks the question. A child enters the walk only from a
//! *visible* item of its parent, and the three readers those items come from
//! are filtered by the same clock
//! ([`iter/doc.rs:120-131,141-153`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
//! with `DocIter::new` handing the clock to `MapRange`, `ListRange` and
//! `SpansInternal` at `iter/doc.rs:184-186`), so an object whose creating op
//! is not in the clock is never queued and never visited. The rule is the
//! same; this file is the one place it can be written down as one line.
//!
//! **The root is the one object no clock can exclude.** Both of its object
//! columns are null ([`tryLoadObjId`](../opset/op_iter.zig), `op_iter.rs:217-219,227`),
//! so no operation made it, and a clock that covers nothing still visits it —
//! which is what upstream does too, since the object a walk starts from is
//! seeked before any item is read (`iter/doc.rs:182-183`).
//!
//! Upstream spells the predicate `Clock::covers(&OpId)` ([`clock.rs:124-136`](../../github-automerge-automerge/rust/automerge/src/clock.rs));
//! the port's [`Clock.contains`](../../src/clock.zig) is the same test
//! (`clock.zig:107-109`) under a different name, because the port's
//! `Clock.covers` is a *clock* covering another clock.
//!
//! # Row order is the order upstream's `BTreeMap` gave
//!
//! Upstream keeps its children in a `BTreeMap<ObjId, IterType>` and takes
//! them with `pop_first` ([`iter/doc.rs:55,146,243`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)),
//! so a walk visits objects in `ObjId` order and not in the order it found
//! them. Row order is that same order: the object columns are sorted by
//! object, which is half of rule **R1**
//! ([`op.zig:2211-2214`](../opset/op.zig)). The queue uses contextual resident
//! `OpId` ordering, not public named-identity ordering by actor bytes. Columns
//! are already in that same resident order, so returned items need no sort.
//!
//! # The unit is an object, not a row
//!
//! [`ObjIdIter`] carries the [`Shiftable`](../../src/hexane/column.zig)
//! conformance mark, and every one of the eight kernel names is
//! [`opiter.ObjIdIter`]'s, forwarded. Two of them read, and both read **the
//! object the range lands in**, not the row it lands on: `shiftNext` and
//! `seekTo` consume the whole run they land in, because a walk that reported
//! the same object twice — once per row — is not a walk over objects. Every
//! consumer in this directory repositions with **whole-object ranges** (the
//! ones [`OpSet.scopeToObj`](../opset/op_set.zig) answers), so for them the
//! two readings agree.
//!
//! **Nothing is held back, and that is what keeps the kernel plain.** The
//! obvious way to collapse a run is to read one row past it and keep it, and
//! that state is what makes `pos` mean something other than what it says: the
//! walk would stand one row beyond the object it just reported, `advanceTo`
//! onto that object's own range would be a no-op, and the object after it
//! would be **silently lost**. So the run is consumed whole instead
//! ([`ObjIdIter.consumeRun`]), the walk's position is always the first row of
//! the object the next read will report, and every one of the eight kernel
//! methods means exactly what it means on a column.
//!
//! A shift past the end of a window is `null` and a range that starts behind
//! the cursor is `error.InvalidValue` ([`column.zig:3641-3642`](../hexane/column.zig),
//! where upstream asserts, `shift.rs:13-14,60`), and both are stated in
//! [`ObjIdIter.shiftNext`] because the step reads a run and the two object
//! columns would answer them for a row.
//!
//! # Constructing a handle and an object walk allocates nothing
//!
//! An iterator is a value. A
//! [`Doc`] is a pointer and an enum, and an [`ObjIdIter`] is two column
//! cursors and a borrowed clock — no allocator anywhere, and no state beyond
//! the cursor, which is what the test "a handle and an object walk are
//! values" says with a counting allocator rather than asserting.
//!
//! **The two recursive walks are not in that claim**, and the difference is
//! what they hold: each one owns a [`SpansInternal`](spans.zig) fold and an
//! [`ObjQueue`], so both take an allocator at
//! [`DocIter.init`](DocIter)/[`DiffIter.init`](DiffIter) and give it back at
//! `deinit`. The fold grows a run buffer and the
//! queue grows per nested object, and a port that hid either behind a global
//! would hand two documents' walks one allocator.
//!
//! # Two walks, and they are not the same walk
//!
//! [`DocIter`] and [`DiffIter`] both walk a document's objects and both hold
//! one each of [`MapRange`](map_range.zig), [`ListRange`](list_range.zig) and
//! a spans reader. They differ in **what they yield** — one item per property
//! against one diff per property — and in what the three readers are built
//! over: `MapRange`/`ListRange`/`SpansInternal` here, `MapDiff`/`ListDiff`/
//! `SpansDiff` there. Upstream keeps them as two types and so does the port;
//! the shared parts are [`Doc`], [`ObjIdIter`], [`IterType`] and
//! [`ObjQueue`], and nothing else is shared.
//!
//! # The order of the recursive walk is not negotiable
//!
//! A child enters the queue as its parent's items are read and is taken back
//! **lowest id first** — upstream's `BTreeMap::pop_first`
//! ([`iter/doc.rs:243`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)),
//! which is [`ObjQueue.popLowest`] — so the walk reads a parent before its
//! children and, among siblings, the one created earliest first. That is
//! `read.rs:68-72`'s "causal order", and it is a **sequence**: a walk that
//! visited a later child first would produce the same *set* of items in a
//! different order. The test "the recursive walk reads the root's rows, then
//! every child, parents before children" is the one that fails if the queue
//! takes the maximum, for exactly that reason.
//!
//! # What is not here
//!
//! **The document-layer entry point is in [read.zig](../src/read.zig).**
//! Upstream reaches this walk through `Automerge::iter` / `ReadDoc::iter_at`
//! ([`read.rs:60,68-76`](../../github-automerge-automerge/rust/automerge/src/read.rs),
//! [`automerge.rs:1669-1674`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//! and the port spells it [`read.iter`](../src/read.zig) and
//! [`read.iterAt`](../src/read.zig). That file builds the [`Doc`] handle —
//! which is the whole of what `iter/doc.rs` ever reaches the document for
//! (`doc.ops()` and `doc.text_encoding()`, `iter/doc.rs:44,100,186`) — and
//! hands it to [`DocIter.init`], exactly as [`PatchDoc.handle`](../../src/doc.zig)
//! does for [`DiffIter`]. Nothing in this directory imports a document.
//!
//! **`DocIter::empty` (`iter/doc.rs:25-33`).** Upstream's is
//! `Option<&OpSet>` plus three default readers, and `iter_for`
//! ([`automerge.rs:1669-1674`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
//! reaches for it when an object id names nothing. The port's leaf readers are
//! not optional either, and for the same reason they were not
//! ([`MapDiff.op_set`](map_range.zig)): a caller with no object scopes to an
//! **empty row range**, and builds the same walk, which answers nothing for
//! the same reason. [`read.iterAt`](../src/read.zig) is that caller.
//!
//! **`DocIterInternal.path_map` (`iter/doc.rs:56`, written at `:218`).** The
//! port's internal walk records no path map, because **nothing in upstream
//! ever reads that one**: the only read of a field by that name is
//! `DiffIter::log` returning *its own* ([`iter/doc.rs:91`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)),
//! and [`patches.PathMap`](../../src/patches.zig) has its own two readers in
//! `patch_builder.rs:39,147`. It is state that upstream allocates per nested
//! object and throws away, and `DocItemInternal::prop` (`iter/doc.rs:454-465`)
//! — the only thing that would fill it — is not ported with it. The
//! diff walk's path map **is** ported, because that one has a reader.
//!
//! **`DocObjItem.obj`'s `Arc<ExId>` (`iter/doc.rs:337-338`, refreshed by a
//! comparison at `:294-298`).** The port's is a plain [`ObjId`]
//! ([`types.ExId`](../types.zig)) without a refcount.
//! One walk hands each item to one caller. The
//! *refresh* is kept, because it is what keeps the actor table read once per
//! object rather than once per item (`iter/doc.rs:295-297`).

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clockmod = @import("../clock.zig");
const column = @import("../hexane/column.zig");
const batchmod = @import("../opset/batch.zig");
const opcols = @import("../opset/columns.zig");
const optypes = @import("../opset/types.zig");
const opiter = @import("../opset/op_iter.zig");
const opset = @import("../opset/op_set.zig");
const patches = @import("../patches.zig");
const hydrate = @import("../hydrate.zig");
const listrange = @import("list_range.zig");
const maprange = @import("map_range.zig");
const spans = @import("spans.zig");
const tools = @import("tools.zig");

const Allocator = std.mem.Allocator;
const ReadOpError = opiter.ReadOpError;

const ActorIdx = types.ActorIdx;
const Clock = clockmod.Clock;
const ClockRange = clockmod.ClockRange;
const Diff = tools.Diff;
const ObjId = types.ExId;
const OpId = types.OpId;
const PatchValue = batchmod.PatchValue;
const Prop = types.Prop;
const TextEncoding = types.TextEncoding;
const ValueRef = optypes.ValueRef;

const RowRange = tools.RowRange;
/// The repositioning kernel, re-exported so a consumer of this file does not
/// have to import [src/hexane/column.zig](../hexane/column.zig) to name what
/// [`ObjIdIter`] carries.
pub const Shiftable = column.Shiftable;

/// What reading a document's objects can fail with.
///
/// **Nothing is added to [`ReadOpError`](../opset/op_iter.zig), and that is
/// deliberate** ([`op_iter.zig:149-160`](../opset/op_iter.zig)): the two
/// object columns are read through `opiter.ObjIdIter`, so a column that ran
/// out is `ParseError` and an id whose halves do not make one is
/// `error.InvalidOpId` — both already members. The name is here so a caller
/// of this file alone can name the set, for the reason
/// [`iter/map_range.zig`](map_range.zig) re-exports `Diff`.
///
/// A walk's own end is `null` and a range behind the cursor is
/// `error.InvalidValue`, which is in `ParseError`.
pub const DocError = ReadOpError;

// ── The walk ────────────────────────────────────────────────────────────────

/// Every object a document holds, once each, in row order, narrowed to a
/// state ([`ObjIdIter`]).
///
/// **Not a second source of truth for anything.** The ids come from the two
/// object columns, and the run each object owns is the one
/// [`opiter.ObjIdIter.seekToValue`](../opset/op_iter.zig) finds — which is
/// the same answer [`OpSet.scopeToObj`](../opset/op_set.zig) gives, because it
/// is the same two descents — so a caller that needs an object's rows asks
/// the op set for them and does not read a range off this walk. The walk's one
/// addition is **the clock**: see the module doc's second section.
pub const ObjIdIter = struct {
    const Self = @This();

    /// The two object columns, read one row at a time
    /// ([`ObjIdIter`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_iter.rs),
    /// `op_iter.rs:570-574`).
    ids: opiter.ObjIdIter,
    /// The state the walk is narrowed to, and null for the present
    /// ([`DocIter::new`](../iter/doc.zig) takes the same
    /// `clock: Option<Clock>`, `iter/doc.rs:42`).
    clock: ?Clock,
    /// **Nothing else.** A step consumes the whole run it lands in, so the
    /// walk's position is always the first row of the object the next read
    /// will report — there is no row drawn ahead and no state to invalidate
    /// when the window moves. That is what makes every kernel method below
    /// mean what the kernel says it means, with no cross-field invariant
    /// between them.
    /// The [`Shiftable`] conformance mark. Naming it instantiates the comptime
    /// check over the eight kernel names
    /// ([`column.zig:4032-4052`](../hexane/column.zig)), which *is* the check
    /// that this walk can be repositioned.
    pub const shiftable = Shiftable(Self);

    /// A walk over every object of an op set, as `clock` sees it
    /// ([`DocIter::new`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
    /// `iter/doc.rs:42-50`, which takes the same `clock: Option<Clock>`).
    ///
    /// **Takes no allocator and allocates nothing.** A clock is a borrowed
    /// vector of counters ([`clock.zig:20-28`](../../src/clock.zig)) and the
    /// caller owns it, exactly as it does for
    /// [`MapRange.init`](map_range.zig) and
    /// [`Spans.init`](spans.zig).
    pub fn init(ids: opiter.ObjIdIter, clock: ?Clock) Self {
        return .{ .ids = ids, .clock = clock };
    }

    // ── The kernel ─────────────────────────────────────────────────────
    //
    // Eight forwarders, as [`MapIter`](map_range.zig) and
    // [`ListIter`](list_range.zig) also carry. Upstream has no such wrapper:
    // it seeks the object cursor and hands the range to one of the three
    // readers ([`iter/doc.rs:147,244`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)),
    // and this walk is the port's spelling of the same repositioning over
    // the same seek — see [`ObjIdIter.next`].

    /// The row the next read starts at
    /// ([`pos`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:20-22`).
    pub fn pos(self: *const Self) usize {
        return self.ids.pos();
    }

    /// One past the last row this walk can reach (`shift.rs:23-25`).
    pub fn maxPos(self: *const Self) usize {
        return self.ids.maxPos();
    }

    /// Truncates the window at `at` ([`set_max`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:26-27`).
    ///
    /// A window that no longer covers the row the walk stands on drains it,
    /// and the next read is null: a walk may not answer an object whose rows
    /// are behind the window it was given.
    pub fn setMax(self: *Self, at: usize) void {
        self.ids.setMax(at);
    }

    /// Advances so the next read is the row at `target` (`shift.rs:34-40`).
    ///
    /// A target at or behind the cursor is a no-op, as it is on a column
    /// ([`column.zig:3612-3618`](../hexane/column.zig), `column.rs:531-535`),
    /// and **the walk's position is the first row of the object the next
    /// read will report**, so a no-op is a no-op on an object boundary and
    /// not one row into a run.
    pub fn advanceTo(self: *Self, target: usize) DocError!void {
        return self.ids.advanceTo(target);
    }

    /// Advances past `amount` rows (`shift.rs:42-47`).
    pub fn advanceBy(self: *Self, amount: usize) DocError!void {
        return self.advanceTo(self.pos() +| amount);
    }

    /// Moves the **window** to `rows` and nothing else
    /// ([`Column.Iterator.shift`](../hexane/column.zig), `column.rs:538-545`).
    pub fn shift(self: *Self, rows: RowRange) void {
        self.setMax(rows.end);
    }

    /// Repositions onto `rows` and reads the first object in it
    /// ([`shift_next`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:56-63`).
    ///
    /// **Two answers, and both are the house rules**: a range past the end of
    /// the window is `null`, and a range that starts behind the cursor is
    /// `error.InvalidValue`
    /// ([`column.zig:3641-3642`](../hexane/column.zig), where upstream
    /// asserts, `shift.rs:13-14`) — a walk that rewound would hand back a row
    /// it has already consumed, and a document walk would count it twice.
    ///
    /// **The guard is written here rather than inherited**, and that is the
    /// one thing this walk cannot delegate: the two object columns raise it
    /// for a **row** ([`opiter.ObjIdIter.shiftNext`](../opset/op_iter.zig),
    /// `op_iter.rs:634-636`), and a run that is collapsed cannot ask a column
    /// for one row and use the answer as an object.
    ///
    /// What is read is the object **at** `rows.start`, and the whole of its
    /// run is consumed; the next read is therefore the object after it. For
    /// the ranges this directory passes — whole objects, from
    /// [`OpSet.scopeToObj`](../opset/op_set.zig) — the object at the start is
    /// the object the range names.
    pub fn shiftNext(self: *Self, rows: RowRange) DocError!?ObjId {
        if (rows.start < self.pos()) return error.InvalidValue;
        self.setMax(rows.end);
        try self.advanceTo(rows.start);
        return self.next();
    }

    /// Consumes through `at` and reads the object it belongs to, or null
    /// behind the cursor and past the end ([`seek_to`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:65-74`).
    ///
    /// **The object, and the whole of it**: the walk stands after the run it
    /// landed in, so the next read is the following object. That is the
    /// module doc's "the unit is an object" rule, and it is worth naming here
    /// because [`ObjIdIter.pos`] after a seek is the *end* of the object the
    /// seek reported — one run further on than a row cursor would leave it,
    /// and never mid-run.
    pub fn seekTo(self: *Self, at: usize) DocError!?ObjId {
        if (at < self.pos()) return null;
        try self.advanceTo(at);
        return self.next();
    }

    // ── The step ───────────────────────────────────────────────────────

    /// The next object, once each, in row order, or null at the end of the
    /// window.
    ///
    /// **The three steps are upstream's three lines**: an object is a run of
    /// equal values in both object columns (rule **R1**,
    /// [`op.zig:2211-2214`](../opset/op.zig), `op_set2/op.rs:1049-1054`), so
    /// the step is "read the row, find the run it belongs to, consume that
    /// run", and the answer is the object when this state has it. The root is
    /// the minimum object and is never skipped.
    ///
    /// **A clock that covers nothing still answers**, and the answer is the
    /// root. Treating a spent cursor as "the walk is over" is the mistake
    /// [`iter/map_range.zig`](map_range.zig)'s test "a map diff whose before
    /// state is empty tags every row an addition" is about, one layer up: a
    /// visibility walk over a clock that covers nothing still walks
    /// ([`visible.zig:192-196`](../opset/visible.zig),
    /// [`iter/tools.rs:373-381`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
    /// and a document walk that answered nothing would report a whole
    /// document as empty.
    pub fn next(self: *Self) DocError!?ObjId {
        while (true) {
            const first = (try self.step()) orelse return null;
            try self.consumeRun(first);
            if (self.covers(first)) return first;
        }
    }

    /// The whole of `first`'s rows, consumed, so the next read is the object
    /// after it.
    ///
    /// **The run comes from the op set's own seek**
    /// ([`ObjIdIter.seekToValue`](../opset/op_iter.zig), `op_iter.rs:616-623`)
    /// and not from comparing rows here, because that is where an object's
    /// rows end for every other reader too — [`OpSet.scopeToObj`](../opset/op_set.zig)
    /// is the same two descents — and a second way to answer it would be a
    /// second source of truth for the same question.
    ///
    /// **The window is restored before anything is consumed through it**,
    /// because the seek leaves both columns widened to the whole op set
    /// ([`op_iter.zig:612-615`](../opset/op_iter.zig)) and a walk may not read
    /// past the rows it was given. The run is then consumed to the *earlier*
    /// of its own end and the window's, so a run the window cuts short is
    /// consumed to the window's end — the object is in the window, so it is
    /// reported, and the rows behind it are not.
    ///
    /// **The seek moves neither cursor in the case this walk reaches it in**,
    /// which is every case: the run starts at or behind the row just read
    /// (rule **R1**, [`op.zig:2211-2214`](../opset/op.zig)), and
    /// `advance_to` is a no-op for a target at or behind the cursor
    /// ([`column.zig:3612-3618`](../hexane/column.zig)). So a run of one row
    /// costs a descent and no rows at all.
    fn consumeRun(self: *Self, first: ObjId) DocError!void {
        const limit = self.ids.maxPos();
        const run = try self.ids.seekToValue(first);
        self.ids.setMax(limit);
        try self.ids.advanceTo(@min(run.end, limit));
    }

    /// The next row's object id, or null at the end of the window
    /// ([`ObjIdIter.shiftNext`](../opset/op_iter.zig), `op_iter.rs:634-636`).
    ///
    /// **The one-row `shiftNext` over the cursor's own window**, because
    /// `opiter.ObjIdIter` has no nullable advance: its `tryNext` is total and
    /// answers `error.MissingValue` where a walk should answer `null`
    /// ([`opiter.zig:619-624`](../opset/op_iter.zig),
    /// [`op_iter.zig:1084-1088`](../opset/op_iter.zig)). Turning that error
    /// into a `null` here would be a reader more permissive than its writer,
    /// so the nullable path is taken instead — `setMax` to the window the
    /// cursor already holds and one `nth` of zero rows
    /// ([`column.zig:3641-3645`](../hexane/column.zig)).
    fn step(self: *Self) DocError!?ObjId {
        return self.ids.shiftNext(.{ .start = self.ids.pos(), .end = self.ids.maxPos() });
    }

    /// Whether `obj` is in the state this walk is narrowed to.
    ///
    /// The module doc's third section is this method: an object's id is its
    /// creating operation's id ([`op_set.zig:1287-1291`](../opset/op_set.zig)),
    /// so the clock covers the object exactly when it covers that operation
    /// (upstream `clock.rs:134-136`, the port's
    /// [`Clock.contains`](../../src/clock.zig) `clock.zig:107-109`), and the
    /// root is the one object no operation created
    /// ([`op_iter.zig:181-188`](../opset/op_iter.zig), `op_iter.rs:217-219,227`).
    fn covers(self: *const Self, obj: ObjId) bool {
        const clock = self.clock orelse return true;
        const created_by = obj.opId() orelse return true;
        return clock.contains(created_by);
    }
};

comptime {
    // **The [`Shiftable`] mark on [`ObjIdIter`] is honest, and every name is
    // reached.** [`column.Shiftable`](../hexane/column.zig) is a comptime
    // check over the eight kernel names (`column.zig:4032-4044`) and *naming
    // the value instantiates it*, so a walk missing one of the eight would not
    // compile. The mark does not check that a **body** compiles, and an
    // uninstantiated body is never analysed. The test "the walk's kernel moves it"
    // calls all eight.
    _ = ObjIdIter.shiftable;
}

// ── The handle ─────────────────────────────────────────────────────────────

/// The handle a document walk runs against: the op set, and how the document
/// measures its text ([`Doc`]).
///
/// **Generic over the op set's row type `O`** and over nothing else, as
/// [`MapRange`](map_range.zig), [`ListRange`](list_range.zig) and
/// [`Spans`](spans.zig) are, because it holds a `*OpSet(O)` and nothing
/// that depends on the row type. A caller whose document holds
/// [`opset/op.zig`](../opset/op.zig)'s `ChangeOp` writes `Doc(ChangeOp)`, and
/// a fixture built on the borrowed `Op` is `Doc(Op)`.
///
/// **Constructing one allocates nothing**: a pointer and an enum. It owns
/// nothing and frees nothing, so it has no `deinit` — it borrows the op set
/// and the caller's clock, and both have to outlive the walks built over it.
pub fn Doc(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The op set every reader this handle hands out reads from, and the
        /// one an exported id is resolved against
        /// ([`DocIter::new`](../iter/doc.zig) reaches it as `doc.ops()`,
        /// `iter/doc.rs:44,100`).
        op_set: *opset.OpSet(O),
        /// How the document measures its text, which the spans reader is the
        /// one consumer of ([`iter/doc.rs:186`](../iter/doc.zig), where
        /// `doc.text_encoding()` goes to `SpansInternal::new` and to the item
        /// export at `iter/doc.rs:301`).
        ///
        /// **It is the document's and not a caller's**, and that is the field's
        /// whole reason to exist: a width read in the wrong encoding is a
        /// reader that looks right and indexes wrong
        /// ([`Spans.init`](spans.zig) is where it is spent).
        text_encoding: types.TextEncoding,

        /// The handle over `op_set`, which measures its text `text_encoding`
        /// ([`DocIter::new`](../iter/doc.zig), `iter/doc.rs:42-50`).
        pub fn init(op_set: *opset.OpSet(O), text_encoding: types.TextEncoding) Self {
            return .{ .op_set = op_set, .text_encoding = text_encoding };
        }

        /// Every object the document holds, as `clock` sees it
        /// ([`OpSet::obj_id_iter`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs),
        /// `op_set.rs:1344-1346`).
        ///
        /// **No allocator**, and the walk it returns owns nothing: two column
        /// cursors and a borrowed clock. A caller that wants the *current*
        /// state passes `null`, which is what a null clock means in every
        /// reader in this directory
        /// ([`MapRange.init`](map_range.zig), `map_range.rs:204-208`).
        pub fn objIdIter(self: *const Self, clock: ?Clock) DocError!ObjIdIter {
            return ObjIdIter.init(try self.op_set.objIdIter(), clock);
        }
    };
}

// ── The document-object diff ────────────────────────────────────────────────
//
// [`DiffIter`] is the second, unrelated type the name `DiffIter` names in
// upstream: [`tools.DiffKernel`](tools.zig) is `iter/tools.rs:529`'s
// `tools::DiffIter`, the row-level kernel every leaf reader is built on, and
// this is `iter/doc.rs:66`'s `doc::DiffIter`, the walk **over objects**. The
// port renamed the first to `DiffKernel` so that this one could keep its
// upstream name; `iter.rs:17` exports this one, which is the name that
// upstream's `automerge.rs` and `autocommit.rs` mean.
//
// **Every upstream caller of this walk is patch building** — `automerge.rs:1078`
// (`log_current_state`), `:1423` (`diff`), `:1454` (`diff_obj`), and
// `autocommit.rs:300` and `:822` (`diff_inner` and `patch_to`) — which is why
// [`log`](DiffIter.log) is the entry point and the iterator is not the point.
// It is not a second source of truth for `iter/spans.zig`'s span diff: that is
// a **row-range** diff answering "what changed in these rows", and this is a
// **document-object** diff answering "which objects changed, and what is each
// one's diff". The two meet only here, where this one hands a row range to
// [`spans.SpansDiff`].

/// Which of the three readers an object is walked with ([`IterType`],
/// `iter/doc.rs`:271-286`).
///
/// **Not [`types.ObjType`], and the mapping is not the identity.** Upstream's
/// three arms come from its `ObjType`, which has no `Table`; the port's has
/// one, and `_ => IterType::List` (`iter/doc.rs`:282-283`) sends it to the
/// **list** reader. Tables are maps upstream — `types.ObjType`'s own note says
/// so — and are read as sequences here, which is upstream's answer and not a
/// port correction.
pub const IterType = enum { map, list, text };

fn iterTypeOf(typ: types.ObjType) IterType {
    return switch (typ) {
        .text => .text,
        .map => .map,
        else => .list,
    };
}

/// A nested object this walk found, and how to read it
/// (`Option<(ObjId, IterType)>`, `iter/doc.rs`:415-446`).
pub const MadeObj = struct {
    /// The object the row named.
    obj: ObjId,
    /// Which reader reads it.
    typ: IterType,
};

/// One changed property of one object ([`DocObjDiffItem`], `iter/doc.rs`:328-332`).
pub fn DocObjDiffItem(comptime O: type) type {
    return struct {
        /// The object the property is on.
        obj: ObjId,
        /// What changed on it.
        item: DiffItem(O),
    };
}

/// One changed property, tagged with the arm of the walk it came from
/// ([`DocDiffItem`], `iter/doc.rs`:390-394`).
///
/// **Three arms and not one**, because the three readers report three shapes
/// and a caller has to know which it got: upstream's enum is the join point,
/// not an optimisation.
pub fn DiffItem(comptime O: type) type {
    return union(enum) {
        const Self = @This();

        /// A map register ([`maprange.MapDiffItem`](map_range.zig), `iter/doc.rs`:391`).
        map: maprange.MapDiffItem(O),
        /// A sequence element ([`listrange.ListDiffItem`](list_range.zig), `iter/doc.rs`:392`).
        list: listrange.ListDiffItem(O),
        /// A text span ([`spans.SpanDiff`](spans.zig), `iter/doc.rs:393`).
        ///
        /// **The only arm of the three that owns anything, and so the only one
        /// a caller has to give back.** The run's bytes and the exported mark
        /// set come out of the allocator the walk was built with, and
        /// [`SpanDiff.deinit`](spans.zig) returns them — which in a loop over
        /// [`DiffIter.next`] reads
        /// `switch (item.item) { .text => |*t| t.deinit(gpa), else => {} }`,
        /// with `gpa` the walk's own [`DiffIter.gpa`]. **The `map` and `list`
        /// arms own nothing**: their key, op id and value point into the op
        /// set's string table and value column and stay valid until the next
        /// mutation of the document, and releasing them would be wrong.
        ///
        /// **Detached is not the same as independent.** The span's *bytes* are
        /// its own and outlive the walk; its mark *names* are the document's
        /// interned strings and are not freed with it, and the block arm's
        /// [`maprange.ExIdPromise`](map_range.zig) still holds the op set it
        /// will resolve against. So a released span shortens nobody else's
        /// life, and a retained one still does not outlive the document.
        text: spans.SpanDiff(O),

        /// The property this item sits at ([`DocDiffItem::prop`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:401-414`).
        ///
        /// **The key is borrowed** from the document's string table, and this is
        /// why [`DiffIter.processItem`] may only keep it for as long as the walk.
        pub fn prop(self: *const Self) Prop {
            return switch (self.*) {
                .map => |m| .{ .key = m.key },
                .list => |l| .{ .index = l.index },
                .text => |t| .{ .index = switch (t.span) {
                    .obj => |o| o.index,
                    .text => |x| x.index,
                } },
            };
        }

        /// The object this item puts or inserts, and how to read it
        /// ([`DocDiffItem::make_obj`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:415-446`).
        ///
        /// **Three guards, and all three are load-bearing.** A row only names
        /// an object if its value *is* one (`ValueRef::Object`), and only if the
        /// diff is **visible**: a deleted register names the object it used to
        /// hold, and descending into it would report changes to an object the
        /// after state does not have. A text block marker is always read as a
        /// **map** (`iter/doc.rs:441`), which is what
        /// [`patch_log.rs:747`](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs)
        /// hard-codes on the other side.
        pub fn makeObj(self: *const Self) ?MadeObj {
            return switch (self.*) {
                .map => |m| if (m.diff.isVisible() and m.value.isObject())
                    .{ .obj = .{ .id = m.id }, .typ = iterTypeOf(m.value.object) }
                else
                    null,
                .list => |l| if (l.diff.isVisible() and l.value.isObject())
                    .{ .obj = .{ .id = l.id }, .typ = iterTypeOf(l.value.object) }
                else
                    null,
                .text => |t| if (t.diff.isVisible()) switch (t.span) {
                    .obj => |o| .{ .obj = .{ .id = o.id.id }, .typ = .map },
                    .text => null,
                } else null,
            };
        }
    };
}

/// What a document diff can raise.
///
/// The leaf reader errors plus recursive block/mark hydration errors.
/// Returned spans are detached using the same iterator allocator and scope;
/// allocation and hydration failures remain typed rather than suppressed.
pub const DiffError = maprange.ReadError || hydrate.OpHydrateError;

// ── The queue ───────────────────────────────────────────────────────────────

/// The objects a recursive walk still owes a visit
/// (`BTreeMap<ObjId, IterType>`, [`iter/doc.rs:55`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)
/// and `:68`).
///
/// **An ordered array and not a map, and the order is the whole point**:
/// upstream's `pop_first` ([`iter/doc.rs:243`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
/// `:137`) always takes the **lowest** id, which is what puts a parent before
/// its children and an early-created sibling before a late-created one. The
/// queue holds only the objects *this* walk has named and not yet visited, so
/// the linear minimum below is bounded by the number of outstanding children
/// — and the alternative, a second ordered map, is not worth a comparison per
/// pop.
///
/// **One type and two users**, [`DiffIter`] and [`DocIterInternal`], because
/// the order is a rule about this file's answers and a rule with two copies
/// is one of them able to drift.
pub const ObjQueue = struct {
    const Self = @This();

    /// The allocator the queue is taken with and given back with.
    gpa: Allocator,
    /// The objects, **in no order at all**: one is appended as each parent is
    /// read, and the minimum is taken out of them one at a time.
    items: std.ArrayList(MadeObj) = .empty,

    /// A queue over `gpa`, holding nothing ([`BTreeMap::new`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
    /// `iter/doc.rs:187,197`).
    pub fn init(gpa: Allocator) Self {
        return .{ .gpa = gpa };
    }

    /// Gives back the queue's own buffer. **The objects in it are values** —
    /// an id and an enum — and own nothing, so there is nothing else to free.
    /// **The queue is unusable once this returns**: `self.* = undefined` is
    /// the last line, so a second call reads undefined memory rather than
    /// reaching an allocator that could diagnose the double free.
    pub fn deinit(self: *Self) void {
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    /// Records that `nested` owes a visit (`next_objs.insert`,
    /// `iter/doc.rs:216,127`).
    pub fn push(self: *Self, nested: MadeObj) Allocator.Error!void {
        return self.items.append(self.gpa, nested);
    }

    /// The lowest queued id, removed (`BTreeMap::pop_first`,
    /// `iter/doc.rs:252,146`).
    ///
    /// **The minimum and not the maximum, and the whole of the walk's order
    /// rests on it.** Two tests in this file fail if this takes the largest:
    /// the diff walk's ("the document diff reads the root's rows and then
    /// descends into each child, in order") and the item walk's ("the
    /// recursive walk reads the root's rows, then every child, parents before
    /// children"). A walk that visits a later child first yields the same
    /// **set** of items in a different **sequence**, so neither test would
    /// notice if it counted them instead of comparing them in order.
    pub fn popLowest(self: *Self) ?MadeObj {
        if (self.items.items.len == 0) return null;
        var at: usize = 0;
        for (self.items.items[1..], 1..) |candidate, i| {
            const candidate_id = candidate.obj.opId();
            const current_id = self.items.items[at].obj.opId();
            const order: std.math.Order = if (candidate_id) |id|
                if (current_id) |current| id.order(current) else .gt
            else if (current_id == null) .eq else .lt;
            if (order == .lt) at = i;
        }
        return self.items.orderedRemove(at);
    }
};

/// The walk over the objects a diff touched, one reader per object type
/// ([`DiffIter`], `iter/doc.rs`:66-76`).
///
/// **One arm per object type, not one per object.** The three readers are
/// constructed once over the starting object's rows and repositioned with
/// `shiftNext` each time the walk moves to another object (`iter/doc.rs:99-115`,
/// `:141-147`); an object is walked by draining the arm its `IterType` names.
///
/// `gpa` is first because two of the arms allocate: [`spans.SpansDiff`] owns a
/// mark fold and a run buffer, and the queue and the path map below are
/// appended to.
pub fn DiffIter(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The allocator the span fold, the queue and the path map are taken
        /// with, and the one [`deinit`](Self.deinit) frees with.
        gpa: Allocator,
        /// The objects this walk still owes a visit, **taken lowest id first**
        /// (`BTreeMap<ObjId, IterType>`, `iter/doc.rs`:67`), which is what
        /// makes the patches come out in id order.
        next_objs: ObjQueue,
        /// Where each nested object the diff surfaced lives
        /// (`BTreeMap<ObjId, (Prop, ObjId)>`, `iter/doc.rs:68`).
        ///
        /// **The walk's own, and empty until an item names a nested object.**
        /// [`log`](Self.log) **moves this field out to its caller and leaves
        /// it empty**, so from that call on one allocation has exactly one
        /// owner; a caller that drives [`next`](Self.next) instead finds the
        /// map here.
        path_map: patches.PathMap = .{},
        /// The object walk, positioned just past the starting object's rows.
        obj_id_iter: ObjIdIter,
        /// The map reader, repositioned onto each map object in turn
        /// (`iter/doc.rs:70`).
        map_iter: maprange.MapDiff(O),
        /// The list reader (`iter/doc.rs:71`).
        list_iter: listrange.ListDiff(O),
        /// The text reader (`iter/doc.rs:72`).
        span_iter: spans.SpansDiff(O),
        /// Which arm the current object is read with (`iter/doc.rs:75`).
        iter_type: IterType,
        /// Whether a nested object is descended into (`iter/doc.rs:74`).
        recursive: bool,
        /// The object the walk is currently reading (`iter/doc.rs:76`).
        obj: ObjId,

        /// How the document measures its text, which is what a spliced span's
        /// width and a deleted span's length are counted in (`spans.rs:40-41`).
        text_encoding: TextEncoding,

        /// A diff over `obj`, between the states `over` names
        /// ([`DiffIter::new`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:94-124`).
        ///
        /// **`obj_id_iter` is given no clock**, which is upstream's
        /// `op_set.obj_id_iter()` (`iter/doc.rs:101`): the object walk sees
        /// **every** object the op set holds, because the narrowing that
        /// matters is the one the three readers do, and an object that exists
        /// in only one of the two states still has to be *visited* to be
        /// reported.
        pub fn init(
            gpa: Allocator,
            doc: *const Doc(O),
            obj: ObjId,
            typ: types.ObjType,
            over: ClockRange,
            recursive: bool,
        ) DiffError!Self {
            const set = doc.op_set;
            var obj_id_iter = ObjIdIter.init(try set.objIdIter(), null);
            const resolved = set.resolveObjId(obj);
            const scope: RowRange = if (resolved) |internal|
                try obj_id_iter.ids.seekToValue(internal)
            else
                .{ .start = 0, .end = 0 };
            return .{
                .gpa = gpa,
                .next_objs = ObjQueue.init(gpa),
                .text_encoding = doc.text_encoding,
                .obj_id_iter = obj_id_iter,
                .map_iter = try maprange.MapDiff(O).init(set, scope, over),
                .list_iter = try listrange.ListDiff(O).init(set, scope, over),
                .span_iter = try spans.SpansDiff(O).init(gpa, set, scope, over, doc.text_encoding),
                .iter_type = iterTypeOf(typ),
                .recursive = recursive,
                .obj = resolved orelse obj,
            };
        }

        /// Gives back the span fold's buffers, the queue and **whatever path
        /// map the walk still holds** — which is all of
        /// [`path_map`](Self.path_map) unless [`log`](Self.log) has already
        /// moved it out.
        ///
        /// **The walk is unusable once this returns**: `self.* = undefined` is
        /// the last line, so a second call reads undefined memory rather than
        /// reaching an allocator that could diagnose the double free.
        /// **Everything the walk has already handed out belongs to the caller** —
        /// a [`DocObjDiffItem`], text arm included, and a path map
        /// [`log`](Self.log) returned — and none of it is touched here.
        pub fn deinit(self: *Self) void {
            self.span_iter.deinit();
            self.next_objs.deinit();
            self.path_map.deinit(self.gpa);
            self.* = undefined;
        }

        /// Walks the whole diff, writing every event into `sink`, and returns
        /// where each nested object it surfaced lives
        /// ([`DiffIter::log`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:79-92`).
        ///
        /// `sink` is a runtime value whose inferred type is checked at comptime.
        /// Its container must provide `putMap`, `incrementMap`, `flagConflict`,
        /// `deleteMap`, `putSeq`, `insertAndMaybeExpose`, `incrementSeq`,
        /// `deleteSeq`, `splice` and `mark`, with `PatchLog`'s parameter and
        /// return types apart from the receiver. The receiver may be the
        /// container value or its mutable or const pointer.
        /// Argument slices are borrowed for each callback; copy them before
        /// returning if the sink retains them. Callbacks return `void`, so
        /// sink failures use the sink's own channel (`PatchLog.failed`).
        /// A walk error may leave both the walk and sink progressed; the path
        /// map stays owned by the walk on that path.
        ///
        /// **The returned [`patches.PathMap`] is upstream's second half of the
        /// return value (`iter/doc.rs:92`), and it is this walk's own — moved
        /// out, not copied.** [`path_map`](Self.path_map) is emptied before
        /// this returns, so from that call on one allocation has exactly one
        /// owner: hand it to [`patches.PatchLog.pathHint`], which takes it over
        /// and frees the log's previous map in its place, or free it with
        /// [`patches.PathMap.deinit`] and this walk's [`gpa`](Self.gpa).
        /// **Returning a copy is what would name one allocation twice** — this
        /// walk's [`deinit`](Self.deinit) and the caller's would both free it —
        /// and upstream's `log` returns a map it owns alone (`iter/doc.rs:91-92`).
        ///
        /// **A caller that throws the map away still has to free it**, as
        /// upstream's two do (`automerge.rs:1423`, `:1454`): the walk no longer
        /// holds it. [`Document.patchTo`](../../src/doc.zig) is that caller, and
        /// the port's [`patches.PatchLog`] builds the same map lazily in
        /// `getPathMap` when it needs one.
        pub fn log(self: *Self, sink: anytype) DiffError!patches.PathMap {
            comptime {
                const P = @TypeOf(sink);
                const Sink = switch (@typeInfo(P)) {
                    .pointer => |p| p.child,
                    else => P,
                };
                switch (@typeInfo(Sink)) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => {},
                    else => @compileError("DiffIter.log requires a sink container"),
                }
                for (.{ "putMap", "incrementMap", "flagConflict", "deleteMap", "putSeq", "insertAndMaybeExpose", "incrementSeq", "deleteSeq", "splice", "mark" }) |name| {
                    if (!@hasDecl(Sink, name)) @compileError("DiffIter.log sink is missing " ++ name);
                    const info = @typeInfo(@TypeOf(@field(Sink, name)));
                    if (info != .@"fn") @compileError("DiffIter.log sink " ++ name ++ " must be a function");
                    const got = info.@"fn";
                    const want = @typeInfo(@TypeOf(@field(patches.PatchLog, name))).@"fn";
                    if (got.is_generic or got.attrs.varargs or got.param_types.len != want.param_types.len or got.return_type != want.return_type) {
                        @compileError("DiffIter.log sink " ++ name ++ " has an incompatible signature");
                    }
                    const receiver = got.param_types[0].?;
                    if (receiver != Sink and receiver != *Sink and receiver != *const Sink) {
                        @compileError("DiffIter.log sink " ++ name ++ " has an incompatible receiver");
                    }
                    for (got.param_types[1..], want.param_types[1..]) |actual, expected| {
                        if (actual != expected) @compileError("DiffIter.log sink " ++ name ++ " has an incompatible parameter");
                    }
                }
            }
            const enc = self.text_encoding;
            while (try self.next()) |got| {
                // **`var`, because the text arm frees what it read.** The span
                // owns its buffer ([`SpanInternal`], `spans.rs:403-407`), and
                // this walk allocated it, so nobody below here is going to.
                var item = got;
                switch (item.item) {
                    .map => |m| logMapItem(m, item.obj, sink, enc),
                    .list => |l| logListItem(l, item.obj, sink, enc),
                    .text => |*t| {
                        logSpanItem(t.*, item.obj, sink, enc);
                        t.deinit(self.gpa);
                    },
                }
            }
            // **Moved, and not copied.** `PathMap` holds its array by value, so
            // returning the field unchanged would hand the caller a second name
            // for one allocation — and `deinit` frees it. After this the walk
            // holds nothing, and the caller owns the map.
            const out = self.path_map;
            self.path_map = .{};
            return out;
        }

        /// The next changed property, or null at the end of the diff
        /// ([`Iterator::next` for `DiffIter`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:306-315`).
        ///
        /// **Drain this object, then move to the next, and keep moving until
        /// one of them has something.** The loop is upstream's
        /// (`iter/doc.rs:309-314`): an object the queue names can turn out to
        /// hold nothing that changed, and `next_object` answers that with
        /// `Some(None)`, which is not the end of the walk.
        ///
        /// **A `.text` item is the caller's, and it is the only arm with
        /// anything to release.** The span's bytes and its exported mark set
        /// come from this walk's [`gpa`](Self.gpa) and nothing below here frees
        /// them, so a caller driving this method owes
        /// `switch (item.item) { .text => |*t| t.deinit(it.gpa), else => {} }`
        /// for every item it takes — which is exactly what
        /// [`log`](Self.log) does with its own. **The `map` and `list` arms own
        /// nothing** and are not released; what they borrow from the document
        /// lasts until the next mutation of it. [`DiffItem.text`] is the whole
        /// of it.
        pub fn next(self: *Self) DiffError!?DocObjDiffItem(O) {
            if (try self.nextProp()) |item| return item;
            while (self.next_objs.popLowest()) |queued| {
                if (try self.nextObject(queued)) |item| return item;
            }
            return null;
        }

        /// Records where a nested object lives, and queues it
        /// ([`DiffIter::process_item`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:119-129`).
        ///
        /// **The path entry is unconditional and the queue is not**: upstream
        /// inserts into `path_map` whether or not `recursive` is set
        /// (`iter/doc.rs:126-128`), because a path is needed to *name* an
        /// object's patches even when its own patches are not wanted, and only
        /// the descent is optional (`iter/doc.rs:125`).
        fn processItem(self: *Self, item: DiffItem(O)) DiffError!DocObjDiffItem(O) {
            if (item.makeObj()) |nested| {
                const prop = item.prop();
                if (self.recursive) try self.next_objs.push(nested);
                try self.path_map.put(self.gpa, .{
                    .obj = nested.obj,
                    .prop = prop,
                    .parent = self.obj,
                });
            }
            return .{ .obj = self.obj, .item = item };
        }

        /// Repositions the three readers onto the next queued object
        /// ([`DiffIter::next_object`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:135-147`).
        ///
        /// **The lowest queued id**, because `BTreeMap::pop_first` takes it
        /// (`iter/doc.rs:146`) and the patches sort by object id. An object
        /// whose rows the op set does not hold — a row the diff named but the
        /// walk cannot scope — is skipped and the search continues, which is
        /// upstream's `if next_range.is_empty() { Some(None) }` (`iter/doc.rs:147`).
        fn nextObject(self: *Self, queued: MadeObj) DiffError!?DocObjDiffItem(O) {
            const rows = try self.obj_id_iter.ids.seekToValue(queued.obj);
            if (rows.start >= rows.end) return null;
            var item: DiffItem(O) = switch (queued.typ) {
                .map => .{ .map = (try self.map_iter.shiftNext(rows)) orelse return null },
                .list => .{ .list = (try self.list_iter.shiftNext(rows)) orelse return null },
                .text => .{ .text = (try self.span_iter.shiftNext(rows)) orelse return null },
            };
            // **The queue append and the path-map insert can both fail, and
            // this item is the only thing in the block that owns anything** —
            // the same guard [`DocIterInternal.nextObject`] carries, so that
            // "it either escapes or is released" is true of both walks and not
            // of one. **It frees nothing on the only failure path there is
            // today**: the one arm [`DiffItem.makeObj`] can name an object by
            // is a block marker, and a block marker owns no bytes. It is here
            // for a text arm that does own something.
            errdefer switch (item) {
                .text => |*t| t.deinit(self.gpa),
                else => {},
            };
            self.obj = queued.obj;
            self.iter_type = queued.typ;
            return try self.processItem(item);
        }

        /// The next changed property of the object the walk is on
        /// ([`DiffIter::next_prop`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:149-161`).
        fn nextProp(self: *Self) DiffError!?DocObjDiffItem(O) {
            var item: DiffItem(O) = switch (self.iter_type) {
                .map => .{ .map = (try self.map_iter.next()) orelse return null },
                .list => .{ .list = (try self.list_iter.next()) orelse return null },
                .text => .{ .text = (try self.span_iter.next()) orelse return null },
            };
            // The same guard, and for the same reason, as
            // [`nextObject`](Self.nextObject)'s.
            errdefer switch (item) {
                .text => |*t| t.deinit(self.gpa),
                else => {},
            };
            return try self.processItem(item);
        }
    };
}

// ── The recursive document walk ─────────────────────────────────────────────
//
// **Upstream's `DocIter` and this file's [`DiffIter`] are two types that read
// the same document and are not variants of each other**, and the difference
// is in what each reader reports: this half is built over the *range* readers
// — [`MapRange`](map_range.zig), [`ListRange`](list_range.zig) and
// [`SpansInternal`](spans.zig) — where [`DiffIter`] is built over the diff
// readers. Upstream keeps the two item enums apart for the same reason
// ([`iter/doc.rs:382-401`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)),
// and so does the port.

/// One property of one object, as a leaf reader saw it and before it is
/// exported ([`DocItemInternal`],
/// [`iter/doc.rs:389-394`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)).
pub fn DocItemInternal(comptime O: type) type {
    return union(enum) {
        const Self = @This();

        /// A map register ([`MapRangeItem`](map_range.zig), `iter/doc.rs`:390`).
        map: maprange.MapRangeItem(O),
        /// A sequence element ([`ListRangeItem`](list_range.zig), `iter/doc.rs`:391`).
        list: listrange.ListRangeItem(O),
        /// A span of a text object, **not yet exported**
        /// ([`SpanInternal`](spans.zig), `iter/doc.rs`:392`).
        text: spans.SpanInternal(O),

        /// The item a caller reads ([`DocItemInternal::export`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:464-474`) — **named `exportItem` and not `export`
        /// because `export` is a Zig keyword**, the same rename
        /// [`MapDiffItem.exportItem`](map_range.zig) carries for the same
        /// reason.
        ///
        /// Map and list arms remain borrowed. Text storage moves on success;
        /// block maps and marks are detached through the supplied source set
        /// and clock (`spans.rs:605-627`). Failure leaves the internal item
        /// owned by its caller, which must deinitialize it.
        pub fn exportItem(self: Self, gpa: Allocator, set: *opset.OpSet(O), clock: ?Clock) DiffError!DocItem(O) {
            return switch (self) {
                .map => |m| DocItem(O){ .map = m },
                .list => |l| DocItem(O){ .list = l },
                .text => |t| DocItem(O){ .text = try t.exportSpan(gpa, set, clock) },
            };
        }

        /// The object this item puts or inserts, and how to read it
        /// ([`DocItemInternal::make_obj`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:475-499`).
        ///
        /// **No visibility test, and that is the whole difference from
        /// [`DiffItem.makeObj`]**: upstream's arms are guarded by
        /// `diff.is_visible()` (`iter/doc.rs:419,428,437`) because a *diff*
        /// item names the value a register used to hold, while these three
        /// readers only ever hand out **visible** rows. A register whose winner
        /// is a delete is not a row this walk reads at all, so a deleted
        /// object is never queued — which is the rule `iter/doc.rs:437` states
        /// by not stating it again.
        ///
        /// A text **block marker** is read as a map (`iter/doc.rs:490`), the
        /// same reading [`patch_log.rs:747`](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs)
        /// hard-codes on the other side.
        pub fn makeObj(self: *const Self) ?MadeObj {
            return switch (self.*) {
                .map => |m| if (m.value.isObject())
                    .{ .obj = .{ .id = m.maybe_exid.id }, .typ = iterTypeOf(m.value.object) }
                else
                    null,
                .list => |l| if (l.value.isObject())
                    .{ .obj = .{ .id = l.maybe_exid.id }, .typ = iterTypeOf(l.value.object) }
                else
                    null,
                .text => |t| switch (t) {
                    .obj => |o| .{ .obj = .{ .id = o.id.id }, .typ = .map },
                    .text => null,
                },
            };
        }

        /// Gives back the run's bytes and its mark set, if this item is one.
        /// The map and list arms borrow and own nothing.
        /// **The item is unusable once this returns**: `self.* = undefined` is
        /// the last line, so a second call reads undefined memory rather than
        /// reaching an allocator that could diagnose the double free.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            switch (self.*) {
                .text => |*t| t.deinit(gpa),
                else => {},
            }
            self.* = undefined;
        }
    };
}

/// One property of one object, as a caller reads it ([`DocItem`],
/// [`iter/doc.rs:383-387`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)).
pub fn DocItem(comptime O: type) type {
    return union(enum) {
        const Self = @This();

        /// A map register ([`MapRangeItem`](map_range.zig), `iter/doc.rs`:384`).
        map: maprange.MapRangeItem(O),
        /// A sequence element ([`ListRangeItem`](list_range.zig), `iter/doc.rs`:385`).
        list: listrange.ListRangeItem(O),
        /// A span of a text object ([`Span`](spans.zig), `iter/doc.rs`:386`).
        text: spans.Span,

        /// The row this item was read from, and **null for a text span**
        /// ([`DocItem::id`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:508-516`).
        pub fn id(self: *const Self) ?ObjId {
            return switch (self.*) {
                .map => |m| m.id(),
                .list => |l| l.id(),
                .text => null,
            };
        }

        /// The value this item carries, and **null for a text span**
        /// ([`DocItem::value`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:518-526`).
        ///
        /// **A span's text is not here**, and that is upstream's: it is
        /// reached through [`DocObjItem.value`], which has a third arm for it
        /// (`iter/doc.rs:377`).
        pub fn value(self: *const Self) ?ValueRef {
            return switch (self.*) {
                .map => |m| m.value,
                .list => |l| l.value,
                .text => null,
            };
        }
    };
}

/// One property of one object, as the internal walk reads it
/// ([`DocObjItemInternal`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
/// `iter/doc.rs`:342-346`).
pub fn DocObjItemInternal(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The object the property is **on** — the parent, not the object the
        /// value names (`iter/doc.rs`:344`, and `iter/doc.rs:364` for the
        /// exported form).
        obj: ObjId,
        /// What was read off it.
        item: DocItemInternal(O),

        /// Gives back the span this item read, if it is one. The map and list
        /// arms borrow the document and own nothing.
        /// **The item is unusable once this returns**, as every other `deinit`
        /// here is: `self.* = undefined` is the last line, and a second call
        /// reads undefined memory rather than reaching an allocator.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.item.deinit(gpa);
            self.* = undefined;
        }
    };
}

/// One property of one object, as a caller reads it ([`DocObjItem`],
/// [`iter/doc.rs:336-341`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)).
pub fn DocObjItem(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The object the property is **on** — the parent, which is what
        /// `iter/doc.rs:338` documents and what a patch built from this walk
        /// needs (`iter/doc.rs:237`). **Upstream's `Arc<ExId>` and this
        /// file's [`ObjId`], which is the same type** (see
        /// [`types.ExId`](../types.zig)) without the refcount.
        obj: ObjId,
        /// What is on it.
        item: DocItem(O),

        /// The key this property hangs by, and **null for anything that is not
        /// a map register** ([`DocObjItem::key`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:365-371`).
        pub fn key(self: *const Self) ?[]const u8 {
            return switch (self.item) {
                .map => |m| m.key,
                .list, .text => null,
            };
        }

        /// The value this property carries, **including a span's text**
        /// ([`DocObjItem::value`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:373-380`).
        ///
        /// **Not upstream's `Option`, and not a copy**: upstream's text arm is
        /// `ValueRef::str(span.as_str()).into_owned()` (`iter/doc.rs:377`),
        /// which allocates because a Rust `ValueRef<'a>` has one lifetime for
        /// both "borrowed from the op set" and "borrowed from this span". Here
        /// the span *is* the borrow — the returned slice points into
        /// `self.item.text` and lives as long as the item does — so the answer
        /// is a [`ValueRef`] with nothing owned and nothing to free, and every
        /// arm has a value, which is why upstream's `Option` is always
        /// `Some`.
        pub fn value(self: *const Self) ValueRef {
            return switch (self.item) {
                .map => |m| m.value,
                .list => |l| l.value,
                // **A block marker reads as the replacement character, and
                // not as an empty string** — `asStr` is what upstream's
                // `span.as_str()` hands over, and it answers U+FFFC for a
                // block ([`spans.zig`](spans.zig)).
                .text => |t| .{ .scalar = .{ .str = t.asStr() } },
            };
        }

        /// Copies every value payload, including text span bytes, into an
        /// independent owner (`iter/doc.rs:373-380`). The result survives
        /// releasing the item or document; OOM leaves the item unchanged.
        pub fn valueOwned(self: *const Self, gpa: Allocator) !optypes.OwnedValueRef {
            return self.value().intoOwned(gpa);
        }

        /// Gives back the span this item carries, if it carries one. The map
        /// and list arms borrow the document and own nothing. **The item is
        /// unusable once this returns**: `self.* = undefined` is the last line,
        /// so a second call reads undefined memory rather than reaching an
        /// allocator — and the document is untouched, so a released span leaves
        /// the mark names the next item borrows valid.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            switch (self.item) {
                .text => |*t| t.deinit(gpa),
                else => {},
            }
            self.* = undefined;
        }
    };
}

/// The walk itself, with the export left to [`DocIter`]
/// ([`DocIterInternal`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
/// `iter/doc.rs`:53-63`, walked at `:321-334`).
///
/// **Upstream splits the walk in two and the split is not arbitrary**: the
/// internal half holds ids and unexported items and is what the patch layer
/// would borrow, and [`DocIter`] wraps it to resolve ids and export one item
/// at a time. The port keeps both, because a caller that wants the raw walk —
/// a patch builder, or a test that wants an item's `ObjId` rather than an
/// `ExId` — is upstream's own caller and not a hypothetical one.
pub fn DocIterInternal(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The allocator the spans fold and the queue are taken with, and the
        /// one [`deinit`](Self.deinit) frees with.
        gpa: Allocator,
        /// The objects this walk still owes a visit, **taken lowest id first**
        /// (`iter/doc.rs`:55`).
        next_objs: ObjQueue,
        /// The object walk, positioned just past the starting object's rows
        /// (`iter/doc.rs`:57`).
        obj_id_iter: ObjIdIter,
        /// The map reader, repositioned onto each map object in turn
        /// (`iter/doc.rs`:58`).
        map_iter: maprange.MapRange(O),
        /// The list reader (`iter/doc.rs`:59`).
        list_iter: listrange.ListRange(O),
        /// The text reader (`iter/doc.rs`:60`).
        span_iter: spans.SpansInternal(O),
        /// Which arm the current object is read with (`iter/doc.rs`:62`).
        iter_type: IterType,
        /// The object the walk is currently reading (`iter/doc.rs`:63`).
        obj: ObjId,

        /// The walk over `obj`'s rows, as the state `clock` names sees them,
        /// descending into every object its visible items name
        /// ([`DocIterInternal::new`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:178-198`).
        ///
        /// **`obj_id_iter` is given no clock**, which is upstream's
        /// `op_set.obj_id_iter()` (`iter/doc.rs:181`): the narrowing that
        /// matters is the one the three readers do, and a child is queued only
        /// by an item one of them handed out.
        ///
        /// **A null clock means the present**, and the three readers agree on
        /// that spelling independently — `MapRange` and `ListRange` take
        /// `Option<Clock>` and `SpansInternal` turns null into
        /// `ClockRange::current(null)` (`spans.rs:276`), which is what makes
        /// the fast arm of its action lookup reachable.
        pub fn init(
            gpa: Allocator,
            doc: *const Doc(O),
            obj: ObjId,
            typ: types.ObjType,
            clock: ?Clock,
        ) DiffError!Self {
            const set = doc.op_set;
            var obj_id_iter = ObjIdIter.init(try set.objIdIter(), null);
            const resolved = set.resolveObjId(obj);
            const scope: RowRange = if (resolved) |internal|
                try obj_id_iter.ids.seekToValue(internal)
            else
                .{ .start = 0, .end = 0 };
            return .{
                .gpa = gpa,
                .next_objs = ObjQueue.init(gpa),
                .obj_id_iter = obj_id_iter,
                .map_iter = try maprange.MapRange(O).init(set, scope, clock),
                .list_iter = try listrange.ListRange(O).init(set, scope, clock, .all()),
                .span_iter = try spans.SpansInternal(O).init(gpa, set, scope, clock, doc.text_encoding),
                .iter_type = iterTypeOf(typ),
                .obj = resolved orelse obj,
            };
        }

        /// Gives back the spans fold's buffers and the queue. **The items
        /// already handed out are the caller's** and are not touched here.
        /// **The walk is unusable once this returns**: `self.* = undefined` is
        /// the last line, so a second call reads undefined memory rather than
        /// reaching an allocator that could diagnose the double free.
        pub fn deinit(self: *Self) void {
            self.span_iter.deinit();
            self.next_objs.deinit();
            self.* = undefined;
        }

        /// The next item of the document, or null at the end of it
        /// ([`Iterator::next` for `DocIterInternal`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:321-334`).
        ///
        /// **Drain this object, then move to the next, and keep moving until
        /// one of them has something** — upstream's loop at `iter/doc.rs:328-333`.
        /// An object the queue names can hold nothing at all (a map created
        /// and never written to has no rows), and `nextObject` answers that
        /// with null, which is **not** the end of the walk: the outer
        /// `Option` in upstream's `Option<Option<DocObjItemInternal>>`
        /// (`iter/doc.rs:239-252`) is what says so.
        pub fn next(self: *Self) DiffError!?DocObjItemInternal(O) {
            if (try self.nextProp()) |item| return item;
            while (self.next_objs.popLowest()) |queued| {
                if (try self.nextObject(queued)) |item| return item;
            }
            return null;
        }

        /// Queues the object this item names, if it names one
        /// ([`DocIterInternal::process_item`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:212-220`).
        ///
        /// **The queue is the only thing upstream records here.** Its
        /// `path_map.insert` on the next line (`iter/doc.rs:218`) is not
        /// ported, and the module doc says why: nothing in the crate reads
        /// that field.
        fn processItem(self: *Self, item: DocItemInternal(O)) DiffError!DocObjItemInternal(O) {
            if (item.makeObj()) |nested| try self.next_objs.push(nested);
            return .{ .obj = self.obj, .item = item };
        }

        /// Repositions the three readers onto the next queued object
        /// ([`DocIterInternal::next_object`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:243-256`).
        ///
        /// **The lowest queued id**, because `BTreeMap::pop_first` takes it
        /// (`iter/doc.rs:252`). An object whose rows the op set does not hold
        /// — an object created and never written to, which is most of what
        /// upstream's own test document is — is skipped and the search
        /// continues, which is upstream's
        /// `if next_range.is_empty() { Some(None) }` (`iter/doc.rs:247`).
        fn nextObject(self: *Self, queued: MadeObj) DiffError!?DocObjItemInternal(O) {
            const rows = try self.obj_id_iter.ids.seekToValue(queued.obj);
            if (rows.start >= rows.end) return null;
            var item: DocItemInternal(O) = switch (queued.typ) {
                .map => .{ .map = (try self.map_iter.shiftNext(rows)) orelse return null },
                .list => .{ .list = (try self.list_iter.shiftNext(rows)) orelse return null },
                .text => .{ .text = (try self.span_iter.shiftNext(rows)) orelse return null },
            };
            // **The span owns its bytes and the queue append can fail**, so
            // the only way this item does not escape this block is by handing
            // it over. Upstream's `String` is dropped on the same path.
            errdefer item.deinit(self.gpa);
            self.obj = queued.obj;
            self.iter_type = queued.typ;
            return try self.processItem(item);
        }

        /// The next item of the object the walk is on
        /// ([`DocIterInternal::next_prop`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:258-272`).
        fn nextProp(self: *Self) DiffError!?DocObjItemInternal(O) {
            var item: DocItemInternal(O) = switch (self.iter_type) {
                .map => .{ .map = (try self.map_iter.next()) orelse return null },
                .list => .{ .list = (try self.list_iter.next()) orelse return null },
                .text => .{ .text = (try self.span_iter.next()) orelse return null },
            };
            errdefer item.deinit(self.gpa);
            return try self.processItem(item);
        }
    };
}

/// The document's own naming for `obj` ([`OpSet::id_to_exid`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs),
/// `op_set.rs:1054-1060`).
///
/// Canonical root stays root. A named or unresolved ID never becomes root
/// merely because it cannot be represented by a resident operation ID.
/// Resident IDs export actor bytes from this document's table; unresolved
/// inputs remain unchanged, and their empty walks emit no items.
///
/// The ids this walk builds carry an actor *index* and no bytes
/// ([`MadeObj`]), so this is where the actor table is read — **once per
/// object the walk visits**, because [`DocIter.next`] refreshes only when the
/// object changes (`iter/doc.rs:294-298`).
fn exidOf(comptime O: type, set: *opset.OpSet(O), obj: ObjId) ObjId {
    return switch (obj) {
        .root, .named => obj,
        .id => |id| if (set.getActor(id.actor)) |actor|
            ObjId.withActor(id, actor)
        else
            obj,
    };
}

/// The recursive walk over a document's items ([`DocIter`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
/// `iter/doc.rs:18-51`, walked at `:291-304`).
///
/// **The walk `ReadDoc::iter` is** ([`read.rs:68-76`](../../github-automerge-automerge/rust/automerge/src/read.rs)):
/// every visible property of every object the document holds, parents before
/// children, and within one object in the order its own reader gives them.
///
/// `gpa` is first because one arm allocates: [`spans.SpansInternal`] owns a
/// mark fold and a run buffer, and it is those bytes — not the document's —
/// that a [`DocObjItem`] of a text object carries. A caller hands the same
/// allocator back to [`deinit`](Self.deinit) and to
/// [`DocObjItem.deinit`](DocObjItem.deinit).
pub fn DocIter(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The allocator the walk and the items it hands out are taken with.
        gpa: Allocator,
        /// The op set an object id is resolved against
        /// (`iter/doc.rs`:20`'s `op_set`, which is an `Option` there and is not
        /// one here — see the module doc on `DocIter::empty`).
        op_set: *opset.OpSet(O),
        /// The object the last item hung by, in the document's own actor
        /// naming (`Arc<ExId>`, `iter/doc.rs`:21`).
        obj_export: ObjId,
        /// The walk itself (`iter/doc.rs`:22`).
        inner: DocIterInternal(O),

        /// The walk over `obj`'s items as `clock` sees them
        /// ([`DocIter::new`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:42-50`).
        ///
        /// **`obj_export` starts at the object the walk starts from**, which
        /// is upstream's `doc.ops().id_to_exid(obj.id.0)` (`iter/doc.rs:44`) and
        /// not a null: the first item names that same object, so the refresh in
        /// [`next`](Self.next) does not fire for it.
        pub fn init(
            gpa: Allocator,
            doc: *const Doc(O),
            obj: ObjId,
            typ: types.ObjType,
            clock: ?Clock,
        ) DiffError!Self {
            const inner = try DocIterInternal(O).init(gpa, doc, obj, typ, clock);
            return .{
                .gpa = gpa,
                .op_set = doc.op_set,
                .obj_export = exidOf(O, doc.op_set, inner.obj),
                .inner = inner,
            };
        }

        /// Gives back the spans fold and the queue. **The items already handed
        /// out are the caller's**, and each is freed with
        /// [`DocObjItem.deinit`](DocObjItem.deinit) and this walk's
        /// [`gpa`](Self.gpa). **The walk is unusable once this returns**:
        /// `self.* = undefined` is the last line, so a second call reads
        /// undefined memory rather than reaching an allocator.
        pub fn deinit(self: *Self) void {
            self.inner.deinit();
            self.* = undefined;
        }

        /// The next item of the document, or null at the end of it
        /// ([`Iterator::next` for `DocIter`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
        /// `iter/doc.rs:291-304`).
        ///
        /// **Three lines and each one is a decision.** Take the next item from
        /// the internal walk (`iter/doc.rs:293`); refresh the exported object
        /// **only when it changed** (`iter/doc.rs:294-298`), which is what
        /// reads the actor table once per object rather than once per item;
        /// and export (`iter/doc.rs:299`).
        ///
        /// **The export moves the span, and nothing else copies**: upstream's
        /// `.into_owned()` on the text arm's value allocates because the two
        /// arms borrow from different places, and the port's item borrows the
        /// span it already owns (see [`DocObjItem.value`]).
        pub fn next(self: *Self) DiffError!?DocObjItem(O) {
            var got = (try self.inner.next()) orelse return null;
            errdefer got.deinit(self.gpa);
            const current = self.obj_export.opId();
            const incoming = got.obj.opId();
            const same = if (current) |id|
                if (incoming) |next_id| id.eql(next_id) else false
            else
                incoming == null;
            if (!same) self.obj_export = exidOf(O, self.op_set, got.obj);
            const clock: ?Clock = switch (self.inner.span_iter.iter.clock) {
                .current => |value| value,
                .diff => |clocks| clocks.after,
            };
            return .{ .obj = self.obj_export, .item = try got.item.exportItem(self.gpa, self.op_set, clock) };
        }
    };
}

/// A value the patch layer records, from a value a reader saw
/// ([`ValueRef::hydrate`](../../github-automerge-automerge/rust/automerge/src/op_set2/types.rs),
/// `op_set2/types.rs:694-705`).
///
/// **A move between two payload shapes and not a conversion**: the object arm
/// carries a type here and an [`ExId`] there (`patch_log.rs:118`), and the id
/// is on the row, so [`MapDiffItem.id`](map_range.zig) and not the value is
/// what the log is handed.
fn patchValueOf(v: ValueRef) PatchValue {
    return switch (v) {
        .object => |o| .{ .object = o },
        .scalar => |s| .{ .scalar = s },
    };
}

/// One map register, written into the sink
/// ([`MapDiffItem::log`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs),
/// `map_range.rs:72-88`).
fn logMapItem(item: anytype, obj: ObjId, sink: anytype, _: TextEncoding) void {
    switch (item.diff) {
        .add => sink.putMap(obj, item.key, patchValueOf(item.value), item.id, item.conflict, item.expose),
        // **The two `Same` arms are exclusive**: a counter that moved and a
        // conflict that appeared are different patches, and upstream checks
        // the counter first (`map_range.rs:79`).
        .same => {
            if (item.inc != 0) {
                sink.incrementMap(obj, item.key, item.inc, item.id);
            } else if (item.conflict) {
                sink.flagConflict(obj, .{ .key = item.key });
            }
        },
        .del => sink.deleteMap(obj, item.key),
    }
}

/// One sequence element, written into the sink
/// ([`ListDiffItem::log`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs),
/// `list_range.rs:218-243`).
fn logListItem(item: anytype, obj: ObjId, sink: anytype, _: TextEncoding) void {
    switch (item.diff) {
        .add => {
            // **A put and an insert are different patches for the same value**
            // (`list_range.rs:222-227`), and `update` is what says which: a row
            // that changed an existing element is a put, a row that inserted
            // one is an insert.
            const v = patchValueOf(item.value);
            if (item.update) {
                sink.putSeq(obj, item.index, v, item.id, item.conflict, item.expose);
            } else {
                sink.insertAndMaybeExpose(obj, item.index, v, item.id, item.conflict, item.expose);
            }
        },
        .same => {
            if (item.inc != 0) {
                sink.incrementSeq(obj, item.index, item.inc, item.id);
            } else if (item.conflict) {
                sink.flagConflict(obj, .{ .index = item.index });
            }
        },
        .del => sink.deleteSeq(obj, item.index, 1),
    }
}

/// The object replacement character: what a block marker reads as, and what a
/// non-string value in a text reads as (`PLACEHOLDER`, `spans.rs:429`).
const placeholder: []const u8 = "\u{fffc}";

/// One text span, written into the sink
/// ([`SpanDiff::log`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
/// `spans.rs:22-44`).
///
/// **Six cases and two of them are upstream's `_ => {}`** (`spans.rs:42-43`): a
/// `Same` block and an `Add` text run carrying no mark change produce no
/// event. The two that are not the obvious ones are the deleted ones — a
/// deleted span is a `delete_seq` whose **length is the width in the
/// document's encoding** (`spans.rs:40`), and a deleted block is a `delete_seq`
/// of **one**, because a block marker is one position wide whatever the
/// placeholder's width is (`spans.rs:41-42`).
fn logSpanItem(item: anytype, obj: ObjId, sink: anytype, enc: TextEncoding) void {
    switch (item.diff) {
        .add => switch (item.span) {
            .text => |t| sink.splice(obj, t.index, t.text, if (t.marks) |m| &m else null),
            // **A block marker is a map** (`iter/doc.rs:441`), the conflict flag
            // is `false` because a span diff reports no register conflict
            // (`spans.rs:33`), and `expose` comes from the span.
            .obj => |o| sink.insertAndMaybeExpose(
                obj,
                o.index,
                .{ .object = .map },
                o.id.id,
                false,
                o.expose,
            ),
        },
        .same => switch (item.span) {
            .text => |t| if (t.marks) |m| {
                sink.mark(obj, t.index, enc.width(t.text), &m);
            },
            .obj => {},
        },
        .del => switch (item.span) {
            .text => |t| sink.deleteSeq(obj, t.index, enc.width(t.text)),
            .obj => |o| sink.deleteSeq(obj, o.index, enc.width(placeholder)),
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const opmod = @import("../opset/op.zig");

const ScalarValue = optypes.ScalarValue;

/// The concrete op set the fixtures are read through, for the reason
/// [`map_range.zig`](map_range.zig) gives: [`opmod.Op`] borrows its row's
/// successors and its value, so a fixture is an array of `Op` values over its
/// own storage and needs no allocator for them, and the index columns come
/// from [`opset.OpSet.rebuildIndex`] rather than from the rows.
const Set = opset.OpSet(opmod.Op);

/// The encoding most fixtures are built with, so a width is a count of code
/// points and not of bytes or of UTF-16 units.
const encoding: types.TextEncoding = .unicode_code_point;

/// The document's one actor. `ActorIdx` is a position in this table
/// ([`types.zig`](../../src/types.zig)).
const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };

fn opId(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

fn made(ctr: u32, actor: ActorIdx) ObjId {
    return .{ .id = opId(ctr, actor) };
}

/// A sequence row anchored to the element at `id` ([`ElemId::from_op_id`],
/// [`types.rs:652-654`](../../github-automerge-automerge/rust/automerge/src/types.rs)).
fn anchored(id: OpId) optypes.KeyRef {
    return .{ .seq = types.ElemId.fromOpId(id) };
}

/// The head of a sequence: the element id that means "inserted at the front"
/// ([`ElemId::head`], `types.rs:657-659`).
fn head() optypes.KeyRef {
    return .{ .seq = types.ElemId.head() };
}

/// A row as the columns spell it. Every borrowed payload — the key, the value,
/// the mark name — belongs to the fixture, which outlives the op set.
fn row(
    id: OpId,
    obj: ObjId,
    key: optypes.KeyRef,
    insert: bool,
    act: optypes.Action,
    val: ScalarValue,
    mark: ?[]const u8,
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
        mark,
        opmod.SuccCursors.none(),
    );
}

/// A row a later operation replaced, and so a row a visible reader does not
/// read — the shape a delete leaves behind.
///
/// **A delete has no row of its own.** `Columns::splice` drops every op whose
/// action is `Delete` ([`columns.rs:423-427`](../opset/columns.zig)), and the
/// register a delete kills keeps the one row it wrote, carrying a successor
/// edge to the delete that replaced it; the index builder then reads that
/// edge as "this row is shadowed"
/// ([`IndexBuilder.flush`](../opset/index.zig), `index.rs:177-181`) and the
/// register is neither visible nor top. **Without the edge the row would read
/// as the value it used to hold**, which is the mistake this helper exists to
/// prevent.
fn shadowedRow(
    id: OpId,
    obj: ObjId,
    key: optypes.KeyRef,
    act: optypes.Action,
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

/// Whether two values are the same value, which is upstream's `assert_eq!`
/// over `ValueRef` ([`iter/doc.rs:600`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)).
///
/// **Two arms and no coercion between them**: a register that holds an
/// object and one that holds a string are not the same value, and a reader
/// that answered `null` where a map was expected would be describing a
/// different document.
fn sameValue(got: ValueRef, want: ValueRef) bool {
    return switch (got) {
        .object => |o| want == .object and o == want.object,
        .scalar => |s| want == .scalar and s.eql(want.scalar),
    };
}

/// A clock over every operation up to and including `cutoff` for the
/// document's one actor, which is the document as it was just after that
/// operation.
fn clockUpTo(gpa: Allocator, cutoff: u32) !Clock {
    var c = try Clock.init(gpa, 1);
    _ = c.include(0, cutoff);
    return c;
}

/// The string table a fixture's op set borrows. **Heap-allocated, and that is
/// an ownership rule rather than a convenience**
/// ([`op_set.zig`](../../opset/op_set.zig)'s `documentSet`): the op set
/// borrows the table, so it has to sit at one address for as long as the set
/// does, and a struct that owned the table and were returned by value would
/// leave the set's `strings.ctx` pointing at a dead frame.
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
    fn asTable(self: *Table) opcols.StringTable {
        return .{ .ctx = self, .resolve = resolve, .intern = intern };
    }
    fn resolve(ctx: *const anyopaque, id: u32) []const u8 {
        const self: *const Table = @ptrCast(@alignCast(ctx));
        return self.items.items[id];
    }
    fn intern(ctx: *anyopaque, text: []const u8, gpa: Allocator) err.ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(ctx));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, text)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, text));
        return id;
    }
};

/// An op set and the table it borrows, built together under one encoding.
const Fixture = struct {
    gpa: Allocator,
    table: Table,
    set: Set,

    fn build(
        gpa: Allocator,
        enc: types.TextEncoding,
        actors: []const types.ActorId,
        rows: []const opmod.Op,
    ) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .table = .init(gpa), .set = undefined };
        self.set = Set.fromActors(gpa, actors, enc, self.table.asTable()) catch |e| {
            self.table.deinit();
            return e;
        };
        errdefer self.table.deinit();
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
};

/// The document every walk below is read from unless it needs another shape:
/// the root, a list it holds, and that list's one element.
///
/// **Canonical row order, and both halves of it.** Objects **ascend** (rule
/// **R1**, [`op.zig:2211-2214`](../opset/op.zig),
/// `op_set2/op.rs:1049-1054`), so the root's two rows come before the list's
/// one; and map registers **ascend by key string** within an object
/// ([`op.zig:2215-2217`](../opset/op.zig), `op_set2/op.rs:1059-1060` — the
/// arm is `s1 > s2`, so the later row's key is the greater one), so `"a"`
/// precedes `"l"`. The list's element is anchored to the head, which opens the
/// first sequence register of its object (rule **R4**, `op_set2/op.rs:1061-1063`).
const list = made(2, 0);

fn twoObjectDoc(gpa: Allocator) !*Fixture {
    return Fixture.build(gpa, encoding, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "a" }, false, .set, .{ .str = "one" }, null),
        row(opId(2, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, null),
        row(opId(3, 0), list, head(), true, .set, .{ .str = "x" }, null),
    });
}

test "a refused document fixture releases its interned strings" {
    // The second row cannot be a sequence register in the root map.
    try testing.expectError(error.InvalidValue, Fixture.build(testing.allocator, encoding, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "held" }, false, .set, .{ .str = "owned" }, null),
        row(opId(2, 0), .root, head(), true, .set, .{ .int = 2 }, null),
    }));
}

test "a document's objects are walked once each, in row order, and the walk stops" {
    const gpa = testing.allocator;
    const doc = try twoObjectDoc(gpa);
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    var it = try handle.objIdIter(null);
    // **The premise is the op set's own shape**: the root's two rows and the
    // list's one, so the walk has exactly two objects to find and the first
    // is the root.
    try testing.expectEqual(@as(usize, 3), doc.set.len());
    const root_rows_range = try doc.set.scopeToObj(.root);
    const list_rows_range = try doc.set.scopeToObj(list);
    try testing.expectEqual(@as(usize, 0), root_rows_range.start);
    try testing.expectEqual(@as(usize, 2), root_rows_range.end);
    try testing.expectEqual(@as(usize, 2), list_rows_range.start);
    try testing.expectEqual(@as(usize, 3), list_rows_range.end);

    try testing.expectEqual(@as(usize, 0), it.pos());
    try testing.expectEqual(@as(usize, 3), it.maxPos());

    // Row order, and the root first: the columns are in `ObjId` order, which
    // is what upstream's `BTreeMap` gave its children.
    const first = (try it.next()) orelse return error.TestExpectedItem;
    try testing.expect(first.eql(.root));
    try testing.expectEqual(@as(usize, 2), it.pos());
    const second = (try it.next()) orelse return error.TestExpectedItem;
    try testing.expect(second.eql(list));
    // **Once each**: the list's one row is a run of one, and the second read
    // consumed it rather than reporting it again.
    try testing.expectEqual(@as(usize, 3), it.pos());
    try testing.expect((try it.next()) == null);
    // And the walk stays over: a second null is the same answer, not a new
    // one, and the cursor has not moved.
    try testing.expect((try it.next()) == null);
    try testing.expectEqual(@as(usize, 3), it.pos());
}

test "a document with no rows has no objects, and its walk is a defined null" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, encoding, &.{actor_a}, &.{});
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    // **An empty op set is a document with no rows at all**, so there is no
    // object to walk: not a root with no rows, but no root either. The root's
    // range is empty, which is the same fact the op set's own
    // [`OpSet.scopeToObj`] answers.
    try testing.expectEqual(@as(usize, 0), doc.set.len());
    const root = try doc.set.scopeToObj(.root);
    try testing.expectEqual(@as(usize, 0), root.end - root.start);

    // With no clock and with a clock that covers everything the answers are
    // the same, and that is the point: the narrowing is not what makes the
    // walk empty.
    var at_present = try handle.objIdIter(null);
    try testing.expectEqual(@as(usize, 0), at_present.pos());
    try testing.expectEqual(@as(usize, 0), at_present.maxPos());
    try testing.expect((try at_present.next()) == null);

    var covering = try clockUpTo(gpa, 4);
    defer covering.deinit();
    var at_clock = try handle.objIdIter(covering);
    try testing.expect((try at_clock.next()) == null);
}

test "the walk's objects are the op set's own, and a long run is one boundary" {
    // 201 `comptimePrint`s, each a comptime format run.
    @setEvalBranchQuota(100_000);
    const gpa = testing.allocator;
    // **A document with many objects and one object with a long run**, so
    // that "one object per step" and "one row per step" cannot both look
    // right: 200 child objects and 699 rows, of which one object holds 300.
    // `long_run` rows of one object are one segment however long it is
    // ([`slab.zig:906-912`](../hexane/slab.zig), which is why the layout cuts
    // at run boundaries and never inside one), and that is why an object's
    // rows cannot be spread over two slabs and a long object is one boundary.
    const child_count = 200;
    const long_run = 300;
    const root_rows = child_count;
    const list_rows = 1;
    const total_rows = root_rows + long_run + (child_count - 1);

    // The keys are comptime strings, so the rows that name them borrow
    // storage that outlives the op set and the walk.
    const child_keys: [child_count + list_rows][]const u8 = comptime blk: {
        var out: [child_count + list_rows][]const u8 = undefined;
        for (&out, 0..) |*k, i| k.* = std.fmt.comptimePrint("m{d:0>3}", .{i});
        break :blk out;
    };
    const first_child = made(1, 0);

    // The rows are built into one allocation, which the caller owns and frees
    // after the op set is destroyed: `Op` borrows its payloads, and an
    // allocation keeps the fixture's rows off the stack.
    const rows = try gpa.alloc(opmod.Op, total_rows);
    defer gpa.free(rows);
    // The root, one `make_*` per child, its keys ascending (rule **R2**,
    // `op_set2/op.rs:1059-1060`) and its objects ascending (rule **R1**).
    // The last child is a **list**, so the document ends on a sequence
    // object: a map object and a sequence row are never adjacent in one
    // object (`op.zig:2215-2222`), and a fixture that put one there would
    // be testing a shape no document has.
    for (0..root_rows) |i| {
        rows[i] = row(
            opId(@intCast(i + 1), 0),
            .root,
            .{ .map = child_keys[i] },
            false,
            if (i + 1 == child_count) .make_list else .make_map,
            .null_value,
            null,
        );
    }
    // The first child, one register of `long_run` rows whose ids ascend
    // strictly (rule **R3**, `op_set2/op.rs:1056-1057`).
    var at: usize = root_rows;
    for (0..long_run) |i| {
        rows[at + i] = row(
            opId(@intCast(root_rows + i + 1), 0),
            first_child,
            .{ .map = "a" },
            false,
            .set,
            .{ .str = "v" },
            null,
        );
    }
    at += long_run;
    // The rest of the children, one row each, and a list at the end so the
    // last object is a sequence's.
    for (1..child_count - 1) |i| {
        rows[at] = row(
            opId(@intCast(at + 1), 0),
            made(@intCast(i + 1), 0),
            .{ .map = "a" },
            false,
            .set,
            .{ .str = "v" },
            null,
        );
        at += 1;
    }
    const last_child = made(@intCast(child_count), 0);
    rows[at] = row(
        opId(@intCast(at + 1), 0),
        last_child,
        head(),
        true,
        .set,
        .{ .str = "x" },
        null,
    );
    at += 1;
    try testing.expectEqual(total_rows, at);

    const doc = try Fixture.build(gpa, encoding, &.{actor_a}, rows);
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    // **The premise**: the first child holds a run of `long_run` rows, which
    // is longer than the run budget one slab may hold
    // ([`slab.zig:906-912`](../hexane/slab.zig) — a run is never split, so a
    // slab that is one very long run keeps one segment however long it is,
    // which is why one object's rows cannot be spread over two slabs and a
    // long object is one boundary whatever the layout), and the op set's own
    // answer for those rows is exactly that many.
    try testing.expect(long_run > column.default_max_segments);
    const long_rows = try doc.set.scopeToObj(first_child);
    try testing.expectEqual(@as(usize, long_run), long_rows.end - long_rows.start);
    // The two object columns hold every row of the document, and the document
    // has 200 objects of which one holds 300 rows: no answer below can be
    // right by accident.
    try testing.expectEqual(total_rows, doc.set.cols.obj_ctr.len());
    try testing.expectEqual(total_rows, doc.set.cols.obj_actor.len());

    // **The conclusion**, and it has two halves because the walk has two
    // answers: every object once, in row order, and — for each of them — the
    // walk standing on that object's last row. `scopeToObj` is the authority
    // for both ([`op_set.rs:1246-1252`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
    // so a walk that reported an object twice, or stopped a row short of the
    // next one, fails here rather than somewhere a reader has to notice.
    var it = try handle.objIdIter(null);
    var covered: usize = 0;
    var found: usize = 0;
    var long_boundaries: usize = 0;
    while (try it.next()) |obj| {
        const rows_of = try doc.set.scopeToObj(obj);
        try testing.expectEqual(covered, rows_of.start);
        try testing.expectEqual(rows_of.end, it.pos());
        covered = rows_of.end;
        found += 1;
        if (obj.eql(first_child)) long_boundaries += 1;
    }
    try testing.expectEqual(@as(usize, 1), long_boundaries);
    try testing.expectEqual(child_count + 1, found);
    try testing.expectEqual(doc.set.len(), covered);
    try testing.expectEqual(total_rows, covered);
    try testing.expect((try it.next()) == null);
}

test "a clock narrows the walk to the objects that state has" {
    const gpa = testing.allocator;
    const doc = try twoObjectDoc(gpa);
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    // **The premise**: the list is created by the operation at counter 2, and
    // its id *is* that operation's id
    // ([`op_set.zig:1287-1291`](../opset/op_set.zig)), so a clock that stops
    // before it cannot have the list in it.
    try testing.expect(doc.set.objectType(list) == .list);
    var covering = try clockUpTo(gpa, 3);
    defer covering.deinit();
    try testing.expect(covering.contains(opId(2, 0)));
    var partial = try clockUpTo(gpa, 1);
    defer partial.deinit();
    try testing.expect(!partial.contains(opId(2, 0)));

    // The covering clock sees the document whole.
    var whole = try handle.objIdIter(covering);
    const first = (try whole.next()) orelse return error.TestExpectedItem;
    try testing.expect(first.eql(.root));
    const second = (try whole.next()) orelse return error.TestExpectedItem;
    try testing.expect(second.eql(list));
    try testing.expect((try whole.next()) == null);

    // **And the narrower clock does not.** The root survives, because no
    // operation created it and no clock can exclude it; the list does not,
    // because the clock does not cover the operation that made it. The
    // answers differ in length, which is the whole of what `Option<Clock>` is
    // for here.
    var earlier = try handle.objIdIter(partial);
    const only = (try earlier.next()) orelse return error.TestExpectedItem;
    try testing.expect(only.eql(.root));
    try testing.expect((try earlier.next()) == null);

    // A clock that covers nothing at all is still a walk with the root in it,
    // not an empty one. A reader that answered nothing would report a
    // document as having no objects at all.
    var empty = try Clock.init(gpa, 1);
    defer empty.deinit();
    var none = try handle.objIdIter(empty);
    const still_root = (try none.next()) orelse return error.TestExpectedItem;
    try testing.expect(still_root.eql(.root));
    try testing.expect((try none.next()) == null);
}

test "a shift past the end is null and a shift behind the cursor is refused" {
    const gpa = testing.allocator;
    const doc = try twoObjectDoc(gpa);
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    var it = try handle.objIdIter(null);
    _ = try it.next();
    _ = try it.next();
    try testing.expectEqual(doc.set.len(), it.pos());

    // **Past the end is a defined answer, not an error**: a reader walks off
    // the end of every window it is given, and the last object is no
    // different from the rest ([`shift.rs:60`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
    try testing.expect((try it.shiftNext(.{ .start = doc.set.len(), .end = doc.set.len() + 8 })) == null);
    // An empty range at the cursor is the same answer, and a range that ends
    // where the cursor stands opens a window with no rows left in it.
    try testing.expect((try it.shiftNext(.{ .start = doc.set.len(), .end = doc.set.len() })) == null);

    // **Behind the cursor is a refusal, not a rewind**: the walk stands past
    // row 2 and row 0 is behind it, so a walk that rewound would answer an
    // object it has already consumed
    // ([`shift.rs:13-14`](../../github-automerge-automerge/rust/hexane/src/shift.rs),
    // where upstream asserts and the port refuses,
    // [`column.zig:3641-3642`](../hexane/column.zig)).
    try testing.expectError(error.InvalidValue, it.shiftNext(.{ .start = 0, .end = 1 }));
    // **The refusal moves nothing**, which is what makes it a refusal: the
    // same walk still answers the same next object.
    try testing.expectEqual(doc.set.len(), it.pos());
    try testing.expectError(error.InvalidValue, it.shiftNext(.{ .start = 1, .end = 2 }));
    try testing.expect((try it.next()) == null);
}

test "the walk's kernel moves it" {
    const gpa = testing.allocator;
    const doc = try twoObjectDoc(gpa);
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    // Every one of the eight names, each with the answer it owes. **A kernel
    // method that no test calls can remain unanalyzed**, so this exercises
    // [`ObjIdIter.shiftable`] rather than merely declaring it.

    // `setMax` truncates the window, and the walk stops at it. With two rows
    // the root's run is whole and the list's row is not in the window at all.
    {
        var it = try handle.objIdIter(null);
        it.setMax(2);
        try testing.expectEqual(@as(usize, 0), it.pos());
        try testing.expectEqual(@as(usize, 2), it.maxPos());
        const first = (try it.next()) orelse return error.TestExpectedItem;
        try testing.expect(first.eql(.root));
        try testing.expectEqual(@as(usize, 2), it.pos());
        try testing.expect((try it.next()) == null);
    }

    // `shift` is `setMax` and nothing else: the window moves, the position
    // does not ([`column.zig:3625-3631`](../hexane/column.zig)).
    {
        var it = try handle.objIdIter(null);
        it.shift(.{ .start = 0, .end = 1 });
        try testing.expectEqual(@as(usize, 0), it.pos());
        try testing.expectEqual(@as(usize, 1), it.maxPos());
        // The root's run is two rows and the window is one, so the walk reads
        // the root off the first row and stops: the row that would have told
        // it the run ended is outside the window, and a lookahead the window
        // no longer covers is dropped rather than handed back
        // ([`ObjIdIter.setMax`]).
        const only = (try it.next()) orelse return error.TestExpectedItem;
        try testing.expect(only.eql(.root));
        try testing.expect((try it.next()) == null);
    }

    // `advanceTo` and `advanceBy` move the position forward and report where
    // they landed. Standing on the list's row, the walk answers the list.
    {
        var it = try handle.objIdIter(null);
        try it.advanceTo(2);
        try testing.expectEqual(@as(usize, 2), it.pos());
        const landed = (try it.next()) orelse return error.TestExpectedItem;
        try testing.expect(landed.eql(list));
        try testing.expectEqual(@as(usize, 3), it.pos());
        try testing.expect((try it.next()) == null);
    }
    {
        var it = try handle.objIdIter(null);
        try it.advanceBy(1);
        try testing.expectEqual(@as(usize, 1), it.pos());
        // A position inside the root's run answers the root, and consumes the
        // run — the unit is an object, so the whole run goes.
        const landed = (try it.next()) orelse return error.TestExpectedItem;
        try testing.expect(landed.eql(.root));
        try testing.expectEqual(@as(usize, 2), it.pos());
        const following = (try it.next()) orelse return error.TestExpectedItem;
        try testing.expect(following.eql(list));
    }

    // `seekTo` answers the object a row belongs to, and leaves the walk after
    // that object's rows. A row behind the cursor is null, not a rewind.
    {
        var it = try handle.objIdIter(null);
        const landed = (try it.seekTo(1)) orelse return error.TestExpectedItem;
        try testing.expect(landed.eql(.root));
        try testing.expectEqual(@as(usize, 2), it.pos());
        try testing.expect((try it.seekTo(0)) == null);
        const next_object = (try it.next()) orelse return error.TestExpectedItem;
        try testing.expect(next_object.eql(list));
        try testing.expect((try it.next()) == null);
    }

    // `shiftNext` onto a whole object's range: the range the op set answers is
    // the one a document walk repositions with, and the object it names is the
    // object the range starts in.
    {
        var it = try handle.objIdIter(null);
        const first = (try it.shiftNext(try doc.set.scopeToObj(.root))) orelse
            return error.TestExpectedItem;
        try testing.expect(first.eql(.root));
        try testing.expectEqual(@as(usize, 2), it.pos());
        const second = (try it.shiftNext(try doc.set.scopeToObj(list))) orelse
            return error.TestExpectedItem;
        try testing.expect(second.eql(list));
        try testing.expectEqual(@as(usize, 3), it.pos());
        try testing.expect((try it.shiftNext(.{ .start = 3, .end = 3 })) == null);
    }
}

test "a handle and an object walk are values" {
    // `FailingAllocator` with no `fail_index` never fails and counts every
    // byte its inner allocator hands out, so it is a counter and a real
    // allocator at once ([`parents.zig:1095-1096`](../opset/parents.zig)). It
    // is the **op set's** allocator, which is the only allocator a walk can
    // reach: neither [`Doc`] nor [`ObjIdIter`] has one of its own, so an
    // allocation in either would come through here.
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counter.allocator();

    const doc = try twoObjectDoc(gpa);
    defer doc.destroy();
    const before = counter.allocated_bytes;

    // **Constructing the handle allocates nothing**: a pointer and an enum.
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);
    try testing.expectEqual(before, counter.allocated_bytes);

    // **Nor does constructing the walk**, and neither does walking it: the
    // walk's window is the op set's own columns, its clock is the caller's,
    // the run of rows a step consumes is found by a descent on the columns
    // themselves, and a descent builds its probe by value
    // ([`opiter.zig:1779-1782`](../opset/op_iter.zig)). The step is the part
    // that could have allocated and does not.
    var it = try handle.objIdIter(null);
    try testing.expectEqual(before, counter.allocated_bytes);
    var seen: usize = 0;
    while (try it.next()) |obj| {
        seen += 1;
        // The answers are read, not only counted, so a walk that returned
        // nothing would not pass on the count.
        try testing.expect(obj.eql(.root) or obj.eql(list));
    }
    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqual(before, counter.allocated_bytes);

    // And a clock, which the walk borrows rather than copies, costs nothing
    // to hand over.
    var clock = try clockUpTo(gpa, 3);
    defer clock.deinit();
    const with_clock = counter.allocated_bytes;
    var narrowed = try handle.objIdIter(clock);
    try testing.expectEqual(with_clock, counter.allocated_bytes);
    _ = try narrowed.next();
    try testing.expectEqual(with_clock, counter.allocated_bytes);
}

test "a handle carries the document's own encoding, and the spans reader reads through it" {
    const gpa = testing.allocator;
    // **A non-default encoding, so a handle that defaulted to code points
    // would fail this rather than agree with it by accident.**
    const enc: types.TextEncoding = .utf16_code_unit;
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, enc, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, null),
        row(opId(2, 0), text, head(), true, .set, .{ .str = "ab" }, null),
        row(opId(3, 0), text, anchored(opId(2, 0)), true, .set, .{ .str = "cd" }, null),
    });
    defer doc.destroy();

    // **The two encodings cannot drift**: the op set carries the one it was
    // built with ([`op_set.zig:633`](../opset/op_set.zig)) and the handle
    // carries the document's, and a reader that measured in the other one
    // would read a width the op set never wrote
    // ([`iter/spans.zig`](spans.zig)'s `len` accounting).
    const handle: Doc(opmod.Op) = .init(&doc.set, enc);
    try testing.expectEqual(enc, handle.text_encoding);
    try testing.expectEqual(enc, doc.set.text_encoding);

    // **And the reader reads the text through the handle**, which is the whole
    // path upstream takes: scope the object, then hand the document's own
    // encoding to `SpansInternal::new` ([`iter/doc.rs:186`](../iter/doc.zig)).
    var reader = try spans.Spans(opmod.Op).init(
        gpa,
        handle.op_set,
        try handle.op_set.scopeToObj(text),
        null,
        handle.text_encoding,
    );
    defer reader.deinit();

    // **The text is the two rows' bytes in one span**, which is what a reader
    // over a text object hands a renderer: one run, no marks, no blocks.
    var one = (try reader.next()) orelse return error.TestExpectedItem;
    defer one.deinit(gpa);
    try testing.expectEqualStrings("abcd", one.asStr());
    try testing.expect(one == .text);
    // And the object's rows are all of them: the walk ends.
    try testing.expect((try reader.next()) == null);
}

test "the document diff reads the root's rows and then descends into each child, in order" {
    const gpa = testing.allocator;
    // Upstream's `DiffIter::log` (`iter/doc.rs:79-92`) is driven by the two
    // halves it composes: `next_prop` drains the object the walk is on
    // (`iter/doc.rs:149-161`) and `next_object` repositions the reader onto
    // the next one (`iter/doc.rs:135-147`). **The second half is the one with
    // a shift in it** — `self.map_iter.shift_next(next_range)` at
    // `iter/doc.rs:141`, `self.list_iter.shift_next(next_range)` at `:142`,
    // `self.span_iter.shift_next(next_range)` at `:143` — so a document with
    // child objects is the only shape that reaches it.
    //
    // **A map child and two list children, because those are two of the three
    // arms and the two readers are built differently**: the map reader's shift
    // repositions onto the rows (`map_range.rs:323-326`) and the list
    // reader's also puts the element index back to zero
    // (`list_range.rs:76-78`), which is a line the map reader does not have.
    // **Two** list children because one is not enough: the index only has to
    // restart when the list reader is shifted a *second* time, so a single
    // child would pass with the reset deleted.
    //
    // Objects ascend (rule R1, `op.zig:2211-2214`), so the root's rows are
    // [0, 4), the map child's row is [4, 5) and the two list children's rows
    // are [5, 7) and [7, 9); and map registers ascend by key string (rule R2,
    // `op.rs:1059-1060`), so "a" precedes "l" precedes "m" precedes "n" —
    // **which is why operation 4's row is written before operation 2's, and
    // operation 8's before operation 2's**. The reader does not sort, so the
    // order written here is the order the answers come back in.
    const map_child = made(2, 0);
    const list_one = made(4, 0);
    const list_two = made(8, 0);
    const doc = try Fixture.build(gpa, encoding, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "a" }, false, .set, .{ .str = "one" }, null),
        row(opId(4, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, null),
        row(opId(2, 0), .root, .{ .map = "m" }, false, .make_map, .null_value, null),
        row(opId(8, 0), .root, .{ .map = "n" }, false, .make_list, .null_value, null),
        row(opId(3, 0), map_child, .{ .map = "z" }, false, .set, .{ .str = "two" }, null),
        row(opId(5, 0), list_one, head(), true, .set, .{ .str = "p" }, null),
        row(opId(6, 0), list_one, anchored(opId(5, 0)), true, .set, .{ .str = "q" }, null),
        row(opId(9, 0), list_two, head(), true, .set, .{ .str = "r" }, null),
        row(opId(10, 0), list_two, anchored(opId(9, 0)), true, .set, .{ .str = "s" }, null),
    });
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    // **The walk, in the order it visits, with the index it reports.** Every
    // assertion is an index into one expected sequence: the readers do not
    // sort, so an order-blind check would pass on a walk that reported a
    // child's element before the root's first key. The list arm's `index` is
    // the load-bearing extra — **it restarts at zero for every object**
    // (`list_range.rs:77`), so the second list's first element is index 0 and
    // not index 2.
    //
    // **The children come out in ascending object id**, not in the order the
    // root named them: the queue takes the lowest id first
    // (`iter/doc.rs:146`, `pop_first` on a `BTreeMap`), so `m` — operation 2
    // — is visited before `l` — operation 4 — even though the root's own rows
    // read "l" first.
    const Step = struct { obj: ObjId, text: []const u8, index: usize };
    const want = [_]Step{
        .{ .obj = .root, .text = "a", .index = 0 },
        .{ .obj = .root, .text = "l", .index = 0 },
        .{ .obj = .root, .text = "m", .index = 0 },
        .{ .obj = .root, .text = "n", .index = 0 },
        .{ .obj = map_child, .text = "z", .index = 0 },
        .{ .obj = list_one, .text = "p", .index = 0 },
        .{ .obj = list_one, .text = "q", .index = 1 },
        .{ .obj = list_two, .text = "r", .index = 0 },
        .{ .obj = list_two, .text = "s", .index = 1 },
    };

    // Recursive: each child named by a visible row of the root is queued
    // (`iter/doc.rs:125`) and read after the root's own rows are spent, lowest
    // id first.
    {
        var it = try DiffIter(opmod.Op).init(gpa, &handle, .root, .map, .{ .current = null }, true);
        defer it.deinit();
        var seen: usize = 0;
        while (try it.next()) |item| {
            if (seen >= want.len) return error.TestUnexpectedResult;
            const got: Step = switch (item.item) {
                .map => |m| .{ .obj = item.obj, .text = m.key, .index = 0 },
                .list => |l| switch (l.value) {
                    .scalar => |s| switch (s) {
                        .str => |t| .{ .obj = item.obj, .text = t, .index = l.index },
                        else => return error.TestUnexpectedResult,
                    },
                    else => return error.TestUnexpectedResult,
                },
                .text => return error.TestUnexpectedResult,
            };
            try testing.expect(item.obj.eql(want[seen].obj));
            try testing.expectEqualStrings(want[seen].text, got.text);
            try testing.expectEqual(want[seen].index, got.index);
            seen += 1;
        }
        try testing.expectEqual(want.len, seen);
        // **The path map is filled even for the recursive walk**, and each
        // child hangs by the property of the root that named it
        // (`iter/doc.rs:126-128`).
        const paths = [_]struct { obj: ObjId, key: []const u8 }{
            .{ .obj = map_child, .key = "m" },
            .{ .obj = list_one, .key = "l" },
            .{ .obj = list_two, .key = "n" },
        };
        for (paths) |p| {
            const at = it.path_map.get(p.obj) orelse return error.TestExpectedItem;
            try testing.expect(at.obj.eql(p.obj));
            try testing.expectEqualStrings(p.key, at.prop.key);
            try testing.expect(at.parent.eql(.root));
        }
        try testing.expectEqual(paths.len, it.path_map.items.items.len);
    }

    // **Not recursive: the paths are still recorded and the descent is not.**
    // `iter/doc.rs:125` is the only difference between the two, and a reader
    // that conflated them would report the children's own rows as well, or
    // would lose the path the patch log needs to name them
    // (`iter/doc.rs:126-128`).
    {
        var it = try DiffIter(opmod.Op).init(gpa, &handle, .root, .map, .{ .current = null }, false);
        defer it.deinit();
        var seen: usize = 0;
        while (try it.next()) |item| {
            const key = switch (item.item) {
                .map => |m| m.key,
                else => return error.TestUnexpectedResult,
            };
            try testing.expect(item.obj.eql(want[seen].obj));
            try testing.expectEqualStrings(want[seen].text, key);
            seen += 1;
        }
        try testing.expectEqual(@as(usize, 4), seen);
        try testing.expect(it.path_map.get(map_child) != null);
        try testing.expect(it.path_map.get(list_one) != null);
        try testing.expect(it.path_map.get(list_two) != null);
    }
}

test "the diff walk hands its path map over, and the walk keeps nothing of it" {
    const gpa = testing.allocator;
    // **One child, and it is a map**, because `PathMap.put` is what grows the
    // buffer: an empty map's `deinit` is a no-op, so a walk that surfaced no
    // nested object would free nothing twice and pass against the defect.
    const map_child = made(1, 0);
    const doc = try Fixture.build(gpa, encoding, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "m" }, false, .make_map, .null_value, null),
        row(opId(2, 0), map_child, .{ .map = "z" }, false, .set, .{ .str = "two" }, null),
    });
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    var sink: patches.PatchLog = .inactive(gpa);
    defer sink.deinit();
    var handed = blk: {
        var it = try DiffIter(opmod.Op).init(gpa, &handle, .root, .map, .{ .current = null }, true);
        defer it.deinit();
        break :blk try it.log(&sink);
    };
    defer handed.deinit(gpa);

    // The transferred map must remain readable after the walk is destroyed.
    const at = handed.get(map_child) orelse return error.TestExpectedItem;
    try testing.expect(at.parent.eql(.root));
    try testing.expectEqualStrings("m", at.prop.key);
}

test "a text item the diff walk hands out is the caller's, and the caller's release is all of it" {
    const gpa = testing.allocator;
    // **A text child holding a block**, because those are the two arms
    // `DiffItem.text` answers with and only one of them owns anything: the run
    // is the span that carries bytes, and the block marker is the span that
    // names an object. The root's own row is the `.map` arm, which owns
    // nothing, so all three arms are driven here.
    const text_child = made(1, 0);
    const doc = try Fixture.build(gpa, encoding, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, null),
        row(opId(3, 0), text_child, head(), true, .set, .{ .str = "hi" }, null),
        row(opId(4, 0), text_child, anchored(opId(3, 0)), true, .make_map, .null_value, null),
    });
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    var it = try DiffIter(opmod.Op).init(gpa, &handle, .root, .map, .{ .current = null }, true);
    defer it.deinit();

    var runs: usize = 0;
    var blocks: usize = 0;
    var maps: usize = 0;
    while (try it.next()) |got| {
        // **`var`, because the text arm is released below** — the span owns
        // its buffer and the walk allocated it, so the walk's `deinit` is not
        // what gives it back.
        var item = got;
        switch (item.item) {
            .text => |*t| {
                defer t.deinit(gpa);
                switch (t.span) {
                    .text => |s| {
                        runs += 1;
                        // **Read before the release**: the bytes are the span's,
                        // so this is the last moment they are readable.
                        try testing.expectEqualStrings("hi", s.text);
                    },
                    .obj => {
                        blocks += 1;
                    },
                }
            },
            else => {
                maps += 1;
            },
        }
    }

    // **All three arms were driven**, so the run above released something and
    // the two that own nothing were not released.
    try testing.expectEqual(@as(usize, 1), maps);
    try testing.expectEqual(@as(usize, 1), runs);
    try testing.expectEqual(@as(usize, 1), blocks);
}

test "the recursive walk reads the root's rows, then every child, parents before children" {
    const gpa = testing.allocator;
    // **Upstream's only test in this file**, `doc_iter`
    // ([`iter/doc.rs:532-602`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)),
    // case for case and **in order**. Upstream builds its document through
    // `tx.put`, `tx.put_object`, `tx.splice_text`, `tx.insert`, `tx.delete`
    // and `tx.commit` (`iter/doc.rs:534-563`) and reads it back through
    // `doc.iter()` (`:567`); **this directory has no transaction layer, so
    // the same document is spelled as the rows that commit would have left**,
    // one operation to one row.
    //
    // **Every operation counter below is the counter the same `tx` call would
    // have used, and that is load-bearing twice over.** An object *is* the
    // operation that created it
    // ([`OpSet.spliceObjects`](../opset/op_set.zig), `op_set.zig:1287-1291`),
    // so the counters fix the object ids; and the queue takes the **lowest**
    // id first ([`ObjQueue.popLowest`], `iter/doc.rs:243`), so they fix the
    // order the children are visited in — `map1` (operation 3) is read before
    // `map2` (operation 5), not the other way round. Counters start at one,
    // which is the numbering [`clockUpTo`] and the test "a clock narrows the
    // walk to the objects that state has" already use.
    //
    // **The rows are written in the order the op set keeps them**, not in the
    // order the operations ran: objects ascend (rule **R1**,
    // [`op.zig:2211-2214`](../opset/op.zig)), map registers ascend by key
    // (rule **R2**, `op.rs:1059-1060`) and a sequence's rows ascend by element
    // id. So the root's thirteen registers come first, then `map1`'s one row,
    // then `map3`'s three, and so on — which is why operation 14's row (in
    // `text1`) is written last even though it ran before the other children's.
    const map1 = made(3, 0);
    const map3 = made(6, 0);
    const map4 = made(7, 0);
    const list1 = made(8, 0);
    const map6 = made(10, 0);
    const list2 = made(11, 0);
    const text1 = made(13, 0);

    // **The two deletes, which are successor edges and not rows**
    // ([`op.zig:1690-1700`](../opset/op.zig)): `tx.delete(&ROOT, "key06")` is
    // operation 28 and `tx.delete(&map6, "m6key2")` is operation 29
    // (`iter/doc.rs:560-561`), and a document holds no row for either. What
    // makes `key06` and `m6key2` **absent** rather than present with the value
    // they used to hold is the edge on the row each delete replaced — without
    // it both registers would read as live, and the answers below would gain
    // a `"key06"` and an `"m6key2"` that upstream's walk does not produce.
    const key06_gone = [_]opmod.SuccEntry{.{ .id = opId(28, 0), .inc = null }};
    const m6key2_gone = [_]opmod.SuccEntry{.{ .id = opId(29, 0), .inc = null }};

    const doc = try Fixture.build(gpa, encoding, &.{actor_a}, &.{
        // The root: `key01`, `key02`, a map, a string, a map, a map, a map, a
        // list, a map, a map, a list, a map, a text (`iter/doc.rs:535-547`).
        row(opId(1, 0), .root, .{ .map = "key01" }, false, .set, .{ .str = "value1" }, null),
        row(opId(2, 0), .root, .{ .map = "key02" }, false, .set, .{ .str = "value2" }, null),
        row(opId(3, 0), .root, .{ .map = "key03" }, false, .make_map, .null_value, null),
        row(opId(4, 0), .root, .{ .map = "key04" }, false, .set, .{ .str = "value4" }, null),
        row(opId(5, 0), .root, .{ .map = "key05" }, false, .make_map, .null_value, null),
        // **`key06` is created and then deleted** (`iter/doc.rs:539`, `:560`),
        // so its row carries the delete and no reader reports it.
        shadowedRow(opId(6, 0), .root, .{ .map = "key06" }, .make_map, .null_value, &key06_gone),
        row(opId(7, 0), .root, .{ .map = "key07" }, false, .make_map, .null_value, null),
        row(opId(8, 0), .root, .{ .map = "key08" }, false, .make_list, .null_value, null),
        row(opId(9, 0), .root, .{ .map = "key09" }, false, .make_map, .null_value, null),
        row(opId(10, 0), .root, .{ .map = "key10" }, false, .make_map, .null_value, null),
        row(opId(11, 0), .root, .{ .map = "key11" }, false, .make_list, .null_value, null),
        row(opId(12, 0), .root, .{ .map = "key12" }, false, .make_map, .null_value, null),
        row(opId(13, 0), .root, .{ .map = "key13" }, false, .make_text, .null_value, null),
        // `map1`, written once (`iter/doc.rs:552`).
        row(opId(15, 0), map1, .{ .map = "m1key1" }, false, .set, .{ .str = "m1value1" }, null),
        // `map3` (`iter/doc.rs:553-555`), whose three rows the walk **never
        // reads**: its only property is on the root, and that one was deleted.
        row(opId(16, 0), map3, .{ .map = "m3key1" }, false, .set, .{ .str = "m3value1" }, null),
        row(opId(17, 0), map3, .{ .map = "m3key2" }, false, .set, .{ .str = "m3value2" }, null),
        row(opId(18, 0), map3, .{ .map = "m3key3" }, false, .set, .{ .str = "m3value3" }, null),
        // `map4`, twice (`iter/doc.rs:556-557`).
        row(opId(19, 0), map4, .{ .map = "m4key1" }, false, .set, .{ .str = "m4value1" }, null),
        row(opId(20, 0), map4, .{ .map = "m4key2" }, false, .set, .{ .str = "m4value2" }, null),
        // `list1`'s three elements, each inserted after the one before
        // (`iter/doc.rs:558-560`).
        row(opId(21, 0), list1, head(), true, .set, .{ .str = "l1e1" }, null),
        row(opId(22, 0), list1, anchored(opId(21, 0)), true, .set, .{ .str = "l1e2" }, null),
        row(opId(23, 0), list1, anchored(opId(22, 0)), true, .set, .{ .str = "l1e3" }, null),
        // `map6` (`iter/doc.rs:561-563`, and the delete at `:561`), so the
        // middle register is absent and the walk reports two of its three.
        row(opId(24, 0), map6, .{ .map = "m6key1" }, false, .set, .{ .str = "m6value1" }, null),
        shadowedRow(opId(25, 0), map6, .{ .map = "m6key2" }, .set, .{ .str = "m6value2" }, &m6key2_gone),
        row(opId(26, 0), map6, .{ .map = "m6key3" }, false, .set, .{ .str = "m6value3" }, null),
        // `list2`'s one element (`iter/doc.rs:564`).
        row(opId(27, 0), list2, head(), true, .set, .{ .str = "l2e1" }, null),
        // **`text1`'s spliced run** (`iter/doc.rs:551`, operation 14), and the
        // last row in the document because `text1` is the highest object id
        // here — its visit is the walk's twenty-second answer.
        row(opId(14, 0), text1, head(), true, .set, .{ .str = "hello world" }, null),
    });
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);

    // **The premises**, so a fixture that drifted fails here rather than as a
    // mysterious twenty-first answer. Twenty-seven rows: the root's thirteen
    // registers and the children's, in one contiguous run per object.
    try testing.expectEqual(@as(usize, 27), doc.set.len());
    try testing.expect(doc.set.objectType(list1) == .list);
    try testing.expect(doc.set.objectType(text1) == .text);
    // **The object the walk must skip and not stop at**: `map2` is created by
    // operation 5 and never written to (`iter/doc.rs:538`), so the op set
    // holds no row of it and its range is empty — upstream's
    // `if next_range.is_empty() { Some(None) }` (`iter/doc.rs:247`). Three
    // objects of this document are in that state: operations 5, 9 and 12.
    const never_written = try doc.set.scopeToObj(made(5, 0));
    try testing.expectEqual(never_written.start, never_written.end);

    // **Upstream's twenty-two answers**, in the order its walk produces them
    // (`iter/doc.rs:574-597`). Upstream compares `(key, value)` pairs and
    // indexes both sides over `max(answers.len(), values.len())`
    // (`iter/doc.rs:598-600`), so a walk that stopped early and a walk that
    // ran on would both fail; **this table adds the object each property
    // hangs by**, which upstream does not check and `iter/doc.rs:337-338`
    // documents — it is the *parent*, never the object the value names.
    const Answer = struct { obj: ObjId, key: []const u8, value: ValueRef };
    const answers = [_]Answer{
        .{ .obj = .root, .key = "key01", .value = .{ .scalar = .{ .str = "value1" } } },
        .{ .obj = .root, .key = "key02", .value = .{ .scalar = .{ .str = "value2" } } },
        .{ .obj = .root, .key = "key03", .value = .{ .object = .map } },
        .{ .obj = .root, .key = "key04", .value = .{ .scalar = .{ .str = "value4" } } },
        .{ .obj = .root, .key = "key05", .value = .{ .object = .map } },
        // **`key06` is not here.** The root's sixth register was created and
        // then deleted, so it holds nothing.
        .{ .obj = .root, .key = "key07", .value = .{ .object = .map } },
        .{ .obj = .root, .key = "key08", .value = .{ .object = .list } },
        .{ .obj = .root, .key = "key09", .value = .{ .object = .map } },
        .{ .obj = .root, .key = "key10", .value = .{ .object = .map } },
        .{ .obj = .root, .key = "key11", .value = .{ .object = .list } },
        .{ .obj = .root, .key = "key12", .value = .{ .object = .map } },
        .{ .obj = .root, .key = "key13", .value = .{ .object = .text } },
        // The children, **lowest object id first**: `map1` (3), `map2` (5,
        // empty, skipped), `map4` (7), `list1` (8), `map5` (9, skipped),
        // `map6` (10), `list2` (11), `map7` (12, skipped), `text1` (13).
        .{ .obj = map1, .key = "m1key1", .value = .{ .scalar = .{ .str = "m1value1" } } },
        .{ .obj = map4, .key = "m4key1", .value = .{ .scalar = .{ .str = "m4value1" } } },
        .{ .obj = map4, .key = "m4key2", .value = .{ .scalar = .{ .str = "m4value2" } } },
        // **A sequence item has no key** (`iter/doc.rs:365-371`), which is
        // why upstream's own table writes `""` for these three.
        .{ .obj = list1, .key = "", .value = .{ .scalar = .{ .str = "l1e1" } } },
        .{ .obj = list1, .key = "", .value = .{ .scalar = .{ .str = "l1e2" } } },
        .{ .obj = list1, .key = "", .value = .{ .scalar = .{ .str = "l1e3" } } },
        // **`m6key2` is not here, and neither is any of `map3`'s three**: one
        // is deleted and the other's only property is.
        .{ .obj = map6, .key = "m6key1", .value = .{ .scalar = .{ .str = "m6value1" } } },
        .{ .obj = map6, .key = "m6key3", .value = .{ .scalar = .{ .str = "m6value3" } } },
        .{ .obj = list2, .key = "", .value = .{ .scalar = .{ .str = "l2e1" } } },
        // **The text object is last and is one answer**, not eleven: the
        // spans reader folds a run into a single span, and a span is one item
        // whatever its width.
        .{ .obj = text1, .key = "", .value = .{ .scalar = .{ .str = "hello world" } } },
    };

    var it = try DocIter(opmod.Op).init(gpa, &handle, .root, .map, null);
    defer it.deinit();

    // **The sequence, not the set.** Every assertion is an index into one
    // expected list and the index only moves when an answer arrives, so a
    // walk that visited a later child first would report the same twenty-two
    // items in a different order and fail on the thirteenth. That is the
    // whole reason the queue takes a minimum and not a maximum.
    var seen: usize = 0;
    while (try it.next()) |got| {
        // **`var`, because the text arm owns what it read** and has to give it
        // back — the same reason [`DiffIter.log`] copies its item out of the
        // `while` capture.
        var item = got;
        defer item.deinit(gpa);
        if (seen >= answers.len) return error.TestUnexpectedResult;
        const want = answers[seen];
        try testing.expectEqual(want.obj.opId(), item.obj.opId());
        // **The key is null for anything that is not a map register**, and the
        // table's `""` is upstream's spelling of that rather than an empty
        // key — asserting the null is what tells the two apart.
        switch (item.item) {
            .map => |m| try testing.expectEqualStrings(want.key, m.key),
            .list, .text => try testing.expect(item.key() == null),
        }
        try testing.expect(sameValue(item.value(), want.value));
        seen += 1;
    }
    // **And the walk is over**, which is the half of upstream's
    // `max(answers.len(), values.len())` a length assertion cannot state: a
    // second `next` must answer null again rather than carry on.
    try testing.expectEqual(answers.len, seen);
    if (try it.next()) |_| return error.TestUnexpectedResult;
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`doc::DocIter` is now ported**, with its item types: [`DocIter`],
//   [`DocIterInternal`], [`DocObjItem`], [`DocObjItemInternal`], [`DocItem`]
//   and [`DocItemInternal`] — [`iter/doc.rs:18-51`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)
//   (`:42-50` the constructor), `:53-63` and `:321-334` (the internal walk),
//   `:336-346` and `:364-380` (the two item structs), and `:382-394`,
//   `:454-499` (the two item enums and their `make_obj`/`export`).
//   **`ObjIdIter` is not it and never was**: that is
//   `OpSet::obj_id_iter` (`op_set.rs:1344-1346`), one object per step, while
//   `DocIter` reads *properties* through the three leaf readers and descends
//   into every object its visible items name. The claim that the port had
//   renamed one into the other is retired with this.
//
// * **Upstream's only test in this file is ported: `doc_iter`,
//   [`iter/doc.rs:532-602`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
//   as "the recursive walk reads the root's rows, then every child, parents
//   before children".** It is written as **rows, not transactions**, because
//   this directory has no transaction layer: every `tx.put`,
//   `tx.put_object`, `tx.splice_text`, `tx.insert` and `tx.delete` becomes the
//   row that operation would have written, at **the counter it would have
//   used** — which matters twice, because an object *is* the operation that
//   created it (`op_set.zig:1287-1291`) and the queue takes the lowest id
//   first.
//
// * **The test has twenty-two answers, not the twenty-one this file's last
//   diff block claimed.** Count `iter/doc.rs:575-596`: twelve root registers
//   (`key06` is created and then deleted), then `m1key1`, `m4key1`, `m4key2`,
//   `l1e1`, `l1e2`, `l1e3`, `m6key1`, `m6key3`, `l2e1` and `hello world` —
//   twenty-two lines, and the port asserts all twenty-two **in order**, plus
//   the object each property hangs by, which upstream does not check.
//
// * **The order is asserted as a sequence and the queue takes a minimum.**
//   Upstream keeps its children in a `BTreeMap<ObjId, IterType>`
//   ([`iter/doc.rs:55`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
//   `:68`) and takes them with `pop_first` (`:243`, `:146`). The port's
//   [`ObjQueue`] is an ordered array and [`ObjQueue.popLowest`] is the linear
//   minimum over it — **now the one copy of that rule for both walks**, where
//   `DiffIter` had its own. Perturbed to take the maximum, the *item* walk's
//   test fails on the thirteenth answer and the *diff* walk's fails on the
//   fifth; a walk that visited a later child first yields the same **set** of
//   answers in a different order, so neither test would notice if it counted
//   them instead of comparing them one at a time.
//
// * **The two deletes in the fixture are successor edges and there is no
//   delete row.** `Columns::splice` drops every op whose action is `Delete`
//   ([`columns.rs:423-427`](../opset/columns.zig)), and what makes `key06`
//   and `m6key2` *absent* rather than present with the value they used to
//   hold is the edge on the row each replaced
//   ([`shadowedRow`]). Without it the register is visible and `top`, and the
//   walk would report a `"key06"` and an `"m6key2"` that upstream's does not.
//
// * **`DocItemInternal::make_obj` has no visibility guard, and
//   [`DiffItem.makeObj`] has one** — [`iter/doc.rs:475-499`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)
//   against `:415-446`. That is upstream's asymmetry and not a port
//   correction: these three readers only ever hand out *visible* rows, so a
//   deleted register never reaches them and never queues its object, while a
//   **diff** item names the value a register used to hold and has to be asked.
//   A walk that queued a deleted object's id would descend into an object the
//   document has no property of — which is what upstream's own test answers
//   show, `map3`'s three rows never appearing.
//
// * **`DocIterInternal` records no `path_map`, where upstream's writes one**
//   ([`iter/doc.rs:56`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
//   written at `:218`, filled from [`DocItemInternal::prop`] at `:454-465`).
//   **Nothing in the crate reads it**: the only read of a field by that name
//   is `DiffIter::log` returning *its own* (`:91`), and `PatchBuilder` has
//   its own map ([`patch_builder.rs:39,147`](../../github-automerge-automerge/rust/automerge/src/patches/patch_builder.rs)).
//   The diff walk's map **is** ported, because that one has a reader and
//   `src/doc.zig` feeds it to `path_hint` (`automerge.rs:1078-1079`).
//
// * **`DocIter::empty` (`iter/doc.rs:25-33`) is not ported as a type.**
//   Upstream's is `Option<&OpSet>` plus three default readers and `iter_for`
//   (`automerge.rs:1669-1674`) reaches for it when an object id names
//   nothing; the port's leaf readers are not optional for the same reason
//   they were not ([`MapDiff.op_set`](map_range.zig)) — a caller with no
//   object scopes to an **empty row range**, and builds the same walk.
//   [`read.iterAt`](../../src/read.zig) is that caller.
//
// * **`DocObjItem.value` returns a [`ValueRef`] and not an `Option<…>`, and
//   allocates nothing.** Upstream's text arm is
//   `ValueRef::str(span.as_str()).into_owned()` (`iter/doc.rs:377`) because a
//   Rust `ValueRef<'a>` has one lifetime for "borrowed from the op set" and
//   "borrowed from this span"; here the span *is* the borrow, so the returned
//   slice points into the item and every arm has a value — which is why
//   upstream's `Option` is always `Some`. **`DocObjItem.obj` is an [`ExId`]
//   and not an `Arc<ExId>`**. The refresh is kept,
//   so the actor table is read once per object rather than once per
//   item (`iter/doc.rs:294-298`).
//
// * **`DocItemInternal::export` is `DocItemInternal::exportItem` here**, and
//   that is a naming deviation forced by the target language:
//   `export` is a Zig keyword, so `pub fn export` is a **parse** error rather
//   than a shadowing warning, and the whole module — with it every test in
//   the tree — fails to build. Upstream's name is on the method's doc comment
//   ([`iter/doc.rs:464-474`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs))
//   and [`SpanInternal.exportSpan`](spans.zig) keeps its own upstream
//   spelling, which is not a keyword. It is the same rename
//   [`MapDiffItem.exportItem`](map_range.zig) and
//   [`ListDiffItem.exportItem`](list_range.zig) already carry, for the same
//   reason. **Every other declaration ported here keeps its upstream name**:
//   `DocIter`, `DocIterInternal`, `DocObjItem`, `DocObjItemInternal`,
//   `DocItem`, `DocItemInternal`, and `make_obj` as `makeObj`,
//   `next_object` as `nextObject`, `next_prop` as `nextProp`,
//   `process_item` as `processItem`.
//
// * **`doc::DiffIter` had no test in this file, though four callers in
//   `src/doc.zig` drive it.** Its test "the document diff reads the root's
//   rows and then descends into each child, in order" is the one that reaches
//   `next_object`
//   ([`iter/doc.rs:135-147`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)),
//   which is the **only** place in this crate where a range reader is
//   shifted forward: `map_iter.shift_next` at `:141` and
//   `list_iter.shift_next` at `:142`. It walks a root map holding three
//   children — a map and two lists — and asserts the nine answers in order,
//   with each list's element index.
//
// * **`processItem` records the path whether or not the walk descends.**
//   [`iter/doc.rs:126-128`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)
//   inserts into `path_map` outside the `recursive` test, and only the
//   descent is optional. Both halves of the diff walk's test assert it: the
//   non-recursive walk answers four items and still carries three paths.
//
// * **The entry point is [read.zig](../../src/read.zig)'s.** Upstream reaches
//   `DocIter` through `Automerge::iter` / `ReadDoc::iter_at`
//   ([`read.rs:60,68-76`](../../github-automerge-automerge/rust/automerge/src/read.rs),
//   [`automerge.rs:1669-1674`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//   and the port spells it [`read.iter`](../../src/read.zig) /
//   [`read.iterAt`](../../src/read.zig): resolve the id, build the clock, hand
//   over the [`Doc`] handle — the two lines upstream's `iter_for` writes, and
//   no more.

test "API parity extracted document text survives item destruction" {
    const gpa = testing.allocator;
    var item: DocObjItem(opmod.Op) = .{
        .obj = .root,
        .item = .{ .text = .{ .text = .{
            .text = try gpa.dupe(u8, "detached text"),
            .marks = null,
        } } },
    };
    var owned = try item.valueOwned(gpa);
    defer owned.deinit(gpa);
    item.deinit(gpa);
    try testing.expectEqualStrings("detached text", owned.value.scalar.str);
}

test "API parity document and diff walks resolve named objects and never alias unknown IDs to root" {
    const gpa = testing.allocator;
    const child = made(1, 0);
    const doc = try Fixture.build(gpa, encoding, &.{ actor_a, types.ActorId.init("other") }, &.{
        row(opId(1, 0), .root, .{ .map = "m" }, false, .make_map, .null_value, null),
        row(opId(2, 0), .root, .{ .map = "root" }, false, .set, .{ .str = "root-value" }, null),
        row(opId(3, 0), child, .{ .map = "child" }, false, .set, .{ .str = "child-value" }, null),
    });
    defer doc.destroy();
    const handle: Doc(opmod.Op) = .init(&doc.set, encoding);
    const named = ObjId.withActor(opId(1, 1), actor_a);
    var values = try DocIter(opmod.Op).init(gpa, &handle, named, .map, null);
    defer values.deinit();
    var value = (try values.next()) orelse return error.TestExpectedItem;
    defer value.deinit(gpa);
    try testing.expectEqualStrings("child", value.key().?);
    try testing.expect(value.obj.eql(ObjId.withActor(opId(1, 0), actor_a)));
    try testing.expect((try values.next()) == null);
    var changes = try DiffIter(opmod.Op).init(gpa, &handle, named, .map, .{ .current = null }, true);
    defer changes.deinit();
    const change = (try changes.next()) orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("child", change.item.map.key);
    try testing.expectEqual(opId(1, 0), change.obj.opId().?);
    try testing.expect((try changes.next()) == null);
    const absent = [_]ObjId{
        ObjId.withActor(opId(1, 0), .init("unknown")),
        ObjId.withActor(opId(9, 0), actor_a),
        .{ .named = .{ .op = .{ .counter = 4294967296, .actor = 0 }, .actor = actor_a } },
        .{ .id = opId(1, 99) },
        ObjId.withActor(opId(0, 0), actor_a),
    };
    for (absent) |missing| {
        for ([_]types.ObjType{ .map, .list, .text }) |typ| {
            var empty_values = try DocIter(opmod.Op).init(gpa, &handle, missing, typ, null);
            defer empty_values.deinit();
            try testing.expect((try empty_values.next()) == null);
            var empty_changes = try DiffIter(opmod.Op).init(gpa, &handle, missing, typ, .{ .current = null }, true);
            defer empty_changes.deinit();
            try testing.expect((try empty_changes.next()) == null);
        }
    }
}
