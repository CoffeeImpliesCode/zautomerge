//! The root of the iteration module: upstream's
//! `rust/automerge/src/iter.rs`, which is twenty-five lines and **declares no
//! algorithm at all** — six `mod` lines, one `pub(crate) mod`, nine `use` lines
//! and one `#[cfg(test)] use`
//! ([`iter.rs:1-25`](../../github-automerge-automerge/rust/automerge/src/iter.rs)).
//! It is a table of contents, and so is this file.
//!
//! # What this file owns
//!
//! **Names, and nothing else.** There is no walk here, no cursor and no
//! allocator, because there is none upstream. A behaviour question that arrives
//! with this file's name on it has its answer in one of the seven siblings
//! below, and the citation on the name says which one.
//!
//! # The seven siblings, and why each is its own file
//!
//! | reached as | upstream | it owns |
//! |---|---|---|
//! | [`tools`] | `iter/tools.rs` (627 lines) | the two lookahead wrappers, the skip filter and the diff kernel every read here is composed from |
//! | [`doc`] | `iter/doc.rs` (603 lines) | the handle a walk runs against, and the walk over a document's objects |
//! | [`keys`] | `iter/keys.rs` (90 lines) | one key string per register |
//! | [`values`] | `iter/values.rs` (36 lines) | one `(value, op id)` pair per register |
//! | [`list_range`] | `iter/list_range.rs` (441 lines) | one entry per **visible** element of a sequence |
//! | [`map_range`] | `iter/map_range.rs` (328 lines) | one row per key of a map object |
//! | [`spans`] | `iter/spans.rs` (684 lines) | one span per run of graphemes, carrying the marks over it |
//!
//! Three reasons, and the first is the load-bearing one.
//!
//! * **The unit differs, and it is the only difference that matters.** A key
//!   walk answers one key per register, a list walk one entry per *visible*
//!   element, a spans walk one span per run of graphemes and marks, and the
//!   object walk one object per document object. These are not one walk with a
//!   flag on it: [`spans.zig`](spans.zig) folds the mark operations interleaved
//!   with the text (`spans.rs:492-511`), which no other reader in this
//!   directory does at all, and [`list_range.zig`](list_range.zig) reports an
//!   element's **width**, which is a text-index question only a sequence asks.
//! * **The toolkit is generic over any cursor and the other six are
//!   compositions of it.** [`tools.Unshift`] draws its lookahead in `init` so
//!   a `peek` needs no `*Self`, and [`tools.DiffKernel`] is three type
//!   parameters wide. A root that owned them would put `SkipIter`'s three and
//!   `ItemOf`'s one into the namespace of every reader in the directory.
//! * **The sizes.** [`spans.zig`](spans.zig) is over a thousand lines on its
//!   own. A facade that also held a thousand-line reader would not be a facade,
//!   and the reader it held would be the one everybody found first.
//!
//! # What is flat here and what is reached through a module
//!
//! **The rule: flat is what upstream's `iter.rs` names on a `use` line, and
//! nothing else.** Upstream exports `DocItem`, `DocIter`, `DocObjItem`,
//! `Keys`, `ListRange`, `ListRangeItem`, `MapRange`, `MapRangeItem`, `Span`,
//! `Spans`, `Values`, `DiffIter`, `ListDiff`, `ListDiffItem`, `MapDiff`,
//! `MapDiffItem`, `Diff`, `RichTextDiff`, `SpanDiff`, `SpanInternal`,
//! `SpansDiff`, `SpansInternal` and `KeyOpIter`
//! ([`iter.rs:10-25`](../../github-automerge-automerge/rust/automerge/src/iter.rs)).
//! Everything it reaches instead as `crate::iter::tools::X` — `Unshift`,
//! `PeekShift`, `SkipWrap`, `SkipIter`, `MergeIter`, `ExIdPromise`,
//! `BoolColumnSkipper` and the rest — is reached here as
//! `slice.tools.X`, which is the same reach at the same visibility. A name
//! upstream's root does not export is a name upstream's root does not want in
//! every reader's namespace, and widening the namespace is how two spellings
//! of one type come to exist.
//!
//! Three names the port adds, each forced by a generic signature upstream does
//! not have, and each in its own section below rather than smuggled in beside
//! the names upstream exports.
//!
//! # [`Doc`] borrows, and the borrow is the whole contract
//!
//! **It holds a `*opset.OpSet(O)` and a `TextEncoding`, and it holds no
//! document and no `*const Document`.** Upstream has no `Doc` type at all: the
//! borrow lives in `DocIter<'a>` as `ops: &'a OpSet` plus the `Automerge` it
//! was built from ([`DocIter::new`](doc.zig), `iter/doc.rs:42-50`), and the
//! port spells that borrow as a named type so a reader is not left inferring
//! it from two constructor arguments.
//!
//! **What the port's `Document` does to that borrow, and why it must not be
//! undone.** The port's [`Document`](../../src/doc.zig) is returned **by
//! value** — `Document.init` and `Document.load` both hand one back — and the
//! op set captures the document's string table: `StringTable.ctx` is a pointer
//! to it. Two consequences, and they point in opposite directions.
//!
//! * The string table is **heap allocated** and the document keeps a pointer to
//!   it ([`src/doc.zig:2155`](../../src/doc.zig) declares `strings: *Strings`,
//!   and [`src/doc.zig:2217`](../../src/doc.zig) allocates it), so *relocating*
//!   a `Document` by value does not relocate the table and every walk built over
//!   it stays valid across the move. That is what makes a by-value return safe
//!   at all, and it is a decision that must not be undone: inlining the table
//!   would make every `Doc` built over a returned document a dangling pointer.
//! * The **op set itself is stored inline** in the document, so a [`Doc`]
//!   taken over `document.ops` is a borrow of that field. The document must not
//!   be moved, returned by value again, or freed while the handle or any walk
//!   built from it is alive.
//!
//! A reader cannot infer either half from two struct fields, which is why the
//! second half is written here and is pinned by the test "the handle is a
//! borrowed op set and an encoding, and it holds no document".
//!
//! # What upstream's root names and this port has not got
//!
//! **Three names, and all three are gaps in [`doc`]**, which is a sibling and
//! not this file's to write. **Corrected 2026-10-01**: this table used to say
//! four, and the fourth (`doc::DiffIter`) was wrong — it has been ported, as
//! [`doc.DiffIter`](doc.zig), and four callers in
//! [src/doc.zig](../../src/doc.zig) reach for it. The `DocIter` row used to
//! call itself a deliberate rename, and that was wrong too.
//!
//! | upstream | where | what it is |
//! |---|---|---|
//! | `DocIter` | `iter/doc.rs:19-50`, walked at `iter/doc.rs:288-315` | the **recursive** walk over a document's objects: a `BTreeMap<ObjId, IterType>` of children (`iter/doc.rs:55`), a `path_map` (`iter/doc.rs:56`), and one each of `MapRange`, `ListRange` and `SpansInternal` (`iter/doc.rs:58-60`), draining the current object before moving to the next (`iter/doc.rs:224-232`, `:270-285`). **Not ported, and not a rename of [`ObjIdIter`]**: [`ObjIdIter`](doc.zig) is `OpSet::obj_id_iter` (`op_set.rs:1344-1346`) — one object per step and nothing else — where upstream's `DocIter` reads *properties* through the three leaf readers and fills a `path_map`. Calling it a rename gave the port a name for a type it does not have, and it is the only `#[test]` in `iter/doc.rs` (`doc_iter`, `iter/doc.rs:530-602`) with no port beside it. |
//! | `DocObjItem` | `iter/doc.rs:337-341` | that item's object arm, with `key()` and `value()` (`iter/doc.rs:346-361`) |
//! | `DocItem` | `iter/doc.rs:383-388` | the per-object item a document walk hands out, with `id()` and `value()` (`iter/doc.rs:509-527`) |
//!
//! **`doc::DiffIter` (`iter/doc.rs:66-76`, walked at `iter/doc.rs:306-315`) is
//! ported**, as [`doc.DiffIter`](doc.zig) — `iter/doc.rs:79-92`'s `log` and
//! the same `next_object`/`next_prop` pair `DocIter` has. **Which of
//! `iter.rs:17` and `iter.rs:20` is which**, since they are separate lines:
//! `:17` is `pub(crate) use doc::DiffIter` — the document diff, the one
//! patched over — and `:20` is `pub(crate) use tools::Diff`, the
//! `Same`/`Add`/`Del` tag at
//! [`iter/tools.rs:610-616`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs),
//! which is what the *range* diff tags its rows with. Different types,
//! different modules, so different lines. **The port's
//! [`tools.DiffKernel`] is upstream's *other* `DiffIter`**
//! ([`iter/tools.rs:528-608`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)):
//! the generic three-parameter diff over a range of rows, which upstream also
//! names `DiffIter` and keeps private to `iter::tools` — the port renames it
//! so `DiffIter` means the document diff in every file here, the one `iter.rs`
//! exports on that line.
//!
//! `KeyOpIter` (`iter.rs:25`) is the fourth and is **not a gap**: it is
//! `#[cfg(test)]` upstream (`keys.rs:53-90`) and is not ported.
//! [`keys.zig`](keys.zig) records the same decision.

