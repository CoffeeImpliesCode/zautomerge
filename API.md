# zautomerge API

The target public surface of the Zig port. This is a contract, not a
description of what exists. See [PROJECT.md](PROJECT.md) for status and
[plan.md](docs/plan.md) for the phase that produces each part.

Method names, argument order, and semantics follow the Rust crate
(`automerge` 0.12.0) so the two trees are diffable. Where Zig forces a
different shape, the deviation is marked **deviation** and justified.

**Every declaration below was audited against the tree on 2026-09-30, re-measured
2026-10-01, and re-audited for this revision; the result is
[§ Audit](#audit-every-declaration-in-this-file-against-the-port).** That table
is the part of this file that makes the next audit cheap: a declaration here
with a row there is a declaration someone checked. A declaration added without a
row is a defect in this file, and a row whose verdict disagrees with the tree is
a worse one.

## Conventions

- **A port declaration is cited by symbol, not by line.** A port citation is
  `src/doc.zig` → `Document.init`; a Rust citation keeps its `automerge.rs:267`
  form, because the reference checkout is pinned and read-only while this tree
  moves under the file. A numeric locator into this repository was wrong the
  moment the file below it grew, and § Conventions of [§ Audit](#audit-every-declaration-in-this-file-against-the-port)
  records four separate rounds of that drift.
- Allocating entry points receive `gpa` or use an allocator retained by their
  owning container. The declaration states which regime applies.
  Output buffers are freed with the allocator that produced them.
  A `Keys` walk retains the document allocator; pass that allocator to `deinit`.
  Native containers do not use a global allocator.
- **The three constructors take a borrowed `std.Io`, and a `Document` keeps
  it.** `Document.init(gpa, io, mode)` and
  `Document.initWithEncoding(gpa, io, encoding, mode)` return
  `InitError` — `Allocator.Error || std.Io.RandomSecureError`, nothing else.
  **`Document.load(gpa, io, bytes, encoding, mode)` answers `LoadError`, not
  `InitError`**: it builds through `initWithEncoding` and then parses, so a
  caller handling entropy refusal on that path handles `error.Canceled` and
  `error.EntropyUnavailable` out of the larger set rather than out of
  `InitError`. The other three documents that can appear to construct —
  `loadInto` and `loadIncremental` on an existing document, and `clone`,
  `fork` and `forkAt` — take **no** `io`, because they use the capability the
  document already stores. `Document` keeps the borrowed capability in its `io`
  field and uses it for every later actor draw, so **the provider must outlive
  the document** and a caller with no live `std.Io` cannot build one. A test
  passes `std.testing.io`; an executable passes its own retained or live
  capability; nothing in the port reaches for an ambient runtime.
- **A fresh document draws a secure 16-byte actor id, and a refusal is an
  error rather than a silent fallback.** `ActorId.random(gpa, io)` allocates
  sixteen bytes from `gpa` and fills them through `std.Io.randomSecure`,
  **which has no weaker fallback**: it either produces the bytes or refuses,
  and it never silently substitutes a predictable source.
  `error.EntropyUnavailable` means the provider had no entropy to give.
  `error.Canceled` means the caller's own cancellation reached the draw, and
  **how much had been written into the buffer at that point is
  provider-dependent** — what is guaranteed is that nothing partial is ever
  returned: `random` frees the buffer and propagates the refusal, so the
  caller either gets sixteen bytes or gets an error. Whether that particular
  call left the process is the provider's business and this port does not
  assert it. Both are `Error` variants, propagated through `InitError` by the
  two constructors, so a caller can tell "no id" from "no entropy". Upstream
  draws the same sixteen bytes from `getrandom` and **panics** when that fails
  (`automerge/src/types.rs:63-68`); returning the refusal is the deviation.
  **A deterministic actor id is `Document.setActorId`, which draws nothing**,
  and that is the door every fixture and golden vector uses.
- Every fallible function returns a **named** error union, not one global set,
  because the port's readers refuse different things: `read.ReadError`
  (`src/read.zig`), `read.ChangeError`, `transact.WriteError`,
  `transaction.TransactionError` (an alias of the same set),
  `doc.InitError`, `doc.LoadError`, `doc.DocumentError`, `doc.DiffError`,
  `patches.MakeError`, `sync.protocol.ProtocolError` and
  `anonymize.AnonymizeError`. A parser on untrusted bytes returns `ParseError`
  and is total: it never panics and never loops.
- Values that borrow from the document are slices into the document's own
  storage, valid until the next mutation. Values a caller may hold across a
  mutation are returned by copy, or owned by the caller and freed with the
  `gpa` that produced them.
- Historical reads take a set of heads: `heads: []const ChangeHash` on the
  eleven `_at` readers (`getAt`, `getAllAt`, `lengthAt`, `keysAt`, `valuesAt`,
  `textAt`, `spansAt`, `marksAt`, `mapRangeAt`, `listRangeAt`, `parentsAt`) and
  `heads: ?[]const ChangeHash` on the three cursor readers `getCursor`,
  `getCursorMoving` and `getCursorPosition`, and on `hydrate`, `iterAt` and
  `markSetAtIndex`. **Upstream carries `at` on the cursor methods themselves**
  (`read.rs:203`, `:228`, `:241`), not as a second name, and the port follows
  it: `getCursorAt`, `getCursorMovingAt` and `getCursorPositionAt` were
  port-only spellings and **are gone** — there is no alias and no deprecated
  shim. **deviation**: the parameter is spelled `heads` where upstream spells it
  `at`, because `src/read.zig`'s file-scope `fn at(id: OpId)` is called by that
  file's own fixtures and a parameter may not shadow it. **A `null` `heads`
  means the document's read scope** (`read.zig`'s private `readScope`) — see
  the `hydrate` entry in §Read — and `heads = getHeads()` is the present on the
  cursor readers as on the `_at` ones, because `Automerge::clock_at`
  (`automerge.rs:1236-1247`) reports no clock for it.
- `root` is the root object id, matching `automerge::ROOT`.

```zig
pub const root: ExId = .root;                      // src/root.zig
```

## Types

| Rust | Zig | Where | Notes |
| --- | --- | --- | --- |
| `ExId` / `ObjId` | `ExId` | `src/types.zig` `ExId` | `union(enum) { id, root }`; upstream re-exports `exid::ExId` as `ObjId`, a rename that changes the meaning — the port uses one name. `src/root.zig` keeps `ObjId` as an alias of `ExId`. |
| `ActorId` | `ActorId` | `src/types.zig` `ActorId` | `struct { bytes: []const u8 }`, external byte string, never stored in a column. **Three ownership regimes behind the one name**, and the table on the type is the rule: `init` borrows the caller's buffer, a document's own ids borrow the document's arena, and `initCopy` / `random` / `fromHex` / `withConcurrency` return bytes from the allocator that call was given, which the caller frees with `gpa.free(id.bytes)`. |
| `OpId` | `OpId` | `src/types.zig` `OpId` | `{ counter: u32, actor: ActorIdx }` |
| `ElemId` | `ElemId` | `src/types.zig` `ElemId` | upstream's `(OpId)` wrapper, kept because a sequence key's actor is optional for the head |
| `ObjType` | `ObjType` | `src/types.zig` `ObjType` | `map`, `table`, `list`, `text` — four, not three; `table` is upstream's backwards-compatible spelling of `map` (`automerge/src/types.rs:171-181`) |
| `Prop` | `Prop` | `src/types.zig` `Prop` | `key: []const u8` or `index: usize`, and nothing else — upstream's `Prop` is `Map(String) \| Seq(usize)` (`types.rs`), and there is no third arm |
| `TextEncoding` | `TextEncoding` | `src/types.zig` `TextEncoding` | `unicode_code_point`, `utf8_code_unit`, `utf16_code_unit`, `grapheme_cluster` — four, matching upstream's four (`automerge/src/types.rs:622-631`) |
| `ScalarValue` | `ScalarValue` | `src/value.zig` `ScalarValue` | tagged union |
| `Value` | `Value` | `src/value.zig` `Value` | `scalar` or `object` |
| `Change` | `doc.Built` | `src/doc.zig` `Built` | **deviation**: the port's `Change` (`src/change.zig`) borrows its bytes and owns one allocation, so a change a document hands out cannot be separated from the body it points into. `Built` is the pair. `Changes` (`src/doc.zig` `Changes`) is the list, with `deinit(gpa)`. |
| `ChangeHash` | `ChangeHash` | `src/types.zig` `ChangeHash` | `struct { bytes: [32]u8 }`, SHA-256 |
| `Mark`, `MarkSet` | `Mark`, `MarkSet` | `src/marks.zig` `Mark`, `MarkSet` | |
| `Cursor` | `Cursor` | `src/cursor.zig` `Cursor` | |
| `Patch`, `PatchAction` | `Patch`, `PatchAction` | `src/patches.zig` `Patch`, `PatchAction` | |
| `Stats` | `Stats` | `src/doc.zig` `Stats` | three counters; upstream's struct also carries the crate and `rustc` versions, which are facts about the build |

## Read

The `ReadDoc` surface is in `src/read.zig`. Calls take `*const Document`, but
some reads populate internal caches. Serialize document access, including reads.
Keep the document and any borrowed clock live while a reader uses them.

```zig
pub fn get(doc: *const Document, obj: ExId, prop: Prop) ReadError!?DocItem;
pub fn getAtScope(doc: *const Document, obj: ExId, prop: Prop, scope: ?Clock) ReadError!?DocItem;
pub fn getAt(doc: *const Document, obj: ExId, prop: Prop, heads: []const ChangeHash) ReadError!?DocItem;
pub fn getAll(doc: *const Document, obj: ExId, prop: Prop, gpa: Allocator) ReadError![]DocItem;
pub fn getAllAt(doc: *const Document, obj: ExId, prop: Prop, heads: []const ChangeHash, gpa: Allocator) ReadError![]DocItem;
pub fn hydrate(doc: *const Document, obj: ExId, heads: ?[]const ChangeHash, gpa: Allocator) HydrateError!hydrate.Value;
pub fn objectType(doc: *const Document, obj: ExId) Error!ObjType;
pub fn length(doc: *const Document, obj: ExId) ReadError!usize;
pub fn lengthAt(doc: *const Document, obj: ExId, heads: []const ChangeHash) ReadError!usize;
pub fn text(doc: *const Document, obj: ExId, gpa: Allocator) ReadError![]u8;
pub fn textAt(doc: *const Document, obj: ExId, heads: []const ChangeHash, gpa: Allocator) ReadError![]u8;
pub fn keys(doc: *const Document, obj: ExId) ReadError!Keys;
pub fn keysAt(doc: *const Document, obj: ExId, heads: []const ChangeHash) ReadError!Keys;
pub fn values(doc: *const Document, obj: ExId, term: *ValueTerm) ReadError!Values;
pub fn valuesAt(doc: *const Document, obj: ExId, heads: []const ChangeHash, term: *ValueTerm) ReadError!Values;
pub fn spans(doc: *const Document, obj: ExId, gpa: Allocator) ReadError!Spans;
pub fn spansAt(doc: *const Document, obj: ExId, heads: []const ChangeHash, gpa: Allocator) ReadError!Spans;
pub fn marks(doc: *const Document, obj: ExId, gpa: Allocator) ReadError![]Mark;
pub fn marksAt(doc: *const Document, obj: ExId, heads: []const ChangeHash, gpa: Allocator) ReadError![]Mark;
pub fn getMarks(doc: *const Document, obj: ExId, from: usize, max: usize, gpa: Allocator) ReadError![]Mark;
pub fn markSetAtIndex(doc: *const Document, obj: ExId, index: usize, heads: ?[]const ChangeHash, gpa: Allocator) ReadError!MarkSet;
pub fn markSetAtScope(doc: *const Document, obj: ExId, index: usize, scope: ?Clock, gpa: Allocator) ReadError!MarkSet;
pub fn parents(doc: *const Document, obj: ExId) ReadError!Parents;
pub fn parentsAt(doc: *const Document, obj: ExId, heads: []const ChangeHash) ReadError!Parents;
pub fn iter(doc: *const Document, gpa: Allocator) DiffError!DocIter;
pub fn iterAt(doc: *const Document, obj: ExId, heads: ?[]const ChangeHash, gpa: Allocator) DiffError!DocIter;
pub fn getCursor(doc: *const Document, obj: ExId, pos: CursorPosition, heads: ?[]const ChangeHash, gpa: Allocator) ReadError!Cursor;
pub fn getCursorMoving(doc: *const Document, obj: ExId, pos: CursorPosition, heads: ?[]const ChangeHash, bias: Bias, gpa: Allocator) ReadError!Cursor;
pub fn getCursorPosition(doc: *const Document, obj: ExId, cursor: Cursor, heads: ?[]const ChangeHash) ReadError!usize;
pub fn getCursorPositionFor(doc: *const Document, obj: ExId, cursor: Cursor, scope: ?Clock) ReadError!usize;
pub fn getMissingDeps(doc: *const Document, heads: []const ChangeHash, gpa: Allocator) Error![]ChangeHash;
pub fn getChangeByHash(doc: *const Document, hash: ChangeHash, gpa: Allocator) ChangeError!?doc.Built;
pub fn stats(doc: *const Document) Stats;
pub fn textEncoding(doc: *const Document) TextEncoding;
pub fn mapRange(doc: *const Document, obj: ExId, range: KeyRange) ReadError!MapRange;
pub fn mapRangeAt(doc: *const Document, obj: ExId, range: KeyRange, heads: []const ChangeHash) ReadError!MapRange;
pub fn listRange(doc: *const Document, obj: ExId, range: IndexRange) ReadError!ListRange;
pub fn listRangeAt(doc: *const Document, obj: ExId, range: IndexRange, heads: []const ChangeHash) ReadError!ListRange;
```

Every declaration above lives in `src/read.zig` under the name it is given
here; nothing in this section is a re-export or an alias. `ValueTerm` is the
query term `values` fills in, and it is an out-parameter rather than a hidden
field because two `Values` over the same document would otherwise share it.
`Bias` is `cursor.MoveCursor` under the name `read.rs` uses. `DocIter`,
`DiffError`, `Keys`, `Values`, `Spans`, `MapRange`, `ListRange` and `Parents`
are the published walk types of this module.

**`iter` and `iterAt` are the document walk, and they are ported.** `iter` is
`ReadDoc::iter_at` (`read.rs:60`) at the root with no heads, `iterAt` the same
walk under a caller-named subtree and clock; the walk itself is
`src/iter/doc.zig`'s `DocIter` and the six item types beside it. **The allocator
is the port's** — upstream allocates no iterator — and `iterAt`'s `heads` is
nullable with a null meaning the document's read scope, which is upstream's
`heads.and_then(|h| self.clock_at(h))` (`automerge.rs:2098`).

### What a document walk owns, and what it borrows

`DocIter` mixes the two, so the rules are per-field rather than per-type:

- **`DiffIter.next`'s `text` arm owns a buffer and the other arms own
  nothing.** A caller driving `next()` directly must free every text item with
  the walk's allocator before dropping it; `DiffIter.log` does exactly that
  internally, so a caller of `log` never sees the obligation.
- **`DiffIter.log` moves the walk's `PathMap` out, it does not copy it.**
  After the call the walk holds nothing, so **the caller owns that map** even
  if it discards it: either hand it to `patches.PatchLog.pathHint`, which takes
  it over and frees the log's previous map in its place, or free it with
  `PathMap.deinit` and the walk's allocator. **Returning a copy is what would
  name one allocation twice**, because the walk's own `deinit` frees it too.
  `PathHint` must be given an allocator that is the walk's own.
- **Mark names and block ids stay borrowed from the document** even on the text
  arm; only the bytes above are owned. A caller holding a mark name holds a
  document borrow, with the document's mutation as its invalidating operation.
- **`spans` and `spansAt` hand back caller-owned spans that outlive the walk.**
  `Spans.deinit` takes no allocator because the fold remembers the one it was
  given, and **it is a different obligation from each span's**: `Span.deinit`
  frees the span's owned text and owned mark set, and the mark *names* inside a
  span are the document's and are not freed. The order is **walk first, spans
  after** — freeing the walk does not touch a span, so a span held past the
  walk's disposal is sound and is the documented answer, while dropping spans
  before the walk is not required and freeing a span twice is a double free.

**`getCursorPositionFor` is the crate-internal door the three cursor readers
resolve their scope through**, upstream's `Automerge::get_cursor_position_for`
over a supplied `Clock`, and it is public because `hydrate` and the `_at`
readers hold a clock and nothing else does.

**The three cursor readers take `heads` in upstream's own argument position, and
upstream has no second name for them.** `ReadDoc::get_cursor` takes
`at: Option<&[ChangeHash]>` as its third parameter
(`read.rs:199-204`), `get_cursor_moving` its fourth (`:224-230`) and
`get_cursor_position` its third (`:237-242`); the port's `heads` sits in the
same place. The spellings are `heads` rather than `at` because `src/read.zig`
declares a file-scope `fn at(id: OpId)` that the file's own fixtures call, and a
parameter may not shadow it. **A `null` `heads` is the document's read scope**
and the module's private `atScope` is the other arm, so
`heads = getHeads()` reads the present.

**`getCursorPosition` answers `error.InvalidCursor` for a cursor naming a row of
a *different* object.** It used to answer `error.InvalidIndex`, the name the op
set's own range check raises, and **the port was inconsistent with itself**:
given a clock the same cursor took the slow arm alone, which answers `null` and
so already refused with `InvalidCursor`, while unscoped the fast arm's range
check ran first and refused with `InvalidIndex`. Upstream has one name for one
question —
`.ok_or_else(|| AutomergeError::InvalidCursor(cursor.clone()))` on the seek's
empty answer (`automerge.rs:1778-1781`) — because upstream's seek answers
`Option` and cannot raise where the port's can. **`getCursor`'s own
`error.InvalidIndex`, for an index at or past the end of the sequence
(`automerge.rs:1754`), is a different question and is unchanged.**

`HydrateError` (`src/read.zig`) is `hydrate.zig`'s `OpHydrateError`: the
union of every read error **plus the mark fold's own set**
(`OpSet::MarksError`), which is what `hydrateText`'s fold
raises and which is not a subset of `ReadError`. The other three arms of
`hydrate` raise no more than `ReadError`. It is named here because the
declaration above returns it.

**`hydrate` returns an owned mirror and the caller frees it with
`Value.deinit`**, exactly once — a `Map`, a `List` and a `Text` sit in the
`Value` by value, so a copy is a move (`src/hydrate.zig`'s `Map.deinit` says
this). **Nothing in it borrows the document**: every scalar payload and every
mark name crosses `Map.putOwned`, `List.push` or `Text.putMark` on the way in,
so a mirror outlives the next mutation of the document. Upstream gets that for
free — its `hydrate::Value` carries no lifetime at all (`hydrate.rs:22-27`) over
a `Vec<u8>` and a `SmolStr` (`value.rs:519-522`) — and the port's `Owned` record
and its three doors exist for exactly that reason.

**deviation**: `mapRange` and `listRange` take an explicit range instead of
upstream's `RangeBounds<String>` / `RangeBounds<usize>`, because Zig has no
range-bounds protocol.

`listRange` takes `IndexRange { start: usize, end: ?usize }`
(`src/iter/list_range.zig`): `start` is the first index and `end` is **one
past** the last, a null `end` being the end of the object. Half-open and two
states per end, because upstream's `normalize_range` does arithmetic that
underflows on `Excluded(0)` and overflows on `Included(usize::MAX)`
(`iter/list_range.rs:359-372`). **An inverted range is not a refusal**: it
names no element and the walk answers nothing.

`mapRange` takes `KeyRange { start: ?KeyBound, end: ?KeyBound }`
(`src/read.zig` `KeyRange`), where `KeyBound` is `union(enum) { included: []const u8,
excluded: []const u8 }` and a null end is `Bound::Unbounded`. **That is all
four of upstream's arms, not two**: the C binding's `AMmapRange` builds Rust's
half-open `begin..end` and documents `end` as "the key one past the last key in
a subrange" (`rust/automerge-c/src/doc/map.rs:482-483,518-529`), and its header
has no entry for an inclusive end, so a C caller can only reach the range by
`KeyRange { start: .{ .included = begin }, end: .{ .excluded = end } }`.
`KeyRange.between(begin, end)` builds exactly that and `KeyRange.through(begin,
end)` the closed form. Both range types default to "the whole object" and both
expose `all()`.

## Write

The `Transactable` surface, on a `Document` in [`Mode.auto`](#document). These
are free functions in `src/transact.zig`, not methods, because upstream's
`Transactable` is a trait and this port declares none (`src/transact.zig`'s
module doc, first section). Each one opens a transaction, applies, commits and
closes; the manual door below is the other way in.

```zig
pub fn put(doc: *Document, obj: ExId, prop: Prop, value: ScalarValue) Error!OpId;
pub fn putObject(doc: *Document, obj: ExId, prop: Prop, t: ObjType) Error!ExId;
pub fn insert(doc: *Document, obj: ExId, index: usize, value: ScalarValue) Error!OpId;
pub fn insertObject(doc: *Document, obj: ExId, index: usize, t: ObjType) Error!ExId;
pub fn increment(doc: *Document, obj: ExId, prop: Prop, by: i64) Error!void;
pub fn delete(doc: *Document, obj: ExId, prop: Prop) Error!usize;
pub fn splice(doc: *Document, obj: ExId, pos: usize, del: isize, gpa: Allocator, values: []const hydrate.Value) Error!void;
pub fn spliceText(doc: *Document, obj: ExId, pos: usize, del: isize, text: []const u8) Error!void;
pub fn mark(doc: *Document, obj: ExId, from: usize, to: usize, name: []const u8, expand: ExpandMark, value: ?ScalarValue) Error!void;
pub fn unmark(doc: *Document, obj: ExId, from: usize, to: usize, expand: ExpandMark, name: []const u8, value: ?ScalarValue) Error!void;
pub fn splitBlock(doc: *Document, obj: ExId, index: usize) Error!ExId;
pub fn joinBlock(doc: *Document, text: ExId, index: usize) Error!void;
pub fn replaceBlock(doc: *Document, text: ExId, index: usize) Error!ExId;
pub fn updateText(doc: *Document, obj: ExId, new_text: []const u8) Error!void;
pub fn updateObject(doc: *Document, obj: ExId, value: hydrate.Map) Error!void;
pub fn updateSpans(doc: *Document, obj: ExId, spans: []const Span) Error!void;
pub fn updateSpansWithConfig(doc: *Document, obj: ExId, config: *const UpdateSpansConfig, spans: []const Span) Error!void;
pub fn batchCreateObject(doc: *Document, obj: ExId, prop: Prop, t: ObjType) Error!ExId;
pub fn batchCreateValue(doc: *Document, obj: ExId, prop: Prop, value: hydrate.Value, as_insert: bool) Error!ExId;
pub fn initRootFromHydrate(doc: *Document, value: hydrate.Map) Error!void;
pub fn pendingOps(doc: *const Document) usize;
pub fn baseHeads(doc: *const Document) []const ChangeHash;
```

Each one is a free function in `src/transact.zig` under the name it is given
here. `openAutoHeld` and `spliceHeld`, the two doors the C ABI's `AMdoc` uses to
hold one transaction open across calls, are in the deviation list below.

These are **twenty-two** declarations, and upstream `Transactable`
(`transaction/transactable.rs:9-216`) has **twenty** methods, so this block is
not one-for-one and never has been. Re-measured 2026-10-01 against the Rust:

- `batchCreateValue` is upstream's `batch_create_object`
  (`transactable.rs:196-202`, `inner.rs:1269-1331`), which takes
  `value: &hydrate::Value, insert: bool` — a hydrated value, not an `ObjType`.
  It is listed here because this file previously omitted it.
- `batchCreateObject(doc, obj, prop, t: ObjType)` has **no upstream
  counterpart**. It is this port's own map-shaped convenience beside
  `batchCreateValue`, and it is the twenty-second declaration.
  `updateSpansWithConfig` is upstream's `update_spans` with its `config`
  argument, which upstream always passes and this port's `updateSpans` does
  not (`transactable.rs:146-152`).
- Four more do not match upstream's arity or argument order, and none of the
  four carries a **deviation** note:
  - `mark` — upstream `mark(obj, mark: Mark, expand)` (`transactable.rs:103-108`),
    three arguments taking a `Mark` struct. This block spells six.
  - `unmark` — upstream `unmark(obj, key, start, end, expand)`
    (`transactable.rs:110-117`), five arguments in that order. This block has
    six, with `expand` third and `name` fifth.
  - `updateSpans` — upstream `update_spans(text, config, new_text)`
    (`transactable.rs:146-152`), three arguments. This block has two, and
    `updateSpansWithConfig` is the three-argument one; `updateSpans` is
    upstream's call with `UpdateSpansConfig::default()`.
  - `updateObject` — upstream `update_object(obj, new_value: &hydrate::Value)`
    (`transactable.rs:183-188`) takes any hydrated value, not only a map. The
    port's three `Transaction` siblings `updateListValue` / `updateTextValue` /
    `updateMapValue` are not declared here at all.
- `put` answers `Error!OpId` and `delete` answers `Error!usize` where upstream
  answers `Result<(), AutomergeError>` (`transactable.rs:21`, `:75`). The port is
  richer; the shape is a widening, not a match.

**deviation**: **each of these is its own transaction, so two calls are
two changes, where upstream's `AutoCommit` holds one transaction open across
calls** (`autocommit.rs:445-457` opens it lazily, `:728-739` commits it, and
`:459-468` is the `ensure_transaction_closed` that `get_heads` (`:695`),
`get_changes` (`:621`) and `save` (`:530-533`) call). Executed against the
reference: `put_object` then `splice_text` with no `commit()` between is **one
change of six operations**, and a read already sees it. **This is observable,
not a convenience**: it changes the number of changes, it changes which actor
an isolated write lands on — `isolate_actor` (`automerge.rs:1259-1281`) is
chosen once per transaction, so a second call inside one isolation forks to the
next concurrency level — and it makes the reference's own
`incremental_list_conflict_survives_isolate_integrate_roundtrip`
(`tests/test.rs:4179-4208`) **fail here with `error.InvalidObjId`** rather than
answer differently, because the object the first transaction made is outside
the second transaction's scope clock. **The C ABI does not share the
deviation**: `AMdoc` is a `{doc, tx}` pair (`src/c/doc.zig`) and holds its
transaction open exactly as upstream does, so the two doors disagree today.
**Matching it is a wrapper type and not a flag** — a `Transaction` borrows its
`Document` — which is `AMdoc`'s shape and upstream's
`AutoCommit { doc, transaction }` (`autocommit.rs:58-64`); the blast radius and
the sequencing are in `src/transact.zig`'s diff block.

**deviation**: `baseHeads` returns a **borrow** of the document's heads, not a
copy. Upstream returns `Vec<ChangeHash>`
(`transactable.rs:155`), this file names no allocator, and a borrowed answer to
"what would the next change depend on?" is the number the caller actually has.
For the transaction's own base see `Transaction.baseHeads`.

**deviation**: two more doors onto the same bodies, for the C ABI's `AMdoc`
which keeps one transaction open across calls
(`autocommit.rs:445-457`):

```zig
pub fn openAutoHeld(gpa: Allocator, doc: *Document) WriteError!Transaction;
pub fn spliceHeld(tx: *Transaction, obj: ExId, pos: usize, del: isize, gpa: Allocator, values: []const hydrate.Value) WriteError!void;
```

Both are `src/transact.zig` free functions, and `spliceHeld` is the only reason
`splice` is not a `Transaction` method: the bulk insert takes an allocator and
`[]hydrate.Value`, which a method that takes no allocator cannot express.

### The manual door

Upstream's manual transaction is `Transaction<'a>`
(`transaction/manual_transaction.rs:21-27`) over
`TransactionInner` (`inner.rs:22-33`), and `transaction.rs`
is a module root: **six** `mod` lines (`:1-6`) and **seven** re-export
statements (`:8-14` — six `pub use` and one `pub(crate) use`), plus a `Result`
alias (`:16`), one private `commit_transaction` (`:18`) and two macros (`:36`,
`:316`). **It declares no trait**, so there
is no "manual `Transactable` surface" to name — the twenty methods above are
implemented on the one type, and the door is which of the two ways in a caller
takes.

`Transaction` is `transact.Transaction` (`src/transaction.zig`) re-exported
under upstream's name, and `src/root.zig` publishes it as `manual_transaction`
so the autocommit module keeps the bare name `transaction`. The methods are in
`src/transact.zig`:

```zig
pub fn open(gpa: Allocator, doc: *Document) WriteError!Transaction;
pub fn openAt(gpa: Allocator, doc: *Document, heads: ?[]const ChangeHash) WriteError!Transaction;
pub fn deinit(self: *Transaction) void;
pub fn commit(self: *Transaction, message: ?[]const u8, time: ?i64) WriteError!?ChangeHash;
pub fn rollback(self: *Transaction) WriteError!usize;
pub fn count(self: *const Transaction) usize;
pub fn baseHeads(self: *const Transaction) []const ChangeHash;
pub fn nextId(self: *const Transaction) OpId;
pub fn scopeClock(self: *Transaction) WriteError!?Clock;
pub fn put(self: *Transaction, obj: ExId, prop: Prop, value: ScalarValue) WriteError!?OpId;
pub fn putObject(self: *Transaction, obj: ExId, prop: Prop, t: ObjType) WriteError!?ExId;
pub fn insert(self: *Transaction, obj: ExId, index: usize, value: ScalarValue) WriteError!?OpId;
pub fn insertObject(self: *Transaction, obj: ExId, index: usize, t: ObjType) WriteError!?ExId;
pub fn increment(self: *Transaction, obj: ExId, prop: Prop, by: i64) WriteError!void;
pub fn delete(self: *Transaction, obj: ExId, prop: Prop) WriteError!?usize;
pub fn splitBlock(self: *Transaction, obj: ExId, index: usize) WriteError!ExId;
pub fn joinBlock(self: *Transaction, text: ExId, index: usize) WriteError!void;
pub fn replaceBlock(self: *Transaction, text: ExId, index: usize) WriteError!ExId;
pub fn mark(self: *Transaction, obj: ExId, from: usize, to: usize, name: []const u8, expand: ExpandMark, value: ?ScalarValue) WriteError!void;
pub fn unmark(self: *Transaction, obj: ExId, from: usize, to: usize, expand: ExpandMark, name: []const u8, value: ?ScalarValue) WriteError!void;
pub fn spliceText(self: *Transaction, obj: ExId, index: usize, del: isize, text: []const u8) WriteError!void;
pub fn blockAt(self: *Transaction, obj: ExId, index: usize) WriteError!?ExId;
pub fn textFor(self: *Transaction, obj: ExId) WriteError![]const u8;
pub fn textEncoding(self: *const Transaction) TextEncoding;
pub fn updateText(self: *Transaction, obj: ExId, new_text: []const u8) WriteError!void;
pub fn updateMapValue(self: *Transaction, id: ExId, value: *const hydrate.Map) WriteError!void;
pub fn updateListValue(self: *Transaction, id: ExId, value: *const hydrate.List) WriteError!void;
pub fn updateTextValue(self: *Transaction, id: ExId, value: *const hydrate.Text) WriteError!void;
pub fn updateSpans(self: *Transaction, obj: ExId, spans: []const Span) WriteError!void;
pub fn updateSpansWithConfig(self: *Transaction, obj: ExId, config: *const UpdateSpansConfig, spans: []const Span) WriteError!void;
pub fn batchCreateObject(self: *Transaction, obj: ExId, prop: Prop, t: ObjType) WriteError!ExId;
pub fn batchCreateValue(self: *Transaction, obj: ExId, prop: Prop, value: hydrate.Value, as_insert: bool) WriteError!ExId;
pub fn initRootFromHydrate(self: *Transaction, value: *const hydrate.Map) WriteError!void;
pub fn get(self: *Transaction, obj: ExId, prop: Prop) WriteError!?read.DocItem;
pub fn markSetAtIndex(self: *Transaction, obj: ExId, index: usize, heads: ?[]const ChangeHash, gpa: Allocator) WriteError!MarkSet;
```

**`updateListValue` and `updateTextValue` are port-only names**, and they are
listed here because §Write's free-function `updateObject` takes only a map: the
three siblings together cover what upstream's single `update_object` does with
any hydrated value (`transactable.rs:183-188`).

`open` and `openAt` **refuse a document that is not in `Mode.manual`** with
`error.InvalidOp`, and every function in `## Write` refuses one that is. That
runtime check is the whole substitution for upstream's two types, and it is a
refusal rather than a trap because Rust's answer was a compile error.

`splice` is **not** a `Transaction` method: the bulk insert takes an allocator
and `[]hydrate.Value`, which is `transact.spliceHeld`'s job.

`src/transaction.zig` owns the rest — the commit options, the outcome, the
accessors and the closure doors — under `zautomerge.manual_transaction`:

```zig
pub const CommitOptions = struct { message: ?[]const u8 = null, time: ?i64 = null };
pub fn Success(comptime O: type) type;
pub fn Failure(comptime O: type) type;
pub fn Outcome(comptime O: type) type;
pub fn actorId(tx: *const Transaction) ?ActorId;
pub fn maxOp(tx: *const Transaction) TransactionError!u64;
pub fn heads(gpa: Allocator, tx: *const Transaction) Error![]ChangeHash;
pub fn hashForOpid(tx: *const Transaction, id: ExId) ?ChangeHash;
pub fn depIndices(gpa: Allocator, tx: *const Transaction) TransactionError![]NodeIdx;
pub fn changeMeta(tx: *const Transaction, deps: []const NodeIdx) TransactionError!doc.BuildMeta;
pub fn authorFooter(gpa: Allocator, tx: *const Transaction) Allocator.Error![]u8;
pub fn commitWith(tx: *Transaction, options: CommitOptions) TransactionError!?ChangeHash;
pub fn abort(tx: *Transaction) TransactionError!void;
pub fn enclose(comptime O: type, gpa: Allocator, doc: *Document, ctx: anytype,
               body: *const fn (@TypeOf(ctx), *Transaction) TransactionError!O) TransactionError!Outcome(O);
pub fn encloseWith(comptime O: type, gpa: Allocator, doc: *Document, ctx: anytype,
                   body: *const fn (@TypeOf(ctx), *Transaction) TransactionError!O,
                   options: ?*const fn (@TypeOf(ctx), O) CommitOptions) TransactionError!Outcome(O);
```

**`Failure(O)` is a five-field struct and this is the shape a caller must
match**, upstream's `transaction::Result` error arm widened to carry what a
partial rollback leaves behind:

| field | meaning |
| --- | --- |
| `err` | the **primary** refusal — the body's error, or the commit's. A rollback refusal never replaces it. |
| `cancelled` | operations already undone, including the progress a partial rollback made before it refused |
| `rollback_error` | the secondary refusal, or null once rollback completed |
| `transaction` | the recovery owner, non-null **only** when rollback refused; the caller then retries `rollback` and disposes it exactly once before touching the borrowed document again |
| `result` | the body's own value, retained when the body succeeded and **only the commit** refused; null when the body itself refused |

`Success(O)` is `{ result: O, hash: ?ChangeHash }`, and it **owns only
`result`** — the document keeps its patch log. `Outcome(O)` is a tagged union
of the two, `success` / `failure`, and it is a union rather than an error union
because upstream's form
(`transaction::Result<O, E> = Result<Success<O>, Failure<E>>`,
`transaction.rs:16`) exists precisely to carry a value alongside a refusal.
**`Outcome.failure` is reachable from two causes and the caller cannot tell
them apart from the union alone**: the body refused, or the body succeeded and
the commit refused. `result` is the discriminator — non-null is the second.

`maxOp` and `changeMeta` are `error.InvalidOp` on a **closed** transaction, and
"closed" means committed **or** rolled back. Upstream's `Transaction` has no
`max_op` accessor at all and takes `self` by value on `commit`, `commit_with`
and `rollback` (`manual_transaction.rs:67`, `:91`, `:100`; `inner.rs:129-130`,
`:211-212`), so a spent transaction does not exist there and the question is
never asked. Here it does, and its arithmetic over a drained `pending` would
answer the empty-state sentinel `start_op - 1` — a number shaped like a
counter and not one. For the committed change's own counter read
`change.max_op`; for the document's read `ChangeGraph.maxOp`. The reasoning is
`src/transaction.zig`'s port differences, item 13.

### What commit and rollback promise

**`Transaction.commit` is staged, and every refusal leaves the transaction
open.** `Document.commit` — which is the fallible half — stages the author
association, the op count, the node-table slot, the extra-meta copy, the next
isolation head and, while the patch log is recording, the staged local patches
**above** its last fallible step, and publishes all of them **below** it: the
history node lands in the graph last, and every step after it is infallible.
**So a commit either publishes everything or publishes nothing**, and the
transaction that asked for it keeps its undo path. `Transaction.commit` sets
its own `closed` flag only after `Document.commit` has returned a hash, which
is what makes that promise reachable by a caller: **a refused commit is a
transaction you may retry or roll back, not one you may only dispose.** The
cost a caller pays for that is that `closed` is not a state `commit` walks
through — a caller that wants to know whether it committed reads the answer.

**`Transaction.rollback` is resumable, and it is not idempotent.** It undoes in
reverse order, and each undo that succeeds is popped and disposed immediately,
with `cancelled` incremented. A refusal therefore leaves a *progressed*
transaction, not an untouched one: **retry `rollback` to continue**, and the
operations the first call already took back are not taken back twice. While a
rollback is in progress the transaction sets `rolling_back`, and `requireOpen`
refuses a write and a commit on that state, so a resumed rollback cannot be
raced by a write. `rollback` answers the running total, not the number undone
by the call that returned. **`Transaction.deinit` is not a rollback**: it frees
the pending records without undoing them, so a caller who abandons a
transaction must `abort` (or `rollback`) first, and the idiom is
`defer tx.deinit();` followed by an explicit fallible `abort` before return.

**Rollback is not atomic across a whole transaction or operation record.**
Each successor edge stages its count, flattened pair, increment and affected
indices together. A refusal can still follow earlier completed edge or row
undo. Keep the journal and retry; resumed replay checks the predecessor row's
count and successor window before identity, because one successor can belong
to several conflicted predecessors. Do not read rows between refusal and
completed recovery.

### Refused native automatic writes

A native automatic write that publishes or queues work keeps its unclosed
transaction in `Document.auto_recovery`. This optional field defaults to null
and is owned by the document; callers must not replace or dispose its contents.
The transfer allocates nothing and preserves the primary write or commit error.

Validation refusal with no published or queued work disposes the empty
transaction and leaves reads and later writes available. Valid unused actor
metadata remains owned by the document; restoring an incidental cache size is
not recovery work.

`Document.recoverAuto()` retries rollback with the document allocator. It
returns the total cancelled operation count, or zero when no recovery is
pending. A refusal retains the progressed record for another call. Success
disposes the record once. The next native automatic mutator performs this
recovery before opening a transaction or assigning new operation IDs.

Keep the document at its address while recovery is pending. Do not read rows,
move storage, export changes, or enter a held/manual transaction until recovery
completes; the guarded entry points refuse with `error.InvalidOp`. Configuration
changes through `setMode`, `setActorId`, `dropIsolation` and `resetDiffCursor`
remain permitted. Recovery scope heads use the transaction's owned dependency
array, not the document's replaceable isolation buffer. Payload bytes supplied
to the refused wrapper need not remain live for rollback.

`Document.deinit` frees the retained record without attempting rollback, because
the whole document is being discarded. Manual commit refusal still permits
commit retry. A manual producer that has partially published or queued work is
rollback-only; validation refusal before any such work does not close it.

`OpSet.addSuccWithUndo(inserts, undo)` takes a caller-owned
`*std.ArrayList(SuccUndo)` allocated with the op set's allocator. It reserves
before mutation and records each published edge before fallible index work.
A refusal retains the published prefix; undo it before reading or mutating
the op set. `SuccUndo.succ.len` is the row count before that individual edge,
not the count before the whole insertion pass. Keep the complete journal and
its row coordinates until undo finishes; there is no owned-slice return or
compatibility entry point.

**`encloseWith`'s `options` callback runs synchronously on the calling thread,
after the body succeeded and before the commit.** It borrows `ctx` and the
body's `result` for the duration of the call and must not mutate or reenter the
document; **the message bytes it returns must stay live through the commit**,
because the commit reads them after the callback has returned. A null callback
selects `CommitOptions.none`. `enclose` is `encloseWith` with a null callback.
Both require a `Mode.manual` document, and opening the transaction can itself
refuse without ever invoking `body`.

`enclose`/`encloseWith` are upstream's `Automerge::transact` /
`transact_with` (`automerge.rs:586-601`), which return
`transaction::Result<O, E>`; an error union cannot carry a value, and the whole
point of that form is that it does, so the result is a tagged union.

## Document

`src/doc.zig`. **`Document` carries a `Mode` flag** (its `mode` field), and
which door a write takes is checked against it at runtime. `Mode.manual` is
upstream's `Automerge`, `Mode.auto` is upstream's `AutoCommit`.

```zig
pub const Document = struct { ... };

// Constructors. The first three take a borrowed `std.Io` and answer `InitError`.
pub fn init(gpa: Allocator, io: std.Io, mode: Mode) InitError!Document;
pub fn initWithEncoding(gpa: Allocator, io: std.Io, encoding: TextEncoding, mode: Mode) InitError!Document;
pub fn load(gpa: Allocator, io: std.Io, bytes: []const u8, encoding: TextEncoding, mode: Mode) LoadError!Document;

// Everything below is a method on `Document`, except where noted.
pub fn deinit(self: *Document) void;
pub fn recoverAuto(self: *Document) transact.WriteError!usize;
pub fn allocator(self: *const Document) Allocator;
pub fn documentMode(self: *const Document) Mode;
pub fn setMode(self: *Document, next: Mode) void;
pub fn loadInto(self: *Document, gpa: Allocator, bytes: []const u8, encoding: TextEncoding, mode: Mode) LoadError!void;
pub fn loadIncremental(self: *Document, gpa: Allocator, bytes: []const u8) LoadError!usize;
pub fn save(self: *Document, gpa: Allocator) LoadError![]u8;
pub fn saveWithOptions(self: *Document, gpa: Allocator, options: SaveOptions) LoadError![]u8;
pub fn saveAfter(self: *Document, gpa: Allocator, heads: []const ChangeHash) LoadError![]u8;
pub fn saveIncremental(self: *Document, gpa: Allocator) LoadError![]u8;
pub fn applyChanges(self: *Document, gpa: Allocator, incoming: []const Change) LoadError!usize;
pub fn getHeads(self: *const Document, gpa: Allocator) Error![]ChangeHash;
pub fn hasChange(self: *const Document, hash: ChangeHash) bool;
pub fn getMissingDeps(self: *const Document, gpa: Allocator, heads: []const ChangeHash) Error![]ChangeHash;
pub fn getChanges(self: *Document, gpa: Allocator, have: []const ChangeHash) DocumentError!Changes;
pub fn getChangesAdded(self: *Document, gpa: Allocator, other: *Document) DocumentError!Changes;
pub fn getLastLocalChange(self: *Document, gpa: Allocator) DocumentError!?Built;
pub fn getChangeByHash(self: *Document, gpa: Allocator, hash: ChangeHash) DocumentError!?Built;
pub fn merge(self: *Document, gpa: Allocator, other: *Document) DocumentError![]ChangeHash;
pub fn commit(self: *Document, gpa: Allocator, args: TransactionArgs, ops: []const ChangeOp, message: ?[]const u8, time: ?i64) LoadError!ChangeHash;
pub fn emptyCommit(self: *Document, gpa: Allocator, message: ?[]const u8, time: ?i64) LoadError!ChangeHash;
pub fn transactionArgs(self: *Document, gpa: Allocator, heads: ?[]const ChangeHash) DocumentError!TransactionArgs;
pub fn getActorId(self: *const Document) ActorId;
pub fn setActorId(self: *Document, actor: ActorId) void;
pub fn getActorIndex(self: *const Document) ?ActorIdx;
pub fn getActor(self: *const Document, idx: ActorIdx) ?ActorId;
pub fn putActorRef(self: *Document, gpa: Allocator, actor: ActorId) Error!ActorIdx;
pub fn removeActor(self: *Document, gpa: Allocator, idx: ActorIdx) Error!void;
pub fn removeUnusedActors(self: *Document, gpa: Allocator) Error!void;
pub fn numActors(self: *const Document) usize;
pub fn getAuthors(self: *const Document, gpa: Allocator) Error![]const []const u8;
pub fn getActors(self: *const Document, gpa: Allocator) Error![]ActorId;
pub fn getAuthor(self: *const Document) ?[]const u8;
pub fn setAuthor(self: *Document, gpa: Allocator, author: ?[]const u8) Error!void;
pub fn getAuthorForActor(self: *const Document, actor: ActorId) ?[]const u8;
pub fn getActorForAuthor(self: *const Document, gpa: Allocator, author: []const u8) Error![]ActorId;
pub fn bundle(self: *Document, gpa: Allocator, hashes: []const ChangeHash) DocumentError!Bundle;
pub fn fragments(self: *const Document, gpa: Allocator, levels: LevelRange) Error![]Fragment;
pub fn getFragment(self: *const Document, gpa: Allocator, head: ChangeHash) Error!?Fragment;
pub fn bundleFragments(self: *Document, gpa: Allocator, wanted: []const Fragment) DocumentError![][]u8;
pub fn forkAt(self: *Document, gpa: Allocator, heads: []const ChangeHash, mode: Mode) LoadError!Document;
pub fn fork(self: *Document, gpa: Allocator, mode: Mode) LoadError!Document;
pub fn clone(self: *Document, gpa: Allocator, mode: Mode) LoadError!Document;
pub fn isolate(self: *Document, gpa: Allocator, heads: []const ChangeHash) DiffError!void;
pub fn integrate(self: *Document) DiffError!void;
pub fn dropIsolation(self: *Document) void;
pub fn isolationHeads(self: *const Document) ?[]const ChangeHash;
pub fn readScope(self: *Document, gpa: Allocator) Error!?*const Clock;
pub fn clockAtScope(self: *Document, gpa: Allocator, heads: []const ChangeHash) Error!?*const Clock;
pub fn isEmpty(self: *const Document) bool;
pub fn len(self: *const Document) usize;
pub fn stats(self: *const Document) Stats;
pub fn textEncoding(self: *const Document) TextEncoding;
pub fn objectType(self: *const Document, obj: ObjId) Error!ObjType;
pub fn resolve(self: *const Document, ex: ExId) ?ExId;
pub fn objectParent(self: *const Document, obj: ObjId) ?ObjId;
pub fn idToExid(self: *const Document, id: OpId) ExId;
pub fn text(self: *Document, gpa: Allocator, obj: ObjId) OpError![]u8;
pub fn marks(self: *Document, gpa: Allocator, obj: ObjId) MarkError![]Mark;
pub fn debugCmp(self: *const Document, other: *const Document) (ParseError || InternalError)!void;

// The diff surface is in §Diffing. The free function below is not a method.
pub fn anonymize(gpa: Allocator, document: *Document, seed: [32]u8) AnonymizeError!Document;  // src/anonymize.zig
```

Everything else in this section is a method on `Document` in `src/doc.zig`.
`anonymize` is a free function in `src/anonymize.zig` because it builds a whole
`Anonymize` and tears it down around one document; `Document.load` is a
file-scope function in the same module because it constructs rather than
mutates, and it takes the same `io` the constructors do.

**`getAuthors` and `bundle` are here, and both were once listed as known gaps.**
`getAuthors(gpa) Error![]const []const u8` is upstream's `get_authors`
(`automerge.rs:410`): **the array is the caller's**, the names are the
document's arena and are valid until the document is dropped, and a name the
document has not stamped on a change is not in it — `setAuthor` alone does not
put a name there, the first commit under that name does. `bundle(gpa, hashes)`
is upstream's `bundle(hashes)` (`automerge.rs:1141`); **the bundle is the
caller's** and is freed with `Bundle.deinit`, `Bundle.bytes` is its on-disk
form, and the receiver is taken mutably only because the one walk it performs
reads a successor scratch buffer the op set owns.

The **deviations** from upstream's `Automerge`, each with a reason:

- **Every constructor takes a `Mode`, a borrowed `std.Io`, and, where it takes
  an encoding, an encoding.** Upstream's `Automerge::new` (`automerge.rs:267`)
  picks UTF-8 and manual by default and `new_with_encoding` (`:307`) is the
  other spelling; this port has one document type with two flavours, so the
  flavour is a parameter rather than a type. An encoding is a document-level
  field that cannot change later (`op_set2/op_set.rs:64`), so it cannot be a
  settable default either. **`io` is this port's alone and has no upstream
  counterpart**: upstream reaches `getrandom` directly and panics
  (`automerge.rs:307-317`), so a Zig caller with no live `std.Io` cannot build
  a document at all, which is the price of not panicking. `clone`, `fork`,
  `forkAt` and `setAuthor` **keep their existing signatures** and use the
  capability the document already stored — which is why `setAuthor` can mint a
  new actor id without taking an `io` of its own.
- **`commit` takes the change's own operations and answers a `ChangeHash`.**
  Upstream's is `Transaction::empty` behind `AutoCommit`, and the hash is what
  upstream returns (`automerge.rs:693`). Handing the ops in is what lets
  `transact.zig` build an operation as a `TxOp` and a `ChangeOp` at once
  without a second encoding pass.
- **`merge` returns the heads afterwards**, because upstream does
  (`automerge.rs:1115-1131`) and a caller merging for the sync protocol needs
  them.
- **`anonymize` takes a seed.** Upstream's is `Automerge::anonymize`
  (`automerge.rs:292`) and draws its own; a Zig caller that wants two runs to
  agree must be able to name the key material, and `anonymize.seed_length` is
  32.

`anonymize` is **this port's own** rather than a mechanical rename: it is
upstream's `Automerge::anonymize` with the key material named, and it is a free
function because it builds a whole `Anonymize` and tears it down around one
document. Its `Shape` is **single-owner on the same terms a `Document` is** —
`deinit` exactly once, no shallow copy (a shallow copy shares ownership and
must not be disposed separately), and the allocator live through disposal —
because a shape hands out borrowed views of the document it was built from, and
every slice it owns lives in its own heap-allocated arena.

**`rollback` is not a `Document` method**, and this file used to say it was.
Upstream's is `TransactionInner::rollback`
(`transaction/inner.rs:211`), which takes the document
rather than being the document; it is `Transaction.rollback` here, under the
manual door above. **There is no `split`** on a document in upstream or in this
port: `Automerge` has `fork` (`automerge.rs:702`), `fork_at` (`:711`) and
`clone`, and nothing named `split`.

### Ownership: one owner, one `deinit`, and no shallow copy

**A `Document` has exactly one owner and must be disposed exactly once.** The
type's own comment says so, and the reason is concrete: `strings` is a
heap-allocated `Strings` block and the op set keeps a pointer into it, so two
copies of the same `Document` value are two owners of one block and the second
`deinit` is a double free. **Hold a `*Document`**, not a `Document` by value.

- **A shallow copy is forbidden, not merely discouraged.** Nothing in the type
  can prevent it — every field is reachable and `Document` is a plain struct —
  so the rule is the caller's: a copy is a second owner, and `deinit` is
  exactly-once.
- **A move is allowed, and only when no borrow of its address remains.** Zig
  lets a `Document` value be returned from `init` and assigned into place,
  because at that moment no `*Document` into it exists. **Once a pointer to the
  document exists, that pointer names the address**, so relocating the value
  out from under it leaves every borrowed slice, walk and transaction reading
  freed memory. That is the whole content of "a move is allowed when no borrow
  of its address remains".
- **`clone`, `fork` and `forkAt` produce independent owners**, each with its
  own allocator-backed state and its own `deinit`. They are the supported way
  to get a second document.
- **The allocator and the `io` capability must both stay live until disposal.**
  The document allocates retained state with the `gpa` it was given, and the
  stored `io` is a borrow whose provider must outlive it. Do not replace
  either ownership-bearing field.
- **`deinit` frees the read scope, the diff cursor, the save cursor, the patch
  log, both actor tables, the string table, the arena and the node table**, in
  that order, and a second call is not defined. `Changes.deinit(gpa)` and
  `Built.deinit(gpa)` are separate exactly-once duties on their own values.

### Synchronization: the caller owns it, for every access

**A `Document` is not internally synchronized and does not pretend to be. Every
access — read as well as write — requires caller synchronization**, which means
one holder at a time. Two properties make that obligation real rather than
declaratory:

- **Readers can update shared scratch and caches.** Several reads take
  `*const Document` and still write: they memoise the scoped clock, advance a
  shared successor scratch buffer, or intern an actor while building a clock.
  **A `*const` receiver is not a read-only receiver**, so two threads reading
  one document concurrently is a data race even when neither writes.
- **Do not mutate through another entry point while a walk is live.** A walk
  borrows the shared buffer above and the document's cached clock; an apply, a
  commit, an isolation change or a second walk invalidates what the first one
  hands out.

**The C ABI inherits this and then widens it** — see § C ABI: its `std.Io`
provider is process-wide and single-threaded, so the obligation there is
global, not per-handle.

### What the caller owns that the document does not

**Every returned buffer is the caller's, and the `gpa` that produced it is the
one that frees it.** That is uniform and it is the rule to remember: `save`,
`saveWithOptions`, `saveAfter`, `saveIncremental` and `bundleFragments` return
`[]u8` buffers freed with the allocator passed in; `getHeads`,
`getMissingDeps`, `getActors`, `getAuthors` and `getActorForAuthor` return
arrays freed with the allocator passed in; `getChanges`, `getChangesAdded` and
`getLastLocalChange` return a `Changes` / `Built` whose own `deinit(gpa)` takes
that allocator, and `manual_transaction.authorFooter` and `sync`'s `encode`
answers likewise. **A returned buffer is
never freed by the document**, so a caller who frees with a different allocator
has the mismatch, not a leak that `Document.deinit` cleans up.

**Borrowed answers stay borrowed.** `text`, `getAuthor`, `isolationHeads`,
`getAuthorForActor`, `baseHeads`, `getActorId` and every `*Range` /
`*AtScope` walk either return the document's own bytes or a slice valid until
the next mutation; §Read's ownership note applies to them all.

### Isolation: what `isolate` and `integrate` do, and the two facts a caller has to get right

Both now call `Document.patchTo`, which is upstream's `AutoCommit::patch_to`
(`autocommit.rs:816-824`) — `PatchLog::finish_current_view` on the view the
document is leaving, then a `DiffIter::log` walk over
`clock_range(before, after)` into the view it is entering. Upstream's `isolate`
is that plus one assignment (`:435-436`) and `integrate` is that plus one
assignment (`:441-442`); before this they moved the `isolation` field and did
neither.

**deviation**: `integrate` is `DiffError!void` where it was `void`, and
`isolate`'s error set widened from `Error!void` to `DiffError!void`. Upstream's
`isolate`/`integrate` return `()` because upstream's
`PatchLog::finish_current_view` reports its one fallible operation by panicking
— `.expect("AutoCommit's patch log always belongs to its document")`
(`patches/patch_log.rs:293`) — and Rust's `Vec`s cannot refuse an allocation.
**The reference is therefore not total here**, so making this total would be a
divergence rather than a fix, and the error is propagated. **There is no place
to swallow it**: catching a refusal leaves the patch log short of a view's
events with nothing to say so, and the next `diffIncremental` answers with a
stream that is silently missing a transition — the defect the wiring removes.

**The C ABI does not share the change.** There is **no `AMintegrate` export**
and `include/automerge.h` declares neither `AMintegrate` nor `AMisolate`;
`src/c/doc.zig`'s `AMdoc.integrate` is a Zig method with no callers, and it is
now `!void`. Nothing in the header moved.

`Document.dropIsolation` is new, and is upstream's isolation write on its own:
the line `AutoCommit::ensure_transaction_closed` (`autocommit.rs:464-466`) and
`AutoCommit::commit_with` (`:735-736`) run beside a commit and on neither of
which is a view transition. `transaction.commitWith` uses it for the scope swap
it performs around a commit — upstream has no such swap, because `AutoCommit`
scopes a transaction when it opens it (`:447`) rather than rewinding the
document to do it, so routing that path through `integrate` would put a
spurious transition in the log of every isolated commit.

**The isolate round trip now emits the reference's seven patches, in the
reference's order, under all four encodings.** The stream is not in this file
because it is in `test/upstream_text_more.zig`, pinned action by action. What
belongs here is the two API facts behind it, because both are a caller's to get
right and neither is a logging nicety.

**One — which actor a change is written as is decided when the transaction is
opened, not when it is committed.** `Document.transactionArgs` reads `heads` for
*both* the dependency set and the actor, and its `Some(heads)` arm calls
`isolate_actor` (`automerge.rs:1259-1281`), which mints a `with_concurrency`
fork of the actor (`types.rs:78-85`) whenever the clock at `heads` does not
cover what that actor has already written. The port has two doors and both are
faithful to a **different** upstream one:

| door | upstream | reads the document's isolation? |
| --- | --- | --- |
| `transact.openAuto`, `transact.openAutoHeld` | `AutoCommit::ensure_transaction_open` (`autocommit.rs:445-457`) | **yes** |
| `Transaction.open`, `Transaction.openAt` | `Automerge::transaction` / `::transaction_at` (`automerge.rs:476-480`, `:501-509`) | **no** — `heads` is the scope clock and `null` means unscoped |

**A caller that isolates and then opens through the low-level door gets a
sequential change**, which is the correct answer for `Automerge::transaction` —
it is reached on a document that has no isolation to read — and the wrong answer
for a caller that wants the reference's `AutoCommit` behaviour. `Document.commit`
does not and cannot paper over it: it takes the transaction's `TransactionArgs`
because the actor index in them is the one every op was already written against
(upstream builds them once, in `ensure_transaction_open`, and
`TransactionInner::commit_impl` reads that same struct — `inner.rs:146-172`,
`:295-297`).

**Two — a local change's patches are the current view's, and they close with
it.** `PatchLog.prepareLocal` copies the change's patches into a
`StagedLocal` beside `events` — a port-only pair, staged because the copy can
be refused and the attachment must not be — and `PatchLog.commitLocal` is the
infallible half that attaches it; `PatchLog.finishCurrentView` then moves both
into `completed` **in that order**, and `makePatches` reads `completed` then
the current view. Upstream holds them as
events in the one list, so a change committed under an isolation is recorded
after the walk that closed the view before it; measured on the oracle's
`text-isolate-incremental`, `PutMap color` and `SpliceText unset` are indices 2
and 3 of seven, after `DeleteMap color` and `DeleteMap name` and before
`Conflict color`. A patch stream is order-sensitive and a mirror is fed it in
order.

**The two halves of `patchTo`, and which one emits what.** The oracle's
`isolateprobe` drains the reference's log at every step of the same case, which
attributes its seven: **five come from the walk** (`DiffIter::log`, called with
`clock_range(before, after)`) and **none from `finish_current_view`**, which is
a no-op at that case's `isolate()` because the previous `diff_incremental` left
the log empty. The close half's job there is to *finalise* the four events the
walk and the isolated commit recorded, which is what puts them in the stream
ahead of the three the `integrate()` walk records. **`integrate()` is not a
no-op either**: after a commit the isolation is `Some([that change])`
(`autocommit.rs:735-736`) while the graph holds every concurrent head, so
`patch_to`'s `before != after` test fires and the walk is what sees a
contested key twice over and raises the conflict.

**A change's own patch range is `args.deps` to *its own hash*, not to
`graph.getHeads()`.** The two are the same list for a sequential change, and
not the same under an isolation, where the change's dependencies are the
isolated heads and the graph keeps every branch it had. Walking to the graph's
heads reports the concurrent branch's changes as this change's own, and flags
the contested key as conflicted on the `PutMap` that introduces it.

### Diffing

`Automerge::diff` (`automerge.rs:1419-1426`) and `AutoCommit`'s cursor
(`autocommit.rs:183-216`, `:347-354`). All five return `Patches`, **which the
caller frees with `Patches.deinit`**: upstream's `Vec<Patch>` frees itself by
dropping, and that ownership does not survive the crossing, so the rule is
written down here rather than inherited.

```zig
pub fn diff(doc: *Document, gpa: Allocator, before: []const ChangeHash, after: []const ChangeHash) DiffError!Patches;
pub fn diffObj(doc: *Document, gpa: Allocator, obj: ExId, before: []const ChangeHash, after: []const ChangeHash, recursive: bool) DiffError!Patches;
pub fn diffIncremental(doc: *Document, gpa: Allocator) DiffError!Patches;
pub fn diffCursor(doc: *const Document, gpa: Allocator) Error![]ChangeHash;
pub fn updateDiffCursor(doc: *Document) Error!void;
pub fn resetDiffCursor(doc: *Document) void;
pub fn makePatches(doc: *const Document, log: *PatchLog) MakeError!Patches;
```

All seven are `src/doc.zig` methods.

`diff` is `diffObj` on the root with `recursive = true`
(`autocommit.rs:255-257`), so there is one implementation of each.
`diffIncremental` reads the events the document **recorded** as it applied
changes since `updateDiffCursor` was last called, answers from them, and then
moves the cursor — so its cost is the size of what changed and not the size of
the history, and a second call with nothing applied returns nothing.
`updateDiffCursor` is the only way to start recording, and it does nothing to a
document with no changes (`autocommit.rs:202`). `resetDiffCursor` stops.
`before` and `after` need not be chronological: document state can move backward.

**deviation**: `Document` carries a patch log and a diff cursor, which
upstream splits between `Automerge` (neither) and `AutoCommit` (both,
`autocommit.rs:67-68`). This port has one document type with a `Mode` flag, so
the fields are on `Document` and start inactive, which is what a caller that
never diffs pays for. `makePatches` takes the **caller's** log rather than the
document's own, exactly as upstream (`autocommit.rs:214-217`).

**not ported**: `AutoCommit::diff_cache` (`autocommit.rs:262-269`), which
memoises the last `(range, obj, recursive, patches)` and answers a repeat with a
clone. **`Patches` here owns its bytes**, so a cache would have to deep-copy
the answer to hand it out — `Patches.appendFrom` is that copy — and the key
would have to pin the borrowed range and object that keep the memoised entry
valid. **That is the whole reason, and it is about shape rather than speed**:
nothing in this repository measures a diff with a cache against a diff without
one, so no performance claim is made here or in § Known gaps. A caller who asks
for the same range twice pays the walk twice.

## Sync

`src/sync/`. **`SyncState` is `sync.State`** (`src/sync/state.zig` `State`) and
**`SyncMessage` is `sync.Message`** (`src/sync/message.zig` `Message`), which is a
struct with an optional body rather than a tagged union: a v2 message may carry
no payload at all.

```zig
// src/sync/state.zig
pub fn new(gpa: Allocator) State;
pub fn newReadOnly(gpa: Allocator) State;
pub fn deinit(state: *State) void;
pub fn encode(state: State, gpa: Allocator) ![]u8;
pub fn decode(gpa: Allocator, bytes: []const u8) ParseError!State;
pub fn setReadOnly(state: *State, read_only: bool) void;
pub fn isPeerReadOnly(state: State) bool;
pub fn peerSupportsSyncReset(state: State) bool;
pub fn sendDoc(state: State) bool;
pub fn their(state: State) ?Their;
pub fn supportsV2Messages(state: State) bool;
pub fn capabilitiesFor(flags: MessageFlags) []const Capability;

// src/sync/message.zig
pub fn init(gpa: Allocator) Message;
pub fn deinit(msg: *Message) void;
pub fn reset(gpa: Allocator, our_heads: []const ChangeHash) !Message;
pub fn decode(gpa: Allocator, bytes: []const u8) ParseError!Message;
pub fn encode(msg: Message, gpa: Allocator) ![]u8;

// src/sync/protocol.zig
pub fn generateSyncMessage(gpa: Allocator, doc: *Document, state: *State) ProtocolError!?Message;
pub fn receiveSyncMessage(gpa: Allocator, doc: *Document, state: *State, message: Message) ProtocolError!void;
pub fn getHashesToSend(gpa: Allocator, doc: *Document, have: []const Have, need: []const ChangeHash) ProtocolError![]ChangeHash;
pub fn makeBloomFilter(gpa: Allocator, doc: *Document, last_sync: []const ChangeHash) ProtocolError!Have;
```

The frozen v1 path is a second pair of the same two functions, because a v1 peer
is a different protocol and not a flag on one (`src/sync/v1.zig`):

```zig
pub fn generateSyncMessage(gpa: Allocator, doc: *Document, state: *State) ProtocolError!?Message;
pub fn receiveSyncMessage(gpa: Allocator, doc: *Document, state: *State, message: Message) ProtocolError!void;
pub fn decodeV1(gpa: Allocator, bytes: []const u8) ParseError!Message;
```

**Ownership in this module is uniform and worth stating once.** `State.encode`,
`Message.encode` and every `ProtocolError![]ChangeHash` answer are **the
caller's**, freed with the `gpa` passed in. `State.their()` **borrows**:
`Their.have` and `Their.need` are views into the state and are invalidated by
the next call that mutates it — `insertSent`, `clearSent` or
`setTheirCapabilities` — so a caller must not hold one across a state mutation.
`MessageBuilder.setHeads`, `setNeed` and `setHave` **take ownership of the
caller's slices**, which is the one place in this module where ownership moves
rather than being borrowed or returned; `MessageBuilder.deinit` releases them.

`receiveSyncMessage` is a mutating call with a partial-failure question a
caller has to answer, and its own documentation states what it leaves mutated
when it returns an error.

The message type byte is `0x42` for v1 and `0x43` for v2
(`src/sync/message.zig` `message_type_sync` and `message_type_sync_v2`), and a
v2-capable peer falls back to v1 when the other side does not advertise v2.

**deviation**: `SyncDoc` does not exist and the four functions are **not**
methods on `Document`. They are free functions taking the document and the
state, because the v1 path is a second pair with the same names in another
module, and a method cannot be two implementations.

**deviation**: `markSyncStateReadOnly` is `State.setReadOnly(state, read_only:
bool)`. Upstream's type is `sync::State`, **not** `SyncState` — `SyncState`
appears upstream only as a doc-example alias (`patches/patch_log.rs:31-35`) and
in a commented-out line (`sync.rs:1360`) — and the method is
`State::set_read_only(&mut self, read_only: bool)` at **`sync/state.rs:159`**,
not in `sync.rs`. The port has no reason to drop the flag.

## Patches

```zig
pub const PatchLog = struct { ... };
pub const Patches = struct { ... };

/// Frees every patch and every byte a patch names. **The one free for the value
/// every method under §Diffing returns**; see that section.
pub fn deinit(patches: *Patches) void;

pub fn init(gpa: Allocator, recording: bool) PatchLog;
pub fn active(gpa: Allocator) PatchLog;
pub fn inactive(gpa: Allocator) PatchLog;
pub fn nullLog(gpa: Allocator) PatchLog;
pub fn deinit(log: *PatchLog) void;

// The staged local-patch pair, below.
pub const StagedLocal = struct { ... };
pub fn prepareLocal(log: *PatchLog, patches: *const Patches) MakeError!StagedLocal;
pub fn commitLocal(log: *PatchLog, staged: StagedLocal) void;
```

All of the above are `src/patches.zig` declarations. `Patches` also has
`init(gpa)`, `allocator()`, `len()`, `slice()`, `appendFrom(other)` and
`clear()`.

### `ConcreteTextValue`

`src/patches.zig` owns this UTF-8 buffer with an allocator and a `TextEncoding`.
`init` requires valid UTF-8. `asStr` borrows the buffer until replacement or disposal.
`len` measures the current buffer in the selected encoding.

```zig
pub fn remove(self: *ConcreteTextValue, index: usize) Error!void;
pub fn removeRange(self: *ConcreteTextValue, index: usize, length: usize) Error!void;
```

`remove` removes one encoded unit. `removeRange` removes one complete span with one replacement allocation.
Both endpoints must be scalar boundaries, or current grapheme boundaries.
A split UTF-8 scalar or UTF-16 surrogate pair returns `error.InvalidCharacter`.
Encoding and allocation refusal leave the original buffer and contents unchanged.
Zero length and an index at or past the end allocate nothing and retain the buffer.
An overshooting end clamps, including when `index + length` would overflow.

These methods do not free a replaced buffer.
The patch arena releases it with `Patches.deinit`.
An ordinary owner frees the old buffer after success only when the pointer changes.
`hydrate.Text` performs this release itself and applies `delete_seq` as one span.

**Representation limit:** Rust stores native encoded units in separate trees
(`text_value.rs:36,113,152`) and renders incomplete units lossily (`:60-62`, `:137-139`).
This port keeps valid UTF-8 and refuses edits that split a scalar.
It also recomputes grapheme segmentation from the current bytes.
It does not promise arbitrary native-unit editing or preservation of Rust's stored grapheme units.
The range operation replaces repeated single-unit deletion in patch coalescing
(`patches/patch_builder.rs:242-249`) and hydrated text.

### Patch log and path-map ownership

**deviation**: the three constructors above are `PatchLog.init`, `.active` and
`.inactive` with an allocator each, and there is **no**
initPatchLogWithCapacity — the log grows, so a capacity is a hint this port
does not take. `nullLog` is upstream's `PatchLog::inactive`
(`src/doc.zig`'s module doc records it as the merge sink). `PatchLog.deinit`
takes no allocator because the log owns nothing it was not given.

**`PatchBuilder` takes ownership of the path map it is seeded with, and its own
allocator is the one that owns every path buffer.** A caller holding a
`PathMap` — from `DiffIter.log`, or one it built — hands it over rather than
releasing it alongside: the builder releases it, and it uses **one allocator for
every buffer it puts and every buffer the map grows into**, not the arena and
not the seed's. **The output arena still owns the produced patch payloads**,
which is a separate obligation from the path map's and is what
`Patches.deinit` releases. The two allocations being distinct is the point: a
patch log outliving its seed, or a seed outliving its log, is the failure this
split prevents.

**deviation**: `PatchLog.prepareLocal(patches)` returning a `StagedLocal`, with
`commitLocal(staged)` as the infallible attachment, have no upstream counterpart
and exist because this port has no insert-time moment to write an *event* in.
`TransactionInner` records one per op as it inserts it (`inner.rs:308-328`); the
port's transaction writes its rows with no log in hand and hands
`Document.commit` the finished ops, which is where the change's patches are
built and staged. **The pair is staged on purpose**: `prepareLocal` can refuse
and the caller releases the result with `StagedLocal.deinit` on that path, so a
refused commit leaves the log with nothing published, while `commitLocal` is
infallible and is the only half that touches the log's lists. It is a **second
current-view list**, not a write into `completed` — see the isolation section
above for the measurement that forces that.

**deviation**: `makePatches` is a method on `Document` and takes the log by
pointer, because that is where upstream puts it (`Automerge::make_patches`,
`automerge.rs:1005-1007`; `AutoCommit::make_patches`, `autocommit.rs:214-217`)
and a free function taking a `Document` by pointer is not that. It returns
`Patches`, not `[]Patch`, for the ownership reason above. There is **no**
`makeCurrentPatches` free function; upstream's `Automerge::current_state`
(`automerge.rs:1014`) is the "whole current state" case of `diff`, and it is
`diff` with an empty `before` (`src/doc.zig` `Document.diff`).

**deviation**: `Document.commit` takes the transaction's `TransactionArgs`
(`src/doc.zig` `Document.commit`) instead of deriving them, and `deps` is **borrowed**. Upstream
has no `Automerge::commit`; `AutoCommit::ensure_transaction_open` builds the
arguments once per transaction (`autocommit.rs:445-457`) and
`TransactionInner::commit_impl` reads that same struct (`inner.rs:146-172`), so
the actor index in it is the one every op was written against by
`TransactionInner::next_id` (`:295-297`). Deriving them at commit time reached
`isolate_actor` — which interns an actor, and interning renumbers every index
above the slot — **after the rows were already in the op set**.

## Errors

```zig
pub const Error = error{ ... };         // src/error.zig — document API, §3.1 of the plan
pub const ParseError = error{ ... };     // src/error.zig — untrusted bytes
pub const InternalError = error{ ... };  // src/error.zig — asserts upstream treats as impossible
pub const InitError = Allocator.Error || std.Io.RandomSecureError;  // src/doc.zig
pub const DiffError = ParseError || ReadOpError || Error || InternalError;  // src/doc.zig = src/iter/doc.zig
```

`ParseError` is the set that must be total over untrusted input: every fixture
in `tests/fuzz-crashers/` and every truncated or corrupted document must return
a `ParseError`, never panic and never loop.

**`Error` carries two variants that are this port's own and have no upstream
counterpart**: `Canceled` — the caller cancelled through its `std.Io` before
the operation finished, and nothing was written — and `EntropyUnavailable` —
the `std.Io` in use could not supply cryptographically secure entropy and does
not fall back to a weaker source, so no actor id was drawn. **Both exist
because upstream panics in those two places** (`automerge.rs:307-317`), and a
caller that cannot distinguish "no id" from "no entropy" cannot decide what to
do. They propagate through the document constructors as `InitError` and out
through `setAuthor`, which mints a new actor id when the author changes.

## C ABI

Not part of the Zig API, and the only place the port speaks to libc. It mirrors
`automerge-c`: the `AMresult` convention, one destructor, pinned enum
discriminants. See [plan.md](docs/plan.md) §6 P10 and
[survey/07](docs/survey/07-bindings.md).

| Declaration | Where |
| --- | --- |
| the header, and the one a C consumer compiles against | `include/automerge.h`, installed as `automerge.h` |
| the production root that forces the exports | `src/c/root.zig` |
| the ABI/header parity check | `test/c/cabi.zig` |
| `AMresult` | `src/c/result.zig` |
| the document surface, and `c_io` | `src/c/doc.zig` |
| the sync surface | `src/c/sync.zig` |
| the C driver and this port's own group | `test/c/main.c`, `test/c/abi_coverage.c` |
| the upstream suite, copied verbatim | `test/c/suite/` |

**What `zig build` ships.** The default step installs **one artifact and one
header**: the static library `libzautomerge.a`, built from the production root
`src/c/root.zig`, and `automerge.h` alongside it. That root exists because
`src/root.zig`'s `c_abi` namespace is lazy — nothing pulls `c/doc.zig` or
`c/sync.zig` in until something references them, and an unanalysed
`export fn` emits no symbol — and because the production library must not
depend on test sources. `src/c/result_from.c` is compiled **into that
library**, not into the test binary: `AMresultFrom` is the ABI's one variadic
function, Zig cannot declare one, upstream writes it in C for the same reason,
and a C consumer linking `libzautomerge.a` expects the symbol there. The
header ships through the package's `paths` (`build.zig.zon` lists `include`), so
a consumer that takes the package gets it; the native module is **still
`zautomerge` and its name is unchanged** — the C artifact and the Zig module
are two different things that happen to share a name, and only the C one is
installed.

**A real compile check against the real header is a separate library.**
`test/c/cabi.zig` is the root of `zautomerge-abi-check`, a second static
library built with the shipped header on its include path, and it **translates
`include/automerge.h` itself** through the same `zig translate-c` every other C
translation unit in this project goes through. Everything it checks is
comptime, so a mismatch fails the build rather than a run:

1. **every function the header declares exists on both sides** — 187 names,
    looked up in the translated header *and* in the four namespaces that can
    export one, so a declaration the library does not export is a compile
    error;
2. **the five exposed structs have matching layouts** — size, alignment,
    field offsets, and canonical field shapes. `AMbyteSpan` and `AMitems`
    cross by value. `AMunknownValue`, `AMstack`, and `AMstackCallbackData`
    are reached by pointer; their pointed-to layouts are also ABI;
3. **every enum constant is checked against the library** — 37 header names
    across five enums, including the distinct default sentinel tags. Coverage
    reflects the header declarations and native enum fields. Each enum's
    size and alignment must match the compiler's C lowering; short enums
    are unsupported;
4. **all 187 physical function signatures are compared** — arity,
    variadicity, calling convention, and canonical return/parameter shapes.
    Canonicalization collapses pointer nullability, pointee constness,
    sentinels, and nominal enum identity; exact-type anchors check selected
    contracts, not all such semantics. Equal shapes also cannot detect a
    reorder of same-typed parameters.

**The check root is not the test root.** `zig test` cannot do this job: `src/c/**`
is `extern "C"` over libc and the test binary links none, which is why
`src/root.zig`'s test block leaves the C modules out on purpose.

**`zig build ctest` uses the production artifact, separately.** The C suite
links `libzautomerge.a` — the same library a consumer gets — and runs the
upstream cmocka suite against it, plus this port's own `abi_coverage.c` group.
The two are independent by construction: `ctest` depends on the ABI-check
library so the header is analysed even when no C case reaches a declaration,
but **the check does not link the artifact and the suite does not link the
check**. A link-level suite proves a declaration resolves to a symbol; the
compile-time check proves the layouts and discriminants agree. Neither alone
is the other.

### C calls from different threads require one global boundary

**There are no locks in this library, and there is no per-handle thread-safety.**
The obligation in `include/automerge.h`'s `\section threads` is stronger than
"do not share one handle between threads": **calls from different threads must
use one caller-owned global serialization boundary and must not overlap, even
across distinct handles.** Two independent documents do not make overlapping
calls from two threads safe.

The reason is the seam, and it is the same `std.Io` from § Conventions. A C
caller cannot supply a capability, so `src/c/doc.zig` binds one at the ABI
boundary — `pub const c_io: std.Io = std.Io.Threaded.global_single_threaded.io()`
— and every entry point that builds a document or draws an actor id reaches it:
`AMcreate`, `AMclone`, `AMfork`, `AMload`, `AMloadIncremental`,
`AMchangeLoadDocument` and `AMactorIdInit`. **That provider is process-wide and
explicitly single-threaded**, so one shared object forces global
serialization rather than per-handle confinement. Two further reasons are in
the header: several accessors memoise a result inside a handle whose prototype
is `const`, and an item's reference count is a plain integer, so there is no
interior mutability to lock over; and a thread-safe `malloc` is not a
thread-safe library.

**The port's own callers do not add a mutex, and the header does not promise
one.** Hold one caller-owned lock through each outer call, its callbacks and its
return. An `AMstackCallback` invoked by `AMstackResult`, `AMstackItem` or
`AMstackItems` may synchronously inspect the stack and result on that same
thread, including advancing a local borrowed `AMitems` cursor and copying
result diagnostics with `AMstrdup` (release only that owned copy with `free`).
**These nested inspection calls use the already-held lock; they must not
reacquire or release it.** This is the pattern in the shipped validator
(`test/c/suite/cmocka_utils.c:67-89`), not general mutation, other reentrancy or
cross-thread entry.

The callback borrows the stack and result and must keep them live, preserving
ownership and links until the outer call returns: no popping, freeing,
replacement or relinking. Returning `false` leaves the result owned by the
stack. Do not retain the callback's stack-parameter address; the null-stack
path uses a temporary node and frees the result after the callback. Retained
item or byte views otherwise require their owning result to stay live. The
library passes callback data unchanged and neither retains nor frees it; keep
callback code and accessed context valid through their last use. The shipped
validator releases its own context after that last use.

The header's `AMstackCallback` contract and the module docs of
`src/c/result.zig`, `src/c/doc.zig` and `src/c/sync.zig` state this bounded rule.
**The Rust reference's `Send`/`Sync` story does not transfer**: a C caller who
needs genuine concurrency uses separate processes.

# Audit: every declaration in this file against the port

Audited 2026-09-30 against the tree at that commit, re-measured 2026-10-01, and
**re-audited for this revision**. The Location column is now **symbol-based**
(`src/doc.zig` `Document.init`) rather than a line number, for the reason §
Conventions gives: four separate re-measurement rounds found the numeric
locators stale, each time because the file below them had grown, and a locator
that must be re-derived on every release is not a locator. **Rust citations keep
their `path:line` form**, because the reference checkout is pinned and
read-only.

- **What the 2026-10-01 re-measurement found, and it is kept here because the
  "was" columns below are only worth reading if the reader knows what went
  wrong**: 149 of 184 inline numeric citations and 72 Location cells pointed at
  the wrong line — the port grew after the audit (`doc.zig` by up to +1061 lines,
  `read.zig` by +304, `transact.zig` by +510). Every citation was re-derived by
  matching the declared name *and* the parameter and return types.
- **Three declarations were wrong against the Rust**, not only against the
  port: `parents` dropped the `Result` that `read.rs:35` and the port's own
  `parents` both have; `mark` and `unmark` do not match
  `transactable.rs:103-117`; and §Write's "twenty … one for one" counts
  twenty-one declarations against upstream's twenty methods.
- **This revision found a further class**: a **known gap that had been closed
  in the tree while the gap list still carried it**. `Document.getAuthors`,
  `Document.bundle`, `Document.fragments`, `Document.getFragment`,
  `Document.bundleFragments` and `read.iter` / `read.iterAt` all exist, and
  each was listed below as absent or not ported. Those rows are corrected here,
  and § Known gaps is shorter than it was.

The **verdict** is about the port, and there are four of them:

- **present** — the port declares this name, with this shape.
- **renamed** — the port declares it under another name; both names are given,
  because the rename is the finding.
- **absent** — the port does not declare it, and this file no longer claims it.
  Every absent row says what replaced it, or says plainly that nothing did.
- **deliberately different** — the port declares this name with a different
  shape, and the section above says why.

The **was** column records what this file claimed **before** the audit. That is
the column that makes the next audit cheap: the failure this audit exists to
stop is an agent reading a name here, not finding it in the port, and
re-deriving the truth from the reference at a cost. A reader who wants to know
what drifted reads that column, not the verdict.

Seven rows in this table are marked **wrong against upstream too**, which is a
stronger statement than "the port differs": those declarations were wrong about
the Rust crate as well, so following them would have produced calls that could
not have been written against either implementation. Three further rows record
prior claims that were wrong about the Rust in the same way — `ObjType`,
`Prop` and `TextEncoding` — and `getMarks` records one "wrong in kind", so
**eleven** rows describe an upstream-wrong prior claim, not seven.

## Conventions and Types

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `root: ExId` | present | `src/root.zig` `root` | — |
| `ExId` | present | `src/types.zig` `ExId` | — |
| `ObjId` | renamed | `src/root.zig` `ObjId`, alias of `ExId` | — |
| `ActorId` | present | `src/types.zig` `ActorId` | — |
| `OpId` | present | `src/types.zig` `OpId` | — |
| `ElemId` | present | `src/types.zig` `ElemId` | not listed; now added |
| `ObjType` (`map`,`list`,`text`) | deliberately different | `src/types.zig` `ObjType` | **wrong**: also `table`, upstream `automerge/src/types.rs:171-181` |
| `Prop` (`key`,`index`,seq type) | deliberately different | `src/types.zig` `Prop` | **wrong**: two arms only, no sequence arm |
| `TextEncoding` (3 names) | deliberately different | `src/types.zig` `TextEncoding` | **wrong**: four names, upstream `automerge/src/types.rs:622-631` |
| `ScalarValue` | present | `src/value.zig` `ScalarValue` | — |
| `Value` | present | `src/value.zig` `Value` | — |
| `Change` | renamed | `src/doc.zig` `Built`, `src/change.zig` `Change` | named `Change` where the port pairs the change with its owned body |
| `ChangeHash` | present | `src/types.zig` `ChangeHash` | — |
| `Mark`, `MarkSet` | present | `src/marks.zig` `Mark`, `MarkSet` | — |
| `Cursor` | present | `src/cursor.zig` `Cursor` | — |
| `Patch`, `PatchAction` | present | `src/patches.zig` `Patch`, `PatchAction` | — |
| `Stats` | present | `src/doc.zig` `Stats` | — |

## §Read

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `get` | present | `src/read.zig` `get` | — |
| `getAll` | deliberately different | `src/read.zig` `getAll` | omitted the allocator |
| `objectType` | present | `src/read.zig` `objectType` | — |
| `length` | deliberately different | `src/read.zig` `length` | claimed `usize`; it is `ReadError!usize` |
| `text` | present | `src/read.zig` `text` | — |
| `keys` | deliberately different | `src/read.zig` `keys` | claimed `Keys`; it is `ReadError!Keys` |
| `values` | deliberately different | `src/read.zig` `values` | claimed `values(doc, obj)`; the port also takes `term: *ValueTerm` |
| `spans` | deliberately different | `src/read.zig` `spans` | omitted the allocator |
| `marks` | deliberately different | `src/read.zig` `marks` | omitted the allocator |
| `getMarks(from, max)` | deliberately different | `src/read.zig` `getMarks` | **wrong in kind**: upstream's `ReadDoc::get_marks` (`read.rs:168-173`) is a single-index `MarkSet`, and that read **is** ported — [`markSetAtIndex`](#read) below. This half-open window over `[]Mark` is `API.md`'s own method and has no upstream spelling; a caller that wants upstream's reaches for `markSetAtIndex` |
| `getAtScope` | present | `src/read.zig` `getAtScope` | the crate-internal door upstream spells `Automerge::get_for(obj, prop, clock)` (`automerge.rs:1859`); `get` is `getAtScope` at the document's own scope |
| `hydrate` | deliberately different | `src/read.zig` `hydrate` | **was absent**: the upstream cases ending in `doc.hydrate(ROOT, None)` (`batch_insert.rs:440`, `:588`, `:793`) were recorded as gaps because `ReadDoc::hydrate` (`read.rs:273-277`) did not exist. **The dependency is recorded here and a coverage count is not** — coverage is measured. The allocator is the port's, upstream allocating the mirror itself, and **a `null` `heads` is the document's read scope rather than upstream's "no clock"** — see the entry below |
| `markSetAtIndex` | present | `src/read.zig` `markSetAtIndex` | upstream's `ReadDoc::get_marks(obj, index, heads)`; **the allocator is the port's**, upstream allocating the `MarkSet` itself |
| `markSetAtScope` | present | `src/read.zig` `markSetAtScope` | `Automerge::get_marks_for(obj, index, clock)` (`automerge.rs:1929-1948`), the crate-internal door the two above resolve their scope through |
| `parents` | present | `src/read.zig` `parents` | — |
| `getMissingDeps` | deliberately different | `src/read.zig` `getMissingDeps` | omitted the allocator |
| `getChangeByHash` | deliberately different | `src/read.zig` `getChangeByHash` | claimed `?Change`; it is `ChangeError!?doc.Built` and takes the allocator |
| `stats` | present | `src/read.zig` `stats` | — |
| `textEncoding` | present | `src/read.zig` `textEncoding` | — |
| `mapRange` | present | `src/read.zig` `mapRange` | named in prose only; takes `KeyRange` (`src/read.zig` `KeyRange`), not `RangeBounds<String>`. **Was** `KeyRange { start: ?[]const u8, end: ?[]const u8 }`, which could not name an excluded end and so could not serve a C `AMmapRange` |
| `listRange` | present | `src/read.zig` `listRange` | named in prose only; takes `IndexRange` (`src/iter/list_range.zig` `IndexRange`) |
| `iter` | present | `src/read.zig` `iter` | **was absent** — recorded as § Known gaps item 3. `ReadDoc::iter_at` (`read.rs:60`) at the root with no heads; the walk is `src/iter/doc.zig` `DocIter`. **The allocator is the port's** |
| `iterAt` | present | `src/read.zig` `iterAt` | **was absent** and was recorded as a declaration this file "named in prose as if it took a range". It is `ReadDoc::iter_at` (`read.rs:60`) under a caller-named subtree and a nullable `heads` whose null is the document's read scope (`automerge.rs:2098`) |
| `getAt` | present | `src/read.zig` `getAt` | upstream's `ReadDoc::get_at(obj, prop, heads)` (`read.rs:266-271`, `automerge.rs:2254-2262`); **was absent** — § Known gaps item 2 |
| `getAllAt` | present | `src/read.zig` `getAllAt` | upstream's `ReadDoc::get_all_at` (`read.rs:293-298`, `automerge.rs:2272-2280`). The dispatch is shared with `getAll` through the private `getAllAtScope`, upstream's `get_all_for`; **the allocator is the port's**, upstream allocating the `Vec` itself |
| `lengthAt` | present | `src/read.zig` `lengthAt` | upstream's `ReadDoc::length_at` (`read.rs:149`, `automerge.rs:2147-2150`) |
| `textAt` | present | `src/read.zig` `textAt` | upstream's `ReadDoc::text_at` (`read.rs:180-184`, `automerge.rs:2200-2207`); **the allocator is the port's**, upstream allocating the `String` itself |
| `keysAt` | present | `src/read.zig` `keysAt` | upstream's `ReadDoc::keys_at` (`read.rs:55`, `automerge.rs:2091-2094`) |
| `valuesAt` | present | `src/read.zig` `valuesAt` | upstream's `ReadDoc::values_at` (`read.rs:137`, `automerge.rs:2138-2141`); takes `term: *ValueTerm` for the same reason `values` does |
| `spansAt` | present | `src/read.zig` `spansAt` | upstream's `ReadDoc::spans_at` (`read.rs:190-194`, `automerge.rs:2160-2167`); **the allocator is the port's** |
| `marksAt` | present | `src/read.zig` `marksAt` | upstream's `ReadDoc::marks_at` (`read.rs:158-162`, `automerge.rs:2213-2220`); **the allocator is the port's** |
| `parentsAt` | present | `src/read.zig` `parentsAt` | upstream's `ReadDoc::parents_at` (`read.rs:40-44`, `automerge.rs:2078-2085`); shares `parents`'s body through the private `parentsAtScope`, upstream's `parents_for` |
| `getCursor` | deliberately different | `src/read.zig` `getCursor` | omitted the allocator, and **carried no `heads` parameter at all until the 2026-10-01 fold — the port previously had a second name for the historical form, `getCursorAt`, and that second name no longer exists**. Upstream's `ReadDoc::get_cursor(obj, position, at)` (`read.rs:199-204`, `automerge.rs:2169-2177`) takes `at` **on the method itself**, in this argument order; the port's parameter is spelled `heads` and the allocator is the port's |
| `getCursorMoving` | deliberately different | `src/read.zig` `getCursorMoving` | omitted the allocator and the `heads`; the port-only `getCursorMovingAt` is gone. Upstream's `ReadDoc::get_cursor_moving(obj, position, at, move_cursor)` (`read.rs:224-230`, `automerge.rs:2179-2188`) — `at` fourth, `move_cursor` after it, which is the port's `bias` in the same place |
| `getCursorPosition` | deliberately different | `src/read.zig` `getCursorPosition` | claimed `Error!CursorPosition`; it is `ReadError!usize`, it now takes `heads`, and the port-only `getCursorPositionAt` is gone. Upstream's `ReadDoc::get_cursor_position(obj, cursor, at)` (`read.rs:237-242`, `automerge.rs:2190-2198`). **Relabels the op set's `error.InvalidIndex` for a cursor naming a row of another object as `error.InvalidCursor`**, which is upstream's own `.ok_or_else(\|\| InvalidCursor(cursor.clone()))` on the seek's empty answer (`automerge.rs:1778-1781`); it answered `InvalidIndex` unscoped and `InvalidCursor` with a clock, so the port was inconsistent with itself. `getCursor`'s `InvalidIndex` for an index at or past the end (`automerge.rs:1754`) is a different question and is unchanged |
| `getCursorPositionFor` | present | `src/read.zig` `getCursorPositionFor` | **was not listed**. The crate-internal door the three above resolve their scope through; public because `hydrate` and the `_at` readers hold a `Clock` |
| `mapRangeAt` | present | `src/read.zig` `mapRangeAt` | upstream's `ReadDoc::map_range_at(obj, range, heads)` (`read.rs:99-104`, `automerge.rs:2110-2118`) |
| `listRangeAt` | present | `src/read.zig` `listRangeAt` | upstream's `ReadDoc::list_range_at(obj, range, heads)` (`read.rs:118-123`, `automerge.rs:2124-2132`) |
| `Document.clockAtScope` | present | `src/doc.zig` `clockAtScope` | upstream's `Automerge::clock_at` (`automerge.rs:1236-1247`), **the one piece of machinery the `_at` set needed and did not have**: the unsuffixed readers resolve their clock through `Document.readScope`, which reads the *isolation*'s heads and no caller-named set. It shares the document's one cached clock (`Document.read_scope`), because a walk copies the `Clock` by value and only its `slots` are borrowed |

## §Write

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `put` | present | `src/transact.zig` `put` | — |
| `putObject` | present | `src/transact.zig` `putObject` | — |
| `insert` | present | `src/transact.zig` `insert` | — |
| `insertObject` | present | `src/transact.zig` `insertObject` | — |
| `increment` | present | `src/transact.zig` `increment` | — |
| `delete` | present | `src/transact.zig` `delete` | — |
| `splice` | present | `src/transact.zig` `splice` | — |
| `spliceText` | present | `src/transact.zig` `spliceText` | — |
| `mark` | present | `src/transact.zig` `mark` | — |
| `unmark` | present | `src/transact.zig` `unmark` | — |
| `splitBlock` | present | `src/transact.zig` `splitBlock` | — |
| `joinBlock` | present | `src/transact.zig` `joinBlock` | — |
| `replaceBlock` | present | `src/transact.zig` `replaceBlock` | — |
| `updateText` | present | `src/transact.zig` `updateText` | — |
| `updateObject` | present | `src/transact.zig` `updateObject` | — |
| `updateSpans` | present | `src/transact.zig` `updateSpans` | — |
| `updateSpansWithConfig` | present | `src/transact.zig` `updateSpansWithConfig` | not listed; now added, with `UpdateSpansConfig` (`src/marks.zig` `UpdateSpansConfig`) |
| `batchCreateObject` | present | `src/transact.zig` `batchCreateObject` | — |
| `initRootFromHydrate` | present | `src/transact.zig` `initRootFromHydrate` | — |
| `pendingOps` | present | `src/transact.zig` `pendingOps` | — |
| `baseHeads` | deliberately different | `src/transact.zig` `baseHeads` | claimed `[]ChangeHash`; it is a `[]const ChangeHash` **borrow** |
| `batchCreateValue` | present | `src/transact.zig` `batchCreateValue` | not listed; now added |
| `openAutoHeld`, `spliceHeld` | present | `src/transact.zig` `openAutoHeld`, `spliceHeld` | not listed; now added |
| `get` (a transaction) | present | `src/transact.zig` `get` | — |
| `markSetAtIndex` (a transaction) | present | `src/transact.zig` `markSetAtIndex` | upstream's `ReadDoc::get_marks` on a `Transaction` (`transaction.rs:231-239`); **`heads` is `?[]const ChangeHash` and `null` means "this transaction's own scope"**, which is not "no scope" |
| `scopeClock` | present | `src/transact.zig` `scopeClock` | upstream's `get_scope(None)` (`manual_transaction.rs:113-122`); `pub` because it is the argument both reads above take |
| `updateListValue`, `updateTextValue` | present | `src/transact.zig` `updateListValue`, `updateTextValue` | **were not listed**. Port-only names; with `updateMapValue` they cover what upstream's single `update_object` (`transactable.rs:183-188`) does with any hydrated value |
| `commit`, `rollback` | deliberately different | `src/transact.zig` `commit`, `rollback` | **the refusal contract was not documented at all**. Both are described under § What commit and rollback promise: a refused commit leaves the transaction open, and `rollback` is resumable, pops each record it undoes, and refuses writes while in progress |
| `Failure(O)`, `Outcome(O)`, `Success(O)` | deliberately different | `src/transaction.zig` `Failure`, `Outcome`, `Success` | `Failure` was documented as a two-field struct `{ err, cancelled }`. It is a **five-field** struct carrying `rollback_error`, a recovery `transaction` and the retained `result`; § Write above has the table |
| **the manual transaction, all of it** | present | `src/transact.zig` `open` (the door), `src/transaction.zig` (the rest) | **was absent**: one sentence said "a separate type" and named no method |

## §Document

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `Document` | present | `src/doc.zig` `Document` | — |
| `init(gpa)` | deliberately different | `src/doc.zig` `init` | claimed `init(gpa) Document`. It is `init(gpa, io, mode) InitError!Document` — a `Mode`, a borrowed `std.Io`, and an error set of exactly `Allocator.Error \|\| std.Io.RandomSecureError` |
| `initWithEncoding(gpa, encoding, mode)` | deliberately different | `src/doc.zig` `initWithEncoding` | claimed no `io` and `Allocator.Error!Document`. It takes `io` and returns `InitError` |
| `load(gpa, bytes)` | deliberately different | `src/doc.zig` `load` | also takes `encoding`, `mode` and `io`, and answers `LoadError` rather than `InitError` |
| `deinit` | present | `src/doc.zig` `deinit` | **the exactly-once, no-shallow-copy and no-move-while-borrowed obligations were not documented**; § Document's ownership section is the contract |
| `loadIncremental(doc, bytes) void` | deliberately different | `src/doc.zig` `loadIncremental` | also takes the allocator and answers `usize` |
| `save` | present | `src/doc.zig` `save` | **the returned buffer's owner was not named**: it is the caller's, freed with the `gpa` passed in |
| `saveIncremental` | present | `src/doc.zig` `saveIncremental` | same ownership note |
| `saveWithOptions`, `saveAfter` | present | `src/doc.zig` `saveWithOptions`, `saveAfter` | not listed; now added, with the same caller-owned buffer |
| `bundleFragments` | present | `src/doc.zig` `bundleFragments` | **not listed**. The caller owns the outer array **and each buffer in it**; a fragment the document cannot rebuild is dropped rather than an error, except `error.OutOfMemory`, which is deliberately not swallowed |
| `commit(…, message, timestamp) Change` | deliberately different | `src/doc.zig` `commit` | takes `ops` and answers a `ChangeHash`. **Its staging was not documented**: everything it publishes happens after its last fallible step, so a refused commit publishes nothing and leaves the transaction open |
| `emptyCommit(…) Change` | deliberately different | `src/doc.zig` `emptyCommit` | answers a `ChangeHash` |
| `merge(doc, other) void` | deliberately different | `src/doc.zig` `merge` | takes the allocator and answers `[]ChangeHash` |
| `applyChanges` | present | `src/doc.zig` `applyChanges` | — |
| `getHeads` | present | `src/doc.zig` `getHeads` | — |
| `getChanges` | deliberately different | `src/doc.zig` `getChanges` | answers `Changes`, not `[]Change`; `Changes.deinit(gpa)` is the caller's duty |
| `getChangesAdded` | deliberately different | `src/doc.zig` `getChangesAdded` | answers `Changes` |
| `getLastLocalChange` | deliberately different | `src/doc.zig` `getLastLocalChange` | takes the allocator, answers `DocumentError!?Built` |
| `getChangeByHash` | deliberately different | `src/doc.zig` `getChangeByHash` | takes the allocator, answers `DocumentError!?Built` |
| `setActorId` | present | `src/doc.zig` `setActorId` | **its role as the deterministic door was not named**. It draws nothing, and it is what every fixture uses instead of the secure draw |
| `getActorId` | present | `src/doc.zig` `getActorId` | — |
| `setActor(doc, actor: usize)` | renamed | `src/doc.zig` `putActorRef` | **wrong against upstream too**: `Automerge::set_actor` (`automerge.rs:367`) takes an `ActorId`, not an index. The upstream door is `setActorId`; `putActorRef` is the port's index-returning intern |
| `getActor(doc) usize` | renamed | `src/doc.zig` `getActorIndex` | **wrong against upstream too**: `Automerge::get_actor` (`automerge.rs:420`) returns `&ActorId`. The port has both: `getActorId` for upstream's answer and `getActorIndex` / `getActor(idx)` for the index |
| `getAuthors(doc, gpa) []ActorId` | present | `src/doc.zig` `getAuthors`, `getActors` | **wrong against upstream too**, and the correction is now in the tree rather than pending: `get_authors` (`automerge.rs:410`) is `&[Author]`, and the port now has that as `getAuthors(gpa) Error![]const []const u8`, **with `getActors(gpa) Error![]ActorId` beside it** for the actor-id list this file used to give the name to. § Known gaps item 4 is closed |
| `getAuthorForActor(doc, actor: usize) ActorId` | deliberately different | `src/doc.zig` `getAuthorForActor` | **wrong against upstream too**: `automerge.rs:414` takes `&ActorId` and answers `Option<Author>`; the port takes `ActorId` by value and answers `?[]const u8`, borrowed from the arena |
| `getActorForAuthor(doc, author) ?usize` | deliberately different | `src/doc.zig` `getActorForAuthor` | **wrong against upstream too**: `get_actors_for_author` (`automerge.rs:403`) answers `Vec<ActorId>`, so this is `Error![]ActorId` with the caller's allocator |
| `forkAt(doc, gpa, heads)` | deliberately different | `src/doc.zig` `forkAt` | also takes a `Mode` |
| `fork(doc, gpa)` | deliberately different | `src/doc.zig` `fork` | also takes a `Mode` |
| `split(doc, gpa, heads)` | absent | — | **wrong against upstream too**: neither upstream nor the port has it |
| `clone(doc, gpa)` | deliberately different | `src/doc.zig` `clone` | also takes a `Mode`, and produces an **independent owner** with its own `deinit` |
| `rollback(doc) usize` | renamed | `src/transact.zig` `rollback` | **wrong against upstream too**: `TransactionInner::rollback` (`transaction/inner.rs:211`) |
| `bundle(doc, gpa) Bundle` | present | `src/doc.zig` `bundle` | **was recorded as absent**, on the reasoning that `src/storage/bundle.zig` had `parse` and `Builder` and no document-level `bundle`. Upstream's `bundle(hashes)` (`automerge.rs:1141`) **is** ported, as `Document.bundle(gpa, hashes) DocumentError!Bundle`. § Known gaps item 6 is closed |
| `fragments`, `getFragment` | present | `src/doc.zig` `fragments`, `getFragment` | **were not listed and were recorded as a missing fragment API**. `Fragment` (`src/change_graph.zig`) and both methods exist; `levels` is a `LevelRange`, and the array plus each fragment's three arrays are the caller's |
| `anonymize(doc, gpa)` | deliberately different | `src/anonymize.zig` `anonymize` | also takes a 32-byte seed |
| `diff` | present | `src/doc.zig` `diff` | **was absent entirely** — `grep -n "diff\|Diff" API.md` found nothing for a method thirteen upstream tests need |
| `diffObj` | present | `src/doc.zig` `diffObj` | added with `diff` |
| `diffIncremental` | present | `src/doc.zig` `diffIncremental` | added with `diff` |
| `diffCursor` | present | `src/doc.zig` `diffCursor` | added with `diff` |
| `updateDiffCursor` | present | `src/doc.zig` `updateDiffCursor` | added with `diff` |
| `resetDiffCursor` | present | `src/doc.zig` `resetDiffCursor` | added with `diff` |
| `makePatches` | present | `src/doc.zig` `makePatches` | — |
| `DiffError` | present | `src/doc.zig` `DiffError` | — |
| `readScope`, `clockAtScope` | present | `src/doc.zig` `readScope`, `clockAtScope` | **the shared-cache rationale was not documented**: both readers answer the same question with the same shape and share one clock, and the soundness of that cache rests on the row count, because `clock_at(heads)` can only change when rows were added |
| `transactionArgs` | present | `src/doc.zig` `transactionArgs` | not listed; now added, and it is the arm that reads the isolation and mints the actor fork |
| `allocator`, `documentMode`, `setMode` | present | `src/doc.zig` `allocator`, `documentMode`, `setMode` | not listed; now added |
| `getActor`, `numActors`, `putActorRef`, `removeActor`, `removeUnusedActors` | present | `src/doc.zig` `getActor`, `numActors`, `putActorRef`, `removeActor`, `removeUnusedActors` | not listed; now added |
| `resolve`, `len`, `isEmpty` | present | `src/doc.zig` `resolve`, `len`, `isEmpty` | not listed; now added. **`isEmpty` reads the change graph and the change queue, not the op set** — the wording "no changes and no rows" was a promise the body did not keep |
| `initWithEncoding`, `loadInto`, `hasChange`, `getMissingDeps`, `isolate`, `integrate`, `isolationHeads`, `objectParent`, `idToExid`, `debugCmp`, `getAuthor`, `setAuthor`, `text`, `marks` | present | same file, by name | not listed; now added. **`setAuthor` mints a new actor id from the stored `io`, and an entropy refusal leaves both actor and author unchanged** |

## §Sync

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `SyncState` | renamed | `src/sync/state.zig` `State` | — |
| `SyncMessage` | renamed | `src/sync/message.zig` `Message` | claimed `union(enum)`; it is a struct |
| `initSyncState()` | renamed | `src/sync/state.zig` `State.new` | — |
| `generateSyncMessage(doc, state) ?SyncMessage` | deliberately different | `src/sync/protocol.zig` `generateSyncMessage` | omitted the allocator; it is a free function, not a `Document` method. **What it leaves mutated on a refusal was not documented**, and neither was the peer's-head ordering that `State.encode`'s ordering assert depends on |
| `receiveSyncMessage(doc, state, msg)` | deliberately different | `src/sync/protocol.zig` `receiveSyncMessage` | same |
| `encodeSyncMessage(state, msg, gpa) ParseError![]u8` | renamed | `src/sync/message.zig` `Message.encode` | it is a method on the message and takes no state |
| `decodeSyncMessage(state, bytes, gpa) ParseError!SyncMessage` | renamed | `src/sync/message.zig` `Message.decode` | same |
| `encodeSyncState(state, gpa)` | renamed | `src/sync/state.zig` `State.encode` | it is a method on the state |
| `decodeSyncState(bytes, gpa)` | renamed | `src/sync/state.zig` `State.decode` | same |
| `markSyncStateReadOnly(state) void` | renamed | `src/sync/state.zig` `State.setReadOnly` | — |
| `MessageBuilder.setHeads` / `setNeed` / `setHave` | present | `src/sync/protocol.zig` `MessageBuilder` | **the ownership of the caller's slices was not documented**: all three take ownership of the slice they are given |
| `BloomFilter.toBytes` | present | `src/sync/bloom.zig` | **the buffer's owner was not documented** |
| the frozen v1 path | present | `src/sync/v1.zig` `generateSyncMessage`, `receiveSyncMessage`, `decodeV1` | not listed; now added |

## §Patches, §Errors, C ABI

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `PatchLog` | present | `src/patches.zig` `PatchLog` | — |
| `Patches` | present | `src/patches.zig` `Patches` | — |
| `Patches.deinit` | present | `src/patches.zig` `Patches.deinit` | — |
| `initPatchLog() PatchLog` | renamed | `src/patches.zig` `PatchLog.init(gpa, recording)` | claimed no allocator |
| `initPatchLogWithCapacity(gpa, capacity)` | absent | — | **absent**: the log grows; there is no capacity parameter anywhere |
| `deinitPatchLog(log, gpa)` | renamed | `src/patches.zig` `PatchLog.deinit()` | it takes no allocator |
| `PatchLog.recordLocal(patches)` | renamed | `src/patches.zig` `prepareLocal` / `commitLocal`, `StagedLocal` | **the method named here no longer exists, and the pair that replaced it is two halves of one staged write**: `prepareLocal` is fallible and its result is released with `StagedLocal.deinit` on the abort path; `commitLocal` is the infallible attachment. A refused commit publishes nothing |
| `makePatches(doc, log, gpa) []Patch` | deliberately different | `src/doc.zig` `makePatches` | returns `Patches` and the log by pointer |
| `makeCurrentPatches(doc, log, gpa)` | absent | `src/doc.zig` `diff` | upstream's `current_state` (`automerge.rs:1014`) is `diff` with an empty `before` |
| `Error`, `ParseError`, `InternalError` | present | `src/error.zig` | — |
| `Error.Canceled`, `Error.EntropyUnavailable` | present | `src/error.zig` `Error` | **were not listed**: two variants this port adds because upstream panics where these return |
| `InitError` | present | `src/doc.zig` `InitError` | **was not listed at all**, and the constructors above returned a different set |
| `DiffError` | present | `src/doc.zig` `DiffError` | — |
| the C ABI | present | `include/automerge.h`, `src/c/root.zig`, `test/c/cabi.zig`, `src/c/result.zig`, `src/c/doc.zig`, `src/c/sync.zig` | **the production root, the installed header and the separate ABI-check root were not named**, and neither was the global serialization obligation |

# Known gaps

Each of these is a real hole, not a deliberate deviation, and each is named
here because the alternative is a caller discovering it.

1. **RESOLVED 2026-10-01 — removed from the list.** This gap said
   `Document.isolatedActorIndex` takes the document's own actor, that a
   transaction opened at historical heads read the present instead, and that
   `can_transaction_at` (`test.rs:2507-2546`) was "transcribed case for case and
   left failing". None of that holds today:
   - `Document.transactionArgs` is now upstream's fork walk — it loops
     `ActorId.withConcurrency` until it finds an actor the clock at `heads`
     covers, or one with no ops (`automerge.rs:1259-1281`).
   - `Document.commit` takes `args: TransactionArgs` as a
     parameter and does not re-derive them; `Transaction.commit`
     (`src/transact.zig` `commit`) hands it its own `actor_index`, `seq`,
     `start_op`, `deps` and `scope`.
   - `test/upstream_doc_test.zig` carries an unskipped `test` asserting
     **upstream's** values at every line — `test.rs:2516`, `:2517`, `:2520`,
     `:2521`, `:2525`, `:2526`, `:2529`, `:2530`, `:2532`, `:2533`, `:2536`,
     `:2537`, `:2540`, `:2541`, `:2543` — and it **passed** when last measured
     (`--test-filter "transaction can be opened at historical heads"`,
     2026-10-01). **That is a historical measurement**: the `io` cutover in this
     revision moved every constructor call site, and re-running it is the
     parent verification step, not something this file may assert.
   What survives is only that `Clock.isolate` sets the isolated actor's slot to
   `maxInt` (`src/clock.zig` `isolate`), which upstream's walk now guards.
2. **RESOLVED 2026-10-01 — removed from the list.** This gap said the `_at`
   historical variants were not ported "with two exceptions", that "a follow-up
   adds one parameter per method and changes no body", and that §Read's
   convention promised heads on "the other twenty-two". **Every upstream
   `ReadDoc` read that names heads is now ported, and the follow-up's own
   prediction — one parameter, no body — is what happened:**
   - **Eleven `_at` readers**, upstream's own names: `getAt`
     (`read.rs:266-271`), `getAllAt` (`:293-298`), `lengthAt` (`:149`),
     `keysAt` (`:55`), `valuesAt` (`:137`), `textAt` (`:180-184`),
     `spansAt` (`:190-194`), `marksAt` (`:158-162`), `mapRangeAt` (`:99-104`),
     `listRangeAt` (`:118-123`) and `parentsAt` (`:40-44`).
   - **Three more, and they are the same three methods.** Upstream carries
     `at: Option<&[ChangeHash]>` **on the methods themselves** — `get_cursor`
     (`read.rs:199-204`, the `at` at `:203`), `get_cursor_moving` (`:224-230`,
     `:228`) and `get_cursor_position` (`:237-242`, `:241`) — and has no second
     name for any of them, so neither does the port. **This revision of this
     item was wrong in a way that mattered: it recorded `getCursorAt`
     (`:199-204`), `getCursorMovingAt` (`:224-230`) and `getCursorPositionAt`
     (`:237-242`) as three additional ported declarations, and said the
     unsuffixed three were "the `at = null` spellings", unchanged, with "no test
     that calls them" broken.** Those three `_at` names were a port-only split
     and **have been removed**; the heads are in the signature of
     `getCursor`, `getCursorMoving` and `getCursorPosition`, and their
     signatures did change, so that sentence does not hold. `src/read.zig`
     records the same cutover at the foot of its own diff block (`:8795-8797`).
   - The two exceptions the gap named — `hydrate` (`read.rs:273-277`) and
     `markSetAtIndex` (`:168-173`) — are unchanged and now sit beside the
     other fourteen rather than alone. `getMissingDeps` (`:302`) takes heads
     upstream too.
   - **One thing did need building**, and the gap did not foresee it:
     `Document.clockAtScope` (`src/doc.zig`), upstream's
     `Automerge::clock_at` (`automerge.rs:1236-1247`). The unsuffixed readers
     resolve their clock through `Document.readScope`, which reads the
     *isolation*'s heads and nothing a caller names. Six of the new readers
     hand a **walk** back, and a walk copies the `Clock` by value and borrows
     only its `slots`, so the clock cannot be built
     and freed inside the call. `clockAtScope` **shares the document's one
     existing `read_scope` cache** rather than adding a second pair of fields,
     because both readers answer the same question with the same shape.
   - **What a historical read resolves its object id against is unchanged and
     is upstream's, not a port's choice.** `Document.resolve`
     (`src/doc.zig` `resolve`) is `exid_to_opid` (`automerge.rs:744-758`), which
     reads `self.ops` and takes no clock: the actor table is the whole
     document's, not a version of it, and a `Clock` is a per-actor vector of
     op counters that scopes *rows*. So "an id valid for the present may not be
     for those heads" does not hold for the id — what those heads can exclude
     is an object's rows. `src/read.zig`'s *Historical reads* section is the
     long form.
   - **One deviation, and it is deliberate**: the three cursor readers name the
     parameter `heads` where upstream names it `at` (`read.rs:203`, `:228`,
     `:241`), because `src/read.zig` declares a file-scope `fn at(id: OpId)` that
     the file's own fixtures call and a parameter may not shadow it. All
     fourteen read the same way now. **The same fold changed one error label**:
     `getCursorPosition` now answers `error.InvalidCursor` for a cursor naming a
     row of a different object, where it answered `error.InvalidIndex`
     unscoped, which is upstream's own `.ok_or_else(|| InvalidCursor(..))` on
     the seek's empty answer (`automerge.rs:1778-1781`) and is what the same
     cursor already answered with a clock.
3. **CLOSED — this revision, and it was a documentation defect rather than a
   code one.** This gap said `ReadDoc::iter_at` / `DocIter` was not ported. It
   is: `read.iter(doc, gpa)` and `read.iterAt(doc, obj, heads, gpa)` are both
   declared, over upstream's `ReadDoc::iter_at` (`read.rs:60`) and
   `Automerge::iter_at` / `AutoCommit::iter_at`
   (`automerge.rs:2096-2100`, `autocommit.rs:855-857`); the walk itself is
   `src/iter/doc.zig`'s `DocIter` with its six item types. The entry point was
   added to the tree before this list was last read.
4. **CLOSED — this revision, likewise.** This gap said `Automerge::get_authors`
   (`automerge.rs:410`) was not ported and that the port had only `getAuthor`
   and `getActors`. The port now has **all three**, and the third is the one
   this gap was about: `Document.getAuthors(gpa) Error![]const []const u8` is
   upstream's `&[Author]` — the array is the caller's, the names are the
   document's arena — while `getActors(gpa) Error![]ActorId` is the actor-id
   list and `getAuthor()` is the one author.
5. **RESOLVED 2026-10-01 — removed from the list.** This gap said
   `src/hydrate.zig` owned the value types and the applier but that there was
   no entry point to produce one. **`read.hydrate` (`src/read.zig` `hydrate`) is
   `ReadDoc::hydrate` (`read.rs:273-277`)**, over `Automerge::hydrate`
   (`automerge.rs:2222-2234`) and `Automerge::hydrate_obj` (`:1638-1650`); the
   recursion itself was always `hydrateMap` / `hydrateList` / `hydrateText`
   over `OpSet::hydrate_map` / `hydrate_list` / `hydrate_text`
   (`hydrate.rs:244-302`), so nothing new is computed here. **What it unblocks
   is the set of upstream cases that end in `doc.hydrate(ROOT, None)` and
   compare that mirror against another** — `batch_insert.rs:440`, `:588` and
   `:793` — each of which was ported with its upstream line recorded against
   this gap. **The dependency is written down and a coverage count is not**;
   counts are measured, and three of them moving at once in a document is how
   a coverage table went wrong twice in one session.

   **One thing did not arrive with it, and it is not a gap:**
   `Automerge::hydrate(heads)` (`automerge.rs:1633-1636`) is this same method at
   the root with no object argument, so a caller writes
   `read.hydrate(&doc, .root, heads, gpa)`. There is no second function and this
   file names none.

   **And one deliberate difference from upstream, which is the only reason the
   method is not a straight port.** Upstream's `None` is *no clock*: both
   `AutoCommit::hydrate` (`autocommit.rs:1011`) and `Transaction::hydrate`
   (`transaction.rs:228`) forward `heads` to `hydrate_obj` without passing
   `get_scope(..)`, where every sibling on the same two types does
   (`autocommit.rs:1020`, `:1003`, `:920-921`, `transaction.rs:238`) — so
   **upstream's `hydrate` reads the present even while the document is
   isolated**, and upstream pins nothing about that. The port's `null` is
   **the document's read scope**, the same clock the other thirteen readers on
   `src/read.zig` take. **The two spellings agree on every document that is not
   isolated**, which is the kind of document every one of those upstream cases
   builds — **and that agreement is what lets them close as written**: a
   `hydrate` that is correct under an isolation and wrong without one would
   fail all of them the same way, and silently.
6. **CLOSED — this revision.** This gap said there is no document-level
   `bundle`. There is: `Document.bundle(gpa, hashes) DocumentError!Bundle` is
   upstream's `Automerge::bundle(hashes)` (`automerge.rs:1141`), the bundle is
   the caller's and is freed with `Bundle.deinit`, and the fragment API beside it
   is ported too — `Document.fragments(gpa, levels)`, `getFragment(gpa, head)`
   and `bundleFragments(gpa, wanted)` over `src/change_graph.zig`'s `Fragment`.
7. **RESOLVED 2026-10-01.** This gap said `UpdateSpansConfig` is not ported.
   It is `src/marks.zig`'s `UpdateSpansConfig`, and
   `transact.updateSpansWithConfig` / `Transaction.updateSpansWithConfig` thread
   it to the mark pass, which reads `per_mark_expands` then `default_expand` for
   each mark it writes and each mark it removes (`text_diff.rs:216-226`,
   `:229-245`). `transact.updateSpans` and `Transaction.updateSpans` are
   upstream's calls with `UpdateSpansConfig::default()`, so their signatures are
   unchanged.
8. **`AutoCommit::diff_cache` is not ported, and the reason is structural rather
   than a performance claim.** Upstream's cache memoises the last
   `(range, obj, recursive, patches)` and answers a repeat with a **clone** of
   the memoised value, because upstream's `Patches` is a `Vec<Patch>` whose
   patches are borrowed views of the document. **This port's `Patches` owns its
   bytes**, so an equivalent cache would have to deep-copy the memoised answer
   to hand it out — `Patches.appendFrom` is that copy — and the key would need
   to pin the borrowed range and object that make the memoised entry valid,
   which is a second invalidation problem the document's own diff cursor does
   not have. § Diffing records the same decision at the declaration.

   **What this does not claim.** No measurement in this repository compares a
   diff with a cache against a diff without one, so nothing here says a cache
   would be faster, slower, or break-even, and nothing here says how often a
   caller repeats the same range. **The claim is only that the port's `Patches`
   ownership makes upstream's clone-on-hit shape inapplicable as written**, and
   that a caller who asks for the same range twice pays the walk twice.

# Zig 0.16.0 / upstream / Rust / port

- **What changed in this file: nothing about the port, and a great deal about
  this file.** Every declaration above was checked against the tree on
  2026-09-30 and the result is the [§ Audit](#audit-every-declaration-in-this-file-against-the-port)
  table. `Automerge::diff` and its five siblings were added; the manual
  transaction surface was added; `getAuthors`, `setActor`, `getActor`,
  `split`, `rollback`, `bundle`, `initPatchLogWithCapacity` and
  `makeCurrentPatches` were removed as claims the port does not make; and
  every remaining signature that was missing an allocator, an error arm or a
  `Mode` now carries the one the port has.

- **What is wrong upstream's side: nothing, and that is the point.** Seven
  things this file asserted were wrong against the *Rust* as well as against
  the port, and all seven are now marked rather than merely corrected.
  `setActor(doc, usize)`, `getActor(doc) usize`, `getAuthors(doc, gpa)
  []ActorId`, `getAuthorForActor(doc, actor: usize) ActorId` and
  `getActorForAuthor(doc, author) ?usize` do not match `automerge.rs:367, 420,
  410, 414, 403`; `split(doc, gpa, heads)` matches nothing at all, upstream or
  here; and `rollback(doc)` matches upstream but only on a transaction
  (`transaction/inner.rs:211`) and not on a document. **An agent that trusted
  this file would have written seven calls that could not have been written as
  written, against either implementation**, which is the failure this audit
  exists to stop.

- **Why the renames are in this file rather than in the port.** `Iter` is
  `iter/doc.zig`'s `ObjIdIter` and upstream `tools`' `DiffIter` is
  `iter/tools.zig`'s `DiffKernel`, because upstream has **two** types named
  `DiffIter` and `iter.rs:17` exports the other one (`iter/doc.rs:66-76`);
  giving the range diff the document diff's name would have renamed the
  document diff. `SyncState`/`SyncMessage` are `State`/`Message` because they
  live in `zautomerge.sync.state` and `zautomerge.sync.message`, where the
  module already says which is which and the longer name repeats it. Both
  renames are recorded at the declaration (`src/iter/tools.zig`, section "The
  name collision") so the reason is in the tree and not only here.

- **Why the audit table is in this file.** `AGENTS.md` calls this a contract,
  and a contract nobody re-checks is a description with better manners. The
  table's "was" column is what makes the *next* audit cheap: the failure mode
  this session hit was an agent reading a name here, not finding it in the
  port, and re-deriving the truth from the reference at a cost. A row with an
  empty "was" is a declaration nobody has to re-derive.

- **What changed in this file since the audit, in the port.** Three known gaps
  are closed, the third **on 2026-10-01**. `read.markSetAtIndex` and
  `read.markSetAtScope` are upstream's single-index `MarkSet` read
  (`read.rs:168-173`); `Transaction.get` and `Transaction.markSetAtIndex` are
  the transaction-scoped pair (`transaction.rs:231-248`); the item that
  replaced them — "a transaction opened at historical heads does not always read
  at them" — no longer describes the tree, which § Known gaps item 1 records;
  and **item 2, the `_at` historical variants, is closed too**: fourteen
  readers in `src/read.zig` now answer at caller-named heads, upstream's names
  followed one for one, and the one piece of machinery they needed —
  `Document.clockAtScope`, upstream's `Automerge::clock_at`
  (`automerge.rs:1236-1247`) — shares the document's existing read-scope
  cache rather than adding a second one. **The follow-on cutover is recorded in
  § Conventions, §Read and § Known gaps item 2**: the port's second name for the
  three historical cursor forms — `getCursorAt`, `getCursorMovingAt`,
  `getCursorPositionAt` — is gone, because upstream never had one
  (`read.rs:203`, `:228`, `:241`), and the heads are in the signature of
  `getCursor`, `getCursorMoving` and `getCursorPosition`. Three audit rows
  (`getCursorAt`, `getCursorMovingAt`, `getCursorPositionAt`) and the three they
  duplicated have become three rows for the three real methods.

- **Known gap 7 is closed: `UpdateSpansConfig` is ported**
  (`marks.rs:466-486`), and nothing else in this file's shape moved for it.
  Upstream's `update_spans(text, config, new_text)` (`transactable.rs:146-152`)
  always takes a config; this file listed a two-argument `updateSpans` and
  recorded the missing argument as a gap, because there was no way to express
  a non-default flag and the two upstream cases that set one
  (`diff_marks.rs:864-903`, `:906-944`) could not be ported. There is now:
  `updateSpansWithConfig` on both the free function and the transaction, and
  `updateSpans` is upstream's call with `UpdateSpansConfig::default()` — which
  is what the port did anyway, because `ExpandMark`'s `Default` is `After`
  (`marks.rs:379-383`) and the old code hardcoded it.

- **What changed for this revision, and it is a contract change rather than a
  re-wording.** Five things a caller has to be able to rely on were not written
  down anywhere, and three of them are new obligations:
  1. **The constructors take a `std.Io` and a `Document` keeps it.**
     `init(gpa, io, mode)`, `initWithEncoding(gpa, io, encoding, mode)` and
     `load(gpa, io, bytes, encoding, mode)` — the last answering `LoadError`
     rather than `InitError` — and `InitError` is exactly
     `Allocator.Error || std.Io.RandomSecureError`. A fresh document draws a
     secure 16-byte actor id, `setActorId` is the deterministic door, and the
     provider must outlive the document. § Conventions is the contract.
  2. **A refused commit leaves the transaction open, and a rollback is
     resumable.** Both are in § What commit and rollback promise, and they are
     what `Failure(O)`'s `rollback_error` / `transaction` / `cancelled` fields
     exist to report: a rollback that refused leaves a **progressed**
     transaction the caller owns, not an unusable document.
  3. **`Document` is single-owner.** No shallow copy; a move only while no
     borrow of its address remains; `clone` / `fork` / `forkAt` for a second
     owner. § Document's ownership section.
  4. **Every returned buffer is the caller's, freed with the `gpa` that produced
     it**, and the save / bundle-fragment / changes surfaces say so at the
     declaration rather than by convention.
  5. **The C route is a shipped artifact and a global obligation.** `zig build`
     installs `libzautomerge.a` from the production root `src/c/root.zig` plus
     `automerge.h`; `test/c/cabi.zig` is a **separate** library that compiles
     the real header; `zig build ctest` links the artifact, not the check; and
     **calls from different threads require one global serialization boundary**,
     because the bridge binds one process-wide
     `std.Io.Threaded.global_single_threaded.io()`. An invoked `AMstackCallback`
     may synchronously inspect its live stack/result on the invoking thread
     under the already-held lock, without reacquiring it or changing ownership.
- **What this revision removed.** Every numeric port locator, and the speed and
  taste claims about `diff_cache`. The `diff_cache` decision is now argued from
  the port's `Patches` ownership and says explicitly that **no measurement in
  this repository compares a cached diff with an uncached one**.
- **What this revision closed in § Known gaps.** Items 3, 4 and 6 were closed in
  the tree while this file still listed them: `read.iter` / `read.iterAt`,
  `Document.getAuthors`, and `Document.bundle` with the fragment API beside it.
  **A known gap that the tree has already answered is a defect in this file**,
  because the alternative is a caller deciding not to use a declaration that is
  right there.
- **Verification belongs to the current tree.** The 2026-09-30 / 2026-10-01
  counts are historical. The current source, compilation and runtime records
  are in [STATUS.md](docs/STATUS.md), including the shipped-header guard,
  allocation-refusal recovery and fetched native/C consumers. No result here
  certifies another target, compiler line or unexercised path.

## API design decisions

Branch: **evolve**. These changes repair the native and C contracts and migrate
their callers without shims. The source baseline is working-copy revision
`4450924c`, committed parent `f8aace30c150ac99f97efbe36a1c731430996ec2`;
these edits are not a committed revision.
The reference is `automerge` 0.12.0 at
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`. The compiler line is Zig 0.16.0.
Current build and runtime evidence belongs in [STATUS.md](docs/STATUS.md).
Historical counts do not certify this working tree.

### Fifteen-topic contract review

| Topic | Deciding constraint and contract |
| --- | --- |
| 1. Root reachability | Consumers import the registered `zautomerge` module. Owning declarations document root aliases. Relative imports alone do not establish a package route. |
| 2. Published artefacts | `build.zig` registers the native module and the static `zautomerge` C artifact. Package paths include their sources, header, and MIT notice. Tests and the oracle are development routes. |
| 3. Mirrored dependencies | Module names mirror the pinned Rust tree for comparison. The handwritten C header is a separate ABI contract, not a Zig-layout promise. |
| 4. Valid construction | Owning containers need their constructors and retained resources. A fresh document needs secure entropy. Literal views are valid only under their stated field invariants. |
| 5. Allocator identity | Owners retain their allocator where later growth or disposal needs it. Caller-owned output names its release allocator. Raw and mark edits use their owner rather than a second allocator parameter. |
| 6. Borrow versus ownership | Reader rows, actor bytes, clocks, and decoder windows have keep-live and invalidation rules. `intoOwned` copies row payloads but does not copy document actor storage. |
| 7. Mutation and finalisation | Receiver spelling does not establish independence or thread safety. Shallow copies of owners share one resource; use explicit clones. Teardowns state exactly-once or reset/no-op behavior. |
| 8. Failure and diagnostics | Error sets name refusals; declarations name residue. Commit refusal leaves a manual transaction open. Native automatic refusal retains published work in the document and recovers before new IDs. Failed rollback preserves resumable ownership and the primary error. Parser and C-result diagnostics keep their own channels. |
| 9. Options and defaults | Optional clocks and heads distinguish read scope from historical reads. Cursor optionals distinguish exhaustion from an absent row. Mode, text encoding, mark expansion, and sync-state defaults are stated at their owners. |
| 10. Type versus value variation | Codec and reader constraints are comptime checks. Runtime options remain values. Sink reflection checks types, not the meaning of two same-typed parameters. |
| 11. Live capabilities | Native document constructors receive `std.Io` and retain it for later actor creation. The provider must outlive the document. Secure-random cancellation discards partial output and propagates `error.Canceled`. |
| 12. Globals | Native callers supply their capability. The fixed C ABI uses a declared process-wide single-threaded provider; calls from different threads share one global serialization boundary, even across distinct handles. Invoked stack callbacks may synchronously inspect live stack/results on the invoking thread under the already-held lock without reacquiring it; no general mutation or cross-thread entry is permitted. |
| 13. Compiler scope | The manifest floor and tested compiler are different evidence. The declared line is 0.16.0; a native build does not prove another target or release. C enum lowering is part of the ABI configuration. |
| 14. Failure-path examples | Examples release owned results and retain borrowed providers. Allocation-refusal tests check observable state and disposal; consumer programs exercise the actual native and C routes. |
| 15. Claim provenance | Source contracts, reached compile checks, and runtime observations are separate claims. No source-only allocation or speed estimate is a measurement. |

### Contested decisions and consumer costs

The records below are this repair's judgments, not recovered upstream motives.
Their taste grade is **analyst-inferred**, authored by the coding assistant.
Their obligations have grade **documented-contract**. The version-scoped
exercised-compilation and runtime records in STATUS.md check named paths;
they do not turn a documented promise into universal enforcement.

| Decision | Priority | Constraint | Cost to consumers | Counterchoice and winning setting |
| --- | --- | --- | --- | --- |
| Retain `std.Io` on `Document` | Independent actor identities without a weak fallback | Clone, fork, and author changes can create actors after construction | Keep the provider live; handle entropy and cancellation errors when an actor is created | Per-call `io` wins for objects that own no backend-bound state and whose callers already supply the capability for every operation |
| Keep the fixed C signatures and declare the provider global | C interoperability | Existing C signatures carry no runtime capability | Serialize calls from different threads under one global boundary, even for distinct handles; invoked stack callbacks inspect live stack/results synchronously on the invoking thread under the already-held lock without reacquiring it or changing ownership, not with general mutation or cross-thread reentrancy | Explicit context handles win in a new ABI that can make provider ownership part of each handle |
| Stage column writes before publishing | Consistent data and indices after allocation refusal | One logical edit changes 21 columns; actor renumbering also changes mark rows/cache and the object table | Retain replacement buffers and copied slab/index metadata until publication or abort; actor remaps materialize independent columns and a new mark-cache map; keep staged owners unchanged | In-place edits win when the whole operation is provably infallible or the caller explicitly accepts and repairs partial progress |
| Make rollback resumable rather than clone the whole document | Preserve recovery without a full-document copy | Undoing successor edges and winner resets can allocate after earlier undo progress | Retain the manual recovery owner or the document's automatic record; retry rollback and do not read rows or move the document until recovery completes | A full snapshot wins when bounded documents and a simple all-or-nothing transaction API justify copying their entire state |
| Transfer path maps with their allocator | Exactly one owner without copying the entire seed | Patch payloads and the path-map array can have different allocators | Preserve borrowed keys and release each resource with its own allocator | A deep-owned seed wins when it must outlive the document that supplies its keys |
| Keep actor ids as byte views with explicit constructors | Wire compatibility and cheap document views | Actor ids have variable length; most reads borrow interned bytes | Read the constructor's ownership rule and free caller-owned bytes explicitly | Separate owned and borrowed types win in a new surface where their extra names prevent frequent ownership mistakes |
| Check the real C header separately from production | A reached ABI check without shipping test dependencies | The variadic function is a C shim; native Zig declarations cover the other exports | Link the shipped artifact and use the shipped header with the stated ABI flags | A generated binding wins when the generator can carry the authored header contract and validate its output on each supported target |
| Keep text UTF-8-backed and delete complete spans | Preserve the surviving suffix and valid rendering | Repeated unit deletion can split a UTF-16 surrogate pair. Current storage holds UTF-8 bytes, not native-unit trees | Use scalar or current grapheme boundaries. Release an old buffer only after replacement. Handle atomic encoding or allocation refusal | Native-unit trees win when callers must edit individual surrogate halves or preserve stored grapheme units across later edits |

Safety fixes need no competing unsafe preference: borrowed storage must stay
live, each owned allocation must be released once, and a fallible operation must
state the work that survives refusal. Zig does not enforce these obligations
through field privacy, receiver spelling, or assignment.