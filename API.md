# zautomerge API

The target public surface of the Zig port. This is a contract, not a
description of what exists. See [PROJECT.md](PROJECT.md) for status and
[plan.md](docs/plan.md) for the phase that produces each part.

Method names, argument order, and semantics follow the Rust crate
(`automerge` 0.12.0) so the two trees are diffable. Where Zig forces a
different shape, the deviation is marked **deviation** and justified.

**Every declaration below was audited against the tree on 2026-09-30 and the
result is [§ Audit](#audit-every-declaration-in-this-file-against-the-port).**
That table is the part of this file that makes the next audit cheap: a
declaration here with a row there is a declaration someone checked. A
declaration added without a row is a defect in this file.

## Conventions

- Every entry point that can allocate takes a `std.mem.Allocator` as its first
  argument.
- Every fallible function returns `Error!T` (`ParseError!T` on the untrusted
  input paths).
- Values that borrow from the document are slices into the document's own
  storage, valid until the next mutation. Values that a caller may hold across a
  mutation are returned by copy.
- Historical reads take a set of heads: `heads: []const ChangeHash` on the
  eleven `_at` readers (`getAt`, `getAllAt`, `lengthAt`, `keysAt`, `valuesAt`,
  `textAt`, `spansAt`, `marksAt`, `mapRangeAt`, `listRangeAt`, `parentsAt`) and
  `heads: ?[]const ChangeHash` on the three cursor readers `getCursor`,
  `getCursorMoving` and `getCursorPosition`, and on `hydrate` and
  `markSetAtIndex`. **Upstream carries `at` on the cursor methods themselves**
  (`read.rs:203`, `:228`, `:241`), not as a second name, and the port follows
  it: `getCursorAt`, `getCursorMovingAt` and `getCursorPositionAt` were
  port-only spellings and **are gone** — there is no alias and no deprecated
  shim. **deviation**: the parameter is spelled `heads` where upstream spells it
  `at`, because `src/read.zig:2241` is a file-scope `fn at(id: OpId)` that the
  file's own fixtures call (`:2301`, `:2303`, `:2316`) and a parameter may not
  shadow it. **A `null` `heads` means the document's read scope**
  (`readScope`, `src/read.zig:552`) — see the `hydrate` entry in §Read — and
  `heads = getHeads()` is the present on the cursor readers as on the `_at`
  ones, because `Automerge::clock_at` (`automerge.rs:1236-1247`) reports no
  clock for it.
- `root` is the root object id, matching `automerge::ROOT`.

```zig
pub const root: ExId = .root;                      // src/root.zig:126
```

The error sets are named per module, not globally, because the port's readers
refuse different things: `read.ReadError` (`src/read.zig:141`),
`read.ChangeError` (`:152`), `transact.WriteError` (`src/transact.zig:179`),
`transaction.TransactionError` (an alias of the same set,
`src/transaction.zig:176`), `doc.LoadError` (`src/doc.zig:207`),
`doc.DocumentError` (`:213`), `doc.DiffError` (`:4227`),
`patches.MakeError` (`src/patches.zig:141`),
`sync.protocol.ProtocolError` (`src/sync/protocol.zig:78`) and
`anonymize.AnonymizeError` (`src/anonymize.zig:190`).

## Types

| Rust | Zig | Where | Notes |
| --- | --- | --- | --- |
| `ExId` / `ObjId` | `ExId` | `src/types.zig:273` | `union(enum) { id, root }`; upstream re-exports `exid::ExId` as `ObjId`, a rename that changes the meaning — the port uses one name. `root.zig:117` keeps `ObjId` as an alias of `ExId`. |
| `ActorId` | `ActorId` | `src/types.zig:84` | `struct { bytes: []const u8 }`, external byte string, never stored in a column |
| `OpId` | `OpId` | `src/types.zig:175` | `{ counter: u32, actor: ActorIdx }` |
| `ElemId` | `ElemId` | `src/types.zig:396` | upstream's `(OpId)` wrapper, kept because a sequence key's actor is optional for the head |
| `ObjType` | `ObjType` | `src/types.zig:494` | `map`, `table`, `list`, `text` — four, not three; `table` is upstream's backwards-compatible spelling of `map` (`automerge/src/types.rs:171-181`) |
| `Prop` | `Prop` | `src/types.zig:519` | `key: []const u8` or `index: usize`, and nothing else — upstream's `Prop` is `Map(String) \| Seq(usize)` (`types.rs`), and there is no third arm |
| `TextEncoding` | `TextEncoding` | `src/types.zig:558` | `unicode_code_point`, `utf8_code_unit`, `utf16_code_unit`, `grapheme_cluster` — four, matching upstream's four (`automerge/src/types.rs:622-631`) |
| `ScalarValue` | `ScalarValue` | `src/value.zig:88` | tagged union |
| `Value` | `Value` | `src/value.zig:170` | `scalar` or `object` |
| `Change` | `doc.Built` | `src/doc.zig:484` | **deviation**: the port's `Change` (`src/change.zig:91`) borrows its bytes and owns one allocation, so a change a document hands out cannot be separated from the body it points into. `Built` is the pair. `Changes` (`src/doc.zig:428`) is the list, with `deinit(gpa)` (`:455`). |
| `ChangeHash` | `ChangeHash` | `src/types.zig:30` | `struct { bytes: [32]u8 }`, SHA-256 |
| `Mark`, `MarkSet` | `Mark`, `MarkSet` | `src/marks.zig:137`, `:325` | |
| `Cursor` | `Cursor` | `src/cursor.zig:359` | |
| `Patch`, `PatchAction` | `Patch`, `PatchAction` | `src/patches.zig:593`, `:628` | |
| `Stats` | `Stats` | `src/doc.zig:417` | three counters; upstream's struct also carries the crate and `rustc` versions, which are facts about the build |

## Read

The `ReadDoc` surface, in `src/read.zig`. `doc: *const Document`, so a read
never needs a mutable borrow, which is what lets iterators be plain values.

```zig
pub fn get(doc: *const Document, obj: ExId, prop: Prop) ReadError!?DocItem;  // read.zig:557
pub fn getAtScope(doc: *const Document, obj: ExId, prop: Prop, scope: ?Clock) ReadError!?DocItem;  // read.zig:588
pub fn getAll(doc: *const Document, obj: ExId, prop: Prop, gpa: Allocator) ReadError![]DocItem;  // read.zig:640
pub fn hydrate(doc: *const Document, obj: ExId, heads: ?[]const ChangeHash, gpa: Allocator) HydrateError!hydrate.Value;  // read.zig:772
pub fn objectType(doc: *const Document, obj: ExId) Error!ObjType;  // read.zig:693
pub fn length(doc: *const Document, obj: ExId) ReadError!usize;  // read.zig:717
pub fn text(doc: *const Document, obj: ExId, gpa: Allocator) ReadError![]u8;  // read.zig:744
pub fn keys(doc: *const Document, obj: ExId) ReadError!Keys;  // read.zig:785
pub fn values(doc: *const Document, obj: ExId, term: *ValueTerm) ReadError!Values;  // read.zig:826
pub fn spans(doc: *const Document, obj: ExId, gpa: Allocator) ReadError!Spans;  // read.zig:853
pub fn marks(doc: *const Document, obj: ExId, gpa: Allocator) ReadError![]Mark;  // read.zig:891
pub fn getMarks(doc: *const Document, obj: ExId, from: usize, max: usize, gpa: Allocator) ReadError![]Mark;  // read.zig:944
pub fn markSetAtIndex(doc: *const Document, obj: ExId, index: usize, heads: ?[]const ChangeHash, gpa: Allocator) ReadError!MarkSet;  // read.zig:1004
pub fn markSetAtScope(doc: *const Document, obj: ExId, index: usize, scope: ?Clock, gpa: Allocator) ReadError!MarkSet;  // read.zig:1062
pub fn parents(doc: *const Document, obj: ExId) ReadError!Parents;  // read.zig:1102
pub fn getCursor(doc: *const Document, obj: ExId, pos: CursorPosition, heads: ?[]const ChangeHash, gpa: Allocator) ReadError!Cursor;  // read.zig:1769
pub fn getCursorMoving(doc: *const Document, obj: ExId, pos: CursorPosition, heads: ?[]const ChangeHash, bias: Bias, gpa: Allocator) ReadError!Cursor;  // read.zig:1807
pub fn getCursorPosition(doc: *const Document, obj: ExId, cursor: Cursor, heads: ?[]const ChangeHash) ReadError!usize;  // read.zig:1855
pub fn getMissingDeps(doc: *const Document, heads: []const ChangeHash, gpa: Allocator) Error![]ChangeHash;  // read.zig:1236
pub fn getChangeByHash(doc: *const Document, hash: ChangeHash, gpa: Allocator) ChangeError!?doc.Built;  // read.zig:1265
pub fn stats(doc: *const Document) Stats;  // read.zig:1278
pub fn textEncoding(doc: *const Document) TextEncoding;  // read.zig:1290
pub fn mapRange(doc: *const Document, obj: ExId, range: KeyRange) ReadError!MapRange;  // read.zig:1341
pub fn listRange(doc: *const Document, obj: ExId, range: IndexRange) ReadError!ListRange;  // read.zig:1370
```

`ValueTerm` (`src/read.zig:179`) is the query term `values` fills in, and it is
an out-parameter rather than a hidden field because two `Values` over the same
document would otherwise share it. `Bias` (`:253`) is `cursor.MoveCursor`
(`src/cursor.zig:222`) under the name `read.rs` uses.

**The three cursor readers take `heads` in upstream's own argument position, and
upstream has no second name for them.** `ReadDoc::get_cursor` takes
`at: Option<&[ChangeHash]>` as its third parameter
(`read.rs:199-204`), `get_cursor_moving` its fourth (`:224-230`) and
`get_cursor_position` its third (`:237-242`); the port's `heads` sits in the
same place. The spellings are `heads` rather than `at` because
`src/read.zig:2241` is a file-scope `fn at(id: OpId)` that the file's own
fixtures call, and a parameter may not shadow it. **A `null` `heads` is the
document's read scope** and `atScope` (`src/read.zig:594`) is the other arm, so
`heads = getHeads()` reads the present.

**`getCursorPosition` answers `error.InvalidCursor` for a cursor naming a row of
a *different* object, and this is a change.** It used to answer
`error.InvalidIndex`, which is the name the op set's own range check raises
(`src/opset/op_set.zig:3145`), and **the port was inconsistent with itself**:
given a clock the same cursor took the slow arm alone
(`src/opset/op_set.zig:3093`), which answers `null` and so already refused with
`InvalidCursor`, while unscoped the fast arm's range check ran first and
refused with `InvalidIndex`. Upstream has one name for one question —
`.ok_or_else(|| AutomergeError::InvalidCursor(cursor.clone()))` on the seek's
empty answer (`automerge.rs:1778-1781`) — because upstream's seek answers
`Option` and cannot raise where the port's can. **`getCursor`'s own
`error.InvalidIndex`, for an index at or past the end of the sequence
(`automerge.rs:1754`), is a different question and is unchanged.**

`HydrateError` (`src/read.zig:172`) is `hydrate.zig`'s `OpHydrateError`: the
union of every read error **plus the mark fold's own set**
(`OpSet::MarksError`), which is what [`hydrateText`](src/hydrate.zig)'s fold
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
(`src/iter/list_range.zig:136`): `start` is the first index and `end` is **one
past** the last, a null `end` being the end of the object. Half-open and two
states per end, because upstream's `normalize_range` does arithmetic that
underflows on `Excluded(0)` and overflows on `Included(usize::MAX)`
(`iter/list_range.rs:359-372`).

`mapRange` takes `KeyRange { start: ?KeyBound, end: ?KeyBound }`
(`src/read.zig:334`), where `KeyBound` is `union(enum) { included: []const u8,
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
pub fn put(doc: *Document, obj: ExId, prop: Prop, value: ScalarValue) Error!OpId;  // transact.zig:2627
pub fn putObject(doc: *Document, obj: ExId, prop: Prop, t: ObjType) Error!ExId;  // transact.zig:2639
pub fn insert(doc: *Document, obj: ExId, index: usize, value: ScalarValue) Error!OpId;  // transact.zig:2651
pub fn insertObject(doc: *Document, obj: ExId, index: usize, t: ObjType) Error!ExId;  // transact.zig:2663
pub fn increment(doc: *Document, obj: ExId, prop: Prop, by: i64) Error!void;  // transact.zig:2680
pub fn delete(doc: *Document, obj: ExId, prop: Prop) Error!usize;  // transact.zig:2694
pub fn splice(doc: *Document, obj: ExId, pos: usize, del: isize, gpa: Allocator, values: []const hydrate.Value) Error!void;  // transact.zig:2709
pub fn spliceText(doc: *Document, obj: ExId, pos: usize, del: isize, text: []const u8) Error!void;  // transact.zig:2781
pub fn mark(doc: *Document, obj: ExId, from: usize, to: usize, name: []const u8, expand: ExpandMark, value: ?ScalarValue) Error!void;  // transact.zig:2796
pub fn unmark(doc: *Document, obj: ExId, from: usize, to: usize, expand: ExpandMark, name: []const u8, value: ?ScalarValue) Error!void;  // transact.zig:2815
pub fn splitBlock(doc: *Document, obj: ExId, index: usize) Error!ExId;  // transact.zig:2834
pub fn joinBlock(doc: *Document, text: ExId, index: usize) Error!void;  // transact.zig:2846
pub fn replaceBlock(doc: *Document, text: ExId, index: usize) Error!ExId;  // transact.zig:2857
pub fn updateText(doc: *Document, obj: ExId, new_text: []const u8) Error!void;  // transact.zig:2873
pub fn updateObject(doc: *Document, obj: ExId, value: hydrate.Map) Error!void;  // transact.zig:2887
pub fn updateSpans(doc: *Document, obj: ExId, spans: []const Span) Error!void;  // transact.zig:2946
pub fn updateSpansWithConfig(doc: *Document, obj: ExId, config: *const UpdateSpansConfig, spans: []const Span) Error!void;  // transact.zig:2967
pub fn batchCreateObject(doc: *Document, obj: ExId, prop: Prop, t: ObjType) Error!ExId;  // transact.zig:2920
pub fn batchCreateValue(doc: *Document, obj: ExId, prop: Prop, value: hydrate.Value, as_insert: bool) Error!ExId;  // transact.zig:2937
pub fn initRootFromHydrate(doc: *Document, value: hydrate.Map) Error!void;  // transact.zig:2958
pub fn pendingOps(doc: *const Document) usize;  // transact.zig:2998
pub fn baseHeads(doc: *const Document) []const ChangeHash;  // transact.zig:3034
```

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
deviation**: `AMdoc` is `{doc, tx}` (`src/c/doc.zig:255-268`) and holds its
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
pub fn openAutoHeld(gpa: Allocator, doc: *Document) WriteError!Transaction;   // transact.zig:2611
pub fn spliceHeld(tx: *Transaction, obj: ExId, pos: usize, del: isize, gpa: Allocator, values: []const hydrate.Value) WriteError!void;  // transact.zig:2738
```

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

`Transaction` is `transact.Transaction` (`src/transaction.zig:166`) re-exported
under upstream's name, and `src/root.zig` publishes it as `manual_transaction`
so the autocommit module keeps the bare name `transaction`. The methods are in
`src/transact.zig`:

```zig
pub fn open(gpa: Allocator, doc: *Document) WriteError!Transaction;                     // transact.zig:463
pub fn openAt(gpa: Allocator, doc: *Document, heads: ?[]const ChangeHash) WriteError!Transaction;  // transact.zig:474
pub fn deinit(self: *Transaction) void;                                                  // transact.zig:441
pub fn commit(self: *Transaction, message: ?[]const u8, time: ?i64) WriteError!?ChangeHash;  // transact.zig:1374
pub fn rollback(self: *Transaction) WriteError!usize;                                    // transact.zig:1437
pub fn count(self: *const Transaction) usize;                                           // transact.zig:482
pub fn baseHeads(self: *const Transaction) []const ChangeHash;                          // transact.zig:490
pub fn nextId(self: *const Transaction) OpId;                                           // transact.zig:497
pub fn put(self: *Transaction, obj: ExId, prop: Prop, value: ScalarValue) WriteError!?OpId;  // transact.zig:907
pub fn putObject(self: *Transaction, obj: ExId, prop: Prop, t: ObjType) WriteError!?ExId;    // transact.zig:931
pub fn insert(self: *Transaction, obj: ExId, index: usize, value: ScalarValue) WriteError!?OpId;  // transact.zig:952
pub fn insertObject(self: *Transaction, obj: ExId, index: usize, t: ObjType) WriteError!?ExId;    // transact.zig:966
pub fn increment(self: *Transaction, obj: ExId, prop: Prop, by: i64) WriteError!void;      // transact.zig:980
pub fn delete(self: *Transaction, obj: ExId, prop: Prop) WriteError!?usize;                // transact.zig:1001
pub fn spliceText(self: *Transaction, obj: ExId, index: usize, del: isize, text: []const u8) WriteError!void;  // transact.zig:1599
pub fn mark(self: *Transaction, obj: ExId, from: usize, to: usize, name: []const u8, expand: ExpandMark, value: ?ScalarValue) WriteError!void;  // transact.zig:1111
pub fn unmark(self: *Transaction, obj: ExId, from: usize, to: usize, expand: ExpandMark, name: []const u8, value: ?ScalarValue) WriteError!void;  // transact.zig:1170
pub fn splitBlock(self: *Transaction, obj: ExId, index: usize) WriteError!ExId;           // transact.zig:1019
pub fn joinBlock(self: *Transaction, text: ExId, index: usize) WriteError!void;            // transact.zig:1048
pub fn replaceBlock(self: *Transaction, text: ExId, index: usize) WriteError!ExId;         // transact.zig:1101
pub fn updateText(self: *Transaction, obj: ExId, new_text: []const u8) WriteError!void;     // transact.zig:1639
pub fn updateMapValue(self: *Transaction, id: ExId, value: *const hydrate.Map) WriteError!void;  // transact.zig:1674
pub fn updateSpans(self: *Transaction, obj: ExId, spans: []const Span) WriteError!void;     // transact.zig:1988
pub fn updateSpansWithConfig(self: *Transaction, obj: ExId, config: *const UpdateSpansConfig, spans: []const Span) WriteError!void;  // transact.zig:2002
pub fn batchCreateObject(self: *Transaction, obj: ExId, prop: Prop, t: ObjType) WriteError!ExId;  // transact.zig:1882
pub fn batchCreateValue(self: *Transaction, obj: ExId, prop: Prop, value: hydrate.Value, as_insert: bool) WriteError!ExId;  // transact.zig:1901
pub fn initRootFromHydrate(self: *Transaction, value: *const hydrate.Map) WriteError!void; // transact.zig:1951
pub fn textFor(self: *Transaction, obj: ExId) WriteError![]const u8;                       // transact.zig:1561
pub fn blockAt(self: *Transaction, obj: ExId, index: usize) WriteError!?ExId;               // transact.zig:1613
pub fn textEncoding(self: *const Transaction) TextEncoding;                                // transact.zig:1590
pub fn get(self: *Transaction, obj: ExId, prop: Prop) WriteError!?read.DocItem;                        // transact.zig:1496
pub fn markSetAtIndex(self: *Transaction, obj: ExId, index: usize, heads: ?[]const ChangeHash, gpa: Allocator) WriteError!MarkSet;  // transact.zig:1524
pub fn scopeClock(self: *Transaction) WriteError!?Clock;                                               // transact.zig:517
```

`open` and `openAt` **refuse a document that is not in `Mode.manual`** with
`error.InvalidOp`, and every function in `## Write` refuses one that is. That
runtime check is the whole substitution for upstream's two types, and it is a
refusal rather than a trap because Rust's answer was a compile error.

`splice` is **not** a `Transaction` method: the bulk insert takes an allocator
and `[]hydrate.Value`, which is `transact.spliceHeld`'s job.

`src/transaction.zig` owns the rest — the commit options, the outcome, the
accessors and the closure doors — under `zautomerge.manual_transaction`:

```zig
pub const CommitOptions = struct { message: ?[]const u8 = null, time: ?i64 = null };  // transaction.zig:193
pub fn Success(comptime O: type) type;                                              // transaction.zig:247
pub const Failure = struct { err: TransactionError, cancelled: usize };             // transaction.zig:265
pub fn Outcome(comptime O: type) type;                                             // transaction.zig:278
pub fn actorId(tx: *const Transaction) ?ActorId;                                    // transaction.zig:303
pub fn maxOp(tx: *const Transaction) TransactionError!u64;                              // transaction.zig:398
pub fn heads(gpa: Allocator, tx: *const Transaction) Error![]ChangeHash;            // transaction.zig:417
pub fn hashForOpid(tx: *const Transaction, id: ExId) ?ChangeHash;                   // transaction.zig:430
pub fn depIndices(gpa: Allocator, tx: *const Transaction) TransactionError![]NodeIdx;  // transaction.zig:461
pub fn changeMeta(tx: *const Transaction, deps: []const NodeIdx) TransactionError!doc.BuildMeta;  // transaction.zig:499
pub fn authorFooter(gpa: Allocator, tx: *const Transaction) Allocator.Error![]u8;   // transaction.zig:527
pub fn commitWith(tx: *Transaction, options: CommitOptions) TransactionError!?ChangeHash;  // transaction.zig:572
pub fn abort(tx: *Transaction) TransactionError!void;                               // transaction.zig:619
pub fn enclose(comptime O: type, gpa: Allocator, doc: *Document, ctx: anytype,
               body: *const fn (@TypeOf(ctx), *Transaction) TransactionError!O) TransactionError!Outcome(O);  // transaction.zig:624
pub fn encloseWith(comptime O: type, gpa: Allocator, doc: *Document, ctx: anytype,
                   body: *const fn (@TypeOf(ctx), *Transaction) TransactionError!O,
                   options: ?*const fn (@TypeOf(ctx), O) CommitOptions) TransactionError!Outcome(O);  // transaction.zig:642
```

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

`enclose`/`encloseWith` are upstream's `Automerge::transact` /
`transact_with` (`automerge.rs:586-601`), which return
`transaction::Result<O, E>`; an error union cannot carry a value and the whole
point of that form is that it does, so the result is a tagged union.

## Document

`src/doc.zig`. **`Document` carries a `Mode` flag** (`src/doc.zig:328`), and
which door a write takes is checked against it at runtime. `Mode.manual` is
upstream's `Automerge`, `Mode.auto` is upstream's `AutoCommit`.

```zig
pub const Document = struct { ... };  // doc.zig:2285

pub fn init(gpa: Allocator, mode: Mode) Allocator.Error!Document;  // doc.zig:2405
pub fn initWithEncoding(gpa: Allocator, encoding: TextEncoding, mode: Mode) Allocator.Error!Document;  // doc.zig:2413
pub fn deinit(doc: *Document) void;  // doc.zig:2451
pub fn load(gpa: Allocator, bytes: []const u8, encoding: TextEncoding, mode: Mode) LoadError!Document;  // doc.zig:3221
pub fn loadInto(doc: *Document, gpa: Allocator, bytes: []const u8, encoding: TextEncoding, mode: Mode) LoadError!void;  // doc.zig:3242
pub fn loadIncremental(doc: *Document, gpa: Allocator, bytes: []const u8) LoadError!usize;  // doc.zig:3628
pub fn save(doc: *Document, gpa: Allocator) LoadError![]u8;  // doc.zig:3738
pub fn saveWithOptions(doc: *Document, gpa: Allocator, options: SaveOptions) LoadError![]u8;  // doc.zig:3768
pub fn saveAfter(doc: *Document, gpa: Allocator, heads: []const ChangeHash) LoadError![]u8;  // doc.zig:3840
pub fn saveIncremental(doc: *Document, gpa: Allocator) LoadError![]u8;  // doc.zig:3868
pub fn applyChanges(doc: *Document, gpa: Allocator, incoming: []const Change) LoadError!usize;  // doc.zig:3909
pub fn getHeads(doc: *const Document, gpa: Allocator) Error![]ChangeHash;  // doc.zig:4507
pub fn getChanges(doc: *Document, gpa: Allocator, have: []const ChangeHash) DocumentError!Changes;  // doc.zig:4555
pub fn getChangesAdded(doc: *Document, gpa: Allocator, other: *Document) DocumentError!Changes;  // doc.zig:4131
pub fn getLastLocalChange(doc: *Document, gpa: Allocator) DocumentError!?Built;  // doc.zig:4596
pub fn getChangeByHash(doc: *Document, gpa: Allocator, hash: ChangeHash) DocumentError!?Built;  // doc.zig:4572
pub fn getMissingDeps(doc: *const Document, gpa: Allocator, heads: []const ChangeHash) Error![]ChangeHash;  // doc.zig:4530
pub fn hasChange(doc: *const Document, hash: ChangeHash) bool;  // doc.zig:4518
pub fn merge(doc: *Document, gpa: Allocator, other: *Document) DocumentError![]ChangeHash;  // doc.zig:4147
pub fn commit(doc: *Document, gpa: Allocator, args: TransactionArgs, ops: []const ChangeOp, message: ?[]const u8, time: ?i64) LoadError!ChangeHash;  // doc.zig:4215
pub fn emptyCommit(doc: *Document, gpa: Allocator, message: ?[]const u8, time: ?i64) LoadError!ChangeHash;  // doc.zig:4487
pub fn setActorId(doc: *Document, actor: ActorId) void;  // doc.zig:2514
pub fn getActorId(doc: *const Document) ActorId;  // doc.zig:2501
pub fn getActorIndex(doc: *const Document) ?ActorIdx;  // doc.zig:2524
pub fn getAuthor(doc: *const Document) ?[]const u8;  // doc.zig:2642
pub fn setAuthor(doc: *Document, gpa: Allocator, author: ?[]const u8) Error!void;  // doc.zig:2655
pub fn getActors(doc: *const Document, gpa: Allocator) Error![]ActorId;  // doc.zig:2633
pub fn getAuthorForActor(doc: *const Document, actor: ActorId) ?[]const u8;  // doc.zig:2611
pub fn getActorForAuthor(doc: *const Document, gpa: Allocator, author: []const u8) Error![]ActorId;  // doc.zig:2620
pub fn forkAt(doc: *Document, gpa: Allocator, heads: []const ChangeHash, mode: Mode) LoadError!Document;  // doc.zig:4737
pub fn fork(doc: *Document, gpa: Allocator, mode: Mode) LoadError!Document;  // doc.zig:4716
pub fn clone(doc: *Document, gpa: Allocator, mode: Mode) LoadError!Document;  // doc.zig:4679
pub fn isolate(doc: *Document, gpa: Allocator, heads: []const ChangeHash) DiffError!void;  // doc.zig:3081
pub fn integrate(doc: *Document) DiffError!void;  // doc.zig:3104
pub fn dropIsolation(doc: *Document) void;  // doc.zig:3128
pub fn isolationHeads(doc: *const Document) ?[]const ChangeHash;  // doc.zig:2949
pub fn numActors(doc: *const Document) usize;  // doc.zig:2535
pub fn isEmpty(doc: *const Document) bool;  // doc.zig:4938
pub fn len(doc: *const Document) usize;  // doc.zig:4868
pub fn stats(doc: *const Document) Stats;  // doc.zig:4797
pub fn textEncoding(doc: *const Document) TextEncoding;  // doc.zig:4807
pub fn objectType(doc: *const Document, obj: ObjId) Error!ObjType;  // doc.zig:4823
pub fn objectParent(doc: *const Document, obj: ObjId) ?ObjId;  // doc.zig:4862
pub fn idToExid(doc: *const Document, id: OpId) ExId;  // doc.zig:4881
pub fn marks(doc: *Document, gpa: Allocator, obj: ObjId) MarkError![]Mark;  // doc.zig:4930
pub fn text(doc: *Document, gpa: Allocator, obj: ObjId) OpError![]u8;  // doc.zig:4892
pub fn debugCmp(doc: *const Document, other: *const Document) (ParseError || InternalError)!void;  // doc.zig:4948
pub fn anonymize(gpa: Allocator, document: *Document, seed: [32]u8) AnonymizeError!Document;  // src/anonymize.zig:209
```

Everything above is a method on `Document` in `src/doc.zig` except `anonymize`,
which is a free function in `src/anonymize.zig:209` because it builds a whole
`Anonymize` and tears it down around one document.

The four **deviations** from upstream's `Automerge`, each with a reason:

- **Every constructor takes a `Mode` and, where it takes an encoding, an
  encoding.** Upstream's `Automerge::new` (`automerge.rs:267`) picks UTF-8 and
  manual by default and `new_with_encoding` (`:307`) is the other spelling; this
  port has one document type with two flavours, so the flavour is a parameter
  rather than a type. An encoding is a document-level field that cannot change
  later (`op_set2/op_set.rs:64`), so it cannot be a settable default either.
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

**`rollback` is not a `Document` method**, and this file used to say it was.
Upstream's is `TransactionInner::rollback`
(`transaction/inner.rs:211`), which takes the document
rather than being the document; it is `Transaction.rollback` here, under the
manual door above. **There is no `split`** on a document in upstream or in this
port: `Automerge` has `fork` (`automerge.rs:702`), `fork_at` (`:711`) and
`clone`, and nothing named `split`.

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
it.** `PatchLog.recordLocal` (a port-only method) parks them beside `events`;
`PatchLog.finishCurrentView` moves both into `completed` **in that order**, and
`makePatches` reads `completed` then the current view. Upstream holds them as
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
pub fn diff(doc: *Document, gpa: Allocator, before: []const ChangeHash, after: []const ChangeHash) DiffError!Patches;  // doc.zig:4979
pub fn diffObj(doc: *Document, gpa: Allocator, obj: ExId, before: []const ChangeHash, after: []const ChangeHash, recursive: bool) DiffError!Patches;  // doc.zig:4996
pub fn diffIncremental(doc: *Document, gpa: Allocator) DiffError!Patches;  // doc.zig:5057
pub fn diffCursor(doc: *const Document, gpa: Allocator) Error![]ChangeHash;  // doc.zig:5076
pub fn updateDiffCursor(doc: *Document) Error!void;  // doc.zig:5092
pub fn resetDiffCursor(doc: *Document) void;  // doc.zig:5113
pub fn makePatches(doc: *const Document, log: *PatchLog) MakeError!Patches;  // doc.zig:5127
```

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
clone. `Patches` here is an arena, so a cache would have to deep-copy the
answer — `Patches.appendFrom` is that copy — and the alternative trades an
allocation on every repeated diff for one on every cache hit, caching an answer
nobody asked for twice.

## Sync

`src/sync/`. **`SyncState` is `sync.State`** (`src/sync/state.zig:87`) and
**`SyncMessage` is `sync.Message`** (`src/sync/message.zig:279`), which is a
struct with an optional body rather than a tagged union: a v2 message may carry
no payload at all.

```zig
pub fn new(gpa: Allocator) State;                                       // state.zig:135
pub fn newReadOnly(gpa: Allocator) State;                              // state.zig:155
pub fn deinit(state: *State) void;                                      // state.zig:164
pub fn encode(state: State, gpa: Allocator) ![]u8;                     // state.zig:184
pub fn decode(gpa: Allocator, bytes: []const u8) ParseError!State;     // state.zig:198
pub fn setReadOnly(state: *State, read_only: bool) void;               // state.zig:240
pub fn isPeerReadOnly(state: State) bool;                              // state.zig:272
pub fn peerSupportsSyncReset(state: State) bool;                       // state.zig:278
pub fn sendDoc(state: State) bool;                                      // state.zig:288
pub fn their(state: State) ?Their;                                     // state.zig:295
pub fn supportsV2Messages(state: State) bool;                          // state.zig:303
pub fn capabilitiesFor(flags: MessageFlags) []const Capability;        // state.zig:344

pub fn init(gpa: Allocator) Message;                                   // message.zig:300
pub fn deinit(msg: *Message) void;                                     // message.zig:315
pub fn reset(gpa: Allocator, our_heads: []const ChangeHash) !Message;  // message.zig:331
pub fn decode(gpa: Allocator, bytes: []const u8) ParseError!Message;   // message.zig:369
pub fn encode(msg: Message, gpa: Allocator) ![]u8;                    // message.zig:445

pub fn generateSyncMessage(gpa: Allocator, doc: *Document, state: *State) ProtocolError!?Message;             // protocol.zig:371
pub fn receiveSyncMessage(gpa: Allocator, doc: *Document, state: *State, message: Message) ProtocolError!void;  // protocol.zig:567
pub fn getHashesToSend(gpa: Allocator, doc: *Document, have: []const Have, need: []const ChangeHash) ProtocolError![]ChangeHash;  // protocol.zig:703
pub fn makeBloomFilter(gpa: Allocator, doc: *Document, last_sync: []const ChangeHash) ProtocolError!Have;  // protocol.zig:807
```

The frozen v1 path is a second pair of the same two functions, because a v1 peer
is a different protocol and not a flag on one:

```zig
pub fn generateSyncMessage(gpa: Allocator, doc: *Document, state: *State) ProtocolError!?Message;             // v1.zig:221
pub fn receiveSyncMessage(gpa: Allocator, doc: *Document, state: *State, message: Message) ProtocolError!void;  // v1.zig:368
pub fn decodeV1(gpa: Allocator, bytes: []const u8) ParseError!Message;                                          // v1.zig:481
```

The message type byte is `0x42` for v1 and `0x43` for v2
(`src/sync/message.zig:78`, `:87`), and a v2-capable peer falls back to v1 when
the other side does not advertise v2.

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
pub const PatchLog = struct { ... };    // src/patches.zig:1983
pub const Patches = struct { ... };     // src/patches.zig:922

/// Frees every patch and every byte a patch names. **The one free for the value
/// every method under §Diffing returns**; see that section.
pub fn deinit(patches: *Patches) void;  // src/patches.zig:939

pub fn init(gpa: Allocator, recording: bool) PatchLog;   // src/patches.zig:2082
pub fn active(gpa: Allocator) PatchLog;                  // src/patches.zig:2092
pub fn inactive(gpa: Allocator) PatchLog;                // src/patches.zig:2097
pub fn nullLog(gpa: Allocator) PatchLog;                 // src/patches.zig:2106
pub fn deinit(log: *PatchLog) void;                      // src/patches.zig:2110
```

`Patches` also has `init(gpa)` (`:930`), `allocator()` (`:935`), `len()` (`:945`),
`slice()` (`:949`), `appendFrom(other)` (`:960`) and `clear()` (`:974`).

**deviation**: the three constructors above are `PatchLog.init`, `.active` and
`.inactive` with an allocator each, and there is **no**
`initPatchLogWithCapacity` — the log grows, so a capacity is a hint this port
does not take. `nullLog` is upstream's `PatchLog::inactive`
(`src/doc.zig`'s module doc records it as the merge sink). `PatchLog.deinit`
takes no allocator because the log owns nothing it was not given.

**deviation**: `PatchLog.recordLocal(patches)` (`src/patches.zig:2555`) has no
upstream counterpart and exists because this port has no insert-time moment to
write an *event* in. `TransactionInner` records one per op as it inserts it
(`inner.rs:308-328`); the port's transaction writes its rows with no log in hand
and hands `Document.commit` the finished ops. `recordLocal` is where they go, and
it is a **second current-view list**, not a write into `completed` — see the
isolation section above for the measurement that forces that.

**deviation**: `makePatches` is a method on `Document` and takes the log by
pointer, because that is where upstream puts it (`Automerge::make_patches`,
`automerge.rs:1005-1007`; `AutoCommit::make_patches`, `autocommit.rs:214-217`)
and a free function taking a `Document` by pointer is not that. It returns
`Patches`, not `[]Patch`, for the ownership reason above. There is **no**
`makeCurrentPatches` free function; upstream's `Automerge::current_state`
(`automerge.rs:1014`) is the "whole current state" case of `diff`, and it is
`diff` with an empty `before` (`src/doc.zig:4203`).

**deviation**: `Document.commit` takes the transaction's `TransactionArgs`
(`src/doc.zig:4073`) instead of deriving them, and `deps` is **borrowed**. Upstream
has no `Automerge::commit`; `AutoCommit::ensure_transaction_open` builds the
arguments once per transaction (`autocommit.rs:445-457`) and
`TransactionInner::commit_impl` reads that same struct (`inner.rs:146-172`), so
the actor index in it is the one every op was written against by
`TransactionInner::next_id` (`:295-297`). Deriving them at commit time reached
`isolate_actor` — which interns an actor, and interning renumbers every index
above the slot — **after the rows were already in the op set**.

## Errors

```zig
pub const Error = error{ ... };         // src/error.zig:17        — document API, §3.1 of the plan
pub const ParseError = error{ ... };     // src/error.zig:94        — untrusted bytes
pub const InternalError = error{ ... };  // src/error.zig:164       — asserts upstream treats as impossible
pub const DiffError = ParseError || ReadOpError || Error || InternalError;  // src/doc.zig:5288 = src/iter/doc.zig:644
```

`ParseError` is the set that must be total over untrusted input: every fixture
in `tests/fuzz-crashers/` and every truncated or corrupted document must return
a `ParseError`, never panic and never loop.

## C ABI

Not part of the Zig API, and the only place the port speaks to libc. It mirrors
`automerge-c`: the `AMresult` convention, one destructor, pinned enum
discriminants. See [plan.md](docs/plan.md) §6 P10 and
[survey/07](docs/survey/07-bindings.md).

| Declaration | Where |
| --- | --- |
| the header | `include/automerge.h` |
| `AMresult` | `src/c/result.zig` |
| the document surface | `src/c/doc.zig` |
| the sync surface | `src/c/sync.zig` |

`src/c/**` is `extern "C"` over libc and `zig test` links none, so
`src/root.zig:222-226` leaves it out of the test block on purpose; it is
verified by the C driver in `test/c/`, which links it and runs the upstream
cmocka suite (`zig build ctest`).

# Audit: every declaration in this file against the port

Audited 2026-09-30 against the tree at that commit, and **re-measured
2026-10-01**. The re-measurement found two classes of drift and both are fixed
below; the verdicts themselves were re-checked against the **Rust** as well as
against the tree, because a verdict that only compares the port to this file
cannot catch a declaration that names something upstream does not have.

- **Line numbers had drifted.** 149 of the 184 `// path:line` citations in the
  body, and 72 of this table's Location cells, pointed at the wrong line — the
  port grew after the audit (`doc.zig` by up to +1061 lines, `read.zig` by +304,
  `transact.zig` by +510, `types.zig` by +66, `patches.zig` by +77). Every
  citation was re-derived by matching the declared name **and** the parameter
  and return types, and each is re-checkable: **184/184** inline citations now
  land on the declaration they name.
- **Three declarations were wrong against the Rust**, not only against the
  port: `parents` dropped the `Result` that `read.rs:35` and `read.zig:1102`
  both have; `mark` and `unmark` do not match `transactable.rs:103-117`; and
  §Write's "twenty … one for one" counts twenty-one declarations against
  upstream's twenty methods.

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
| `root: ExId` | present | `src/root.zig:126` | — |
| `ExId` | present | `src/types.zig:273` | — |
| `ObjId` | renamed | `src/root.zig:117`, alias of `ExId` | — |
| `ActorId` | present | `src/types.zig:84` | — |
| `OpId` | present | `src/types.zig:175` | — |
| `ElemId` | present | `src/types.zig:396` | not listed; now added |
| `ObjType` (`map`,`list`,`text`) | deliberately different | `src/types.zig:494` | **wrong**: also `table`, upstream `automerge/src/types.rs:171-181` |
| `Prop` (`key`,`index`,seq type) | deliberately different | `src/types.zig:519` | **wrong**: two arms only, no sequence arm |
| `TextEncoding` (3 names) | deliberately different | `src/types.zig:558` | **wrong**: four names, upstream `automerge/src/types.rs:622-631` |
| `ScalarValue` | present | `src/value.zig:88` | — |
| `Value` | present | `src/value.zig:170` | — |
| `Change` | renamed | `src/doc.zig:484` (`Built`), `src/change.zig:91` | named `Change` where the port pairs the change with its owned body |
| `ChangeHash` | present | `src/types.zig:30` | — |
| `Mark`, `MarkSet` | present | `src/marks.zig:137`, `:325` | — |
| `Cursor` | present | `src/cursor.zig:359` | — |
| `Patch`, `PatchAction` | present | `src/patches.zig:593`, `:628` | — |
| `Stats` | present | `src/doc.zig:417` | — |

## §Read

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `get` | present | `src/read.zig:557` | — |
| `getAll` | deliberately different | `src/read.zig:640` | omitted the allocator |
| `objectType` | present | `src/read.zig:693` | — |
| `length` | deliberately different | `src/read.zig:717` | claimed `usize`; it is `ReadError!usize` |
| `text` | present | `src/read.zig:744` | — |
| `keys` | deliberately different | `src/read.zig:785` | claimed `Keys`; it is `ReadError!Keys` |
| `values` | deliberately different | `src/read.zig:826` | claimed `values(doc, obj)`; the port also takes `term: *ValueTerm` |
| `spans` | deliberately different | `src/read.zig:853` | omitted the allocator |
| `marks` | deliberately different | `src/read.zig:891` | omitted the allocator |
| `getMarks(from, max)` | deliberately different | `src/read.zig:944` | **wrong in kind**: upstream's `ReadDoc::get_marks` (`read.rs:168-173`) is a single-index `MarkSet`, and that read **is** ported — [`markSetAtIndex`](#read) below. This half-open window over `[]Mark` is `API.md`'s own method and has no upstream spelling; a caller that wants upstream's reaches for `markSetAtIndex` |
| `getAtScope` | present | `src/read.zig:588` | the crate-internal door upstream spells `Automerge::get_for(obj, prop, clock)` (`automerge.rs:1859`); `get` is `getAtScope` at the document's own scope |
| `hydrate` | deliberately different | `src/read.zig:772` | **was absent**: the upstream cases ending in `doc.hydrate(ROOT, None)` (`batch_insert.rs:440`, `:588`, `:793`) were recorded as gaps because `ReadDoc::hydrate` (`read.rs:273-277`) did not exist. **The dependency is recorded here and a coverage count is not** — coverage is measured. The allocator is the port's, upstream allocating the mirror itself, and **a `null` `heads` is the document's read scope rather than upstream's "no clock"** — see the entry below |
| `markSetAtIndex` | present | `src/read.zig:1004` | upstream's `ReadDoc::get_marks(obj, index, heads)`; **the allocator is the port's**, upstream allocating the `MarkSet` itself |
| `markSetAtScope` | present | `src/read.zig:1062` | `Automerge::get_marks_for(obj, index, clock)` (`automerge.rs:1929-1948`), the crate-internal door the two above resolve their scope through |
| `parents` | present | `src/read.zig:1102` | — |
| `getMissingDeps` | deliberately different | `src/read.zig:1236` | omitted the allocator |
| `getChangeByHash` | deliberately different | `src/read.zig:1265` | claimed `?Change`; it is `ChangeError!?doc.Built` and takes the allocator |
| `stats` | present | `src/read.zig:1278` | — |
| `textEncoding` | present | `src/read.zig:1290` | — |
| `mapRange` | present | `src/read.zig:1341` | named in prose only; takes `KeyRange` (`src/read.zig:334`), not `RangeBounds<String>`. **Was** `KeyRange { start: ?[]const u8, end: ?[]const u8 }`, which could not name an excluded end and so could not serve a C `AMmapRange` |
| `listRange` | present | `src/read.zig:1370` | named in prose only; takes `IndexRange` (`src/iter/list_range.zig:136`) |
| `iterAt` | absent | `src/read.zig:52` | named in prose as if it took a range; it is not ported at all |
| `getAt` | present | `src/read.zig:797` | upstream's `ReadDoc::get_at(obj, prop, heads)` (`read.rs:266-271`, `automerge.rs:2254-2262`); **was absent** — § Known gaps item 2 |
| `getAllAt` | present | `src/read.zig:861` | upstream's `ReadDoc::get_all_at` (`read.rs:293-298`, `automerge.rs:2272-2280`). The twenty-line dispatch is shared with `getAll` through the private `getAllAtScope` (`src/read.zig:874`), upstream's `get_all_for`; **the allocator is the port's**, upstream allocating the `Vec` itself |
| `lengthAt` | present | `src/read.zig:1110` | upstream's `ReadDoc::length_at` (`read.rs:149`, `automerge.rs:2147-2150`) |
| `textAt` | present | `src/read.zig:1161` | upstream's `ReadDoc::text_at` (`read.rs:180-184`, `automerge.rs:2200-2207`); **the allocator is the port's**, upstream allocating the `String` itself |
| `keysAt` | present | `src/read.zig:1235` | upstream's `ReadDoc::keys_at` (`read.rs:55`, `automerge.rs:2091-2094`) |
| `valuesAt` | present | `src/read.zig:1298` | upstream's `ReadDoc::values_at` (`read.rs:137`, `automerge.rs:2138-2141`); takes `term: *ValueTerm` for the same reason `values` does |
| `spansAt` | present | `src/read.zig:1355` | upstream's `ReadDoc::spans_at` (`read.rs:190-194`, `automerge.rs:2160-2167`); **the allocator is the port's** |
| `marksAt` | present | `src/read.zig:1442` | upstream's `ReadDoc::marks_at` (`read.rs:158-162`, `automerge.rs:2213-2220`); **the allocator is the port's** |
| `parentsAt` | present | `src/read.zig:1691` | upstream's `ReadDoc::parents_at` (`read.rs:40-44`, `automerge.rs:2078-2085`); shares `parents`'s body through the private `parentsAtScope` (`src/read.zig:1698`), upstream's `parents_for` |
| `getCursor` | deliberately different | `src/read.zig:1769` | omitted the allocator, and **carried no `heads` parameter at all until the 2026-10-01 fold — the port previously had a second name for the historical form, `getCursorAt`, and that second name no longer exists**. Upstream's `ReadDoc::get_cursor(obj, position, at)` (`read.rs:199-204`, `automerge.rs:2169-2177`) takes `at` **on the method itself**, in this argument order; the port's parameter is spelled `heads` and the allocator is the port's |
| `getCursorMoving` | deliberately different | `src/read.zig:1807` | omitted the allocator and the `heads`; the port-only `getCursorMovingAt` is gone. Upstream's `ReadDoc::get_cursor_moving(obj, position, at, move_cursor)` (`read.rs:224-230`, `automerge.rs:2179-2188`) — `at` fourth, `move_cursor` after it, which is the port's `bias` in the same place |
| `getCursorPosition` | deliberately different | `src/read.zig:1855` | claimed `Error!CursorPosition`; it is `ReadError!usize`, it now takes `heads`, and the port-only `getCursorPositionAt` is gone. Upstream's `ReadDoc::get_cursor_position(obj, cursor, at)` (`read.rs:237-242`, `automerge.rs:2190-2198`). **Relabels the op set's `error.InvalidIndex` for a cursor naming a row of another object as `error.InvalidCursor`**, which is upstream's own `.ok_or_else(\|\| InvalidCursor(cursor.clone()))` on the seek's empty answer (`automerge.rs:1778-1781`); it answered `InvalidIndex` unscoped and `InvalidCursor` with a clock, so the port was inconsistent with itself. `getCursor`'s `InvalidIndex` for an index at or past the end (`automerge.rs:1754`) is a different question and is unchanged |
| `mapRangeAt` | present | `src/read.zig:2061` | upstream's `ReadDoc::map_range_at(obj, range, heads)` (`read.rs:99-104`, `automerge.rs:2110-2118`) |
| `listRangeAt` | present | `src/read.zig:2124` | upstream's `ReadDoc::list_range_at(obj, range, heads)` (`read.rs:118-123`, `automerge.rs:2124-2132`) |
| `Document.clockAtScope` | present | `src/doc.zig:5477` | upstream's `Automerge::clock_at` (`automerge.rs:1236-1247`), **the one piece of machinery the `_at` set needed and did not have**: the unsuffixed readers resolve their clock through `Document.readScope`, which reads the *isolation*'s heads and no caller-named set. It shares the document's one cached clock (`src/doc.zig:2364-2380`), because a walk copies the `Clock` by value and only its `slots` are borrowed |

## §Write

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `put` | present | `src/transact.zig:2627` | — |
| `putObject` | present | `src/transact.zig:2639` | — |
| `insert` | present | `src/transact.zig:2651` | — |
| `insertObject` | present | `src/transact.zig:2663` | — |
| `increment` | present | `src/transact.zig:2680` | — |
| `delete` | present | `src/transact.zig:2694` | — |
| `splice` | present | `src/transact.zig:2709` | — |
| `spliceText` | present | `src/transact.zig:2781` | — |
| `mark` | present | `src/transact.zig:2796` | — |
| `unmark` | present | `src/transact.zig:2815` | — |
| `splitBlock` | present | `src/transact.zig:2834` | — |
| `joinBlock` | present | `src/transact.zig:2846` | — |
| `replaceBlock` | present | `src/transact.zig:2857` | — |
| `updateText` | present | `src/transact.zig:2873` | — |
| `updateObject` | present | `src/transact.zig:2887` | — |
| `updateSpans` | present | `src/transact.zig:2946` | — |
| `updateSpansWithConfig` | present | `src/transact.zig:2967` | not listed; now added, with `UpdateSpansConfig` (`marks.rs:466-486`) |
| `batchCreateObject` | present | `src/transact.zig:2920` | — |
| `initRootFromHydrate` | present | `src/transact.zig:2958` | — |
| `pendingOps` | present | `src/transact.zig:2998` | — |
| `baseHeads` | deliberately different | `src/transact.zig:3034` | claimed `[]ChangeHash`; it is a `[]const ChangeHash` **borrow** |
| `batchCreateValue` | present | `src/transact.zig:2937` | not listed; now added |
| `openAutoHeld`, `spliceHeld` | present | `src/transact.zig:2611`, `src/transact.zig:2250` | not listed; now added |
| `get` (a transaction) | present | `src/transact.zig:1496` | — |
| `markSetAtIndex` (a transaction) | present | `src/transact.zig:1524` | upstream's `ReadDoc::get_marks` on a `Transaction` (`transaction.rs:231-239`); **`heads` is `?[]const ChangeHash` and `null` means "this transaction's own scope"**, which is not "no scope" |
| `scopeClock` | present | `src/transact.zig:517` | upstream's `get_scope(None)` (`manual_transaction.rs:113-122`); `pub` because it is the argument both reads above take |
| **the manual transaction, all of it** | present | `src/transact.zig:463` (the door), `src/transaction.zig:193` (the rest) | **was absent**: one sentence said "a separate type" and named no method |

## §Document

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `Document` | present | `src/doc.zig:2285` | — |
| `init(gpa)` | deliberately different | `src/doc.zig:2405` | claimed `init(gpa) Document`; it takes a `Mode` and returns `Allocator.Error!Document` |
| `deinit` | present | `src/doc.zig:2451` | — |
| `load(gpa, bytes)` | deliberately different | `src/doc.zig:3221` | also takes `encoding` and `mode` |
| `loadIncremental(doc, bytes) void` | deliberately different | `src/doc.zig:3628` | also takes the allocator and answers `usize` |
| `save` | present | `src/doc.zig:3738` | — |
| `saveIncremental` | present | `src/doc.zig:3868` | — |
| `commit(…, message, timestamp) Change` | deliberately different | `src/doc.zig:4215` | takes `ops` and answers a `ChangeHash` |
| `emptyCommit(…) Change` | deliberately different | `src/doc.zig:4487` | answers a `ChangeHash` |
| `merge(doc, other) void` | deliberately different | `src/doc.zig:4147` | takes the allocator and answers `[]ChangeHash` |
| `applyChanges` | present | `src/doc.zig:3909` | — |
| `getHeads` | present | `src/doc.zig:4507` | — |
| `getChanges` | deliberately different | `src/doc.zig:4555` | answers `Changes`, not `[]Change` |
| `getChangesAdded` | deliberately different | `src/doc.zig:4131` | answers `Changes` |
| `getLastLocalChange` | deliberately different | `src/doc.zig:4596` | takes the allocator, answers `DocumentError!?Built` |
| `getChangeByHash` | deliberately different | `src/doc.zig:4572` | takes the allocator, answers `DocumentError!?Built` |
| `setActorId` | present | `src/doc.zig:2514` | — |
| `getActorId` | present | `src/doc.zig:2501` | — |
| `setActor(doc, actor: usize)` | renamed | `src/doc.zig:2549` `putActorRef(gpa, ActorId) Error!ActorIdx` | **wrong against upstream too**: `Automerge::set_actor` (`automerge.rs:367`) takes an `ActorId`, not an index |
| `getActor(doc) usize` | renamed | `src/doc.zig:2524` `getActorIndex() ?ActorIdx` | **wrong against upstream too**: `Automerge::get_actor` (`automerge.rs:420`) returns `&ActorId` |
| `getAuthors(doc, gpa) []ActorId` | renamed | `src/doc.zig:2633` `getActors(gpa) Error![]ActorId` | **wrong against upstream too**: `get_authors` (`automerge.rs:410`) is `&[Author]`, and that method is **not ported** |
| `getAuthorForActor(doc, actor: usize) ActorId` | deliberately different | `src/doc.zig:2611` `getAuthorForActor(actor: ActorId) ?[]const u8` | **wrong against upstream too**: `automerge.rs:414` takes `&ActorId` and answers `Option<Author>` |
| `getActorForAuthor(doc, author) ?usize` | deliberately different | `src/doc.zig:2620` `getActorForAuthor(gpa, author) Error![]ActorId` | **wrong against upstream too**: `get_actors_for_author` (`automerge.rs:403`) answers `Vec<ActorId>` |
| `forkAt(doc, gpa, heads)` | deliberately different | `src/doc.zig:4737` | also takes a `Mode` |
| `fork(doc, gpa)` | deliberately different | `src/doc.zig:4716` | also takes a `Mode` |
| `split(doc, gpa, heads)` | absent | — | **wrong against upstream too**: neither upstream nor the port has it |
| `clone(doc, gpa)` | deliberately different | `src/doc.zig:4679` | also takes a `Mode` |
| `rollback(doc) usize` | renamed | `src/transact.zig:1437` `Transaction.rollback` | **wrong against upstream too**: `TransactionInner::rollback` (`transaction/inner.rs:211`) |
| `bundle(doc, gpa) Bundle` | absent | — | upstream's `bundle(hashes)` (`automerge.rs:1141`) takes a hash list; `src/storage/bundle.zig` has `parse` and `Builder` and no document-level `bundle` |
| `anonymize(doc, gpa)` | deliberately different | `src/anonymize.zig:209` | also takes a 32-byte seed |
| `diff` | present | `src/doc.zig:4979` | **was absent entirely** — `grep -n "diff\|Diff" API.md` found nothing for a method thirteen upstream tests need |
| `diffObj` | present | `src/doc.zig:4996` | added with `diff` |
| `diffIncremental` | present | `src/doc.zig:5057` | added with `diff` |
| `diffCursor` | present | `src/doc.zig:5076` | added with `diff` |
| `updateDiffCursor` | present | `src/doc.zig:5092` | added with `diff` |
| `resetDiffCursor` | present | `src/doc.zig:5113` | added with `diff` |
| `makePatches` | present | `src/doc.zig:5127` | — |
| `DiffError` | present | `src/doc.zig:5288` | — |
| `initWithEncoding`, `loadInto`, `saveWithOptions`, `saveAfter`, `hasChange`, `getMissingDeps`, `isolate`, `integrate`, `isolationHeads`, `numActors`, `isEmpty`, `len`, `objectParent`, `idToExid`, `debugCmp`, `getAuthor`, `setAuthor` | present | `src/doc.zig:2413, 3242, 3768, 3840, 4518, 4530, 3081, 3104, 2949, 2535, 4938, 4868, 4862, 4881, 4948, 2642, 2655` | not listed; now added |

## §Sync

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `SyncState` | renamed | `src/sync/state.zig:87` `State` | — |
| `SyncMessage` | renamed | `src/sync/message.zig:279` `Message` | claimed `union(enum)`; it is a struct |
| `initSyncState()` | renamed | `src/sync/state.zig:135` `State.new(gpa)` | — |
| `generateSyncMessage(doc, state) ?SyncMessage` | deliberately different | `src/sync/protocol.zig:371` | omitted the allocator; it is a free function, not a `Document` method |
| `receiveSyncMessage(doc, state, msg)` | deliberately different | `src/sync/protocol.zig:567` | same |
| `encodeSyncMessage(state, msg, gpa) ParseError![]u8` | renamed | `src/sync/message.zig:445` `Message.encode(gpa) ![]u8` | it is a method on the message and takes no state |
| `decodeSyncMessage(state, bytes, gpa) ParseError!SyncMessage` | renamed | `src/sync/message.zig:369` `Message.decode(gpa, bytes)` | same |
| `encodeSyncState(state, gpa)` | renamed | `src/sync/state.zig:184` `State.encode(gpa)` | it is a method on the state |
| `decodeSyncState(bytes, gpa)` | renamed | `src/sync/state.zig:198` `State.decode(gpa, bytes)` | same |
| `markSyncStateReadOnly(state) void` | renamed | `src/sync/state.zig:240` `setReadOnly(read_only: bool)` | — |
| the frozen v1 path | present | `src/sync/v1.zig:221`, `src/sync/v1.zig:368`, `src/sync/v1.zig:481` | not listed; now added |

## §Patches, §Errors, C ABI

| Declaration | Verdict | Location | Was |
| --- | --- | --- | --- |
| `PatchLog` | present | `src/patches.zig:1983` | — |
| `Patches` | present | `src/patches.zig:922` | — |
| `Patches.deinit` | present | `src/patches.zig:939` | — |
| `initPatchLog() PatchLog` | renamed | `src/patches.zig:2082` `PatchLog.init(gpa, recording)` | claimed no allocator |
| `initPatchLogWithCapacity(gpa, capacity)` | absent | — | **absent**: the log grows; there is no capacity parameter anywhere |
| `deinitPatchLog(log, gpa)` | renamed | `src/patches.zig:2110` `PatchLog.deinit()` | it takes no allocator |
| `makePatches(doc, log, gpa) []Patch` | deliberately different | `src/doc.zig:5127` | returns `Patches` and the log by pointer |
| `makeCurrentPatches(doc, log, gpa)` | absent | `src/doc.zig:4979` | upstream's `current_state` (`automerge.rs:1014`) is `diff` with an empty `before` |
| `Error`, `ParseError`, `InternalError` | present | `src/error.zig:17, 94, 164` | — |
| `DiffError` | present | `src/doc.zig:5288` | — |
| the C ABI | present | `include/automerge.h`, `src/c/result.zig`, `src/c/doc.zig`, `src/c/sync.zig` | — |

# Known gaps

Each of these is a real hole, not a deliberate deviation, and each is named
here because the alternative is a caller discovering it.

1. **RESOLVED 2026-10-01 — removed from the list.** This gap said
   `Document.isolatedActorIndex` takes the document's own actor, that a
   transaction opened at historical heads read the present instead, and that
   `can_transaction_at` (`test.rs:2507-2546`) was "transcribed case for case and
   left failing". None of that holds today:
   - `src/doc.zig:2891` is now upstream's fork walk — it loops
     `ActorId.withConcurrency` until it finds an actor the clock at `heads`
     covers, or one with no ops (`automerge.rs:1259-1281`).
   - `Document.commit` (`src/doc.zig:4215`) takes `args: TransactionArgs` as a
     parameter and does not re-derive them; `Transaction.commit`
     (`src/transact.zig:1374`) hands it its own `actor_index`, `seq`,
     `start_op`, `deps` and `scope`.
   - `test/upstream_doc_test.zig:3126` is an unskipped `test` asserting
     **upstream's** values at every line — `test.rs:2516`, `:2517`, `:2520`,
     `:2521`, `:2525`, `:2526`, `:2529`, `:2530`, `:2532`, `:2533`, `:2536`,
     `:2537`, `:2540`, `:2541`, `:2543` — and it **passes**
     (`--test-filter "transaction can be opened at historical heads"`, 2026-10-01).
   What survives is only that `Clock.isolate` sets the isolated actor's slot to
   `maxInt` (`src/clock.zig:128`), which upstream's walk now guards.
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
     `Document.clockAtScope` (`src/doc.zig:5477`), upstream's
     `Automerge::clock_at` (`automerge.rs:1236-1247`). The unsuffixed readers
     resolve their clock through `Document.readScope`, which reads the
     *isolation*'s heads and nothing a caller names. Six of the new readers
     hand a **walk** back, and a walk copies the `Clock` by value and borrows
     only its `slots` (`src/doc.zig:2364-2380`), so the clock cannot be built
     and freed inside the call. `clockAtScope` **shares the document's one
     existing `read_scope` cache** rather than adding a second pair of fields,
     because both readers answer the same question with the same shape.
   - **What a historical read resolves its object id against is unchanged and
     is upstream's, not a port's choice.** `Document.resolve`
     (`src/doc.zig:4984`) is `exid_to_opid` (`automerge.rs:744-758`), which
     reads `self.ops` and takes no clock: the actor table is the whole
     document's, not a version of it, and a `Clock` is a per-actor vector of
     op counters that scopes *rows*. So "an id valid for the present may not be
     for those heads" does not hold for the id — what those heads can exclude
     is an object's rows. `src/read.zig`'s *Historical reads* section is the
     long form.
   - **One deviation, and it is deliberate**: the three cursor readers name the
     parameter `heads` where upstream names it `at` (`read.rs:203`, `:228`,
     `:241`), because `src/read.zig:2241` is a file-scope `fn at(id: OpId)` that
     the file's own fixtures call and a parameter may not shadow it. All
     fourteen read the same way now. **The same fold changed one error label**:
     `getCursorPosition` now answers `error.InvalidCursor` for a cursor naming a
     row of a different object, where it answered `error.InvalidIndex`
     unscoped, which is upstream's own `.ok_or_else(|| InvalidCursor(..))` on
     the seek's empty answer (`automerge.rs:1778-1781`) and is what the same
     cursor already answered with a clock.
3. **`ReadDoc::iter_at` / `DocIter` is not ported.** It is the recursive
   document walk, and `src/read.zig:52` records why: it is the adapter that
   feeds a document's `path_map` and `next_objs` (`iter/doc.rs:55-56`), so it
   belongs to the patch layer. The object walk it stands on —
   `iter/doc.zig`'s `ObjIdIter` — **is** ported and is all that walk needs.
4. **`Automerge::get_authors` (`automerge.rs:410`) is not ported.** The port
   has `getAuthor` (the one author) and `getActors` (every actor id); the
   `&[Author]` slice of every distinct author is not there.
5. **RESOLVED 2026-10-01 — removed from the list.** This gap said
   `src/hydrate.zig` owned the value types and the applier but that there was
   no entry point to produce one. **`read.hydrate` (`src/read.zig:772`) is
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
6. **No document-level `bundle`.** `src/storage/bundle.zig` reads and writes
   bundle chunks (`parse`, `Builder`) and interoperates with the reference, but
   `Automerge::bundle(hashes)` (`automerge.rs:1141`) — *take these hashes and
   give me a bundle* — is not there.
7. **RESOLVED 2026-10-01.** This gap said `UpdateSpansConfig` is not ported.
   It is `src/marks.zig:731`, and `transact.updateSpansWithConfig` /
   `Transaction.updateSpansWithConfig` thread it to the mark pass, which reads
   `per_mark_expands` then `default_expand` for each mark it writes and each
   mark it removes (`text_diff.rs:216-226`, `:229-245`). `transact.updateSpans`
   and `Transaction.updateSpans` are upstream's calls with
   `UpdateSpansConfig::default()`, so their signatures are unchanged.
8. **`AutoCommit::diff_cache` is not ported** — deliberately, and §Diffing says
   why.

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