const std = @import("std");
const types = @import("../types.zig");
const batch = @import("../opset/batch.zig");

// ── The submodules, one per upstream `mod` line ─────────────────────────────

/// The iteration toolkit: the lookahead wrappers, the skip filter and the diff
/// kernel ([`iter/tools.rs`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs),
/// `iter.rs:8`, 627 lines).
///
/// Upstream's is `pub(crate) mod tools`, so it is reachable as
/// `crate::iter::tools::X` and the root exports exactly one of its items,
/// [`Diff`]. Everything else — [`Unshift`], [`PeekShift`], [`SkipWrap`],
/// [`SkipIter`], [`MergeIter`], [`ExIdPromise`] — is reached as
/// `tools.Unshift` and not from the root.
pub const tools = @import("tools.zig");

/// The handle a walk runs against, and the walk over a document's objects
/// ([`iter/doc.rs`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
/// `iter.rs:1`, 603 lines).
///
/// Upstream's is `mod doc` and the root exports `DocItem`, `DocIter` and
/// `DocObjItem` from it (`iter.rs:10`); the port's exports are [`Doc`], the
/// handle, and [`ObjIdIter`], the walk — see the module's table of what is
/// missing and why.
pub const doc = @import("doc.zig");

/// One key string per register ([`iter/keys.rs`](../../github-automerge-automerge/rust/automerge/src/iter/keys.rs),
/// `iter.rs:2`, 90 lines).
pub const keys = @import("keys.zig");

