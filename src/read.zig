//! The read surface: everything a caller can ask a document without changing
//! it.
//!
//! Upstream `read.rs` ([read.rs:15-311](../../github-automerge-automerge/rust/automerge/src/read.rs))
//! is a **pure trait**: thirty method signatures, no body, and not one op-set
//! call in the file. It names `op_set2::Parents` (`:7`) and `Stats` (`:313-330`)
//! and everything else. The bodies are in
//! [`impl ReadDoc for Automerge`](../github-automerge-automerge/rust/automerge/src/automerge.rs)
//! (`:2073-2320`) and in the `*_for` helpers it calls
//! (`:1569-1971`). **In this port the trait and the implementation are one
//! file**, because there is one concrete
//! [`Document`](doc.zig) rather than a trait with two implementors
//! ([plan §3.2](../../docs/plan.md)); upstream's `Automerge` and `AutoCommit`
//! are one type with a `mode` flag here, so the thirty methods become free
//! functions over `*const Document`.
//!
//! # Every method here is a surface over something that already answers it
//!
//! No method in this file computes a document answer. Each one is a
//! [`docmod.Document`](doc.zig) method, an [`opsetmod.OpSet`](opset/op_set.zig)
//! entry point, an [`iter/`](iter/) walk, a [`cursormod`](cursor.zig) function,
//! or a [`parentsmod.Parents`](opset/parents.zig) walk — and each one says
//! which, with a `path:line`. **A reader that recomputed one of those would be
//! a second source of truth for it**, which is the defect
//! [docs/STATUS.md](docs/STATUS.md) records as the port's most transferable
//! lesson, and the reason [`parents`] does not walk the object columns itself
//! when [`OpSet.parentObject`](opset/op_set.zig) already answers it.
//!
//! # The ownership rule, and why it is written on every method
//!
//! [plan §5.4](../../docs/plan.md) requires that "every public type that can
//! return borrowed data states its owner in the signature", and
//! [AGENTS.md](AGENTS.md) that a slice into a document's storage "is valid
//! until the next mutation". **Neither is inferable from a Zig signature** — a
//! `[]const u8` and a `[]u8` look alike — so every method below says which it
//! is. The three shapes that occur here, and what each costs the caller:
//!
//! | shape | methods | the caller's obligation |
//! |---|---|---|
//! | **borrowed** | [`get`], [`getAll`], [`keys`], [`values`], [`marks`], [`parents`], [`mapRange`], [`listRange`] | do not read the borrowed bytes after the next mutation; take `intoOwned` if the caller has to keep one |
//! | **caller-owned** | [`text`], [`getAll`]'s slice, [`getMarks`]'s slice, [`markSetAtIndex`]'s set, [`getMissingDeps`]'s slice, [`getChangeByHash`]'s change, [`spans`]'s spans | free with the allocator the method was given |
//!
//! **Every `*At` reader has the shape its unsuffixed sibling has, and says so
//! by naming it** — [`getAt`] is [`get`], [`keysAt`] is [`keys`] — because
//! they are the same body with one argument changed. **The six that hand back
//! a walk carry one obligation the unsuffixed ones do not: the clock they
//! read is the document's, so the walk is over before the next `_at` read at
//! other heads.** The *Historical reads* section below is where that is
//! argued.
//!
//! **A `Cursor` is a value, and that is the whole point of the type**: it names
//! an element by its operation id, not by an index, so it survives every
//! mutation that does not remove that element. The test
//! `test "a cursor taken before a mutation still names the same element after it"`
//! is the one that would fail if this file answered a cursor with an index.
//!
//! # What is deliberately not here
//!
//! * **`Document.hydrate(heads)`.** Upstream's
//!   [`Automerge::hydrate`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1633-1636
//!   is this file's [`hydrate`] at the root and nothing else — one walk with no
//!   object argument — so a caller writes
//!   `read.hydrate(&doc, .root, heads, gpa)`. It is not a second method here
//!   and `API.md` §Read names none.
//! * **`DocIter::empty`.** Upstream's [`iter/doc.rs`:25-33](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)
//!   is an `Option<&OpSet>` plus three default readers, which
//!   [`Automerge::iter_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1673
//!   reaches for when an id names nothing. The port builds the same walk over
//!   an object with no rows, which answers nothing for the same reason — see
//!   [`iterAt`].
//! * **Nothing else.** Every other `ReadDoc` method that names `heads`
//!   upstream is ported: the eleven `_at` readers are [`getAt`], [`getAllAt`],
//!   [`lengthAt`], [`keysAt`], [`valuesAt`], [`textAt`], [`spansAt`],
//!   [`marksAt`], [`mapRangeAt`], [`listRangeAt`] and [`parentsAt`], plus
//!   [`iterAt`], which carries its heads under upstream's own
//!   `Option<&[ChangeHash]>`; the three
//!   that carry `at: Option<&[ChangeHash]>` **on the method itself** are
//!   [`getCursor`], [`getCursorMoving`] and [`getCursorPosition`], one
//!   signature each and in upstream's argument order (`read.rs:203, 228, 241`);
//!   and [`hydrate`], [`markSetAtIndex`] and [`getMissingDeps`] already had one.
//!
//! **One naming deviation, and it is in this file's favour.** Upstream spells
//! the parameter `at` in the signatures that carry it on the method itself
//! (`read.rs:203, 228, 241` for the three cursor readers, `:60` for
//! [`iterAt`]) and `heads` in the `_at` ones; the port spells all of them
//! `heads`, so one convention covers the surface and [`atScope`] takes one
//! name too. **The name is upstream's as well as the port's** — upstream's
//! bodies destructure the argument the same way, `at.and_then(|heads|
//! self.clock_at(heads))` (`automerge.rs:2098`, `:2175`, `:2186`, `:2196`) —
//! so this is upstream's own binding and not a renaming of one.
//!
//! # Historical reads
//!
//! **Upstream's `ReadDoc` carries a read at `heads` beside almost every read
//! of the present, and this file has every one of them.** Every one of
//! them is the unsuffixed body with one thing changed — the clock, whether the
//! heads arrive in the name or as an argument — and upstream's own wrappers are
//! two lines that say exactly that: `let clock = self.clock_at(heads);` then
//! `self.*_for(.., clock)`
//! **Nothing else in this file needed new machinery**, because every walk it
//! hands back already took `?Clock` and every [`OpSet`](opset/op_set.zig) entry
//! point it calls already took one; the single exception is [`getAllAt`],
//! where the twenty-line dispatch under [`getAll`] is now shared with
//! [`getAllAtScope`] rather than written twice, and [`parentsAt`], which
//! shares the empty-walk branch for the same reason. The one thing that *did*
//! need building is [`Document.clockAtScope`](doc.zig) — upstream's
//! `Automerge::clock_at` with its heads-are-current shortcut, which this file
//! needed as a *sibling* of [`Document.readScope`](doc.zig) rather than as a
//! new field: a walk copies the clock by value, so the clock's `slots` have
//! to outlive the walk, and both readers share the document's one cache.
//!
//! ## `heads` that are the present
//!
//! **`*_at(getHeads())` is the unsuffixed read, and that is upstream's own
//! shortcut rather than an approximation.**
//! [`Automerge::clock_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1236-1247
//! returns `None` — an unscoped read of the present — "when `heads` is exactly
//! the current heads, so `*_at(doc.get_heads())` takes the same indexed fast
//! paths as the un-suffixed methods", and [`atScope`] returns that `None` too.
//! **A test that passes the document's own heads therefore proves nothing
//! about a historical read**, because it exercises the shortcut; the tests for
//! these methods name heads the present has moved past.
//!
//! ## What a historical read resolves its object id against
//!
//! **The same actor table the present uses — and that is upstream's, not a
//! port's convenience.** The worry is real and worth naming: `ExId` carries
//! the actor's **bytes** and a stale index is repaired by
//! [`Document.resolve`](doc.zig), so a reader that handed the caller's id to
//! the op set without resolving it would look up the wrong actor whenever an
//! `isolate` has interned a concurrency actor ahead of the one the id was
//! minted under. Upstream's `exid_to_opid`
//! ([`automerge.rs`:744-758](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
//! does the same repair — `get_actor_safe(idx)` and then `lookup_actor(actor)`
//! — and **it takes no clock**, because it reads `self.ops`: the op set's
//! actor table is the whole document's, not a version of it. `exid_to_obj`
//! then asks `self.ops.object_type` (`:788-792`, `:760-768`), again with no
//! clock. **A [`Clock`] is a per-actor vector of op counters**
//! ([`clock.zig`](clock.zig):59-77): it scopes *rows*, and an object index and
//! an actor table are not rows. So "an id valid for the present may not be for
//! those heads" does not hold for the id — what those heads can exclude is the
//! object's **rows**, and every reader here finds the object first and reads
//! its rows under the clock.
//!
//! **Every reader below resolves, and the resolution is where the port says
//! so**: [`liveObj`] for the readers that refuse an id naming nothing,
//! [`liveObjOrSelf`] for the three whose answer is an empty walk rather than
//! an error. **The order of the two — resolve, then build the clock — is free
//! in this port and is upstream's anyway.** Neither step can intern an actor:
//! [`OpSet.lookupActor`](opset/op_set.zig) is `*const Self` and a binary
//! search (`:1476-1488`), and [`ChangeGraph.clockAt`](change_graph.zig) sizes
//! a [`Clock`] from `numActors()` and reads the graph (`:464-474`).
//!
//! # `*const Document`, and the one place the const is dropped
//!
//! `API.md` §Read states the surface as `doc: *const Document` "so a read never
//! needs a mutable borrow, which is what lets iterators be plain values". That
//! holds here: nothing in this file writes to a document. But a walk over the
//! op set moves that op set's **shared** successor buffer and top-walk scratch
//! ([op_set.zig:638-640](../opset/op_set.zig)'s module doc, third and fourth
//! sections), so `OpSet.topOps` and every `iterRange` take `*Set` rather than
//! `*const Set`. [`mutableOps`] is where the const is dropped, and it says so;
//! every use of it is one of those two.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");
const value = @import("value.zig");
const docmod = @import("doc.zig");
const opmod = @import("opset/op.zig");
const optypes = @import("opset/types.zig");
const opitermod = @import("opset/op_iter.zig");
const opsetmod = @import("opset/op_set.zig");
const parentsmod = @import("opset/parents.zig");
const marksmod = @import("marks.zig");
const clockmod = @import("clock.zig");
const cursormod = @import("cursor.zig");
const iterdoc = @import("iter/doc.zig");
const hydmod = @import("hydrate.zig");
const iterkeys = @import("iter/keys.zig");
const itervalues = @import("iter/values.zig");
const iterspans = @import("iter/spans.zig");
const patchesmod = @import("patches.zig");
const itermap = @import("iter/map_range.zig");
const iterlist = @import("iter/list_range.zig");

const Allocator = std.mem.Allocator;
const ChangeHash = types.ChangeHash;
const ChangeOp = opmod.ChangeOp;
const Clock = clockmod.Clock;
const Document = docmod.Document;
const ElemId = types.ElemId;
const Error = err.Error;
const ExId = types.ExId;
const InternalError = err.InternalError;
const Mark = marksmod.Mark;
const MarkSet = marksmod.MarkSet;
const ObjType = types.ObjType;
const Op = opmod.Op;
const OpId = types.OpId;
const ParseError = err.ParseError;
const Prop = types.Prop;
const ScalarValue = optypes.ScalarValue;
const SequenceType = types.SequenceType;
const Set = docmod.Set;
const Stats = docmod.Stats;
const TextEncoding = types.TextEncoding;
const ValueRef = optypes.ValueRef;

const testing = std.testing;

// ── What a read can raise ───────────────────────────────────────────────────

/// What every method in this file can raise.
///
/// **The union of the three sets the walks name, and the reason it is not
/// `Error` alone.** [`err.Error`](error.zig) is the document API's set, and a
/// walk over the op set's columns raises
/// [`opitermod.ReadOpError`](opset/op_iter.zig) — `InvalidOpId`, `InvalidKey`,
/// `MissingKey`, `MissingValue` and the `ParseError` members that set drags in
/// ([op_iter.zig:149-160](../opset/op_iter.zig)) — which is neither a subset
/// of `Error` nor of `ParseError`. A reader that turned one of those into
/// `null` or into `0` would answer "no such object" for a document that has
/// one, which is the defect [docs/STATUS.md](docs/STATUS.md) names as "a
/// reader that is more permissive than its writer hides the writer's bug". So
/// this set is the union, and it is the same union under four names in the
/// crate: [`docmod.OpError`](doc.zig), [`iterkeys.KeysError`](iter/keys.zig),
/// [`itermap.ReadError`](iter/map_range.zig) and
/// [`docmod.MarkError`](doc.zig).
pub const ReadError = opitermod.ReadOpError || Error || InternalError;

/// What [`getChangeByHash`] can raise.
///
/// **Wider than [`ReadError`] and not by accident.** A document chunk stores
/// the change graph's metadata and the op set's rows, not the change chunks, so
/// the collector that rebuilds a change re-encodes it and can raise anything
/// the encoder and the op set's own load path raise
/// ([`docmod.DocumentError`](doc.zig)). A reader that narrowed this to
/// [`ReadError`] would have to answer something else for a change the document
/// holds, and "something else" for a change is a change with the wrong bytes.
pub const ChangeError = docmod.DocumentError;

/// What [`hydrate`] can raise.
///
/// **[`ReadError`] plus the mark fold's own set, and the second half is not an
/// accident.** [`hydmod.hydrateText`] folds the mark rows into the mirror
/// (hydrate.zig, over [`OpSet.calculateMarksAt`](../opset/op_set.zig)), and
/// that fold raises [`opsetmod.MarksError`](../opset/op_set.zig) — which is
/// neither [`ReadError`] nor a subset of it. **The three other arms
/// ([`hydmod.hydrateMap`], [`hydmod.hydrateList`], [`hydmod.hydrateOp`]) raise
/// no more than [`ReadError`]**, so this is the narrowest set that covers all
/// four, and it is [`hydmod.OpHydrateError`] rather than a name of this file's
/// because that is where the union is declared.
pub const HydrateError = hydmod.OpHydrateError;

// ── The surface's types ─────────────────────────────────────────────────────

/// An object's keys, one per visible register
/// ([`Keys`](iter/keys.zig), `iter/keys.rs:7-28`).
///
/// **Returned by value and it owns nothing**: it is a pointer to the document's
/// op set, a winner walk, and a fixed buffer. Free the winner walk with
/// [`Keys.deinit`](iter/keys.zig), passing [`Document.allocator`](doc.zig).
///
/// The walk borrows the document's successor buffer, so **only one `Keys` over
/// one document may be live at a time**
/// ([op_set.zig:40-49](../opset/op_set.zig)).
pub const Keys = iterkeys.Keys(ChangeOp);

/// The winner walk [`values`] reads through
/// ([`TopQuery`](iter/values.zig), `op_set.rs:1085-1091`).
///
/// **The caller holds it and frees it.** `Values` stores a `*I` and has no
/// allocator of its own, so the term has to outlive the walk and something has
/// to free it — see [`values`] for why [`values`] fills one rather than
/// building one inside a returned value.
///
/// The buffers were allocated by the **document's** allocator
/// ([`OpSet.topOps`](opset/op_set.zig)), so free with
/// [`Document.allocator`](doc.zig), not with an allocator the caller chose.
pub const ValueTerm = itervalues.TopQuery(ChangeOp);

/// An object's values, one per visible register, with the id each came from
/// ([`Values`](iter/values.zig), `iter/values.rs:8-36`).
pub const Values = itervalues.Values(ChangeOp, ValueTerm);

/// The sequence of block markers and text spans of a text object
/// ([`Spans`](iter/spans.zig), `iter/spans.rs:283-288`).
///
/// **Owns its fold and gives it back** with [`Spans.deinit`](iter/spans.zig),
/// which takes no allocator because the fold remembers the one
/// [`Spans.init`](iter/spans.zig) was given. **The spans it hands out are the
/// caller's**, and each carries owned text and an owned mark set:
/// [`Span.deinit`](iter/spans.zig) frees both. The mark *names* inside a span
/// are the document's and are not freed.
pub const Spans = iterspans.Spans(ChangeOp);

/// A map object's visible keys, one at a time
/// ([`MapRange`](iter/map_range.zig), `iter/map_range.rs:94-213`).
pub const MapRange = itermap.MapRange(ChangeOp);

/// One key of a map, as a reader sees it
/// ([`MapRangeItem`](iter/map_range.zig), `iter/map_range.rs:13-20`).
///
/// **The key and the scalar payload are borrowed** from the document's string
/// table and value column and are valid until the next mutation of it;
/// [`MapRangeItem.intoOwned`](iter/map_range.zig) is the copy for a caller
/// that has to hold one across a mutation.
pub const MapRangeItem = itermap.MapRangeItem(ChangeOp);

/// A sequence object's visible elements, one at a time
/// ([`ListRange`](iter/list_range.zig), `iter/list_range.rs:255-357`).
pub const ListRange = iterlist.ListRange(ChangeOp);

/// One visible element of a sequence
/// ([`ListRangeItem`](iter/list_range.zig), `iter/list_range.rs:14-20`).
///
/// **The value is borrowed** from the document and is valid until the next
/// mutation of it; [`ListRangeItem.intoOwned`](iter/list_range.zig) is the
/// copy.
pub const ListRangeItem = iterlist.ListRangeItem(ChangeOp);

/// A half-open range of element indices
/// ([`IndexRange`](iter/list_range.zig), which is
/// [API.md](../API.md)'s `struct { start: usize, end: ?usize }` and upstream's
/// `RangeBounds<usize>` made concrete).
pub const IndexRange = iterlist.IndexRange;

/// The walk from an object up to the document root
/// ([`Parents`](opset/parents.zig), `op_set2/op_set/parents.rs:14-18`).
///
/// **Returned by value, owning nothing**: a pointer to the document's op set, a
/// clock, and a budget. There is no `deinit` because there is nothing to free.
///
/// Each `Parent`'s [`prop`](opset/parents.zig) is **borrowed** from the
/// document's string table when it is a map key, and is valid until the next
/// mutation of the document.
pub const Parents = parentsmod.Parents(ChangeOp);

/// The recursive walk over a document's items
/// ([`DocIter`](iter/doc.zig), `iter/doc.rs:19-50`).
///
/// **Owned by the caller and freed with [`deinit`](iterdoc.DocIter.deinit)**,
/// which takes no allocator: the walk owns the spans fold's buffers and the
/// object queue and nothing else.
pub const DocIter = iterdoc.DocIter(ChangeOp);

/// One property of one object, as [`DocIter`] hands it out
/// ([`DocObjItem`](iter/doc.zig), `iter/doc.rs:337-341`).
pub const DocObjItem = iterdoc.DocObjItem(ChangeOp);

/// What the recursive walk can fail with ([`iterdoc.DiffError`](iter/doc.zig)).
pub const DiffError = iterdoc.DiffError;

/// A stable address in a sequence
/// ([`Cursor`](cursor.zig), `cursor.rs:19-26`).
pub const Cursor = cursormod.Cursor;

/// Where in a sequence a cursor is
/// ([`CursorPosition`](cursor.zig), `cursor.rs:49-55`).
pub const CursorPosition = cursormod.CursorPosition;

/// Which way a cursor moves when the element it names is removed.
///
/// **`API.md` names this `Bias`; the port's cursor module names it
/// `MoveCursor`** ([`cursor.zig:222-227`](cursor.zig), upstream `cursor.rs:70-74`).
/// It is one enum under two spellings, and this is the name the contract uses,
/// so it is the name this file's signature has. `read.Bias.before` and
/// `cursor.MoveCursor.before` are the same value.
pub const Bias = cursormod.MoveCursor;

/// One value and the operation that put it there
/// ([`ReadDoc::get`](../../github-automerge-automerge/rust/automerge/src/read.rs):259-263
/// returns the tuple `(Value, ExId)`;
/// [docs/plan.md §5.4](../../docs/plan.md) names the pair `DocItem`).
///
/// **The pair is a copy; the bytes inside it are the document's.** A
/// [`ValueRef`]'s `str`, `bytes`, `actor_id` or `unknown` payload, and a
/// [`Prop.key`](types.zig) slice, all point into the op set's value column or
/// string table, so a `DocItem` is valid until the next mutation of the
/// document — which is upstream's `Value<'a>` borrow
/// ([read.rs:263](../../github-automerge-automerge/rust/automerge/src/read.rs))
/// and [AGENTS.md](AGENTS.md)'s rule, and is why the type is a struct and not
/// an `Owned` one.
///
/// **`value` is [`ValueRef`], which is upstream's `types::Value`**
/// ([op_set2/types.rs:667-675](../opset/types.zig)): `object` carries the
/// object's **type**, not its id, because the id is the second field. The
/// port declares that shape twice — here borrowed, and again as
/// [`patches.Value`](patches.zig) with arena-owned payloads — and a third
/// time as [`value.Value`](value.zig) with `object: ExId`, which cannot
/// express "an object and its type" and is therefore not this method's
/// return.
pub const DocItem = struct {
    /// What the operation carries: a scalar, or an object and its type
    /// ([`Op::value`](opset/op.zig), `op.rs:1096-1106`).
    value: ValueRef,
    /// The id of the operation that put the value there
    /// ([`Op::exid`](opset/op.zig), reached through
    /// [`OpSet.idToExid`](opset/op_set.zig), `op_set.rs:1054-1060`).
    ///
    /// For a value that **is** an object, this is that object's id: a make
    /// action's own id *is* the id of the object it makes
    /// ([doc.zig:2073-2081](../opset/op_set.zig)'s object index is keyed by
    /// the creating op). For a scalar it is the id of the operation, which is
    /// what disambiguates the rows of a conflicted register
    /// ([read.rs:251-253](../../github-automerge-automerge/rust/automerge/src/read.rs)).
    id: ExId,
};

/// One end of a [`KeyRange`]: upstream's `Bound<&str>` at that end
/// ([`OpSet::map_range`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs):406-416).
///
/// **The excluded arm is not decoration, and the C binding is why.** The
/// reference's `AMmapRange` builds Rust's `begin..end`
/// ([`automerge-c/src/doc/map.rs:518-529`](../../github-automerge-automerge/rust/automerge-c/src/doc/map.rs))
/// and documents `end` as "The key one past the last key in a subrange"
/// (`:482-483`), so a C caller **cannot name an inclusive end at all** — there
/// is no header entry for one. A pair of optional keys could not say it
/// either, which is what [`OpSet.mapRange`](opset/op_set.zig)'s parameters used
/// to be.
///
/// **It is declared in [opset/op_set.zig](opset/op_set.zig) and re-exported
/// here, not declared twice.** [`OpSet.mapRange`](opset/op_set.zig) takes it,
/// that file cannot import this one, and a range bound means the same thing to
/// both — so there is one declaration and this name.
pub const KeyBound = opsetmod.KeyBound;

/// A range of map keys, which is upstream's `RangeBounds<String>` made
/// concrete the way [iter/list_range.zig](iter/list_range.zig)'s
/// [`IndexRange`] is for `RangeBounds<usize>`.
///
/// [API.md](../API.md) writes both ranges as `struct { start: usize, end:
/// ?usize }`, and a `usize` range cannot address a map key, so this one is
/// keyed.
///
/// **A null end is `Bound::Unbounded`** (`op_set.rs:407,413`) — the head or the
/// tail of the object — **and each non-null end is a [`KeyBound`]**, so all
/// four of upstream's arms are reachable and none is a second computation of
/// another. The two named constructors are the two shapes a caller has:
/// [`between`](KeyRange.between) is half-open and [`through`](KeyRange.through)
/// is closed, and `start` and `end` stay writable for a range that mixes the
/// arms.
///
/// **A key the object does not have** bounds the range **where it would sort**,
/// because upstream's `scope_to_value` is a B-tree descent that answers the
/// sorted insertion point (`op_set.rs:404`), and
/// [`OpSet.propRange`](opset/op_set.zig) answers the same thing: it counts the
/// rows it steps over, so a key that sorts below every register the object holds
/// answers the object's head and a key that sorts above every one of them
/// answers its tail. **The row a range starts or stops at is therefore a
/// property of the key's order, not of whether the object holds it.**
///
/// **A `start` at or past its `end`** is empty rather than a refusal — the
/// `@max` in [`OpSet.mapRange`](opset/op_set.zig), which is upstream's
/// `start..end` being a Rust `Range` ([`map_range.rs:204-208`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)).
pub const KeyRange = struct {
    /// The first key the reader answers, or null for the start of the object.
    start: ?KeyBound = null,
    /// The key the reader stops before, or null for the end of the object.
    end: ?KeyBound = null,

    /// The range that answers every key — the two `Unbounded` arms.
    pub fn all() KeyRange {
        return .{};
    }

    /// `start..end`, half-open: every key from `start` up to but **not**
    /// including `end`. **This is the shape the C binding builds**
    /// (`automerge-c/src/doc/map.rs:518-529`), and the shape [`IndexRange`]
    /// already is, so a C `AMmapRange` and a Zig `mapRange` over the same
    /// document answer the same keys.
    pub fn between(start: ?[]const u8, end: ?[]const u8) KeyRange {
        return .{
            .start = if (start) |k| .{ .included = k } else null,
            .end = if (end) |k| .{ .excluded = k } else null,
        };
    }

    /// `start..=end`, closed: both keys are answered. Upstream spells it
    /// `(Bound::Included(start), Bound::Included(end))`.
    pub fn through(start: ?[]const u8, end: ?[]const u8) KeyRange {
        return .{
            .start = if (start) |k| .{ .included = k } else null,
            .end = if (end) |k| .{ .included = k } else null,
        };
    }
};

// ── Helpers ─────────────────────────────────────────────────────────────────

/// The document's op set as a **mutable** pointer, for a walk that borrows it.
///
/// **The `const` is dropped and nothing writes through it.** A walk over an op
/// set moves that op set's shared successor buffer
/// ([op_set.zig:40-49](../opset/op_set.zig)'s fourth section) and, for a
/// winner walk, its top scratch as well, so `OpSet.topOps` and `OpSet.iterRange`
/// take `*Set`. This is the only place in the crate that casts the const away
/// for a read, and every caller of it is one of those two methods.
///
/// It is sound because **a read does not mutate a document** — every method
/// below either reads the columns or hands back a walk — and because the
/// walks that take this pointer borrow it rather than keep it. It is a
/// `*const Document` in the signature because
/// [API.md](../API.md) §Read says so, not because the op set is const-safe.
fn mutableOps(doc: *const Document) *Set {
    return @constCast(&doc.ops);
}

/// `obj` with its actor index resolved against the document's actor table, or
/// `error.NotAnObject` when it names nothing here
/// ([`Document.resolve`](doc.zig)).
///
/// **Every reader below resolves before it hands the id to the op set, and
/// that is upstream's shape rather than a port convenience.** Upstream's
/// `exid_to_obj` re-resolves the index
/// ([`automerge.rs:788-792`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and every one of these methods reaches it — `keys_for` (`:1662`),
/// `values_for` (`:1700`), `length_for` (`:1707`), `text_for` (`:1714`),
/// `spans_for` (`:1723`), `get_cursor_for` (`:1732`),
/// `get_cursor_position_for` (`:1760`), `map_range_for` (`:1676`),
/// `list_range_for` (`:1688`), `marks_for` (`:1851`), `parents_for` (`:1652`).
/// The port's `ExId` is reached one step further away — through
/// [`Document.idToExid`](doc.zig), which records the actor's bytes, and
/// [`Document.resolve`](doc.zig), which repairs the index when an `isolate`
/// has interned a concurrency actor ahead of the one the id was minted under.
fn liveObj(doc: *const Document, obj: ExId) Error!ExId {
    return doc.resolve(obj) orelse error.NotAnObject;
}

/// [`liveObj`] for the readers whose answer for an id that names nothing is an
/// **empty walk rather than an error** — upstream's
/// `.ok().map(..).unwrap_or_default()`.
///
/// **The fallback is the id itself and not the root**, and that is the whole
/// point of doing it this way: an id whose actor is no longer in the table
/// names nothing in this document, so handing it to the walk unanswered is
/// exactly what every reader here did before [`Document.resolve`] existed, and
/// the walk yields nothing. Mapping it to the root instead would answer with
/// the **root's** keys, length and elements — a true statement about a
/// different object.
fn liveObjOrSelf(doc: *const Document, obj: ExId) ExId {
    return doc.resolve(obj) orelse obj;
}

/// The clock every reader below hands to the op set, or null for an unscoped
/// read of the present ([`Document.readScope`](doc.zig), upstream's
/// `get_scope(None)` at `autocommit.rs:794-814`).
///
/// **It sits beside [`liveObj`] and not at each walk because that is where a
/// reader added later already has to come.** Upstream resolves the two in the
/// same call — `Automerge::get_for` is `get_for(&self, obj, prop, clock)`
/// ([`automerge.rs`:1859-1889](../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and `AutoCommit::get` fills that last argument from `get_scope(None)` —
/// so a reader here that resolved an object and then passed `null` where the
/// clock goes would not be a shape upstream can be written in. Eight of the
/// fourteen readers that call this return a **walk**, and a walk copies the
/// clock by value ([`TopOps`](opset/top_op.zig)'s field is a `?Clock`), so
/// the clock must outlive the reader; [`Document.readScope`](doc.zig) keeps it
/// on the document for exactly that reason and this copy borrows it.
///
/// **Nothing here frees the answer**, and that is the whole difference from
/// an owned clock: `scope` is a value the op set stores, and its `slots`
/// belong to the document.
///
/// **[`atScope`] is this function with the caller's heads in place of the
/// isolation's**, and it is what every `*At` reader below calls; the two share
/// the document's one cached clock ([`Document.clockAtScope`](doc.zig)).
fn readScope(doc: *const Document) Error!?Clock {
    const scope = try mutableDoc(doc).readScope(doc.gpa) orelse return null;
    return scope.*;
}

/// The clock a historical read at caller-named `heads` runs at, or null when
/// `heads` name the present
/// ([`Document.clockAtScope`](doc.zig), upstream's `Automerge::clock_at` at
/// [`automerge.rs`:1236-1247](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **This is [`readScope`] with the caller's heads in place of the
/// isolation's, and it is upstream's own shape rather than a port
/// convenience.** Every `*_at` on `Automerge` is `let clock =
/// self.clock_at(heads);` followed by the unsuffixed body with that clock
/// ([`automerge.rs`:2078-2280](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// and **`clock_at` and not `change_graph::clock_at` is the name those
/// wrappers use, because it carries the heads-are-current shortcut** — which
/// is what makes `*_at(get_heads())` answer as the present does. Every `*At`
/// reader below is exactly that two-line wrapper.
///
/// **`heads` here is never optional**, matching upstream's
/// `heads: &[ChangeHash]` on the ten `_at` methods
/// ([`read.rs`:40-55, 99-104, 118-123, 137, 149, 158-162, 180-184, 190-194, 266-271, 293-298](../../github-automerge-automerge/rust/automerge/src/read.rs))
/// — a caller that wants the present writes the unsuffixed name. **The three
/// cursor methods and [`hydrate`] are the exceptions upstream itself makes**
/// (`at: Option<&[ChangeHash]>`, [`read.rs`:172, 203, 228, 241, 276](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and the port reaches this through the same door, with `null` meaning **the
/// document's own read scope** rather than "no scope" — the reading
/// [`hydrate`] argues at length and [`markSetAtIndex`] already applies.
/// **Those three carry the heads as an argument rather than under a second
/// name, because upstream carries them as an argument**
/// ([`read.rs`:203, 228, 241](../../github-automerge-automerge/rust/automerge/src/read.rs));
/// the eleven above are still a second name, because upstream gives those a
/// second name too.
///
/// **Nothing here frees the answer, and the reason is the one
/// [`Document.clockAtScope`](doc.zig) gives.** A walk copies the [`Clock`] by
/// value and borrows only its `slots` ([`TopOps`](opset/top_op.zig):250), so
/// the slots have to outlive the walk the reader hands back; the document
/// caches them and frees the previous pair when the heads change. **A borrowed
/// clock is therefore valid until the next scoped read at *other* heads**,
/// which on a document that is neither isolated nor mutated is never.
fn atScope(doc: *const Document, heads: []const ChangeHash) Error!?Clock {
    const scope = try mutableDoc(doc).clockAtScope(doc.gpa, heads) orelse return null;
    return scope.*;
}

/// The document as a **mutable** pointer, for a [`Document`](doc.zig) method
/// the port gives one.
///
/// **The `const` is dropped and nothing writes through it.** Three
/// `Document` methods take `*Document` where upstream takes `&self`:
/// [`getChangeByHash`](doc.zig), [`getChanges`](doc.zig) and the
/// [`collectByHashes`](doc.zig) behind it. Upstream's reason is interior
/// mutability, and [plan §3.2](../../docs/plan.md) says so in as many words:
/// "A method that would need `&mut self` on a read (`getHeads`, `getChanges`
/// take `&mut self` upstream purely for interior-mutability caching) takes
/// `*Document` in Zig and the cache is explicit." **None of them writes a row,
/// an object or a head** — the collector re-encodes a change out of the op set
/// and hands back owned bytes, which is why [`getChangeByHash`]'s contract is
/// that the *caller* owns the result rather than that the caller freed
/// something the document had been holding.
fn mutableDoc(doc: *const Document) *Document {
    return @constCast(doc);
}

/// The value one operation carries, and the id of that operation
/// ([`Op::tagged_value`](opset/op.zig), `op.rs:1084-1086`, over
/// [`Op::value`](opset/op.zig), `op.rs:1096-1106`).
///
/// **Upstream's `value()` is a `match` with a `panic!` in its last arm**, and
/// this keeps the panic as a refusal: a register whose winner is a `delete` or
/// an `increment` is a document the walks should never have produced — a
/// delete is a successor edge and not a row
/// ([opset/columns.zig:81-85](../opset/columns.zig)), and an increment is
/// dropped by the grouper ([found_op.zig:12-16](../opset/found_op.zig)) — so
/// `error.Invariant` is the honest answer and `null` is not.
///
/// The two mark arms are upstream's two string constants, not the mark's own
/// value: `op.rs:1101-1103` returns `"markBegin"` for a row whose `mark_name`
/// column holds a name and `"markEnd"` for one where it is null, and a
/// mark's own value is read with [`getMarks`](../../API.md) instead.
fn taggedValue(op: Op, set: *const Set) ReadError!DocItem {
    const v: ValueRef = switch (op.action()) {
        // `OpType::Make(obj_type) => ValueRef::Object(*obj_type)`
        // (`op.rs:1098`), which is the port's
        // `ValueRef.fromActionValue` for the four make arms
        // (`opset/types.zig:244-248`).
        .make_map => .{ .object = .map },
        .make_list => .{ .object = .list },
        .make_text => .{ .object = .text },
        .make_table => .{ .object = .table },
        // `OpType::Put(scalar) => ValueRef::Scalar(scalar.clone())` (`:1099`).
        .set => .{ .scalar = op.value() },
        // `:1101-1103`.
        .mark => if (op.markName() != null)
            .{ .scalar = .{ .str = "markBegin" } }
        else
            .{ .scalar = .{ .str = "markEnd" } },
        // `_ => panic!("cant convert op into a value - {:?}", self)` (`:1104`).
        .delete, .increment => return error.Invariant,
    };
    // `self.exid(op_set)` (`op.rs:1085`), which is
    // `OpId::id_to_exid(self.id, op_set)` (`op_set.rs:1054-1060`) and the
    // port's `OpSet.idToExid`.
    return .{ .value = v, .id = set.idToExid(op.id()) };
}

/// The register at `found`'s winning row, or null for an empty register.
///
/// **The last row is the winner, and that is the register's own order**
/// ([found_op.zig:154-171](../opset/found_op.zig): one register's rows are
/// contiguous and ascend strictly in op id, and an op id orders by counter then
/// actor ([types.zig:192-197](../src/types.zig))). Upstream spells it
/// `.ops.last()` in [`get`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1872
/// and `.ops.last()` again in `get_cursor_for` (`:1751`).
fn winner(found: *opsetmod.OpsFound) ?Op {
    const items = found.ops.items;
    if (items.len == 0) return null;
    return items[items.len - 1];
}

// ── The thirteen methods, and the two range readers ──────────────────────────

/// The value at `obj`'s property `prop`, with the id of the operation that put
/// it there
/// ([`ReadDoc::get`](../../github-automerge-automerge/rust/automerge/src/read.rs):259-263,
/// over [`Automerge::get_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1859-1889).
///
/// **Ownership: borrowed.** The [`DocItem`] is a value and its bytes are the
/// document's — valid until the next mutation of `doc`. Nothing is allocated
/// and nothing is freed.
///
/// **What it refuses, and it is upstream's own dispatch table** (`:1866-1887`):
///
/// * `error.NotAnObject` — `obj` names no object. Upstream's
///   `exid_to_obj` (`:1865`, `:788-792`) refuses it and this does the same
///   through [`Document.objectType`](doc.zig).
/// * `error.InvalidOp` — the property does not exist in that object: a map key
///   asked of a list or a text, or an index asked of a map or a table. This is
///   upstream's `_ => return Err(AutomergeError::InvalidOp(obj.typ))` (`:1886`).
/// * **`null`**, and not a `null_value` — the register has no visible row. A
///   key that was deleted and a key that was never written are the same answer
///   here, and the test "a deleted key is absent, not a null value" is the one
///   that says so.
///
/// Upstream returns "a single arbitrarily chosen value" for a conflicted key
/// ([read.rs:255-257](../../github-automerge-automerge/rust/automerge/src/read.rs))
/// and the choice is deterministic: [`winner`] takes the register's last row.
pub fn get(doc: *const Document, obj: ExId, prop: Prop) ReadError!?DocItem {
    return getAtScope(doc, obj, prop, try readScope(doc));
}

/// [`get`] under the clock the caller supplies — upstream's
/// `Automerge::get_for(.., clock)`
/// ([`automerge.rs:1859`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// which is the **crate-internal** door both [`ReadDoc::get`](read.rs:259-263)
/// and a transaction's read resolve their scope through.
///
/// **This is upstream's own split and not a second reader.** Upstream has the
/// trait method `get` ([`read.rs`:259-263](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// the `get_at` trait method with heads
/// ([`transaction.rs`:250-258](../../github-automerge-automerge/rust/automerge/src/transaction.rs)),
/// and the one implementation both of them call with a clock
/// ([`transaction.rs`:241-248](../../github-automerge-automerge/rust/automerge/src/transaction.rs)):
/// `self.doc.get_for(obj, prop, self.get_scope(None))`. The clock is what
/// differs, and this is the function it is passed to.
///
/// **A `Transaction.get` reaches it and [`get`] cannot.** [`readScope`] is the
/// *document's* isolation; a transaction reads at its **own** scope, which is
/// a different clock for an isolated document and the same one for an
/// unscoped transaction ([`manual_transaction.rs:113-122`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)),
/// so the scope is a parameter here rather than a line inside the body.
/// Widening [`liveObj`], [`winner`] and [`taggedValue`] instead would leave
/// the dispatch below written twice, and the dispatch is the part that decides
/// which seek runs and which error a bad property raises.
///
/// **Ownership and refusals are [`get`]'s**: borrowed [`DocItem`], no
/// allocation, and `NotAnObject` / `InvalidOp` / `null` for the three cases its
/// table names.
pub fn getAtScope(
    doc: *const Document,
    obj: ExId,
    prop: Prop,
    scope: ?Clock,
) ReadError!?DocItem {
    const set = mutableOps(doc);
    const live = try liveObj(doc, obj);
    const typ = try doc.objectType(live);
    var found = switch (typ) {
        .map, .table => switch (prop) {
            .key => |key| try set.seekOpsByMapKey(doc.gpa, live, key, scope),
            .index => return error.InvalidOp,
        },
        .list, .text => switch (prop) {
            .key => return error.InvalidOp,
            .index => |i| try set.seekOpsByIndex(
                doc.gpa,
                live,
                i,
                // `obj.typ.as_sequence_type().expect("list and text must have
                // a sequence type")` (`:1875-1878`): the arm was chosen on the
                // type, so this is the same value it would have produced.
                typ.asSequenceType() orelse return error.Invariant,
                scope,
            ),
        },
    };
    defer found.deinit(doc.gpa);
    const op = winner(&found) orelse return null;
    return try taggedValue(op, set);
}

/// [`get`] as at `heads`
/// ([`ReadDoc::get_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):266-271,
/// over [`Automerge::get_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2254-2262).
///
/// **Ownership, the three refusals and the answer are [`get`]'s**, because the
/// body is the one upstream hands to both spellings
/// ([`automerge.rs`:2260-2261](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.get_for(obj.as_ref(), prop.into(), clock)`,
/// and [`get`] is [`getAtScope`] at the document's own scope.
///
/// **A key whose value those heads have not yet written is `null`, and a key
/// those heads have not yet deleted still holds its value** — the register is
/// read as that clock sees it, and both answers are the same answer the
/// present gives about a key that was never written or a value that was never
/// deleted. **A `put` that the present's clock resolves to a second value is
/// reported as that second value here**, and the id comes back with it, which
/// is why the id is half the answer upstream ([`read.rs`:245-253](../../github-automerge-automerge/rust/automerge/src/read.rs)).
///
/// **`heads` is a list and never null** ([`read.rs`:270](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// which is why this is a second name rather than a second parameter: a
/// caller that wants the present asks [`get`]. **Naming the document's own
/// heads reads the present too**, because [`Automerge::clock_at`] reports no
/// clock for them ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// — upstream's own comment says `*_at(doc.get_heads())` takes the indexed
/// fast paths, and [`atScope`] keeps the shortcut.
///
/// **The id is resolved, not passed through**: [`getAtScope`] calls
/// [`liveObj`] before anything reaches the op set, which is upstream's
/// `exid_to_obj` ([`automerge.rs`:1865](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// — and the module doc's *Historical reads* section is where why a
/// historical read resolves against the same actor table as the present is
/// argued.
pub fn getAt(
    doc: *const Document,
    obj: ExId,
    prop: Prop,
    heads: []const ChangeHash,
) ReadError!?DocItem {
    return getAtScope(doc, obj, prop, try atScope(doc, heads));
}

/// Every value at `obj`'s property `prop` that conflicts, each with the id of
/// the operation that put it there
/// ([`ReadDoc::get_all`](../../github-automerge-automerge/rust/automerge/src/read.rs):284-288,
/// over [`Automerge::get_all_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1891-1927).
///
/// **Ownership: the slice is the caller's** — free it with `gpa` — and **each
/// [`DocItem`]'s bytes are the document's**, valid until the next mutation.
/// [API.md](../API.md) gives this method no allocator; the return type is a
/// list of values, so it takes one, and the report names it as a deviation.
///
/// **The same refusals as [`get`]**, from the same dispatch: `NotAnObject` for
/// an id that names nothing, `InvalidOp` for a property the object does not
/// have.
///
/// **Ascending in op id, which upstream asserts rather than sorts**
/// ([automerge.rs:1921-1925](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// the rows come out in row order and one register's rows ascend in op id, so
/// the ids ascend too. The assert is upstream's and it is in a debug build
/// only, which is upstream's only.
pub fn getAll(
    doc: *const Document,
    obj: ExId,
    prop: Prop,
    gpa: Allocator,
) ReadError![]DocItem {
    return getAllAtScope(doc, obj, prop, try readScope(doc), gpa);
}

/// [`getAll`] as at `heads`
/// ([`ReadDoc::get_all_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):293-298,
/// over [`Automerge::get_all_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2272-2280).
///
/// **Ownership, the two refusals, the ascending op ids and the allocated
/// slice are [`getAll`]'s**, and the body is the one upstream hands to both
/// spellings ([`automerge.rs`:2278-2279](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.get_all_for(obj.as_ref(), prop.into(), clock)`.
/// [`getAllAtScope`] is upstream's `get_all_for` and is **private because the
/// twenty-line dispatch under it must not be written twice** — the one place
/// in this file where an `_at` needed a shared body rather than a second
/// call.
///
/// **A conflict that those heads have already resolved reads as one value**,
/// and that is the clock's whole effect: the seek returns the register's rows
/// as *that* clock sees them ([`OpSet.seekOpsByMapKey`](opset/op_set.zig),
/// [`OpSet.seekOpsByIndex`](opset/op_set.zig)), so a `put` the later change
/// shadowed is not in the list at all.
///
/// **`heads` is a list and never null** ([`read.rs`:297](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **The clock is borrowed from the document and this method copies every
/// value out before it returns**, so the answer survives the next `_at` read
/// — the values' *bytes* are the document's and are valid until the next
/// mutation, exactly as [`get`]'s are.
pub fn getAllAt(
    doc: *const Document,
    obj: ExId,
    prop: Prop,
    heads: []const ChangeHash,
    gpa: Allocator,
) ReadError![]DocItem {
    return getAllAtScope(doc, obj, prop, try atScope(doc, heads), gpa);
}

/// [`getAll`] and [`getAllAt`] under the clock the caller supplies — upstream's
/// `Automerge::get_all_for(obj, prop, clock)`
/// ([`automerge.rs`:1891-1927](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
fn getAllAtScope(
    doc: *const Document,
    obj: ExId,
    prop: Prop,
    scope: ?Clock,
    gpa: Allocator,
) ReadError![]DocItem {
    const set = mutableOps(doc);
    const live = try liveObj(doc, obj);
    const typ = try doc.objectType(live);
    var found = switch (typ) {
        .map, .table => switch (prop) {
            .key => |key| try set.seekOpsByMapKey(doc.gpa, live, key, scope),
            .index => return error.InvalidOp,
        },
        .list, .text => switch (prop) {
            .key => return error.InvalidOp,
            .index => |i| try set.seekOpsByIndex(
                doc.gpa,
                live,
                i,
                typ.asSequenceType() orelse return error.Invariant,
                scope,
            ),
        },
    };
    defer found.deinit(doc.gpa);

    const ops = found.ops.items;
    const out = try gpa.alloc(DocItem, ops.len);
    errdefer gpa.free(out);
    var last: ?ExId = null;
    for (ops, 0..) |op, i| {
        out[i] = try taggedValue(op, set);
        // `assert_eq!(values.iter().map(|v| &v.1)..., ...sorted()...)`
        // (`:1921-1925`).
        if (last != null) std.debug.assert(out[i - 1].id.order(out[i].id) == .lt);
        last = out[i].id;
    }
    return out;
}

/// The object `obj` as a materialized mirror — every value under it, in one
/// owned tree ([`ReadDoc::hydrate`](../../github-automerge-automerge/rust/automerge/src/read.rs):273-277,
/// over [`Automerge::hydrate`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2222-2234,
/// over [`Automerge::hydrate_obj`],
/// [`automerge.rs`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1638-1650).
///
/// **Ownership: the caller's, and it owns every byte it holds.** Free the
/// answer with `Value.deinit` (hydrate.zig) **once** — a `Map`, a `List` and a
/// `Text` are held in the `Value` by value, so a copy of the answer is a move
/// and a second `deinit` frees the same table twice ([`Map.deinit`]'s doc
/// says this). **Nothing in the mirror points into the document.** Every
/// scalar's payload and every mark's name crosses one of [`Map.putOwned`],
/// [`List.push`] or [`Text.putMark`] on the way in
/// ([`ownValue`], hydrate.zig), so **a mirror outlives the next mutation of
/// the document** — which upstream gets for free, because its `hydrate::Value`
/// carries no lifetime at all ([`hydrate.rs`](hydrate.zig):22-27) over a
/// `Vec<u8>` and a `SmolStr` ([`value.rs`:519-522). The allocator is this
/// parameter's and the containers record it, so `deinit` takes none.
///
/// **This is a composition and not a walk of its own.** The recursion is
/// [`hydmod.hydrateMap`], [`hydmod.hydrateList`] and [`hydmod.hydrateText`]
/// over [`OpSet.topOps`](../opset/top_op.zig) — upstream's
/// [`OpSet::hydrate_map` / `hydrate_list` / `hydrate_text` / `hydrate_op`]
/// (`hydrate.rs`:244-302), which [hydrate.zig](hydrate.zig) already ports.
/// **The only thing this file adds is the entry point and the three arms**:
/// `exid_to_obj` ([`liveObj`]), the object's type, and the clock.
///
/// **Which arm runs is the object's type** — a map and a table are one arm
/// ([`automerge.rs:1645-1649`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// a list and a text are the other two — **and `error.NotAnObject` for an id
/// that names none**, which is upstream's `exid_to_obj` (`:1643`, `:788-792`).
///
/// ## `heads`, and what `null` is
///
/// | `heads` | the clock the mirror is built at |
/// |---|---|
/// | `Some(h)` | a full [`Clock`](clock.zig) from [`ChangeGraph.clockAt`](change_graph.zig), **whatever `h` is** — the document's own heads included, because this arm does not take the shortcut; upstream's arm is `heads.and_then(|h| self.clock_at(h))` and **`clock_at` does shortcut** ([`automerge.rs`:1236-1247](../../github-automerge-automerge/rust/automerge/src/automerge.rs)); **the answers agree and the work does not** ([`markSetAtIndex`] is the same shape) |
/// | `null` | **the document's read scope** — [`readScope`], so the isolation's clock, and no clock at all when the document is not isolated |
///
/// **The `null` row is upstream's answer on an un-isolated document and the
/// port's on an isolated one, and that is a deliberate departure.**
/// `Automerge::hydrate` resolves its clock with
/// `heads.and_then(|h| self.clock_at(h))`
/// ([`automerge.rs:2228`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// so upstream's `None` is *no clock* — and it is the same for both of
/// upstream's `ReadDoc` implementors, because `AutoCommit::hydrate`
/// ([`autocommit.rs:1011`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs))
/// and `Transaction::hydrate`
/// ([`transaction.rs:228`](../../github-automerge-automerge/rust/automerge/src/transaction.rs))
/// forward `heads` to `hydrate_obj` **without passing `get_scope(..)`** — where
/// every sibling on the same two types does (`autocommit.rs:1020`, `:1003`,
/// `transaction.rs:238`, `autocommit.rs:920-921`). So **upstream's `hydrate`
/// reads the present even while the document is isolated.** Upstream pins
/// nothing here: its `hydrate` tests all pass `Some(..)` or run on an
/// un-isolated document (`test.rs:207`, `:385-386`, `:3910-3914`,
/// `:3936-3937`, `batch_insert.rs:451`, `:612-613`, `:812-813`).
///
/// The port takes the scope instead, and the reason is
/// [AGENTS.md](../AGENTS.md)'s: **a reader that answers for an isolated
/// document what the rest of the surface refuses is a reader lying.** Every
/// other reader here reaches its clock through [`readScope`]
/// ([`top_op.zig`:250, :728](../opset/top_op.zig),
/// [`parents.zig`](../opset/parents.zig),
/// [`map_range.zig`:846](../iter/map_range.zig),
/// [`list_range.zig`:731](../iter/list_range.zig),
/// [`spans.zig`:1176](../iter/spans.zig)), and a mirror built from the
/// present's rows is a false statement about the isolation rather than a stale
/// copy. **The two spellings are the same answer for every document that is
/// not isolated** — [`readScope`] reports no clock for those, so the clock is
/// null either way — so this changes nothing a caller can observe without
/// isolating first, and the test `test "hydrate at null heads is the
/// document's own scope"` is what holds the difference down.
///
/// ## `null` heads means the present, and other cases rest on that
///
/// **The paragraph above is the whole argument, and the argument has a
/// consequence worth stating on its own: `heads = null` and
/// `heads = getHeads()` are the same read on every document that is not
/// isolated.** Upstream's reason is one function, and it is the *same*
/// function both of this method's arms go through:
/// [`Automerge::clock_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1236-1247
/// returns `None` — "an unscoped read of the present document" — "when `heads`
/// is exactly the current heads, so `*_at(doc.get_heads())` takes the same
/// indexed fast paths as the un-suffixed methods", and `heads.and_then(|h|
/// self.clock_at(h))` is the line in both [`hydrate`]
/// ([`:2228`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and upstream's `hydrate_obj` (`:1644`). **So upstream builds no clock for
/// `Some(h)` at the present's own heads and this method builds one**, because
/// the `Some` arm below reaches [`ChangeGraph.clockAt`](change_graph.zig)
/// rather than [`Document.clockAtScope`](doc.zig), which is the door that
/// carries the shortcut. **The two spellings still agree, for a second and
/// independent reason: a full clock over the present's own heads *is* the
/// present**, so what separates them is the work and not the answer.
///
/// **Cases are written against that agreement, and a change to the `null` arm
/// breaks them.** The upstream `batch_insert` cases that end in
/// `doc.hydrate(ROOT, None)` (`batch_insert.rs:451`, `:612-613`, `:812-813`)
/// build un-isolated documents, so they exercise `null` as *the present*
/// rather than as *a clock*: **a `hydrate` that is correct under an isolation
/// and wrong without one fails every one of them, and fails it silently** —
/// a mirror that is merely plausible passes an equality between two documents
/// that are both unscoped and both wrong. The failure this file has produced
/// most often is two structures that must agree computing one answer by
/// different rules, and `null` heads is exactly such a pair: this method's arm
/// and [`readScope`]'s. **They are one rule here, and that is a thing a reader
/// of this comment needs, not a thing to be re-derived at the next change.**
pub fn hydrate(
    doc: *const Document,
    obj: ExId,
    heads: ?[]const ChangeHash,
    gpa: Allocator,
) HydrateError!hydmod.Value {
    const set = mutableOps(doc);
    const live = try liveObj(doc, obj);
    const typ = try doc.objectType(live);
    // **`heads.and_then(|h| self.clock_at(h))`** (`automerge.rs:2228`), with
    // the `null` arm resolved through `readScope` as the doc above says.
    // **The `Some` arm owns its clock and the `null` arm does not**, so the
    // owned one is held in a slot the `defer` can free: a `?Clock` handed back
    // by value could not say which arm built it.
    var owned: ?Clock = null;
    defer if (owned) |*c| c.deinit();
    const scope: ?Clock = if (heads) |h| blk: {
        owned = try mutableDoc(doc).graph.clockAt(doc.gpa, h);
        break :blk owned;
    } else try readScope(doc);
    return switch (typ) {
        .list => try hydmod.hydrateList(Set, set, gpa, live, scope),
        .text => try hydmod.hydrateText(Set, set, gpa, live, scope),
        .map, .table => try hydmod.hydrateMap(Set, set, gpa, live, scope),
    };
}

/// What kind of object `obj` is
/// ([`ReadDoc::object_type`](../../github-automerge-automerge/rust/automerge/src/read.rs):152,
/// over [`Automerge::object_type`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2282-2287).
///
/// **Ownership: a value.** An [`ObjType`] is two bits of an enum and outlives
/// the document.
///
/// `error.NotAnObject` for an id that names none, and the root is a map and
/// always answers — upstream's `ObjMeta::root()`
/// ([automerge.rs:760-768](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// reached through [`Document.objectType`](doc.zig).
pub fn objectType(doc: *const Document, obj: ExId) Error!ObjType {
    return doc.objectType(obj);
}

/// How long `obj` is, in the document's text encoding
/// ([`ReadDoc::length`](../../github-automerge-automerge/rust/automerge/src/read.rs):142,
/// over [`Automerge::length_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1707-1712).
///
/// **Ownership: a value.** A `usize`.
///
/// **Zero for an object this document does not have**, which is upstream's
/// `.unwrap_or(0)` (`:1711`) and is a separate arm from the fallible one below
/// rather than the same one: the port's
/// [`OpSet.seqLength`](opset/op_set.zig) raises `ParseError` and
/// `ReadOpError` for a column that ran out, and **a reader that turned that
/// into `0` would answer "no such object" for a document that has one**.
/// [API.md](../API.md) gives this method no error arm, matching upstream's
/// infallible `seq_length`; the report names it as a deviation.
///
/// A **map** is counted over its distinct visible keys, a **list** over its
/// distinct visible insert positions, and a **text** by the sum of its widths
/// ([`OpSet.seqLength`](opset/op_set.zig), `op_set.rs:429-461`). A map is not
/// special-cased: `:437` is an `unwrap_or(ObjType::Map)`, so an id the index
/// does not know takes the map arm.
pub fn length(doc: *const Document, obj: ExId) ReadError!usize {
    const scope = try readScope(doc);
    const live = liveObjOrSelf(doc, obj);
    if (doc.ops.objectType(live) == null) return 0;
    return mutableOps(doc).seqLength(live, doc.textEncoding(), scope);
}

/// [`length`] as at `heads`
/// ([`ReadDoc::length_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):149,
/// over [`Automerge::length_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2147-2150).
///
/// **Ownership and both zeros are [`length`]'s** — `0` for an object this
/// document does not have (upstream's `.unwrap_or(0)`, `:1711`) and the
/// fallible column errors that must not be flattened into it — and the body
/// is the one upstream hands to both spellings
/// ([`automerge.rs`:2148-2149](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.length_for(obj.as_ref(), clock)`.
///
/// **A text's length is measured in the document's own encoding at those
/// heads**, so a read before an insert can answer a smaller number in grapheme
/// clusters than the present does for the same object — the units do not
/// change and the visible rows do ([`OpSet.seqLength`](opset/op_set.zig)).
///
/// **`heads` is a list and never null** ([`read.rs`:149](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
pub fn lengthAt(doc: *const Document, obj: ExId, heads: []const ChangeHash) ReadError!usize {
    const scope = try atScope(doc, heads);
    const live = liveObjOrSelf(doc, obj);
    if (doc.ops.objectType(live) == null) return 0;
    return mutableOps(doc).seqLength(live, doc.textEncoding(), scope);
}

/// The string a text object reads as
/// ([`ReadDoc::text`](../../github-automerge-automerge/rust/automerge/src/read.rs):176,
/// over [`Automerge::text_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1714-1721,
/// over [`OpSet::text`](opset/op_set.zig), `op_set.rs:1041-1052`).
///
/// **Ownership: the caller's.** Free the bytes with `gpa`; nothing in them
/// points back at the document.
///
/// `error.NotAnObject` for an id that names no object, which upstream's
/// `exid_to_obj` raises (`:1719`) and which
/// [`OpSet.text`](opset/op_set.zig) does not: it scopes the object's rows and
/// an id with none has no rows, so it would answer the empty string. **A
/// reader that answered "" for a bad id would be indistinguishable from an
/// empty text object**, so the check is here, once.
///
/// **A map and a list are not refused.** Upstream only checks that the id
/// names an object (`:1719`), so `text` over a map is the concatenation of
/// its visible string values and over a list is its elements' — whatever
/// [`OpSet.text`](opset/op_set.zig) walks, which appends `U+FFFC` for
/// anything that is not a string (`:1046-1050`).
pub fn text(doc: *const Document, obj: ExId, gpa: Allocator) ReadError![]u8 {
    const scope = try readScope(doc);
    const live = try liveObj(doc, obj);
    _ = try doc.objectType(live);
    return mutableOps(doc).text(gpa, live, scope);
}

/// [`text`] as at `heads`
/// ([`ReadDoc::text_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):180-184,
/// over [`Automerge::text_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2200-2207).
///
/// **Ownership and every refusal are [`text`]'s** — the bytes are the
/// caller's and a map is still not refused — and the body is the one upstream
/// hands to both spellings
/// ([`automerge.rs`:2205-2206](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.text_for(obj.as_ref(), clock)`.
///
/// **`heads` is a list and never null** ([`read.rs`:183](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **The clock is borrowed from the document and this method copies the whole
/// answer out before it returns**, so there is nothing for the caller to keep
/// alive: the bytes are the only thing that outlives the call.
pub fn textAt(
    doc: *const Document,
    obj: ExId,
    heads: []const ChangeHash,
    gpa: Allocator,
) ReadError![]u8 {
    const scope = try atScope(doc, heads);
    const live = try liveObj(doc, obj);
    _ = try doc.objectType(live);
    return mutableOps(doc).text(gpa, live, scope);
}

/// The keys of `obj`, one per visible register
/// ([`ReadDoc::keys`](../../github-automerge-automerge/rust/automerge/src/read.rs):50,
/// over [`Automerge::keys_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1662-1667,
/// over [`Keys::ofObj`](iter/keys.zig), `op_set.rs:377-379`).
///
/// **Ownership: the walk borrows the document, and the keys it hands out
/// borrow the document too — in two different ways, and the caller has to know
/// which is which:**
///
/// * a **map key** is the document's **interned** bytes
///   ([doc.zig:206-212](../doc.zig): the string table interns, and interning
///   copies into an arena that only grows), so it is valid for as long as the
///   document — the test
///   `test "a map key is the document's own bytes, and a mutation does not move them"`
///   is the one that says so;
/// * a **sequence anchor** is rendered into the walk's **own fixed buffer**
///   ([`Keys.render`](iter/keys.zig), `op_set.rs:1093-1098`), so it is valid
///   **only until the next `next()`** on the same walk. Copy it if it has to
///   outlive the step.
///
/// **Free the walk** with [`Keys.deinit`](iter/keys.zig), passing
/// [`Document.allocator`](doc.zig), because that is the allocator the op set
/// allocated the walk's scratch with. **Only one `Keys` per document at a
/// time** ([op_set.zig:40-49](../opset/op_set.zig)).
///
/// **An id that names no object yields an empty walk**, which is upstream's
/// `.ok().map(..).unwrap_or_default()` (`:1663-1666`) and not an error: the
/// walk is over an empty row range and answers `null` at once.
///
/// **A deleted key is absent**, not a key with a null value: the walk is a
/// winner walk ([`OpSet.topOps`](opset/op_set.zig)) and a delete is a
/// successor edge and not a row
/// ([opset/columns.zig:81-85](../opset/columns.zig)), so a shadowed register
/// has no winner to hand out.
pub fn keys(doc: *const Document, obj: ExId) ReadError!Keys {
    return Keys.ofObj(mutableOps(doc), liveObjOrSelf(doc, obj), try readScope(doc));
}

/// [`keys`] as at `heads`
/// ([`ReadDoc::keys_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):55,
/// over [`Automerge::keys_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2091-2094).
///
/// **Ownership is [`keys`]'s, in both of its senses** — a map key is the
/// document's interned bytes and a sequence anchor is the walk's own buffer,
/// valid until the next `next()` — **and so is the empty walk for an id that
/// names no object**, which is upstream's `.ok().map(..).unwrap_or_default()`
/// (`:1663-1666`). The body is the one upstream hands to both spellings
/// ([`automerge.rs`:2092-2093](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.keys_for(obj.as_ref(), clock)`.
///
/// **A key deleted after those heads is a key again**, because a delete is a
/// successor edge and the clock decides whether that edge is there
/// ([opset/columns.zig:81-85](../opset/columns.zig)). That is the whole of a
/// historical `keys`, and a walk that cannot see the delete reports the key
/// that the present has dropped.
///
/// **`heads` is a list and never null** ([`read.rs`:55](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **The clock is borrowed from the document**, so free the walk with
/// [`Document.allocator`](doc.zig) before the next `_at` read at other heads.
pub fn keysAt(doc: *const Document, obj: ExId, heads: []const ChangeHash) ReadError!Keys {
    return Keys.ofObj(mutableOps(doc), liveObjOrSelf(doc, obj), try atScope(doc, heads));
}

/// The values of `obj`, one per visible register, each with the id it came from
/// ([`ReadDoc::values`](../../github-automerge-automerge/rust/automerge/src/read.rs):129,
/// over [`Automerge::values_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1700-1705).
///
/// **Ownership: the walk borrows the document, and so does every value it hands
/// out.** A [`ValueRef`]'s `str`, `bytes` or `actor_id` payload is read out of
/// the op set's value column, and the row that carries it points its
/// successors into the op set's **shared** buffer
/// ([op_set.zig:40-49](../opset/op_set.zig)), so a value is valid until the
/// next walk over the same op set is advanced and, in any case, until the next
/// mutation of the document.
///
/// **`term` is an output parameter and the caller frees it.** This is the one
/// place [API.md](../API.md)'s signature could not be used as written, and the
/// reason is a property of the port's own type rather than a choice:
/// [`Values`](iter/values.zig) stores `iter: *I` and has no allocator, so the
/// query term it reads through must outlive it and something has to free it
/// ([iter/values.zig:340-349](../iter/values.zig) says exactly this). **A
/// function that returned a `Values` over a term it built on its own stack
/// would return a pointer to a dead frame**, which is a use-after-free in every
/// caller rather than none.
///
/// So the term is an out-slot the caller owns, and this fills it:
///
/// ```zig
/// var term: read.ValueTerm = undefined;
/// var it = try read.values(&doc, .root, &term);
/// defer term.deinit(doc.allocator());
/// while (try it.next()) |item| { ... }
/// ```
///
/// **Free the term with [`Document.allocator`](doc.zig)**, because
/// [`OpSet.topOps`](opset/op_set.zig) allocated its scratch with the op set's
/// own allocator. **Only one `Values` per document at a time.**
///
/// **An id that names no object yields an empty walk**, which is upstream's
/// `.ok().map(..).unwrap_or_default()` (`:1701-1704`).
pub fn values(doc: *const Document, obj: ExId, term: *ValueTerm) ReadError!Values {
    const scope = try readScope(doc);
    term.* = try ValueTerm.ofObj(mutableOps(doc), liveObjOrSelf(doc, obj), scope);
    return Values.init(mutableOps(doc), term, scope);
}

/// [`values`] as at `heads`
/// ([`ReadDoc::values_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):137,
/// over [`Automerge::values_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2138-2141).
///
/// **Everything [`values`] says about ownership, the out-slot and the
/// one-walk-per-document rule is this method's too** — `term` is the caller's
/// and is filled here and freed with [`Document.allocator`](doc.zig), and
/// **the clock is borrowed from the document**, so free the walk and the term
/// before the next `_at` read at other heads. The body is the one upstream
/// hands to both spellings
/// ([`automerge.rs`:2139-2140](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.values_for(obj.as_ref(), clock)`.
///
/// **`heads` is a list and never null** ([`read.rs`:137](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
pub fn valuesAt(
    doc: *const Document,
    obj: ExId,
    heads: []const ChangeHash,
    term: *ValueTerm,
) ReadError!Values {
    const scope = try atScope(doc, heads);
    term.* = try ValueTerm.ofObj(mutableOps(doc), liveObjOrSelf(doc, obj), scope);
    return Values.init(mutableOps(doc), term, scope);
}

/// The block markers and text spans of `obj`
/// ([`ReadDoc::spans`](../../github-automerge-automerge/rust/automerge/src/read.rs):187,
/// over [`Automerge::spans_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1723-1730).
///
/// **Ownership: three answers and they are all different.** The reader owns
/// its fold and gives it back with [`Spans.deinit`](iter/spans.zig), which
/// takes no allocator. **Each span is the caller's** and carries owned text and
/// an owned mark set, so [`Span.deinit`](iter/spans.zig) frees it with `gpa`;
/// the mark *names* inside it are the document's and are not freed. The reader
/// must be freed **after** the spans it handed out, because those spans came
/// out of its fold.
///
/// [API.md](../API.md) gives this method no allocator; the fold allocates and
/// upstream's `Spans` owns `Arc<MarkSet>`s and a `String`
/// ([iter/spans.zig:340-342](../iter/spans.zig)), so it takes one. The report
/// names it as a deviation.
///
/// `error.NotAnObject` for an id that names no object, which is upstream's
/// `exid_to_obj` (`:1728`). **A map is not refused** — upstream only checks
/// that the id names an object, and a map's rows are not inserts, so the walk
/// yields nothing.
pub fn spans(doc: *const Document, obj: ExId, gpa: Allocator) ReadError!Spans {
    const scope = try readScope(doc);
    const live = try liveObj(doc, obj);
    _ = try doc.objectType(live);
    return Spans.init(gpa, mutableOps(doc), try doc.ops.spans(live), scope, doc.textEncoding());
}

/// [`spans`] as at `heads`
/// ([`ReadDoc::spans_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):190-194,
/// over [`Automerge::spans_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2160-2167).
///
/// **Ownership, the three answers and the `NotAnObject` refusal are
/// [`spans`]'s**, because the body is the one upstream hands to both
/// spellings ([`automerge.rs`:2165-2166](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.spans_for(obj.as_ref(), clock)`.
/// **A map is still not refused and still yields nothing**, because upstream
/// only checks that the id names an object (`:1728`).
///
/// **`heads` is a list and never null** ([`read.rs`:193](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **The clock is borrowed from the document**, and this walk holds the mark
/// set each span names: free the walk, and the spans it handed out, before
/// the next `_at` read at other heads.
pub fn spansAt(
    doc: *const Document,
    obj: ExId,
    heads: []const ChangeHash,
    gpa: Allocator,
) ReadError!Spans {
    const scope = try atScope(doc, heads);
    const live = try liveObj(doc, obj);
    _ = try doc.objectType(live);
    return Spans.init(gpa, mutableOps(doc), try doc.ops.spans(live), scope, doc.textEncoding());
}

/// Every mark on `obj`, coalesced into runs and with the unmarks dropped
/// ([`ReadDoc::marks`](../../github-automerge-automerge/rust/automerge/src/read.rs):155,
/// over [`Automerge::marks_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1851-1857
/// over [`Automerge::calculate_marks`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1569-1596,
/// over [`OpSet.calculateMarksAt`](opset/op_set.zig), whose two arms are
/// [`OpSet::calculate_marks_fast`](opset/op_set.zig), `op_set.rs:961-1024`, and
/// `calculate_marks_slow`, `automerge.rs:1598-1631`).
///
/// **Which arm runs is the caller's clock and not this method's choice**
/// ([`automerge.rs`:1582-1595](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// the two indexes answer a read of the present, and a walk of the object's
/// rows as that clock sees them answers anything else. A read at an isolation
/// therefore reports the marks the isolation's clock has, and **the same
/// document read unscoped reports a different set** — which is the point of
/// the read and not an inconsistency in it.
///
/// **Ownership: the slice is the caller's** and **each mark's bytes are the
/// document's**. A [`Mark.name`](marks.zig) is the interned mark name and a
/// byte-carrying [`ScalarValue`] is read out of the value column, so both are
/// valid until the next mutation of the document. Free the slice with `gpa`;
/// the bytes in it are the document's and are not freed.
///
/// [API.md](../API.md) gives this method no allocator; the return type is a
/// list, so it takes one. The report names it as a deviation.
///
/// **A non-sequence is the empty list, not an error**: upstream's
/// `let Some(seq_type) = .. else { return Ok(Vec::new()) }` with its own
/// comment that it should be an error and is not kept for compatibility
/// ([automerge.rs:1576-1580](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
/// An **unmark** — a mark whose value is `null` — is dropped
/// ([op_set.rs:1023](../opset/op_set.zig)), because a tombstone is not a mark.
pub fn marks(doc: *const Document, obj: ExId, gpa: Allocator) ReadError![]Mark {
    // **Two resolutions in upstream's order** (`AutoCommit::marks` is
    // `marks_for(obj, self.get_scope(None))`,
    // [`autocommit.rs`:919-921](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)):
    // the id first and the clock second: the clock is built from the document,
    // and building it can intern an actor, which renumbers the actor table an
    // id was resolved against. **`readScope` is not optional here and not a
    // detail** — a clock is what turns
    // [`OpSet.calculateMarksAt`](opset/op_set.zig) from the two indexes into
    // the walk of the rows the clock sees
    // ([`automerge.rs`:1582-1595](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and the walk is the only arm that can answer a read at an isolation.
    const live = try liveObj(doc, obj);
    return mutableOps(doc).calculateMarksAt(gpa, live, try readScope(doc));
}

/// [`marks`] as at `heads`
/// ([`ReadDoc::marks_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):158-162,
/// over [`Automerge::marks_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2213-2220).
///
/// **Ownership, the empty list for a non-sequence and the dropped unmarks are
/// [`marks`]'s**, because the body is the one upstream hands to both
/// spellings ([`automerge.rs`:2218-2219](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.marks_for(obj.as_ref(), clock)`.
///
/// **This is where the two mark readers earn their keep.** [`marks`]'s own
/// doc says which arm runs is the caller's clock and not the method's choice
/// ([`automerge.rs`:1582-1595](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// the two indexes answer a read of the **present**, and a walk of the
/// object's rows as a clock sees them answers anything else. **So every mark
/// this method reports that the present does not have is evidence the clock
/// reached the walk** — an `*_at` that quietly passed `null` would report the
/// present's marks under a historical name, and the test that would catch it
/// is the one in the test section of this file.
///
/// **The id is resolved before the clock is built, exactly as [`marks`] does
/// it**, and the order is upstream's: `marks_for` is `calculate_marks`, whose
/// first line is `self.exid_to_obj(obj.as_ref())?`
/// ([`automerge.rs`:1574](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **`heads` is a list and never null** ([`read.rs`:161](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// — upstream's fast arm, in this reader's own case.
pub fn marksAt(
    doc: *const Document,
    obj: ExId,
    heads: []const ChangeHash,
    gpa: Allocator,
) ReadError![]Mark {
    const live = try liveObj(doc, obj);
    return mutableOps(doc).calculateMarksAt(gpa, live, try atScope(doc, heads));
}

/// The marks of `obj` that cover any index in the half-open window
/// `[from, max)`, in ascending order ([API.md](../API.md) §Read).
///
/// **This is [API.md](../API.md)'s method and not upstream's.** Upstream's
/// `get_marks` is [`markSetAtIndex`](read.zig): a [`MarkSet`] at **one
/// index**, [`read.rs:164-173`](../../github-automerge-automerge/rust/automerge/src/read.rs),
/// which is ported beside this one. A window of runs has no upstream spelling
/// — [`marks`] is the run list, and this is that list filtered — so the two
/// answer two questions and the port carries both. **The single-index read is
/// the one to reach for**, and it is the one that carries the heads.
///
/// **Ownership: the slice is the caller's**, and each mark's bytes are the
/// document's, exactly as for [`marks`]. [API.md](../API.md) gives this method
/// no allocator; the return type is a list, so it takes one.
///
/// **The window is half-open and empty when `max <= from`**, which is the
/// convention [API.md](../API.md) states for its other ranges and the one
/// upstream's `Range::contains` implements
/// ([iter/list_range.zig:151-155](../iter/list_range.zig), `list_range.rs:351`).
///
/// **A mark intersects the window when `mark.start < max and from <
/// mark.end`**, and a zero-width mark intersects nothing — which is the same
/// rule the mark fold itself applies, since it only closes a run when `seq >
/// start` ([op_set.rs:997](../opset/op_set.zig)). **A `max` past the end of
/// the object is the object's end**, and reads the object's own marks rather
/// than refusing, which is what the fold's own closing line does
/// ([op_set.rs:1018](../opset/op_set.zig)).
///
/// A **non-sequence** is the empty list, for the same reason and with the same
/// compatibility comment as [`marks`].
///
/// **Scoped by [`marks`], and not by a window of its own:** this is the whole
/// scoped mark list that the window is cut from, so a read through an
/// isolation cannot name its way past a mark the isolation excludes. The
/// clock reaches this method through that one call and is not asked for again
/// — asking it twice would build it twice, and the second build could be a
/// different clock.
pub fn getMarks(
    doc: *const Document,
    obj: ExId,
    from: usize,
    max: usize,
    gpa: Allocator,
) ReadError![]Mark {
    const all = try marks(doc, obj, gpa);
    if (from >= max) {
        gpa.free(all);
        return &.{};
    }
    var out: std.ArrayList(Mark) = .empty;
    errdefer out.deinit(gpa);
    for (all) |m| {
        if (m.start >= max or m.end <= from) continue;
        try out.append(gpa, m);
    }
    gpa.free(all);
    return out.toOwnedSlice(gpa);
}

/// The marks covering `index` of the sequence `obj`
/// ([`ReadDoc::get_marks`](../../github-automerge-automerge/rust/automerge/src/read.rs):164-173,
/// over [`Automerge::get_marks_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1929-1948).
///
/// **This is upstream's `get_marks`, and [`getMarks`](read.zig:979) is not.**
/// Upstream's is a [`MarkSet`] at **one index** — "what is marked here" — and
/// this is it. `getMarks` answers a half-open **window** over `[]Mark`, which
/// is the shape [API.md](../API.md) §Read gives and which upstream does not
/// have; a caller that wants the marks over a range asks [`marks`], and a
/// caller that wants the value a mark holds *at* a position asks this. The two
/// are not one method composed of the other: a `MarkSet` resolves same-name
/// marks against each other ([`MarkStateMachine`](marks.zig)) and an unmark
/// — a mark whose value is `Null` — is gone from it, while `getMarks` reports
/// runs and [`marks`] drops the tombstone only at the end of its own fold.
///
/// **`heads` is a clock, and `null` is not "no scope".** Upstream resolves it
/// through `get_scope(heads)` ([`autocommit.rs:794-814`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
/// and that match is the whole rule:
///
/// | `heads` | the clock the read runs at |
/// |---|---|
/// | `Some(h)` | a full [`Clock`](clock.zig) from [`ChangeGraph.clockAt`](change_graph.zig), **whatever `h` is** — the document's own heads included, because this arm does not take the shortcut |
/// | `None` | the isolation's clock, or none at all when the document is not isolated |
///
/// **The second row is upstream's own shortcut, and upstream's `Some` arm
/// takes it too.** [`Automerge::get_marks`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2236-2244
/// is `let clock = heads.and_then(|h| self.clock_at(h));` (`:2242`), and
/// `clock_at` answers `None` for the present's own heads (`:1236-1247`);
/// through an `AutoCommit`,
/// [`get_scope`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):794-805
/// calls that same `clock_at` from its first arm whenever no transaction is in
/// flight (`:800-804`). So **upstream's `Some(heads)` and `None` are the same
/// call at the present's own heads**, and this method's are not — and **what
/// differs is which arm of [`markSetAtScope`] runs and not what it answers**:
/// upstream's `clock` is `None` for those heads and takes `get_marks_fast`
/// (`:1937-1938`), while the `Some` arm below hands it a clock and so takes
/// the walk, which is the general arm and answers the same thing. The test
/// `test "markSetAtIndex answers the set at one index, and the heads decide
/// which path reads it"` reads both arms and is what holds the difference down.
/// Through a transaction the `None` arm is the transaction's own clock
/// ([`manual_transaction.rs:113-122`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)),
/// which is [`Transaction.markSetAtIndex`](transact.zig) and not this function.
///
/// **Which arm of upstream's dispatch runs is decided by `clock.is_none()`
/// and the object type** ([`automerge.rs:1937`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)) —
/// [`markSetAtScope`] below carries that rule and is where both arms live.
///
/// **Ownership: the set is the caller's** — `MarkSet.deinit` it — and its names
/// are the document's, valid until the next mutation.
pub fn markSetAtIndex(
    doc: *const Document,
    obj: ExId,
    index: usize,
    heads: ?[]const ChangeHash,
    gpa: Allocator,
) ReadError!MarkSet {
    if (heads) |h| {
        // **Upstream's arm is `heads.and_then(|h| self.clock_at(h))`**
        // (`automerge.rs:2242`, and `autocommit.rs:800-804` through an
        // `AutoCommit`), and **`clock_at` shortcuts the present**
        // (`:1241-1247`): it answers `None` when `h` is the document's own
        // heads. This arm reaches the graph's clock directly instead —
        // [`ChangeGraph.clockAt`](change_graph.zig), which is the call
        // `Automerge::clock_at` itself makes (`automerge.rs:1245`) and the one
        // [`Transaction.scopeClock`](transact.zig) makes for its own scope —
        // so **the clock is built even when `h` is the present's own heads,
        // which is not what upstream does.** The answers agree and the doc
        // above says on what.
        var clock = try mutableDoc(doc).graph.clockAt(doc.gpa, h);
        defer clock.deinit();
        return markSetAtScope(doc, obj, index, clock, gpa);
    }
    // The `None` arm: the isolation's clock, or none (`get_scope(None)`,
    // `:813`). **An unscoped document gets `null` and takes the indexed
    // path**, which is the whole of the `clock.is_none()` rule below.
    return markSetAtScope(doc, obj, index, try readScope(doc), gpa);
}

/// [`markSetAtIndex`] under the clock the caller supplies — upstream's
/// `Automerge::get_marks_for(.., clock)`
/// ([`automerge.rs:1929-1948`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **The two arms, and the rule that picks between them.**
///
/// | the read | how |
/// |---|---|
/// | no clock **and** the object is text | [`OpSet.getMarks`](opset/op_set.zig), one prefix descent — upstream's `get_marks_fast` (`:1938`) |
/// | anything else | [`OpSet.markSetAtIndex`](opset/op_set.zig), a walk over the object's winners — upstream's `get_marks_slow` (`:1947`, `:1950-1971`) |
///
/// The test is `clock.is_none() && obj.typ == ObjType::Text`
/// ([`automerge.rs:1937`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// and **it is the rule and not an optimisation**: the mark index names the
/// present and nothing else, so the walk is the only arm that can answer a
/// historical read. Upstream compares the two answers under
/// `slow_path_assertions` (`:1939-1943`), which is the port's
/// [`check_slow_paths`](opset/op_set.zig).
///
/// **This is the sibling of [`marks`] and [`marksAt`], not their
/// composition.** Those answer every run of marks a clock sees; this one
/// answers only the set at one index, and it finds that index by summing
/// element widths as it walks rather than by measuring the run boundaries
/// those two measure. They agree where they overlap and neither is written in
/// terms of the other, because a list has no text widths for the run fold to
/// measure and the walk here is upstream's own
/// ([`automerge.rs`:1959-1970](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **A non-sequence is the empty set**, which is upstream's
/// `let Some(seq_type) = .. else { return MarkSet::default() }` and its own
/// comment that it should be an error and is not
/// ([`automerge.rs:1956-1958`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
/// An id that names no object is `error.NotAnObject`, from [`liveObj`], which
/// is upstream's `exid_to_obj` (`:1935`).
pub fn markSetAtScope(
    doc: *const Document,
    obj: ExId,
    index: usize,
    scope: ?Clock,
    gpa: Allocator,
) ReadError!MarkSet {
    const set = mutableOps(doc);
    const live = try liveObj(doc, obj);
    const typ = try doc.objectType(live);
    if (scope == null and typ == .text) return set.getMarks(gpa, live, index);
    // `:1956-1958`. **The caller of the walk is the one that knows**, so the
    // sequence type is read here and handed down rather than re-derived there.
    const seq = typ.asSequenceType() orelse return MarkSet.init(gpa);
    return set.markSetAtIndex(gpa, live, index, seq, scope);
}

/// The chain of parents of `obj`, innermost first
/// ([`ReadDoc::parents`](../../github-automerge-automerge/rust/automerge/src/read.rs):35,
/// over [`Automerge::parents_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1652-1660).
///
/// **Ownership: the walk borrows the document and owns nothing**, so it has no
/// `deinit`. Each [`Parent.prop`](opset/parents.zig) is a `Prop` whose
/// `key` slice is the document's interned bytes, valid until the next mutation.
///
/// **An id that names no object is an empty walk, and that is the refusal.**
/// Upstream returns `Err(AutomergeError::InvalidObjId)` (`:1657`,
/// `read.rs:26-29`) and [API.md](../API.md) gives this method no error arm, so
/// the refusal is expressed in the walk: **a walk with nothing to spend**, which
/// answers `null` at once and makes `path` the empty array — the same answer the
/// root gives, because the root has no parents either
/// ([`Parents.next`](opset/parents.zig), `parents.rs:52-55`).
///
/// **This matters because a scalar's id is a row.** `get` hands back the id of
/// the operation that put a scalar there, and that id **is** a row, so
/// [`OpSet.parentObject`](opset/op_set.zig) would happily walk up from it and
/// answer the scalar's container — which is exactly the extension upstream's
/// own doc comment anticipates and declines (`read.rs:31-34`). The type check
/// is what declines it, and it is why this method cannot be
/// `Parents.init(opset, obj, null)` and nothing else.
pub fn parents(doc: *const Document, obj: ExId) ReadError!Parents {
    return parentsAtScope(doc, obj, try readScope(doc));
}

/// [`parents`] as at `heads`
/// ([`ReadDoc::parents_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):40-44,
/// over [`Automerge::parents_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2078-2085).
///
/// **Ownership, the empty-walk refusal and the scalar-id check are
/// [`parents`]'s**, because the body is the one upstream hands to both
/// spellings ([`automerge.rs`:2083-2084](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.parents_for(obj.as_ref(), clock)`.
/// [`parentsAtScope`] is upstream's `parents_for` and is **private because
/// nothing outside this file has a clock to give it** — unlike
/// [`getAtScope`], which a transaction reaches.
///
/// **`heads` is a list and never null** ([`read.rs`:43](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**, because
/// [`Automerge::clock_at`] reports no clock for them
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **The clock is borrowed from the document**, so the walk reads it long
/// after this returns: drop it before the next `_at` read at other heads.
/// **An object those heads do not contain answers the empty walk**, because
/// the object index is clock-independent (see the module doc's *Historical
/// reads* section) and only its *rows* are scoped — so the walk finds no
/// parent row to spend. That is the same refusal an id that names no object
/// gets, and it is the right one: those heads say nothing about that object.
pub fn parentsAt(doc: *const Document, obj: ExId, heads: []const ChangeHash) ReadError!Parents {
    return parentsAtScope(doc, obj, try atScope(doc, heads));
}

/// [`parents`] and [`parentsAt`] under the clock the caller supplies —
/// upstream's `Automerge::parents_for(obj, clock)`
/// ([`automerge.rs`:1652-1660](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
fn parentsAtScope(doc: *const Document, obj: ExId, scope: ?Clock) ReadError!Parents {
    // `get_obj_meta` (`automerge.rs:760-768`) is the check; upstream spells it
    // `self.exid_to_obj(obj)?` (`:1657`).
    // An id the actor table can no longer name is the same refusal as one that
    // names no object, so it is handed on unresolved and falls into the branch
    // below rather than being answered with the root's parents.
    const live = liveObjOrSelf(doc, obj);
    if (doc.ops.objectType(live) == null) {
        var empty = Parents.init(mutableOps(doc), .root, scope);
        // A budget of zero is [`Parents.next`]'s own end condition
        // (`parents.rs:52-55` and the module doc's cycle section), so the walk
        // answers nothing and `path` answers the empty array.
        empty.budget = 0;
        return empty;
    }
    return Parents.init(mutableOps(doc), live, scope);
}

/// Every visible property of every object the document holds, parents before
/// children
/// ([`ReadDoc::iter`](../../github-automerge-automerge/rust/automerge/src/read.rs):68-76,
/// over [`Automerge::iter_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1669-1674).
///
/// **This is `iterAt(doc, .root, null, gpa)`, and it is upstream's own
/// default method**: `fn iter(&self) -> DocIter<'_> { self.iter_at(&ROOT,
/// None) }` ([`read.rs`:74-76](../../github-automerge-automerge/rust/automerge/src/read.rs)).
/// One body, two spellings, so [`iterAt`] carries the ownership and the
/// order.
///
/// **The order is causal and is not negotiable.** The walk takes a child back
/// out of its queue lowest id first — upstream's `BTreeMap::pop_first`
/// ([`iter/doc.rs`:243, :252](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)),
/// which is [`ObjQueue.popLowest`](iter/doc.zig) — so an object created
/// earlier is visited earlier, and a parent before its children. That is the
/// sentence in [`read.rs`:64-72](../../github-automerge-automerge/rust/automerge/src/read.rs)
/// ("objects which were created \"first\" in the documents history are
/// visited first"), and it is a **sequence**: the same items in another order
/// would be a different walk. **The test that says so is "iter reads every
/// object in causal order, parents before children" below**, and it claims the
/// order **separately from which items came back** — the object each answer
/// hangs by, run by run, against the order the queue's minimum gives — so a
/// membership failure and an order failure are two failures and not one.
///
/// **Ownership: three answers, and they are all different.** The walk owns
/// the spans fold and the object queue, so [`deinit`](iterdoc.DocIter.deinit)
/// takes no allocator and must run before the document mutates. **Each item
/// is the caller's** — a text span carries owned text and an owned mark set —
/// and is freed with [`deinit`](iterdoc.DocObjItem.deinit) and the `gpa` this
/// was given. **The clock is the document's**, borrowed for the walk's life
/// ([`readScope`]).
pub fn iter(doc: *const Document, gpa: Allocator) DiffError!DocIter {
    return iterAt(doc, .root, null, gpa);
}

/// [`iter`] over the subtree under `obj`, as at `heads`
/// ([`ReadDoc::iter_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):60,
/// over [`Automerge::iter_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2096-2100
/// and [`AutoCommit::iter_at`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):855-857).
///
/// **Ownership and the order are [`iter`]'s**, because the body is the one
/// upstream hands to both spellings:
/// `self.iter_for(obj.as_ref(), clock)` ([`automerge.rs`:2099](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// where the clock is `heads.and_then(|heads| self.clock_at(heads))` (`:2098`).
///
/// **`heads` is upstream's `Option<&[ChangeHash]>` and it is on the method
/// itself** ([`read.rs`:60](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// so the port carries it here too. **`heads = null` is this document's read
/// scope, not "no scope"** — the isolation's clock, and no clock at all when
/// the document is not isolated ([`readScope`]) — which is the reading
/// [`hydrate`] and [`markSetAtIndex`] argue at length, and which is
/// upstream's `AutoCommit::iter_at` (`autocommit.rs`:856) rather than
/// upstream's `Automerge::iter_at`. **It agrees with upstream on every
/// document that is not isolated**, the only case in which upstream's
/// `get_scope(None)` answers a clock at all.
///
/// **An id that names no object is the empty walk**, which is upstream's
/// `.ok().map(..).unwrap_or_else(DocIter::empty)`
/// ([`automerge.rs`:1670-1674](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
/// The port has no separate "empty" walk — see the module doc of
/// [iter/doc.zig](iter/doc.zig) on `DocIter::empty` — so this is the same
/// walk built over an object with no rows, which answers nothing for the same
/// reason.
pub fn iterAt(
    doc: *const Document,
    obj: ExId,
    heads: ?[]const ChangeHash,
    gpa: Allocator,
) DiffError!DocIter {
    // Compute the clock before resolving the object, as in `iter_at`
    // (`automerge.rs:2097-2099`) followed by `iter_for` (`:1669-1674`).
    const scope = if (heads) |h|
        try atScope(doc, h)
    else
        try readScope(doc);
    // **The root is a map whether or not a row created it**, which is
    // [`Document.objectType`](doc.zig)'s own answer and upstream's
    // `ObjMeta::root()` ([`automerge.rs`:760-768](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    const live = if (obj.eql(.root)) obj else liveObjOrSelf(doc, obj);
    const typ = doc.ops.objectType(live) orelse .map;
    // **The handle is a local, and nothing keeps it.** [`DocIter.init`] copies
    // the op-set pointer and the encoding out of it and retains neither the
    // handle nor anything inside it, so this two-field value lives for the
    // length of the call and the walk borrows the *document*.
    const view = handle(doc);
    return DocIter.init(gpa, &view, live, typ, scope);
}

/// The handle the recursive walk is built over ([`Doc.init`](iter/doc.zig),
/// which is upstream's `DocIter::new` reaching the document for `doc.ops()`
/// and `doc.text_encoding()`, [`iter/doc.rs`:42-50](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)).
///
/// **A value, and the walk copies out of it before this returns.** [`DocIter`]
/// stores the op-set pointer and the encoding and nothing else, so nothing
/// here outlives the call — which is the answer to "does this leave a pointer
/// into a returned stack frame": it does not, and the same two lines
/// [`PatchDoc.handle`](doc.zig) spells for the diff walk are the shape.
fn handle(doc: *const Document) iterdoc.Doc(ChangeOp) {
    return .init(mutableOps(doc), doc.textEncoding());
}

/// A stable address for the position `pos` in a list or text object, read as
/// the clock `heads` names
/// ([`ReadDoc::get_cursor`](../../github-automerge-automerge/rust/automerge/src/read.rs):199-204,
/// over [`Automerge::get_cursor_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1732-1758
/// over [`cursor.getCursor`](cursor.zig)).
///
/// **`heads` is upstream's `at`, carried on the method itself.**
/// `fn get_cursor<O: AsRef<ExId>, I: Into<CursorPosition>>(&self, obj: O,
/// position: I, at: Option<&[ChangeHash]>) -> Result<Cursor, AutomergeError>`
/// ([`read.rs`:203](../../github-automerge-automerge/rust/automerge/src/read.rs))
/// is one signature with the heads in it, so this is one method with the
/// heads in it. **The parameter is named `heads` because that is what
/// upstream binds it to**: every one of the three bodies destructures it the
/// same way — `let clock = at.and_then(|heads| self.clock_at(heads));`
/// ([`automerge.rs`:2175, :2186, :2196](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// — and it is the name all fourteen readers in this file use, so
/// [`atScope`] takes one name too.
///
/// **`heads = null` is this document's read scope, not "no scope"**: the
/// isolation's clock, and no clock at all when the document is not isolated.
/// That is the reading [`markSetAtIndex`] argues at length and the reading
/// [`hydrate`] argues at length, and **it agrees with upstream on every
/// document that is not isolated** — the only case in which upstream's
/// `and_then` produces a clock at all.
///
/// **Ownership: a value, and that is the type's whole point.** A [`Cursor`] is
/// an element's *operation id* and a bias — not an index — so it outlives every
/// mutation that does not remove the element it names, and re-reading it
/// through [`getCursorPosition`] is how a caller finds where it has got to.
/// The `OpCursor`'s [`ActorId`](types.zig) is the document's own bytes:
/// [`Document`](doc.zig)'s arena owns the actor table
/// ([doc.zig:91-92](../doc.zig)), and adding an actor *shifts indices* without
/// moving bytes ([`OpSet.insertActor`](opset/op_set.zig), `op_set.rs:1400`).
/// So **a cursor stays valid for the life of the document**, and the test
/// `test "a cursor taken before a mutation still names the same element after it"`
/// is the one that checks it.
///
/// [API.md](../API.md) gives this method no allocator; the seek underneath
/// collects a register and allocates ([`OpSet.seekOpsByIndex`](opset/op_set.zig)),
/// so it takes one. The report names it as a deviation.
///
/// **This is [`getCursorMoving`] with `bias = .after`**, which is upstream's
/// own sentence ([read.rs:198](../../github-automerge-automerge/rust/automerge/src/read.rs)):
/// "This is equivalent to `Self::get_cursor_moving()` with `move_cursor =
/// MoveCursor::After`" (`:2176`).
///
/// **What it refuses** ([`cursor.getCursor`](cursor.zig), `automerge.rs:1739-1754`):
/// `error.NotAnObject` for an id that names no object, `error.InvalidOp` for
/// **a map, which has no cursor position at all** (`:1740-1742`), and
/// `error.InvalidIndex` for an index at or past the end of the sequence.
/// `.start` and `.end` never fail (`automerge.rs:1744-1745`): a start or an end
/// position can never be removed, so `bias` does not affect them
/// ([read.rs:221](../../github-automerge-automerge/rust/automerge/src/read.rs)).
pub fn getCursor(
    doc: *const Document,
    obj: ExId,
    pos: CursorPosition,
    heads: ?[]const ChangeHash,
    gpa: Allocator,
) ReadError!Cursor {
    return getCursorMoving(doc, obj, pos, heads, .after, gpa);
}

/// [`getCursor`], with the bias that says which way the cursor moves when the
/// element it names is removed
/// ([`ReadDoc::get_cursor_moving`](../../github-automerge-automerge/rust/automerge/src/read.rs):224-230,
/// over [`Automerge::get_cursor_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1732-1758
/// over [`cursor.getCursor`](cursor.zig)).
///
/// **`heads` is upstream's `at` and it is upstream's argument order** —
/// `position`, then `at`, then `move_cursor`
/// ([`read.rs`:228](../../github-automerge-automerge/rust/automerge/src/read.rs),
/// [`automerge.rs`:2179-2188](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **Ownership: a value**, for the same reason and with the same lifetime as
/// [`getCursor`].
///
/// **`bias` decides only what happens once the element is gone.** With the
/// element still there both biases answer its index
/// ([cursor.zig:742](../cursor.zig), `automerge.rs:1803-1804`). With it gone,
/// `.after` answers the index it *would* have had — the next visible element's
/// index, or the sequence's length (`:1789-1794`) — and `.before` walks back
/// to the nearest element that is still visible, or `0` (`:1795-1803`).
///
/// **The clock changes which elements the seek can see and nothing else**, so
/// an index at or past the end of the sequence *at those heads* is
/// `error.InvalidIndex` where the present would have answered a cursor
/// ([`automerge.rs`:1751-1755](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
/// **`.start` and `.end` are unchanged by any clock**, for the reason
/// [`getCursor`] gives: a start or an end position can never be removed
/// ([`read.rs`:221](../../github-automerge-automerge/rust/automerge/src/read.rs)).
pub fn getCursorMoving(
    doc: *const Document,
    obj: ExId,
    pos: CursorPosition,
    heads: ?[]const ChangeHash,
    bias: Bias,
    gpa: Allocator,
) ReadError!Cursor {
    const scope = if (heads) |h| try atScope(doc, h) else try readScope(doc);
    return cursormod.getCursor(gpa, mutableOps(doc), try liveObj(doc, obj), pos, scope, bias);
}

/// Where `cursor` sits in `obj` under the clock `heads` names
/// ([`ReadDoc::get_cursor_position`](../../github-automerge-automerge/rust/automerge/src/read.rs):237-242,
/// over [`Automerge::get_cursor_position_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1760-1849
/// over [`cursor.getCursorPosition`](cursor.zig)).
///
/// **`heads` is upstream's `at` and it is upstream's argument order**
/// ([`read.rs`:241](../../github-automerge-automerge/rust/automerge/src/read.rs),
/// [`automerge.rs`:2190-2198](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **Ownership: a value.** A `usize`.
///
/// **This is the other half of the cursor property.** A cursor taken before a
/// mutation is asked this question after it, and the answer moves with the
/// elements around it: an element inserted *before* the one it names pushes its
/// index up, and an element deleted before it pulls the index down. That is
/// what a stable address is for
/// ([read.rs:206-210](../../github-automerge-automerge/rust/automerge/src/read.rs)).
///
/// **What it refuses** ([`cursor.getCursorPosition`](cursor.zig),
/// `automerge.rs:1766-1781`): `error.NotAnObject` for an id that names no
/// object, and `error.InvalidCursor` for **a map, which has no cursor
/// position** (`:1772-1774`), for an actor the document's table does not hold
/// (`:783-785`), for a counter that names no row in `obj` (`:1778-1781`), and
/// **for a counter that names a row of some other object** — the same question
/// and the same refusal; see the `catch` below.
///
/// **A cursor the clock does not cover is `error.InvalidCursor`** —
/// upstream's `op_cursor_to_opid` ([`automerge.rs`:777-780](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// over [`cursormod.getCursorPosition`](cursor.zig)'s `c.contains(elem.id)`
/// guard. **This is the one
/// place a historical cursor read refuses something the present answers**,
/// and it is not a corner: it is exactly "name an element that did not exist
/// at those heads", which is the question a historical read is asked.
///
/// `.start` answers `0` and `.end` answers the sequence's length, both
/// infallibly (`:1767-1768`).
pub fn getCursorPosition(
    doc: *const Document,
    obj: ExId,
    cursor: Cursor,
    heads: ?[]const ChangeHash,
) ReadError!usize {
    const scope = if (heads) |h| try atScope(doc, h) else try readScope(doc);
    return getCursorPositionFor(doc, obj, cursor, scope);
}

/// [`getCursorPosition`] with the clock already resolved — upstream's
/// `Automerge::get_cursor_position_for`
/// ([`automerge.rs:1760-1849`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// which is the function **both** `ReadDoc` receivers call underneath:
/// `Automerge`'s at [`:2197`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)
/// and `AutoCommit`'s at
/// [`autocommit.rs:1003`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs).
///
/// **The clock is a parameter here rather than `heads`, because the two
/// receivers resolve it differently and the difference is load-bearing.**
/// [`Automerge::get_cursor_position`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2196
/// fills it with `at.and_then(|heads| self.clock_at(heads))`, while
/// [`AutoCommit::get_scope`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):794-805
/// — the one an [`AMdoc`](c/doc.zig) reaches — **takes a different arm when a
/// transaction is in flight**, and upstream says why in its own comment
/// ([`:797-799`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)):
/// "the heads == current-heads shortcut (an unscoped read) is only sound with
/// no transaction in flight: pending ops are already in the op set but not yet
/// under the graph's heads". **Collapsing the two is what let a cursor resolve
/// at the present when a C caller asked for the heads it was minted at.**
pub fn getCursorPositionFor(
    doc: *const Document,
    obj: ExId,
    cursor: Cursor,
    scope: ?Clock,
) ReadError!usize {
    // **The label on the empty seek is upstream's, and it is applied in the
    // function upstream applies it in.**
    //
    // `get_cursor_position_for` seeks the cursor's element inside `obj` and
    // turns the seek's *empty* answer into its own refusal:
    // `.ok_or_else(|| AutomergeError::InvalidCursor(cursor.clone()))`
    // ([`automerge.rs`:1778-1781](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    // **Upstream's seek cannot raise — it answers `Option` — and the port's
    // can**: [`OpSet.seekListOpid`](opset/op_set.zig) is fallible for the same
    // question and returns `error.InvalidIndex` when the row the id names lies
    // outside the object's range
    // ([`op_set.zig`:3145](../opset/op_set.zig)'s range check, and the two prefix
    // descents below it). **So the
    // refusal arrives under the wrong name, and this is the one place the name
    // is put back**: upstream's `InvalidCursor` for this arm is the port's
    // `InvalidCursor` for this arm, as it already was for every other.
    //
    // **The `InvalidIndex` this catches is exactly one refusal**, so nothing
    // else is relabelled: `OpSet.scopeToObj` is `ParseError`
    // ([`op_set.zig`:2092](../opset/op_set.zig)), `OpSet.getOpIdPos` reports a
    // counter the document does not hold as `error.InvalidValue` or as a `null`
    // ([`:2352-2368`](../opset/op_set.zig)), `OpSet.get` is `ReadOpError`
    // ([`:2193`](../opset/op_set.zig)), and the backward walk's own seek
    // ([`cursor.zig`:830](../cursor.zig)) asks about an **anchor of this
    // object**, which upstream's `None => break Ok(0)`
    // ([`automerge.rs`:1841](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // already covers — so it is not the source of this arm either.
    //
    // **It also makes the present and a historical read agree with each
    // other**, which they did not before. With a clock the port takes the slow
    // arm alone ([`seekListOpid`](opset/op_set.zig):3093), which answers `null`
    // for an id outside the object and so already refused with
    // `InvalidCursor`; without one the fast arm's range check ran first
    // ([`:3145`](../opset/op_set.zig)) and refused with `InvalidIndex`. **Same
    // cursor, same object, two names, depending only on whether a clock was in
    // play.** Upstream has one name because it has one question and one `None`.
    const found = cursormod.getCursorPosition(
        mutableOps(doc),
        try liveObj(doc, obj),
        cursor,
        scope,
    ) catch |e| switch (e) {
        error.InvalidIndex => return error.InvalidCursor,
        else => |rest| return rest,
    };
    return found;
}

/// The hashes of the changes of `heads` this document does not have, sorted and
/// deduplicated
/// ([`ReadDoc::get_missing_deps`](../../github-automerge-automerge/rust/automerge/src/read.rs):302,
/// over [`Automerge::get_missing_deps`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2289-2292
/// over [`missing_deps_from`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2037-2066).
///
/// **Ownership: the slice is the caller's.** Free it with `gpa`.
///
/// [API.md](../API.md) gives this method no allocator and no error arm; the
/// walk behind it builds a hash set and a stack
/// ([`ChangeGraph.missingDepsFrom`](change_graph.zig), `:759-778`) and cannot
/// answer without one, so both were added. The report names them as
/// deviations. **A borrowed slice is not an option**: a document has nowhere
/// to keep the answer, and a global would be
/// [AGENTS.md](AGENTS.md)'s forbidden hidden allocator.
///
/// **The change queue is chained in front of `heads`**, which is upstream's
/// whole line (`:2290-2291`): a change that arrived early is not missing, it is
/// waiting, and the answer a sync peer needs is the first hash on each path
/// back that is neither applied nor queued.
pub fn getMissingDeps(
    doc: *const Document,
    heads: []const ChangeHash,
    gpa: Allocator,
) Error![]ChangeHash {
    return doc.getMissingDeps(gpa, heads);
}

/// The change with this hash, or null when the document does not hold it
/// ([`ReadDoc::get_change_by_hash`](../../github-automerge-automerge/rust/automerge/src/read.rs):305,
/// over [`Automerge::get_change_by_hash`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2294-2298).
///
/// **Ownership: the caller's.** Free it with `Built.deinit`](doc.zig), which
/// gives back the encoded body **and** the actor array `parseChange` made.
///
/// [API.md](../API.md) gives this method a bare `?Change` and no allocator,
/// and **it cannot be written that way in this port**: a document chunk stores
/// the graph's metadata and the op set's rows, not the change chunks
/// ([doc.zig:50-54](../doc.zig)), so a change is *re-encoded* from the rows
/// every time it is asked for and its bytes are freshly allocated. There is
/// nothing in the document for a borrowed `?Change` to borrow. The port's
/// answer is [`docmod.Built`](doc.zig) — the bytes plus the change — and it is
/// what [`Document.getChangeByHash`](doc.zig) already returns. The report
/// names it as a deviation.
///
/// **A hash the document does not hold is `null` and not an error** — that is
/// upstream's `Option` — **but a change the graph *does* hold and the op set
/// cannot rebuild is an error**, because the alternative is a change with the
/// wrong bytes in it and a peer that would reject it.
pub fn getChangeByHash(doc: *const Document, hash: ChangeHash, gpa: Allocator) ChangeError!?docmod.Built {
    return mutableDoc(doc).getChangeByHash(gpa, hash);
}

/// What the document holds
/// ([`ReadDoc::stats`](../../github-automerge-automerge/rust/automerge/src/read.rs):308,
/// over [`Automerge::stats`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2300-2315).
///
/// **Ownership: a value.** Three `u64`s that outlive the document.
///
/// Upstream's struct also carries the crate name, the crate version and the
/// `rustc` version, which are facts about the build and not about the
/// document, so [`Stats`](doc.zig) has three fields and the report says so.
pub fn stats(doc: *const Document) Stats {
    return doc.stats();
}

/// How every text width in the document is measured
/// ([`ReadDoc::text_encoding`](../../github-automerge-automerge/rust/automerge/src/read.rs):310,
/// over [`OpSet::text_encoding`](opset/op_set.zig), `op_set.rs:64`).
///
/// **Ownership: a value.** An enum, and a document-level one: the encoding
/// cannot change after the document is built, because every text-width entry
/// in the op set is measured in it
/// ([doc.zig:2119-2122](../doc.zig)).
pub fn textEncoding(doc: *const Document) TextEncoding {
    return doc.textEncoding();
}

/// The keys and values of the map `obj` whose key falls in `range`
/// ([`ReadDoc::map_range`](../../github-automerge-automerge/rust/automerge/src/read.rs):84-88,
/// over [`Automerge::map_range_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1676-1686,
/// over [`OpSet::map_range`](opset/op_set.zig), `op_set.rs:396-419`).
///
/// **Ownership: the walk borrows the document, and every
/// [`MapRangeItem`] it hands out borrows the document too** — the key out of
/// the string table, a scalar payload out of the value column — and is valid
/// until the next mutation. [`MapRangeItem.intoOwned`](iter/map_range.zig) is
/// the copy for a caller that has to hold one across a mutation.
///
/// **Constructing one allocates nothing**: four column cursors, a skipper and a
/// lookahead, all of them values over storage the op set already holds
/// ([iter/map_range.zig:835-836](../iter/map_range.zig)), and the row range is
/// [`OpSet.mapRange`](opset/op_set.zig)'s four arms — two column descents and at
/// most two key-column walks, and no allocation.
///
/// **A list or a text yields an empty walk**, which is upstream's documented
/// behaviour — "If the object correspoding to `obj` is a list then this will
/// return an empty iterator" ([read.rs:80-81](../../github-automerge-automerge/rust/automerge/src/read.rs))
/// — and **an id that names no object yields an empty walk** too, which is
/// upstream's `.ok().map(..).unwrap_or_default()` (`:1682-1685`). Neither is an
/// error, and the test "a list and an unknown id are empty map ranges, not errors"
/// is the one that says so.
///
/// The row range behind `range` is [`OpSet.mapRange`](opset/op_set.zig)'s
/// arithmetic (`op_set.rs:396-419`) and nothing else: **this function used to
/// keep a second copy of it** and does not any more. Upstream's `match`, arm
/// for arm (`op_set.rs:406-416`), is a null bound is the object range, an
/// `included` **start** is the register's `.start` and an `excluded` start is
/// its `.end`, and the **end** bound is the mirror of that — `included` is the
/// register's `.end`, `excluded` is its `.start`. The asymmetry is upstream's
/// and it is why a pair of optional keys could not stand in for a
/// `RangeBounds`: `Included(end)` and `Excluded(end)` name **different** row
/// ranges, one register apart, and the two arms a C `AMmapRange` needs
/// (`op_set.rs:409` and `:415`) were the two it could not reach.
///
/// **One owner, one answer.** [`OpSet.mapRange`](opset/op_set.zig) takes a
/// [`KeyBound`] at each end and reaches all four arms, so this function hands
/// `range.start` and `range.end` straight to it. The C binding's own row
/// arithmetic ([`src/c/doc.zig:4032-4040`](c/doc.zig)) is the same four arms
/// written once more; a reader and the C binding over one document now answer
/// the same keys because both go through the same per-arm answer rather than
/// because two copies agree.
///
/// **A range whose `start` is at or past its `end` is empty**, for the reason
/// [`OpSet.mapRange`](opset/op_set.zig) gives.
pub fn mapRange(doc: *const Document, obj: ExId, range: KeyRange) ReadError!MapRange {
    return MapRange.init(
        mutableOps(doc),
        try doc.ops.mapRange(liveObjOrSelf(doc, obj), range.start, range.end),
        try readScope(doc),
    );
}

/// [`mapRange`] as at `heads`
/// ([`ReadDoc::map_range_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):99-104,
/// over [`Automerge::map_range_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2110-2118).
///
/// **Ownership and the row arithmetic are [`mapRange`]'s** — this body is the
/// one upstream hands to both spellings
/// ([`automerge.rs`:2116-2117](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.map_range_for(obj.as_ref(), range, clock)`.
/// **A list or a text and an id that names no object both still yield an
/// empty walk**, and the row bounds behind `range` are still
/// [`OpSet.mapRange`](opset/op_set.zig)'s four arms and not a second copy of
/// them.
///
/// **`heads` is a list and never null** ([`read.rs`:103](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **The clock is borrowed from the document, not owned by this call**: free
/// or drop the walk before the next `_at` read at other heads.
pub fn mapRangeAt(
    doc: *const Document,
    obj: ExId,
    range: KeyRange,
    heads: []const ChangeHash,
) ReadError!MapRange {
    return MapRange.init(
        mutableOps(doc),
        try doc.ops.mapRange(liveObjOrSelf(doc, obj), range.start, range.end),
        try atScope(doc, heads),
    );
}

/// The elements and values of the list or text `obj` whose index falls in
/// `range`
/// ([`ReadDoc::list_range`](../../github-automerge-automerge/rust/automerge/src/read.rs):110,
/// over [`Automerge::list_range_for`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1688-1698,
/// over [`OpSet::list_range`](opset/op_set.zig), `op_set.rs:386-394`).
///
/// **Ownership: the walk borrows the document, and every
/// [`ListRangeItem`] it hands out borrows the document too** — a scalar payload
/// out of the value column — and is valid until the next mutation.
/// [`ListRangeItem.intoOwned`](iter/list_range.zig) is the copy.
///
/// **Constructing one allocates nothing**, as [`mapRange`] is, and
/// **`range` is the port's half-open [`IndexRange`]** where upstream's is a
/// `RangeBounds<usize>`, because Zig has no range-bounds protocol
/// ([iter/list_range.zig:127-135](../iter/list_range.zig)).
///
/// **The filter is after the walk, as upstream's is**: an element's index is
/// only known once the elements before it have been counted, so a range that
/// starts past the end of the object still walks every row and answers nothing
/// ([iter/list_range.zig:740-746](../iter/list_range.zig), `list_range.rs:345-357`).
/// **A map or an unknown id therefore yields an empty walk**, and not an error.
pub fn listRange(doc: *const Document, obj: ExId, range: IndexRange) ReadError!ListRange {
    return ListRange.init(
        mutableOps(doc),
        try doc.ops.listRange(liveObjOrSelf(doc, obj)),
        try readScope(doc),
        range,
    );
}

/// [`listRange`] as at `heads`
/// ([`ReadDoc::list_range_at`](../../github-automerge-automerge/rust/automerge/src/read.rs):118-123,
/// over [`Automerge::list_range_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2124-2132).
///
/// **Ownership, the filter and the empty-walk cases are [`listRange`]'s**,
/// because the body is the one upstream hands to both spellings
/// ([`automerge.rs`:2130-2131](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// `let clock = self.clock_at(heads); self.list_range_for(obj.as_ref(), range, clock)`.
/// **This method adds a clock and nothing else.**
///
/// **`heads` is a list and never null** ([`read.rs`:122](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// and **naming the document's own heads reads the present**, because
/// [`Automerge::clock_at`] reports no clock for them
/// ([`automerge.rs`:1241-1246](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// — so `listRangeAt(.., doc.getHeads())` is `listRange`. The module doc's
/// *Historical reads* section is where that shortcut is argued.
///
/// **The clock is borrowed from the document, not owned by this call**, and
/// the walk reads it long after this function returns: free or drop the walk
/// before the next `_at` read at other heads.
pub fn listRangeAt(
    doc: *const Document,
    obj: ExId,
    range: IndexRange,
    heads: []const ChangeHash,
) ReadError!ListRange {
    return ListRange.init(
        mutableOps(doc),
        try doc.ops.listRange(liveObjOrSelf(doc, obj)),
        try atScope(doc, heads),
        range,
    );
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// The document's one actor, as the test fixtures name it. An actor index is a
/// position in a sorted table ([types.zig:20-21](../src/types.zig)), so with
/// one actor every index in the columns is `0`.
const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };

/// An id no row and no object index holds. **Both halves are past the end** so
/// the object columns' descents miss rather than finding the first object's
/// rows by accident.
const missing: ExId = .{ .id = OpId.init(999, 7) };

/// One row of a fixture, in the columns' own vocabulary.
const OpSpec = struct {
    /// The row's own operation id.
    ctr: u32,
    /// The object the row hangs in. The root when absent.
    obj: ExId = .root,
    /// What the row does.
    action: optypes.Action = .set,
    /// The register it addresses: a map key, or the element it hangs by.
    key: optypes.KeyRef,
    /// The value it carries.
    value: optypes.ScalarValue = .null_value,
    /// **Whether the row inserts into a sequence rather than overwriting a
    /// key** — and every mark row does
    /// ([`op_set.zig:4015-4021`](../opset/op_set.zig) is the port's own
    /// `markBegin` helper and says "Both halves of a mark are inserts, which is
    /// what upstream's `insert_mark_end_after` produces", `transaction/inner.rs:830-866`).
    /// A mark that is not an insert has a register of its raw key and the row
    /// order checker refuses the pair, so this field is not optional.
    insert: bool = false,
    /// Whether a mark expands before its span.
    expand: bool = false,
    /// The mark's name, or null for a mark **end** — which is what makes a
    /// mark row a begin and an end ([value.zig:264-272](../src/value.zig)).
    mark: ?[]const u8 = null,
    /// The rows this one shadows, which is how a **delete** is written
    /// ([`opset/columns.zig:81-85`](../opset/columns.zig): "A delete is never a
    /// row"). There is no delete action here and no such row: a delete is a
    /// successor edge on the row it removes, and upstream's delete op is a row
    /// the columns drop ([`columns.zig:420`](../opset/columns.zig)).
    succ: []const OpId = &.{},
};

/// `specs` as the [`ChangeOp`]s the op set's splice path takes, with each
/// row's successor edges on the row itself.
fn buildOps(gpa: Allocator, actor: types.ActorIdx, specs: []const OpSpec) ![]ChangeOp {
    const ops = try gpa.alloc(ChangeOp, specs.len);
    var made: usize = 0;
    errdefer {
        for (ops[0..made]) |*op| op.deinit(gpa);
        gpa.free(ops);
    }
    for (specs, 0..) |spec, i| {
        ops[i] = try ChangeOp.init(
            gpa,
            OpId.init(spec.ctr, actor),
            spec.obj,
            spec.action,
            spec.key,
            spec.value,
            spec.insert,
            spec.expand,
            spec.mark,
            &.{},
        );
        for (spec.succ) |s| {
            try ops[i].succs.append(gpa, .{ .id = s, .inc = null });
        }
        made += 1;
    }
    return ops;
}

/// The objects of the sample fixture, at the ids the rows that make them say.
/// **Named once**, because a test that restates a counter inline has a second
/// place to be wrong.
const list_id: ExId = .{ .id = OpId.init(1, 0) };
const text_id: ExId = .{ .id = OpId.init(2, 0) };
const map_id: ExId = .{ .id = OpId.init(3, 0) };

/// The text object **inside** the nested map, so [`parents`] has two levels to
/// walk rather than one.
const deep_id: ExId = .{ .id = OpId.init(19, 0) };

/// The list's four elements. **`elem_d` is the deleted one**, so the list reads
/// `a`, `b`, `c`.
const elem_a: OpId = OpId.init(5, 0);
const elem_b: OpId = OpId.init(6, 0);
const elem_c: OpId = OpId.init(7, 0);
const elem_d: OpId = OpId.init(8, 0);

/// The text's three elements, one grapheme each, so a mark can end on an
/// element boundary and the window tests have somewhere to put a boundary.
const elem_h: OpId = OpId.init(10, 0);
const elem_i: OpId = OpId.init(11, 0);
const elem_bang: OpId = OpId.init(12, 0);

fn mkey(k: []const u8) optypes.KeyRef {
    return optypes.KeyRef.fromStr(k);
}

fn at(id: OpId) optypes.KeyRef {
    return optypes.KeyRef.fromElemId(ElemId.fromOpId(id));
}

fn head() optypes.KeyRef {
    return optypes.KeyRef.fromElemId(ElemId.head());
}

/// The document every test below is read from unless it needs another shape: a
/// **map**, a **list**, a **text object**, **two deletes** and **three marks**,
/// built through the op set's own splice path.
///
/// # The rows are in canonical order, and that is the whole fixture
///
/// [`Op.step`](opset/op.zig) is the executable form of the row-order invariant
/// (rules **R1**–**R4**, `op.zig:2205-2222`) and [`sample`] checks it, so a
/// fixture written in the wrong order is refused here rather than read back
/// plausibly wrong further down. Three of the four rules are doing work in the
/// rows below:
///
/// * **R1** puts the root's rows first, then the list (op `1,0`), the text
///   (op `2,0`) and the map (op `3,0`) — objects ascend.
/// * **R2** sorts the root's map registers by *key string*, which is why
///   `"gone"` at counter 9 comes before `"hello"` at counter 4. The counters
///   ascend within a register (R3) and the registers do not follow them.
/// * **R4** is the interesting one, and it is what decides where the mark rows
///   go. An insert opens a register keyed by **its own id**
///   ([`Op.elemidOrKey`](opset/op.zig), `op.rs:1040-1046`), and a new register
///   is legal iff the insert hangs by the element the previous row belongs to
///   **or its own id sorts before that element** (`op.rs:1061-1063`). So a
///   mark's position in the sequence is decided by *which element its row
///   lands next to*, and its two halves are `n` and `n + 1` because a mark end
///   closes `id.prev()` ([`MarkStateMachine.markEnd`](marks.zig), `marks.rs:294-319`).
///
/// # The three marks, and what each is for
///
/// | mark | span | why it is here |
/// |---|---|---|
/// | `code` | `[0, 3)` | **straddles every window.** A begin with no end runs to the end of the object ([`op_set.rs:1017-1022`](../opset/op_set.zig)), which is the one case that exercises the closing line. |
/// | `bold` | `[0, 1)` | **fits the first window exactly**, so a windowed read that counted rather than intersected would still answer one mark — and the intersection rule is what the test checks. |
/// | `em` | `[1, 2)` | **the middle**, so "in the middle" is a real middle rather than the start again. |
///
/// The mark rows are therefore **not** in counter order: `code`'s begin (17) and
/// `bold`'s begin (13) both hang by the head and so sort *before* the element
/// they mark, and `bold`'s end (14) hangs by `elem_h` and so lands *after* it.
const sample_specs = [_]OpSpec{
    // The root map, in key order: "gone" < "hello" < "list" < "map" < "text".
    // **The delete on `"gone"`** is a successor edge on that row; the id it
    // names need not be a row, and in a real document it is the delete's own
    // op id ([`iter/keys.zig:299-305`](../iter/keys.zig) says the same).
    .{ .ctr = 9, .key = mkey("gone"), .value = .{ .str = "bye" }, .succ = &.{OpId.init(41, 0)} },
    .{ .ctr = 4, .key = mkey("hello"), .value = .{ .str = "world" } },
    .{ .ctr = 1, .action = .make_list, .key = mkey("list") },
    .{ .ctr = 3, .action = .make_map, .key = mkey("map") },
    .{ .ctr = 2, .action = .make_text, .key = mkey("text") },

    // The list: `a`, `b`, `c`, `d` — each hanging by the one before it, which
    // is R4's first arm every time. **The delete on `d`**, again as a successor
    // edge, so the list reads three elements.
    .{ .ctr = 5, .obj = list_id, .key = head(), .insert = true, .value = .{ .str = "a" } },
    .{ .ctr = 6, .obj = list_id, .key = at(elem_a), .insert = true, .value = .{ .str = "b" } },
    .{ .ctr = 7, .obj = list_id, .key = at(elem_b), .insert = true, .value = .{ .str = "c" } },
    .{ .ctr = 8, .obj = list_id, .key = at(elem_c), .insert = true, .value = .{ .str = "d" }, .succ = &.{OpId.init(40, 0)} },

    // The text: three single-grapheme elements, then the marks woven between
    // them. **`code`'s begin hangs by the head** (register `17,0`, so it sorts
    // before `elem_h`'s register `10,0` by R4's second arm) and has no end.
    .{ .ctr = 17, .obj = text_id, .key = head(), .insert = true, .action = .mark, .mark = "code", .value = .{ .uint = 7 } },
    // **`bold`'s begin** also hangs by the head (register `13,0`, before `17,0`).
    .{ .ctr = 13, .obj = text_id, .key = head(), .insert = true, .action = .mark, .mark = "bold", .value = .{ .uint = 0 } },
    // `elem_h`, one grapheme wide.
    .{ .ctr = 10, .obj = text_id, .key = head(), .insert = true, .value = .{ .str = "h" } },
    // **`em`'s begin hangs by `elem_h`**, so it lands right after it and the
    // mark starts at index 1. Its id is 15, which sorts before `bold`'s end's
    // register `14,0`... no: after it, by R4's second arm (`14 < 15`).
    .{ .ctr = 15, .obj = text_id, .key = at(elem_h), .insert = true, .action = .mark, .mark = "em", .value = .{ .uint = 1 } },
    // **`bold`'s end**, no name, and `id.prev()` is 12 — no: 13, which is
    // `bold`'s own begin. It hangs by `elem_h`, so it lands right after it at
    // index 1 and the mark is `[0, 1)`.
    .{ .ctr = 14, .obj = text_id, .key = at(elem_h), .insert = true, .action = .mark, .value = .{ .uint = 0 } },
    // `elem_i`, one grapheme wide.
    .{ .ctr = 11, .obj = text_id, .key = at(elem_h), .insert = true, .value = .{ .str = "i" } },
    // **`em`'s end**, `id.prev()` being 15, hanging by `elem_i` so it lands at
    // index 2. The mark is `[1, 2)`.
    .{ .ctr = 16, .obj = text_id, .key = at(elem_i), .insert = true, .action = .mark, .value = .{ .uint = 1 } },
    // `elem_bang`, the last grapheme.
    .{ .ctr = 12, .obj = text_id, .key = at(elem_i), .insert = true, .value = .{ .str = "!" } },

    // The nested map, and a text object **inside** it, so `parents` has two
    // levels to walk and `get` on a nested object is exercised. The map's own
    // registers are in key order — `"deep"` before `"in_map"` — and its rows
    // are the last in the document because the map is the highest object.
    .{ .ctr = 19, .obj = map_id, .action = .make_text, .key = mkey("deep") },
    .{ .ctr = 18, .obj = map_id, .key = mkey("in_map"), .value = .{ .str = "yes" } },
};

/// [`sample_specs`] spliced into a fresh document and its index rebuilt.
///
/// **The splice path, not `applyChanges`.** A local commit and a peer's change
/// both go through the change encoder, and a read surface must not depend on it
/// to be tested. [`OpSet.splice`](opset/op_set.zig) plus
/// [`OpSet.rebuildIndex`](opset/op_set.zig) is what a load does
/// ([`op_set.zig:51-62`](../opset/op_set.zig)), and **the rebuild is not
/// optional**: the five index columns are derived state, the exporter does not
/// write them ([`op_set.zig:745-748`](../opset/op_set.zig)), and a splice
/// leaves every row a winner ([`OpSet.visible`](opset/op_set.zig) is
/// `Op.visible`).
fn sample(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, .auto);
    errdefer doc.deinit();
    const a = try doc.putActorRef(gpa, actor_a);
    try testing.expectEqual(@as(types.ActorIdx, 0), a);

    const ops = try buildOps(gpa, a, &sample_specs);
    defer docmod.freeChangeOps(gpa, ops);
    _ = try mutableOps(&doc).splice(0, ops);
    try mutableOps(&doc).rebuildIndex();

    // **The premises, before any conclusion is drawn from them.** Row order
    // first, because a fixture that got it wrong is refused here rather than
    // read back plausibly wrong; then the object index, because every reader
    // that takes an object id asks the index and not the caller's word.
    try testing.expect(try mutableOps(&doc).validateOpOrder());
    try testing.expectEqual(@as(?opsetmod.TopIndexFault, null), try mutableOps(&doc).validateTopIndex());
    try testing.expectEqual(ObjType.map, try doc.objectType(.root));
    try testing.expectEqual(ObjType.list, try doc.objectType(list_id));
    try testing.expectEqual(ObjType.text, try doc.objectType(text_id));
    try testing.expectEqual(ObjType.map, try doc.objectType(map_id));
    return doc;
}

/// A root map built from `specs`, through the same splice path [`sample`] uses.
///
/// **The row order in `specs` is the row order in the op set**, so a fixture
/// written here is in rule **R2**/rule **R3** order — registers ascending by key
/// string, and a register's own rows ascending by counter — and **that is
/// checked rather than assumed.** [`Op.step`](../opset/op.zig) is the
/// executable form of the row-order invariant (`op.zig:2205-2222`), the
/// readers take the rows as they find them and no reader sorts, so a fixture
/// written out of order is a document that answers in a sequence no reader may
/// produce. **The row-order and top-index premises [`sample`] states are run
/// here too**, and a fixture that breaks either is **refused at the build**
/// rather than read back as answers in an order the op set does not hold them
/// in.
fn rootMap(gpa: Allocator, specs: []const OpSpec) !Document {
    var doc = try Document.init(gpa, .auto);
    errdefer doc.deinit();
    const a = try doc.putActorRef(gpa, actor_a);
    const ops = try buildOps(gpa, a, specs);
    defer docmod.freeChangeOps(gpa, ops);
    _ = try mutableOps(&doc).splice(0, ops);
    try mutableOps(&doc).rebuildIndex();

    // **The premises, in the two lines `sample` writes.** Row order first,
    // because every answer a read gives is read out of it; the top index
    // second, because a reader that takes an object id asks the index and not
    // the caller's word.
    try testing.expect(try mutableOps(&doc).validateOpOrder());
    try testing.expectEqual(@as(?opsetmod.TopIndexFault, null), try mutableOps(&doc).validateTopIndex());
    return doc;
}

/// **The document `test_range_iter_map` builds**
/// ([`automerge-c/test/map_tests.c:252-261`](../../github-automerge-automerge/rust/automerge-c/test/map_tests.c)):
/// four keys `a`…`d` put once each, then `a` twice more and `d` once more, so
/// `a` and `d` are registers of three and two rows and `b` and `c` are
/// registers of one. **Registers of more than one row are the point**: a
/// half-open end that is off by a whole register shows up here and nowhere
/// else, and the values are the ones the case asserts (`a` is 8, `b` is 4,
/// `c` is 5).
const c_map_specs = [_]OpSpec{
    .{ .ctr = 0, .key = mkey("a"), .value = .{ .uint = 3 } },
    .{ .ctr = 1, .key = mkey("a"), .value = .{ .uint = 7 } },
    .{ .ctr = 2, .key = mkey("a"), .value = .{ .uint = 8 } },
    .{ .ctr = 3, .key = mkey("b"), .value = .{ .uint = 4 } },
    .{ .ctr = 4, .key = mkey("c"), .value = .{ .uint = 5 } },
    .{ .ctr = 5, .key = mkey("d"), .value = .{ .uint = 6 } },
    .{ .ctr = 6, .key = mkey("d"), .value = .{ .uint = 9 } },
};

/// Adds one more key on the root, as rows of its own.
///
/// Used to **mutate a document a read has already answered from**, which is the
/// only way the ownership rules can be tested rather than asserted.
fn mutate(gpa: Allocator, doc: *Document) !void {
    const a = try doc.putActorRef(gpa, actor_a);
    const specs = [_]OpSpec{
        .{
            .ctr = 30,
            .key = mkey("zzz"),
            // **A long value, so the op set's raw value column has to grow** and
            // the mutation cannot be a no-op on the storage a read borrowed.
            .value = .{ .str = "a value long enough to move the raw column's block" },
        },
    };
    const ops = try buildOps(gpa, a, &specs);
    defer docmod.freeChangeOps(gpa, ops);
    const root_rows = try mutableOps(doc).scopeToObj(.root);
    // **At the end**, because `"zzz"` sorts after every key the root holds and
    // rule **R2** orders map registers by key string
    // ([op_set.rs:1059-1060](../opset/op_set.zig)). A mutation at the front
    // would be a row out of order, and a fixture that had one would be refused
    // by the checker rather than read back plausibly wrong.
    _ = try mutableOps(doc).splice(root_rows.end, ops);
    try mutableOps(doc).rebuildIndex();
}

/// Splices one insert into the list, where the op set's own resolver says the
/// row goes.
///
/// **The resolver, not a guess.** The anchor is the load-bearing answer of a
/// local insert ([insert.zig](opset/insert.zig)'s module doc, "The three
/// answers, and which of them is the row-order invariant") and a hand-written
/// anchor that disagreed with it would be a fixture that only reads correctly
/// by accident.
fn insertIntoList(gpa: Allocator, doc: *Document, ctr: u32, index: usize, text_bytes: []const u8) !void {
    const a = try doc.putActorRef(gpa, actor_a);
    var where = try mutableOps(doc).queryInsertAt(gpa, list_id, index, .list, null);
    defer where.deinit(gpa);
    const specs = [_]OpSpec{
        .{
            .ctr = ctr,
            .obj = list_id,
            .key = optypes.KeyRef.fromElemId(where.elemid),
            .insert = true,
            .value = .{ .str = text_bytes },
        },
    };
    const ops = try buildOps(gpa, a, &specs);
    defer docmod.freeChangeOps(gpa, ops);
    _ = try mutableOps(doc).splice(where.pos, ops);
    try mutableOps(doc).rebuildIndex();
}

/// Shadows the list element `victim` with a delete, **after** the fixture was
/// spliced.
///
/// **A delete is a successor edge and not a row**
/// ([opset/columns.zig:81-85](../opset/columns.zig)), so there is nothing to
/// splice: the op set's own mutating entry point is
/// [`OpSet.addSuccWithUndo`](opset/op_set.zig), which writes the edge *and*
/// takes the row out of the visible index — `:1584-1591` calls that arm a
/// delete and lists the three things it stops. The undo list it returns is
/// **not** replayed, which is what "not undoing this" means, and it is freed.
fn deleteElem(gpa: Allocator, doc: *Document, victim: OpId, delete_id: OpId) !void {
    const set = mutableOps(doc);
    const pos = (try set.getOpIdPos(victim)) orelse return error.TestUnexpectedResult;
    var walk = try set.iterRange(.{ .start = pos, .end = pos + 1 });
    const row = (try walk.next()) orelse return error.TestUnexpectedResult;
    const ins = row.addSucc(delete_id, null);
    const undo = try set.addSuccWithUndo(&.{ins});
    gpa.free(undo);
    try set.rebuildIndex();
}

/// Reads every key of `obj` out of a [`Keys`] walk, in order, **copied**.
fn keyList(gpa: Allocator, doc: *const Document, obj: ExId) ![][]const u8 {
    var walk = try keys(doc, obj);
    defer walk.deinit(doc.allocator());
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    // **Copied, and that is the contract**: a sequence anchor is the walk's own
    // buffer and is valid only until the next `next()` ([`keys`]).
    while (try walk.next()) |k| try out.append(gpa, try gpa.dupe(u8, k));
    return out.toOwnedSlice(gpa);
}

fn freeStrings(gpa: Allocator, list: []const []const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

/// The values of a [`Values`] walk over `obj`, in order, with their ids.
fn valueList(gpa: Allocator, doc: *const Document, obj: ExId) ![]itervalues.ValuesItem {
    var term: ValueTerm = undefined;
    var walk = try values(doc, obj, &term);
    defer term.deinit(doc.allocator());
    var out: std.ArrayList(itervalues.ValuesItem) = .empty;
    errdefer out.deinit(gpa);
    while (try walk.next()) |item| try out.append(gpa, item);
    return out.toOwnedSlice(gpa);
}

/// The keys and values of a [`MapRange`] walk, owned.
fn mapItems(gpa: Allocator, doc: *const Document, obj: ExId, range: KeyRange) ![]itermap.OwnedMapRangeItem {
    var walk = try mapRange(doc, obj, range);
    var out: std.ArrayList(itermap.OwnedMapRangeItem) = .empty;
    errdefer {
        for (out.items) |*it| it.deinit(gpa);
        out.deinit(gpa);
    }
    while (try walk.next()) |item| try out.append(gpa, try item.intoOwned(gpa));
    return out.toOwnedSlice(gpa);
}

fn freeMapItems(gpa: Allocator, items: []itermap.OwnedMapRangeItem) void {
    for (items) |*it| it.deinit(gpa);
    gpa.free(items);
}

/// One element of a [`ListRange`] walk, as an owned string.
const ListItem = struct {
    /// Which visible element it was.
    index: usize,
    /// Its value, owned. These fixtures put strings in their lists and nothing
    /// else, so a non-string is `error.TestUnexpectedResult` and not a silent
    /// empty string — a fixture that quietly compared `""` would pass against a
    /// walk that found nothing.
    text: []u8,

    fn deinit(self: ListItem, gpa: Allocator) void {
        gpa.free(self.text);
    }
};

/// The elements of a [`ListRange`] walk over `obj`, as owned strings.
fn listItems(
    gpa: Allocator,
    doc: *const Document,
    obj: ExId,
    range: IndexRange,
) ![]ListItem {
    var walk = try listRange(doc, obj, range);
    var out: std.ArrayList(ListItem) = .empty;
    errdefer {
        for (out.items) |it| it.deinit(gpa);
        out.deinit(gpa);
    }
    while (try walk.next()) |item| {
        try out.append(gpa, .{
            .index = item.index,
            .text = try gpa.dupe(u8, switch (item.value) {
                .object => return error.TestUnexpectedResult,
                .scalar => |s| switch (s) {
                    .str => |t| t,
                    else => return error.TestUnexpectedResult,
                },
            }),
        });
    }
    return out.toOwnedSlice(gpa);
}

fn freeListItems(gpa: Allocator, items: []ListItem) void {
    for (items) |it| it.deinit(gpa);
    gpa.free(items);
}

/// A hash no document holds, made of a value rather than of zeroes so it is
/// distinguishable from [`ChangeHash.zero`].
fn missing_hash() ChangeHash {
    var h = ChangeHash.zero;
    for (&h.bytes, 0..) |*b, i| b.* = @truncate(i + 1);
    return h;
}

/// An allocator that counts `alloc` calls, so "this walk allocates nothing" is
/// a measurement rather than a claim about the source text.
///
/// **The count is of calls, not of bytes.** A walk that allocates nothing and a
/// walk that allocates one zero-length buffer are different answers, and only
/// the first is the claim.
const Counting = struct {
    /// What the counting wraps.
    inner: Allocator,
    /// How many `alloc` calls have gone through it.
    allocs: usize = 0,
    /// How many `free` calls have gone through it, so a test can show a walk's
    /// scratch came back rather than only that it was taken.
    frees: usize = 0,

    /// The allocator that counts, for a walk to be given.
    fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &counting_vtable };
    }
};

/// The four vtable slots, forwarding to [`Counting`]'s counters and then to the
/// wrapped allocator. **A container-level `const`** and not a function
/// returning `&.{ … }`, so the coercion to `*const Allocator.VTable` is the
/// compiler's to make once rather than at four call-shaped literals.
const counting_vtable: Allocator.VTable = .{
    .alloc = countingAlloc,
    .resize = countingResize,
    .remap = countingRemap,
    .free = countingFree,
};

fn countingAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Counting = @ptrCast(@alignCast(ctx));
    self.allocs += 1;
    return self.inner.rawAlloc(len, alignment, ret_addr);
}

fn countingResize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    const self: *Counting = @ptrCast(@alignCast(ctx));
    return self.inner.rawResize(memory, alignment, new_len, ret_addr);
}

fn countingRemap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    const self: *Counting = @ptrCast(@alignCast(ctx));
    return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
}

fn countingFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Counting = @ptrCast(@alignCast(ctx));
    self.frees += 1;
    self.inner.rawFree(memory, alignment, ret_addr);
}

// ── The fixture, read ───────────────────────────────────────────────────────

test "get reads values and objects by key and by index, with the id that made them" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **A scalar, and the id of the operation that put it there.**
    const hello = (try get(&doc, .root, .{ .key = "hello" })).?;
    try testing.expectEqualStrings("world", hello.value.scalar.str);
    try testing.expectEqual(OpId.init(4, 0), hello.id.opId().?);

    // **An object, and the type it is.** A make action's own id *is* the
    // object's id, so `value.object` and `id` are two answers to one question.
    const list = (try get(&doc, .root, .{ .key = "list" })).?;
    try testing.expectEqual(ObjType.list, list.value.object);
    try testing.expectEqual(list_id.opId().?, list.id.opId().?);

    const nested = (try get(&doc, map_id, .{ .key = "in_map" })).?;
    try testing.expectEqualStrings("yes", nested.value.scalar.str);
    try testing.expectEqual(OpId.init(18, 0), nested.id.opId().?);

    // **A sequence by index**, which is the other arm of upstream's dispatch
    // table ([automerge.rs:1874-1885](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    try testing.expectEqualStrings("a", (try get(&doc, list_id, .{ .index = 0 })).?.value.scalar.str);
    try testing.expectEqualStrings("b", (try get(&doc, list_id, .{ .index = 1 })).?.value.scalar.str);
    // **The fourth element was deleted**, so the list has three and index 3 is
    // past the end rather than `"d"`.
    try testing.expectEqualStrings("c", (try get(&doc, list_id, .{ .index = 2 })).?.value.scalar.str);
    try testing.expect((try get(&doc, list_id, .{ .index = 3 })) == null);

    // An index past the end of a sequence is `null`, not an error
    // ([op_set.rs:680-685](../opset/op_set.zig)), and so is a key nobody wrote.
    try testing.expect((try get(&doc, list_id, .{ .index = 9 })) == null);
    try testing.expect((try get(&doc, .root, .{ .key = "no-such-key" })) == null);
}

test "getAll answers every row of a conflicted register and one row of a clean one" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **A clean register has exactly one row**, and `getAll` and `get` agree.
    const one = try getAll(&doc, .root, .{ .key = "hello" }, gpa);
    defer gpa.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("world", one[0].value.scalar.str);

    // **A conflicted register has one row per visible value.** So put `hello`
    // twice, with no delete between: a second row in the same register, which
    // is the shape `get_all` exists to report.
    const a = try doc.putActorRef(gpa, actor_a);
    const specs = [_]OpSpec{
        .{ .ctr = 31, .key = mkey("hello"), .value = .{ .str = "again" } },
    };
    const ops = try buildOps(gpa, a, &specs);
    defer docmod.freeChangeOps(gpa, ops);
    const root_rows = try mutableOps(&doc).scopeToObj(.root);
    // **After** the register's existing row, not before it: one register's rows
    // are contiguous and ascend strictly in op id (rule **R3**,
    // [op_set.rs:1056-1057](../opset/op_set.zig)), and `31 > 4`.
    _ = try mutableOps(&doc).splice(root_rows.start + 2, ops);
    try mutableOps(&doc).rebuildIndex();
    try testing.expect(try mutableOps(&doc).validateOpOrder());

    const two = try getAll(&doc, .root, .{ .key = "hello" }, gpa);
    defer gpa.free(two);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqualStrings("world", two[0].value.scalar.str);
    try testing.expectEqualStrings("again", two[1].value.scalar.str);
    // **Ascending in op id**, which is the assertion upstream makes
    // ([automerge.rs:1921-1925](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
    // the rows come out in row order and one register's rows ascend in op id,
    // so this order is a property of the answer and not of this test.
    try testing.expect(two[0].id.order(two[1].id) == .lt);
    // And `get` picks the same winner the register's own order names.
    try testing.expectEqualStrings("again", (try get(&doc, .root, .{ .key = "hello" })).?.value.scalar.str);
}

test "objectType and length answer for a map, a list and a text, and zero for an unknown id" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    try testing.expectEqual(ObjType.map, try objectType(&doc, .root));
    try testing.expectEqual(ObjType.list, try objectType(&doc, list_id));
    try testing.expectEqual(ObjType.text, try objectType(&doc, text_id));
    try testing.expectError(error.NotAnObject, objectType(&doc, missing));

    // The root's **visible** registers: five were written and `"gone"` is
    // deleted, so four count.
    try testing.expectEqual(@as(usize, 4), try length(&doc, .root));
    // **Three of the list's four elements are visible** — `d` is deleted.
    try testing.expectEqual(@as(usize, 3), try length(&doc, list_id));
    // **A text's length is in its encoding's units, not in bytes and not in
    // characters** ([op_set.rs:439-440](../opset/op_set.zig)): three
    // single-grapheme elements, so three.
    try testing.expectEqual(@as(usize, 3), try length(&doc, text_id));
    // **Zero for an object the document does not have**, which is upstream's
    // `.unwrap_or(0)` ([automerge.rs:1711](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // and is its own arm rather than the same one.
    try testing.expectEqual(@as(usize, 0), try length(&doc, missing));
}

test "text reads a text object, and a map is not a text object" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    const s = try text(&doc, text_id, gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings("hi!", s);

    // **A map is not refused** — upstream only checks that the id names an
    // object ([automerge.rs:1719](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // — so this is a read over the map's own rows, in register order. **Three
    // of the four visible values are objects, and an object reads as U+FFFC**
    // ([`OpSet.text`](opset/op_set.zig) appends the replacement character for
    // anything that is not a string, `op_set.rs:1046-1050`), so the answer is
    // one string and three placeholders. The deleted `"gone"` contributes
    // nothing at all, which is the other half of the assertion.
    const m = try text(&doc, .root, gpa);
    defer gpa.free(m);
    try testing.expectEqualStrings("world\u{fffc}\u{fffc}\u{fffc}", m);
}

test "keys walks a map in key order and a list in element order" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    const map_keys = try keyList(gpa, &doc, .root);
    defer freeStrings(gpa, map_keys);
    // **Row order, and map registers ascend by key string** (rule **R2**,
    // [op_set.rs:1059-1060](../opset/op_set.zig)), so this is sorted order and
    // not insertion order — and the deleted `"gone"` is not in it.
    try testing.expectEqual(@as(usize, 4), map_keys.len);
    try testing.expectEqualStrings("hello", map_keys[0]);
    try testing.expectEqualStrings("list", map_keys[1]);
    try testing.expectEqualStrings("map", map_keys[2]);
    try testing.expectEqualStrings("text", map_keys[3]);

    // **A sequence's keys are its element ids rendered as strings**
    // ([read.rs:49-50](../../github-automerge-automerge/rust/automerge/src/read.rs)),
    // and in *element* order, which is not the order the strings sort in — the
    // point [iter/keys.zig:120-126](../iter/keys.zig) makes.
    const list_keys = try keyList(gpa, &doc, list_id);
    defer freeStrings(gpa, list_keys);
    try testing.expectEqual(@as(usize, 3), list_keys.len);
    try testing.expectEqualStrings("5@aaaaaaaa", list_keys[0]);
    try testing.expectEqualStrings("6@aaaaaaaa", list_keys[1]);
    try testing.expectEqualStrings("7@aaaaaaaa", list_keys[2]);
}

test "a deleted key is absent, not a key with a null value" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **The three ways to ask, and they all say absent.** The distinction is
    // the point: a reader that handed back `null_value` for a deleted key would
    // be indistinguishable from a key that was written as null.
    try testing.expect((try get(&doc, .root, .{ .key = "gone" })) == null);
    const all = try getAll(&doc, .root, .{ .key = "gone" }, gpa);
    defer gpa.free(all);
    try testing.expectEqual(@as(usize, 0), all.len);

    const map_keys = try keyList(gpa, &doc, .root);
    defer freeStrings(gpa, map_keys);
    for (map_keys) |k| try testing.expect(!std.mem.eql(u8, k, "gone"));

    const items = try mapItems(gpa, &doc, .root, .all());
    defer freeMapItems(gpa, items);
    for (items) |it| try testing.expect(!std.mem.eql(u8, it.key, "gone"));

    // **And a deleted list element is absent from `values` for the same
    // reason** — the delete named `elem_d`, so the list reads `a`, `b`, `c`
    // and not `a`, `b`, `c`, `d`.
    const vals = try valueList(gpa, &doc, list_id);
    defer gpa.free(vals);
    try testing.expectEqual(@as(usize, 3), vals.len);
    try testing.expectEqualStrings("a", vals[0].value.scalar.str);
    try testing.expectEqualStrings("b", vals[1].value.scalar.str);
    try testing.expectEqualStrings("c", vals[2].value.scalar.str);
}

test "values walks an object and resolves every value's id" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    const vals = try valueList(gpa, &doc, .root);
    defer gpa.free(vals);
    // **Four values**, one per visible register, in register order: the
    // registers are `hello`, `list`, `map`, `text`, and **three of the four
    // hold objects**, so this is the case that says a walk reports the *type*
    // of an object and not only its id.
    try testing.expectEqual(@as(usize, 4), vals.len);
    try testing.expectEqualStrings("world", vals[0].value.scalar.str);
    try testing.expectEqual(ObjType.list, vals[1].value.object);
    try testing.expectEqual(ObjType.map, vals[2].value.object);
    try testing.expectEqual(ObjType.text, vals[3].value.object);
    // **The id is the value's own when it is an object** — a make action's id
    // *is* the object's id — and the operation's id when it is a scalar.
    // **Identity, not shape.** An [`ExId`] carries the operation and, when the
    // reader had the actor table to hand, the actor's **bytes**
    // ([`types.zig`](types.zig)) — and identity is the operation alone, so the
    // comparison is [`ExId.eql`](types.zig) and not `expectEqual`.
    try testing.expect(vals[1].id.eql(list_id));
    try testing.expect(vals[3].id.eql(text_id));
    try testing.expectEqual(OpId.init(4, 0), vals[0].id.opId().?);
}

test "spans reads the text as one span per run of equal marks" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    var walk = try spans(&doc, text_id, gpa);
    defer walk.deinit();

    // **Three spans, one per grapheme**, because the mark set changes at every
    // element boundary: `{bold, code}`, then `{code, em}`, then `{code}`.
    var first = (try walk.next()).?;
    defer first.deinit(gpa);
    try testing.expectEqualStrings("h", first.asStr());
    const first_marks = first.text.marks.?;
    try testing.expectEqual(@as(usize, 2), first_marks.len());
    {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        var it = first_marks.iter();
        while (it.next()) |e| try names.append(gpa, e.name);
        try testing.expectEqualStrings("bold", names.items[0]);
        try testing.expectEqualStrings("code", names.items[1]);
    }

    var second = (try walk.next()).?;
    defer second.deinit(gpa);
    try testing.expectEqualStrings("i", second.asStr());
    const second_marks = second.text.marks.?;
    try testing.expectEqual(@as(usize, 2), second_marks.len());

    var third = (try walk.next()).?;
    defer third.deinit(gpa);
    try testing.expectEqualStrings("!", third.asStr());
    const third_marks = third.text.marks.?;
    try testing.expectEqual(@as(usize, 1), third_marks.len());

    // **And it stops.** Concatenating the three is the object's text, which is
    // what `asStr` is for ([iter/spans.zig:373-380](../iter/spans.zig)).
    try testing.expect((try walk.next()) == null);
}

test "marks reads the runs and getMarks reads a window" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    const all = try marks(&doc, text_id, gpa);
    defer gpa.free(all);
    // **Three marks, sorted by name** ([marks.zig:120-125](../src/marks.zig)):
    // `bold` over the first grapheme, `code` over the whole object, `em` over
    // the second.
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("bold", all[0].name);
    try testing.expectEqual(@as(usize, 0), all[0].start);
    try testing.expectEqual(@as(usize, 1), all[0].end);
    try testing.expectEqualStrings("code", all[1].name);
    try testing.expectEqual(@as(usize, 0), all[1].start);
    try testing.expectEqual(@as(usize, 3), all[1].end);
    try testing.expectEqualStrings("em", all[2].name);
    try testing.expectEqual(@as(usize, 1), all[2].start);
    try testing.expectEqual(@as(usize, 2), all[2].end);
    // **The values are the marks' own**, and a mark's value is read here and
    // not through `get`: `get` on a mark row answers `"markBegin"`
    // ([op.rs:1101](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    // which is upstream's constant and not the value.
    try testing.expectEqual(@as(u64, 0), all[0].value.uint);
    try testing.expectEqual(@as(u64, 7), all[1].value.uint);
    try testing.expectEqual(@as(u64, 1), all[2].value.uint);

    // **The window, and what makes it a window and not a count.** `[0, 1)`
    // holds `bold` exactly and straddles `code`, and does not reach `em`.
    // A reader that answered "the marks whose *start* is inside the window"
    // would also answer `code` here, and one that answered "the marks that
    // start before it" would answer `em`; only the intersection rule
    // (`mark.start < max and from < mark.end`) gives these two.
    const Cases = struct {
        from: usize,
        max: usize,
        want: []const []const u8,
    };
    const cases = [_]Cases{
        // **At the start.**
        .{ .from = 0, .max = 1, .want = &.{ "bold", "code" } },
        // **In the middle.**
        .{ .from = 1, .max = 2, .want = &.{ "code", "em" } },
        // **At the end**, and past it. `code` is the only mark still reaching.
        .{ .from = 2, .max = 3, .want = &.{"code"} },
        // **Past the end** reads the object's own marks and refuses nothing.
        .{ .from = 2, .max = 99, .want = &.{"code"} },
        // **The whole object.**
        .{ .from = 0, .max = 99, .want = &.{ "bold", "code", "em" } },
        // **An empty window** — `max <= from` — and one entirely past the end.
        .{ .from = 1, .max = 1, .want = &.{} },
        .{ .from = 99, .max = 200, .want = &.{} },
    };
    inline for (cases) |c| {
        const got = try getMarks(&doc, text_id, c.from, c.max, gpa);
        defer gpa.free(got);
        try testing.expectEqual(c.want.len, got.len);
        for (c.want, got) |want, m| try testing.expectEqualStrings(want, m.name);
    }

    // **A map has no marks, and that is the empty list rather than an error** —
    // upstream's `else { return Ok(Vec::new()) }` with its own compatibility
    // comment ([automerge.rs:1576-1580](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    const none = try marks(&doc, .root, gpa);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "markSetAtIndex answers the set at one index, and the heads decide which path reads it" {
    const gpa = testing.allocator;
    const enc: TextEncoding = .unicode_code_point;
    var f = try textFixture(gpa, enc, "hi!");
    defer f.deinit();
    try trans.mark(&f.doc, f.text, 0, 3, "bold", .after, .{ .bool_value = true });
    try checkPremises(&f.doc, f.text, enc);

    // **The heads from before the unmark.** The read turns them into a clock
    // it owns, so this list is only borrowed for the call.
    const heads = try f.doc.getHeads(gpa);
    defer gpa.free(heads);
    const want_bold = [_]MarkName{.{ .name = "bold", .value = .{ .bool_value = true } }};

    // **No heads is the present, and it is the indexed path.**
    // `get_scope(None)` ([`automerge.rs:806-813`](../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // hands `markSetAtScope` no clock, and `clock.is_none() && typ == Text`
    // (`:1937`) is what selects `get_marks_fast` — one prefix descent on the
    // mark index and no walk at all.
    var at_present = try markSetAtIndex(&f.doc, f.text, 1, null, gpa);
    defer at_present.deinit();
    try expectMarkSetNames(&at_present, &want_bold);

    // **The same document read at its own heads, which is the walk.** These two
    // are upstream's `assert_eq!(fast, slow, "indexed marks != walked marks")`
    // ([`:1939-1943`](../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // and the port's [`check_slow_paths`](opset/op_set.zig), and **this is the
    // only place the port reads both arms**: a heads-taking read of an
    // unisolated document is not a slower read, it is a different one, and the
    // two have to answer the same thing.
    var at_own_heads = try markSetAtIndex(&f.doc, f.text, 1, heads, gpa);
    defer at_own_heads.deinit();
    try expectMarkSetNames(&at_own_heads, &want_bold);

    // **And the third reader agrees with both**: `getMarks` is the window over
    // `marks`, which is the mark index's *runs* and not its set, so it is not
    // one of the two arms above.
    {
        const window = try getMarks(&f.doc, f.text, 1, 2, gpa);
        defer gpa.free(window);
        try testing.expectEqual(@as(usize, 1), window.len);
        try testing.expectEqualStrings("bold", window[0].name);
    }

    // **The unmark, and the two reads stop agreeing** — which is the whole
    // reason [`markSetAtIndex`] takes heads at all, and upstream's own case
    // ([`test.rs:2681-2713`](../github-automerge-automerge/rust/automerge/tests/test.rs)).
    try trans.unmark(&f.doc, f.text, 0, 3, .none, "bold", null);
    try checkPremises(&f.doc, f.text, enc);

    // **At the present it is gone**: the mark index names the present, and an
    // unmark is a tombstone rather than a mark
    // ([`automerge.rs:1965`](../github-automerge-automerge/rust/automerge/src/automerge.rs),
    // `without_unmarks`).
    var gone_at_present = try markSetAtIndex(&f.doc, f.text, 1, null, gpa);
    defer gone_at_present.deinit();
    try expectMarkSetNames(&gone_at_present, &.{});

    // **At the heads from before it, it is still `true`** — and this read is
    // `get_marks_slow` reached for the only reason upstream gives: the clock is
    // not null, so the index is not consulted
    // ([`automerge.rs:1937`](../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    var still_at_heads = try markSetAtIndex(&f.doc, f.text, 1, heads, gpa);
    defer still_at_heads.deinit();
    try expectMarkSetNames(&still_at_heads, &want_bold);

    // **An index past the end is the empty set and not an error**
    // ([`MarkSet::default()`](https://docs.rs/automerge/latest/automerge/struct.Automerge.html)),
    // **and an object with no sequence is the empty set for the same reason**
    // (`automerge.rs:1956-1958`): both are the trailing `MarkSet::default()`.
    var past_end = try markSetAtIndex(&f.doc, f.text, 99, null, gpa);
    defer past_end.deinit();
    try expectMarkSetNames(&past_end, &.{});
    var on_a_map = try markSetAtIndex(&f.doc, .root, 0, null, gpa);
    defer on_a_map.deinit();
    try expectMarkSetNames(&on_a_map, &.{});

    // **A mark over the whole object reads the same at every index in it**, and
    // one unit past it does not — the half-open rule, from the other side.
    {
        var first = try markSetAtIndex(&f.doc, f.text, 0, heads, gpa);
        defer first.deinit();
        try expectMarkSetNames(&first, &want_bold);
        var past = try markSetAtIndex(&f.doc, f.text, 3, heads, gpa);
        defer past.deinit();
        try expectMarkSetNames(&past, &.{});
    }
}

test "parents walks up to the root, and refuses a scalar's id by answering nothing" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **Two levels, innermost first** ([parents.rs:8-10](../opset/parents.zig)):
    // the text object inside the nested map, and then the map itself. Each step
    // reports the **container** and the property of the container the child
    // hangs by, so the first step's `obj` is the map and its `prop` is `"deep"`.
    var walk = try parents(&doc, deep_id);
    const first = (try walk.next()).?;
    // **Identity, not shape.** The walk's `obj` comes from
    // [`OpSet.idToExid`](opset/op_set.zig), which records the actor's bytes
    // beside the operation ([`op_set.rs:1054-1060`](../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
    // and an [`ExId`] that names the same operation either way is one value
    // ([`types.zig`](types.zig)). So the comparison is [`ExId.eql`](types.zig).
    try testing.expect(first.obj.eql(map_id));
    try testing.expectEqualStrings("deep", first.prop.key);
    try testing.expectEqual(ObjType.map, first.typ);
    const second = (try walk.next()).?;
    try testing.expectEqual(.root, second.obj);
    try testing.expectEqualStrings("map", second.prop.key);
    try testing.expect((try walk.next()) == null);

    // **An object whose container is the root has one level**, which is the
    // same walk one step shorter and not a truncated one.
    var one_deep = try parents(&doc, map_id);
    const only = (try one_deep.next()).?;
    try testing.expectEqual(.root, only.obj);
    try testing.expectEqualStrings("map", only.prop.key);
    try testing.expect((try one_deep.next()) == null);

    // **`path` is forward order** — "This is _not_ in reverse order"
    // ([parents.rs:23](../opset/parents.zig)) — so it reads root-first where
    // the walk reads innermost-first, and the root's own path is empty rather
    // than null.
    const path = try (try parents(&doc, deep_id)).path(gpa);
    defer gpa.free(path);
    try testing.expectEqual(@as(usize, 2), path.len);
    try testing.expectEqualStrings("map", path[0].prop.key);
    try testing.expectEqualStrings("deep", path[1].prop.key);
    const root_path = try (try parents(&doc, .root)).path(gpa);
    defer gpa.free(root_path);
    try testing.expectEqual(@as(usize, 0), root_path.len);

    // **The refusal.** A scalar's id *is* a row, so `parentObject` would walk up
    // from it happily; the type check is what declines, and it declines by
    // answering nothing. This is upstream's `InvalidObjId` expressed in a
    // signature with no error arm, and it is the extension upstream's own doc
    // comment anticipates and declines ([read.rs:31-34](../../github-automerge-automerge/rust/automerge/src/read.rs)).
    const put_id = (try get(&doc, .root, .{ .key = "hello" })).?.id;
    var none = try parents(&doc, put_id);
    try testing.expect((try none.next()) == null);
    try testing.expectEqual(@as(usize, 0), none.remaining());
    const no_path = try (try parents(&doc, missing)).path(gpa);
    defer gpa.free(no_path);
    try testing.expectEqual(@as(usize, 0), no_path.len);
}

// ── The ownership rules, tested ────────────────────────────────────────────

test "a map key is the document's own bytes, and a mutation does not move them" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **A key read out of the walk is the document's interned bytes**, and the
    // intern table is an arena that only grows ([doc.zig:206-212](../doc.zig)),
    // so the slice survives a mutation. This is the *stronger* of the two
    // promises [`keys`] makes, and it is the one a test can check: a promise of
    // "valid until the next mutation" cannot be checked, because nothing says
    // the mutation has to move the bytes.
    var walk = try keys(&doc, .root);
    defer walk.deinit(doc.allocator());
    const held = (try walk.next()).?;
    try testing.expectEqualStrings("hello", held);

    // **A mutation that makes the value column grow**, so it cannot be a no-op
    // on the storage.
    try mutate(gpa, &doc);

    // The held slice is still the document's own bytes and still says what it
    // said. **Asserting this is the point**: the alternative — re-reading and
    // asserting the *new* value — would pass whether or not the rule held,
    // which is [docs/STATUS.md](docs/STATUS.md)'s "a test that cannot fail is
    // not a test".
    try testing.expectEqualStrings("hello", held);

    // And the reader is right after the mutation, which is the other half.
    try testing.expectEqualStrings(
        "world",
        (try get(&doc, .root, .{ .key = "hello" })).?.value.scalar.str,
    );
    const after = (try get(&doc, .root, .{ .key = "zzz" })).?;
    try testing.expectEqualStrings(
        "a value long enough to move the raw column's block",
        after.value.scalar.str,
    );
}

test "a borrowed value is the document's, and the copy is the caller's" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **A [`DocItem`] is a value and its bytes are the document's.** The two
    // halves of the rule in one place: the struct itself needs no free, and
    // nothing in it is copied.
    const item = (try get(&doc, .root, .{ .key = "hello" })).?;
    try testing.expectEqualStrings("world", item.value.scalar.str);
    try mutate(gpa, &doc);
    // The contract is "valid until the next mutation", so the **re-read** is
    // the only thing asserted here: the earlier slice's bytes are the
    // document's, and a test that asserted on them would be pinning what the
    // mutation happens to do to the raw column rather than what this method
    // promises.
    try testing.expectEqualStrings("world", (try get(&doc, .root, .{ .key = "hello" })).?.value.scalar.str);

    // **The copy is the caller's, and it outlives the mutations.** This is the
    // shape a caller reaches for when it has to keep a value across one, and
    // it is what `intoOwned` is for ([iter/map_range.zig:265-277](../iter/map_range.zig)).
    var walk = try mapRange(&doc, .root, .{ .start = .{ .included = "hello" } });
    const raw = (try walk.next()).?;
    var owned = try raw.intoOwned(gpa);
    defer owned.deinit(gpa);
    try mutate(gpa, &doc);
    try mutate(gpa, &doc);
    try testing.expectEqualStrings("hello", owned.key);
    try testing.expectEqualStrings("world", owned.value.value.scalar.str);
}

test "a cursor taken before a mutation still names the same element after it" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **The list is `a`, `b`, `c`** before the mutation.
    try testing.expectEqual(@as(usize, 3), try length(&doc, list_id));
    const at_b = try getCursor(&doc, list_id, .{ .index = 1 }, null, gpa);
    try testing.expectEqual(@as(usize, 1), try getCursorPosition(&doc, list_id, at_b, null));
    // **A cursor is a value carrying the element's operation id and a bias**,
    // and no index anywhere in it. That is the whole point of the type.
    switch (at_b) {
        .op => |o| {
            try testing.expectEqual(@as(u64, elem_b.counter), o.ctr);
            try testing.expectEqual(Bias.after, o.move_cursor);
        },
        else => return error.TestUnexpectedResult,
    }

    // **Insert an element *before* it**, through the op set's own resolver.
    // The cursor does not move, because it does not know about indices.
    try insertIntoList(gpa, &doc, 32, 0, "first");

    // **The same cursor, asked again, and it has followed its element.**
    try testing.expectEqual(@as(usize, 4), try length(&doc, list_id));
    try testing.expectEqualStrings("first", (try get(&doc, list_id, .{ .index = 0 })).?.value.scalar.str);
    try testing.expectEqual(@as(usize, 2), try getCursorPosition(&doc, list_id, at_b, null));
    try testing.expectEqualStrings("b", (try get(&doc, list_id, .{ .index = 2 })).?.value.scalar.str);

    // **And the cursor's own actor bytes survived the mutation**, which is the
    // second half of the value claim: the document's arena owns the actor
    // table ([doc.zig:91-92](../doc.zig)) and adding a row does not move it.
    switch (at_b) {
        .op => |o| try testing.expectEqualStrings("aaaaaaaa", o.actor.bytes),
        else => return error.TestUnexpectedResult,
    }
}

test "a cursor with a bias moves the way the bias says when its element is deleted" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **Two cursors on the same element, one per bias**, taken while the list
    // is `a`, `b`, `c`.
    const after = try getCursorMoving(&doc, list_id, .{ .index = 1 }, null, .after, gpa);
    const before = try getCursorMoving(&doc, list_id, .{ .index = 1 }, null, .before, gpa);

    // **Delete the element both cursors name**, with a visible element on
    // *each* side of the hole — that is the state in which the two biases are
    // not the same answer, and it is the state upstream's two arms were written
    // for.
    try deleteElem(gpa, &doc, elem_b, OpId.init(33, 0));
    try testing.expect(try mutableOps(&doc).validateOpOrder());
    try testing.expectEqual(@as(usize, 2), try length(&doc, list_id));
    try testing.expectEqualStrings("a", (try get(&doc, list_id, .{ .index = 0 })).?.value.scalar.str);
    try testing.expectEqualStrings("c", (try get(&doc, list_id, .{ .index = 1 })).?.value.scalar.str);

    // **`.after` answers the index the element *would* have had** — the next
    // visible element's index, here `c` at 1
    // ([automerge.rs:1789-1794](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // — **and `.before` walks back to the nearest element still visible**, here
    // `a` at 0 (`:1795-1803`). **The two differ, and that difference is the
    // whole of the bias.**
    try testing.expectEqual(@as(usize, 1), try getCursorPosition(&doc, list_id, after, null));
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc, list_id, before, null));

    // **Take the element on the `.after` side away too**, and `.after` answers
    // the sequence's **length** — upstream's third case, "or `sequence.length`
    // if none of the next items are visible" (`:1793`) — while `.before` is
    // unmoved, because what it walks back to has not changed.
    try deleteElem(gpa, &doc, elem_c, OpId.init(34, 0));
    try testing.expectEqual(@as(usize, 1), try length(&doc, list_id));
    try testing.expectEqual(@as(usize, 1), try getCursorPosition(&doc, list_id, after, null));
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc, list_id, before, null));
}

test "a start and an end cursor are the ends, and a bias does not touch them" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **`Cursor::Start => Ok(0)` and `Cursor::End => Ok(length)`**
    // ([automerge.rs:1767-1768](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and both come back from `getCursor` without a seek (`:1744-1745`), so
    // neither can fail on an index.
    const start = try getCursor(&doc, list_id, .start, null, gpa);
    const end = try getCursor(&doc, list_id, .end, null, gpa);
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc, list_id, start, null));
    try testing.expectEqual(@as(usize, 3), try getCursorPosition(&doc, list_id, end, null));

    // **A bias is ignored for them**, which is upstream's own sentence: the
    // start and end positions can never be removed
    // ([read.rs:221](../../github-automerge-automerge/rust/automerge/src/read.rs)).
    const end_before = try getCursorMoving(&doc, list_id, .end, null, .before, gpa);
    const end_after = try getCursorMoving(&doc, list_id, .end, null, .after, gpa);
    try testing.expectEqual(@as(usize, 3), try getCursorPosition(&doc, list_id, end_before, null));
    try testing.expectEqual(@as(usize, 3), try getCursorPosition(&doc, list_id, end_after, null));
}

// ── The range readers ──────────────────────────────────────────────────────

test "mapRange reads a key range at the start, in the middle, at the end and past the end" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // The root's visible keys, in order: `hello`, `list`, `map`, `text`. The
    // row range is upstream's `match` over the two bounds
    // ([`OpSet.mapRange`](opset/op_set.zig), `op_set.rs:406-416`), so every
    // case below is read off the register table rather than off intuition.
    //
    // **`through` and `between` differ by one register, and nothing else.**
    // Both take the same two keys; `through` ends at the register's `.end` and
    // `between` at its `.start` (`op_set.rs:414` against `:415`). A pair of
    // cases over the *same* two keys is therefore the sharpest thing here: an
    // implementation that resolved every end the same way passes the interior
    // cases of either and fails the pair.
    const Cases = struct {
        range: KeyRange,
        want: []const []const u8,
    };
    const cases = [_]Cases{
        // **The whole object**, and the two unbounded arms together.
        .{ .range = .all(), .want = &.{ "hello", "list", "map", "text" } },
        // **At the start.** The unbounded end is the object's end, so this is
        // everything from `hello` on.
        .{ .range = .{ .start = .{ .included = "hello" } }, .want = &.{ "hello", "list", "map", "text" } },
        // **Two keys**, and the smallest closed range there is.
        .{ .range = .through("hello", "list"), .want = &.{ "hello", "list" } },
        // **The same two keys, half-open**, so `list` drops out. This is the
        // case a both-inclusive reader cannot pass.
        .{ .range = .between("hello", "list"), .want = &.{"hello"} },
        // **In the middle.** From `list` to `text` is three of the four.
        .{ .range = .through("list", "text"), .want = &.{ "list", "map", "text" } },
        .{ .range = .between("list", "text"), .want = &.{ "list", "map" } },
        // **One key**, which is a range whose two bounds name the same key —
        // and the two arms disagree about it, which is the whole point.
        .{ .range = .through("map", "map"), .want = &.{"map"} },
        .{ .range = .between("map", "map"), .want = &.{} },
        // **At the end**, and the unbounded start arm.
        .{ .range = .{ .start = .{ .included = "text" } }, .want = &.{"text"} },
        .{ .range = .through(null, "map"), .want = &.{ "hello", "list", "map" } },
        // **`end` past the last key is the end**, and the same is true of the
        // last key itself when the range is half-open: an absent key reads as
        // "past the end" and the present one as a register to stop before.
        .{ .range = .through("map", "zzz"), .want = &.{ "map", "text" } },
        .{ .range = .between("map", "zzz"), .want = &.{ "map", "text" } },
        // **Past the end.** A `start` that sorts above every register empties
        // the range, because that is where it would be inserted
        // ([`OpSet.propRange`](opset/op_set.zig), `column.rs:958-1000`).
        .{ .range = .{ .start = .{ .included = "zzz" } }, .want = &.{} },
        // **An absent key bounds the range where it sorts**, which is
        // upstream's descent's answer for a value the column does not hold.
        // `"aaa"` sorts below every key this object holds, so it bounds at the
        // object's **head**: the closed range is everything up to `map` and
        // the half-open one drops `map` too. Before that answer was fixed an
        // absent key answered the object's *end*, so both of these read empty
        // — right for a key past the last register, which is the one case that
        // needs no answer, and wrong for every other absent key.
        .{ .range = .through("aaa", "map"), .want = &.{ "hello", "list", "map" } },
        .{ .range = .between("aaa", "map"), .want = &.{ "hello", "list" } },
        // **An absent key in the middle**, where the object holds a register
        // on either side of where it would sort. `through` and `between` are
        // the **same** range here and that is the whole claim: an absent key's
        // register is `at..at`, so `.start` and `.end` are one row
        // (`column.rs:971`), while a *present* key's differ by the register.
        // A reader that answered the object's end for an absent key passes
        // every case above this one and fails here.
        .{ .range = .through("hello", "mzz"), .want = &.{ "hello", "list", "map" } },
        .{ .range = .between("hello", "mzz"), .want = &.{ "hello", "list", "map" } },
        // **A start at or past its end** is empty rather than a refusal, and
        // here the two cross: an `end` that sorts below the `start`, which is
        // the `@max` in [`OpSet.mapRange`](opset/op_set.zig).
        .{ .range = .through("map", "aaa"), .want = &.{} },
        .{ .range = .between("map", "aaa"), .want = &.{} },
        // **An excluded start skips the register it names**, so `excluded`
        // and `included` over the same key differ by that one register.
        .{ .range = .between(null, "text"), .want = &.{ "hello", "list", "map" } },
        .{ .range = .{ .start = .{ .excluded = "list" } }, .want = &.{ "map", "text" } },
        .{ .range = .{ .start = .{ .excluded = "map" } }, .want = &.{"text"} },
    };
    inline for (cases) |c| {
        const got = try mapItems(gpa, &doc, .root, c.range);
        defer freeMapItems(gpa, got);
        try testing.expectEqual(c.want.len, got.len);
        for (c.want, got) |want, it| try testing.expectEqualStrings(want, it.key);
    }
}

test "a half-open key range is the shape the C binding builds, and the two failing C cases are its boundaries" {
    const gpa = testing.allocator;
    var doc = try rootMap(gpa, &c_map_specs);
    defer doc.deinit();

    // **The premise**: the document reads `a`, `b`, `c`, `d` and nothing else,
    // and `a` is 8 — the state the C case leaves it in. A range that returned
    // the right keys off the wrong document would be a coincidence, so the
    // whole-object read is asserted before any range is.
    {
        const got = try mapItems(gpa, &doc, .root, .all());
        defer freeMapItems(gpa, got);
        const want = [_][]const u8{ "a", "b", "c", "d" };
        try testing.expectEqual(want.len, got.len);
        for (want, got) |key, it| try testing.expectEqualStrings(key, it.key);
    }

    // **`test_range_iter_map`'s `["b"-"d")`**
    // ([`automerge-c/test/map_tests.c:270-303`](../../github-automerge-automerge/rust/automerge-c/test/map_tests.c)):
    // two items, `b` and `c`, and then nothing. **A both-inclusive end returns
    // `b`, `c` *and* `d`**, which is three — the assertion the C suite makes
    // and the one this port failed.
    {
        const got = try mapItems(gpa, &doc, .root, .between("b", "d"));
        defer freeMapItems(gpa, got);
        const want = [_][]const u8{ "b", "c" };
        try testing.expectEqual(want.len, got.len);
        for (want, got) |key, it| try testing.expectEqualStrings(key, it.key);
    }

    // **`test_get_range_values`'s partial current map range** (`:1430-1433`):
    // `["aa"-"dd")` over four keys is **three** items, not four. The keys here
    // are one byte each rather than two, which is the same range over the same
    // shape, and it is the same assertion: the start is in, the end is out.
    {
        const got = try mapItems(gpa, &doc, .root, .between("a", "d"));
        defer freeMapItems(gpa, got);
        const want = [_][]const u8{ "a", "b", "c" };
        try testing.expectEqual(want.len, got.len);
        for (want, got) |key, it| try testing.expectEqualStrings(key, it.key);
    }

    // **The four boundaries, named as the C header names them** — `end` is
    // "the key one past the last key in a subrange"
    // ([`automerge-c/src/doc/map.rs:482-483`](../../github-automerge-automerge/rust/automerge-c/src/doc/map.rs)).
    const Boundaries = struct {
        range: KeyRange,
        want: []const []const u8,
        what: []const u8,
    };
    const cases = [_]Boundaries{
        // **`begin == end` gives nothing.** A half-open range over zero keys
        // is empty; a reader that added one would answer `d` here.
        .{ .range = .between("d", "d"), .want = &.{}, .what = "begin == end" },
        // **`begin > end` gives nothing.** The C binding refuses this outright
        // with `Invalid range` (`map.rs:521-523`), so the reader is never
        // asked — but the range type is, by a Zig caller, and the answer is
        // empty rather than a reversed walk.
        .{ .range = .between("d", "a"), .want = &.{}, .what = "begin > end" },
        // **`end - 1` gives the last element**: with `end` at `d`, the range
        // stops after `c`.
        .{ .range = .between("a", "d"), .want = &.{ "a", "b", "c" }, .what = "end - 1" },
        // **and `end` itself is not in it**, which is the same case read the
        // other way: `end` at `c` stops after `b`.
        .{ .range = .between("a", "c"), .want = &.{ "a", "b" }, .what = "end" },
    };
    for (cases) |c| {
        const got = try mapItems(gpa, &doc, .root, c.range);
        defer freeMapItems(gpa, got);
        testing.expectEqual(c.want.len, got.len) catch |e| {
            std.debug.print("boundary `{s}`: wanted {d} keys, got {d}\n", .{
                c.what, c.want.len, got.len,
            });
            return e;
        };
        for (c.want, got) |key, it| try testing.expectEqualStrings(key, it.key);
    }

    // **A `start` only, and an `end` only**, which is the C suite's other two
    // `AMmapRange` calls (`map_tests.c:306` and `:354`): `"b"..` is three
    // keys and `.."d"` is three, and the second of them is a range whose
    // *end* is exclusive with no start at all.
    {
        const got = try mapItems(gpa, &doc, .root, .between("b", null));
        defer freeMapItems(gpa, got);
        const want = [_][]const u8{ "b", "c", "d" };
        try testing.expectEqual(want.len, got.len);
        for (want, got) |key, it| try testing.expectEqualStrings(key, it.key);
    }
    {
        const got = try mapItems(gpa, &doc, .root, .between(null, "d"));
        defer freeMapItems(gpa, got);
        const want = [_][]const u8{ "a", "b", "c" };
        try testing.expectEqual(want.len, got.len);
        for (want, got) |key, it| try testing.expectEqualStrings(key, it.key);
    }
}

test "listRange reads a half-open index range at the start, in the middle, at the end and past the end" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // The list reads `a`, `b`, `c`, so the middle is not the start.
    const Cases = struct {
        range: IndexRange,
        want: []const []const u8,
    };
    const cases = [_]Cases{
        // **The whole object.**
        .{ .range = .all(), .want = &.{ "a", "b", "c" } },
        // **At the start.**
        .{ .range = .{ .start = 0, .end = 1 }, .want = &.{"a"} },
        // **In the middle.**
        .{ .range = .{ .start = 1, .end = 2 }, .want = &.{"b"} },
        // **At the end**, and the unbounded end arm.
        .{ .range = .{ .start = 2 }, .want = &.{"c"} },
        .{ .range = .{ .end = 2 }, .want = &.{ "a", "b" } },
        // **Past the end.** The filter is after the walk, so a range that
        // starts past the end still walks every row and answers nothing
        // ([iter/list_range.zig:740-746](../iter/list_range.zig)).
        .{ .range = .{ .start = 5 }, .want = &.{} },
        .{ .range = .{ .start = 1, .end = 1 }, .want = &.{} },
        // **Past the end as the bound** is the object's end, not a refusal:
        // `end` is one past the last index the reader answers, so `99` and
        // `null` are the same answer here.
        .{ .range = .{ .start = 0, .end = 99 }, .want = &.{ "a", "b", "c" } },
        .{ .range = .{ .end = 3 }, .want = &.{ "a", "b", "c" } },
    };
    inline for (cases) |c| {
        const got = try listItems(gpa, &doc, list_id, c.range);
        defer freeListItems(gpa, got);
        try testing.expectEqual(c.want.len, got.len);
        for (c.want, got) |want, it| try testing.expectEqualStrings(want, it.text);
    }
}

test "a list and an unknown id are empty map ranges, and a map reads as a one-element sequence" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **A list yields an empty map range**, which is upstream's documented
    // behaviour ("If the object correspoding to `obj` is a list then this will
    // return an empty iterator",
    // [read.rs:80-81](../../github-automerge-automerge/rust/automerge/src/read.rs))
    // and its `.unwrap_or_default()` (`:1682-1685`).
    const of_list = try mapItems(gpa, &doc, list_id, .all());
    defer freeMapItems(gpa, of_list);
    try testing.expectEqual(@as(usize, 0), of_list.len);

    // **And so does an id that names no object.**
    const of_nothing = try mapItems(gpa, &doc, missing, .all());
    defer freeMapItems(gpa, of_nothing);
    try testing.expectEqual(@as(usize, 0), of_nothing.len);

    // **And a map is not refused by `listRange` either — it is read as a
    // sequence of its visible rows, with their values.** Upstream builds the
    // same reader over the same rows
    // ([automerge.rs:1693-1697](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and a map's rows carry no `insert` flag, so the walk counts each of them
    // as an element and hands out the map's values. **The indexes it reports
    // are positions in that reading, and its values are the objects** — which
    // is the answer, and it is why the helper above refuses a non-string
    // rather than quietly substituting an empty one.
    var over_map = try listRange(&doc, .root, .all());
    var seen: usize = 0;
    while (try over_map.next()) |item| {
        try testing.expectEqual(seen, item.index);
        try testing.expect(item.value.isObject());
        seen += 1;
    }
    // **One, not four.** A map's rows all carry `insert = false`, and the
    // reader counts **distinct positions in the insert prefix column** — the
    // same `dedup` that is the list arm of [`OpSet.seqLength`](opset/op_set.zig)
    // (`op_set.rs:451-456`). Nothing ever advances that prefix, so there is
    // exactly one position and the map reads as a one-element sequence at
    // index 0. **That is the faithful answer** — not a refusal, and not a
    // truncation.
    try testing.expectEqual(@as(usize, 1), seen);
}

// ── The empty document, and a target that is not an object ─────────────────

test "an empty document answers every method rather than trapping" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, .auto);
    defer doc.deinit();

    // **The premise**: a document with no changes, no rows and no actors.
    try testing.expect(doc.isEmpty());
    try testing.expectEqual(@as(usize, 0), doc.len());
    try testing.expectEqual(@as(u64, 0), stats(&doc).num_ops);
    try testing.expectEqual(@as(u64, 0), stats(&doc).num_changes);
    try testing.expectEqual(TextEncoding.unicode_code_point, textEncoding(&doc));

    // The root exists and is a map, and it is empty.
    try testing.expectEqual(ObjType.map, try objectType(&doc, .root));
    try testing.expectEqual(@as(usize, 0), try length(&doc, .root));
    try testing.expect((try get(&doc, .root, .{ .key = "anything" })) == null);

    const all = try getAll(&doc, .root, .{ .key = "anything" }, gpa);
    defer gpa.free(all);
    try testing.expectEqual(@as(usize, 0), all.len);

    const t = try text(&doc, .root, gpa);
    defer gpa.free(t);
    try testing.expectEqualStrings("", t);

    var k = try keys(&doc, .root);
    defer k.deinit(doc.allocator());
    try testing.expect((try k.next()) == null);

    var term: ValueTerm = undefined;
    var v = try values(&doc, .root, &term);
    defer term.deinit(doc.allocator());
    try testing.expect((try v.next()) == null);

    var sp = try spans(&doc, .root, gpa);
    defer sp.deinit();
    try testing.expect((try sp.next()) == null);

    const m = try marks(&doc, .root, gpa);
    defer gpa.free(m);
    try testing.expectEqual(@as(usize, 0), m.len);
    const gm = try getMarks(&doc, .root, 0, 10, gpa);
    defer gpa.free(gm);
    try testing.expectEqual(@as(usize, 0), gm.len);

    var p = try parents(&doc, .root);
    try testing.expect((try p.next()) == null);
    const path = try p.path(gpa);
    defer gpa.free(path);
    try testing.expectEqual(@as(usize, 0), path.len);

    // **An empty document's mirror is an empty map**: the root exists, so
    // `exid_to_obj` answers and the walk yields nothing
    // ([`hydrate.rs`](hydrate.zig):250-257). It is not a refusal and not a
    // trap, and saying so here is what keeps it from becoming one.
    var mirror = try hydrate(&doc, .root, null, gpa);
    defer mirror.deinit();
    try testing.expectEqual(@as(usize, 0), (try mirrorMap(&mirror)).count());

    // **A cursor at an index on the *root* is `error.InvalidOp`**, not
    // `InvalidIndex`: the root is a map, a map has no cursor position at all
    // ([automerge.rs:1740-1742](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and that check runs **before** the seek, so it is the arm that fires.
    // `InvalidIndex` — upstream's `Err(AutomergeError::InvalidIndex(i))` for a
    // register with no rows (`:1753-1754`) — needs a sequence to be
    // unreachable, and the refusal test on the sample fixture is where that is
    // checked. Both are defined answers and neither traps.
    try testing.expectError(error.InvalidOp, getCursor(&doc, .root, .{ .index = 0 }, null, gpa));
    // **`.start` and `.end` are answers on a *sequence*, not on a map.**
    // `get_cursor_for` resolves the object and its sequence type **before** it
    // looks at the position ([automerge.rs:1739-1745](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // so a map refuses both: `error.InvalidOp` at `:1740-1742` fires before the
    // `CursorPosition::Start => Ok(Cursor::Start)` arm at `:1744` is reached.
    // The end cursors on a *list* are in the test below, where there is a
    // sequence to resolve.
    try testing.expectError(error.InvalidOp, getCursor(&doc, .root, .start, null, gpa));
    try testing.expectError(error.InvalidOp, getCursor(&doc, .root, .end, null, gpa));

    var mr = try mapRange(&doc, .root, .all());
    try testing.expect((try mr.next()) == null);
    var lr = try listRange(&doc, .root, .all());
    try testing.expect((try lr.next()) == null);

    // **The change graph is empty, so a change is absent and a head is
    // missing.** Both are `Option`s upstream
    // ([read.rs:305,302](../../github-automerge-automerge/rust/automerge/src/read.rs)).
    try testing.expect((try getChangeByHash(&doc, ChangeHash.zero, gpa)) == null);
    const missing_deps = try getMissingDeps(&doc, &.{ChangeHash.zero}, gpa);
    defer gpa.free(missing_deps);
    try testing.expectEqual(@as(usize, 1), missing_deps.len);
    try testing.expect(missing_deps[0].eql(ChangeHash.zero));
}

test "a target that is not an object is a defined refusal, and a map has no cursor" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **`error.NotAnObject`**, which is upstream's `InvalidObjId` with a payload
    // this error set does not carry
    // ([automerge.rs:2286](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    // Each of these would have been a wrong answer — a value, an empty walk, a
    // panic — without the check.
    try testing.expectError(error.NotAnObject, objectType(&doc, missing));
    try testing.expectError(error.NotAnObject, get(&doc, missing, .{ .key = "x" }));
    try testing.expectError(error.NotAnObject, getAll(&doc, missing, .{ .key = "x" }, gpa));
    try testing.expectError(error.NotAnObject, text(&doc, missing, gpa));
    try testing.expectError(error.NotAnObject, spans(&doc, missing, gpa));
    try testing.expectError(error.NotAnObject, getCursor(&doc, missing, .start, null, gpa));
    try testing.expectError(error.NotAnObject, hydrate(&doc, missing, null, gpa));
    // **`.start` answers before the object is looked at** — upstream's
    // `Cursor::Start => Ok(0)` is the first arm of
    // `get_cursor_position_for`
    // ([automerge.rs:1766-1768](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // and the `exid_to_obj` refusal is the third (`:1770`). **So a `.start`
    // cursor is `0` even for an id that names nothing**, and this is the
    // faithful answer rather than a missing check; the `.op` case is where
    // `NotAnObject` actually comes from, and the refusal test below uses one.
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc, missing, .start, null));
    const bad: Cursor = .{ .op = cursormod.OpCursor.init(
        ElemId.fromOpId(missing.opId().?),
        0,
        .after,
        actor_a,
    ) };
    try testing.expectError(error.NotAnObject, getCursorPosition(&doc, missing, bad, null));

    // **A scalar's id is a row and is still not an object**: `get` hands it
    // back, and every reader that wants an object refuses it.
    const put_id = (try get(&doc, .root, .{ .key = "hello" })).?.id;
    try testing.expectError(error.NotAnObject, objectType(&doc, put_id));
    try testing.expectError(error.NotAnObject, get(&doc, put_id, .{ .key = "x" }));
    // **And `hydrate` refuses a scalar's id the same way**, because it is the
    // same `exid_to_obj` ([`automerge.rs:1643`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    try testing.expectError(error.NotAnObject, hydrate(&doc, put_id, null, gpa));
    // **And `parents` refuses it by answering nothing** rather than walking up
    // from the row.
    var p = try parents(&doc, put_id);
    try testing.expect((try p.next()) == null);

    // **`error.InvalidOp`**: a property the object does not have. A map key
    // asked of a list, an index asked of a map
    // ([automerge.rs:1886](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    try testing.expectError(error.InvalidOp, get(&doc, list_id, .{ .key = "hello" }));
    try testing.expectError(error.InvalidOp, get(&doc, .root, .{ .index = 0 }));
    try testing.expectError(error.InvalidOp, getAll(&doc, list_id, .{ .key = "hello" }, gpa));
    try testing.expectError(error.InvalidOp, getAll(&doc, .root, .{ .index = 0 }, gpa));

    // **A map has no cursor position at all**, and **the two methods refuse it
    // in upstream's own order, which is not the same order.**
    // `getCursor` resolves the object and its sequence type *first*
    // ([automerge.rs:1740-1742](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // so it is `error.InvalidOp` for every position including `.start`;
    // `getCursorPosition` answers `Cursor::Start => Ok(0)` **first** (`:1767`)
    // and only reaches the `as_sequence_type` refusal at `:1772-1774` for an
    // `.op` cursor. **The disagreement is upstream's**, and the port keeps it
    // rather than smoothing it into one rule.
    try testing.expectError(error.InvalidOp, getCursor(&doc, .root, .start, null, gpa));
    try testing.expectError(error.InvalidOp, getCursor(&doc, .root, .{ .index = 0 }, null, gpa));
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc, .root, .start, null));
    const on_a_map: Cursor = .{ .op = cursormod.OpCursor.init(
        ElemId.fromOpId(OpId.init(4, 0)),
        0,
        .after,
        actor_a,
    ) };
    try testing.expectError(error.InvalidCursor, getCursorPosition(&doc, .root, on_a_map, null));

    // **An index at or past the end of a sequence is `error.InvalidIndex`**
    // (`:1753-1754`).
    try testing.expectError(error.InvalidIndex, getCursor(&doc, list_id, .{ .index = 3 }, null, gpa));
    try testing.expectError(error.InvalidIndex, getCursor(&doc, list_id, .{ .index = 99 }, null, gpa));

    // **A cursor whose element is not in this object** — the root's `hello`
    // register's id asked of the list — is **`error.InvalidCursor`, which is
    // upstream's name for it.** Upstream's `seek_list_opid` answers an `Option`
    // and `get_cursor_position_for` turns the empty answer into its own
    // refusal, `.ok_or_else(|| AutomergeError::InvalidCursor(cursor.clone()))`
    // (`:1778-1781`); **the port's [`OpSet.seekListOpid`](opset/op_set.zig) is
    // fallible for the same question and raises `error.InvalidIndex` when the
    // row the id names is outside the object's range**
    // ([op_set.zig:3145](../opset/op_set.zig)), so the refusal arrived under
    // the wrong name.** [`getCursorPosition`] now puts upstream's name back,
    // and this is the expectation that changed with it — **not** a
    // transcription fix and not a second source of truth about which rows an
    // object has: the op set still decides, and the reader only names what it
    // decided.
    //
    // **It also closes an inconsistency inside the port.** With a clock the
    // seek takes the slow arm alone ([`seekListOpid`](opset/op_set.zig):3093),
    // which answers `null` and already refused with `InvalidCursor`; without
    // one the fast arm's range check ran first and refused with
    // `InvalidIndex`. **The same cursor and the same object refused under two
    // names depending only on whether a clock was in play**, and upstream has
    // one name because it has one question and one `None`. The second half of
    // that claim is a test of its own: the historical suite's `getCursorPosition
    // reads the position as those heads saw it` reads both spellings.
    const elsewhere: Cursor = .{ .op = cursormod.OpCursor.init(
        ElemId.fromOpId(put_id.opId().?),
        0,
        .after,
        actor_a,
    ) };
    try testing.expectError(error.InvalidCursor, getCursorPosition(&doc, list_id, elsewhere, null));
}

// ── Changes ────────────────────────────────────────────────────────────────

test "getChangeByHash answers null for a hash the document does not hold" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    // **The premise**: the sample was spliced, so the graph is empty and no
    // hash is held. That is a fixture property and it is the reason this test
    // can say what it says.
    try testing.expectEqual(@as(usize, 0), stats(&doc).num_changes);

    // **Absent is `null` and not an error** — that is upstream's `Option`
    // ([read.rs:305](../../github-automerge-automerge/rust/automerge/src/read.rs)).
    // The alternative would be an error for a question a sync peer asks about
    // every hash it has.
    try testing.expect((try getChangeByHash(&doc, ChangeHash.zero, gpa)) == null);
    try testing.expect((try getChangeByHash(&doc, missing_hash(), gpa)) == null);
}

test "getMissingDeps answers the hashes the document lacks, and none of the ones it holds" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, .auto);
    defer doc.deinit();

    // **Two empty commits, so the graph has two nodes and the second depends
    // on the first** ([automerge.rs:693-697](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    // This is the document-layer API, and it is the only way a read-only
    // fixture can have a change graph at all.
    const first = try doc.emptyCommit(gpa, null, null);
    const second = try doc.emptyCommit(gpa, null, null);
    try testing.expect(!first.eql(second));
    try testing.expectEqual(@as(u64, 2), stats(&doc).num_changes);

    // **A hash the document holds is not missing**, and neither is anything
    // behind it — which is the whole of the walk
    // ([automerge.rs:2052-2054](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    const held = try getMissingDeps(&doc, &.{second}, gpa);
    defer gpa.free(held);
    try testing.expectEqual(@as(usize, 0), held.len);

    const also_held = try getMissingDeps(&doc, &.{ first, second }, gpa);
    defer gpa.free(also_held);
    try testing.expectEqual(@as(usize, 0), also_held.len);

    // **A hash it does not hold is missing**, and the answer is **sorted and
    // deduplicated** (`:2063-2065`).
    const absent = missing_hash();
    const one = try getMissingDeps(&doc, &.{absent}, gpa);
    defer gpa.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expect(one[0].eql(absent));

    // **A repeated hash is one answer**, and a head the document holds
    // alongside it does not appear.
    const both = try getMissingDeps(&doc, &.{ absent, absent, second }, gpa);
    defer gpa.free(both);
    try testing.expectEqual(@as(usize, 1), both.len);
    try testing.expect(both[0].eql(absent));
}

// ── The allocators ─────────────────────────────────────────────────────────

test "constructing a walk allocates nothing, and the walks that allocate are freed with the document's allocator" {
    const gpa = testing.allocator;
    var doc = try sample(gpa);
    defer doc.deinit();

    var counting = Counting{ .inner = gpa };
    const counted = counting.allocator();

    // **The three that allocate nothing, measured.** Each of these is four
    // column cursors, a skipper and a lookahead over storage the op set already
    // holds ([iter/map_range.zig:835-836](../iter/map_range.zig),
    // [iter/list_range.zig:714-715](../iter/list_range.zig),
    // [opset/parents.zig:295-302](../opset/parents.zig)), and a reader that
    // allocated would be a reader whose iterator is a heap object — which
    // [plan §3](../../docs/plan.md) says is not one.
    counting.allocs = 0;
    var mr = try mapRange(&doc, .root, .all());
    try testing.expectEqual(@as(usize, 0), counting.allocs);
    var lr = try listRange(&doc, list_id, .all());
    try testing.expectEqual(@as(usize, 0), counting.allocs);
    var p = try parents(&doc, map_id);
    try testing.expectEqual(@as(usize, 0), counting.allocs);
    // **And the walks still answer**, which is what makes the count above about
    // a walk and not about a walk that never started.
    try testing.expect((try mr.next()) != null);
    try testing.expect((try lr.next()) != null);
    try testing.expect((try p.next()) != null);

    // **The two that do allocate, measured through the *document's* allocator.**
    // A winner walk needs scratch, and the scratch comes out of the op set's own
    // allocator ([`OpSet.topOps`](opset/op_set.zig), whose `topScratch` takes
    // `self.gpa`) — **not** out of one a caller passes, which is why the
    // counting wrapper has to be the *document's* allocator to see them at all.
    // That is the finding, not a workaround: a caller cannot fund a
    // `Keys`/`Values` walk, and `Keys.deinit(doc.allocator())` /
    // `ValueTerm.deinit(doc.allocator())` are the only frees that match.
    var counted_doc = try sample(counted);
    defer counted_doc.deinit();

    counting.allocs = 0;
    var k = try keys(&counted_doc, .root);
    const after_keys = counting.allocs;
    try testing.expect(after_keys > 0);
    _ = try k.next();
    const frees_before = counting.frees;
    k.deinit(counted_doc.allocator());
    // **And the scratch came back**, which is the half a count alone would not
    // say: the walk's allocations were freed, not just taken.
    try testing.expect(counting.frees > frees_before);

    counting.allocs = 0;
    var term: ValueTerm = undefined;
    var v = try values(&counted_doc, .root, &term);
    try testing.expect(counting.allocs > 0);
    _ = try v.next();
    const frees_before_v = counting.frees;
    term.deinit(counted_doc.allocator());
    try testing.expect(counting.frees > frees_before_v);

    // `spans` is the third, and it is *given* the allocator rather than taking
    // the document's, so it is freed with no argument at all
    // ([`Spans.deinit`](iter/spans.zig)). **It allocates on the first `next`,
    // not on construction** — the fold's own buffers are built lazily — so the
    // count is read after the read, and the doc on [`Spans`] says
    // "Constructing one allocates nothing" and is right.
    counting.allocs = 0;
    var sp = try spans(&doc, text_id, counted);
    try testing.expectEqual(@as(usize, 0), counting.allocs);
    var span = (try sp.next()).?;
    try testing.expect(counting.allocs > 0);
    span.deinit(counted);
    sp.deinit();
}

test "every allocating method frees cleanly, and the document outlives them all" {
    const gpa = testing.allocator;
    // **`testing.allocator` is the arbiter**: a leak or a double free fails at
    // the end of this test rather than somewhere above it.
    var doc = try sample(gpa);
    defer doc.deinit();

    // **One of everything, in one scope**, so a method whose result is not
    // freed shows up as a leak here.
    {
        const item = (try get(&doc, .root, .{ .key = "hello" })).?;
        try testing.expectEqualStrings("world", item.value.scalar.str);
        gpa.free(try getAll(&doc, .root, .{ .key = "hello" }, gpa));
        gpa.free(try text(&doc, text_id, gpa));
        gpa.free(try marks(&doc, text_id, gpa));
        gpa.free(try getMarks(&doc, text_id, 0, 3, gpa));
        gpa.free(try getMissingDeps(&doc, &.{}, gpa));
        gpa.free(try getMissingDeps(&doc, &.{missing_hash()}, gpa));
        // **The deepest allocation this file makes is a mirror** — the whole
        // tree under the object, owned — so it is freed by the same rule as
        // every line above it, on all three container types.
        var mirror = try hydrate(&doc, .root, null, gpa);
        mirror.deinit();
        mirror = try hydrate(&doc, list_id, null, gpa);
        mirror.deinit();
        mirror = try hydrate(&doc, text_id, null, gpa);
        mirror.deinit();
        if (try getChangeByHash(&doc, ChangeHash.zero, gpa)) |maybe_built| {
            var built = maybe_built;
            built.deinit(gpa);
        }
        _ = try getCursor(&doc, list_id, .{ .index = 0 }, null, gpa);
        _ = try getCursorMoving(&doc, list_id, .{ .index = 1 }, null, .before, gpa);
        _ = try getCursorPosition(&doc, list_id, try getCursor(&doc, list_id, .start, null, gpa), null);
        freeMapItems(gpa, try mapItems(gpa, &doc, .root, .all()));
        freeListItems(gpa, try listItems(gpa, &doc, list_id, .all()));
        gpa.free(try valueList(gpa, &doc, .root));
        freeStrings(gpa, try keyList(gpa, &doc, .root));
        gpa.free(try (try parents(&doc, map_id)).path(gpa));
        _ = try length(&doc, list_id);
        _ = try objectType(&doc, .root);
        _ = stats(&doc);
        _ = textEncoding(&doc);
    }

    // **The document is still sound after all of it**, which is the half a leak
    // check alone would not say.
    const still = try text(&doc, text_id, gpa);
    defer gpa.free(still);
    try testing.expectEqualStrings("hi!", still);
}

// ── The upstream text and text-encoding suites ──────────────────────────────
//
// Ported case for case from
// `$AUTOMERGE_REF/rust/automerge/tests/text_encoding.rs` and
// `$AUTOMERGE_REF/rust/automerge/tests/text.rs`. **Every one of them runs
// under all four encodings**, which is the whole subject of
// `text_encoding.rs`: a text index has to name the same element whichever of
// the four units it is counted in (`text_encoding.rs`:34-46).

/// The write surface. This file's own tests build documents by hand and only
/// read them; the upstream text tests write and then read, and
/// [`transact`]'s free functions are upstream's `AutoCommit` — one call opens
/// a transaction and commits it, which is what `AutoCommit` does with every
/// method ([`doc.zig`](../doc.zig)'s `Mode`, and `automerge.rs`:307-317).
const trans = @import("transact.zig");

/// The four encodings, in the order `tests/text_encoding.rs` names them
/// (`text_encoding.rs`:50-55) and in the order its `Scenario` loops over them
/// (`:124-133`).
const all_encodings = [_]TextEncoding{
    .unicode_code_point,
    .utf8_code_unit,
    .utf16_code_unit,
    .grapheme_cluster,
};

/// The encodings in which a block marker is **one position wide**, which is
/// what makes a model written in ASCII-plus-`\n` a model of the document.
///
/// **Three of the four, and the fourth is the odd one for a reason that is
/// about U+FFFC rather than about indexes.** `seq_length` measures anything
/// that is not a string as `width("\u{fffc}")` (`op_set.rs:443-447`), and
/// U+FFFC is **three bytes** in UTF-8, so under `utf8_code_unit` a block marker
/// occupies three positions while the model's `\n` occupies one. The
/// reference, asked directly, agrees: its own block probe reports
/// `after split at 3: length=7` under code points and `length=11` for the same
/// shape under UTF-8 code units.
///
/// Upstream's own generated-scenario test never has to choose, because it runs
/// under `AutoCommit::new()` — one encoding — and that encoding is
/// `UnicodeCodePoint` in a default build (`TextEncoding::platform_default`,
/// `text_value.rs:12-22`). See the diff block at the bottom of this file.
const one_wide_block_encodings = [_]TextEncoding{
    .unicode_code_point,
    .utf16_code_unit,
    .grapheme_cluster,
};

/// One index per encoding.
///
/// **Upstream writes the same four-way `match` inline in every one of its
/// fourteen closing actions** (`text_encoding.rs`:203-208, `:222-227`,
/// `:253-258`, `:281-286`, `:305-310`, `:329-334`, `:348-353`, `:367-372`,
/// `:386-391`, `:414-419`, `:461-466`, `:507-512`, `:552-557`, `:596-601`).
/// A table is that same choice written once, and it puts the four numbers side
/// by side where a reviewer can check them against each other — which is the
/// only reason to be sure they are four spellings of one position.
const EncIdx = struct {
    unicode_code_point: usize,
    utf8_code_unit: usize,
    utf16_code_unit: usize,
    grapheme_cluster: usize,

    fn pick(self: EncIdx, enc: TextEncoding) usize {
        return switch (enc) {
            .unicode_code_point => self.unicode_code_point,
            .utf8_code_unit => self.utf8_code_unit,
            .utf16_code_unit => self.utf16_code_unit,
            .grapheme_cluster => self.grapheme_cluster,
        };
    }
};

/// One string per encoding, the same shape as [`EncIdx`] for the cases where
/// an index names a character and the character is not the same one in all
/// four.
const EncStr = struct {
    unicode_code_point: []const u8,
    utf8_code_unit: []const u8,
    utf16_code_unit: []const u8,
    grapheme_cluster: []const u8,

    fn pick(self: EncStr, enc: TextEncoding) []const u8 {
        return switch (enc) {
            .unicode_code_point => self.unicode_code_point,
            .utf8_code_unit => self.utf8_code_unit,
            .utf16_code_unit => self.utf16_code_unit,
            .grapheme_cluster => self.grapheme_cluster,
        };
    }
};

/// A document with one text object on the root and `body` spliced into it, and
/// its premises asserted.
///
/// This is upstream's `Scenario::run_with_encoding` and nothing more
/// (`text_encoding.rs`:133-139): a fresh document in the given encoding, a
/// text object at `"text"`, and one splice of the scenario's text.
const TextDoc = struct {
    doc: Document,
    text: ExId,

    fn deinit(self: *TextDoc) void {
        self.doc.deinit();
        self.* = undefined;
    }
};

fn textFixture(gpa: Allocator, encoding: TextEncoding, body: []const u8) !TextDoc {
    var doc = try Document.initWithEncoding(gpa, encoding, .auto);
    errdefer doc.deinit();
    // **A named actor, because a random one would make a failure
    // unreproducible.** Upstream draws one (`automerge.rs`:307-317); the
    // port's `Document.init` draws none at all (`doc.zig`:2194-2199), so
    // naming one here is what makes every fixture below deterministic.
    doc.setActorId(.{ .bytes = "aaaaaaaa" });
    const obj = try trans.putObject(&doc, .root, .{ .key = "text" }, .text);
    try trans.spliceText(&doc, obj, 0, 0, body);
    try checkPremises(&doc, obj, encoding);
    return .{ .doc = doc, .text = obj };
}

/// The premises every conclusion in this section rests on: the rows are in the
/// order the op set's own rules demand, the top index agrees with them, the
/// object index knows the two objects the fixture names, and the document is
/// measuring text in the encoding it was asked for.
///
/// **Checked before every conclusion, and again after every mutation.** A
/// fixture whose rows are out of order reads back plausibly wrong rather than
/// wrongly, and `validateOpOrder` is the only thing that says so — a mark
/// fixture that is one row out of order is green and meaningless.
fn checkPremises(doc: *const Document, obj: ExId, encoding: TextEncoding) !void {
    if (!try mutableOps(doc).validateOpOrder()) {
        std.debug.print(
            "encoding {s}: the rows no longer follow the row-order invariant (op_set.rs:167-175)\n",
            .{@tagName(encoding)},
        );
        return error.TestExpectedEqual;
    }
    if (try mutableOps(doc).validateTopIndex()) |fault| {
        std.debug.print("encoding {s}: the top index disagrees with the rows: {any}\n", .{
            @tagName(encoding),
            fault,
        });
        return error.TestExpectedEqual;
    }
    try testing.expectEqual(ObjType.map, try doc.objectType(.root));
    try testing.expectEqual(ObjType.text, try doc.objectType(obj));
    try testing.expectEqual(encoding, doc.textEncoding());
}

fn expectText(got: []const u8, want: []const u8, enc: TextEncoding) !void {
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("encoding {s}: read \"{s}\", want \"{s}\"\n", .{
            @tagName(enc),
            got,
            want,
        });
        return error.TestExpectedEqual;
    }
}

fn expectLen(got: usize, want: usize, enc: TextEncoding) !void {
    if (got != want) {
        std.debug.print("encoding {s}: read {d} units, want {d}\n", .{
            @tagName(enc),
            got,
            want,
        });
        return error.TestExpectedEqual;
    }
}

/// Every element of `obj`, compared with `want` one element at a time.
///
/// **Element by element and not on the joined string**, because the string is
/// *derived* from the elements: two characters where the model wants one, or
/// one where it wants two, read back the same bytes. The length is checked
/// first so a document that gained or lost an element is named as such rather
/// than as a wrong character, and then each index is read on its own through
/// [`get`] — which is the one reader here that addresses a single element
/// rather than a run of them.
///
/// **A block marker in `want` is not a string and so fails here**, and that is
/// the right answer for this helper: nothing in this section writes one.
/// Upstream's `splice_text` inserts the characters it is handed and does
/// **not** turn a `'\n'` into one ([`inner.rs:1473-1512`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs));
/// only `split_block` makes a block, and the test above pins that.
fn expectChars(
    doc: *const Document,
    obj: ExId,
    want: []const []const u8,
    enc: TextEncoding,
) !void {
    const got_len = try length(doc, obj);
    if (got_len != want.len) {
        std.debug.print("encoding {s}: {d} elements, want {d}\n", .{
            @tagName(enc),
            got_len,
            want.len,
        });
        return error.TestExpectedEqual;
    }
    for (want, 0..) |w, i| try expectCharAt(doc, obj, i, w, enc);
}

/// Asserts that `index` is where `want` starts, so an index a test hard-codes
/// is checked against the text rather than trusted.
///
/// **Only for an index upstream means to be on a character boundary.** A test
/// that deliberately indexes inside a character (the cursor case, the patch
/// cases, the multi-byte case) does not call this, because the answer there is
/// whatever the encoding's rounding rule says and not the character.
fn expectCharAt(
    doc: *const Document,
    obj: ExId,
    index: usize,
    want: []const u8,
    enc: TextEncoding,
) !void {
    const item = (try get(doc, obj, .{ .index = index })) orelse {
        std.debug.print("encoding {s}: nothing at index {d}\n", .{ @tagName(enc), index });
        return error.TestUnexpectedResult;
    };
    switch (item.value) {
        .scalar => |s| switch (s) {
            .str => |t| return expectText(t, want, enc),
            else => {},
        },
        .object => {},
    }
    std.debug.print("encoding {s}: index {d} does not hold a string\n", .{
        @tagName(enc),
        index,
    });
    return error.TestUnexpectedResult;
}

/// Asserts that `got` is exactly `want`, by name, by range and by value, in
/// the order the mark fold emits them (**by name** — [`marks`]'s own
/// contract, `marks.zig`:120-125).
fn expectMarkRuns(got: []const Mark, want: []const Mark, enc: TextEncoding) !void {
    if (got.len != want.len) {
        std.debug.print("encoding {s}: read {d} mark run(s), want {d}\n", .{
            @tagName(enc),
            got.len,
            want.len,
        });
        for (got) |m| std.debug.print("  got:  {s} [{}, {d})\n", .{ m.name, m.start, m.end });
        for (want) |m| std.debug.print("  want: {s} [{}, {d})\n", .{ m.name, m.start, m.end });
        return error.TestExpectedEqual;
    }
    for (got, want) |g, w| {
        if (!std.mem.eql(u8, g.name, w.name) or g.start != w.start or g.end != w.end or
            !g.value.eql(w.value))
        {
            std.debug.print("encoding {s}: got {s} [{}, {d}) = {any}, want {s} [{}, {d}) = {any}\n", .{
                @tagName(enc),
                g.name,
                g.start,
                g.end,
                g.value,
                w.name,
                w.start,
                w.end,
                w.value,
            });
            return error.TestExpectedEqual;
        }
    }
}

/// A mark's name and value, with no range — **upstream's `MarkSet`**, which is
/// a set of `(name, value)` pairs at one index and carries no range at all
/// (`marks.rs`:48-52, `read.rs`:168-173).
const MarkName = struct {
    name: []const u8,
    value: ScalarValue,
};

/// Asserts that `got` is exactly `want` **by name and value and nothing
/// else**, which is what a single-index read is upstream.
fn expectMarkNames(got: []const Mark, want: []const MarkName, enc: TextEncoding) !void {
    if (got.len != want.len) {
        std.debug.print("encoding {s}: read {d} mark(s), want {d}\n", .{
            @tagName(enc),
            got.len,
            want.len,
        });
        for (got) |m| std.debug.print("  got:  {s} = {any}\n", .{ m.name, m.value });
        for (want) |m| std.debug.print("  want: {s} = {any}\n", .{ m.name, m.value });
        return error.TestExpectedEqual;
    }
    for (got, want) |g, w| {
        if (!std.mem.eql(u8, g.name, w.name) or !g.value.eql(w.value)) {
            std.debug.print("encoding {s}: got {s} = {any}, want {s} = {any}\n", .{
                @tagName(enc),
                g.name,
                g.value,
                w.name,
                w.value,
            });
            return error.TestExpectedEqual;
        }
    }
}

/// Asserts that a [`MarkSet`] is exactly `want`, **by name and value and
/// nothing else**, which is what upstream's `MarkSet` is
/// ([`marks.rs`:48-52](../src/marks.zig), [`read.rs`:168-173](../../github-automerge-automerge/rust/automerge/src/read.rs)).
///
/// **The set's own order, which is name order and is checked rather than
/// sorted** ([`marks.zig:355-363`](../src/marks.zig)): the entries are a flat
/// array kept in that order, so two sets built by two different paths — the
/// mark index's and the row walk's — have to come out in the same order or
/// they are not the same set.
fn expectMarkSetNames(set: *const MarkSet, want: []const MarkName) !void {
    if (set.len() != want.len) {
        std.debug.print("read {d} mark name(s), want {d}\n", .{ set.len(), want.len });
        var dump = set.iter();
        while (dump.next()) |entry| {
            std.debug.print("  got:  {s} = {any}\n", .{ entry.name, entry.value });
        }
        for (want) |w| std.debug.print("  want: {s} = {any}\n", .{ w.name, w.value });
        return error.TestExpectedEqual;
    }
    var it = set.iter();
    for (want) |w| {
        const entry = it.next() orelse return error.TestExpectedResult;
        if (!std.mem.eql(u8, entry.name, w.name) or !entry.value.eql(w.value)) {
            std.debug.print("got {s} = {any}, want {s} = {any}\n", .{
                entry.name,
                entry.value,
                w.name,
                w.value,
            });
            return error.TestExpectedEqual;
        }
    }
}

/// One span of a text object, as this section needs to see it: whether it is a
/// block, its text, and whether it carries any mark at all.
const Shape = struct {
    block: bool = false,
    text: []const u8 = "",
    marked: bool = false,
};

/// Every span of `obj`, collected, with each span's own bytes copied out so the
/// walk can be freed before the shapes are read.
fn readShapes(gpa: Allocator, doc: *const Document, obj: ExId) ![]Shape {
    var walk = try spans(doc, obj, gpa);
    defer walk.deinit();
    var out: std.ArrayList(Shape) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s.text);
        out.deinit(gpa);
    }
    while (try walk.next()) |span| {
        switch (span) {
            .block => try out.append(gpa, .{ .block = true }),
            .text => |t| {
                const bytes = try gpa.dupe(u8, t.text);
                // **The mark set is read and dropped, not freed field by
                // field.** [`spans`]'s contract is that each span is the
                // caller's and [`Span.deinit`](../iter/spans.zig) frees the
                // text and the set together, and the set's names are the
                // document's.
                const marked = t.marks != null;
                var owned: iterspans.Span = span;
                owned.deinit(gpa);
                try out.append(gpa, .{ .text = bytes, .marked = marked });
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

fn freeShapes(gpa: Allocator, list: []Shape) void {
    for (list) |s| gpa.free(s.text);
    gpa.free(list);
}

/// Prints every shape, so a failure names the spans the port produced rather
/// than only the index that was wrong.
fn showShapes(shapes: []const Shape) void {
    for (shapes, 0..) |s, i| {
        std.debug.print("  span {d}: block={} marked={} \"{s}\"\n", .{
            i,
            s.block,
            s.marked,
            s.text,
        });
    }
}

/// Upstream's `marks_are_consolidated` (`tests/text.rs`:712-728): **no two
/// adjacent text spans carry the same marks**, and a block resets the
/// comparison.
///
/// **The three states, not a boolean.** `last_marks` is an
/// `Option<&Option<MarkSet>>`, so "no previous text span" and "a previous text
/// span with no marks" are different, and a first unmarked span must not
/// compare equal to the start. `?bool` with a null for "the last thing was a
/// block" is the same three states.
fn marksAreConsolidated(shapes: []const Shape) bool {
    var last: ?bool = null;
    for (shapes) |s| {
        if (s.block) {
            last = null;
            continue;
        }
        if (last) |prev| {
            if (prev == s.marked) return false;
        }
        last = s.marked;
    }
    return true;
}

// ── tests/text_encoding.rs ─────────────────────────────────────────────────

test "text_encoding: length counts one text four ways (text_encoding.rs:183-196)" {
    const gpa = testing.allocator;
    // 👩‍👩‍👧‍👦 is U+1F469 U+200D U+1F467 U+1F466: one grapheme cluster, seven
    // code points, eleven UTF-16 code units, twenty-five UTF-8 code units
    // (text_encoding.rs:169-181). "hello" is five of each.
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "hello👩‍👩‍👧‍👦");
        defer f.deinit();
        const want: usize = switch (enc) {
            .unicode_code_point => 12,
            .utf8_code_unit => 30,
            .utf16_code_unit => 16,
            .grapheme_cluster => 6,
        };
        try expectLen(try length(&f.doc, f.text), want, enc);
        // **The text is one string under all four**, so the four lengths are
        // four measures of it and not four different documents.
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "hello👩‍👩‍👧‍👦", enc);
    }
}

test "text_encoding: spliceText inserts at the same place in each encoding (text_encoding.rs:198-216)" {
    const gpa = testing.allocator;
    // **All four indexes are the `w` of "world"**, which is the position the
    // expectation "…👩‍👩‍👧‍👦 beautiful world" names.
    const index_of = EncIdx{
        .unicode_code_point = 14,
        .utf8_code_unit = 32,
        .utf16_code_unit = 18,
        .grapheme_cluster = 8,
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "hello 👩‍👩‍👧‍👦 world");
        defer f.deinit();
        const index = index_of.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "w", enc);

        try trans.spliceText(&f.doc, f.text, index, 0, "beautiful ");
        try checkPremises(&f.doc, f.text, enc);
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "hello 👩‍👩‍👧‍👦 beautiful world", enc);
    }
}

test "text_encoding: a mark written in each encoding reads back over the same span (text_encoding.rs:218-245)" {
    const gpa = testing.allocator;
    // **The four lengths of one text**: "he", the seven code points of
    // 👩‍👩‍👧‍👦, and "llo" — 12 code points, 30 UTF-8 bytes, 16 UTF-16 units,
    // 6 grapheme clusters.
    const len = EncIdx{
        .unicode_code_point = 12,
        .utf8_code_unit = 30,
        .utf16_code_unit = 16,
        .grapheme_cluster = 6,
    };
    // **The four `end_index`es are not the same position**, and upstream does
    // not claim they are: 11 is the `o`, one before the end, and 27, 13 and 4
    // are all the *first* `l` of `"llo"`. What they share is the **start**,
    // which upstream writes as a literal `1` and which is the `e` in every
    // one of them — so the mark starts in the same place and only its end
    // moves with the encoding.
    const end = EncIdx{
        .unicode_code_point = 11,
        .utf8_code_unit = 27,
        .utf16_code_unit = 13,
        .grapheme_cluster = 4,
    };
    const end_char = EncStr{
        .unicode_code_point = "o",
        .utf8_code_unit = "l",
        .utf16_code_unit = "l",
        .grapheme_cluster = "l",
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        try expectCharAt(&f.doc, f.text, 1, "e", enc);
        const last = end.pick(enc);
        try expectLen(try length(&f.doc, f.text), len.pick(enc), enc);
        try expectCharAt(&f.doc, f.text, last, end_char.pick(enc), enc);

        try trans.mark(&f.doc, f.text, 1, last, "bold", .both, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);
        const got = try marks(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectMarkRuns(got, &.{.{
            .start = 1,
            .end = last,
            .name = "bold",
            .value = .{ .bool_value = true },
        }}, enc);
    }
}

test "text_encoding: unmark removes the run a mark wrote, in each encoding (text_encoding.rs:247-271)" {
    const gpa = testing.allocator;
    const len = EncIdx{
        .unicode_code_point = 12,
        .utf8_code_unit = 30,
        .utf16_code_unit = 16,
        .grapheme_cluster = 6,
    };
    const end = EncIdx{
        .unicode_code_point = 11,
        .utf8_code_unit = 27,
        .utf16_code_unit = 13,
        .grapheme_cluster = 4,
    };
    const end_char = EncStr{
        .unicode_code_point = "o",
        .utf8_code_unit = "l",
        .utf16_code_unit = "l",
        .grapheme_cluster = "l",
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const last = end.pick(enc);
        try expectLen(try length(&f.doc, f.text), len.pick(enc), enc);
        try expectCharAt(&f.doc, f.text, last, end_char.pick(enc), enc);
        try trans.mark(&f.doc, f.text, 1, last, "bold", .both, .{ .bool_value = true });
        // **The mark is there before the unmark removes it**, or an unmark of
        // nothing would pass this test.
        const before = try marks(&f.doc, f.text, gpa);
        defer gpa.free(before);
        try expectMarkRuns(before, &.{.{
            .start = 1,
            .end = last,
            .name = "bold",
            .value = .{ .bool_value = true },
        }}, enc);

        // **`null` is the unmark.** Upstream's `unmark` takes no value at all
        // (`transactable.rs`:91-101) and the port's `value: ?ScalarValue` is
        // the same choice written down: "null is upstream's
        // `Mark::new(name, ScalarValue::Null, ..)`" (transact.zig:936).
        try trans.unmark(&f.doc, f.text, 1, last, .both, "bold", null);
        try checkPremises(&f.doc, f.text, enc);
        const after = try marks(&f.doc, f.text, gpa);
        defer gpa.free(after);
        try expectMarkRuns(after, &.{}, enc);
    }
}

test "text_encoding: a cursor taken before an insert still names the same character after it (text_encoding.rs:273-298)" {
    const gpa = testing.allocator;
    // **A cursor created before a remote edit must resolve to the right
    // position after it.** The cursor is taken at the first `l` of
    // "he👩‍👩‍👧‍👦llo" and a whole extra family emoji is spliced in *before* it;
    // the cursor's element is the `l` and its index has moved by the width of
    // what was inserted.
    const index_of = EncIdx{
        .unicode_code_point = 9,
        .utf8_code_unit = 27,
        .utf16_code_unit = 13,
        .grapheme_cluster = 3,
    };
    // **The same four numbers after the insert**: 9 + 7, 27 + 25, 13 + 11,
    // 3 + 1.
    const moved = EncIdx{
        .unicode_code_point = 16,
        .utf8_code_unit = 52,
        .utf16_code_unit = 24,
        .grapheme_cluster = 4,
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const index = index_of.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);

        const cursor = try getCursor(&f.doc, f.text, .{ .index = index }, null, gpa);
        // **Where the cursor is before the edit**, so a cursor that simply
        // answered `index` would be caught here and not only after.
        try expectLen(try getCursorPosition(&f.doc, f.text, cursor, null), index, enc);

        // **Index 2 is where the emoji starts in all four encodings**, so the
        // insert lands before the cursor's `l`. The element there is one code
        // point except under the grapheme encoding, where `spliceText` writes
        // one operation per cluster (transact.zig:2138-2140) and the whole
        // 👩‍👩‍👧‍👦 is the element. UTF-16 is *not* the grapheme encoding: its
        // operations are still one code point each, and they are merely two
        // units wide.
        const first_unit = switch (enc) {
            .unicode_code_point, .utf8_code_unit, .utf16_code_unit => "👩",
            .grapheme_cluster => "👩‍👩‍👧‍👦",
        };
        try expectCharAt(&f.doc, f.text, 2, first_unit, enc);
        try trans.spliceText(&f.doc, f.text, 2, 0, "👩‍👩‍👧‍👦");
        try checkPremises(&f.doc, f.text, enc);

        try expectLen(try getCursorPosition(&f.doc, f.text, cursor, null), moved.pick(enc), enc);
        // **And the text is the one the moved index names.**
        try expectCharAt(&f.doc, f.text, moved.pick(enc), "l", enc);
    }
}

test "text_encoding: get reads the character each encoding's index names (text_encoding.rs:300-322)" {
    const gpa = testing.allocator;
    const index_of = EncIdx{
        .unicode_code_point = 9,
        .utf8_code_unit = 27,
        .utf16_code_unit = 13,
        .grapheme_cluster = 3,
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦lo");
        defer f.deinit();
        const index = index_of.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);
        const item = (try get(&f.doc, f.text, .{ .index = index })) orelse
            return error.TestUnexpectedResult;
        switch (item.value) {
            .scalar => |s| switch (s) {
                .str => |t| try expectText(t, "l", enc),
                else => return error.TestUnexpectedResult,
            },
            .object => return error.TestUnexpectedResult,
        }
    }
}

test "text_encoding: put replaces the element each encoding's index names (text_encoding.rs:324-341)" {
    const gpa = testing.allocator;
    const index_of = EncIdx{
        .unicode_code_point = 9,
        .utf8_code_unit = 27,
        .utf16_code_unit = 13,
        .grapheme_cluster = 3,
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const index = index_of.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);

        _ = try trans.put(&f.doc, f.text, .{ .index = index }, .{ .str = "L" });
        try checkPremises(&f.doc, f.text, enc);
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "he👩‍👩‍👧‍👦Llo", enc);
    }
}

test "text_encoding: insert puts a character before the one each encoding's index names (text_encoding.rs:343-360)" {
    const gpa = testing.allocator;
    const index_of = EncIdx{
        .unicode_code_point = 9,
        .utf8_code_unit = 27,
        .utf16_code_unit = 13,
        .grapheme_cluster = 3,
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const index = index_of.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);

        _ = try trans.insert(&f.doc, f.text, index, .{ .str = "L" });
        try checkPremises(&f.doc, f.text, enc);
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "he👩‍👩‍👧‍👦Lllo", enc);
    }
}

test "text_encoding: delete removes the character each encoding's index names (text_encoding.rs:362-379)" {
    const gpa = testing.allocator;
    const index_of = EncIdx{
        .unicode_code_point = 9,
        .utf8_code_unit = 27,
        .utf16_code_unit = 13,
        .grapheme_cluster = 3,
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const index = index_of.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);

        _ = try trans.delete(&f.doc, f.text, .{ .index = index });
        try checkPremises(&f.doc, f.text, enc);
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "he👩‍👩‍👧‍👦lo", enc);
    }
}

test "text_encoding: splitBlock cuts at the place each encoding's index names (text_encoding.rs:381-407)" {
    const gpa = testing.allocator;
    const index_of = EncIdx{
        .unicode_code_point = 9,
        .utf8_code_unit = 27,
        .utf16_code_unit = 13,
        .grapheme_cluster = 3,
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const index = index_of.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);

        _ = try trans.splitBlock(&f.doc, f.text, index);
        try checkPremises(&f.doc, f.text, enc);

        // **Three spans, and the block sits between the two halves**: a block
        // marker is a row in the sequence, so it splits the text into what is
        // before it and what is after it. Upstream filters the block out and
        // keeps the two text spans (`text_encoding.rs`:393-403); the block is
        // asserted here too, because "a block that vanished" and "a block that
        // is there and was filtered" are different documents.
        const shapes = try readShapes(gpa, &f.doc, f.text);
        defer freeShapes(gpa, shapes);
        try testing.expectEqual(@as(usize, 3), shapes.len);
        try expectText(shapes[0].text, "he👩‍👩‍👧‍👦", enc);
        try testing.expect(shapes[1].block);
        try expectText(shapes[2].text, "llo", enc);
    }
}

// ── tests/text.rs ──────────────────────────────────────────────────────────

/// A character boundary: how many `enc` units precede it, and where it is in
/// the bytes. **Both halves, because the rule needs both** — the round is
/// stated in units and the splice is in bytes.
const Boundary = struct {
    units: usize,
    at: usize,
};

/// The first character boundary at or after `pos` units.
///
/// This is upstream's rounding rule, which its own comments state twice: "Deleting
/// in the middle of the multibyte character 🐻 at index 4 (according to utf16
/// offsets) should delete the following character" (`tests/text.rs`:934-937)
/// and "deleting in the middle of a multi-byte character will delete after"
/// (`:1009`, `:1015`). A position already on a boundary is its own ceiling.
fn ceilToBoundary(enc: TextEncoding, bytes: []const u8, pos: usize) !Boundary {
    var units: usize = 0;
    var off: usize = 0;
    while (off < bytes.len) {
        if (units >= pos) return .{ .units = units, .at = off };
        // **One code point at a time, not the rest of the buffer**: a width
        // is measured per character and `encoding.width` on a slice measures
        // all of it.
        const seq = std.unicode.utf8ByteSequenceLength(bytes[off]) catch
            return error.TestUnexpectedResult;
        const wide = @min(seq, bytes.len - off);
        const w = enc.width(bytes[off .. off + wide]);
        if (w == 0) return error.TestUnexpectedResult;
        units += w;
        off += wide;
    }
    return .{ .units = units, .at = off };
}

/// One element of `bytes`, in the document's own units and in bytes.
const Element = struct {
    start_units: usize,
    width: usize,
    start: usize,
    end: usize,
};

/// The element that holds unit `cursor`, or null past the end — upstream's
/// `seek_ops_by_index` returning an empty `ops` and the delete loop breaking
/// on it (`inner.rs`:762-770).
///
/// **One code point per element, and that is what the document has here.** The
/// only text this is used on is a run of 🐻, which is one code point and one
/// grapheme cluster in every encoding, so "element" and "code point" are the
/// same thing. Under the grapheme encoding `spliceText` writes one operation
/// per cluster (transact.zig:2138-2140) and this walk would need to cluster
/// too; under the other three it writes one per code point, and a code point
/// is one element in each of them however many units it is wide.
fn elementAt(enc: TextEncoding, bytes: []const u8, cursor: usize) !?Element {
    var units: usize = 0;
    var off: usize = 0;
    while (off < bytes.len) {
        const seq = std.unicode.utf8ByteSequenceLength(bytes[off]) catch
            return error.TestUnexpectedResult;
        const wide = @min(seq, bytes.len - off);
        const w = enc.width(bytes[off .. off + wide]);
        if (w == 0) return error.TestUnexpectedResult;
        if (cursor < units + w) {
            return Element{
                .start_units = units,
                .width = w,
                .start = off,
                .end = off + wide,
            };
        }
        units += w;
        off += wide;
    }
    return null;
}

/// The text `before` reads as after `spliceText(text, pos, del, ins)`, by
/// upstream's algorithm rather than by a table of answers.
///
/// The rule is three steps, and each is upstream's own line:
///
/// 1. **The insert index rounds up to the end of the element that contains
///    it.** `query_insert_at` returns the width accumulated over the elements
///    it consumed ([`InsertQuery.resolve`](insert.rs):131-134, :149), so a
///    target inside a character comes back as that character's end — and
///    `index = query.index` before anything is written (`inner.rs`:695-700).
/// 2. **The new text goes there**, and `delete_index = index +
///    inserted_width` (`inner.rs`:757): the delete starts *after* what was
///    inserted, not at the caller's index.
/// 3. **The delete takes whole elements until it has taken `del` units.**
///    `deleted += step` where `step` is the element's width
///    (`inner.rs`:766-768, :789), so `del` is a budget in units and an element
///    is never half-deleted. A cursor that lands inside an element is moved
///    to that element's end and **nothing is counted** — "if we delete in the
///    middle of a multi-character move cursor to the next character"
///    (`inner.rs`:772-777).
///
/// **Why a rule and not a table.** Upstream pins one encoding and three
/// literal strings (`tests/text.rs`:929-940). Under `utf16_code_unit` this
/// must reproduce those three exactly, and that is asserted. Under the other
/// three the same three numbers land somewhere else — index 2 is inside the
/// first 🐻 in both UTF-16 and UTF-8, and on a boundary in code points and
/// graphemes — so the answer is legitimately different, and this is what says
/// which.
fn splicedText(
    gpa: Allocator,
    enc: TextEncoding,
    before: []const u8,
    pos: usize,
    del: usize,
    ins: []const u8,
) ![]u8 {
    // **Step 1: the insert index rounds up to the end of the element that
    // contains it** (`insert.rs`:131-134, :149 against `inner.rs`:695-700).
    const anchor = try ceilToBoundary(enc, before, pos);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, before[0..anchor.at]);
    try out.appendSlice(gpa, ins);
    // **The rest of `before` is still there.** The insert goes *between* two
    // elements and everything after the anchor shifts along; dropping the tail
    // would delete the whole rest of the text and every answer would be a
    // truncation of it.
    try out.appendSlice(gpa, before[anchor.at..]);
    if (del == 0) return out.toOwnedSlice(gpa);

    // **After the insert, not at it** (`inner.rs`:757).
    var cursor = anchor.units + enc.width(ins);
    var deleted: usize = 0;
    while (deleted < del) {
        const found = (try elementAt(enc, out.items, cursor)) orelse break;
        const next_before_removal = found.start_units + found.width;
        if (found.start_units < cursor) {
            // **Round up and count nothing** (`inner.rs`:774-777).
            cursor = next_before_removal;
            continue;
        }
        // **`len` is a count, not an end index.** `replaceRangeAssumeCapacity`
        // computes `self.items[start + len ..]`, so handing it `found.end` —
        // an absolute offset — asks it to skip `start + end` bytes when only
        // `end - start` are being removed. It survived because the two agree
        // whenever `found.start` is 0, which is the first element of a
        // one-element deletion; every later element in a multi-character
        // delete overran the buffer and **panicked, taking the whole test
        // binary down with it** (a slice with `start > end` is a panic, and
        // this file's readers must be total over their input).
        out.replaceRangeAssumeCapacity(found.start, found.end - found.start, &.{});
        deleted += found.width;
        // **The removal shifts everything after it down by its own width**,
        // so the next element is now at `found.start_units`.
        cursor = found.start_units;
    }
    return out.toOwnedSlice(gpa);
}

/// One mark operation, as [`modelCovering`] reads it.
const MarkOp = struct {
    name: []const u8,
    start: usize,
    end: usize,
    value: ScalarValue,
};

/// A `(name, value)` pair, in name order.
const Pair = struct {
    name: []const u8,
    value: ScalarValue,
};

/// The marks that cover `index`, read from the operations themselves.
///
/// **The third source upstream does not need, and this port does.** Upstream's
/// `get_marks_agrees_with_marks_at_every_index` (`tests/text.rs`:1044-1088)
/// compares two *independent* readers: `get_marks` is a seek plus a walk of
/// the mark state at one index (`read.rs`:168-173), and `marks` is the
/// whole-object fold (`read.rs`:155). This port has one reader and a filter —
/// [`getMarks`] is literally [`marks`] restricted to a window
/// (read.zig:759-779) — so comparing the two proves nothing and is the kind
/// of test [AGENTS.md](AGENTS.md) says to delete rather than fix.
///
/// The model is the operations the test applied, read by their own rules:
///
/// * a mark covers the half-open range `[start, end)`;
/// * two operations on one name are both active where they overlap and **the
///   later one wins**, because the rows are in document order and the fold
///   reads them in that order ([`Op.step`](opset/op.zig)'s R3,
///   `op.rs`:1056-1057);
/// * an operation whose value is `null` is a tombstone: it removes the name
///   there rather than setting it ([`marks`], `marks.zig`:273-279;
///   `op_set.rs`:1023).
fn modelCovering(gpa: Allocator, ops: []const MarkOp, index: usize) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    errdefer out.deinit(gpa);
    for (ops) |op| {
        if (op.start > index or index >= op.end) continue;
        // **A tombstone replaces the value, it does not join the set.** The
        // later operation wins whatever its value is, and a `null` winner
        // means the name is not there — which is the whole of
        // `MarkAccumulator.intoIterNoUnmark` (`marks.zig`:273-279) and
        // `op_set.rs:1023`.
        var replaced = false;
        for (out.items) |*p| {
            if (std.mem.eql(u8, p.name, op.name)) {
                p.value = op.value;
                replaced = true;
                break;
            }
        }
        if (!replaced) try out.append(gpa, .{ .name = op.name, .value = op.value });
    }
    // **Then the tombstones are dropped**, so a name the last operation
    // removed is absent rather than present with a null value.
    var keep: usize = 0;
    for (out.items) |p| {
        if (p.value == .null_value) continue;
        out.items[keep] = p;
        keep += 1;
    }
    out.shrinkRetainingCapacity(keep);
    std.mem.sort(Pair, out.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// The `(name, value)` pairs a window read reports, in name order, so it can
/// be compared with [`modelCovering`].
fn readPairs(gpa: Allocator, ms: []const Mark) ![]Pair {
    const out = try gpa.alloc(Pair, ms.len);
    for (ms, 0..) |m, i| out[i] = .{ .name = m.name, .value = m.value };
    std.mem.sort(Pair, out, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out;
}

fn expectPairs(got: []const Pair, want: []const Pair, index: usize, enc: TextEncoding) !void {
    if (got.len != want.len) {
        std.debug.print("encoding {s}, index {d}: read {d} mark(s), want {d}\n", .{
            @tagName(enc),
            index,
            got.len,
            want.len,
        });
        for (got) |p| std.debug.print("  got:  {s} = {any}\n", .{ p.name, p.value });
        for (want) |p| std.debug.print("  want: {s} = {any}\n", .{ p.name, p.value });
        return error.TestExpectedEqual;
    }
    for (got, want) |g, w| {
        if (!std.mem.eql(u8, g.name, w.name) or !g.value.eql(w.value)) {
            std.debug.print("encoding {s}, index {d}: got {s} = {any}, want {s} = {any}\n", .{
                @tagName(enc),
                index,
                g.name,
                g.value,
                w.name,
                w.value,
            });
            return error.TestExpectedEqual;
        }
    }
}

/// `doc.text(text)` with the object-replacement character every block marker
/// reads as put back to a newline (`tests/text.rs`:701-702).
fn normalizeBlocks(gpa: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) {
        if (std.mem.startsWith(u8, raw[i..], "\u{fffc}")) {
            try out.append(gpa, '\n');
            i += 3;
            continue;
        }
        try out.append(gpa, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// The characters the spans of `obj` spell, with a block read as a newline
/// (`tests/text.rs`:690-693).
fn spanChars(gpa: Allocator, shapes: []const Shape) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (shapes) |s| {
        if (s.block) {
            try out.append(gpa, '\n');
        } else {
            try out.appendSlice(gpa, s.text);
        }
    }
    return out.toOwnedSlice(gpa);
}

test "text: updateText over a fork converges on the fork's text (text.rs:16-30)" {
    const gpa = testing.allocator;
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "Hello, world!");
        defer f.deinit();
        // **A second actor, because a fork is a second history.** Upstream's
        // `AutoCommit::fork` draws a fresh random actor
        // (`automerge.rs`:702-706) and so does the port's `Document.fork`
        // (`doc.zig`:3700-3705) — but those sixteen bytes come from the
        // allocator and `setActorId` replaces the field without freeing them
        // (`doc.zig`:2295-2301), which `std.testing.allocator` will not let
        // pass. **`clone` and `setActorId`**: the same document with a
        // different actor, which is all a fork is.
        var other = try f.doc.clone(gpa, .auto);
        defer other.deinit();
        other.setActorId(.{ .bytes = "bbbbbbbb" });

        try trans.updateText(&other, f.text, "Goodbye, world!");
        try trans.updateText(&f.doc, f.text, "Hello, friends!");
        const heads = try f.doc.merge(gpa, &other);
        defer gpa.free(heads);
        try checkPremises(&f.doc, f.text, enc);

        // **The fork's text wins**: it is the later change, and `update_text`
        // is a diff, so the merge is "Goodbye, " against "Hello, " and every
        // character after the common prefix.
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "Goodbye, friends!", enc);
    }
}

test "text: updateText with ZWJ grapheme families converges across a merge (text.rs:32-53)" {
    const gpa = testing.allocator;
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "left👨‍👩‍👦right");
        defer f.deinit();
        var other = try f.doc.clone(gpa, .auto);
        defer other.deinit();
        other.setActorId(.{ .bytes = "bbbbbbbb" });

        // man, woman, girl — a different family of three.
        try trans.updateText(&other, f.text, "left👨‍👩‍👧right");
        // man, woman, boy, boy — a family of four.
        try trans.updateText(&f.doc, f.text, "left👨‍👩‍👦‍👦right");
        const heads = try f.doc.merge(gpa, &other);
        defer gpa.free(heads);
        try checkPremises(&f.doc, f.text, enc);

        // **A family of three followed by a family of four.** The whole point
        // is that the diff is over grapheme clusters: an edit that rewrites
        // one cluster must not take its neighbours with it, and the merge
        // must not collapse the two families into one.
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "left👨‍👩‍👧👨‍👩‍👦‍👦right", enc);
    }
}

test "text: two marks written after an insertion are two runs (text.rs:143-161)" {
    const gpa = testing.allocator;
    // **Upstream's assertion here is that the two writes do not fail**, and a
    // test that only checks that proves nothing, so the runs they produce are
    // asserted as well. The two are `strong` over `[1, 2)` and over `[3, 4)`,
    // with `2` between them, so a fold that coalesced them would be a fold
    // that marked the `3` as well.
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "12345");
        defer f.deinit();
        try trans.mark(&f.doc, f.text, 1, 2, "strong", .both, .{ .bool_value = true });
        try trans.mark(&f.doc, f.text, 3, 4, "strong", .both, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);

        const got = try marks(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectMarkRuns(got, &.{
            .{ .start = 1, .end = 2, .name = "strong", .value = .{ .bool_value = true } },
            .{ .start = 3, .end = 4, .name = "strong", .value = .{ .bool_value = true } },
        }, enc);
    }
}

test "text: zero-width marks do not split a span run (text.rs:297-319)" {
    const gpa = testing.allocator;
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "1234");
        defer f.deinit();
        try trans.mark(&f.doc, f.text, 1, 1, "strong", .both, .{ .bool_value = true });
        try trans.mark(&f.doc, f.text, 2, 2, "strong", .both, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);

        // **One run, not four.** A zero-width mark covers nothing, so the four
        // positions all read as the same set of marks and the spans
        // consolidate to one. A fold that opened a run for each mark
        // operation would produce four spans with the same marks, which is
        // the "adjacent spans with equal marks" this refuses.
        const shapes = try readShapes(gpa, &f.doc, f.text);
        defer freeShapes(gpa, shapes);
        if (!marksAreConsolidated(shapes)) {
            std.debug.print("encoding {s}: {d} spans, two of them with equal marks\n", .{
                @tagName(enc),
                shapes.len,
            });
            showShapes(shapes);
            return error.TestExpectedEqual;
        }
        try testing.expectEqual(@as(usize, 1), shapes.len);
        try expectText(shapes[0].text, "1234", enc);
        try testing.expect(!shapes[0].marked);
    }
}

test "text: an empty mark before a block marker does not repeat the text (text.rs:321-348)" {
    const gpa = testing.allocator;
    // **Three encodings, and `utf8_code_unit` is deliberately not among them**
    // — see [`one_wide_block_encodings`]. The scenario is two block markers and
    // then an insertion at **index 2**, and under UTF-8 code units the two
    // markers occupy units 0-2 and 3-5, so index 2 names a position *inside*
    // the first marker. The reference, asked directly, answers the port rather
    // than this expectation:
    //
    // ```
    // UnicodeCodePoint spans=["Block", "Block", "Text(\"a\")"] len=3
    // Utf8CodeUnit     spans=["Block", "Text(\"a\")", "Block"] len=7
    // Utf16CodeUnit    spans=["Block", "Block", "Text(\"a\")"] len=3
    // GraphemeCluster  spans=["Block", "Block", "Text(\"a\")"] len=3
    // ```
    //
    // — and `tests/text.rs:321-348` runs under `AutoCommit::new()`, which is
    // `UnicodeCodePoint` (`text_value.rs:12-22`).
    for (one_wide_block_encodings) |enc| {
        var f = try textFixture(gpa, enc, "");
        defer f.deinit();
        _ = try trans.splitBlock(&f.doc, f.text, 0);
        _ = try trans.splitBlock(&f.doc, f.text, 0);
        try trans.mark(&f.doc, f.text, 1, 1, "strong", .both, .{ .bool_value = true });
        try trans.spliceText(&f.doc, f.text, 2, 0, "a");
        try checkPremises(&f.doc, f.text, enc);

        // **Two blocks and one unmarked `a`, and the `a` appears once.** The
        // empty mark sits at index 1, between the two block markers, and a
        // reader that let a zero-width mark open a span would repeat the text
        // around it.
        const shapes = try readShapes(gpa, &f.doc, f.text);
        defer freeShapes(gpa, shapes);
        if (shapes.len != 3) {
            std.debug.print("encoding {s}: {d} spans, want 3\n", .{ @tagName(enc), shapes.len });
            showShapes(shapes);
            return error.TestExpectedEqual;
        }
        const want_block = [_]bool{ true, true, false };
        for (shapes, want_block) |s, want| {
            if (s.block != want) {
                std.debug.print("encoding {s}: span at the wrong position\n", .{@tagName(enc)});
                showShapes(shapes);
                return error.TestExpectedEqual;
            }
        }
        try expectText(shapes[2].text, "a", enc);
        try testing.expect(!shapes[2].marked);

        const chars = try spanChars(gpa, shapes);
        defer gpa.free(chars);
        try expectText(chars, "\n\na", enc);
    }
}

test "text: updateText inside an isolation keeps both sides (text.rs:644-656)" {
    const gpa = testing.allocator;
    // **Every element, in order.** A text is a sequence of elements rather than
    // a string, and the property this test is named for is that *both* writes
    // survive: the `c` the isolated change made and the `b` the concurrent one
    // made are both here, each in its own place, and an element that was lost
    // or duplicated is named by the comparison rather than hidden inside it.
    //
    // **The `"\n"` entries are ordinary characters, not block markers.**
    // Upstream's `splice_text` inserts the characters it is handed and does
    // not translate a newline into one
    // ([`inner.rs:1473-1512`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs));
    // only `split_block` makes a block, and the test above pins that. So the
    // merged document is six characters and upstream's own `doc.text` answer is
    // the six-character string `"a\nc\nb\n"`
    // ([`tests/text.rs`:655](../../../github-automerge-automerge/rust/automerge/tests/text.rs)).
    const after_first = [_][]const u8{ "a", "\n" };
    const after_second = [_][]const u8{ "a", "\n", "b", "\n" };
    const after_both = [_][]const u8{ "a", "\n", "c", "\n", "b", "\n" };
    // **The isolated write's own state**, which is what a read *through the
    // isolation* answers and is neither of the two the document itself can
    // show: the `b` is concurrent with the `c` and is not in the `c`'s
    // history, so the merge below is not what is visible here.
    const after_isolated = [_][]const u8{ "a", "\n", "c", "\n" };

    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "");
        defer f.deinit();
        try trans.updateText(&f.doc, f.text, "a\n");
        // **The state the isolation is taken at**, so the test is not
        // isolating an empty document and passing for that reason.
        try expectChars(&f.doc, f.text, &after_first, enc);

        const initial = try f.doc.getHeads(gpa);
        defer gpa.free(initial);
        try trans.updateText(&f.doc, f.text, "a\nb\n");
        try checkPremises(&f.doc, f.text, enc);
        try expectChars(&f.doc, f.text, &after_second, enc);

        // **The second `update_text` is made against the first change alone**,
        // so it is concurrent with the `b` rather than after it. Integrating
        // then has to keep both, and the concurrent one wins its line: the `c`
        // lands between the `a` and the `b` rather than after the `b`.
        try f.doc.isolate(gpa, initial);
        try trans.updateText(&f.doc, f.text, "a\nc\n");

        // **Read with the isolation still in place, and it reads the
        // isolated write's own state — `"a\nc\n"` — not the merge and not the
        // pre-isolation `"a\n"`.** Two steps make that, and both are
        // upstream's:
        //
        // * `AutoCommit::text` resolves its clock through `get_scope(None)`,
        //   whose second arm is `(Some(i), None) => self.doc.clock_at(i)`
        //   ([`autocommit.rs`:806-813](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
        //   so the read is **not** of the present — this port's
        //   [`Document.readScope`](doc.zig) is that arm;
        // * and `i` is **not** `initial` any more, because a commit made
        //   under an isolation advances it. Upstream runs
        //   `self.isolation = ...` on both ends of a commit
        //   ([`autocommit.rs`:464-466, `:735-736](../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
        //   and this port's [`Document.commit`](doc.zig) is that line.
        //   Without it the second write under one isolation could not see the
        //   object the first made, and the concurrency walk would fork a third
        //   actor.
        //
        // So `update_text("a\nc\n")` commits a change whose history is
        // `initial` plus itself, the `b` is concurrent with it and is not in
        // that history, and four elements is the only answer consistent with
        // both arms. Upstream's own case
        // ([`tests/text.rs`:644-656](../../../github-automerge-automerge/rust/automerge/tests/text.rs))
        // asserts **after** `integrate`, so it has no answer for the read in
        // between — this is the port's own line, and before the readers were
        // scoped it was asserting the unscoped read.
        try expectChars(&f.doc, f.text, &after_isolated, enc);
        {
            const seen = try text(&f.doc, f.text, gpa);
            defer gpa.free(seen);
            try expectText(seen, "a\nc\n", enc);
        }

        try f.doc.integrate();
        try checkPremises(&f.doc, f.text, enc);
        try expectChars(&f.doc, f.text, &after_both, enc);

        // **Upstream's own assertion, read the other way round**
        // ([`tests/text.rs`:655](../../../github-automerge-automerge/rust/automerge/tests/text.rs)):
        // the same six elements as one string.
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "a\nc\nb\n", enc);
    }
}

// ── The isolation reaches every reader ──────────────────────────────────────

/// A root map with a **list**, a **marked text object** and a scalar, built
/// through manual transactions so a `Transaction` can be opened on it after.
///
/// **Manual and not `textFixture`'s auto**, because one of the three tests
/// below opens a `Transaction` and that is the only door a transaction opens
/// ([`transact.zig`](transact.zig)'s "the wrong door" case,
/// `autocommit.rs`:447-452). The shape is chosen so that **each of the
/// fourteen readers has something the later write changes**: a key that is
/// overwritten (`get`, `getAll`), a key that is *added* (`keys`, `values`,
/// `mapRange`, `length`), text that grows (`text`, `length`, `spans`,
/// `listRange` over the list), a mark that appears (`marks`, `getMarks`), and
/// a list element inserted ahead of an existing one (the two cursor readers).
const ScopedDoc = struct {
    doc: Document,
    text: ExId,
    list: ExId,
    heads: []ChangeHash,

    fn deinit(self: *ScopedDoc, gpa: Allocator) void {
        gpa.free(self.heads);
        self.doc.deinit();
        self.* = undefined;
    }
};

fn scopedFixture(gpa: Allocator) !ScopedDoc {
    var doc = try Document.init(gpa, .manual);
    errdefer doc.deinit();
    // **A named actor, because a random one would make a failure
    // unreproducible** — [`textFixture`] gives the reason.
    doc.setActorId(.{ .bytes = "aaaaaaaa" });
    var tx = try trans.Transaction.open(gpa, &doc);
    defer tx.deinit();
    const txt = try tx.putObject(.root, .{ .key = "text" }, .text);
    const list = try tx.putObject(.root, .{ .key = "list" }, .list);
    _ = try tx.put(.root, .{ .key = "size" }, .{ .int = 100 });
    try tx.spliceText(txt, 0, 0, "aaabbbccc");
    try tx.mark(txt, 0, 3, "bold", .both, .{ .bool_value = true });
    for ([_][]const u8{ "a", "b", "c" }, 0..) |s, i| {
        _ = try tx.insert(list, i, .{ .str = s });
    }
    _ = try tx.commit(null, null);
    const heads = try doc.getHeads(gpa);
    return .{ .doc = doc, .text = txt, .list = list, .heads = heads };
}

/// The four writes a test makes **under** an isolation, one per kind of thing
/// a reader can be wrong about.
fn writeAfterIsolate(f: *ScopedDoc, gpa: Allocator) !void {
    var tx = try trans.Transaction.open(gpa, &f.doc);
    defer tx.deinit();
    _ = try tx.put(.root, .{ .key = "size" }, .{ .int = 150 });
    _ = try tx.put(.root, .{ .key = "other" }, .{ .int = 999 });
    try tx.spliceText(f.text, 3, 0, "QQQ");
    try tx.mark(f.text, 3, 6, "italic", .both, .{ .bool_value = true });
    _ = try tx.insert(f.list, 0, .{ .str = "z" });
    _ = try tx.commit(null, null);
}

test "a read scoped to the current heads is the unscoped read" {
    const gpa = testing.allocator;
    var f = try scopedFixture(gpa);
    defer f.deinit(gpa);

    // **Every reader's answer, taken before the isolation**, is what the same
    // reader has to answer once the document is isolated **at the heads it is
    // already at**. Upstream says so in `Automerge::clock_at`
    // ([`automerge.rs`:1242-1249](../github-automerge-automerge/rust/automerge/src/automerge.rs)):
    // "Returns `None` — an unscoped read of the present document — when
    // `heads` is exactly the current heads, so `*_at(doc.get_heads())` takes
    // the same indexed fast paths as the un-suffixed methods". **A document
    // that built a clock here would be a document answering a different
    // question than upstream does**, and it would be answering it on the slow
    // path.
    try f.doc.isolate(gpa, f.heads);
    try testing.expectEqual(f.heads.len, (f.doc.isolationHeads() orelse unreachable).len);

    {
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "aaabbbccc", .unicode_code_point);
        try testing.expectEqual(@as(usize, 9), try length(&f.doc, f.text));
        try testing.expectEqual(@as(usize, 3), try length(&f.doc, f.list));
    }
    {
        const got = try marks(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectMarkRuns(got, &.{
            .{ .start = 0, .end = 3, .name = "bold", .value = .{ .bool_value = true } },
        }, .unicode_code_point);
    }
    {
        const key_names = try keyList(gpa, &f.doc, .root);
        defer freeStrings(gpa, key_names);
        try testing.expectEqual(@as(usize, 3), key_names.len);
    }
}

test "every reader on an isolated document cannot see a write made after the isolation" {
    const gpa = testing.allocator;
    const enc: TextEncoding = .unicode_code_point;
    var f = try scopedFixture(gpa);
    defer f.deinit(gpa);

    // **A cursor for the list's first element, taken before the isolation.**
    // It names an *operation id* and not an index ([`Cursor`], `cursor.rs`:19-26),
    // so it survives the insert that follows; what changes is where it sits.
    const first_elem = try getCursor(&f.doc, f.list, .{ .index = 0 }, null, gpa);

    // The two isolations are what upstream's `can_isolate`
    // ([`test.rs`:2557, `:2579](../github-automerge-automerge/rust/automerge/tests/test.rs))
    // does, and **the second one is load-bearing**: a commit made under an
    // isolation advances it ([`Document.commit`](doc.zig),
    // [`autocommit.rs`:735-736](../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
    // so without it the isolation would name the later head and the read would
    // see the write it is supposed to hide. A test that isolated once and read
    // would pass on a port with no scoping at all.
    try f.doc.isolate(gpa, f.heads);
    try writeAfterIsolate(&f, gpa);
    try f.doc.isolate(gpa, f.heads);

    // **All fourteen readers, below** — [`marks`] and [`getMarks`] included.
    // The two marks readers reach [`OpSet.calculateMarksAt`](opset/op_set.zig)'s
    // *walk* where the other twelve reach an index or an iterator, and the walk
    // is the arm a clock selects.

    // `get`: the overwritten key reads its old value.
    try testing.expectEqual(
        @as(i64, 100),
        (try scalarOf((try get(&f.doc, .root, .{ .key = "size" })).?)).int,
    );
    // **and the key that did not exist yet is absent**, which is a different
    // question from the first and fails differently.
    try testing.expect((try get(&f.doc, .root, .{ .key = "other" })) == null);

    // `getAll`: one row in that register, and it is the old value.
    {
        const all = try getAll(&f.doc, .root, .{ .key = "size" }, gpa);
        defer gpa.free(all);
        try testing.expectEqual(@as(usize, 1), all.len);
        try testing.expectEqual(@as(i64, 100), (try scalarOf(all[0])).int);
    }

    // `text` and `length`.
    {
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "aaabbbccc", enc);
    }
    try testing.expectEqual(@as(usize, 9), try length(&f.doc, f.text));
    // **`length` over a map counts visible keys**, so the added key is the
    // third reader's evidence and not the first's (`op_set.rs`:429-461).
    try testing.expectEqual(@as(usize, 3), try length(&f.doc, .root));

    // `keys` and `values`.
    {
        const key_names = try keyList(gpa, &f.doc, .root);
        defer freeStrings(gpa, key_names);
        try testing.expectEqual(@as(usize, 3), key_names.len);
        for (key_names) |k| try testing.expect(!std.mem.eql(u8, k, "other"));
    }
    {
        const vals = try valueList(gpa, &f.doc, .root);
        defer gpa.free(vals);
        try testing.expectEqual(@as(usize, 3), vals.len);
    }

    // `spans`: the text is the old text and the later mark is not on it.
    {
        const shapes = try readShapes(gpa, &f.doc, f.text);
        defer freeShapes(gpa, shapes);
        var joined: usize = 0;
        for (shapes) |s| joined += s.text.len;
        try testing.expectEqual(@as(usize, 9), joined);
    }

    // **`marks` and `getMarks`.** Measured on the reference by the oracle's
    // `updocprobe atheads` (`tools/oracle/src/main.rs`, whose script is this
    // one written through the reference's own writer): at the first head the
    // mark list is `bold [0, 3)`, and at the present — after
    // `writeAfterIsolate` — it is `bold [0, 6)` and `italic [3, 6)`. **The
    // splice landed on the *end* of the bold mark and `ExpandMark::Both` is
    // what made it inherit**, which is why the present's bold is `[0, 6)` and
    // not `[0, 3)`. Under the isolation neither the splice nor the italic mark
    // is in the document the clock names, so both readers answer the earlier
    // list and nothing else — **which is the assertion a reader that ignored
    // the clock could not pass.**
    {
        const got = try marks(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectMarkRuns(got, &.{
            .{ .start = 0, .end = 3, .name = "bold", .value = .{ .bool_value = true } },
        }, enc);
    }
    // **The window reader, on the same scoped list.** `getMarks(0, 3)` is the
    // bold run; `getMarks(3, 12)` is empty, because the run that reaches into
    // that window is the italic one and the isolation's clock has no italic
    // mark at all.
    {
        const got = try getMarks(&f.doc, f.text, 0, 3, gpa);
        defer gpa.free(got);
        try expectMarkRuns(got, &.{
            .{ .start = 0, .end = 3, .name = "bold", .value = .{ .bool_value = true } },
        }, enc);
    }
    {
        const got = try getMarks(&f.doc, f.text, 3, 12, gpa);
        defer gpa.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }

    // `mapRange` and `listRange`.
    {
        const items = try mapItems(gpa, &f.doc, .root, .all());
        defer freeMapItems(gpa, items);
        try testing.expectEqual(@as(usize, 3), items.len);
        for (items) |it| try testing.expect(!std.mem.eql(u8, it.key, "other"));
    }
    {
        const items = try listItems(gpa, &f.doc, f.list, .all());
        defer freeListItems(gpa, items);
        try testing.expectEqual(@as(usize, 3), items.len);
        try expectText(items[0].text, "a", enc);
    }

    // `parents`: the text object still hangs off the root under `"text"`.
    {
        var walk = try parents(&f.doc, f.text);
        const step = (try walk.next()).?;
        try testing.expectEqual(.root, step.obj);
        try testing.expectEqualStrings("text", step.prop.key);
        try testing.expect((try walk.next()) == null);
    }

    // `getCursorMoving` and `getCursorPosition`: the inserted element is not
    // there, so the cursor still sits where it did. **Unscoped it would be 1.**
    try testing.expectEqual(
        @as(usize, 0),
        try getCursorPosition(&f.doc, f.list, first_elem, null),
    );
    {
        const at0 = try getCursor(&f.doc, f.list, .{ .index = 0 }, null, gpa);
        try testing.expectEqual(
            @as(usize, 0),
            try getCursorPosition(&f.doc, f.list, at0, null),
        );
    }

    // **And the isolation is what hid all of it.** `integrate` is upstream's
    // [`AutoCommit::integrate`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):439-443),
    // the writes become ordinary history, and the same readers now see them.
    try f.doc.integrate();
    try testing.expectEqual(
        @as(i64, 150),
        (try scalarOf((try get(&f.doc, .root, .{ .key = "size" })).?)).int,
    );
    try testing.expect((try get(&f.doc, .root, .{ .key = "other" })) != null);
    try testing.expectEqual(@as(usize, 12), try length(&f.doc, f.text));
    try testing.expectEqual(@as(usize, 4), try length(&f.doc, .root));
    try testing.expectEqual(@as(usize, 4), try length(&f.doc, f.list));
    try testing.expectEqual(
        @as(usize, 1),
        try getCursorPosition(&f.doc, f.list, first_elem, null),
    );
    // **And the two mark readers now read the present**, which is the other
    // half of the claim: the same document and the same two readers answer
    // `bold [0, 3)` under the isolation and `bold [0, 6)` plus `italic
    // [3, 6)` once the clock is the present's. **Both lists are the
    // reference's own**, read by `updocprobe atheads` at `first` and at the
    // present, and a reader that ignored the clock would fail the *first* of
    // the two assertions above rather than this one.
    {
        const got = try marks(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectMarkRuns(got, &.{
            .{ .start = 0, .end = 6, .name = "bold", .value = .{ .bool_value = true } },
            .{ .start = 3, .end = 6, .name = "italic", .value = .{ .bool_value = true } },
        }, enc);
    }
    // **`getMarks` over the window the italic mark covers**, so the two readers
    // are shown to be answering one list rather than two of their own. **Two
    // runs and not one**, because a run intersects the window it reaches into
    // rather than one it starts in: `bold [0, 6)` reaches `[3, 6)` and
    // `italic [3, 6)` fills it.
    {
        const got = try getMarks(&f.doc, f.text, 3, 6, gpa);
        defer gpa.free(got);
        try expectMarkRuns(got, &.{
            .{ .start = 0, .end = 6, .name = "bold", .value = .{ .bool_value = true } },
            .{ .start = 3, .end = 6, .name = "italic", .value = .{ .bool_value = true } },
        }, enc);
    }
}

/// The three-commit text history the oracle's `updocprobe atheads` builds
/// (`tools/oracle/src/main.rs`), and the heads each commit ended at.
///
/// **The script is the reference's, op for op**: a text object, `aaabbbccc`,
/// a `bold` mark over `[0, 3)` written `ExpandMark::Both`; then `QQQ` spliced
/// at index 3 and an `italic` mark over `[3, 6)`; then an unmark of `italic`
/// over `[3, 6)` written `ExpandMark::None`. Reading the three heads and the
/// present of one document is the whole of what the oracle records, and the
/// two writers differ in nothing a mark read can see.
const AtHeads = struct {
    doc: Document,
    text: ExId,
    first: []ChangeHash,
    second: []ChangeHash,
    third: []ChangeHash,

    fn deinit(self: *AtHeads, gpa: Allocator) void {
        gpa.free(self.first);
        gpa.free(self.second);
        gpa.free(self.third);
        self.doc.deinit();
        self.* = undefined;
    }
};

fn atHeadsFixture(gpa: Allocator) !AtHeads {
    var doc = try Document.init(gpa, .manual);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = "aaaaaaaa" });
    var tx = try trans.Transaction.open(gpa, &doc);
    const txt = try tx.putObject(.root, .{ .key = "text" }, .text);
    try tx.spliceText(txt, 0, 0, "aaabbbccc");
    try tx.mark(txt, 0, 3, "bold", .both, .{ .bool_value = true });
    _ = try tx.commit(null, null);
    tx.deinit();
    const first = try doc.getHeads(gpa);

    var second_tx = try trans.Transaction.open(gpa, &doc);
    defer second_tx.deinit();
    try second_tx.spliceText(txt, 3, 0, "QQQ");
    try second_tx.mark(txt, 3, 6, "italic", .both, .{ .bool_value = true });
    _ = try second_tx.commit(null, null);
    const second = try doc.getHeads(gpa);

    var third_tx = try trans.Transaction.open(gpa, &doc);
    defer third_tx.deinit();
    // **`null` is the tombstone**, which is how an unmark is spelled here and
    // how `Transaction.unmark` reaches `Transaction.mark` (transact.zig:1170-1180).
    try third_tx.unmark(txt, 3, 6, .none, "italic", null);
    _ = try third_tx.commit(null, null);
    const third = try doc.getHeads(gpa);

    return .{ .doc = doc, .text = txt, .first = first, .second = second, .third = third };
}

test "a mark read at an older head answers that head, and the present answers the present" {
    const gpa = testing.allocator;
    const enc: TextEncoding = .unicode_code_point;
    var f = try atHeadsFixture(gpa);
    defer f.deinit(gpa);

    // **Every expectation below is the reference's own**, read by the oracle's
    // `updocprobe` — `cargo run --manifest-path tools/oracle/Cargo.toml --
    // updocprobe -` — over the script [`atHeadsFixture`] builds. The four
    // readings are all different from one another, so a reader that answered
    // any of them for all four is caught here rather than argued about.
    //
    // **What the present says that none of the older heads does**: the `QQQ`
    // splice landed on the *end* of the `bold` mark, and `ExpandMark::Both`
    // made it inherit, so at the present `bold` covers `[0, 6)` and not
    // `[0, 3)`. `bold [0, 3)` at the first head is therefore not a stale copy
    // of the present — it is a different range, measured in a different text.

    // At the first head: the text as it was, and one mark over its head.
    try f.doc.isolate(gpa, f.first);
    {
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "aaabbbccc", enc);
        try testing.expectEqual(@as(usize, 9), try length(&f.doc, f.text));
        const runs = try marks(&f.doc, f.text, gpa);
        defer gpa.free(runs);
        try expectMarkRuns(runs, &.{
            .{ .start = 0, .end = 3, .name = "bold", .value = .{ .bool_value = true } },
        }, enc);
    }

    // At the second head: the splice and the mark over it, and `bold` grown
    // over the splice.
    try f.doc.isolate(gpa, f.second);
    {
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "aaaQQQbbbccc", enc);
        try testing.expectEqual(@as(usize, 12), try length(&f.doc, f.text));
        const runs = try marks(&f.doc, f.text, gpa);
        defer gpa.free(runs);
        try expectMarkRuns(runs, &.{
            .{ .start = 0, .end = 6, .name = "bold", .value = .{ .bool_value = true } },
            .{ .start = 3, .end = 6, .name = "italic", .value = .{ .bool_value = true } },
        }, enc);
    }

    // At the third head: the unmark is under this clock, so `italic` is gone
    // rather than reported as a run of `null` — **the tombstone is not a mark**
    // (`op_set.rs:1023`) — and `bold` is untouched by it.
    try f.doc.isolate(gpa, f.third);
    {
        const runs = try marks(&f.doc, f.text, gpa);
        defer gpa.free(runs);
        try expectMarkRuns(runs, &.{
            .{ .start = 0, .end = 6, .name = "bold", .value = .{ .bool_value = true } },
        }, enc);
        // **And `italic` is still there at the second head**, which is the
        // other direction of the same claim and the one that would fail if the
        // walk consulted the present's index.
        try f.doc.isolate(gpa, f.second);
        const earlier = try marks(&f.doc, f.text, gpa);
        defer gpa.free(earlier);
        try expectMarkRuns(earlier, &.{
            .{ .start = 0, .end = 6, .name = "bold", .value = .{ .bool_value = true } },
            .{ .start = 3, .end = 6, .name = "italic", .value = .{ .bool_value = true } },
        }, enc);
    }

    // **The present, with no isolation at all** — which is the reading that
    // takes the indexed arm, and it agrees with the third head because the
    // present *is* the third head here. `integrate` drops the isolation rather
    // than the document having one to drop first.
    try f.doc.integrate();
    {
        const runs = try marks(&f.doc, f.text, gpa);
        defer gpa.free(runs);
        try expectMarkRuns(runs, &.{
            .{ .start = 0, .end = 6, .name = "bold", .value = .{ .bool_value = true } },
        }, enc);
    }
}

test "a transaction's scope is the transaction's, and a document's is the isolation's" {
    const gpa = testing.allocator;
    const enc: TextEncoding = .unicode_code_point;
    var f = try scopedFixture(gpa);
    defer f.deinit(gpa);

    try f.doc.isolate(gpa, f.heads);
    try writeAfterIsolate(&f, gpa);
    try f.doc.isolate(gpa, f.heads);

    // **The document arm.** `AutoCommit::get_scope`'s second match arm is
    // `(Some(i), None) => self.doc.clock_at(i)`
    // ([`autocommit.rs`:806-813](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)) —
    // "then look at clock for isolation (no transaction is open, so isolation
    // at the current heads can read unscoped)" — and no transaction is open.
    {
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "aaabbbccc", enc);
    }

    // **The transaction arm**, which is the *first* arm and names a different
    // clock: `t.get_scope()` ([`transact.zig`](transact.zig)'s `scopeClock`).
    // It is built from the same heads **and marks the transaction's own actor**
    // ([`Clock.isolate`](clock.zig):128-136, upstream's `isolate_actor`,
    // `automerge.rs`:1276-1280), so the transaction sees the ops it has
    // written and is about to write — which the document's clock does not.
    var tx = try trans.Transaction.open(gpa, &f.doc);
    defer tx.deinit();
    try tx.spliceText(f.text, 3, 0, "QQQ");
    // **The transaction's read is not the document's read, and that is the
    // claim** — so this asserts the *relation* between the two answers and
    // leaves the transaction's own string to the transaction's own tests. What
    // it would be wrong to assert is that the two are equal: upstream keeps
    // them apart on purpose (`get_scope`'s first arm against its second,
    // `autocommit.rs`:806-813), because the transaction's clock has the
    // transaction's own actor marked ([`Clock.isolate`](clock.zig):128-136)
    // and the document's does not.
    const through_tx = try tx.textFor(f.text);
    try testing.expect(!std.mem.eql(u8, through_tx, "aaabbbccc"));
    try testing.expect(std.mem.indexOf(u8, through_tx, "QQQ") != null);

    // **The two differ, and the difference is the whole claim.** The pending
    // operation is in the op set already and is under neither clock's heads,
    // so a reader that reached for the transaction's clock would report a
    // write the caller has not committed, and a reader that reached for the
    // document's clock would hide a write upstream shows.
    {
        const got = try text(&f.doc, f.text, gpa);
        defer gpa.free(got);
        try expectText(got, "aaabbbccc", enc);
    }

    // **Committing closes the transaction and advances the isolation**, so the
    // two agree again — and only because of the advance, not because either
    // arm fell back to the present.
    // **The transaction is spent**, so its own reads are refused and the only
    // reader left is the document's. What the committed document reads is
    // [`can_isolate`](../../github-automerge-automerge/rust/automerge/tests/test.rs)'s
    // question and [`test "text: updateText inside an isolation keeps both
    // sides (text.rs:644-656)"`] above is its answer; this test is about which
    // clock each of the two arms reaches, and that is settled above.
}

/// The scalar an item carries, and a refusal rather than a silent null
fn scalarOf(item: DocItem) !ScalarValue {
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

test "text: a splice that lands inside a multi-unit character deletes after it (text.rs:923-941)" {
    const gpa = testing.allocator;
    const bears = "🐻🐻🐻🐻🐻🐻";
    // **Upstream's three answers, for `utf16_code_unit` only** — the encoding
    // its `new_with_encoding` call pins (`tests/text.rs`:925). The three
    // indexes are 2, 4 and 4 in *its* units, and under UTF-16 a 🐻 is two of
    // them, so two of the three land inside a character and one lands on a
    // boundary. The rule that produces all three is [`splicedText`], and it
    // is asserted for the other three encodings as well — where a 🐻 is four
    // UTF-8 bytes, one code point, or one cluster, so the same numbers mean
    // something else and the answer is legitimately different.
    const Step = struct { pos: usize, del: usize, ins: []const u8, want: []const u8 };
    const utf16_answers = [_]Step{
        .{ .pos = 2, .del = 2, .ins = "A🐻A", .want = "🐻A🐻A🐻🐻🐻🐻" },
        .{ .pos = 4, .del = 1, .ins = "X", .want = "🐻A🐻X🐻🐻🐻🐻" },
        .{ .pos = 4, .del = 2, .ins = "Y", .want = "🐻A🐻Y🐻🐻🐻" },
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, bears);
        defer f.deinit();
        // **`before` is the caller's and the loop hands each read to the
        // next**, so the `defer` frees the last one and the loop frees the
        // ones before it. A `defer` body is evaluated when it runs, not when
        // it is declared, which is what makes this correct.
        var before = try text(&f.doc, f.text, gpa);
        defer gpa.free(before);
        try expectText(before, bears, enc);

        for (utf16_answers) |step| {
            const want = try splicedText(gpa, enc, before, step.pos, step.del, step.ins);
            // **The rule and upstream's literal string are one answer under
            // UTF-16**, and UTF-16 is the only encoding upstream states one
            // for.
            if (enc == .utf16_code_unit) try expectText(want, step.want, enc);

            try trans.spliceText(&f.doc, f.text, step.pos, @intCast(step.del), step.ins);
            try checkPremises(&f.doc, f.text, enc);
            const got = try text(&f.doc, f.text, gpa);
            gpa.free(before);
            before = got;
            try expectText(got, want, enc);
            gpa.free(want);
        }
    }
}

test "text: a mark removed by a null value is not a mark (text.rs:835-866)" {
    const gpa = testing.allocator;
    // **The bug this reproduces** is automerge-swift#214, where a mark removed
    // by setting its value to null came back from `get_marks` *with* the null
    // value (`tests/text.rs`:837-840).
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "abcdefg");
        defer f.deinit();
        try trans.mark(&f.doc, f.text, 0, 1, "name1", .none, .{ .int = 1 });
        try checkPremises(&f.doc, f.text, enc);
        // **The mark is there before it is removed**, or a document that never
        // wrote it would pass this.
        const live = try marks(&f.doc, f.text, gpa);
        defer gpa.free(live);
        try expectMarkRuns(live, &.{
            .{ .start = 0, .end = 1, .name = "name1", .value = .{ .int = 1 } },
        }, enc);

        try trans.mark(&f.doc, f.text, 0, 1, "name1", .none, .null_value);
        try checkPremises(&f.doc, f.text, enc);

        // **Empty, not one mark with a null value.** A tombstone is not a mark
        // (`marks.zig`:273-279, `op_set.rs`:1023), and the window read at the
        // index it covered must agree.
        const after = try marks(&f.doc, f.text, gpa);
        defer gpa.free(after);
        try expectMarkRuns(after, &.{}, enc);
        const window = try getMarks(&f.doc, f.text, 0, 1, gpa);
        defer gpa.free(window);
        try expectMarkRuns(window, &.{}, enc);
        // **And the rest of the text is unmarked too**, so the removal was a
        // mark and not a deletion.
        const other = try getMarks(&f.doc, f.text, 1, 7, gpa);
        defer gpa.free(other);
        try expectMarkRuns(other, &.{}, enc);
        const body = try text(&f.doc, f.text, gpa);
        defer gpa.free(body);
        try expectText(body, "abcdefg", enc);
    }
}

/// A `[a-zA-Z]{1,10}` string, the shape [`arb_insert`] and [`arb_add_mark`]
/// draw (`tests/text.rs`:752, :778).
///
/// **Inline, because a generated scenario has to own its own strings** and an
/// allocator per action would be a second thing to get wrong in a test whose
/// subject is the text.
const Letters = struct {
    bytes: [10]u8 = @splat('a'),
    len: u8 = 1,

    fn slice(self: *const Letters) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// One step of a generated scenario ([`Action`](tests/text.rs):730-749).
const Action = union(enum) {
    insert: struct { index: usize, value: Letters },
    del: struct { index: usize, len: usize },
    split_block: struct { index: usize },
    add_mark: struct { index: usize, len: usize, name: Letters, value: Letters },
};

/// A deterministic 64-bit LCG.
///
/// **A property framework's job, done by hand.** Upstream drives
/// `marks_are_okay` with `proptest` (`tests/text.rs`:658-710), which shrinks a
/// counterexample to something readable and persists it across runs. The port
/// has no property framework and no persistence, so what is left is: the same
/// action alphabet, the same ranges, and a **fixed seed**, which makes every
/// failure reproducible. The number of scenarios is a parameter below, not a
/// hidden default, so a reader can see what coverage this claims.
const Lcg = struct {
    state: u64,

    fn next(self: *Lcg) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state;
    }

    /// A value in `[0, n)`, which is what a `proptest` `0..n` range means.
    fn below(self: *Lcg, n: usize) usize {
        if (n == 0) return 0;
        return @intCast(self.next() % n);
    }

    /// A value in `[0, n]`, which is what a `proptest` `0..=n` range means.
    fn upTo(self: *Lcg, n: usize) usize {
        return self.below(n + 1);
    }
};

/// A `[a-zA-Z]{1,10}` string, one draw.
fn arbLetters(rng: *Lcg) Letters {
    var out = Letters{};
    out.len = @intCast(1 + rng.below(10));
    for (out.bytes[0..out.len]) |*b| {
        b.* = 'a' + @as(u8, @intCast(rng.below(26)));
    }
    return out;
}

/// One action against a state of `len` bytes, over the same four generators
/// upstream builds (`tests/text.rs`:751-799).
fn arbAction(rng: *Lcg, len: usize) Action {
    // **An empty state can only be inserted into** — upstream's `arb_action`
    // returns `arb_insert` and nothing else when `text.is_empty()`
    // (`:788-791`), because every other generator has an empty range.
    if (len == 0) return .{ .insert = .{ .index = 0, .value = arbLetters(rng) } };
    return switch (rng.below(4)) {
        // `arb_insert`: `0..=text.len()` and a 1..10 letter string (`:751-753`).
        0 => .{ .insert = .{ .index = rng.upTo(len), .value = arbLetters(rng) } },
        // `arb_delete`: the `len == 1` arm, then `delete_len in 1..len` with
        // `index in 0..len - delete_len` (`:755-768`).
        1 => blk: {
            if (len == 1) break :blk Action{ .del = .{ .index = 0, .len = 1 } };
            const del = 1 + rng.below(len - 1);
            break :blk Action{ .del = .{
                .index = rng.below(len - del),
                .len = del,
            } };
        },
        // `arb_split_block`: `0..=text.len()` (`:770-772`).
        2 => .{ .split_block = .{ .index = rng.upTo(len) } },
        // `arb_add_mark`: `index in 0..len`, `len in 0..len - index`, and a
        // 1..10 letter name and value (`:774-786`).
        else => blk: {
            const index = rng.below(len);
            const run = rng.below(len - index);
            break :blk Action{ .add_mark = .{
                .index = index,
                .len = run,
                .name = arbLetters(rng),
                .value = arbLetters(rng),
            } };
        },
    };
}

/// A scenario: `max_actions` actions over a state that starts empty
/// ([`arb_scenario`](tests/text.rs):801-833), with `max_actions in 0..10`.
fn arbScenario(gpa: Allocator, rng: *Lcg, out: *std.ArrayList(Action)) !void {
    const max_actions = rng.below(10);
    var state: std.ArrayList(u8) = .empty;
    defer state.deinit(gpa);
    var n: usize = 0;
    while (n < max_actions) : (n += 1) {
        const action = arbAction(rng, state.items.len);
        // **The state is advanced with the same rules the document is**, so
        // the next action's ranges are legal. A block marker is a newline
        // here, as it is in upstream's `pump` (`:822`).
        switch (action) {
            .insert => |v| {
                try state.insertSlice(gpa, v.index, v.value.slice());
            },
            .del => |v| {
                const end = v.index + v.len;
                if (end > state.items.len) return error.TestUnexpectedResult;
                state.replaceRange(gpa, v.index, end, &.{}) catch return error.OutOfMemory;
            },
            .split_block => |v| try state.insert(gpa, v.index, '\n'),
            .add_mark => {},
        }
        try out.append(gpa, action);
    }
}

/// The scenario, one action per line, in the order it was applied
/// ([`tests/text.rs:685`](../../github-automerge-automerge/rust/automerge/tests/text.rs)'s
/// `println!("scenario: {:?}", scenario)`, which upstream prints before each
/// of its three panics).
///
/// **The model and the document advance together in the loop above, so the
/// line number here is the line number of the action that first made them
/// disagree** — which is the only thing a report needs to be actionable.
fn showScenario(actions: []const Action, after: usize) void {
    for (actions, 0..) |a, i| {
        const mark: []const u8 = if (i == after) " <-- here" else "";
        switch (a) {
            .insert => |v| std.debug.print("  {d}: insert({d}, \"{s}\"){s}\n", .{
                i,
                v.index,
                v.value.slice(),
                mark,
            }),
            .del => |v| std.debug.print("  {d}: delete({d}, {d}){s}\n", .{
                i,
                v.index,
                v.len,
                mark,
            }),
            .split_block => |v| std.debug.print("  {d}: split_block({d}){s}\n", .{
                i,
                v.index,
                mark,
            }),
            .add_mark => |v| std.debug.print("  {d}: add_mark({d}, {d}, \"{s}\", \"{s}\"){s}\n", .{
                i,
                v.index,
                v.len,
                v.name.slice(),
                v.value.slice(),
                mark,
            }),
        }
    }
}

test "text: a generated edit history leaves consolidated marks and the right text (text.rs:658-710)" {
    const gpa = testing.allocator;
    // **The two invariants upstream asserts**, in its own order
    // (`tests/text.rs`:683-708): the spans of the document are consolidated,
    // and both the spans and `text` spell the same characters the scenario
    // was supposed to produce.
    //
    // **Three encodings, and `utf8_code_unit` is deliberately not among them**
    // — see [`one_wide_block_encodings`] and the diff block at the bottom of
    // this file. The other three are not three copies of the same run: they
    // are the only three under which this model's index **is** the document's
    // index, and the reference confirms the three agree at every step of the
    // scenario that used to fail here. What `utf8_code_unit` does to a block
    // marker is covered under all four encodings by
    // `test "text_encoding: splitBlock cuts at the place each encoding's index names"`
    // and by
    // `test "text: an empty mark before a block marker does not repeat the text"`.
    //
    // **Sixty-four scenarios over the same four generators**, with a fixed
    // seed. A `proptest` run of the same test explores a different set on
    // every run; this one explores the same set on every run, which is what
    // makes a failure reportable.
    const scenarios = 64;
    var rng = Lcg{ .state = 0x5eed_1234_9abc_def0 };
    for (one_wide_block_encodings) |enc| {
        for (0..scenarios) |which| {
            var actions: std.ArrayList(Action) = .empty;
            defer actions.deinit(gpa);
            try arbScenario(gpa, &rng, &actions);

            var f = try textFixture(gpa, enc, "");
            defer f.deinit();
            var model: std.ArrayList(u8) = .empty;
            defer model.deinit(gpa);

            for (actions.items, 0..) |action, step| {
                switch (action) {
                    .insert => |v| {
                        try trans.spliceText(&f.doc, f.text, v.index, 0, v.value.slice());
                        try model.insertSlice(gpa, v.index, v.value.slice());
                    },
                    .del => |v| {
                        try trans.spliceText(&f.doc, f.text, v.index, @intCast(v.len), "");
                        const end = v.index + v.len;
                        if (end > model.items.len) return error.TestUnexpectedResult;
                        model.replaceRange(gpa, v.index, end, &.{}) catch return error.OutOfMemory;
                    },
                    .split_block => |v| {
                        _ = try trans.splitBlock(&f.doc, f.text, v.index);
                        try model.insert(gpa, v.index, '\n');
                    },
                    .add_mark => |v| {
                        try trans.mark(
                            &f.doc,
                            f.text,
                            v.index,
                            v.index + v.len,
                            v.name.slice(),
                            .both,
                            .{ .str = v.value.slice() },
                        );
                    },
                }
                // **The rendered text against the model, after every action.**
                // That is the check that names the action which went wrong: a
                // check only at the end says the two disagree, and this
                // history has up to ten actions.
                //
                // **The rendered text and not the length, and the reason is
                // that a block marker is not one unit in every encoding.** It
                // is measured as `width("\u{fffc}")` (`op_set.rs:443-447`),
                // which is 1 in code points, UTF-16 units and grapheme
                // clusters and **3 in UTF-8 code units** — U+FFFC is three
                // bytes (`TextEncoding::width`, `text_encoding.rs:184-201`).
                // A model that put one byte where the document counts three
                // would report every `split_block` as a divergence.
                try checkPremises(&f.doc, f.text, enc);
                const raw_now = try text(&f.doc, f.text, gpa);
                defer gpa.free(raw_now);
                const now = try normalizeBlocks(gpa, raw_now);
                defer gpa.free(now);
                if (!std.mem.eql(u8, now, model.items)) {
                    std.debug.print(
                        "encoding {s}, scenario {d}: after action {d} the document reads \"{s}\", the model \"{s}\"\n",
                        .{ @tagName(enc), which, step, now, model.items },
                    );
                    showScenario(actions.items, step);
                    return error.TestExpectedEqual;
                }
            }

            const shapes = try readShapes(gpa, &f.doc, f.text);
            defer freeShapes(gpa, shapes);
            if (!marksAreConsolidated(shapes)) {
                std.debug.print(
                    "encoding {s}, scenario {d}: marks are not consolidated over {d} spans\n",
                    .{ @tagName(enc), which, shapes.len },
                );
                showShapes(shapes);
                showScenario(actions.items, actions.items.len - 1);
                return error.TestExpectedEqual;
            }

            const spelled = try spanChars(gpa, shapes);
            defer gpa.free(spelled);
            if (!std.mem.eql(u8, spelled, model.items)) {
                std.debug.print("encoding {s}, scenario {d}: spans spell \"{s}\", want \"{s}\"\n", .{
                    @tagName(enc),
                    which,
                    spelled,
                    model.items,
                });
                // **The length agreed after every action**, so the actions did
                // not add or drop a character: some action put one in the
                // wrong place, and this is the whole history to look at.
                showScenario(actions.items, actions.items.len - 1);
                return error.TestExpectedEqual;
            }

            const raw = try text(&f.doc, f.text, gpa);
            defer gpa.free(raw);
            const actual = try normalizeBlocks(gpa, raw);
            defer gpa.free(actual);
            if (!std.mem.eql(u8, actual, model.items)) {
                std.debug.print("encoding {s}, scenario {d}: text reads \"{s}\", want \"{s}\"\n", .{
                    @tagName(enc),
                    which,
                    actual,
                    model.items,
                });
                showScenario(actions.items, actions.items.len - 1);
                return error.TestExpectedEqual;
            }
        }
    }
}

test "text: every index agrees with the marks the operations describe (text.rs:1044-1088)" {
    const gpa = testing.allocator;
    // **Four overlapping marks, a fifth that removes part of the first, and a
    // splice past the end** (`tests/text.rs`:1050-1067). The `bold` name is
    // written three times with three different values over three ranges, which
    // is what makes this a test of the fold and not of a list.
    //
    // **The historical half runs on a fork.** Upstream reads the same document
    // at `heads` through `length_at` / `marks_at` / `get_marks(.., Some(&heads))`
    // (`:1079-1087`); this port has no `_at` variants
    // ([`read`]'s module doc, "The `_at` variants"), and
    // [`Document.forkAt`](doc.zig) builds the same state.
    const applied = [_]MarkOp{
        .{ .name = "bold", .start = 0, .end = 9, .value = .{ .bool_value = true } },
        .{ .name = "italic", .start = 4, .end = 15, .value = .{ .bool_value = true } },
        .{ .name = "link", .start = 10, .end = 19, .value = .{ .str = "example" } },
        .{ .name = "bold", .start = 6, .end = 8, .value = .{ .int = 2 } },
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "the quick brown fox");
        defer f.deinit();
        for (applied) |op| {
            try trans.mark(&f.doc, f.text, op.start, op.end, op.name, .none, op.value);
        }
        try checkPremises(&f.doc, f.text, enc);

        const heads = try f.doc.getHeads(gpa);
        defer gpa.free(heads);
        try trans.mark(&f.doc, f.text, 2, 5, "bold", .none, .null_value);
        try trans.spliceText(&f.doc, f.text, 19, 0, " jumps over");
        try checkPremises(&f.doc, f.text, enc);

        // **The fifth operation is a tombstone and not a deletion**, so the
        // model carries it as a mark op with a null value, exactly as the
        // document does.
        var with_removal: std.ArrayList(MarkOp) = .empty;
        defer with_removal.deinit(gpa);
        try with_removal.appendSlice(gpa, &applied);
        try with_removal.append(gpa, .{
            .name = "bold",
            .start = 2,
            .end = 5,
            .value = .null_value,
        });

        var at_heads = try f.doc.forkAt(gpa, heads, .auto);
        defer at_heads.deinit();
        try checkAllIndices(gpa, &f.doc, f.text, with_removal.items, enc, "current");
        try checkAllIndices(gpa, &at_heads, f.text, &applied, enc, "at heads");
    }
}

/// For every index of `doc`'s text object, the window read at that index equals
/// the marks [`modelCovering`] says cover it, and the whole-object read names
/// exactly the names the model puts somewhere.
fn checkAllIndices(
    gpa: Allocator,
    doc: *const Document,
    obj: ExId,
    ops: []const MarkOp,
    enc: TextEncoding,
    when: []const u8,
) !void {
    const len = try length(doc, obj);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    for (0..len + 2) |index| {
        const want = try modelCovering(gpa, ops, index);
        defer gpa.free(want);
        const got = try getMarks(doc, obj, index, index + 1, gpa);
        defer gpa.free(got);
        const pairs = try readPairs(gpa, got);
        defer gpa.free(pairs);
        try expectPairs(pairs, want, index, enc);
        for (want) |p| {
            if (!containsName(names.items, p.name)) try names.append(gpa, try gpa.dupe(u8, p.name));
        }
    }
    // **The whole-object read names exactly the names the model puts
    // somewhere**, which is the part of upstream's comparison that does not
    // depend on how the fold splits a name's coverage into runs.
    const all = try marks(doc, obj, gpa);
    defer gpa.free(all);
    for (all) |m| {
        if (!containsName(names.items, m.name)) {
            std.debug.print("encoding {s}, {s}: marks() names \"{s}\", the model never does\n", .{
                @tagName(enc),
                when,
                m.name,
            });
            return error.TestExpectedEqual;
        }
    }
    for (names.items) |n| {
        var found = false;
        for (all) |m| {
            if (std.mem.eql(u8, m.name, n)) found = true;
        }
        if (!found) {
            std.debug.print("encoding {s}, {s}: the model covers \"{s}\", marks() never names it\n", .{
                @tagName(enc),
                when,
                n,
            });
            return error.TestExpectedEqual;
        }
    }
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn sameNames(a: []const Pair, b: []const Pair) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or !x.value.eql(y.value)) return false;
    }
    return true;
}

test "text: a mark's end is counted in the document's own units (text.rs:1090-1119)" {
    const gpa = testing.allocator;
    // **Upstream already loops over the four encodings** (`tests/text.rs`:
    // :1092-1097), and the loop is the point: one mark over `[1, len)` and one
    // 😀 in the middle give four *different* lengths — 4, 7, 5 and 4 for code
    // points, UTF-8 bytes, UTF-16 units and grapheme clusters — so a reader
    // that counted in the wrong unit puts the mark's end in the wrong place.
    const lengths = EncIdx{
        .unicode_code_point = 4,
        .utf8_code_unit = 7,
        .utf16_code_unit = 5,
        .grapheme_cluster = 4,
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "a\u{1f600}bc");
        defer f.deinit();
        // **Index 1 is the 😀 in all four**, so the mark starts in the same
        // place and only its end moves.
        const want_len = lengths.pick(enc);
        try expectLen(try length(&f.doc, f.text), want_len, enc);
        try expectCharAt(&f.doc, f.text, 1, "\u{1f600}", enc);

        try trans.mark(&f.doc, f.text, 1, want_len, "bold", .none, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);

        const applied = [_]MarkOp{
            .{ .name = "bold", .start = 1, .end = want_len, .value = .{ .bool_value = true } },
        };
        // **One run, over exactly `[1, len)`** — the end is the last index, so
        // a reader that made it `len + 1` would mark past the text.
        const all = try marks(&f.doc, f.text, gpa);
        defer gpa.free(all);
        try expectMarkRuns(all, &.{
            .{ .start = 1, .end = want_len, .name = "bold", .value = .{ .bool_value = true } },
        }, enc);
        try checkAllIndices(gpa, &f.doc, f.text, &applied, enc, "current");
    }
}

test "text: a mark at the end of a long text is found at the end (text.rs:1121-1154)" {
    const gpa = testing.allocator;
    // **210 000 characters, ten times the phrase** (`tests/text.rs`:1125), so
    // the mark is far past the first page of the op tree and the index it is
    // read at is far past the first hundred patches.
    //
    // **The text is pure ASCII, so all four encodings measure it as 210 000
    // units and the encoding does not change any answer here.** The loop is
    // kept because "the same under all four" is a claim worth making, and
    // because `length` is the one place an encoding bug would show.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..10_000) |_| try body.appendSlice(gpa, "the quick brown fox. ");
    try testing.expectEqual(@as(usize, 210_000), body.items.len);

    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, body.items);
        defer f.deinit();
        const len = try length(&f.doc, f.text);
        try expectLen(len, 210_000, enc);
        try trans.mark(&f.doc, f.text, len - 4, len, "bold", .none, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);

        // **Names and values only, and that is upstream's assertion.** Upstream
        // compares `get_marks` — a `MarkSet`, a set of `(name, value)` pairs at
        // one index (`read.rs`:168-173) — with a literal `[("bold", true)]`
        // (`tests/text.rs`:1137-1149). It never looks at the run's range there,
        // because `MarkSet` has none; the range is checked once, on the
        // whole-object read, at the end of this test.
        const want = [_]MarkName{.{
            .name = "bold",
            .value = .{ .bool_value = true },
        }};
        // **The last four positions carry the mark and the one before them
        // does not**, and one past the end does not either — the four
        // assertions of `tests/text.rs`:1137-1153, each of which would pass
        // against a reader that answered "the mark nearest this index".
        for ([_]usize{ len - 1, len - 4 }) |index| {
            const got = try getMarks(&f.doc, f.text, index, index + 1, gpa);
            defer gpa.free(got);
            try expectMarkNames(got, &want, enc);
        }
        for ([_]usize{ len - 5, len }) |index| {
            const got = try getMarks(&f.doc, f.text, index, index + 1, gpa);
            defer gpa.free(got);
            try expectMarkNames(got, &.{}, enc);
        }
        // **The mark really is over the last four positions**, so the four
        // windows above are not all empty by accident.
        const all = try marks(&f.doc, f.text, gpa);
        defer gpa.free(all);
        try expectMarkRuns(all, &.{
            .{ .start = len - 4, .end = len, .name = "bold", .value = .{ .bool_value = true } },
        }, enc);
    }
}

// ── The patch stream ────────────────────────────────────────────────────────
//
// The tests below are the ones whose subject is not a document but the **patch
// stream** a document produces: `Automerge::diff` and `AutoCommit::
// diff_incremental` (`automerge.rs:1419-1457`, `autocommit.rs:255-305`,
// `:340-355`). The port's four methods are [`Document.diff`],
// [`Document.diffObj`], [`Document.diffIncremental`] and
// [`Document.makePatches`] (doc.zig:3976-4123), which is the same surface, and
// every one of them answers with a [`patchesmod.Patches`] the caller frees.
//
// **Every test below asks for the stream through [`Document.diff`] and not
// through [`Document.diffIncremental`], and that is a gap in the port rather
// than a choice.** Upstream's incremental diff reads the events the document
// recorded as it moved (`autocommit.rs:340-355`), and for a **local** edit
// those events come from the branch log the transaction built and the commit
// merged into the document's log (`autocommit.rs:732`). The port's
// `Transaction` has no patch log at all — `transaction.zig:240` says "There
// is no `patch_log` field, because there is no patch log to carry", and
// `transaction.zig:1517` says the same of the `Document`'s own — and the only
// writer of [`Document.patch_log`] is [`Document.applyChanges`]
// (doc.zig:3372-3380). So `updateDiffCursor` followed by a local edit followed
// by `diffIncremental` answers **"nothing changed"**: the log is active, it is
// empty, and [`Document.diffIncremental`]'s first case returns it verbatim
// (doc.zig:4195-4202). All five of the `text_encoding.rs` patch tests measured
// it, and all five read zero patches.
//
// [`Document.diff`] is the same function over the same two points in history,
// so what these tests assert — the shape and the content of the stream a
// reader is handed — is unchanged. What is not exercised is the
// *incremental* code path itself, and that is the gap to close, not something
// a test here can paper over.

/// The index every `tests/text_encoding.rs` patch scenario writes at
/// (`text_encoding.rs:414-419`, `:461-466`, `:507-512`, `:552-557`,
/// `:596-601`).
///
/// **The same four numbers in all five of the file's patch tests**, because
/// all five aim at the same place in the same text — the `l` of `llo`, which
/// follows the 👩‍👩‍👧‍👦 and is the ninth code point, the twenty-seventh UTF-8
/// byte, the thirteenth UTF-16 unit and the third grapheme cluster
/// (`text_encoding.rs:169-181`).
const patch_index = EncIdx{
    .unicode_code_point = 9,
    .utf8_code_unit = 27,
    .utf16_code_unit = 13,
    .grapheme_cluster = 3,
};

/// Prints a patch stream, one line per patch, so a failure names the patches
/// the port produced rather than only the count that was wrong.
fn showPatches(slice: []const patchesmod.Patch) void {
    for (slice, 0..) |p, i| {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(testing.allocator);
        p.action.format(testing.allocator, &body) catch {};
        std.debug.print("  patch {d}: {s}\n", .{ i, body.items });
    }
}

/// The `(name, value)` pairs of a patch's mark set, in name order, so a set
/// read out of a patch can be compared with a literal list of names.
///
/// **Sorted on the way out, because the set is a set.** Upstream's mark
/// payloads are `HashSet<(String, ScalarValue)>`
/// (`text.rs:59-63`, `text_encoding.rs:217-232`) and a `HashSet` has no order,
/// so a test that compared in iteration order would be comparing Rust's hash
/// seed. [`MarkSet`] is name-sorted here ([`marks.MarkSet`]), so the pairs
/// come out in that order and the comparison is by name.
fn patchMarkNames(gpa: Allocator, set: ?marksmod.MarkSet) ![]MarkName {
    const s = set orelse return gpa.alloc(MarkName, 0);
    const out = try gpa.alloc(MarkName, s.entries.items.len);
    for (s.entries.items, out) |e, *o| o.* = .{ .name = e.name, .value = e.value };
    return out;
}

/// Asserts that the mark set a patch carries is exactly `want`, by name and
/// value, in name order ([`expectMarkRuns`]'s contract, on a patch payload).
fn expectPatchMarks(
    got: ?marksmod.MarkSet,
    want: []const MarkName,
    enc: TextEncoding,
    what: []const u8,
) !void {
    const names = try patchMarkNames(testing.allocator, got);
    defer testing.allocator.free(names);
    if (got == null) {
        std.debug.print("encoding {s}: {s} carried no mark set, want {d} mark(s)\n", .{
            @tagName(enc),
            what,
            want.len,
        });
        return error.TestExpectedEqual;
    }
    if (names.len != want.len) {
        std.debug.print("encoding {s}: {s} carried {d} mark(s), want {d}\n", .{
            @tagName(enc),
            what,
            names.len,
            want.len,
        });
        for (names) |n| std.debug.print("  got:  {s} = {any}\n", .{ n.name, n.value });
        for (want) |w| std.debug.print("  want: {s} = {any}\n", .{ w.name, w.value });
        return error.TestExpectedEqual;
    }
    for (names, want) |g, w| {
        if (!std.mem.eql(u8, g.name, w.name) or !g.value.eql(w.value)) {
            std.debug.print("encoding {s}: {s} carried {s} = {any}, want {s} = {any}\n", .{
                @tagName(enc),
                what,
                g.name,
                g.value,
                w.name,
                w.value,
            });
            return error.TestExpectedEqual;
        }
    }
}

/// Two patch streams, patch for patch, by object, by path length and by
/// action content ([`patchesmod.PatchAction.eql`]).
///
/// **Upstream compares whole `Patch` values with `assert_eq!`**
/// (`text.rs:641`), and a derived `PartialEq` on a struct of slices and
/// vectors is a content comparison. `Patch` has no `eql` of its own — the
/// actions are the part that is a value — so the object and the path are
/// checked here and the actions by the patch layer's own comparison.
fn patchStreamEql(a: []const patchesmod.Patch, b: []const patchesmod.Patch) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.obj.eql(y.obj)) return false;
        if (x.path.len != y.path.len) return false;
        if (!patchesmod.PatchAction.eql(x.action, y.action)) return false;
    }
    return true;
}

test "text_encoding: a put arrives as a delete and a splice at the same index (text_encoding.rs:409-454)" {
    const gpa = testing.allocator;
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const index = patch_index.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);

        const before = try f.doc.getHeads(gpa);
        defer gpa.free(before);
        _ = try trans.put(&f.doc, f.text, .{ .index = index }, .{ .str = "L" });
        try checkPremises(&f.doc, f.text, enc);
        const after = try f.doc.getHeads(gpa);
        defer gpa.free(after);

        var patches = try f.doc.diff(gpa, before, after);
        defer patches.deinit();
        // **Exactly two patches, a delete and then a splice, and the two
        // indexes are the same** (`text_encoding.rs:424-441`). A put into a
        // text object is a delete of the old character followed by an insert
        // of the new one, because a text element can be wider than one unit
        // (`patch_log.rs:411-436`).
        if (patches.slice().len != 2) {
            std.debug.print("encoding {s}: {d} patch(es), want 2\n", .{
                @tagName(enc),
                patches.slice().len,
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        const del = switch (patches.slice()[0].action) {
            .delete_seq => |a| a,
            else => {
                std.debug.print("encoding {s}: patch 0 is {s}, want a delete\n", .{
                    @tagName(enc),
                    @tagName(patches.slice()[0].action),
                });
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            },
        };
        const ins = switch (patches.slice()[1].action) {
            .splice_text => |a| a,
            else => {
                std.debug.print("encoding {s}: patch 1 is {s}, want a splice\n", .{
                    @tagName(enc),
                    @tagName(patches.slice()[1].action),
                });
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            },
        };
        if (del.length != 1) {
            std.debug.print("encoding {s}: the delete removed {d} unit(s), want 1\n", .{
                @tagName(enc),
                del.length,
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        if (del.index != ins.index) {
            std.debug.print("encoding {s}: the delete is at {d} and the splice at {d}\n", .{
                @tagName(enc),
                del.index,
                ins.index,
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        try expectText(ins.value.asStr(), "L", enc);
    }
}

test "text_encoding: an insert arrives as one splice at the index it was made at (text_encoding.rs:456-499)" {
    const gpa = testing.allocator;
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const index = patch_index.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);

        const before = try f.doc.getHeads(gpa);
        defer gpa.free(before);
        _ = try trans.insert(&f.doc, f.text, index, .{ .str = "L" });
        try checkPremises(&f.doc, f.text, enc);
        const after = try f.doc.getHeads(gpa);
        defer gpa.free(after);

        var patches = try f.doc.diff(gpa, before, after);
        defer patches.deinit();
        // **One patch, and it is a splice carrying `L`**
        // (`text_encoding.rs:469-489`).
        if (patches.slice().len != 1) {
            std.debug.print("encoding {s}: {d} patch(es), want 1\n", .{
                @tagName(enc),
                patches.slice().len,
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        const one = switch (patches.slice()[0].action) {
            .splice_text => |a| a,
            else => {
                std.debug.print("encoding {s}: the one patch is {s}, want a splice\n", .{
                    @tagName(enc),
                    @tagName(patches.slice()[0].action),
                });
                return error.TestExpectedEqual;
            },
        };
        try expectText(one.value.asStr(), "L", enc);
        if (one.index != index) {
            std.debug.print("encoding {s}: the splice is at {d}, want the index it was made at {d}\n", .{
                @tagName(enc),
                one.index,
                index,
            });
            return error.TestExpectedEqual;
        }
    }
}

test "text_encoding: a splice arrives as one splice at the index it was made at (text_encoding.rs:501-544)" {
    const gpa = testing.allocator;
    // **The same assertion as the insert case, and deliberately both.**
    // `insert` and `splice_text` with a zero delete are two spellings of one
    // edit (`transactable.rs:88-101`), and upstream keeps a test for each; a
    // port that merged them would have proved one of the two.
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const index = patch_index.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);

        const before = try f.doc.getHeads(gpa);
        defer gpa.free(before);
        try trans.spliceText(&f.doc, f.text, index, 0, "L");
        try checkPremises(&f.doc, f.text, enc);
        const after = try f.doc.getHeads(gpa);
        defer gpa.free(after);

        var patches = try f.doc.diff(gpa, before, after);
        defer patches.deinit();
        if (patches.slice().len != 1) {
            std.debug.print("encoding {s}: {d} patch(es), want 1\n", .{
                @tagName(enc),
                patches.slice().len,
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        const one = switch (patches.slice()[0].action) {
            .splice_text => |a| a,
            else => {
                std.debug.print("encoding {s}: the one patch is {s}, want a splice\n", .{
                    @tagName(enc),
                    @tagName(patches.slice()[0].action),
                });
                return error.TestExpectedEqual;
            },
        };
        try expectText(one.value.asStr(), "L", enc);
        if (one.index != index) {
            std.debug.print("encoding {s}: the splice is at {d}, want the index it was made at {d}\n", .{
                @tagName(enc),
                one.index,
                index,
            });
            return error.TestExpectedEqual;
        }
    }
}

test "text_encoding: a delete arrives as one delete of one element (text_encoding.rs:546-589)" {
    const gpa = testing.allocator;
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const index = patch_index.pick(enc);
        try expectCharAt(&f.doc, f.text, index, "l", enc);

        const before = try f.doc.getHeads(gpa);
        defer gpa.free(before);
        _ = try trans.delete(&f.doc, f.text, .{ .index = index });
        try checkPremises(&f.doc, f.text, enc);
        const after = try f.doc.getHeads(gpa);
        defer gpa.free(after);

        var patches = try f.doc.diff(gpa, before, after);
        defer patches.deinit();
        // **One patch, a delete, of length one** (`text_encoding.rs:559-579`).
        // The index is the same four numbers: the delete is reported at the
        // index the character occupied, in the document's own units.
        if (patches.slice().len != 1) {
            std.debug.print("encoding {s}: {d} patch(es), want 1\n", .{
                @tagName(enc),
                patches.slice().len,
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        const one = switch (patches.slice()[0].action) {
            .delete_seq => |a| a,
            else => {
                std.debug.print("encoding {s}: the one patch is {s}, want a delete\n", .{
                    @tagName(enc),
                    @tagName(patches.slice()[0].action),
                });
                return error.TestExpectedEqual;
            },
        };
        if (one.length != 1) {
            std.debug.print("encoding {s}: the delete removed {d} unit(s), want 1\n", .{
                @tagName(enc),
                one.length,
            });
            return error.TestExpectedEqual;
        }
        if (one.index != index) {
            std.debug.print("encoding {s}: the delete is at {d}, want the index it was made at {d}\n", .{
                @tagName(enc),
                one.index,
                index,
            });
            return error.TestExpectedEqual;
        }
    }
}

test "text_encoding: a mark arrives as one mark patch spanning the range (text_encoding.rs:591-639)" {
    const gpa = testing.allocator;
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "he👩‍👩‍👧‍👦llo");
        defer f.deinit();
        const end_index = patch_index.pick(enc);
        try expectCharAt(&f.doc, f.text, 1, "e", enc);

        const before = try f.doc.getHeads(gpa);
        defer gpa.free(before);
        try trans.mark(&f.doc, f.text, 1, end_index, "bold", .both, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);
        const after = try f.doc.getHeads(gpa);
        defer gpa.free(after);

        var patches = try f.doc.diff(gpa, before, after);
        defer patches.deinit();
        // **One patch about this object, a `Mark`, carrying one mark named
        // `bold`** (`text_encoding.rs:605-629`). The filter upstream applies is
        // `p.obj == *text`, and the port keeps it: a `Mark` patch about a
        // different object would be a different answer, not a longer stream.
        var seen: usize = 0;
        var the_mark: ?Mark = null;
        for (patches.slice()) |p| {
            if (!p.obj.eql(f.text)) continue;
            const m = switch (p.action) {
                .mark => |a| a,
                else => {
                    std.debug.print("encoding {s}: a patch about the text object is {s}, want a mark\n", .{
                        @tagName(enc),
                        @tagName(p.action),
                    });
                    showPatches(patches.slice());
                    return error.TestExpectedEqual;
                },
            };
            if (m.marks.len != 1) {
                std.debug.print("encoding {s}: the mark patch carries {d} mark(s), want 1\n", .{
                    @tagName(enc),
                    m.marks.len,
                });
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            }
            if (!std.mem.eql(u8, m.marks[0].name, "bold")) {
                std.debug.print("encoding {s}: the mark is named \"{s}\", want \"bold\"\n", .{
                    @tagName(enc),
                    m.marks[0].name,
                });
                return error.TestExpectedEqual;
            }
            the_mark = m.marks[0];
            seen += 1;
        }
        if (seen != 1) {
            std.debug.print("encoding {s}: {d} mark patch(es) about the text object, want 1\n", .{
                @tagName(enc),
                seen,
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        // **The range, in the document's own units, and the start is 1 in all
        // four** — the mark begins before the `e`, which is the first
        // character after the `h`.
        if (the_mark.?.start != 1 or the_mark.?.end != end_index) {
            std.debug.print("encoding {s}: the mark covers [{d}, {d}), want [1, {d})\n", .{
                @tagName(enc),
                the_mark.?.start,
                the_mark.?.end,
                end_index,
            });
            return error.TestExpectedEqual;
        }
    }
}

test "text: a splice inside a mark carries that mark in its patch (text.rs:84-141)" {
    const gpa = testing.allocator;
    // **The bug this reproduces**: a splice that hits the `can_shortcut_search`
    // optimisation produced a patch with the marks missing
    // (`tests/text.rs:86-87`). The two splices are at index 1 and then index 2,
    // and the mark covers `[1, 2)`, so the first is at the mark's start and the
    // second at its end — and with `ExpandMark::Both` the mark's own end
    // expands, so the second insert is inside it too.
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "12345");
        defer f.deinit();
        try trans.mark(&f.doc, f.text, 1, 2, "strong", .both, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);

        const want = [_]MarkName{.{ .name = "strong", .value = .{ .bool_value = true } }};
        // **The two indexes are 1 and 2 in all four encodings, and that is a
        // fact and not an accident**: `"12345"` is five code points, five
        // UTF-8 bytes, five UTF-16 units and five grapheme clusters, so the
        // mark over `[1, 2)` is the same range whichever unit it is counted
        // in.
        // **The two characters either side of each insertion point, and they
        // are the same two for both steps.** Step one inserts at index 1 of
        // `"12345"`, so `2` is at 1 and `3` at 2. Step two runs on `"-12345"`,
        // so `2` is at 2 and `3` at 3. The rule "`2` is at `index` and `3` is
        // at `index + 1`" is what both satisfy, and it is stated rather than
        // tabulated so the second step cannot be off by the first step's edit.
        for ([_]usize{ 1, 2 }) |index| {
            try expectCharAt(&f.doc, f.text, index, "2", enc);
            try expectCharAt(&f.doc, f.text, index + 1, "3", enc);
            const before = try f.doc.getHeads(gpa);
            defer gpa.free(before);
            try trans.spliceText(&f.doc, f.text, index, 0, "-");
            try checkPremises(&f.doc, f.text, enc);
            const after = try f.doc.getHeads(gpa);
            defer gpa.free(after);

            var patches = try f.doc.diff(gpa, before, after);
            defer patches.deinit();
            // **Upstream asserts one patch; a heads diff answers two, and the
            // difference is the `diffIncremental` gap this section's header
            // names — not a mark that went missing.** Upstream reads the
            // *recorded* events, so it sees the splice and nothing else; a
            // walk over two heads recomputes the marks for the whole object
            // and also reports that the mark's range moved from `[1, 2)` to
            // `[2, 3)`, because the `-` landed at its start. The port answers:
            //
            // ```
            // patch 0: SpliceText { index: 1, value: "-", marks: {strong=Bool(true)} }
            // patch 1: Mark { marks: [{ name: "strong", value: Bool(true), start: 2, end: 3 }] }
            // ```
            //
            // **The splice patch carries `strong`, which is the whole point of
            // upstream's test** (`text.rs:85-87`: the shortcut dropped the
            // marks). So the mark assertion below is the one with teeth, and
            // the patch **count** is the assertion that cannot be met until
            // `Document.diffIncremental` reads a local edit. **Left red on
            // purpose**: the fix is the missing patch log, not this test, and
            // the reference's own stream for this fixture is the oracle's
            // business to settle once that log exists.
            if (patches.slice().len != 1) {
                std.debug.print("encoding {s}, index {d}: {d} patch(es), want 1\n", .{
                    @tagName(enc),
                    index,
                    patches.slice().len,
                });
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            }
            const one = switch (patches.slice()[0].action) {
                .splice_text => |a| a,
                else => {
                    std.debug.print("encoding {s}, index {d}: the one patch is {s}, want a splice\n", .{
                        @tagName(enc),
                        index,
                        @tagName(patches.slice()[0].action),
                    });
                    return error.TestExpectedEqual;
                },
            };
            if (one.index != index) {
                std.debug.print("encoding {s}: the splice is at {d}, want {d}\n", .{
                    @tagName(enc),
                    one.index,
                    index,
                });
                return error.TestExpectedEqual;
            }
            try expectText(one.value.asStr(), "-", enc);
            try expectPatchMarks(one.marks, &want, enc, "the splice patch");
        }
    }
}

test "text: a mark that expands is reported on the inserts that expand it (text.rs:542-612)" {
    const gpa = testing.allocator;
    // **Two splices, one at each end of the mark, and `ExpandMark::Both`**
    // (`tests/text.rs:546-551`): the mark covers `[3, 6)` of `aaabbbccc`, so
    // the insert at 6 lands after the mark's end and the insert at 3 before its
    // start, and `Both` means both of those are inside the mark afterwards.
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "aaabbbccc");
        defer f.deinit();
        try trans.mark(&f.doc, f.text, 3, 6, "strong", .both, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);

        const want = [_]MarkName{.{ .name = "strong", .value = .{ .bool_value = true } }};
        const steps = [_]struct { index: usize, text: []const u8 }{
            .{ .index = 6, .text = "<" },
            .{ .index = 3, .text = ">" },
        };
        for (steps) |step| {
            const before = try f.doc.getHeads(gpa);
            defer gpa.free(before);
            try trans.spliceText(&f.doc, f.text, step.index, 0, step.text);
            try checkPremises(&f.doc, f.text, enc);
            const after = try f.doc.getHeads(gpa);
            defer gpa.free(after);

            var patches = try f.doc.diff(gpa, before, after);
            defer patches.deinit();
            if (patches.slice().len != 1) {
                std.debug.print("encoding {s}, index {d}: {d} patch(es), want 1\n", .{
                    @tagName(enc),
                    step.index,
                    patches.slice().len,
                });
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            }
            const one = switch (patches.slice()[0].action) {
                .splice_text => |a| a,
                else => {
                    std.debug.print("encoding {s}, index {d}: the one patch is {s}, want a splice\n", .{
                        @tagName(enc),
                        step.index,
                        @tagName(patches.slice()[0].action),
                    });
                    return error.TestExpectedEqual;
                },
            };
            if (one.index != step.index) {
                std.debug.print("encoding {s}: the splice is at {d}, want {d}\n", .{
                    @tagName(enc),
                    one.index,
                    step.index,
                });
                return error.TestExpectedEqual;
            }
            try expectText(one.value.asStr(), step.text, enc);
            try expectPatchMarks(one.marks, &want, enc, "the splice patch");
        }
    }
}

test "text: a noexpand mark at the end does not mark a later insertion (text.rs:504-540)" {
    const gpa = testing.allocator;
    // **The mark ends at the last character and does not expand**
    // (`tests/text.rs:508-522`), so an insertion at the end of the text lands
    // after the mark's end anchor and must not carry it. A reader that treated
    // the mark as still open would report it.
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "Hello world");
        defer f.deinit();
        try trans.mark(&f.doc, f.text, 10, 11, "strong", .none, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);
        // **The mark really is where it says it is**, so the insertion below is
        // not passing by accident.
        const live = try marks(&f.doc, f.text, gpa);
        defer gpa.free(live);
        try expectMarkRuns(live, &.{
            .{ .start = 10, .end = 11, .name = "strong", .value = .{ .bool_value = true } },
        }, enc);

        const before = try f.doc.getHeads(gpa);
        defer gpa.free(before);
        try trans.spliceText(&f.doc, f.text, 11, 0, "a");
        try checkPremises(&f.doc, f.text, enc);
        const after = try f.doc.getHeads(gpa);
        defer gpa.free(after);

        var patches = try f.doc.diff(gpa, before, after);
        defer patches.deinit();
        // **One patch, a splice, with no mark set at all** (`text.rs:530-539`).
        if (patches.slice().len != 1) {
            std.debug.print("encoding {s}: {d} patch(es), want 1\n", .{
                @tagName(enc),
                patches.slice().len,
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        const one = switch (patches.slice()[0].action) {
            .splice_text => |a| a,
            else => {
                std.debug.print("encoding {s}: the one patch is {s}, want a splice\n", .{
                    @tagName(enc),
                    @tagName(patches.slice()[0].action),
                });
                return error.TestExpectedEqual;
            },
        };
        if (one.marks != null) {
            std.debug.print("encoding {s}: the splice patch carried a mark set, want none\n", .{
                @tagName(enc),
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
    }
}

test "text: a mark that crosses an op-tree page is not counted twice (text.rs:417-502)" {
    const gpa = testing.allocator;
    // **The bug this reproduces** is a mark that had ended much earlier
    // suddenly appearing on characters far after it (`tests/text.rs:419-422`),
    // caused by the insert query skipping a node whose `mark_end` index it
    // resolved to the wrong operation (`text.rs:444-457`: it removed
    // `index.mark_end` entries by id where the map was keyed by the id of the
    // **begin**, so the removal had to be `id.prev()`).
    //
    // **Thirty-two characters so the mark straddles two pages of the op tree**
    // — `B` is 16 (`text.rs:11`) and the page holds sixteen rows — and then a
    // hundred insertions at the end, each preceded by a block marker so the
    // document keeps growing and the target stays past the mark.
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "");
        defer f.deinit();
        var one_page: std.ArrayList(u8) = .empty;
        defer one_page.deinit(gpa);
        for (0..32) |_| try one_page.append(gpa, 'a');
        try trans.spliceText(&f.doc, f.text, 0, 0, one_page.items);
        try trans.mark(&f.doc, f.text, 15, 17, "strong", .none, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);

        for (0..100) |round| {
            const len = try length(&f.doc, f.text);
            _ = try trans.splitBlock(&f.doc, f.text, len);
            try checkPremises(&f.doc, f.text, enc);
            const grown = try length(&f.doc, f.text);
            const before = try f.doc.getHeads(gpa);
            defer gpa.free(before);
            try trans.spliceText(&f.doc, f.text, grown, 0, "a");
            try checkPremises(&f.doc, f.text, enc);
            const after = try f.doc.getHeads(gpa);
            defer gpa.free(after);

            var patches = try f.doc.diff(gpa, before, after);
            defer patches.deinit();
            // **One patch, a splice, and no marks** (`text.rs:486-500`). The
            // insertion is past the mark's end, which ended two characters
            // after it began.
            if (patches.slice().len != 1) {
                std.debug.print("encoding {s}, round {d}: {d} patch(es), want 1\n", .{
                    @tagName(enc),
                    round,
                    patches.slice().len,
                });
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            }
            const one = switch (patches.slice()[0].action) {
                .splice_text => |a| a,
                else => {
                    std.debug.print("encoding {s}, round {d}: the one patch is {s}, want a splice\n", .{
                        @tagName(enc),
                        round,
                        @tagName(patches.slice()[0].action),
                    });
                    return error.TestExpectedEqual;
                },
            };
            if (one.marks != null) {
                std.debug.print(
                    "encoding {s}, round {d}: the splice past the mark's end carried a mark set, want none\n",
                    .{ @tagName(enc), round },
                );
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            }
        }
    }
}

test "text: a remote mark with expand-after arrives as the same patches as the local one (text.rs:614-642)" {
    const gpa = testing.allocator;
    // **The two streams must be equal, not merely similar**
    // (`tests/text.rs:641`): a reader that computed the marks of an inserted
    // character differently for a merge than for a local edit would pass every
    // test above this one and fail this one.
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "fox");
        defer f.deinit();
        try trans.mark(&f.doc, f.text, 0, 3, "strong", .after, .{ .bool_value = true });
        try checkPremises(&f.doc, f.text, enc);

        // **A fork, not a clone of the bytes**: the merge has to be a real
        // merge, and `clone` plus a named actor is the port's `fork` — see
        // `test "text: updateText over a fork converges on the fork's text"`.
        var other = try f.doc.clone(gpa, .auto);
        defer other.deinit();
        other.setActorId(.{ .bytes = "bbbbbbbb" });

        const before_a = try f.doc.getHeads(gpa);
        defer gpa.free(before_a);
        try trans.spliceText(&f.doc, f.text, 3, 0, "a");
        try checkPremises(&f.doc, f.text, enc);
        const after_a = try f.doc.getHeads(gpa);
        defer gpa.free(after_a);

        const before_b = try other.getHeads(gpa);
        defer gpa.free(before_b);
        const merged = try other.merge(gpa, &f.doc);
        defer gpa.free(merged);
        try checkPremises(&other, f.text, enc);
        const after_b = try other.getHeads(gpa);
        defer gpa.free(after_b);

        var local = try f.doc.diff(gpa, before_a, after_a);
        defer local.deinit();
        var remote = try other.diff(gpa, before_b, after_b);
        defer remote.deinit();
        if (!patchStreamEql(local.slice(), remote.slice())) {
            std.debug.print("encoding {s}: the local and the remote stream differ\nlocal:\n", .{
                @tagName(enc),
            });
            showPatches(local.slice());
            std.debug.print("remote:\n", .{});
            showPatches(remote.slice());
            return error.TestExpectedEqual;
        }
    }
}

test "text: three marks over one sentence come back as five splices with their marks (text.rs:163-295)" {
    const gpa = testing.allocator;
    // **The whole of upstream's expected stream, and it is the longest
    // expectation in either file** (`tests/text.rs:198-294`): the text object
    // itself, then five splices whose marks are exactly the three marks'
    // coverage at each point. A fold that put `bold` on the first four
    // characters and nothing else would pass every shorter test here.
    const comment = "comment:somerandomcommentid";
    const applied = [_]struct { name: []const u8, start: usize, end: usize, value: ScalarValue }{
        .{ .name = "bold", .start = 0, .end = 37, .value = .{ .bool_value = true } },
        .{ .name = "italic", .start = 4, .end = 19, .value = .{ .bool_value = true } },
        .{
            .name = comment,
            .start = 10,
            .end = 13,
            .value = .{ .str = "foxes are my favorite animal!" },
        },
    };
    for (all_encodings) |enc| {
        var f = try textFixture(gpa, enc, "the quick fox jumps over the lazy dog");
        defer f.deinit();
        for (applied) |m| {
            try trans.mark(&f.doc, f.text, m.start, m.end, m.name, .both, m.value);
        }
        try checkPremises(&f.doc, f.text, enc);

        const heads = try f.doc.getHeads(gpa);
        defer gpa.free(heads);
        // **From nothing to the present**, which is what an incremental diff
        // on a document whose cursor was never set answers
        // ([`Document.diffIncremental`]'s second case, `autocommit.rs:288-296`).
        var patches = try f.doc.diff(gpa, &.{}, heads);
        defer patches.deinit();
        if (patches.slice().len != 6) {
            std.debug.print("encoding {s}: {d} patch(es), want 6\n", .{
                @tagName(enc),
                patches.slice().len,
            });
            showPatches(patches.slice());
            return error.TestExpectedEqual;
        }

        // **Patch 0 is the text object itself, at the root under `text`**
        // (`text.rs:199-210`).
        {
            const p = patches.slice()[0];
            if (!p.obj.eql(.root)) {
                std.debug.print("encoding {s}: patch 0 is about {any}, want the root\n", .{
                    @tagName(enc),
                    p.obj,
                });
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            }
            const put = switch (p.action) {
                .put_map => |a| a,
                else => {
                    std.debug.print("encoding {s}: patch 0 is {s}, want a map put\n", .{
                        @tagName(enc),
                        @tagName(p.action),
                    });
                    showPatches(patches.slice());
                    return error.TestExpectedEqual;
                },
            };
            if (!std.mem.eql(u8, put.key, "text")) {
                std.debug.print("encoding {s}: the object is at \"{s}\", want \"text\"\n", .{
                    @tagName(enc),
                    put.key,
                });
                return error.TestExpectedEqual;
            }
            if (put.conflict) {
                std.debug.print("encoding {s}: the object put is a conflict, want a clean one\n", .{
                    @tagName(enc),
                });
                return error.TestExpectedEqual;
            }
        }

        // **The five splices, in order, with the marks each one carries**
        // (`text.rs:211-291`). **Every `marks` list is in *name* order, and
        // that is not a choice:** a [`MarkSet`](marks.zig) holds its entries
        // sorted by name ([`MarkSet`]'s module doc, and the reason
        // [`expectPatchMarks`] can compare them positionally at all), so
        // `{bold, italic, comment:…}` names the same set as
        // `{bold, comment:…, italic}` and the *list* is a different order
        // than the set it names.
        //
        // Upstream's own literal for the `fox` splice lists them
        // `bold`, `comment:`, `italic` in that order
        // ([`text.rs`:243-258](../../../github-automerge-automerge/rust/automerge/tests/text.rs)),
        // which is upstream's `HashSet` order and happens to be the name
        // order too. **Listing the three the other way round was the whole
        // of [docs/STATUS.md](docs/STATUS.md)'s one failing text case.**
        const bold = MarkName{ .name = "bold", .value = .{ .bool_value = true } };
        const italic = MarkName{ .name = "italic", .value = .{ .bool_value = true } };
        const cmt = MarkName{ .name = comment, .value = .{ .str = "foxes are my favorite animal!" } };
        const want = [_]struct { index: usize, text: []const u8, marks: []const MarkName }{
            .{ .index = 0, .text = "the ", .marks = &.{bold} },
            .{ .index = 4, .text = "quick ", .marks = &.{ bold, italic } },
            .{ .index = 10, .text = "fox", .marks = &.{ bold, cmt, italic } },
            .{ .index = 13, .text = " jumps", .marks = &.{ bold, italic } },
            .{ .index = 19, .text = " over the lazy dog", .marks = &.{bold} },
        };
        for (want, 1..) |w, i| {
            const p = patches.slice()[i];
            if (!p.obj.eql(f.text)) {
                std.debug.print("encoding {s}: patch {d} is about {any}, want the text object\n", .{
                    @tagName(enc),
                    i,
                    p.obj,
                });
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            }
            const one = switch (p.action) {
                .splice_text => |a| a,
                else => {
                    std.debug.print("encoding {s}: patch {d} is {s}, want a splice\n", .{
                        @tagName(enc),
                        i,
                        @tagName(p.action),
                    });
                    showPatches(patches.slice());
                    return error.TestExpectedEqual;
                },
            };
            if (one.index != w.index) {
                std.debug.print("encoding {s}: patch {d} splices at {d}, want {d}\n", .{
                    @tagName(enc),
                    i,
                    one.index,
                    w.index,
                });
                showPatches(patches.slice());
                return error.TestExpectedEqual;
            }
            try expectText(one.value.asStr(), w.text, enc);
            try expectPatchMarks(
                one.marks,
                w.marks,
                enc,
                "the splice patch",
            );
        }
    }
}

// ── The mirror, and the scope it is built at ─────────────────────────────────

/// What the four comparison helpers below raise.
///
/// **Named and not inferred, and the reason is the recursion.** They call each
/// other — [`expectMirroredValue`] dispatches on the object's type and
/// [`expectMirroredMap`] calls back into it for every register — so an
/// inferred set is a cycle the compiler resolves by refusing
/// (`error: dependency loop with length 2`). **The set is [`HydrateError`]
/// because that is every reader the helpers call**, plus the two
/// `std.testing` refusals they raise themselves.
const MirrorError = HydrateError || error{ TestExpectedEqual, TestUnexpectedResult };

/// A mirror value that is not the kind asked for.
const MirrorKindError = error{TestUnexpectedResult};

/// The map inside a mirror value, or a refusal.
///
/// **Captured by pointer and not by value**: a `Value` embeds its `Map` in the
/// `object` arm by value, so a `|x|` capture would copy the container and hand
/// back a pointer into a dead frame.
fn mirrorMap(v: *const hydmod.Value) MirrorKindError!*const hydmod.Map {
    const o: *const hydmod.Object = switch (v.*) {
        .object => |*x| x,
        else => return error.TestUnexpectedResult,
    };
    return switch (o.*) {
        .map => |*m| m,
        else => return error.TestUnexpectedResult,
    };
}

/// The text object inside a mirror value, or a refusal. See [`mirrorMap`].
fn mirrorText(v: *const hydmod.Value) MirrorKindError!*const hydmod.Text {
    const o: *const hydmod.Object = switch (v.*) {
        .object => |*x| x,
        else => return error.TestUnexpectedResult,
    };
    return switch (o.*) {
        .text => |*t| t,
        else => return error.TestUnexpectedResult,
    };
}

/// The list inside a mirror value, or a refusal. See [`mirrorMap`].
fn mirrorList(v: *const hydmod.Value) MirrorKindError!*const hydmod.List {
    const o: *const hydmod.Object = switch (v.*) {
        .object => |*x| x,
        else => return error.TestUnexpectedResult,
    };
    return switch (o.*) {
        .list => |*l| l,
        else => return error.TestUnexpectedResult,
    };
}

/// **Every register of a map mirror, against the readers, one at a time.**
///
/// This is what makes the test an assertion and not a measurement: the counts
/// are compared first, so a mirror that is merely non-empty fails here, and
/// then every key and every value is compared against a **second, independent**
/// answer — the readers below.
fn expectMirroredMap(
    gpa: Allocator,
    doc: *const Document,
    obj: ExId,
    m: *const hydmod.Map,
) MirrorError!void {
    // **The key set, by count and in both directions.** `keys` is a winner
    // walk and a delete is a successor edge and not a row
    // ([`keys`]'s doc), so a mirror that walked shadows rather than winners
    // would still be holding the deleted key here.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    {
        // **The walk is drained and dropped inside this block, and that is
        // load-bearing.** A `Keys` walk borrows the op set's shared successor
        // buffer and top scratch ([op_set.zig:40-49](../opset/op_set.zig)), so
        // the recursion below — which opens walks of its own — must not run
        // while one is live. The keys are the document's interned bytes and
        // outlive the walk ([`keys`]'s doc), so collecting them costs nothing.
        var walk = try keys(doc, obj);
        defer walk.deinit(doc.allocator());
        while (try walk.next()) |k| try names.append(gpa, k);
    }
    try testing.expectEqual(names.items.len, m.count());
    try testing.expectEqual(names.items.len, try length(doc, obj));
    for (names.items) |k| try testing.expect(m.get(k) != null);

    var it = m.entries.iterator();
    while (it.next()) |entry| {
        const mv = entry.value_ptr;
        const key = entry.key_ptr.*;
        // **The conflict flag is the register's visible-row count.**
        // `MapValue::new(value, id, conflict)` takes it ([`hydrate/map.rs`:81])
        // and upstream hands it `top.conflict` (`hydrate.rs:254`), which holds
        // exactly when more than one row of the register is visible — the same
        // thing `getAll` counts here. **A mirror that reported `false` for a
        // conflicted register, or `true` for a clean one, fails on this line
        // and nowhere else.**
        const all = try getAll(doc, obj, .{ .key = key }, gpa);
        defer gpa.free(all);
        try testing.expectEqual(all.len > 1, mv.conflict);
        const winner_val = try get(doc, obj, .{ .key = key }) orelse
            return error.TestUnexpectedResult;
        try expectMirroredValue(gpa, doc, winner_val, &mv.value);
    }
}

/// **Every element of a list mirror, in order, against the reader.**
fn expectMirroredList(
    gpa: Allocator,
    doc: *const Document,
    obj: ExId,
    l: *const hydmod.List,
) MirrorError!void {
    // A list is counted over its distinct visible insert positions ([`length`]'s
    // doc) and the mirror counts elements, so the two counts agree.
    try testing.expectEqual(try length(doc, obj), l.count());
    for (0..l.count()) |i| {
        // **One index at a time, and the walk is read out before the
        // recursion.** A `ListRange` allocates nothing ([`listRange`]'s doc)
        // and borrows the op set's rows, so this is drained to its single
        // element and confirmed to hold exactly one before anything below
        // reads through the document again.
        var walk = try listRange(doc, obj, .{ .start = i, .end = i + 1 });
        const item = (try walk.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(i, item.index);
        try testing.expect((try walk.next()) == null);
        // **By index, so a mirror whose list came back in any other order
        // fails here** — the mirror is a sequence, not a set.
        const element = l.get(i) orelse return error.TestUnexpectedResult;
        const all = try getAll(doc, obj, .{ .index = i }, gpa);
        defer gpa.free(all);
        try testing.expectEqual(all.len > 1, item.conflict);
        try expectMirroredValue(gpa, doc, .{
            .value = item.value,
            .id = item.maybe_exid.exid(),
        }, element);
    }
}

/// **A text mirror's characters and its marks, against the readers.**
fn expectMirroredText(
    gpa: Allocator,
    doc: *const Document,
    obj: ExId,
    t: *const hydmod.Text,
) MirrorError!void {
    const got = try text(doc, obj, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings(got, t.asStr());
    // **The count is in the document's own encoding**, which is the encoding
    // the mirror was built in, so the two must agree unit for unit.
    try testing.expectEqual(try length(doc, obj), t.count());

    // **Marks by name, in both directions.** The mirror's field is a
    // name → value set and holds no span at all ([`Text`]'s doc over
    // `hydrate/text.rs:10`), so `marks` is what says where — and the reader's
    // own non-emptiness is asserted first, because **a mirror carrying no
    // marks and a reader reporting none would satisfy the first loop alone.**
    const runs = try marks(doc, obj, gpa);
    defer gpa.free(runs);
    try testing.expect(runs.len > 0);
    var held = t.marks.iter();
    while (held.next()) |entry| {
        var seen = false;
        for (runs) |run| {
            if (!std.mem.eql(u8, run.name, entry.name)) continue;
            seen = true;
            try testing.expect(entry.value.eql(run.value));
        }
        try testing.expect(seen);
    }
    for (runs) |run| {
        var seen = false;
        var again = t.marks.iter();
        while (again.next()) |entry| {
            if (!std.mem.eql(u8, entry.name, run.name)) continue;
            seen = true;
            break;
        }
        try testing.expect(seen);
    }
}

/// **One value of a mirror against one value the readers report.**
///
/// **Scalars by type and by payload** — [`Value.eql`] compares the union tag
/// first ([`hydrate.zig`](hydrate.zig):630), so a scalar where the mirror
/// holds an object, or the wrong arm of a tagged union, fails here rather than
/// comparing payload bytes. **Objects by their id and then by their contents**,
/// which is what makes the check recursive.
fn expectMirroredValue(
    gpa: Allocator,
    doc: *const Document,
    got: DocItem,
    want: *const hydmod.Value,
) MirrorError!void {
    switch (got.value) {
        .scalar => |s| {
            // **`fromScalar` is the reader's answer in the mirror's own
            // type** and it borrows, which is safe: both live only as long as
            // the document and nothing here mutates it.
            const held = hydmod.Value.fromScalar(s);
            try testing.expect(want.eql(&held));
        },
        .object => |typ| {
            // **For an object the register's id is the make's id** ([`get`]'s
            // `DocItem` doc), so the two answers are compared rather than
            // assumed — and the mirror keeps that id on the container
            // ([`Value.objId`], hydrate.zig).
            try testing.expectEqual(got.id, want.objId() orelse
                return error.TestUnexpectedResult);
            switch (typ) {
                .map, .table => try expectMirroredMap(gpa, doc, got.id, try mirrorMap(want)),
                .list => try expectMirroredList(gpa, doc, got.id, try mirrorList(want)),
                .text => try expectMirroredText(gpa, doc, got.id, try mirrorText(want)),
            }
        },
    }
}

/// A document with **one of every kind of value a mirror can hold**, and the
/// two things a naive walk gets wrong: **a deleted key** and **a conflicted
/// key**.
fn mirrorFixture(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, .auto);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = "aaaaaaaa" });

    const map = try trans.putObject(&doc, .root, .{ .key = "map" }, .map);
    const list = try trans.putObject(&doc, .root, .{ .key = "list" }, .list);
    const txt = try trans.putObject(&doc, .root, .{ .key = "text" }, .text);
    const child = try trans.putObject(&doc, map, .{ .key = "child" }, .map);

    _ = try trans.put(&doc, child, .{ .key = "leaf" }, .{ .str = "green" });
    _ = try trans.put(&doc, map, .{ .key = "deep" }, .{ .uint = 7 });

    // **Nine scalars and one null, one per arm of `ScalarValue`** that a
    // mirror can hold, so a `Value.eql` that compared only the bytes would pass
    // an `int` for a `uint` here.
    _ = try trans.put(&doc, .root, .{ .key = "bool" }, .{ .bool_value = true });
    _ = try trans.put(&doc, .root, .{ .key = "bytes" }, .{ .bytes = &.{ 1, 2, 3 } });
    _ = try trans.put(&doc, .root, .{ .key = "counter" }, .{ .counter = .{ .current = 5 } });
    _ = try trans.put(&doc, .root, .{ .key = "float" }, .{ .float = 1.5 });
    _ = try trans.put(&doc, .root, .{ .key = "int" }, .{ .int = -7 });
    _ = try trans.put(&doc, .root, .{ .key = "null" }, .null_value);
    _ = try trans.put(&doc, .root, .{ .key = "str" }, .{ .str = "hello" });
    _ = try trans.put(&doc, .root, .{ .key = "uint" }, .{ .uint = 42 });

    _ = try trans.insert(&doc, list, 0, .{ .str = "first" });
    _ = try trans.insert(&doc, list, 1, .{ .counter = .{ .current = 3 } });
    const boxed = try trans.insertObject(&doc, list, 2, .map);
    _ = try trans.put(&doc, boxed, .{ .key = "k" }, .{ .str = "v" });

    try trans.spliceText(&doc, txt, 0, 0, "hello world");
    try trans.mark(&doc, txt, 0, 5, "bold", .both, .{ .bool_value = true });
    try trans.mark(&doc, txt, 6, 11, "link", .none, .{ .str = "u" });

    // **A deleted key.** `delete` drops the register's rows and leaves a
    // successor edge, so a mirror is wrong to show it ([`keys`]'s doc).
    _ = try trans.put(&doc, .root, .{ .key = "doomed" }, .{ .str = "bye" });
    _ = try trans.delete(&doc, .root, .{ .key = "doomed" });

    // **A conflicted key, from a second actor.** A second `put` through the
    // same transaction would shadow the first and leave one visible row; two
    // actors with no successor edge between their rows is what `top.conflict`
    // reports (`op_set.rs`), so this is a real merge.
    var other = try doc.clone(gpa, .auto);
    defer other.deinit();
    other.setActorId(.{ .bytes = "bbbbbbbb" });
    _ = try trans.put(&other, .root, .{ .key = "clash" }, .{ .str = "theirs" });
    _ = try trans.put(&doc, .root, .{ .key = "clash" }, .{ .str = "ours" });
    const merged = try other.merge(gpa, &doc);
    defer gpa.free(merged);
    return doc;
}

test "hydrate at null heads mirrors the document, element by element" {
    const gpa = testing.allocator;
    const enc: TextEncoding = .unicode_code_point;
    var doc = try mirrorFixture(gpa);
    defer doc.deinit();

    var root = try hydrate(&doc, .root, null, gpa);
    defer root.deinit();
    // **An owned mirror, and this is the assertion that it is one.** The
    // document is mutated underneath the mirror at the end of this test and
    // the mirror is compared again afterwards — upstream's `hydrate::Value`
    // carries no lifetime ([`hydrate.rs`](hydrate.zig):22-27) precisely because
    // it owns everything it holds, and a mirror that borrowed the document's
    // value column would read freed storage there rather than fail here.
    try expectMirroredMap(gpa, &doc, .root, try mirrorMap(&root));

    // **The literals, written out.** Every comparison above is against another
    // reader, so two readers that drifted together would pass all of it; the
    // tables below are the document's contents stated once, independently.
    const m = try mirrorMap(&root);
    try testing.expectEqual(@as(usize, 12), m.count());
    try testing.expect(m.get("doomed") == null);
    // **The conflict is visible in the mirror's own register**, and `ours` is
    // the winner by op id — `getAll`'s last row ([`winner`]).
    {
        const clash = m.get("clash") orelse return error.TestUnexpectedResult;
        try testing.expect(clash.eql(&hydmod.Value.fromScalar(.{ .str = "ours" })));
    }
    // **The nested map and list are mirrors of their own**, and this is where
    // the recursion is checked rather than assumed.
    const map = m.get("map") orelse return error.TestUnexpectedResult;
    const child = (try mirrorMap(map)).get("child") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("green", (try mirrorMap(child))
        .get("leaf").?.str);
    const list = try mirrorList(m.get("list") orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(usize, 3), list.count());
    try testing.expect((list.get(0) orelse return error.TestUnexpectedResult).eql(
        &hydmod.Value.fromScalar(.{ .str = "first" }),
    ));
    try testing.expect((list.get(1) orelse return error.TestUnexpectedResult).eql(
        &hydmod.Value.fromScalar(.{ .counter = .{ .current = 3 } }),
    ));
    // **The third element is a map, and it is reached as one** — a `List.get`
    // takes an index and a `Map.get` takes a key, so reading it the other way
    // round does not compile rather than silently answering element 0.
    const boxed = try mirrorMap(list.get(2) orelse return error.TestUnexpectedResult);
    try testing.expect((boxed.get("k") orelse return error.TestUnexpectedResult).eql(
        &hydmod.Value.fromScalar(.{ .str = "v" }),
    ));

    // **The text, its two marks by name, and their spans.** The mirror holds
    // the names and the values; the reader holds the spans; both are asserted
    // literally.
    const t = try mirrorText(m.get("text") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("hello world", t.asStr());
    try testing.expectEqual(@as(usize, 11), t.count());
    try expectMarkSetNames(&t.marks, &.{
        .{ .name = "bold", .value = .{ .bool_value = true } },
        .{ .name = "link", .value = .{ .str = "u" } },
    });
    // **The spans, from the reader.** The mirror holds the names and the
    // values and no range at all ([`Text`]'s doc over `hydrate/text.rs:10`),
    // so the spans are the reader's to say and are written out here.
    const text_obj = (try mirrorText(m.get("text") orelse
        return error.TestUnexpectedResult)).id;
    const runs = try marks(&doc, text_obj, gpa);
    defer gpa.free(runs);
    try expectMarkRuns(runs, &.{
        .{ .start = 0, .end = 5, .name = "bold", .value = .{ .bool_value = true } },
        .{ .start = 6, .end = 11, .name = "link", .value = .{ .str = "u" } },
    }, enc);

    // **An owned mirror, and this is the assertion that it is one.** A fork
    // at the present's heads is the same document, so the two mirrors are the
    // same tree — which gives a second, independent answer to compare the
    // mirror against rather than the readers above.
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    var fork = try doc.forkAt(gpa, heads, .auto);
    defer fork.deinit();
    var forked = try hydrate(&fork, .root, null, gpa);
    defer forked.deinit();
    try testing.expect(forked.eql(&root));

    // **A mutation underneath the mirror, and the mirror does not move.** The
    // value column has to grow and the text has to be spliced, because a
    // mirror that borrowed either would read the document's storage after the
    // mutation — and the port has produced a wrong *value* rather than a crash
    // that way already, which is why this is asserted and not assumed.
    _ = try trans.put(&doc, .root, .{ .key = "str" }, .{
        .str = "a value long enough to move the raw column's block",
    });
    _ = try trans.put(&doc, .root, .{ .key = "bool" }, .{ .bool_value = false });
    try trans.spliceText(&doc, text_obj, 0, 0, "XX");
    try testing.expect(forked.eql(&root));
    // **And a fresh mirror of the mutated document is a different tree**, so
    // the equality above is not two empty mirrors agreeing.
    var after = try hydrate(&doc, .root, null, gpa);
    defer after.deinit();
    try testing.expect(!after.eql(&root));
}

test "hydrate at heads does not see the writes the heads exclude" {
    const gpa = testing.allocator;
    const enc: TextEncoding = .unicode_code_point;
    var doc = try Document.init(gpa, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "aaaaaaaa" });

    const txt = try trans.putObject(&doc, .root, .{ .key = "text" }, .text);
    try trans.spliceText(&doc, txt, 0, 0, "aaabbbccc");
    try trans.mark(&doc, txt, 0, 3, "bold", .both, .{ .bool_value = true });
    const first = try doc.getHeads(gpa);
    defer gpa.free(first);

    try trans.spliceText(&doc, txt, 3, 0, "QQQ");
    _ = try trans.put(&doc, .root, .{ .key = "late" }, .{ .str = "later" });
    try trans.mark(&doc, txt, 3, 6, "italic", .both, .{ .bool_value = true });
    const second = try doc.getHeads(gpa);
    defer gpa.free(second);

    // **What the heads DO include, positively and by identity.** A test named
    // "does not see the writes the heads exclude" passes three ways — the
    // mirror is correctly scoped, the mirror is empty, or the write was never
    // made — and only the first is a pass. **So the positive half comes first
    // and is by id, not by count**: the root holds a `text` object, that
    // object is the one the fixture made, and its nine characters are the
    // nine the first commit wrote. An empty mirror cannot satisfy any of the
    // three.
    //
    // **The mark set is asserted literally and not through `Value.eql`, and
    // that is load-bearing.** [`Text.eql`](hydrate.zig) is `asStr()` alone
    // (hydrate.zig:1525-1527) — upstream's derive compares the `String` and
    // leaves the `marks` field out — so two mirrors that differ only in their
    // text marks compare **equal**, and a `Value.eql` proof of this test would
    // pass on a mirror holding the present's `italic`.
    var at_first = try hydrate(&doc, .root, first, gpa);
    defer at_first.deinit();
    {
        const m = try mirrorMap(&at_first);
        try testing.expectEqual(@as(usize, 1), m.count());
        const t = try mirrorText(m.get("text") orelse return error.TestUnexpectedResult);
        try testing.expectEqual(txt, t.id);
        try testing.expectEqualStrings("aaabbbccc", t.asStr());
        try testing.expectEqual(@as(usize, 9), t.count());
        try expectMarkSetNames(&t.marks, &.{
            .{ .name = "bold", .value = .{ .bool_value = true } },
        });
    }

    // **The same state read two ways, which is the property itself.** A fork
    // at `first` *is* the document as it was, so hydrating it unscoped and
    // hydrating `doc` at `first` must be the same tree — and a scoped walk
    // that leaked the present's rows produces a different one.
    var fork = try doc.forkAt(gpa, first, .auto);
    defer fork.deinit();
    var forked = try hydrate(&fork, .root, null, gpa);
    defer forked.deinit();
    try testing.expect(forked.eql(&at_first));

    // **And the present is a different answer**, in both directions, so the
    // comparison above is not two wrong answers agreeing.
    var at_present = try hydrate(&doc, .root, null, gpa);
    defer at_present.deinit();
    try testing.expect(!at_present.eql(&at_first));
    // **And the excluded writes are visible at the present, which is what
    // proves they happened at all.** Without this the test above would also
    // pass on a fixture whose second commit silently did nothing.
    {
        const m = try mirrorMap(&at_present);
        try testing.expectEqual(@as(usize, 2), m.count());
        try testing.expectEqualStrings(
            "later",
            (m.get("late") orelse return error.TestUnexpectedResult).str,
        );
        const t = try mirrorText(m.get("text") orelse return error.TestUnexpectedResult);
        try testing.expectEqual(txt, t.id);
        try testing.expectEqualStrings("aaaQQQbbbccc", t.asStr());
        try testing.expectEqual(@as(usize, 12), t.count());
        try expectMarkSetNames(&t.marks, &.{
            .{ .name = "bold", .value = .{ .bool_value = true } },
            .{ .name = "italic", .value = .{ .bool_value = true } },
        });
    }

    // **The readers under the same heads say the same thing**, which is the
    // property all the other readers on this file were pinned for.
    try doc.isolate(gpa, first);
    {
        const runs = try marks(&doc, txt, gpa);
        defer gpa.free(runs);
        try expectMarkRuns(runs, &.{
            .{ .start = 0, .end = 3, .name = "bold", .value = .{ .bool_value = true } },
        }, enc);
        // **And the isolation's own answer is the mirror's.** `readScope`
        // hands [`hydrate`] the isolation's clock for a `null` `heads`, so a
        // mirror built under this isolation equals the one built at `first`
        // over an un-isolated document.
        var scoped = try hydrate(&doc, .root, null, gpa);
        defer scoped.deinit();
        try testing.expect(scoped.eql(&at_first));
    }

    // **`integrate` drops the isolation**, so the present answers again and
    // the two mirrors differ — which is what holds the line above down rather
    // than leaving it resting on a single comparison.
    try doc.integrate();
    var after = try hydrate(&doc, .root, null, gpa);
    defer after.deinit();
    try testing.expect(after.eql(&at_present));
    try testing.expect(!after.eql(&at_first));
}

test "hydrate reads a list and a text object as themselves" {
    // **The three arms of [`hydrate`]'s type dispatch, read directly.**
    //
    // Every other test here hydrates `.root`, and a root is a map — so the
    // `list` and `text` arms
    // ([`automerge.rs:1646-1648`](../../github-automerge-automerge/rust/automerge.rs))
    // are reached only through `hydrate.zig`'s own `hydrate_op`, never through
    // this method. **A dispatch that handed a list to `hydrateMap` would
    // satisfy every other test in this file.** That hole is not hypothetical:
    // mutating this method's `.text` arm to build an empty text left all three
    // of them green. This test closes it.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "aaaaaaaa" });

    const list = try trans.putObject(&doc, .root, .{ .key = "list" }, .list);
    const txt = try trans.putObject(&doc, .root, .{ .key = "text" }, .text);
    _ = try trans.insert(&doc, list, 0, .{ .str = "alpha" });
    _ = try trans.insert(&doc, list, 1, .{ .counter = .{ .current = 4 } });
    try trans.spliceText(&doc, txt, 0, 0, "hello world");
    try trans.mark(&doc, txt, 0, 5, "bold", .both, .{ .bool_value = true });

    // **The list arm**, compared element by element against the reader and then
    // against literals — the same two cross-checks the root gets.
    {
        var list_mirror = try hydrate(&doc, list, null, gpa);
        defer list_mirror.deinit();
        const l = try mirrorList(&list_mirror);
        try testing.expectEqual(list, l.id);
        try expectMirroredList(gpa, &doc, list, l);
        try testing.expectEqual(@as(usize, 2), l.count());
        try testing.expect((l.get(0) orelse return error.TestUnexpectedResult).eql(
            &hydmod.Value.fromScalar(.{ .str = "alpha" }),
        ));
        try testing.expect((l.get(1) orelse return error.TestUnexpectedResult).eql(
            &hydmod.Value.fromScalar(.{ .counter = .{ .current = 4 } }),
        ));
    }

    // **The text arm**, its characters and its marks. An empty text is the
    // shape-valid wrong answer this is here for, so the characters are
    // asserted twice and the marks are asserted by hand — `Text.eql` would not
    // see them.
    {
        var text_mirror = try hydrate(&doc, txt, null, gpa);
        defer text_mirror.deinit();
        const t = try mirrorText(&text_mirror);
        try testing.expectEqual(txt, t.id);
        try expectMirroredText(gpa, &doc, txt, t);
        try testing.expectEqualStrings("hello world", t.asStr());
        try testing.expectEqual(@as(usize, 11), t.count());
        try expectMarkSetNames(&t.marks, &.{
            .{ .name = "bold", .value = .{ .bool_value = true } },
        });
    }

    // **Both arms honour a clock, which is the same dispatch under a different
    // argument.** A method that resolved the type correctly and the clock not
    // at all would pass every assertion above.
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    _ = try trans.insert(&doc, list, 2, .{ .str = "later" });
    try trans.spliceText(&doc, txt, 0, 0, "ZZ");
    {
        var list_at = try hydrate(&doc, list, heads, gpa);
        defer list_at.deinit();
        try testing.expectEqual(@as(usize, 2), (try mirrorList(&list_at)).count());
    }
    {
        var text_at = try hydrate(&doc, txt, heads, gpa);
        defer text_at.deinit();
        const t = try mirrorText(&text_at);
        try testing.expectEqualStrings("hello world", t.asStr());
        try expectMarkSetNames(&t.marks, &.{
            .{ .name = "bold", .value = .{ .bool_value = true } },
        });
        // **And the present is a different answer**, so the two above are not
        // the same tree reached twice.
        var now = try hydrate(&doc, txt, null, gpa);
        defer now.deinit();
        try testing.expect(!now.eql(&text_at));
        try testing.expectEqualStrings("ZZhello world", (try mirrorText(&now)).asStr());
    }
    {
        // **The present's list has the element the clock excluded**, which is
        // what proves the insert happened rather than leaving the count at 2
        // for a second reason.
        var now = try hydrate(&doc, list, null, gpa);
        defer now.deinit();
        try testing.expectEqual(@as(usize, 3), (try mirrorList(&now)).count());
    }
}

test "hydrate at null heads is the document's own scope" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "aaaaaaaa" });
    _ = try trans.put(&doc, .root, .{ .key = "kept" }, .{ .str = "yes" });
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    _ = try trans.put(&doc, .root, .{ .key = "late" }, .{ .str = "no" });

    // **Upstream's answer and the port's are the same here** — this document
    // has no isolation, so [`readScope`] reports no clock and a `null` `heads`
    // is a read of the present either way (`automerge.rs:2228`). It is
    // asserted so the scoping in the test above is not the only thing that
    // makes `hydrate` work.
    var plain = try hydrate(&doc, .root, null, gpa);
    defer plain.deinit();
    try testing.expectEqual(@as(usize, 2), (try mirrorMap(&plain)).count());

    // **Under an isolation the two differ, and the port answers the
    // isolation.** `hydrate_obj` (`automerge.rs:1644`) is what upstream calls,
    // and it does not consult the document's isolation at all — see [`hydrate`]'s
    // doc. **The claim being pinned is that the mirror does not report a write
    // the rest of this file's readers refuse to report**: `keys` under the same
    // isolation reports one key, and so does the mirror.
    try doc.isolate(gpa, heads);
    {
        var walk = try keys(&doc, .root);
        defer walk.deinit(doc.allocator());
        const seen = (try walk.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("kept", seen);
        try testing.expect((try walk.next()) == null);
    }
    var isolated = try hydrate(&doc, .root, null, gpa);
    defer isolated.deinit();
    try testing.expectEqual(@as(usize, 1), (try mirrorMap(&isolated)).count());
    try testing.expect((try mirrorMap(&isolated)).get("late") == null);
    try testing.expect(!isolated.eql(&plain));
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **Thirty-three of the thirty-six upstream cases are ported here**, and the
//   instrument is the convention rather than any count in prose:
//   `grep -rc '^test "text_encoding: ' src/` reports **15**, against the
//   fifteen `#[test]` functions in `tests/text_encoding.rs` (`:183`, `:198`,
//   `:218`, `:247`, `:273`, `:300`, `:324`, `:343`, `:362`, `:381`, `:409`,
//   `:456`, `:501`, `:546`, `:591`), and `grep -rc '^test "text: ' src/`
//   reports **18**, against `tests/text.rs`'s twenty-one `#[test]` functions
//   (`:16`, `:32`, `:84`, `:143`, `:163`, `:297`, `:321`, `:350`, `:417`,
//   `:504`, `:542`, `:614`, `:644`, the `proptest!` at `:658`, `:835`, `:868`,
//   `:923`, `:1044`, `:1090`, `:1121`) less the three that
//   `test/upstream_text_more.zig` carries as **five** blocks —
//   `insertions_after_noexpand_spans_are_not_marked` (`:350-415`),
//   `incorrect_patches_produced_when_isolating_and_integrating` (`:868-921`) and
//   `splicing_into_multibyte_characters` (`:943-1023`, one `#[test]` with three
//   cases). That file is wired into `zig build test` (build.zig:256-265).
//
//   **Thirty-three here plus three there is the whole of thirty-six**, so
//   nothing upstream is unported. Upstream's `text.rs` pins one encoding per
//   case — `text.rs:878` pins `UnicodeCodePoint`, `:925` and `:952` pin
//   `Utf16CodeUnit` — and **the port runs every case under all four**
//   (`text_encoding.rs`:50-55, `:124-133`), which is that file's whole subject
//   (`:34-46`) and the reason a port that copies the pin covers a quarter of
//   the axis.
//
// * **Two of the thirty-three run under three encodings and not four, and both
//   name the exclusion in the comment that opens their body.**
//   `empty_marks_before_block_marker_dont_repeat_text` (`text.rs`:321-348) and
//   the `marks_are_okay` driver (`text.rs`:658-710) build a model in
//   ASCII-plus-`\n`, and a block marker is **three bytes** wide under
//   `utf8_code_unit` ([`one_wide_block_encodings`]), so a `'\n'`-wide model does
//   not describe that document. **The UTF-8 axis is not uncovered because of
//   them**: the other sixteen `text: ` cases here and all fifteen
//   `text_encoding: ` cases run under `utf8_code_unit`, the block-bearing ones
//   included, because they carry their own widths rather than a `'\n'`
//   assumption.
//
// * **A `text:`-prefixed filter does not reach the diff path, and this file's
//   own prefix is not a sufficient instrument for it.** Perturbing
//   [`SpanState.flush`](iter/spans.zig) so that a `Del` run costs index — the
//   asymmetry [`SpanState.diffWidth`] exists to preserve — left all nineteen
//   matches of `--test-filter "text: "` green, this file's eighteen among them,
//   and failed only `text_encoding: a put arrives as a delete and a splice at
//   the same index (text_encoding.rs:409-454)`, the one case here that reads a
//   `DeleteSeq` index. **The `text_encoding:` prefix is what watches the diff**,
//   and that is why the two prefixes are counted separately above rather than
//   summed.
//
// * **Zig has no property framework, so `marks_are_okay` (`text.rs`:658-710)
//   is a fixed-seed driver.** The same four action generators and the same
//   ranges (`:751-833`) are drawn from a 64-bit LCG instead of `proptest`, and
//   the two invariants upstream asserts (`:683-708`) are checked per scenario.
//   A `proptest` run explores a different set every time and shrinks a
//   counterexample; this one explores the same sixty-four every time, which is
//   what makes a failure reproducible. The scenario count is a named
//   constant in the test, not a hidden default.
//
// * **`get_marks` is a window here and a single index upstream.** Upstream's
//   `ReadDoc::get_marks` (`read.rs`:168-173) answers a `MarkSet` at one index;
//   [API.md](../API.md) §Read gives [`getMarks`] a half-open `[from, max)`
//   window, and the module doc above says so. A single-index read is the
//   window `[index, index + 1)`, which is what the ported tests use where
//   upstream reads one index — and the two places upstream compares a
//   single-index read against a whole-object read are therefore **not
//   ported as comparisons**: [`getMarks`] is literally [`marks`] filtered to
//   a window, so such a test would compare a value with itself. The
//   ported tests compare against a **model of the mark operations the test
//   applied** ([`modelCovering`]) instead, which is a third and independent
//   source.
//
// * **The historical half of `get_marks_agrees_with_marks_at_every_index`
//   (`text.rs`:1044-1088) runs on a fork.** Upstream reads the same document
//   at `heads` through `length_at` / `marks_at` / `get_marks(.., Some(&heads))`
//   (`:1079-1087`); this port has no `_at` variants (the module doc above,
//   "The `_at` variants"), and [`Document.forkAt`](doc.zig) builds the same
//   state from the same heads.
//
// * **`mark_created_after_insertion` (`text.rs`:143-161) asserts the runs the
//   two marks produce, not that they do not fail.** Upstream's whole
//   assertion is two `unwrap()`s, and [AGENTS.md](AGENTS.md) says a test that
//   only shows a call did not throw is a test that proves nothing. The runs are
//   a strict superset of the assertion, so nothing upstream checks is lost.
//
// * **`deleting_in_middle_of_multibyte_char_moves_the_cursor_to_after_the_character`
//   (`text.rs`:923-941) is stated as upstream's algorithm, not as a table.**
//   Upstream pins `TextEncoding::Utf16CodeUnit` and three literal strings; the
//   ported test asserts those three literals under UTF-16 **and** asserts the
//   same answer under the other three encodings from the rule that produces
//   them ([`splicedText`], `inner.rs`:695-700, `:756-792` against
//   `op_set2/op_set.rs`:463-492). The three numbers upstream writes mean
//   different things in each encoding — index 2 is inside the first 🐻 in both
//   UTF-16 and UTF-8 and on a boundary in code points and graphemes — so the
//   other three answers are genuinely different and are not upstream's.
//
// * **`fork` is `clone` plus `setActorId` in the two merge tests.** Upstream's
//   `AutoCommit::fork` draws a fresh random actor (`automerge.rs`:702-706) and
//   so does [`Document.fork`](doc.zig) — but those sixteen bytes come from the
//   allocator and `setActorId` replaces the field without freeing them
//   (`doc.zig`:2295-2301), so `std.testing.allocator` refuses the test. A
//   `clone` and a named actor is the same thing minus the leak.
//
// * **A key range is [`KeyRange`], and it is a spelling rather than a second
//   computation.** Upstream takes a `RangeBounds<String>` ([`read.rs:84-88`]
//   over [`automerge.rs:1676-1686`]) and Zig has no range-bounds protocol, so
//   each end is a [`KeyBound`] or null — the same shape [iter/list_range.zig]
//   gives `RangeBounds<usize>`. **The bounds are not resolved here.** There
//   was a second implementation of upstream's four arms in this file, kept
//   alive because [`OpSet.mapRange`](opset/op_set.zig) took a pair of optional
//   keys and so reached only two of them ([`op_set.rs:408`], `:414`); it is
//   gone and [`mapRange`] hands both ends to [`OpSet.mapRange`](opset/op_set.zig),
//   which reaches all four. One owner, one answer: a bound resolved in two
//   places is two answers the day one of them changes.
//
// * **The bound kind is declared in `op_set.zig` and re-exported here.**
//   [`OpSet.mapRange`](opset/op_set.zig) takes it and `op_set.zig` cannot import
//   this file, so declaring it here and passing it across would be a second
//   type. `pub const KeyBound = opsetmod.KeyBound;` is the same type under the
//   name this file's API has always used.
//
// * **`hydrate` is the composition it claims to be, and `null` heads is the
//   one place it is not a straight port.** The recursion is
//   [`hydmod.hydrateMap`] / `hydrateList` / `hydrateText` over `OpSet.topOps`
//   (`hydrate.rs:244-302`) and this file adds the entry point, the type
//   dispatch (`automerge.rs:1645-1649`) and the clock. **The clock is the
//   departure**: upstream's `heads.and_then(|h| self.clock_at(h))`
//   (`automerge.rs:2228`) makes `None` mean *no clock*, and both of upstream's
//   other `ReadDoc` implementors forward `heads` to `hydrate_obj` without
//   `get_scope(..)` (`autocommit.rs:1011`, `transaction.rs:228`) where every
//   sibling does — so upstream's `hydrate` reads the present under an
//   isolation. The port's `null` is [`readScope`], the isolation's clock, which
//   is the same null on every un-isolated document. Upstream pins nothing
//   either way, and `test "hydrate at null heads is the document's own scope"`
//   is what holds the difference down.
//
// * **The mirror tests assert contents against the readers and then against
//   literals, because the two cross-checks fail differently.** Every key,
//   element, scalar and mark name is compared against a second reader, and the
//   key set is compared **by count in both directions** — so a mirror that is
//   merely non-empty, or that kept a deleted key, fails there rather than
//   passing. The literal tables below that cross-check are what catch two
//   readers drifting together. **And the `conflict` flag is pinned against
//   `getAll`'s row count**, because `MapValue::new(value, id, conflict)` takes
//   it (`hydrate/map.rs:81`) from `top.conflict` (`hydrate.rs:254`) and it is
//   the one field of a hydrated register that no `Value.eql` looks at — a mirror
//   reporting `false` for every register would pass every other comparison in
//   the file.
//
// * **The ownership of a mirror is asserted by mutating under it.** A fork at
//   the present's heads is the same document, so the two mirrors are the same
//   tree; the document is then given a longer scalar, a flipped boolean and a
//   spliced text, and the two are compared again. **A borrowed scalar reads the
//   op set's value column after the mutation**, and this port has produced a
//   wrong *value* rather than a crash that way already — which is why the test
//   is a comparison after a mutation and not a claim in a doc comment.
//
// * **Hydrating the root exercises one of [`hydrate`]'s three arms, and a
//   mutation found it.** The first three tests all pass `.root`, and a root is
//   a map — so the `list` and `text` arms (`automerge.rs:1646-1648`) were
//   reached only through `hydrate.zig`'s own `hydrate_op`, never through this
//   method. **Rewriting the `.text` arm to build an empty text left all three
//   green**, which is the whole falsification result in one line: a dispatch
//   that handed a text to `hydrateMap`, or built an empty one, satisfied every
//   test in the file. `test "hydrate reads a list and a text object as
//   themselves"` closes it, and both mutations are caught by it now —
//   `.text` building `""`, and `.list` routed to `hydrateMap`.
//
//   **This is the general shape worth keeping.** A method whose *dispatch* has
//   arms is tested by its arms; a test that only ever calls it on the most
//   common input has not tested the others, whatever it asserts.

// ── The historical readers: the answers, then the resolution ────────────────
//
// This block was verified green on 2026-10-01 as a standalone root
// (`zig test --cache-dir <private> --dep build_options -Mroot=<the standalone
//   copy> -Mbuild_options=<file with `pub const check_slow_paths = false;>`)
// and falsified twice: removing `liveObj`/`liveObjOrSelf` from the fourteen
// `*At` bodies fails all fourteen `resolves the object id it was handed`
// tests; making `atScope` return null fails ten of the historical tests.
// **So this is a specification and not a smoke test**: each of the fourteen
// calls exactly one reader, which is what makes one perturbation of the
// fourteen bodies a per-method falsification rather than a joint one.
//
// `keysWant`/`keyCount`/`spanText`/`expectOne` below are **new**, because the
// test section's own `keyList` reads only the *present*.
//
// What the paste into this file resolved, all of it mechanical:
//
// * **The `read.` prefix is gone.** A file cannot `@import` itself, so every
//   `read.getAt` is [`getAt`] and every `read.Keys` is [`Keys`].
// * **The ten `const` imports are gone.** `std`, `testing`, `docmod`,
//   `types`, `Allocator`, `ChangeHash`, `Document`, `ExId` and `Prop` are
//   already at this file's scope (`:158-203`), and [`trans`] is declared for
//   the text suites (`:3918`); restating any of them would be a duplicate
//   declaration, so none is restated.
// * **Nothing else collides.** `Fix`, `fix`, `keysWant`, `keyCount`,
//   `spanText` and `expectOne` are new names in this file, and none of the
//   test names below repeats one already here.
// * **The `at` the standalone copy was warned about is still not reached**:
//   the cursor calls below name the folded methods, and the folded methods
//   name their heads parameter `heads` — see the difference block at the foot
//   of this file. Nothing below shadows the file-scope `fn at(id: OpId)`.
//
// **What changed on the way in**, beyond the `read.` prefix and the imports:
// the three cursor tests lost the `At` from their names and their calls name
// the folded methods, so the green run above was against `getCursorAt`,
// `getCursorMovingAt` and `getCursorPositionAt` — **the same reads, with the
// heads argument in upstream's place.** Nothing else in the block was
// touched.

const Fix = struct {
    doc: Document,
    heads1: []ChangeHash,
    heads2: []ChangeHash,
    text: ExId,
    list: ExId,
    sub: ExId,
    late: ExId,

    fn deinit(self: *Fix, gpa: Allocator) void {
        gpa.free(self.heads1);
        gpa.free(self.heads2);
        self.doc.deinit();
        self.* = undefined;
    }
};

/// **The fixture makes three things true at once, and each one is load
/// bearing.**
///
/// 1. `heads1` and `heads2` are both **behind the present** — the fork/merge
///    at the end moves the heads on — so every read here builds a clock and
///    takes a walk rather than [`Automerge::clock_at`]'s indexed fast path.
///    A test that passed the document's own heads would prove nothing.
/// 2. The present's answer **differs** from the answer at either older head
///    for every method, so a reader that quietly passed `null` fails.
/// 3. Every `ExId` this keeps was minted while `aaaaaaaa` was actor index 0,
///    and the fork's actor `00000000` **sorts before it**, so interning that
///    actor through the merge renumbers `aaaaaaaa` to 1 and leaves those ids
///    carrying a stale index. Only [`Document.resolve`] repairs them.
fn fix(gpa: Allocator) !Fix {
    var doc = try Document.init(gpa, .manual);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = "aaaaaaaa" });

    var tx = try trans.Transaction.open(gpa, &doc);
    const txt = try tx.putObject(.root, .{ .key = "text" }, .text);
    try tx.spliceText(txt, 0, 0, "abc");
    const lst = try tx.putObject(.root, .{ .key = "list" }, .list);
    _ = try tx.insert(lst, 0, .{ .str = "l0" });
    const sub = try tx.putObject(.root, .{ .key = "sub" }, .map);
    _ = try tx.put(sub, .{ .key = "inner" }, .{ .str = "in1" });
    _ = try tx.put(.root, .{ .key = "k" }, .{ .str = "v1" });
    _ = try tx.commit(null, null);
    tx.deinit();
    const heads1 = try doc.getHeads(gpa);
    errdefer gpa.free(heads1);

    var tx2 = try trans.Transaction.open(gpa, &doc);
    _ = try tx2.put(.root, .{ .key = "k" }, .{ .str = "v2" });
    _ = try tx2.delete(lst, .{ .index = 0 });
    try tx2.spliceText(txt, 0, 0, "Z");
    try tx2.mark(txt, 0, 3, "bold", .both, .{ .bool_value = true });
    const late = try tx2.putObject(.root, .{ .key = "late" }, .map);
    _ = try tx2.commit(null, null);
    tx2.deinit();
    const heads2 = try doc.getHeads(gpa);
    errdefer gpa.free(heads2);

    var fork = try doc.fork(gpa, .manual);
    defer fork.deinit();
    fork.setActorId(.{ .bytes = "00000000" });
    {
        var ftx = try trans.Transaction.open(gpa, &fork);
        _ = try ftx.put(.root, .{ .key = "forked" }, .{ .int = 1 });
        _ = try ftx.commit(null, null);
        ftx.deinit();
    }
    const now = try doc.merge(gpa, &fork);
    defer gpa.free(now);

    // **The premise, checked rather than assumed.**
    for (now) |h| {
        try testing.expect(!ChangeHash.eql(h, heads1[0]));
        try testing.expect(!ChangeHash.eql(h, heads2[0]));
    }
    return .{
        .doc = doc,
        .heads1 = heads1,
        .heads2 = heads2,
        .text = txt,
        .list = lst,
        .sub = sub,
        .late = late,
    };
}

/// How many keys a [`Keys`] walk reports, having checked it reported
/// `want`. Every key is copied out first: a sequence anchor is the walk's own
/// buffer and is only valid until the next `next()`.
fn keysWant(gpa: Allocator, walk: *Keys, want: []const u8) !usize {
    var held: std.ArrayList([]u8) = .empty;
    defer {
        for (held.items) |s| gpa.free(s);
        held.deinit(gpa);
    }
    while (try walk.next()) |k| try held.append(gpa, try gpa.dupe(u8, k));
    var seen = false;
    for (held.items) |k| {
        if (std.mem.eql(u8, k, want)) seen = true;
    }
    try testing.expect(seen);
    return held.items.len;
}

fn keyCount(walk: *Keys) !usize {
    var n: usize = 0;
    while (try walk.next()) |_| n += 1;
    return n;
}

fn spanText(gpa: Allocator, walk: *Spans) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(gpa);
    while (try walk.next()) |payload| {
        var span = payload;
        defer span.deinit(gpa);
        try joined.appendSlice(gpa, span.asStr());
    }
    return joined.toOwnedSlice(gpa);
}

/// One [`DocItem`], or a clean test failure.
///
/// **The point is that it fails rather than panics.** A perturbed reader that
/// answers `null` must show up as a `FAIL` line, not as an abort that stops
/// the run before the other thirteen resolution tests have had their say.
fn expectOne(item: ?DocItem) !DocItem {
    return item orelse return error.TestUnexpectedResult;
}

// ── The historical answers, one per method ───────────────────────────────────

test "getAt reads the register as those heads saw it" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const k = Prop{ .key = "k" };
    try testing.expectEqualStrings("v1", (try expectOne(try getAt(&f.doc, .root, k, f.heads1))).value.scalar.str);
    try testing.expectEqualStrings("v2", (try expectOne(try getAt(&f.doc, .root, k, f.heads2))).value.scalar.str);
    try testing.expectEqualStrings("v2", (try expectOne(try get(&f.doc, .root, k))).value.scalar.str);
    // A key written after those heads was never written, and that is `null`.
    try testing.expect((try getAt(&f.doc, .root, .{ .key = "late" }, f.heads1)) == null);
}

test "getAllAt reads the register as those heads saw it" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const k = Prop{ .key = "k" };
    const at1 = try getAllAt(&f.doc, .root, k, f.heads1, gpa);
    defer gpa.free(at1);
    const at2 = try getAllAt(&f.doc, .root, k, f.heads2, gpa);
    defer gpa.free(at2);
    const now = try getAll(&f.doc, .root, k, gpa);
    defer gpa.free(now);
    try testing.expectEqual(@as(usize, 1), at1.len);
    try testing.expectEqual(@as(usize, 1), at2.len);
    try testing.expectEqual(@as(usize, 1), now.len);
    try testing.expectEqualStrings("v1", at1[0].value.scalar.str);
    try testing.expectEqualStrings("v2", at2[0].value.scalar.str);
    try testing.expectEqualStrings("v2", now[0].value.scalar.str);
}

test "lengthAt counts the elements those heads could see" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), try lengthAt(&f.doc, f.text, f.heads1));
    try testing.expectEqual(@as(usize, 4), try lengthAt(&f.doc, f.text, f.heads2));
    try testing.expectEqual(@as(usize, 4), try length(&f.doc, f.text));
    try testing.expectEqual(@as(usize, 1), try lengthAt(&f.doc, f.list, f.heads1));
    try testing.expectEqual(@as(usize, 0), try lengthAt(&f.doc, f.list, f.heads2));
    try testing.expectEqual(@as(usize, 0), try length(&f.doc, f.list));
}

test "textAt reads the string as those heads saw it" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const a = try textAt(&f.doc, f.text, f.heads1, gpa);
    defer gpa.free(a);
    const b = try textAt(&f.doc, f.text, f.heads2, gpa);
    defer gpa.free(b);
    const c = try text(&f.doc, f.text, gpa);
    defer gpa.free(c);
    try testing.expectEqualStrings("abc", a);
    try testing.expectEqualStrings("Zabc", b);
    try testing.expectEqualStrings("Zabc", c);
}

test "keysAt reads the keys as those heads saw them" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    {
        var w = try keysAt(&f.doc, .root, f.heads1);
        defer w.deinit(f.doc.allocator());
        try testing.expectEqual(@as(usize, 4), try keysWant(gpa, &w, "sub"));
    }
    {
        var w = try keysAt(&f.doc, .root, f.heads2);
        defer w.deinit(f.doc.allocator());
        try testing.expectEqual(@as(usize, 5), try keysWant(gpa, &w, "late"));
    }
    {
        var w = try keys(&f.doc, .root);
        defer w.deinit(f.doc.allocator());
        try testing.expectEqual(@as(usize, 6), try keysWant(gpa, &w, "forked"));
    }
}

test "valuesAt reads the values as those heads saw them" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    {
        var term: ValueTerm = undefined;
        defer term.deinit(f.doc.allocator());
        var w = try valuesAt(&f.doc, .root, f.heads1, &term);
        var n: usize = 0;
        while (try w.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 4), n);
    }
    {
        var term: ValueTerm = undefined;
        defer term.deinit(f.doc.allocator());
        var w = try values(&f.doc, .root, &term);
        var n: usize = 0;
        while (try w.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 6), n);
    }
}

test "spansAt reads the spans as those heads saw them" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    {
        var w = try spansAt(&f.doc, f.text, f.heads1, gpa);
        defer w.deinit();
        const joined = try spanText(gpa, &w);
        defer gpa.free(joined);
        try testing.expectEqualStrings("abc", joined);
    }
    {
        var w = try spans(&f.doc, f.text, gpa);
        defer w.deinit();
        var n: usize = 0;
        while (try w.next()) |payload| {
            var span = payload;
            defer span.deinit(gpa);
            // The `Z` was spliced in **before** the mark was written, so
            // `bold [0, 3)` covers `Zab` and not `Z`.
            if (span.text.marks != null) {
                try testing.expectEqualStrings("Zab", span.asStr());
                n += 1;
            }
        }
        try testing.expectEqual(@as(usize, 1), n);
    }
}

test "marksAt reads the marks as those heads saw them" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const at1 = try marksAt(&f.doc, f.text, f.heads1, gpa);
    defer gpa.free(at1);
    const at2 = try marksAt(&f.doc, f.text, f.heads2, gpa);
    defer gpa.free(at2);
    const now = try marks(&f.doc, f.text, gpa);
    defer gpa.free(now);
    try testing.expectEqual(@as(usize, 0), at1.len);
    try testing.expectEqual(@as(usize, 1), at2.len);
    try testing.expectEqual(@as(usize, 1), now.len);
    try testing.expectEqualStrings("bold", at2[0].name);
    try testing.expectEqual(@as(usize, 0), at2[0].start);
    try testing.expectEqual(@as(usize, 3), at2[0].end);
}

test "mapRangeAt reads the items as those heads saw them" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    {
        var w = try mapRangeAt(&f.doc, .root, .{}, f.heads1);
        var n: usize = 0;
        while (try w.next()) |item| {
            // `forked` arrived with the merge, so those heads cannot have it.
            if (std.mem.eql(u8, item.key, "forked")) return error.TestUnexpectedResult;
            n += 1;
        }
        try testing.expectEqual(@as(usize, 4), n);
    }
    {
        var w = try mapRange(&f.doc, .root, .{});
        var n: usize = 0;
        while (try w.next()) |item| {
            if (std.mem.eql(u8, item.key, "forked")) n += 1;
        }
        try testing.expectEqual(@as(usize, 1), n);
    }
}

test "listRangeAt reads the elements as those heads saw them" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    {
        var w = try listRangeAt(&f.doc, f.list, .{}, f.heads1);
        var n: usize = 0;
        while (try w.next()) |item| {
            try testing.expectEqual(@as(usize, 0), item.index);
            try testing.expectEqualStrings("l0", item.value.scalar.str);
            n += 1;
        }
        try testing.expectEqual(@as(usize, 1), n);
    }
    {
        var w = try listRangeAt(&f.doc, f.list, .{}, f.heads2);
        try testing.expect((try w.next()) == null);
    }
    {
        var w = try listRange(&f.doc, f.list, .{});
        try testing.expect((try w.next()) == null);
    }
}

test "parentsAt walks up as those heads saw it" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    {
        var w = try parentsAt(&f.doc, f.sub, f.heads1);
        const first = (try w.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(ExId.root, first.obj);
        try testing.expectEqualStrings("sub", first.prop.key);
        try testing.expect((try w.next()) == null);
    }
    {
        // `late` did not exist at the first head, so the walk reports the
        // parent **invisibly** — upstream's `Parent.visible`, the same answer
        // `Parents::visible_path` turns into `None` (`parents.rs:41-52`). The
        // walk does not stop, because upstream's does not (`parents.rs:65`).
        var w = try parentsAt(&f.doc, f.late, f.heads1);
        const first = (try w.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("late", first.prop.key);
        try testing.expect(!first.visible);
        try testing.expect((try w.next()) == null);
    }
    {
        var w = try parentsAt(&f.doc, f.late, f.heads2);
        const first = (try w.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("late", first.prop.key);
        try testing.expect((try w.next()) == null);
    }
}

test "getCursor reads the element as those heads saw it" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const c = try getCursor(&f.doc, f.list, .{ .index = 0 }, f.heads1, gpa);
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&f.doc, f.list, c, f.heads1));
    try testing.expectError(error.InvalidIndex, getCursor(&f.doc, f.list, .{ .index = 0 }, f.heads2, gpa));
    try testing.expectError(error.InvalidIndex, getCursor(&f.doc, f.list, .{ .index = 0 }, null, gpa));
}

test "getCursorMoving reads the element as those heads saw it" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const after = try getCursorMoving(&f.doc, f.list, .{ .index = 0 }, f.heads1, .after, gpa);
    const before = try getCursorMoving(&f.doc, f.list, .{ .index = 0 }, f.heads1, .before, gpa);
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&f.doc, f.list, after, f.heads1));
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&f.doc, f.list, before, f.heads1));
    try testing.expectError(
        error.InvalidIndex,
        getCursorMoving(&f.doc, f.list, .{ .index = 0 }, f.heads2, .after, gpa),
    );
}

test "getCursorPosition reads the position as those heads saw it" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);

    // **A cursor on the element `heads1` can see and `heads2` cannot.** At
    // `heads2` the element is deleted, and `MoveCursor::After`'s documented
    // answer for an invisible element is "the next index of a visible item
    // that was also visible when the cursor was made" — which here is `0`,
    // because the list is empty (`automerge.rs:1789-1794`). **So this pair is
    // the clock moving a position without the cursor moving with it.**
    const c = try getCursor(&f.doc, f.list, .{ .index = 0 }, f.heads1, gpa);
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&f.doc, f.list, c, f.heads1));
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&f.doc, f.list, c, f.heads2));

    // **And the refusal the clock can add.** A cursor on the `Z` — spliced in
    // by the *second* change — names an operation the `heads1` clock does not
    // cover, which is upstream's `op_cursor_to_opid` refusal
    // (`automerge.rs:777-780`) and the port's
    // [`cursormod.getCursorPosition`](cursor.zig)'s `c.contains(elem.id)` guard.
    const cz = try getCursor(&f.doc, f.text, .{ .index = 0 }, f.heads2, gpa);
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&f.doc, f.text, cz, f.heads2));
    try testing.expectError(error.InvalidCursor, getCursorPosition(&f.doc, f.text, cz, f.heads1));
}

test "*At at the document's own heads is the unsuffixed read" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const now = try f.doc.getHeads(gpa);
    defer gpa.free(now);
    const k = Prop{ .key = "k" };
    try testing.expectEqualStrings("v2", (try expectOne(try getAt(&f.doc, .root, k, now))).value.scalar.str);
    try testing.expectEqual(@as(usize, 4), try lengthAt(&f.doc, f.text, now));
    {
        const a = try textAt(&f.doc, f.text, now, gpa);
        defer gpa.free(a);
        try testing.expectEqualStrings("Zabc", a);
    }
    {
        var w = try keysAt(&f.doc, .root, now);
        defer w.deinit(f.doc.allocator());
        try testing.expectEqual(@as(usize, 6), try keyCount(&w));
    }
    {
        const a = try marksAt(&f.doc, f.text, now, gpa);
        defer gpa.free(a);
        try testing.expectEqual(@as(usize, 1), a.len);
    }
    {
        var w = try listRangeAt(&f.doc, f.list, .{}, now);
        try testing.expect((try w.next()) == null);
    }
    {
        var w = try parentsAt(&f.doc, f.late, now);
        const first = (try w.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("late", first.prop.key);
    }
    {
        const a = try getAllAt(&f.doc, .root, k, now, gpa);
        defer gpa.free(a);
        try testing.expectEqualStrings("v2", a[0].value.scalar.str);
    }
    {
        var w = try mapRangeAt(&f.doc, .root, .{}, now);
        var n: usize = 0;
        while (try w.next()) |item| {
            if (std.mem.eql(u8, item.key, "forked")) n += 1;
        }
        try testing.expectEqual(@as(usize, 1), n);
    }
    {
        var term: ValueTerm = undefined;
        defer term.deinit(f.doc.allocator());
        var w = try valuesAt(&f.doc, .root, now, &term);
        var n: usize = 0;
        while (try w.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 6), n);
    }
}

// ── Resolution, one per method: each fails if that method stops resolving ────
//
// The fixture's `text`, `list` and `sub` all carry actor index 0 with the bytes
// `aaaaaaaa`, and the merge put `00000000` at index 0. Every read below names
// one of them, so a reader that handed the caller's id to the op set unresolved
// answers about `00000000` — which owns nothing at those counters.
//
// **Each test calls exactly one reader**, which is what makes one perturbation
// of the fourteen bodies a per-method falsification rather than a joint one:
// removing resolution from all fourteen fails all fourteen, and no test can be
// failing because of a method it never calls.

test "getAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const got = try expectOne(try getAt(&f.doc, f.sub, .{ .key = "inner" }, f.heads2));
    try testing.expectEqualStrings("in1", got.value.scalar.str);
}

test "getAllAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const got = try getAllAt(&f.doc, f.sub, .{ .key = "inner" }, f.heads2, gpa);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("in1", got[0].value.scalar.str);
}

test "lengthAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try lengthAt(&f.doc, f.sub, f.heads2));
}

test "keysAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    var w = try keysAt(&f.doc, f.sub, f.heads2);
    defer w.deinit(f.doc.allocator());
    try testing.expectEqual(@as(usize, 1), try keysWant(gpa, &w, "inner"));
}

test "valuesAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    var term: ValueTerm = undefined;
    defer term.deinit(f.doc.allocator());
    var w = try valuesAt(&f.doc, f.sub, f.heads2, &term);
    const item = (try w.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("in1", item.value.scalar.str);
    try testing.expect((try w.next()) == null);
}

test "textAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const got = try textAt(&f.doc, f.text, f.heads2, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("Zabc", got);
}

test "spansAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    var w = try spansAt(&f.doc, f.text, f.heads2, gpa);
    defer w.deinit();
    const joined = try spanText(gpa, &w);
    defer gpa.free(joined);
    try testing.expectEqualStrings("Zabc", joined);
}

test "marksAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    const got = try marksAt(&f.doc, f.text, f.heads2, gpa);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("bold", got[0].name);
}

test "mapRangeAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    var w = try mapRangeAt(&f.doc, f.sub, .{}, f.heads2);
    var n: usize = 0;
    while (try w.next()) |item| {
        try testing.expectEqualStrings("inner", item.key);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);
}

test "listRangeAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    var w = try listRangeAt(&f.doc, f.list, .{}, f.heads1);
    var n: usize = 0;
    while (try w.next()) |item| {
        try testing.expectEqualStrings("l0", item.value.scalar.str);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);
}

test "parentsAt resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    var w = try parentsAt(&f.doc, f.sub, f.heads2);
    const first = (try w.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("sub", first.prop.key);
    try testing.expect((try w.next()) == null);
}

test "getCursor resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    _ = try getCursor(&f.doc, f.list, .{ .index = 0 }, f.heads1, gpa);
}

test "getCursorMoving resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    _ = try getCursorMoving(&f.doc, f.list, .{ .index = 0 }, f.heads1, .before, gpa);
}

test "getCursorPosition resolves the object id it was handed" {
    const gpa = testing.allocator;
    var f = try fix(gpa);
    defer f.deinit(gpa);
    // **The cursor is minted at the same heads**, because the present's list is
    // empty and `getCursor` would refuse with `InvalidIndex`.
    const c = try getCursor(&f.doc, f.list, .{ .index = 0 }, f.heads1, gpa);
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&f.doc, f.list, c, f.heads1));
}

// ── The recursive walk ───────────────────────────────────────────────────────

/// One item the recursive walk handed out, with the text and the key copied
/// out of the item that owns them.
///
/// **The copy is the whole point of this fixture.** A text arm carries owned
/// text and an owned mark set ([`DocObjItem.deinit`](iter/doc.zig)), and a map
/// key borrows the document's string table, so an item cannot outlive its own
/// `deinit` and neither can anything read out of it. A table of these is
/// comparable after the walk is done.
const WalkItem = struct {
    /// The object the property hangs by — the **parent**, never the object the
    /// value names ([`DocObjItem.obj`](iter/doc.zig)).
    obj: ExId,
    key: ?[]const u8,
    /// The value as text, or the object type's name.
    value: []const u8,
};

/// Walks `doc` and returns what it saw, in order, with everything copied.
fn walkTo(
    gpa: Allocator,
    doc: *const Document,
    obj: ExId,
    heads: ?[]const ChangeHash,
) ![]WalkItem {
    var walk = try iterAt(doc, obj, heads, gpa);
    defer walk.deinit();
    var out: std.ArrayList(WalkItem) = .empty;
    errdefer {
        for (out.items) |item| {
            if (item.key) |k| gpa.free(k);
            gpa.free(item.value);
        }
        out.deinit(gpa);
    }
    while (try walk.next()) |got| {
        var item = got;
        defer item.deinit(gpa);
        try out.ensureUnusedCapacity(gpa, 1);
        const key = if (item.key()) |k| try gpa.dupe(u8, k) else null;
        errdefer if (key) |k| gpa.free(k);
        // **Every arm copies, including the borrowed ones.** The text arm's
        // slice points into the span this very `defer` releases, so taking it
        // would leave the table pointing at freed memory — the whole reason
        // this fixture exists rather than an index into the walk.
        const rendered: []const u8 = switch (item.value()) {
            .scalar => |s| switch (s) {
                .str => |v| try gpa.dupe(u8, v),
                .int => |n| try std.fmt.allocPrint(gpa, "{d}", .{n}),
                .uint => |n| try std.fmt.allocPrint(gpa, "{d}", .{n}),
                .counter => |c| try std.fmt.allocPrint(gpa, "{d}", .{c.current}),
                .bool_value => |b| try gpa.dupe(u8, if (b) "true" else "false"),
                else => try std.fmt.allocPrint(gpa, "{s}", .{@tagName(s)}),
            },
            .object => |t| try gpa.dupe(u8, @tagName(t)),
        };
        out.appendAssumeCapacity(.{
            .obj = item.obj,
            .key = key,
            .value = rendered,
        });
    }
    return out.toOwnedSlice(gpa);
}

fn freeWalk(gpa: Allocator, items: []WalkItem) void {
    for (items) |item| {
        gpa.free(item.value);
        if (item.key) |k| gpa.free(k);
    }
    gpa.free(items);
}

/// The objects [`walk_specs`] holds, **at the ids the rows that make them
/// say** — an object *is* the operation that created it
/// ([`OpSet.spliceObjects`](../opset/op_set.zig), `op_set.zig:1287-1291`), so
/// the counter in the row is the id.
const walk_map: ExId = .{ .id = OpId.init(1, 0) };
const walk_list: ExId = .{ .id = OpId.init(2, 0) };
const walk_text: ExId = .{ .id = OpId.init(3, 0) };
const walk_deeper: ExId = .{ .id = OpId.init(5, 0) };

/// The list's first element: the register the second row opens **after**, and
/// the id of the row that created it.
const walk_elem_x: OpId = OpId.init(7, 0);

/// The document the recursive walk is read from: **a root map with three
/// children** — a map, a list and a text object — a string of its own, and a
/// **fourth object that is created and never written to**.
///
/// # The rows are in the op set's order, and that is the whole fixture
///
/// [`rootMap`] splices `specs` in the order they are written and refuses the
/// result when it is out of rule order ([`Op.step`](../opset/op.zig),
/// `op.zig:2205-2222`) — the premise [`sample`] states. **No reader sorts**: a
/// walk takes the op set's rows as it finds them ([`iter/doc.zig`](iter/doc.zig),
/// *Row order is the order upstream's `BTreeMap` gave*), so rows written in the
/// order the operations **ran** would build a document that answers in a
/// sequence no reader may produce. Three of the four rules are doing work in
/// the rows below:
///
/// * **R1** puts the root's rows first, then `child_map` (operation 1),
///   `child_list` (2) and `child_text` (3) — objects ascend.
/// * **R2** puts the root's registers in key order (`"child_list"` <
///   `"child_map"` < `"child_text"` < `"root_key"`), which is why the row for
///   operation 1 is written above the row for operation 2, and `child_map`'s
///   own two in key order (`"deeper"` < `"inner"`).
/// * **R4** puts the list's second element after the first: an insert opens a
///   register keyed by its own id, and it is legal there only because it hangs
///   by the element the row before it created (`op.rs:1061-1063`).
///
/// # The object no answer hangs by
///
/// `deeper` is a `make_text` at operation 5 and **nothing is ever written to
/// it**, so the op set indexes the object and holds no row of it: the walk
/// queues it, finds an empty range and carries on
/// ([`DocIterInternal.nextObject`](iter/doc.zig), upstream's
/// `if next_range.is_empty() { Some(None) }`, `iter/doc.rs:245-247`). It is
/// here for that and for nothing else, and the test states it as a premise —
/// **an object with no rows and an id that names nothing are different
/// answers**, and only the first is one the walk steps over.
const walk_specs = [_]OpSpec{
    // The root map, in key order.
    .{ .ctr = 2, .key = mkey("child_list"), .action = .make_list },
    .{ .ctr = 1, .key = mkey("child_map"), .action = .make_map },
    .{ .ctr = 3, .key = mkey("child_text"), .action = .make_text },
    .{ .ctr = 4, .key = mkey("root_key"), .value = .{ .str = "root" } },

    // `child_map`'s own two registers, in key order. **`deeper` is written
    // once and never again**, which is what makes [`walk_deeper`] an object
    // with no rows.
    .{ .ctr = 5, .obj = walk_map, .key = mkey("deeper"), .action = .make_text },
    .{ .ctr = 6, .obj = walk_map, .key = mkey("inner"), .value = .{ .str = "in" } },

    // `child_list`'s two elements, the second hanging by the first.
    .{ .ctr = 7, .obj = walk_list, .key = head(), .insert = true, .value = .{ .str = "x" } },
    .{ .ctr = 8, .obj = walk_list, .key = at(walk_elem_x), .insert = true, .value = .{ .str = "y" } },

    // `child_text`'s one run. A text object is read as spans, and a span is one
    // answer however wide the run behind it is.
    .{ .ctr = 9, .obj = walk_text, .key = head(), .insert = true, .value = .{ .str = "hi" } },
};

/// **Every answer the walk of [`walk_specs`] owes, and no order.** A table that
/// also spelled the sequence would make a membership failure and an order
/// failure the same failure, so the order is claimed on its own below and this
/// is a **multiset**: the table is as long as the walk's answers, so a row
/// answered twice is a row not answered at all rather than a length that
/// happened to match.
const walk_answers = [_]struct { obj: ExId, key: ?[]const u8, value: []const u8 }{
    // The root's own four registers.
    .{ .obj = .root, .key = "child_list", .value = "list" },
    .{ .obj = .root, .key = "child_map", .value = "map" },
    .{ .obj = .root, .key = "child_text", .value = "text" },
    .{ .obj = .root, .key = "root_key", .value = "root" },
    // `child_map`'s two registers, and an object answers as the name of its
    // type ([`walkTo`] renders it that way).
    .{ .obj = walk_map, .key = "deeper", .value = "text" },
    .{ .obj = walk_map, .key = "inner", .value = "in" },
    // `child_list`'s two elements, and **a sequence item has no key**
    // ([`DocObjItem.key`](iter/doc.zig), `iter/doc.rs:365-371`).
    .{ .obj = walk_list, .key = null, .value = "x" },
    .{ .obj = walk_list, .key = null, .value = "y" },
    // `child_text`'s one span.
    .{ .obj = walk_text, .key = null, .value = "hi" },
    // **And nothing for `deeper`** — see above.
};

/// Whether the answer's key is the one the table names. **A null key is a key
/// of its own**: a sequence item has none, and an absent key is not an empty
/// one.
fn sameWalkKey(want: ?[]const u8, got: ?[]const u8) bool {
    const named = want orelse return got == null;
    const answer = got orelse return false;
    return std.mem.eql(u8, named, answer);
}

test "iter reads every object in causal order, parents before children" {
    const gpa = testing.allocator;
    var doc = try rootMap(gpa, &walk_specs);
    defer doc.deinit();

    // **The object the walk steps over**, stated before anything is read of
    // it: the document holds it and has no row of it, so what the walk skips
    // is a real object and not an id that names nothing.
    try testing.expectEqual(ObjType.text, try doc.objectType(walk_deeper));
    const deeper_rows = try mutableOps(&doc).scopeToObj(walk_deeper);
    try testing.expectEqual(deeper_rows.start, deeper_rows.end);

    const items = try walkTo(gpa, &doc, .root, null);
    defer freeWalk(gpa, items);

    // **Membership: every answer, once each.** The count is the table's own, so
    // a table row that came back twice is a row that came back never — a walk
    // reporting a register it has already spent, or a child twice, cannot hide
    // behind a length.
    try testing.expectEqual(walk_answers.len, items.len);
    for (walk_answers) |want| {
        var found = false;
        for (items) |got| {
            if (found) break;
            found = want.obj.eql(got.obj) and sameWalkKey(want.key, got.key) and
                std.mem.eql(u8, want.value, got.value);
        }
        try testing.expect(found);
    }

    // **The order: which object each answer hangs by, run by run.** The two
    // things `read.rs:64-72` promises are that a parent is read before its
    // children and that, among the children of one parent, the one created
    // first is read first — the queue is taken with the **lowest** id
    // ([`ObjQueue.popLowest`](iter/doc.zig), upstream's
    // `BTreeMap::pop_first`, `iter/doc.rs:243`). **The counters fix the ids
    // and the ids fix this order**, so it is written down once: `child_map` is
    // operation 1, `child_list` 2, `child_text` 3, and `deeper` — operation 5,
    // queued by `child_map`'s own read and drained after all three — answers
    // nothing.
    //
    // **A run and not an item, and that is what makes this an order**: a walk
    // that read a child before its parent, or `child_text` before `child_map`,
    // would give the same four objects in a different sequence, and a run that
    // came back a second time — which is what a walk that went back up the
    // tree looks like — is a run past the table.
    const runs = [_]ExId{ .root, walk_map, walk_list, walk_text };
    var run: usize = 0;
    for (items, 0..) |item, i| {
        if (i != 0 and items[i - 1].obj.eql(item.obj)) continue;
        try testing.expect(run < runs.len);
        try testing.expect(runs[run].eql(item.obj));
        run += 1;
    }
    try testing.expectEqual(runs.len, run);

    // **Inside one object the walk does not reorder.** A run's answers are that
    // object's own rows in the order the op set keeps them, and rule **R2**
    // puts a map's registers in key order — so the keys of a run ascend.
    // **As a property and not as a list**: the membership check above already
    // says which keys came back, and this says the one thing it cannot, that
    // the walk did not put them in an order of its own. A reader that read the
    // root's registers by counter, or in reverse, would answer the same nine
    // items and break here.
    var run_start: usize = 0;
    while (run_start < items.len) {
        var prev: ?[]const u8 = null;
        var end = run_start;
        while (end < items.len and items[end].obj.eql(items[run_start].obj)) : (end += 1) {
            const key = items[end].key orelse continue;
            if (prev) |p| try testing.expect(std.mem.order(u8, p, key) == .lt);
            prev = key;
        }
        run_start = end;
    }
}

test "iterAt reads the subtree under the object it was given, and nothing else" {
    const gpa = testing.allocator;
    // **The same document the walk above reads.** One fixture, so a subtree
    // and a walk of the whole document cannot come to say different things
    // about what it holds.
    var doc = try rootMap(gpa, &walk_specs);
    defer doc.deinit();

    // **A subtree is the same walk started at another object.** Upstream's
    // `iter_at` differs from `iter` only in the object it hands
    // [`DocIter::new`](iter/doc.zig) and in the clock
    // ([`automerge.rs`:2096-2100](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // so the list, the text and the map each answer their own rows and
    // descend into what they name.
    const items = try walkTo(gpa, &doc, walk_list, null);
    defer freeWalk(gpa, items);
    try testing.expectEqual(@as(usize, 2), items.len);
    for (items) |item| try testing.expect(item.obj.eql(walk_list));
    try testing.expectEqualStrings("x", items[0].value);
    try testing.expectEqualStrings("y", items[1].value);
    try testing.expect(items[0].key == null);

    // **An id that names no object is the empty walk**, which is upstream's
    // `.ok().map(..).unwrap_or_else(DocIter::empty)`
    // ([`automerge.rs`:1670-1674](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // — not an error, and not the root's properties.
    const absent = ExId{ .id = OpId.init(999, 0) };
    const none = try walkTo(gpa, &doc, absent, null);
    defer freeWalk(gpa, none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "iterAt at heads the present has moved past reports the state then" {
    const gpa = testing.allocator;
    var f = try atHeadsFixture(gpa);
    defer f.deinit(gpa);

    // Mark boundaries split text spans. The later insert is at index 3,
    // so only the first marked span changes; the trailing span stays put.
    for ([_][]const ChangeHash{ f.first, f.third }, [_][]const u8{ "aaa", "aaaQQQ" }) |heads, want_text| {
        const items = try walkTo(gpa, &f.doc, .root, heads);
        defer freeWalk(gpa, items);
        try testing.expectEqual(@as(usize, 3), items.len);
        try testing.expect(items[0].obj.eql(.root));
        try testing.expectEqualStrings("text", items[0].key.?);
        try testing.expectEqualStrings("text", items[0].value);
        try testing.expectEqualStrings(want_text, items[1].value);
        try testing.expectEqualStrings("bbbccc", items[2].value);
    }

    // A null heads argument uses the document's isolation, not the present.
    try f.doc.isolate(gpa, f.first);
    const isolated = try walkTo(gpa, &f.doc, .root, null);
    defer freeWalk(gpa, isolated);
    try testing.expectEqual(@as(usize, 3), isolated.len);
    try testing.expectEqualStrings("aaa", isolated[1].value);
    try testing.expectEqualStrings("bbbccc", isolated[2].value);
}

// ── Diff against the reference, for the historical-read surface ──────────────
//
// **What the table does not have a row for is the tests.** The block above is
// this surface's specification — one test per `_at` reader for the answer it
// gives at heads behind the present, one more for the same reader at the
// document's own heads, and one per method for `liveObj`/`liveObjOrSelf` being
// present in that method's body. **Twenty-nine tests, each calling exactly one
// reader**, which is what makes one perturbation of the fourteen bodies a
// per-method falsification rather than a joint one; and it was falsified twice
// before it was pasted here. **A method whose dispatch has arms is tested by
// its arms**, and the same argument is the one
// `test "hydrate reads a list and a text object as themselves"` makes for
// `hydrate`'s type dispatch — a root is a map, so a suite that only ever
// hydrates `.root` has never read the `list` or `text` arm.
//
// | Zig 0.16.0 | upstream | Rust | port | does not / is / this |
// | --- | --- | --- | --- | --- |
// | `getAt(doc, obj, prop, heads)` | `ReadDoc::get_at` (`read.rs:266-271`) | `fn get_at<O: AsRef<ExId>, P: Into<Prop>>(&self, obj: O, prop: P, heads: &[ChangeHash]) -> Result<Option<(Value<'_>, ExId)>, AutomergeError>` | `pub fn getAt(doc: *const Document, obj: ExId, prop: Prop, heads: []const ChangeHash) ReadError!?DocItem` | **is** upstream's name and argument order; **does not** return `(Value<'_>, ExId)` — a `DocItem` whose `value` is the port's borrowed `ValueRef`; **is** a free function over `*const Document`, not a trait method |
// | `getAllAt(doc, obj, prop, heads, gpa)` | `ReadDoc::get_all_at` (`read.rs:293-298`) | `-> Result<Vec<(Value<'_>, ExId)>, AutomergeError>` | `-> ReadError![]DocItem` | **takes** an allocator upstream does not — upstream allocates the `Vec`; the twenty-line dispatch is shared with `getAll` through the private `getAllAtScope`, which is upstream's `get_all_for` (`automerge.rs:1891-1927`) |
// | `lengthAt(doc, obj, heads)` | `ReadDoc::length_at` (`read.rs:149`) | `fn length_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> usize` | `-> ReadError!usize` | **is** upstream's answer; **does not** flatten the op set's column errors into `0` — that is `length`'s pre-existing deviation from upstream's `.unwrap_or(0)` (`automerge.rs:1711`) and this method keeps it |
// | `keysAt(doc, obj, heads)` | `ReadDoc::keys_at` (`read.rs:55`) | `fn keys_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Keys<'_>` | `-> ReadError!Keys` | **is** upstream's name and the same walk; **is** clock-scoped by a `Clock` the document owns, because a walk copies the `Clock` and borrows only its `slots` |
// | `valuesAt(doc, obj, heads, term)` | `ReadDoc::values_at` (`read.rs:137`) | `fn values_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Values<'_>` | `-> ReadError!Values` plus `term: *ValueTerm` | **takes** a term upstream does not — `Values` stores `iter: *I` and has no allocator (`iter/values.zig:340-349`), so the term it reads through must outlive it |
// | `textAt(doc, obj, heads, gpa)` | `ReadDoc::text_at` (`read.rs:180-184`) | `-> Result<String, AutomergeError>` | `-> ReadError![]u8` | **is** upstream's name; **does not** return a `String` |
// | `spansAt(doc, obj, heads, gpa)` | `ReadDoc::spans_at` (`read.rs:190-194`) | `-> Result<Spans<'_>, AutomergeError>` | `-> ReadError!Spans` | **takes** an allocator, because the fold allocates where upstream's `Spans` owns its `Arc<MarkSet>`s |
// | `marksAt(doc, obj, heads, gpa)` | `ReadDoc::marks_at` (`read.rs:158-162`) | `-> Result<Vec<Mark>, AutomergeError>` | `-> ReadError![]Mark` | **takes** an allocator: upstream allocates the `Vec` |
// | `mapRangeAt(doc, obj, range, heads)` | `ReadDoc::map_range_at` (`read.rs:99-104`) | `range: R` where `R: RangeBounds<String>` | `range: KeyRange` | **takes** the port's `KeyRange`, which `API.md` specifies and which can name an excluded end that `RangeBounds` cannot reach from a C caller |
// | `listRangeAt(doc, obj, range, heads)` | `ReadDoc::list_range_at` (`read.rs:118-123`) | `range: R` where `R: RangeBounds<usize>` | `range: IndexRange` | **takes** the port's half-open `IndexRange` (`src/iter/list_range.zig:136`), because Zig has no range-bounds protocol |
// | `parentsAt(doc, obj, heads)` | `ReadDoc::parents_at` (`read.rs:40-44`) | `fn parents_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Result<Parents<'_>, AutomergeError>` | `-> ReadError!Parents` | **is** upstream's name; **does not** raise on an id that names nothing — the walk answers nothing, which is `parents`'s pre-existing reduction of upstream's `InvalidObjId` (`automerge.rs:1657`) |
// | `getCursor(doc, obj, pos, heads, gpa)` | `ReadDoc::get_cursor` (`read.rs:199-204`) | `fn get_cursor<O, I: Into<CursorPosition>>(&self, obj: O, position: I, at: Option<&[ChangeHash]>) -> Result<Cursor, AutomergeError>` | `pub fn getCursor(doc: *const Document, obj: ExId, pos: CursorPosition, heads: ?[]const ChangeHash, gpa: Allocator) ReadError!Cursor` | **is** upstream's single signature with the heads in it, **is** its argument order, and **does not** have a second name for the heads: `getCursorAt` was a port-only split and is gone; **names** the parameter `heads`, which is upstream's own binding in the body (`automerge.rs:2175`) rather than a renaming, and **takes** an allocator upstream does not |
// | `getCursorMoving(doc, obj, pos, heads, bias, gpa)` | `ReadDoc::get_cursor_moving` (`read.rs:224-230`) | the same `at: Option<&[ChangeHash]>`, with `move_cursor` after it (`automerge.rs:2179-2188`) | `pub fn getCursorMoving(doc: *const Document, obj: ExId, pos: CursorPosition, heads: ?[]const ChangeHash, bias: Bias, gpa: Allocator) ReadError!Cursor` | **ditto**, and `getCursorMovingAt` is gone |
// | `getCursorPosition(doc, obj, cursor, heads)` | `ReadDoc::get_cursor_position` (`read.rs:237-242`) | the same `at: Option<&[ChangeHash]>` (`automerge.rs:2190-2198`) | `pub fn getCursorPosition(doc: *const Document, obj: ExId, cursor: Cursor, heads: ?[]const ChangeHash) ReadError!usize` | **ditto**, and `getCursorPositionAt` is gone; **is** upstream's two-line `Automerge` wrapper (`let clock = at.and_then(\|heads\| self.clock_at(heads)); self.get_cursor_position_for(obj, cursor, clock)`) and **is not** `AutoCommit`'s, which resolves the same `at` through `get_scope` (`autocommit.rs:794-805`) and takes a different arm while a transaction is in flight; **the relabel now lives one function down**, in `getCursorPositionFor` |
// | `getCursorPositionFor(doc, obj, cursor, scope)` | `Automerge::get_cursor_position_for` (`automerge.rs:1760-1849`) | `pub(crate) fn get_cursor_position_for(&self, obj: &ExId, cursor: &Cursor, clock: Option<Clock>) -> Result<usize, AutomergeError>` | `pub fn getCursorPositionFor(doc: *const Document, obj: ExId, cursor: Cursor, scope: ?Clock) ReadError!usize` | **is** that helper, **and it is what both `ReadDoc` receivers reach underneath** (`automerge.rs:2197`, `autocommit.rs:1003`); **takes the clock rather than the heads** because the two receivers build it differently and the difference is load-bearing; **relabels** the op set's `error.InvalidIndex` for a cursor naming a row of another object as `error.InvalidCursor`, which is upstream's own `.ok_or_else(\|\| InvalidCursor(cursor.clone()))` on the seek's `None` (`automerge.rs:1778-1781`) — the seek cannot raise upstream, and the port's can (`op_set.zig:3145`) — **and that is the layer upstream puts it on** |
// | `hydrate(doc, obj, heads, gpa)` | `Automerge::hydrate_obj` (`automerge.rs:1638-1650`) | `let clock = heads.and_then(\|h\| self.clock_at(h));` (`:1644`, and `:2228` for `ReadDoc::hydrate`) | `heads: ?[]const ChangeHash` | **builds** the clock through `ChangeGraph.clockAt` where upstream **shortcuts** through `Automerge::clock_at`, which answers no clock for the present's own heads (`:1236-1247`); **the answers agree** — a full clock over the present is the present — **and the work does not** |
// | `markSetAtIndex(doc, obj, index, heads, gpa)` | `Automerge::get_marks` / `AutoCommit::get_scope` (`automerge.rs:2236-2244`, `autocommit.rs:794-805`) | `heads.and_then(\|h\| self.clock_at(h))` (`:2242`), and `clock_at` from `get_scope`'s first arm when no transaction is in flight (`autocommit.rs:800-804`) | the same `heads: ?[]const ChangeHash` | **as** `hydrate`: the `Some` arm keeps a full clock upstream does not build, so it takes `markSetAtScope`'s walk where upstream takes `get_marks_fast` (`:1937-1938`); **the answer is the same** and the test `markSetAtIndex answers the set at one index, and the heads decide which path reads it` reads both arms |
// | `Document.clockAtScope(gpa, heads)` | `Automerge::clock_at` (`automerge.rs:1236-1247`) | `pub(crate) fn clock_at(&self, heads: &[ChangeHash]) -> Option<Clock>` | `pub fn clockAtScope(self: *Document, gpa: Allocator, heads: []const ChangeHash) Error!?*const clockmod.Clock` | **is** upstream's resolution for every `*_at`, heads-are-current shortcut included; **borrows** where upstream moves, and the document caches the one clock and frees the previous pair |