/// One `(value, op id)` pair per register
/// ([`iter/values.rs`](../../github-automerge-automerge/rust/automerge/src/iter/values.rs),
/// `iter.rs:6`, 36 lines).
pub const values = @import("values.zig");

/// One entry per **visible** element of a sequence, with its index, its value
/// and its width ([`iter/list_range.rs`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs),
/// `iter.rs:3`, 441 lines).
pub const list_range = @import("list_range.zig");

/// One row per key of a map object, carrying the key, the value a reader sees
/// and whether the register is conflicted
/// ([`iter/map_range.rs`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs),
/// `iter.rs:4`, 328 lines).
pub const map_range = @import("map_range.zig");

/// One span per run of graphemes and block markers, each carrying the marks
/// that were active over it ([`iter/spans.rs`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
/// `iter.rs:5`, 684 lines).
pub const spans = @import("spans.zig");

// ── `iter.rs:10` — doc ───────────────────────────────────────────────────────

/// The handle a document walk runs against: the op set, and how the document
/// measures its text ([`Doc`](doc.zig), `iter/doc.rs:42-50`).
///
/// **This is the port's spelling of upstream's `&'a Automerge` borrow**, which
/// upstream keeps as a field of `DocIter<'a>` rather than as a type of its
/// own. Its lifetime is the module's third section and it is stated there in
/// full: it borrows an op set that must not move under it.
pub const Doc = doc.Doc;

/// Every object a document holds, once each, in row order, narrowed to a clock
/// ([`ObjIdIter`](doc.zig)).
///
/// **Upstream's [`DocIter`](doc.zig)**
/// ([`iter/doc.rs`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
/// `iter.rs:10`, `iter/doc.rs:19-76`), renamed because this port's answers one
/// *object* per step — which is what `OpSet::obj_id_iter`
/// ([`op_set.rs:1344-1346`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs))
/// is — and a second type called `DocIter` beside `opiter.ObjIdIter` would be
/// a second source of truth for "where does an object end".
pub const ObjIdIter = doc.ObjIdIter;

/// What reading a document's objects can fail with ([`DocError`](doc.zig)).
///
/// **Not upstream**: `iter.rs:10` exports no error name and `iter/doc.rs`
/// returns `Result<_, OpQueryError>`. The port needs the set in a signature, so
/// it names it here rather than in each of the twenty-odd call sites that would
/// otherwise spell it out.
pub const DocError = doc.DocError;

// ── `iter.rs:11` — keys ──────────────────────────────────────────────────────

/// An object's keys, in row order, one per visible register
/// ([`Keys`](keys.zig), `iter.rs:11`, `iter/keys.rs:8-11`).
pub const Keys = keys.Keys;

/// What reading an object's keys can fail with
/// ([`KeysError`](keys.zig), `keys.zig:119`).
///
/// **Not upstream**, for the reason [`DocError`] gives: upstream's `Keys`
/// returns upstream's `OpQueryError` and `iter.rs:11` exports no name for it.
/// It is a **subset of [`ReadError`]** — the same union without the
/// [`ParseError`](../../src/error.zig) arm, which the three range readers add
/// because a counter's value is read through
/// [`OpSet.getIncrementDiffAtPos`](../opset/op_set.zig) — so a caller holding
/// both names can widen with the one it already has.
pub const KeysError = keys.KeysError;

// ── `iter.rs:12,18` — list_range ─────────────────────────────────────────────

/// One entry per visible element of a sequence
/// ([`ListRange`](list_range.zig), `iter.rs:12`, `list_range.rs:214-241`).
pub const ListRange = list_range.ListRange;

/// That entry: the element's index, its value and its width in the document's
/// text encoding ([`ListRangeItem`](list_range.zig), `iter.rs:12`,
/// `list_range.rs:16-24`).
pub const ListRangeItem = list_range.ListRangeItem;

/// What happened to a sequence's rows between two states, one entry each
/// ([`ListDiff`](list_range.zig), `iter.rs:18`).
///
/// **`pub(crate)` upstream and `pub` here** because the port has no `pub(crate)`:
/// the distinction upstream draws with visibility is the distinction the port
/// draws with naming — a diff is what a *patch* run reads
/// ([`map_range.zig`](map_range.zig)'s second section) and a range is what a
/// *read* hands a caller, and the two names are what keeps them apart.
pub const ListDiff = list_range.ListDiff;

/// One entry of a sequence's diff, before it is exported to a caller
/// ([`ListDiffItem`](list_range.zig), `iter.rs:18`).
pub const ListDiffItem = list_range.ListDiffItem;

// ── `iter.rs:13,19` — map_range ──────────────────────────────────────────────

/// A map object's visible keys, one at a time
/// ([`MapRange`](map_range.zig), `iter.rs:13`, `map_range.rs:94-213`).
pub const MapRange = map_range.MapRange;

/// That row: the key, the value a reader sees, whether the register is
/// conflicted, the row it was read from and its id
/// ([`MapRangeItem`](map_range.zig), `iter.rs:13`, `map_range.rs:13-20`).
pub const MapRangeItem = map_range.MapRangeItem;

/// What happened to a map's rows between two states, one entry each
/// ([`MapDiff`](map_range.zig), `iter.rs:19`).
///
/// `pub(crate)` upstream for the reason [`ListDiff`] gives above.
pub const MapDiff = map_range.MapDiff;

/// One entry of a map's diff, before it is exported to a caller
/// ([`MapDiffItem`](map_range.zig), `iter.rs:19`).
pub const MapDiffItem = map_range.MapDiffItem;

/// Everything the three range readers can fail with
/// ([`ReadError`](map_range.zig)).
///
/// **Not upstream**, for the reason [`DocError`] gives, and it is the map
/// reader's because the map reader is the one the list reader and the spans
/// reader both build on: `iter/list_range.zig` and `iter/spans.zig` name
/// `map_range.ReadError` as their own.
pub const ReadError = map_range.ReadError;

// ── `iter.rs:14,22` — spans ──────────────────────────────────────────────────

/// One run of a text object: text, a block marker, or a gap, with the marks
/// that were active over it ([`Span`](spans.zig), `iter.rs:14`).
pub const Span = spans.Span;

/// A text object as a sequence of spans, each carrying its marks
/// ([`Spans`](spans.zig), `iter.rs:14`, `spans.rs:117-141`).
pub const Spans = spans.Spans;

/// A span's diff tag and marks as they were at one state
/// ([`SpanDiff`](spans.zig), `iter.rs:22`).
pub const SpanDiff = spans.SpanDiff;

/// A span read from raw rows, before the reader has decided what to coalesce
/// ([`SpanInternal`](spans.zig), `iter.rs:22`).
pub const SpanInternal = spans.SpanInternal;

/// A text object's spans as a diff between two states
/// ([`SpansDiff`](spans.zig), `iter.rs:22`).
pub const SpansDiff = spans.SpansDiff;

/// The row-level walk a spans reader is built on, before the coalescing
/// ([`SpansInternal`](spans.zig), `iter.rs:22`).
pub const SpansInternal = spans.SpansInternal;

/// A `MarkStateMachine` for the document and one for the merge, and the marks
/// they disagree about ([`RichTextDiff`](../../opset/batch.zig),
/// `iter.rs:22`, `spans.rs:648-679`).
///
/// **Upstream declares it in `iter/spans.rs`; this port declares it in
/// `opset/batch.zig` and that placement is forced, not chosen.** Upstream
/// `spans.rs:648` defines it, `iter.rs:22` re-exports it, and
/// `op_set2/change/batch.rs:3` imports it *back out of the iter root*
/// (`use crate::iter::RichTextDiff`). In Zig the import direction cannot be
/// mutual: `spans.zig` already imports `batch.zig`, so a `batch.zig` that
/// imported `spans.zig` would be a cycle. The type therefore lives in the
/// module that has to use it and the root re-exports it under upstream's name,
/// so a consumer writes `slice.RichTextDiff` and reads
/// `spans.rs:648-679`, exactly as upstream's consumer does.
pub const RichTextDiff = batch.RichTextDiff;

// ── `iter.rs:15` — values ────────────────────────────────────────────────────

/// An object's values, with the id of the operation each came from
/// ([`Values`](values.zig), `iter.rs:15`, `values.rs:8-11`).
pub const Values = values.Values;

/// One value and the operation that put it there
/// ([`ValuesItem`](values.zig), `values.rs:27`).
///
/// **Not upstream**: upstream's item is the bare tuple `(types::Value<'a>,
/// ExId)` (`values.rs:26`) and a Zig tuple cannot be named in a signature, so
/// the pair needs a name for [`Values.next`] to return one
/// ([values.zig:139-168](values.zig)).
pub const ValuesItem = values.ValuesItem;

/// What reading values can fail with ([`ValuesError`](values.zig),
/// `values.zig:145`).
///
/// **Not upstream**, for the reason [`DocError`] gives.
pub const ValuesError = values.ValuesError;

/// A raw row walk as a query term — one of the two inners a [`Values`] can be
/// built over ([`RowQuery`](values.zig), `op_query.rs:48-56`).
///
/// **Not upstream as a type**: upstream's inner is a `Box<dyn OpQueryTerm>`
/// and the two impls are the trait impls on `OpIter` and `TopOps`. Zig has no
/// trait objects, so each impl becomes the type that carries its methods
/// ([values.zig:190-204](values.zig)).
pub const RowQuery = values.RowQuery;

/// A winner walk as a query term, the other of the two inners
/// ([`TopQuery`](values.zig), `top_op.rs:67-75`).
///
/// Not upstream as a type, for the reason [`RowQuery`] gives.
pub const TopQuery = values.TopQuery;

// ── `iter.rs:20` — tools ─────────────────────────────────────────────────────

/// Whether a row is the same in two states, added, or gone
/// ([`Diff`](tools.zig), `iter.rs:20`, `iter/tools.rs:610-616`).
///
/// The one item of [`tools`] upstream's root exports flat, and the only
/// enumeration every diff reader in this directory tags its rows with.
/// **`iter.rs:20` is this and not the document diff** — `iter.rs:17` is the
/// `doc` one, the gap this file's table records.
pub const Diff = tools.Diff;

// The diff kernel the three range readers are built on
// ([`DiffKernel`](tools.zig), `iter/tools.rs:528-608`) has **no `pub const`
// here, and deliberately**: upstream's `iter.rs` re-exports one item of `tools`
// and this is not it, so a root export would put a name in every reader's
// namespace that the rule above this section keeps out. It is reached as
// `tools.DiffKernel`, where upstream reaches it as `iter::tools::DiffIter` —
// renamed because upstream has two types by that name and `iter.rs:17` exports
// the other one. **This note is a file comment and not a doc comment on the
// declaration below**, because it is about a name this file does not export.
/// The repositioning kernel every cursor in this directory carries
/// ([`Shiftable`](tools.zig), `iter/tools.rs:62`).
///
/// `pub(crate) trait Shiftable` upstream, reached as `iter::tools::Shiftable`
/// and not from the root. **The port re-exports it from `tools` rather than
/// leaving each reader to name `hexane/column.zig`**, which is what
/// [`doc.zig`](doc.zig) already does at its own level
/// ([doc.zig:187](doc.zig)).
pub const Shiftable = tools.Shiftable;

// ── The re-exports resolve ───────────────────────────────────────────────────
//
// Comptime, and not in a test: a rename in a sibling is then a *compile error
// in this file*, which names the sibling and the line, rather than a failure
// three files away in a caller. Every name below is a re-export and not a copy,
// so naming it here is the whole of the check — there is no second declaration
// in this file for a rename to miss.

comptime {
    _ = Doc;
    _ = ObjIdIter;
    _ = DocError;
    _ = Keys;
    _ = KeysError;
    _ = ListRange;
    _ = ListRangeItem;
    _ = ListDiff;
    _ = ListDiffItem;
    _ = MapRange;
    _ = MapRangeItem;
    _ = MapDiff;
    _ = MapDiffItem;
    _ = ReadError;
    _ = Span;
    _ = Spans;
    _ = SpanDiff;
    _ = SpanInternal;
    _ = SpansDiff;
    _ = SpansInternal;
    _ = RichTextDiff;
    _ = Values;
    _ = ValuesItem;
    _ = ValuesError;
    _ = RowQuery;
    _ = TopQuery;
    _ = Diff;
    _ = Shiftable;
    _ = tools;
    _ = doc;
    _ = keys;
    _ = values;
    _ = list_range;
    _ = map_range;
    _ = spans;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const clockmod = @import("../clock.zig");
const optypes = @import("../opset/types.zig");
const opcols = @import("../opset/columns.zig");
const opmod = @import("../opset/op.zig");
const opset = @import("../opset/op_set.zig");

const Allocator = std.mem.Allocator;
const Clock = clockmod.Clock;
const KeyRef = optypes.KeyRef;
const ScalarValue = optypes.ScalarValue;
const ValueRef = optypes.ValueRef;

/// The concrete op set the fixture is read through, for the reason
/// [`keys.zig`](keys.zig) gives: [`opmod.Op`] borrows its row's successors and
/// its value, so a fixture is an array of `Op` over its own storage and needs
/// no allocator for them, and the index columns come from
/// [`OpSet.rebuildIndex`](../../opset/op_set.zig) rather than from the rows.
const Set = opset.OpSet(opmod.Op);

/// The encoding the fixture is built with, so a width is a count of code
/// points and not a count of bytes.
const encoding: types.TextEncoding = .unicode_code_point;

const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };

fn opId(ctr: u32, actor: types.ActorIdx) types.OpId {
    return types.OpId.init(ctr, actor);
}

fn made(ctr: u32, actor: types.ActorIdx) types.ExId {
    return .{ .id = opId(ctr, actor) };
}

fn anchor(id: types.OpId) KeyRef {
    return .{ .seq = types.ElemId.fromOpId(id) };
}

fn head() KeyRef {
    return .{ .seq = types.ElemId.head() };
}

fn row(
    id: types.OpId,
    obj: types.ExId,
    key: KeyRef,
    insert: bool,
    act: optypes.Action,
    val: ScalarValue,
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
        opmod.SuccCursors.none(),
    );
}

fn mapRow(
    id: types.OpId,
    obj: types.ExId,
    key: []const u8,
    val: ScalarValue,
) opmod.Op {
    return row(id, obj, .{ .map = key }, false, .set, val);
}

/// The string table the fixture's op set borrows.
///
/// **Heap-allocated, and that is an ownership rule and not a convenience**, the
/// same rule [`src/doc.zig`](../../src/doc.zig) applies to `Document.strings`:
/// the op set captures `&table`, so the table has to sit at one address for as
/// long as the set does, and a struct that owned the table and were returned
/// by value would leave the set's `strings.ctx` pointing at a dead frame.
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
    fn intern(ctx: *const anyopaque, text: []const u8, gpa: Allocator) types.ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(@constCast(ctx)));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, text)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse return error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, text));
        return id;
    }
};

/// The op set, the table it borrows and the rows, **heap allocated together**.
///
/// **The allocation is the point.** A [`Document`](../../src/doc.zig) stores its
/// op set *inline* and is returned by value, so a handle taken over
/// `document.ops` borrows a field that a later move would relocate. This
/// fixture puts the same set at one address for its whole life, which is what
/// the module's third section says a caller owes a handle — and the test
/// "a handle over an op set answers, and the op set is what keeps it alive"
/// walks one built this way.
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
        // **The index is derived, never declared**: a row carries no statement
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

/// The document every test here reads from: a root map with three keys, and a
/// list it holds.
///
/// Objects **ascend** (rule **R1**, `op_set2/op.rs:1049-1054`) and map
/// registers **ascend by key string** within an object
/// (`op_set2/op.rs:1059-1060`), so the root's three rows come before the list's
/// one and `"a"`, `"b"`, `"l"` are already in order. The list's element is
/// anchored to the head, which opens the first sequence register of its object
/// (rule **R4**, `op_set2/op.rs:1061-1063`).
///
/// **The list's id is the operation that made it, at counter 3**
/// ([`OpSet.objectIdAt`](../../opset/op_set.zig), `op_set.rs:1287-1291`), which
/// is what makes the clock below a real narrowing rather than a coincidence: a
/// clock stopping at counter 2 does not cover the operation that created the
/// list, so the list cannot be in that state
/// ([`doc.zig:883-893`](doc.zig)).
const list_obj = made(3, 0);

fn threeKeyDoc(gpa: Allocator) !*Fixture {
    return Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }),
        mapRow(opId(2, 0), .root, "b", .{ .int = 2 }),
        row(opId(3, 0), .root, .{ .map = "l" }, false, .make_list, .null_value),
        row(opId(4, 0), list_obj, head(), true, .set, .{ .str = "x" }),
    });
}

/// `ValueRef` equality as upstream's `PartialEq` means it
/// ([map_range.zig:1198-1205](map_range.zig)), spelled here rather than
/// imported because the two walks below are compared against each other and
/// not against a literal.
fn sameValue(got: ValueRef, want: ValueRef) !void {
    if (std.meta.activeTag(got) != std.meta.activeTag(want)) return error.TestExpectedEqual;
    switch (want) {
        .object => |o| try testing.expectEqual(o, got.object),
        .scalar => |s| try testing.expect(s.eql(got.scalar)),
    }
}

// ── The tests ───────────────────────────────────────────────────────────────

test "a handle over an op set answers, and the op set is what keeps it alive" {
    // `FailingAllocator` with no `fail_index` never fails and counts every
    // byte its inner allocator hands out, so it is a counter and a real
    // allocator at once. It is the **op set's** allocator, which is the only
    // allocator a handle or a walk can reach: neither [`Doc`] nor
    // [`ObjIdIter`] has one of its own, so an allocation in either would come
    // through here.
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counter.allocator();

    const fx = try threeKeyDoc(gpa);
    defer fx.destroy();
    const before = counter.allocated_bytes;

    // **Constructing the handle allocates nothing**: a pointer and an enum.
    // "A borrowed slice is valid only while its owner is" and a handle is
    // borrowed whole.
    const handle: Doc(opmod.Op) = .init(&fx.set, encoding);
    try testing.expectEqual(before, counter.allocated_bytes);

    // **And it carries the document's own encoding**, because a width read in
    // the wrong one is a reader that looks right and indexes wrong.
    try testing.expectEqual(encoding, handle.text_encoding);
    try testing.expectEqual(encoding, fx.set.text_encoding);

    // **The walk answers.** Two objects, in row order: the root and the list
    // its `"l"` key makes. The ids are compared, not the count, so a walk that
    // answered nothing — or answered the same object twice — fails.
    var it = try handle.objIdIter(null);
    try testing.expectEqual(before, counter.allocated_bytes);
    const first = (try it.next()) orelse return error.TestExpectedItem;
    try testing.expect(first.eql(.root));
    const second = (try it.next()) orelse return error.TestExpectedItem;
    try testing.expect(second.eql(list_obj));
    try testing.expect((try it.next()) == null);
    try testing.expectEqual(before, counter.allocated_bytes);

    // **What keeps the document alive: the op set, at the address it had when
    // the handle took it.** `Fixture` is heap allocated, so `fx.set` is the
    // same object for the whole block above and the handle's `*Set` stays
    // valid; the same is true of a real document because
    // [`Document.init`](../../src/doc.zig) heap allocates its `*Strings` and
    // keeps the pointer, so a by-value `Document` return relocates the
    // document but not the table the op set points into. **The op set is the
    // one thing a move would still relocate**, which is why a caller that has
    // taken a handle must not move the document again. The test below pins the
    // half of that contract a type can pin, and this is the half only the
    // caller can honour.

    // **A clock is borrowed, not copied**, and narrowing to it costs nothing to
    // hand over: the root existed at counter 3, so a clock through 3 still
    // sees both objects and one through 2 does not.
    var clock = try Clock.init(gpa, 1);
    defer clock.deinit();
    _ = clock.include(0, 2);
    // **Re-based after the clock's own allocation**: `Clock.init` allocates its
    // slot array, so the counter has legitimately moved and the property under
    // test is what *handing the clock over* costs, not the clock.
    const with_clock = counter.allocated_bytes;
    var narrowed = try handle.objIdIter(clock);
    try testing.expectEqual(with_clock, counter.allocated_bytes);
    const only = (try narrowed.next()) orelse return error.TestExpectedItem;
    try testing.expect(only.eql(.root));
    try testing.expect((try narrowed.next()) == null);
}

test "the handle is a borrowed op set and an encoding, and it holds no document" {
    // **The contract the module's third section is about, stated as a type.**
    // A `Doc` that held a `*const Document`, or an owned copy of one, would be
    // a different promise: the caller could then move the document and the
    // handle would follow it, and every op set it hands out would be reading
    // from wherever the document last was. There is no such field, and these
    // three assertions fail the moment one is added.
    const info = @typeInfo(Doc(opmod.Op)).@"struct";
    try testing.expectEqual(@as(usize, 2), info.field_types.len);
    try testing.expect(info.field_types[0] == *Set);
    try testing.expect(info.field_types[1] == types.TextEncoding);

    // **Which is also the answer to "what does a handle allocate".** Two
    // fields, one a pointer and one a one-byte enum: a handle is a value, it
    // owns nothing, and it has no `deinit` to get wrong. The size is *not*
    // `sizeOf(usize) + sizeOf(enum)` — the struct is padded out to the
    // pointer's alignment, so it is checked as the padded sum instead.
    try testing.expectEqual(
        std.mem.alignForward(usize, @sizeOf(usize) + @sizeOf(types.TextEncoding), @alignOf(usize)),
        @sizeOf(Doc(opmod.Op)),
    );
    try testing.expectEqual(@sizeOf(usize), @alignOf(Doc(opmod.Op)));
}

test "a map walked through this root is the same walk as one reached directly" {
    const gpa = testing.allocator;
    const fx = try threeKeyDoc(gpa);
    defer fx.destroy();

    // **Two walks over the same object, one of each spelling**, both read to
    // exhaustion and compared row for row. The rows are compared by key bytes
    // and by value, because `expectEqual` on two slices compares their
    // *pointers* ([`std/testing.zig:130-139`](../../lib/std/testing.zig)) and a
    // key here is a borrow whose address says nothing.
    //
    // This is the test that says the re-exports are the same types and not
    // copies. A copy of `Keys` that agreed today would still be a second
    // source of truth, and the drift is what this file exists to prevent.
    var through_root = try Keys(opmod.Op).ofObj(&fx.set, .root, null);
    defer through_root.deinit(gpa);
    var direct = try keys.Keys(opmod.Op).ofObj(&fx.set, .root, null);
    defer direct.deinit(gpa);

    for ([_][]const u8{ "a", "b", "l" }) |want| {
        const got = (try through_root.next()) orelse return error.TestExpectedResult;
        const other = (try direct.next()) orelse return error.TestExpectedResult;
        try testing.expectEqualStrings(want, got);
        try testing.expectEqualStrings(got, other);
    }
    try testing.expect((try through_root.next()) == null);
    try testing.expect((try direct.next()) == null);

    // **And the same for the reader that carries values, not names**, because
    // one walk agreeing says nothing about the other: the map reader is a
    // different type, a different file and a different upstream file, so it
    // gets its own round trip.
    var root_range = try MapRange(opmod.Op).init(
        &fx.set,
        try fx.set.scopeToObj(.root),
        null,
    );
    // **No `deinit`**, because a `MapRange` owns nothing: four column cursors,
    // a skipper and a lookahead, all of them values over storage the op set
    // already holds ([map_range.zig:976-987](map_range.zig)). Dropping the
    // `defer` here is a statement that the reader cannot leak.
    var direct_range = try map_range.MapRange(opmod.Op).init(
        &fx.set,
        try fx.set.scopeToObj(.root),
        null,
    );
    // And the direct spelling, for the same reason.

    var rows: usize = 0;
    while (try root_range.next()) |item| {
        const other = (try direct_range.next()) orelse return error.TestExpectedResult;
        try testing.expectEqualStrings(item.key, other.key);
        try sameValue(item.value, other.value);
        try testing.expectEqual(item.conflict, other.conflict);
        try testing.expectEqual(item.pos, other.pos);
        try testing.expectEqual(item.maybe_exid.id, other.maybe_exid.id);
        rows += 1;
    }
    try testing.expect((try direct_range.next()) == null);
    // **The count is asserted too**: two walks that both answer nothing would
    // agree, and the loop above would not notice.
    try testing.expectEqual(@as(usize, 3), rows);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **This file is upstream's `iter.rs`, and it has no algorithm.** Upstream
//   is twenty-five lines ([`iter.rs:1-25`](../../github-automerge-automerge/rust/automerge/src/iter.rs)):
//   six `mod` lines, one `pub(crate) mod`, nine `use` lines and one
//   `#[cfg(test)] use`. The port is the same table with the eight names of
//   those `use` lines plus [`Doc`], [`DocError`], [`ReadError`],
//   [`ValuesItem`], [`ValuesError`], [`RowQuery`] and [`TopQuery`], which
//   upstream expresses as types it does not need to name: `&'a Automerge`
//   (`:42`), a bare tuple (`:27`), and the two `OpQueryTerm` impls
//   ([`op_query.rs:48-56`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_query.rs),
//   [`top_op.rs:67-75`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/top_op.rs)).
//   **`slice.zig` is the port's name and upstream has no such file** — the
//   name is the port's own and is recorded here because a reader looking for
//   `iter.rs` will not find it by that name.
//
// * **The gap table above was wrong on two of its four rows and both are
//   corrected in place.** `doc::DiffIter` is ported, as
//   [`doc.DiffIter`](doc.zig) with four callers in `src/doc.zig`; it was
//   described here as "not ported" and named a pending gap. And `DocIter` was
//   described as a "deliberate rename" of [`ObjIdIter`], which it is not:
//   upstream's `DocIter` is the recursive walk that reads properties through
//   the three leaf readers and fills a `path_map`
//   ([`iter/doc.rs:19-50`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs)),
//   where [`ObjIdIter`](doc.zig) is `OpSet::obj_id_iter`
//   ([`op_set.rs:1344-1346`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
//   one object per step and nothing else. **Three names are now missing, not
//   four, and the missing one is `DocIter` itself** — which is also why
//   upstream's `doc_iter` case has no port.
//
// * **`tools::DiffKernel` is upstream's *other* `DiffIter`.** Upstream has
//   two types by that name: the row-level kernel at
//   [`iter/tools.rs:528-608`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs),
//   private to its own module, and the document-object walk at
//   [`iter/doc.rs:66`](../../github-automerge-automerge/rust/automerge/src/iter/doc.rs),
//   which `iter.rs:17` re-exports. The port renames the first so the second
//   can keep the name upstream's root puts on that line.
