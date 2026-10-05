# zautomerge API

This file states the supported native and C contracts of the Zig port.
See [PROJECT.md](PROJECT.md) for implementation status and [plan.md](docs/plan.md) for phase gates.

The reference is Automerge 0.12.0 at `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`.
The compiler line is Zig 0.16.0. These contracts describe the current working tree; correctness and performance evidence have separate scopes.
Source declarations do not prove compilation, runtime correctness, or performance.
Current verification limits are in [Known gaps](#known-gaps).
The [current STATUS checkpoint](docs/STATUS.md#latest-observed-checkpoint-2026-10-08) is authoritative for observed results.

## Conventions

- Port citations use a file and symbol. Rust citations use the pinned source's `path:line`.
  The [Rust surveys](docs/survey/README.md) record the reference surface.
- Owners retain their allocator where later growth or disposal needs it.
  Output-only readers accept a caller allocator. Release each output with its specified allocator.
  `Keys.deinit` uses the document allocator.
- `Document.init(gpa, io)` and `initWithEncoding(gpa, io, encoding)` return `InitError`.
  This is exactly `Allocator.Error || std.Io.RandomSecureError`.
  `Document.load(gpa, io, bytes, encoding)` returns the larger `LoadError`.
  `AutoCommit` constructors use the same raw constructors and loader.
- A document retains a borrowed `std.Io`. Its provider and allocator must outlive the document.
  Clone, fork, load-into, and author changes use this retained capability.
  Tests supply `std.testing.io`. Executables supply their live capability.
- A fresh actor uses 16 secure random bytes.
  `ActorId.random(gpa, io)` frees partial output on `Canceled` or `EntropyUnavailable`.
  It has no weaker fallback. Rust panics on entropy refusal (`types.rs:63-68`).
  `Document.setActorId` draws nothing and supplies deterministic fixture identities.
- Named error unions belong to their entry points: `ReadError`, `ChangeError`, `HydrateError`,
  `WriteError`, `TransactionError`, `InitError`, `LoadError`, `DocumentError`, `DiffError`,
  `MakeError`, `ProtocolError`, and `AnonymizeError`.
  A parser must return typed errors on untrusted input, not panic or loop.
- Borrowed document payloads must not survive mutation or teardown.
  Owned outputs survive both. Assignment of an owner transfers its cleanup duty. It does not clone storage.
- Historical reads take explicit heads. Nullable heads normally select the owner's current read scope.
  `hydrate(null)` is the exception: it reads raw current rows without an isolation or transaction clock.
  Explicit historical heads exclude pending operations, even when they equal the committed graph heads.
  Historical clock storage remains stable across other reads until mutation invalidates it.
- `read.ReadDoc(R)` is a compile-time adapter for `Document`, `Transaction`, and `AutoCommit`.
  It borrows its owner and uses no runtime vtable.
  Ordinary `AutoCommit` readers do not commit pending work.
- `TextEncoding.platformDefault()` follows the declared compile-time indexing option.
  Without an option, it selects `unicode_code_point`. It does not infer an encoding from the operating system.
- `version` is the package manifest version, currently `0.0.0`.
  `upstream_version` is the separate compatibility target, `0.12.0`.
  `Stats` reports `package_name`, `package_version`, and the actual Zig `compiler_version`.
- `root` is the root object id, matching `automerge::ROOT`.

```zig
pub const root: ExId = .root;                      // src/root.zig
```

## Types

| Rust | Zig | Where | Notes |
| --- | --- | --- | --- |
| `ExId` / `ObjId` | `ExId`, root alias `ObjId` | `src/types.zig` | `root`, resident `id: OpId`, or `named: Named`. Named identity carries a `u64` counter, actor bytes, and a `u32` cached actor hint. |
| `ActorId` | `ActorId` | `src/types.zig` | Arbitrary bytes. `init` borrows. `initCopy`, `random`, `fromHex`, and `withConcurrency` own bytes freed with their allocator. Document-returned bytes borrow the document. |
| `Author` | `Author` | `src/types.zig` | Arbitrary bytes, not UTF-8. `init` borrows. `initCopy`, `dup`, and `fromHex` own bytes released by `deinitOwned(gpa)`. |
| `OpId`, `ElemId` | `OpId`, `ElemId` | `src/types.zig` | Resident counters and actor indices are `u32`. `ElemId` distinguishes the sequence head. Public wide identifiers do not widen resident storage. |
| `ObjType` | `ObjType` | `src/types.zig` | `map`, `table`, `list`, `text`. `table` retains the reference's legacy map meaning (`types.rs:171-181`). |
| `Prop` | `Prop` | `src/types.zig` | `key: []const u8` or `index: usize`. |
| `TextEncoding` | `TextEncoding` | `src/types.zig` | `unicode_code_point`, `utf8_code_unit`, `utf16_code_unit`, `grapheme_cluster`. |
| `ScalarValue` | `ScalarValue` | `src/value.zig` | Flat scalar tags. Byte-bearing payloads borrow unless an owned constructor says otherwise. |
| `Value` | `Value` | `src/value.zig` | `scalar: ScalarValue` or `object: ObjType`, not an object identifier. |
| `ScalarValueRef`, `ValueRef` | Root exports | `src/value.zig`, `src/opset/types.zig` | Borrowed op-set values with allocator-taking owned conversions. |
| `Change` | `Change`, owned `doc.Built` | `src/change.zig`, `src/doc.zig` | Root `Change` is a header over borrowed body bytes. `Built` owns its body and header allocation. `Changes.deinit(gpa)` frees its items. |
| `ExpandedChange`, `ExpandedOp`, `ExpandedOpId` | Root exports | `src/change.zig` | Structured operations and stable identities. `Change.decode(gpa)` returns independent owned storage. |
| `ChangeHash` | `ChangeHash` | `src/types.zig` | Wrapper with `bytes: [32]u8`, SHA-256. |
| `Mark`, `MarkSet` | `Mark`, `MarkSet` | `src/marks.zig` | Owned and borrowed mark views have distinct cleanup and lifetime rules. |
| `Span` | `iter.spans.Span` | `src/iter/spans.zig` | Owned text, marks, or complete `hydrate.Map` block payload. `SpanInput` is the borrowed writer input. |
| `Cursor` | `cursor.Cursor` | `src/cursor.zig` | Wire counters are `u64`. Resolution checks resident capacity and returns `InvalidCursor` for an unrepresentable counter. |
| `Patch`, `PatchAction`, `Patches` | `patches` namespace | `src/patches.zig` | Ordered actions. `Patches` owns every returned path, identity, scalar, mark, and native text tree. |
| `Stats` | `Stats` | `src/doc.zig` | Three document counters plus package and Zig compiler provenance. |
| `Automerge`, `AutoCommit`, `Transaction` | `doc.Document`, root `AutoCommit`, root `Transaction` | `src/doc.zig`, `src/autocommit.zig`, `src/transaction.zig` | Separate raw, automatic, and borrowed transaction owners. `transaction` is the manual transaction namespace. |

`ExId.parse`, `fromBytes`, and `dup` own named actor bytes. Release them with `deinitOwned(gpa)`.
`counter()` preserves the public `u64`. `opId()` returns `null` when a counter cannot fit resident `u32` storage.
Named equality and hashing use actor bytes and the counter, not the cached hint.
Stable string and JSON identifiers use `_root` or `counter@hex-actor`.
The versioned byte codec retains the checked `u32` hint and full `u64` counter (`exid.rs:24-123`).
Unresolved resident IDs cannot fabricate stable actor bytes.

`ActorId`, `Author`, and `ChangeHash` provide hex, formatting, and JSON codecs.
Their JSON parser outputs use the parser allocator. A `std.json.Parsed` owner releases its arena.
Do not separately free arena views.
`ScalarValue` and `Value` provide constructors, type checks, conversions, formatting, and owned extraction.
Unsigned-to-signed numeric conversion wraps as the reference does.
`OwnedScalarValue.deinit(gpa)` and `value.OwnedValue.deinit(gpa)` release copied scalar storage.

`Value.map`, `table`, `list`, and `text` construct object-kind values.
`from`, `str`, `int`, `uint`, `float`, `counter`, `timestamp`, and `bytes` construct borrowed scalar values.
`fromCodepoint(gpa, cp)` returns owned UTF-8 and rejects an invalid scalar with `InvalidCharacter`.
Both public value types expose exact-tag checks and `asBytes`, `asStr`, `asI64`, `asU64`, `asF64`, and `asBool`.
`Value.asObject` and `asScalar` return optional borrowed payloads.
`intoScalar`, `intoBytes`, `intoString`, and `intoOwned` copy output and reject the wrong kind with `InvalidValueType`.
Scalar `dup(gpa)` requires `deinitOwned(gpa)`; `intoOwned(gpa)` instead returns the explicit wrapper.
Scalar `asDatatype` checks requested counter/timestamp bounds. It does not wrap an out-of-range unsigned input.
`asI64OrDefault` returns zero for float or nonnumeric tags.
Scalar JSON codecs use the reference's untagged JSON policy. Display formatting remains a separate contract.

## Hexane packing

The low-level codec modules are root-reachable as `zautomerge.hexane`.
Their default factories remain `rle.Rle(T)`, `rle.RleOption(T)`,
`rle.RleUtf8(Nullable)`, `bool_codec.Bool`, and `delta.Delta(T)`.
They use `rle.Leb128`, which names `src/leb128.zig` without a forwarding copy.

Explicit packing seams are `rle.RleWith(P, T, Nullable, Utf8)`,
`bool_codec.BoolWith(P)`, `delta.DeltaWith(P, T)`,
`rle.payloadReadWith(P, T, bytes, pos)`, and
`rle.payloadAppendWith(P, gpa, out, T, value)`. `P` is a comptime type.
It must match the required signed/unsigned read, write, append, size, and
maximum-size declarations in `src/leb128.zig`. Reads must consume a positive,
in-bounds byte count and use the same `ParseError` contract.
The same packing must encode headers, counts, lengths, and value payloads.

`slab.rewrite_lit_header` now requires `P` as its first argument:
`rewrite_lit_header(P, gpa, buf, header_pos, total)`.
Default-wire callers pass `rle.Leb128`; alternate-wire callers pass their codec's
packing. There is no old-signature alias.

These seams do not select a different Automerge document format.
Only LEB128 ships for document storage. The private BeLen provider is test-only;
the five upstream alternate-packing cases use it to exercise the entire path.

## Read

`src/read.zig` supplies generic free readers and `ReadDoc(R)`.
The public owners are `Document`, `Transaction`, and `AutoCommit`.
Serialize all access. A const receiver can still update shared scratch or caches.

These signature fragments use module-local type names.
`doc: anytype` must be a supported owner pointer.
Methods on `Transaction` and `AutoCommit` omit that first argument.

```zig
pub fn get(doc: anytype, obj: ExId, prop: Prop) ReadError!?DocItem;
pub fn getAt(doc: anytype, obj: ExId, prop: Prop, heads: []const ChangeHash) ReadError!?DocItem;
pub fn getAll(doc: anytype, obj: ExId, prop: Prop, gpa: Allocator) ReadError![]DocItem;
pub fn getAllAt(doc: anytype, obj: ExId, prop: Prop, heads: []const ChangeHash, gpa: Allocator) ReadError![]DocItem;
pub fn hydrate(doc: anytype, obj: ExId, heads: ?[]const ChangeHash, gpa: Allocator) HydrateError!hydrate.Value;
pub fn objectType(doc: anytype, obj: ExId) Error!ObjType;
pub fn length(doc: anytype, obj: ExId) ReadError!usize;
pub fn lengthAt(doc: anytype, obj: ExId, heads: []const ChangeHash) ReadError!usize;
pub fn text(doc: anytype, obj: ExId, gpa: Allocator) ReadError![]u8;
pub fn textAt(doc: anytype, obj: ExId, heads: []const ChangeHash, gpa: Allocator) ReadError![]u8;
pub fn keys(doc: anytype, obj: ExId) ReadError!Keys;
pub fn keysAt(doc: anytype, obj: ExId, heads: []const ChangeHash) ReadError!Keys;
pub fn values(doc: anytype, obj: ExId, term: *ValueTerm) ReadError!Values;
pub fn valuesAt(doc: anytype, obj: ExId, heads: []const ChangeHash, term: *ValueTerm) ReadError!Values;
pub fn spans(doc: anytype, obj: ExId, gpa: Allocator) ReadError!Spans;
pub fn spansAt(doc: anytype, obj: ExId, heads: []const ChangeHash, gpa: Allocator) ReadError!Spans;
pub fn marks(doc: anytype, obj: ExId, gpa: Allocator) ReadError![]Mark;
pub fn marksAt(doc: anytype, obj: ExId, heads: []const ChangeHash, gpa: Allocator) ReadError![]Mark;
pub fn getMarks(doc: anytype, obj: ExId, from: usize, max: usize, gpa: Allocator) ReadError![]Mark;
pub fn markSetAtIndex(doc: anytype, obj: ExId, index: usize, heads: ?[]const ChangeHash, gpa: Allocator) ReadError!MarkSet;
pub fn parents(doc: anytype, obj: ExId) ReadError!Parents;
pub fn parentsAt(doc: anytype, obj: ExId, heads: []const ChangeHash) ReadError!Parents;
pub fn iter(doc: anytype, gpa: Allocator) DiffError!DocIter;
pub fn iterAt(doc: anytype, obj: ExId, heads: ?[]const ChangeHash, gpa: Allocator) DiffError!DocIter;
pub fn getCursor(doc: anytype, obj: ExId, pos: CursorPosition, heads: ?[]const ChangeHash, gpa: Allocator) ReadError!Cursor;
pub fn getCursorMoving(doc: anytype, obj: ExId, pos: CursorPosition, heads: ?[]const ChangeHash, bias: Bias, gpa: Allocator) ReadError!Cursor;
pub fn getCursorPosition(doc: anytype, obj: ExId, cursor: Cursor, heads: ?[]const ChangeHash) ReadError!usize;
pub fn getMissingDeps(doc: anytype, heads: []const ChangeHash, gpa: Allocator) Error![]ChangeHash;
pub fn getChangeByHash(doc: anytype, hash: ChangeHash, gpa: Allocator) ChangeError!?zautomerge.doc.Built;
pub fn stats(doc: anytype) Stats;
pub fn textEncoding(doc: anytype) TextEncoding;
pub fn mapRange(doc: anytype, obj: ExId, range: KeyRange) ReadError!MapRange;
pub fn mapRangeAt(doc: anytype, obj: ExId, range: KeyRange, heads: []const ChangeHash) ReadError!MapRange;
pub fn listRange(doc: anytype, obj: ExId, range: IndexRange) ReadError!ListRange;
pub fn listRangeAt(doc: anytype, obj: ExId, range: IndexRange, heads: []const ChangeHash) ReadError!ListRange;
```

`getAtScope`, `markSetAtScope`, and `getCursorPositionFor` remain raw-document helpers with explicit `?Clock` arguments.
`ValueTerm` is caller-held query scratch. Two `Values` walks must not share it.
`Bias` names `cursor.MoveCursor`.

### Scopes and lifetimes

The eleven `At` readers select committed historical rows (`read.rs:40-298`).
Cursor methods carry nullable heads directly (`read.rs:199-242`).
An explicit empty head set selects empty history, not the present.
Explicit heads exclude pending operations, even when they equal committed graph heads.
Transactions include pending rows in ordinary scoped reads.
`hydrate(null)` instead reads raw current rows, matching Rust (`automerge.rs:2222-2234`, `transaction.rs:228`, `autocommit.rs:1011`).

`Document.clockAtScope` retains independent heap-backed historical clocks.
Selecting another head set does not free a clock that an existing walk borrows.
Mutation, actor remapping, isolation changes, or teardown invalidate these borrows.
Shared iterator scratch still restricts overlapping walks.
Do not mutate a document while a borrowed walk is live.

`DocItem` carries a borrowed `ValueRef` and identity.
`getAll` owns its outer array, not every payload inside it.
`text` and `textAt` return owned UTF-8 buffers. Free them with the reader allocator.
`marks` and `marksAt` own their run array. Ordinary names and scalar payloads retain document borrows.
`MarkSet.deinit()` releases set storage. Borrowed names still require the document.
`MarkSet.dup(gpa)` gives an independent owned copy.

`MapRangeItem.intoOwned(gpa)` and `ListRangeItem.intoOwned(gpa)` copy keys, scalar payloads, and identity actor bytes.
Their owned result types release all copied storage with `deinit(gpa)`.
`DocObjItem.valueOwned(gpa)` copies only its value payload into `OwnedValueRef`.
That value survives item and document disposal and uses `deinit(gpa)`.
It does not detach the complete item, its object identity, or a map key.
Keep those item borrows live separately, or explicitly copy the identity and key.
`Keys.nextOwned(gpa)` copies each result. Free that result with `gpa`.
A failed copy consumes that step but returns no owned storage.

`DiffIter.next` text items own their text buffer. Other low-level walk fields can borrow the document.
`DiffIter.log` consumes text items and moves its `PathMap` out.
Transfer that map to `PatchLog.pathHint` or release it with its own allocator.

`Spans.deinit()` releases the walk, not previously returned spans.
Each `Span.deinit(gpa)` releases text, owned mark names and values, or the complete block map.
Returned spans survive walk disposal, document mutation, and document teardown.
`Span.dup(gpa)` makes another independent owner.

`hydrate` returns an independent object tree. Release it with `hydrate.Value.deinit()`.
Scalar literals remain borrowed until owned conversion or container insertion copies them.
`hydrate.OwnedValue` has `value`, `gpa`, and `deinit()` with no allocator argument.
It differs from `value.OwnedValue`, whose `deinit` takes `gpa`.

`getCursorPosition` returns `InvalidCursor` for another object's cursor or a counter outside resident capacity.
`getCursor` retains `InvalidIndex` for an invalid requested position.

### Ranges

`IndexRange { start: usize, end: ?usize }` is half-open.
A null end means the end of the object. An inverted range yields no items.
`KeyRange { start: ?KeyBound, end: ?KeyBound }` supports included, excluded, and unbounded ends.
`KeyBound` carries `included: []const u8` or `excluded: []const u8`.
`between(begin, end)` is half-open. `through(begin, end)` is closed. Both range types offer `all()`.
This expresses Rust's range bounds without its trait (`iter/list_range.rs:359-372`, `read.rs:99-123`).

## Write

Writes are methods on `Transaction` or `AutoCommit`.
The automatic owner holds the same transaction engine across calls.
A raw `Document` requires an explicit transaction. It has no per-call automatic writer route.
The root `transaction` namespace owns commit types, closure helpers, and `OwnedTransaction`.

These signature fragments use `Transaction` as receiver.
`AutoCommit` exposes the same writer arguments and results.
Each writer uses the owner's retained allocator.

```zig
pub fn put(self: *Transaction, obj: ExId, prop: Prop, value: ScalarValue) WriteError!?OpId;
pub fn putObject(self: *Transaction, obj: ExId, prop: Prop, t: ObjType) WriteError!ExId;
pub fn insert(self: *Transaction, obj: ExId, index: usize, value: ScalarValue) WriteError!OpId;
pub fn insertObject(self: *Transaction, obj: ExId, index: usize, t: ObjType) WriteError!ExId;
pub fn increment(self: *Transaction, obj: ExId, prop: Prop, by: i64) WriteError!void;
pub fn delete(self: *Transaction, obj: ExId, prop: Prop) WriteError!usize;
pub fn splice(self: *Transaction, obj: ExId, pos: usize, del: isize, values: []const hydrate.Value) WriteError!void;
pub fn spliceText(self: *Transaction, obj: ExId, index: usize, del: isize, text: []const u8) WriteError!void;
pub fn mark(self: *Transaction, obj: ExId, from: usize, to: usize, name: []const u8, expand: ExpandMark, value: ?ScalarValue) WriteError!void;
pub fn unmark(self: *Transaction, obj: ExId, from: usize, to: usize, expand: ExpandMark, name: []const u8, value: ?ScalarValue) WriteError!void;
pub fn splitBlock(self: *Transaction, obj: ExId, index: usize) WriteError!ExId;
pub fn joinBlock(self: *Transaction, text: ExId, index: usize) WriteError!void;
pub fn replaceBlock(self: *Transaction, text: ExId, index: usize) WriteError!ExId;
pub fn updateText(self: *Transaction, obj: ExId, new_text: []const u8) WriteError!void;
pub fn updateObject(self: *Transaction, obj: ExId, value: *const hydrate.Value) WriteError!void;
pub fn updateSpans(self: *Transaction, obj: ExId, spans: []const SpanInput) WriteError!void;
pub fn updateSpansWithConfig(self: *Transaction, obj: ExId, config: *const UpdateSpansConfig, spans: []const SpanInput) WriteError!void;
pub fn batchCreateObject(self: *Transaction, obj: ExId, prop: Prop, t: ObjType) WriteError!ExId;
pub fn batchCreateValue(self: *Transaction, obj: ExId, prop: Prop, value: hydrate.Value, as_insert: bool) WriteError!ExId;
pub fn initRootFromHydrate(self: *Transaction, value: *const hydrate.Map) WriteError!void;
```

`put` returns `null` when the write creates no operation.
`delete` returns the number of delete operations, not a text width.
These results differ from Rust's unit results (`transactable.rs:21,75`).
`mark` decomposes Rust's `Mark` argument. `unmark(..., null)` removes the named mark.
A non-null unmark value applies that value instead.
These argument shapes are deliberate deviations (`transactable.rs:103-117`).

`updateObject` dispatches full map, list, or text values and returns `ChangeType` for incompatible kinds.
`updateMapValue`, `updateListValue`, and `updateTextValue` remain typed transaction helpers.
`batchCreateValue` covers Rust's hydrated `batch_create_object` (`transactable.rs:196-202`).
`batchCreateObject` is the port's object-kind convenience.

`SpanInput.block` borrows `*const hydrate.Map`.
`SpanInput.text` borrows `text: []const u8` and optional `marks: ?*const MarkSet`.
Inputs need remain live only through the call. Writers retain deep-owned block and mark payloads.
A block input is not a template object ID.
`updateSpans` uses default configuration.
`updateSpansWithConfig` uses `per_mark_expands` before `default_expand` (`marks.rs:466-486`, `text_diff.rs:216-245`).

### The manual door

`Transaction` borrows one raw document. Keep the document at its address until the transaction closes.
Do not mutate it through another entry point while the transaction owns its journal.

```zig
pub fn open(gpa: Allocator, doc: *Document) WriteError!Transaction;
pub fn openAt(gpa: Allocator, doc: *Document, heads: ?[]const ChangeHash) WriteError!Transaction;
pub fn openWithPatchLog(gpa: Allocator, doc: *Document, log: *PatchLog, heads: ?[]const ChangeHash) WriteError!Transaction;
pub fn deinit(self: *Transaction) WriteError!void;
pub fn deinitClosed(self: *Transaction) void;
pub fn commit(self: *Transaction) WriteError!transaction.CommitResult;
pub fn commitWith(self: *Transaction, options: transaction.CommitOptions) WriteError!transaction.CommitResult;
pub fn rollback(self: *Transaction) WriteError!usize;
pub fn count(self: *const Transaction) usize;
pub fn baseHeads(self: *const Transaction) []const ChangeHash;
pub fn nextId(self: *const Transaction) OpId;
pub fn scopeClock(self: *Transaction) read.ReadError!?Clock;
pub fn takePatchLog(self: *Transaction) PatchLog;
pub fn textFor(self: *Transaction, obj: ExId) WriteError![]const u8;
pub fn blockAt(self: *Transaction, obj: ExId, index: usize) WriteError!?ExId;
```

`open` and `openAt` use an inactive log.
`openWithPatchLog` consumes `*log` only after successful opening.
Actor-table incompatibility or allocation refusal preserves the caller's log and document.
Explicit heads select historical transaction scope. The transaction owns its dependency array.
`baseHeads` borrows that array until disposal.
`textFor` borrows transaction-owned text until the next successful `textFor` or disposal.
Failure preserves its previous buffer.

`CommitOptions` has `message: ?[]const u8` and `time: ?i64`, both defaulting to null.
The message is borrowed through commit. Time is signed Unix seconds.
Null time uses the transaction timestamp, which defaults to zero, not the current time.
`CommitResult` has `hash: ?ChangeHash` and an owned `patch_log`.
Release it once with `CommitResult.deinit(gpa)`, including a no-write result whose hash is null.
`takePatchLog` requires a closed transaction.

Commit refusal leaves the transaction open for retry or rollback.
History publication stages fallible work before publishing a complete graph node.
Capacity growth may remain after refusal. A refused commit must not publish a partial change.
Producer refusal after partial row publication makes that journal rollback-only.
Validation refusal before publication does not close it.

Rollback is resumable, not atomic or idempotent.
It removes completed undo records and returns the total cancelled count.
On refusal, retain the journal and retry. Do not inspect rows before recovery completes.
Writes and commit refuse while rollback is in progress.
`Transaction.deinit()` attempts rollback and can refuse. Refusal retains the owner.
`deinitClosed()` only releases a closed journal, or one whose entire owning document immediately dies.
It must not abandon unfinished rows in a live document.
`transaction.abort(tx)` is the idempotent explicit rollback helper.

### Closure results and recovery

`enclose(O, gpa, doc, ctx, body)` and `encloseWith(O, gpa, doc, ctx, body, options)`
accept a callback `fn(ctx, *Transaction) E!O`.
`encloseWithPatchLog(O, gpa, doc, log, ctx, body, options)` uses the logged constructor.
Opening errors return directly without invoking the body.
The result is `TransactionError!Outcome(O, E)`, not a fixed callback error set.

| Result | Fields and ownership |
| --- | --- |
| `Success(O)` | `result: O`, `hash: ?ChangeHash`, owned `patch_log: PatchLog`. Dispose the callback result as its type requires and release the log once. |
| `Failure(O, E)` | Primary `err: E || TransactionError`, total `cancelled`, optional `rollback_error`, optional recovery `transaction`, optional retained `result`, and `patch_log`. |
| `Outcome(O, E)` | Tagged union `success` or `failure`. A successful body value survives a later commit refusal in `failure.result`. |

A rollback refusal never replaces the primary error.
When `failure.transaction` is present, that transaction owns the real log.
The separate failure log is inactive. Otherwise `failure.patch_log` owns the returned log.
Retry and dispose the recovery transaction exactly once before accessing the raw document again.

Callbacks run synchronously on the calling thread without document reentrancy.
The options callback receives `*const O`, not a copied result.
Do not retain callback transaction or result pointers.
Returned message bytes must remain live until commit returns.
A null options callback selects `CommitOptions.none`.

`transaction.actorId`, `maxOp`, `heads`, `hashForOpid`, `depIndices`, `changeMeta`, and `authorFooter`
remain explicit metadata helpers.
`heads(gpa, tx)` copies full committed document heads. It is not the transaction's borrowed `baseHeads`.
`maxOp` and `changeMeta` return `InvalidOp` after commit or rollback.
`authorFooter(gpa, tx)` returns owned bytes, present only for the actor's first authored change.

### An owned transaction

`OwnedTransaction` embeds `document` and the same `transaction` journal.
Initialize it at its final address with `init(self, gpa, doc: *Document, heads)`.
`initWithPatchLog(self, gpa, doc, log, heads)` consumes both source owners only on successful opening.
Do not copy or move it while open. Read and write through its `transaction` field.

`commit(options)` returns `Committed { document: Document, result: CommitResult }`.
`rollback()` returns `RolledBack { document: Document, cancelled: usize, patch_log: PatchLog }`.
Both transfer terminal owners only on success. Refusal retains recovery state.
`deinit()` rolls back before document disposal and can refuse.
`deinitClosed()` destroys the entire owned document and journal, or does nothing after terminal transfer.

## Document

`src/doc.zig` owns the mode-less raw `Document`.
`src/autocommit.zig` owns the separate automatic facade.
Neither constructor requires a lifecycle flag.
These signature fragments use module-local names and list raw document methods.

```zig
pub const Document = struct { ... };

// These public owned types live in zautomerge.doc, not zautomerge.change_record.
pub const ChangeMetadata = struct {
    actor: ActorId,
    author: ?[]const u8,
    seq: u64,
    start_op: u64,
    max_op: u64,
    timestamp: i64,
    message: ?[]const u8,
    deps: []const ChangeHash,
    hash: ChangeHash,
    extra: []const u8,
    pub fn deinit(self: *ChangeMetadata, gpa: Allocator) void;
};
pub const ChangeMetas = struct {
    items: std.ArrayList(ChangeMetadata),
    pub fn deinit(self: *ChangeMetas, gpa: Allocator) void;
};

pub fn init(gpa: Allocator, io: std.Io) InitError!Document;
pub fn initWithEncoding(gpa: Allocator, io: std.Io, encoding: TextEncoding) InitError!Document;
pub fn load(gpa: Allocator, io: std.Io, bytes: []const u8, encoding: TextEncoding) LoadError!Document;
pub fn loadWithOptions(gpa: Allocator, io: std.Io, bytes: []const u8, options: LoadOptions) LoadError!Document;
pub fn loadUnverifiedHeads(gpa: Allocator, io: std.Io, bytes: []const u8, options: LoadOptions) LoadError!Document;
pub fn rescue(gpa: Allocator, io: std.Io, bytes: []const u8) LoadError!hydrate.OwnedValue;

// Everything below is a method on `Document`, except where noted.
pub fn deinit(self: *Document) void;
pub fn allocator(self: *const Document) Allocator;
pub fn loadInto(self: *Document, gpa: Allocator, bytes: []const u8, encoding: TextEncoding) LoadError!void;
pub fn loadIntoWithOptions(self: *Document, gpa: Allocator, bytes: []const u8, options: LoadOptions) LoadError!void;
pub fn loadIncremental(self: *Document, gpa: Allocator, bytes: []const u8) LoadError!usize;
pub fn loadIncrementalWithPatchLog(self: *Document, gpa: Allocator, bytes: []const u8, log: *PatchLog) LoadError!usize;
pub fn save(self: *Document, gpa: Allocator) LoadError![]u8;
pub fn saveWithOptions(self: *Document, gpa: Allocator, options: SaveOptions) LoadError![]u8;
pub fn saveAfter(self: *Document, gpa: Allocator, heads: []const ChangeHash) LoadError![]u8;
pub fn saveIncremental(self: *Document, gpa: Allocator) LoadError![]u8;
pub fn applyChanges(self: *Document, gpa: Allocator, incoming: []const Change) LoadError!usize;
pub fn applyChangesWithPatchLog(self: *Document, gpa: Allocator, incoming: []const Change, log: *PatchLog) LoadError!usize;
pub fn getHeads(self: *const Document, gpa: Allocator) Error![]ChangeHash;
pub fn hasChange(self: *const Document, hash: ChangeHash) bool;
pub fn getMissingDeps(self: *const Document, gpa: Allocator, heads: []const ChangeHash) Error![]ChangeHash;
pub fn getChanges(self: *Document, gpa: Allocator, have: []const ChangeHash) DocumentError!Changes;
pub fn getChangesByHashes(self: *Document, gpa: Allocator, hashes: []const ChangeHash) DocumentError!Changes;
pub fn getChangesAdded(self: *Document, gpa: Allocator, other: *Document) DocumentError!Changes;
pub fn getLastLocalChange(self: *Document, gpa: Allocator) DocumentError!?Built;
pub fn getChangeByHash(self: *Document, gpa: Allocator, hash: ChangeHash) DocumentError!?Built;
pub fn getChangesMeta(self: *const Document, gpa: Allocator, have: []const ChangeHash) Error!ChangeMetas;
pub fn getChangeMetaByHash(self: *const Document, gpa: Allocator, hash: ChangeHash) Error!?ChangeMetadata;
pub fn hashForOpid(self: *const Document, id: ExId) ?ChangeHash;
pub fn merge(self: *Document, gpa: Allocator, other: *Document) DocumentError![]ChangeHash;
pub fn mergeWithPatchLog(self: *Document, gpa: Allocator, other: *Document, log: *PatchLog) DocumentError![]ChangeHash;
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
pub fn forkAt(self: *Document, gpa: Allocator, heads: []const ChangeHash) LoadError!Document;
pub fn fork(self: *Document, gpa: Allocator) LoadError!Document;
pub fn clone(self: *Document, gpa: Allocator) LoadError!Document;
pub fn isolate(self: *Document, gpa: Allocator, heads: []const ChangeHash) DiffError!void;
pub fn integrate(self: *Document) DiffError!void;
pub fn dropIsolation(self: *Document) void;
pub fn isolationHeads(self: *const Document) ?[]const ChangeHash;
pub fn readScope(self: *Document, gpa: Allocator) Error!?*const Clock;
pub fn clockAtScope(self: *Document, gpa: Allocator, heads: []const ChangeHash) Error!*const Clock;
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
pub fn hasOurChanges(self: *const Document, state: *const sync.state.State) bool;
pub fn initFromHydrate(self: *Document, gpa: Allocator, map: *const hydrate.Map) transaction.TransactionError!transaction.Outcome(void, transaction.TransactionError);
pub fn importObj(self: *const Document, gpa: Allocator, spelling: []const u8) DocumentError!ExId;
pub fn import(self: *const Document, gpa: Allocator, spelling: []const u8) DocumentError!ImportedObject;
pub fn dump(self: *const Document, gpa: Allocator, writer: *std.Io.Writer) (ParseError || std.Io.Writer.Error)!void;
pub fn diffOpSet(self: *const Document, gpa: Allocator, other: *const Document, writer: *std.Io.Writer) (ParseError || std.Io.Writer.Error)!void;

// The diff surface is in §Diffing. The free function below is not a method.
pub fn anonymize(gpa: Allocator, document: *Document, seed: [32]u8) AnonymizeError!Document;  // src/anonymize.zig
```

### Loading and replacement

`LoadOptions` is a value with these public defaults:

| Field | Default and meaning |
| --- | --- |
| `on_partial_load` | `.refuse`. `.ignore` discards every decoded tail change after a partial decode. It retains the first document snapshot, or an empty document for a change-first stream. |
| `verification_mode` | `.check`. `.dont_check` skips only stored-versus-derived head equality. Checksums, framing, and columns still require validation. |
| `string_migration` | `.no_migration`. `.convert_to_text` migrates visible scalar strings in maps and lists before assigning the supplied author. |
| `patch_log` | `null`, no caller log. A non-null `*PatchLog` is borrowed, never consumed by loading. |
| `text_encoding` | `TextEncoding.platformDefault()`. Encoding is not stored in the document file. |
| `author` | `null`. Non-null author bytes are copied into the new owner. They need not be UTF-8. |

`loadUnverifiedHeads` forces `.dont_check`.
Unknown stored heads can remain visible. This is a damaged-metadata inspection route, not a saveability guarantee.
`loadIntoWithOptions` replaces its document only after successful preparation.
On refusal, the old document remains owned and unchanged.
`OutOfMemory` is never a partial-load policy success.
`loadIncremental` on a nonempty document applies a fully decoded prefix and ignores a malformed tail.
Allocation and application failures remain errors. This differs from full-load `.ignore` tail disposal.
Reference policy: `automerge.rs:74-183,833-999,1027-1069`.

`rescue` relaxes only mark-order validation and returns an owned current value, not the original history.
Call `hydrate.OwnedValue.deinit()` once.
Strict parser rejection alone does not prove rescue success (`automerge.rs:897-903`).

Snapshot loads require canonical physical operation order, including byte-lexical map keys and contiguous registers.
`loadUnverifiedHeads` and `rescue` do not bypass this check.
Invalid order returns `ParseError.InvalidValue`, even when reconstructed history hashes match.

### Incoming changes and external logs

`applyChanges`, incremental loading, and merge can retain a valid published prefix on allocation refusal.
Do not infer whole-batch atomicity from an error union.
Each published history node must retain its exact operation interval, author association, and opaque footer.
Passing current complete roots and a bounded static audit do not prove every incoming-change or allocation-refusal state. See [Known gaps](#known-gaps) for proof scope.

The `WithPatchLog` variants borrow the caller's log only through the operation.
They preflight Rust's sorted insertion/prefix actor-table compatibility before incoming mutation.
A log from another document is valid when that actor-table comparison permits it.
Private document identity is not a public rejection criterion.
Compatible insertions remap indexed events; an old trailing actor suffix can remain when the target table is shorter.
`PatchLogMismatch` rejects an incompatible actor order and retains the caller's log unchanged.
`validateActors(actors)` allocates nothing and changes no log state.
`migrateActors(actors)` stages copied actor bytes and index remapping; mismatch or allocation refusal leaves the log unchanged.
This differs from `Transaction.openWithPatchLog`, which transfers the log on successful opening.

### History change batches

`getChanges` selects committed changes outside `have` and its dependencies, with dependencies before dependents (`automerge.rs:1512-1514`).
`getChangeByHash` returns null for an absent hash, otherwise an owned `Built` (`automerge.rs:2294-2298`).
Neither contract changes for batched lookup.

`Document.getChangesByHashes(gpa, hashes)` returns one `Built` per requested occurrence, in exact request order.
It preserves repeated hashes and empty changes. Request order need not be dependency order.
An empty request returns an empty owned `Changes`.
An unknown explicit batch hash returns `error.MissingDeps`, not null or a shortened result.
Reconstruction and allocation errors release partial output without changing committed history.
Source contract: `src/doc.zig` `Document.getChangesByHashes`, `ChangeCollector::for_hashes` (`op_set2/change/collector.rs:724-734`).

Each occurrence owns its body and actor-table allocation, including repeated hashes and empty changes.
The returned data borrows neither the document nor the request and survives document mutation or disposal.
Release the collection once with `Changes.deinit(gpa)`, using the reader's allocator.
Do not separately free items that remain in the collection.
For early release, remove one `Built` from the collection, then call its `deinit(gpa)`.
Releasing that occurrence does not invalidate the others (`src/doc.zig` `Built`, `Changes`, `Document.getChangesByHashes`).

Reconstruction uses authoritative operation rows and actual successor edges to recover predecessors and deletions (`op_set2/change/collector.rs:791-793,839-850`).
`Change.withOpCount` restores `max_op` from the operation count, including `start_op - 1` for empty changes.
It does not change encoded bytes or hashes (`src/doc.zig` `encodeOneChange`, `change.rs:30-46,74-76`, `automerge.rs:693-697`).
The mutable reader reuses shared successor scratch and invalidates outstanding borrowed successor views.
These scratch views are ephemeral borrows, not returned ownership (`src/doc.zig` `Document.getChangesByHashes`).

This raw-document helper supports protocol batched lookup corresponding to Rust's crate-private `get_change_payloads`.
The protocol chooses the V2 whole-document branch before batch reconstruction (`src/sync/protocol.zig` `buildPayload`, `sync.rs:221-231`).
It adds no `AutoCommit` method, close barrier, or compatibility shim.

### Metadata, authors, imports, and diagnostics

`doc.ChangeMetadata` owns `actor.bytes`, `author`, `message`, `deps`, and `extra`.
Release a standalone value with `deinit(gpa)` or a collection with `ChangeMetas.deinit(gpa)`.
Do not separately free collection items.
`timestamp` is signed Unix seconds. Operation intervals are inclusive.
An empty change has `max_op = start_op - 1`. Empty encoded messages return null.

Document metadata can inherit the actor's author association (`change/collector.rs:693-720`).
`Change.author(gpa)` instead reads only that individual change's footer.
An empty, unknown, or malformed author footer returns null.
Footer column parsing errors still propagate typed `ParseError`.
`extra` and `extra_bytes` retain the complete opaque footer, including unknown or trailing bytes.

`getChangesMeta` excludes `have` and its dependencies and returns dependencies before dependents.
Empty `have` selects all committed history. Unknown and duplicate frontier hashes have no effect.
`getChangeMetaByHash` returns null outside committed history.
Allocation refusal releases partial output without changing history.
`change_record.ChangeMetadata.fromChange(gpa, change)` is a separate borrowed low-level record.
It contains that individual footer and author. Its `intoOwned(gpa)` copies those fields.

`hashForOpid` allocates nothing. Root, unknown, and pending IDs return null.
Deletion does not erase the originating change hash.
Named IDs resolve actor bytes rather than trust stale cached slots.
`transaction.hashForOpid` and `AutoCommit.hashForOpid` expose the same committed lookup.

`getActors`, `getAuthors`, and `getActorForAuthor` return caller-owned arrays of borrowed bytes.
`setAuthor` copies arbitrary bytes and draws a new actor when the author changes.
Entropy refusal leaves actor and author unchanged.
Raw `setActorId` borrows uninterned caller bytes until the document interns them.
Keep those bytes live. `AutoCommit.setActorId` copies its input.

`importObj(gpa, spelling)` parses a stable ID and resolves its actor.
Malformed spelling returns `InvalidObjIdFormat`. Unknown actors or unrepresentable resident counters return `InvalidObjId`.
`import` also verifies a live object and returns `ImportedObject { id, object_type }`.
Imported actor bytes borrow the document.
`initFromHydrate` writes one transaction and returns its full owned outcome, including recovery on rollback refusal.
It does not remove existing keys absent from the input map (`automerge.rs:297-304`).
The input creates predecessor-free operations in sorted key order, followed by breadth-first nested values (`inner.rs:1334-1380`).
The latest operation wins for an existing key. Older visible values remain conflicts.
Repeated equal inputs still create operations.
This matches canonical Rust change replay, not the pinned reference initializer's incorrect retained-root row placement.
`dump` and `diffOpSet` write diagnostics through a caller-owned writer.
Writer refusal can leave a prefix. They are not aliases for `debugCmp`.
`anonymize` takes an explicit 32-byte seed, unlike Rust's internally drawn seed.
Its document and `Shape` owners retain their own cleanup and borrow duties.
Rollback belongs to a transaction. There is no document `split` method.

### Ownership and synchronization

Each `Document` has one owner and one `deinit`.
A shallow copy is not an independent owner.
Move a document only when no address borrow remains.
Use `clone`, `fork`, or `forkAt` for independent state.
The retained allocator and `io` provider must outlive disposal.
`Built`, `Changes`, metadata, fragments, bundles, and output buffers have separate cleanup duties.
Free fragment arrays and the outer collection through their documented allocator.
`bundleFragments` returns both an owned outer array and owned buffers.
It drops fragments it cannot rebuild, but never swallows `OutOfMemory`.

Serialize reads as well as writes. Reader caches and scratch are not internally synchronized.
Do not mutate while a borrowed walk is live.
The C route requires the stronger global boundary stated in [C ABI](#c-abi).

### AutoCommit

`AutoCommit` embeds one `Document` and one optional `Transaction`.
Writers open that transaction lazily. Ordinary reads see pending work without committing.
Several writes share one change until an explicit commit or close barrier.
Commit returns `WriteError!?ChangeHash`. A no-write commit returns null, not an empty change.
`emptyChange(options)` deliberately publishes a zero-operation change.
`rollback()` retains cancellation progress if it refuses.
Producer refusal retains the sole held journal. Partial publication requires rollback before further row access.
`deinit()` releases the held journal and entire document without exposing unfinished rows to another owner.

Keep an open `AutoCommit` at its final address.
`cloneInto(gpa, destination)` copies pending state without closing the source.
Initialize the clone at its final address. On refusal, the destination is uninitialized and the source remains unchanged.
`fromDocument(document)` consumes a raw document without an externally held transaction.
`fork` and `forkAt` close first and return independent closed owners.
`withActor` and `withAuthor` return the same owner pointer after their closing setter.

| Operation group | Pending transaction policy |
| --- | --- |
| All ordinary and historical `ReadDoc` methods, including `hydrate` | Do not close. Historical reads exclude pending work. `hydrate(null)` uses raw current rows. |
| `getHeads`, `getChanges`, `getChangesMeta`, `getChangeMetaByHash`, `getLastLocalChange`, inherent `getMissingDeps` and `getChangeByHash` | Close before reading committed history. |
| Generic `read.getMissingDeps` and `read.getChangeByHash` | Do not close. These use the `ReadDoc` path, not the inherent facade barrier. |
| `save`, `saveWithOptions`, `saveAfter`, `saveIncremental`, `saveAndVerify` | Close first. Caller owns output bytes. |
| `applyChanges`, `applyChangesBatch`, their logged variants, incremental loading, merge and logged merge | Close first. Merge and `getChangesAdded` close both owners. |
| `diff`, `diffObj`, `diffIncremental`, `updateDiffCursor`, `resetDiffCursor` | Close first. |
| `isolate`, `integrate`, setters, `anonymize`, `document`, `dump` | Close first. `document()` then returns a raw const borrow. |
| `sync`, sync generation, receive, logged receive, `hasOurChanges` | Close first. Receive consumes the message on every path. |
| `cloneInto`, `pendingOps`, `baseHeads`, `diffCursor`, `makePatches`, actor/author getters, `stats`, `isEmpty`, `hashForOpid`, imports, fragments, bundles, `diffOpSet` | Do not close. Committed-history readers do not publish pending work. |

`getHeads` reports the isolated view when isolated.
`hasOurChanges` compares exact ordered peer shared heads with full committed graph heads, ignoring isolation.
The raw predicate neither allocates nor mutates.
Isolation chooses the concurrency actor when opening a transaction, not during commit (`automerge.rs:1259-1281`).
Automatic isolated commits advance their isolation to the new change.
Raw commits do not advance facade isolation.
Incoming work outside an isolated view uses a null internal sink rather than corrupt its view log.
Isolation and integration finish the outgoing patch view before recording the transition (`autocommit.rs:816-824`).

### Diffing

Raw `Document.diff(gpa, before, after)` and `diffObj(gpa, obj, before, after, recursive)` return owned `Patches`.
`diff` selects root with `recursive = true`.
Head ranges can run backward. Release each result with `Patches.deinit()`.
Raw `diffIncremental`, `diffCursor`, `updateDiffCursor`, `resetDiffCursor`, and `makePatches` remain available.
`diffCursor(gpa)` returns owned hashes. `makePatches(log)` borrows the external log.

`AutoCommit.diff` and `diffObj` maintain one cached range, object identity, recursive flag, and owned patch batch.
The cache owns canonical head keys and durable actor bytes. It never retains caller key slices.
Each hit returns a deep independent `Patches` owner.
Refused cache replacement preserves the previous valid cache.
Mutations invalidate it. `cloneInto` copies it independently.
`diffIncremental` advances its cursor only after producing a successful result.
Cache-hit copying is a consumer cost, not a measured speed claim (`autocommit.rs:262-269`).

## Sync

`src/sync/` exposes `sync.state.State` and `sync.message.Message`.
The message is a struct with an optional body, not a tagged union.
A v2 message can carry no payload.

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
pub fn receiveSyncMessageWithPatchLog(gpa: Allocator, doc: *Document, state: *State, message: Message, log: *PatchLog) ProtocolError!void;
pub fn getHashesToSend(gpa: Allocator, doc: *Document, have: []const Have, need: []const ChangeHash) ProtocolError![]ChangeHash;
pub fn makeBloomFilter(gpa: Allocator, doc: *Document, last_sync: []const ChangeHash) ProtocolError!Have;
```

The frozen v1 path is a second pair of the same two functions, because a v1 peer
is a different protocol and not a flag on one (`src/sync/v1.zig`):

```zig
pub fn generateSyncMessage(gpa: Allocator, doc: *Document, state: *State) ProtocolError!?Message;
pub fn receiveSyncMessage(gpa: Allocator, doc: *Document, state: *State, message: Message) ProtocolError!void;
pub fn receiveSyncMessageWithPatchLog(gpa: Allocator, doc: *Document, state: *State, message: Message, log: *PatchLog) ProtocolError!void;
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

`receiveSyncMessage` consumes its message on every path, including typed refusal.
Do not separately dispose it afterward.
State and document can retain a valid applied prefix on failure.
Logged raw receive borrows the log and rejects an incompatible projected actor table before incoming document or state mutation.
It still consumes the message on that rejection.

The message type byte is `0x42` for v1 and `0x43` for v2
(`src/sync/message.zig` `message_type_sync` and `message_type_sync_v2`), and a
v2-capable peer falls back to v1 when the other side does not advertise v2.

Raw protocol operations are free functions on `Document` and `State`.
`AutoCommit.sync()` returns a borrowed `SyncDoc` wrapper after closing pending work.
Its generation, receive, and logged receive methods retain that closing policy.
Direct facade sync methods provide the same barrier.
The wrapper does not own the document or state.

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

`ConcreteTextValue` owns native units in allocator-backed sequence trees (`text_value.rs:36-192`).
Units are `u8`, `u16`, `u21`, or owned grapheme byte strings.
UTF-8 and UTF-16 edits can retain incomplete scalars.
Stored grapheme segmentation does not change merely because adjacent text changes.

```zig
pub fn init(gpa: Allocator, s: []const u8, enc: TextEncoding) Error!ConcreteTextValue;
pub fn initOwned(gpa: Allocator, bytes: []u8, enc: TextEncoding) Error!ConcreteTextValue;
pub fn encoding(self: *const ConcreteTextValue) TextEncoding;
pub fn len(self: ConcreteTextValue) usize;
pub fn get(self: *const ConcreteTextValue, index: usize) ?Unit;
pub fn splice(self: *ConcreteTextValue, index: usize, value: []const u8) Error!void;
pub fn spliceTextValue(self: *ConcreteTextValue, index: usize, other: *const ConcreteTextValue) Error!void;
pub fn push(self: *ConcreteTextValue, value: []const u8) Error!void;
pub fn remove(self: *ConcreteTextValue, index: usize) Error!void;
pub fn removeRange(self: *ConcreteTextValue, index: usize, length: usize) Error!void;
pub fn makeString(self: *const ConcreteTextValue, gpa: Allocator) Error![]u8;
pub fn dup(self: ConcreteTextValue, gpa: Allocator) Error!ConcreteTextValue;
pub fn deinit(self: *ConcreteTextValue) void;
```

`len` counts native units, not rendered bytes.
`get` returns null out of range. A returned grapheme slice borrows the owner until mutation or disposal.
UTF-8-unit initialization accepts arbitrary bytes. Other encodings reject invalid UTF-8 with `InvalidCharacter`.
`initOwned` consumes its input buffer only on success.
`splice` appends for a past-end index. Invalid input or allocation refusal preserves the original units.
`spliceTextValue` requires matching encodings and preserves stored unit boundaries.
`removeRange` deletes native units without allocation and clamps its end.
Zero length and a past-end index are no-ops. Splitting a scalar is not an encoding refusal.
`makeString(gpa)` returns owned, lossy UTF-8. Free it with `gpa`.
There is no borrowed UTF-8 `asStr` or direct `.bytes` field.
An ordinary owner calls `deinit` once. `Patches.deinit` releases patch-owned native text trees.

### Patch log and path-map ownership

`PatchLog.init(gpa, recording)`, `active`, `inactive`, and `nullLog` retain their allocator.
There is no capacity constructor. `deinit()` releases log storage.
`prepareLocal(patches)` returns owned `StagedLocal`.
Release that stage on refusal or transfer it to infallible `commitLocal(staged)`.
Transactions now record events into their sole owned log during writes.
Commit transfers that log in `CommitResult`, rather than fabricate a document-owned substitute.

`PatchBuilder` consumes its seed `PathMap`.
The path-map array and keys follow their source allocator and borrow rules.
The result `Patches` arena owns copied output paths, identities, scalar bytes, and marks.
Do not release a transferred seed twice.
`makePatches` borrows a compatible log and returns an independent `Patches` owner.
The renderer exports object, path, value, and exposed identities through the selected document's actor table.
A compatible retained log suffix can name an actor absent from that table.
Primary apply can succeed, yet subsequent rendering returns `InvalidActorIndex`.
The reference panics on that missing export slot; native rendering reports the checked error.
It does not insert an actor, use log actor bytes as a substitute, or suppress the refusal.
Public non-rendering `Document.idToExid` remains unchanged.
Patch-document implementations must provide a fallible `exportPatchId`; there is no infallible fallback.
All renderer export failures propagate through `MakeError`.
The log's path-map seed is first-use builder input and can be consumed during rendering.
Do not assume that an extra rendering call observes the same internal seed.

Batch publication has a different ownership check from public actor compatibility.
`beginBatch()` records the exact target address in `batch_origin`.
`preparePublish(target)` requires that same target and stages all fallible output preparation.
`publish(target)` consumes the prepared stage without allocation.
Do not move the target log while its stage is live or publish a stage into a merely actor-compatible log.
The whole-current-state operation is `diff` with empty `before`.

`Document.commit` receives the transaction's prepared `TransactionArgs` and borrowed dependency array.
It does not choose the actor again after rows already exist.
The actor decision belongs to transaction opening (`autocommit.rs:445-457`, `inner.rs:146-172,295-297`).


## Errors

```zig
pub const Error = error{ ... };         // src/error.zig — document API, §3.1 of the plan
pub const ParseError = error{ ... };     // src/error.zig — untrusted bytes
pub const InternalError = error{ ... };  // src/error.zig — asserts upstream treats as impossible
pub const InitError = Allocator.Error || std.Io.RandomSecureError;  // src/doc.zig
pub const DiffError = ParseError || ReadOpError || Error || InternalError;  // src/doc.zig = src/iter/doc.zig
```

Parsers must return typed errors over untrusted bytes, never panic or loop.
This is a requirement, not a completed audit claim.
Malformed input can also reach allocation, capacity, read, or application error sets.
Do not require every failure to be a member of `ParseError` alone.

`Canceled` and `EntropyUnavailable` propagate secure-random refusal through constructors and actor creation.
The port does not return a partially drawn actor or fall back to a weaker source.
`setAuthor` retains actor and author when its secure draw refuses.
These are scoped guarantees, not a promise that cancellation rolls back any earlier application work.
The pinned Rust actor constructor panics on entropy failure (`automerge.rs:307-317`).

## C ABI

Not part of the Zig API, and the only place the port speaks to libc. It mirrors
`automerge-c`: the `AMresult` convention, one destructor, pinned enum
discriminants. See [plan.md](docs/plan.md) §6 P10 and
[survey/07](docs/survey/07-bindings.md).

`AMdoc` owns the same native `AutoCommit` used by Zig consumers.
Pending clones use `cloneInto` at the final destination address.
Public C signatures and global serialization duties remain unchanged.

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

**`zig build ctest-shared` is the native dynamic-link corpus gate.** It builds
a test-only shared library from the same production root (including
`result_from.c`), links a standalone C consumer without cmocka, and depends on
the ABI compile check. Its C fixture table is generated from the canonical
`test/fixtures/manifest.zig`: all 18 current load outcomes are asserted, and
each of the five valid documents exercises save/reload equality and heads,
transaction writes with commit hash/head/change and exact-value checks, and
encoded bidirectional sync to quiescence within 32 rounds with document/head
equality and both peers' values. Result owners outlive every borrowed handle.
Failures return nonzero with fixture diagnostics. Build-managed runtime search
paths locate the shared artifact; the default installed package remains the
static library and header. This gate is not exhaustive C API coverage or live
Rust sync interoperability; see `test/c/README.md` for scope and commands.

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

This is a source-contract ledger for the current working tree.
It replaces stale signature rows and historical gap claims, not the phase gates.
Every reader in [Read](#read) and writer in [Write](#write) has its full current argument shape above.
Grouped rows below retain the complete declaration scope. A source row is not a passing test.

| Surface | Current source owner and contract |
| --- | --- |
| `root`, `ObjId`, `ExId`, `ActorId`, `Author`, `OpId`, `ElemId`, `ObjType`, `Prop`, `TextEncoding`, `ChangeHash` | `src/root.zig`, `src/types.zig`. Stable public IDs, checked resident capacity, four text encodings, explicit borrowed and owned codecs. |
| `Value`, `ScalarValue`, `ValueRef`, `ScalarValueRef`, owned wrappers and datatype helpers | `src/value.zig`, `src/opset/types.zig`. Objects carry kinds, not identities. Owned conversion detaches scalar bytes. |
| `Change`, `Built`, `Changes`, expanded types, both metadata forms | `src/change.zig`, `src/doc.zig`. Borrowed header versus independent structured decode and owned body. Authoritative opaque footer survives reconstruction. |
| `Mark`, `MarkSet`, `ExpandMark`, `UpdateSpansConfig` | `src/marks.zig`. Mark ownership, borrowed tombstone-filtered view, configurable expansion. |
| `Cursor`, `Patch`, `PatchAction`, `Patches`, `ConcreteTextValue`, `Stats` | `src/cursor.zig`, `src/patches.zig`, `src/doc.zig`. Wide wire cursor, ordered owned patches, native text units, truthful build provenance. |
| `get`, `getAll`, `objectType`, `length`, `text`, `keys`, `values`, `spans`, `marks`, `parents`, `mapRange`, `listRange`, `iter` | `src/read.zig`, `ReadDoc(R)`, `Transaction`, `AutoCommit`. Ordinary scoped readers do not close automatic work. |
| `getAt`, `getAllAt`, `lengthAt`, `keysAt`, `valuesAt`, `textAt`, `spansAt`, `marksAt`, `mapRangeAt`, `listRangeAt`, `parentsAt`, `iterAt` | Same reader owners. Explicit heads use durable committed historical clocks. |
| `getCursor`, `getCursorMoving`, `getCursorPosition`, `hydrate`, `markSetAtIndex` | Same reader owners. Nullable heads belong to the actual methods. `hydrate(null)` deliberately bypasses scope. |
| `getAtScope`, `markSetAtScope`, `getCursorPositionFor` | `src/read.zig`. Raw explicit-clock helpers. |
| `getMarks`, `getMissingDeps`, `getChangeByHash`, `stats`, `textEncoding` | `src/read.zig`. Mark window is distinct from single-index mark set. Generic history readers are nonclosing. |
| `put`, `putObject`, `insert`, `insertObject`, `increment`, `delete`, `splice`, `spliceText`, `mark`, `unmark` | `src/transact.zig` `Transaction`, `src/autocommit.zig` `AutoCommit`. Owner methods, no per-call automatic free writers. |
| `splitBlock`, `joinBlock`, `replaceBlock`, `updateText`, `updateObject`, `updateSpans`, `updateSpansWithConfig` | Same writer owners. Full hydrated objects and borrowed rich-span inputs. |
| `batchCreateObject`, `batchCreateValue`, `initRootFromHydrate`, typed map/list/text update helpers | Same writer engine. Object-kind convenience remains distinct from hydrated batch input. |
| `open`, `openAt`, `openWithPatchLog`, `commit`, `commitWith`, `rollback`, `deinit`, `deinitClosed`, `takePatchLog` | `Transaction`. Success-only log transfer, owned commit result, retained recovery on refusal, fallible rollback disposal. |
| `count`, `baseHeads`, `nextId`, `scopeClock`, `textFor`, `blockAt`, all transaction readers | `Transaction`. Borrowed dependencies, scoped pending view, caller-held document lifetime. |
| `CommitOptions`, `CommitResult`, `Success(O)`, `Failure(O,E)`, `Outcome(O,E)`, closure variants, `OwnedTransaction` | `src/transaction.zig`, root `transaction`. Callback error preservation and exactly one recovery/log owner. |
| `actorId`, `maxOp`, `heads`, `hashForOpid`, `depIndices`, `changeMeta`, `authorFooter`, `abort` | `src/transaction.zig`. Explicit metadata helpers. Commit options apply through the transaction method. |
| `init`, `initWithEncoding`, `load`, `loadWithOptions`, `loadUnverifiedHeads`, `rescue`, `loadInto`, `loadIntoWithOptions` | `Document`, with corresponding facade constructors. Mode-less construction, retained `io`, complete load policies, detached rescue result. |
| `save`, `saveWithOptions`, `saveAfter`, `saveIncremental`, incremental load, apply, merge and external-log forms | `Document`, `AutoCommit`. Raw versus close-barrier policy. Owned output and borrowed incoming logs. |
| `getHeads`, `hasChange`, `getMissingDeps`, `getChanges`, `getChangesAdded`, `getLastLocalChange`, `getChangeByHash`, metadata readers, `hashForOpid` | `Document`, facade history routes. Full versus isolated head semantics and detached owned results. |
| `getChangesByHashes` | `src/doc.zig` `Document`. Low-level ordered, multiplicity-preserving owned batch for protocol lookup. No facade route or close barrier. |
| `commit`, `emptyCommit`, `transactionArgs`, `allocator` | `Document`. Raw publication primitives, not a second automatic lifecycle. |
| `getActorId`, `setActorId`, `getActorIndex`, `getActor`, `numActors`, `putActorRef`, `removeActor`, `removeUnusedActors` | `Document`. Sorted actor authority and checked remapping. Facade setter closes and copies actor bytes. |
| `getAuthors`, `getActors`, `getAuthor`, `setAuthor`, `getAuthorForActor`, `getActorForAuthor` | `Document`, `AutoCommit`. Arbitrary author bytes. Outer arrays own storage, ordinary byte views borrow. |
| `fork`, `forkAt`, `clone`, isolation methods, `readScope`, `clockAtScope`, `isEmpty`, `len`, `resolve`, `objectType`, `objectParent`, `idToExid`, raw `text`, `marks`, `debugCmp` | `Document`. Independent owners, stable historical clocks, explicit raw helpers. `isEmpty` tests graph and queue, not row count. |
| `bundle`, `fragments`, `getFragment`, `bundleFragments` | `Document`, `AutoCommit`. Complete fragment/buffer cleanup. Facade routes do not close pending work. |
| `initFromHydrate`, `import`, `importObj`, `dump`, `diffOpSet`, `hasOurChanges`, seeded `anonymize` | `src/doc.zig`, `src/anonymize.zig`, facade equivalents where declared. Full outcome, typed imports, writer diagnostics, exact shared-head predicate. |
| `diff`, `diffObj`, `diffIncremental`, `diffCursor`, `updateDiffCursor`, `resetDiffCursor`, `makePatches` | Raw document plus automatic facade. Facade owns one-entry cache and independent results. |
| Automatic lifecycle, `cloneInto`, `document`, `withActor`, `withAuthor`, `emptyChange`, `sync`, batch variants, `saveAndVerify` | `src/autocommit.zig`. One held engine, address-stable pending clone, declared close barriers. |
| Sync `State`, `Message`, constructors, encode/decode, readonly/capability methods, `MessageBuilder`, `BloomFilter.toBytes` | `src/sync/`. State and message owners, caller-owned encoded bytes, consuming builder setters. |
| Sync generation, receive, logged receive, hash selection, bloom generation, frozen v1, `decodeV1` | `src/sync/protocol.zig`, `src/sync/v1.zig`. Raw free protocol routes and automatic closing wrapper. Receive consumes the message. |
| `PatchLog`, its constructors and teardown, `StagedLocal`, `prepareLocal`, `commitLocal`, `Patches` methods | `src/patches.zig`. Retained allocators, owned staged attachment, deep output storage. No capacity constructor. |
| `Error`, `ParseError`, `InternalError`, named constructor/read/write/load/diff/patch/sync sets | Their owning modules. Typed refusals and operation-specific residue, not a single global guarantee. |
| C artifact, installed header, result/doc/sync routes, ABI check | `include/automerge.h`, `src/c/root.zig`, `test/c/cabi.zig`. Separate production artifact and reached header checks. Global serialization remains required. |

## Hydrated values and marks

`hydrate.Value` has flat scalar tags and `object: hydrate.Object`.
Composite payloads are `object.map`, `object.list`, and `object.text`, not scalar or map union aliases.
Use `Value.scalar(s)` or `Value.fromScalar(s)` for a scalar.
`map(gpa)`, `list(gpa)`, and `text(gpa, encoding, bytes)` construct composite owners.
`Value.init(gpa, publicValue, encoding)` and `dup(gpa)` return `hydrate.OwnedValue`.
`asMap` and `asList` return borrowed mutable container pointers or null.

`MapValue` has `value`, `conflict`, and its retained byte owner.
`MapValue.init(value, conflict)` still borrows scalar payloads until insertion.
`Map.putOwned(key, register)` copies the key and any unowned byte-bearing scalar payload.
On success it transfers the register's composite map/list/text structures; it does not duplicate them.
On refusal the caller still owns the original register and its structures.
Do not dispose or reuse an inserted composite as a second owner.
Use `dup(gpa)` before insertion when the source must remain independent.
`Map`, `List`, `Text`, their register values, marked values, mark sets, and spans provide independent deep copies.
Release each owner once. A shallow assignment is not a clone.
Patch application follows property paths. Object IDs in the mirror are diagnostic metadata, not path-validation authority.
Application refusal preserves the valid action prefix, not an inferred all-or-nothing batch.
Oversized sequence deletion returns `InvalidIndex` instead of reproducing the reference panic.

`MarkSet.nonDeletedMarks()` returns a borrowed, no-allocation `NonDeletedMarks`.
Its `len`, `isEmpty`, and `eql` ignore null tombstones.
Keep the source set live and unchanged.

## Expanded changes and serialization

`Change.decode(gpa)` returns owned `ExpandedChange`.
`ExpandedChange.dup(gpa)` copies operations, identities, scalar payloads, dependencies, and footer bytes.
`deinit(gpa)` releases a decode or duplicate owner.
A JSON `Parsed` arena instead owns its parsed views. Release the wrapper, not each view.
`ExpandedChange.encode(gpa)` returns owned `doc.Built` through the production wire codec.
`extra_bytes` is authoritative. `hash` and parsed `author` are informational and do not change encoding.
The encoder recomputes the hash and retains the operation count after parsing.
Resident operation bounds still apply to encoding.

Expanded operation JSON uses the reference action, object, key or element, predecessor, insertion, value, datatype, and mark fields.
Expanded change JSON uses `ops`, `actor`, optional `hash`, `seq`, `startOp`, `time`, `message`, `deps`, `extraBytes`, and optional `author`.
Do not serialize allocator state or native implementation fields.
`Change.fromBytes(gpa, bytes)` accepts framed or compressed changes and returns owned `Built`.
`rawBytes(gpa)` and `compressedBytes(gpa)` return owned buffers without adding a mutable cache to the borrowed header.
`len(gpa)` and `isEmpty(gpa)` inspect operation rows.
`actorsOwned(gpa)` copies every actor's bytes. Release each actor buffer and then the array.

`autoserde.AutoSerde(R).from(reader)` borrows any full `ReadDoc` owner.
`toJson(gpa)` returns owned compact JSON. `writeJson(gpa, writer)` borrows the writer.
`serialize(gpa, backend)` uses a compile-time backend with map, sequence, string, and scalar operations.
`JsonSerializer` and the independent owned `TokenStream` implement that protocol.
The backend declares `Error` and supplies `beginMap`, `endMap`, `mapKey(key,index)`,
`beginSeq`, `endSeq`, `element(index)`, `string(bytes)`, and `scalar(value)`, each returning `Error!void`.
Entry indices start at zero. This is a compile-time protocol, not a runtime interface object.
Backends must consume or copy borrowed payloads during each call.
Backend refusal can leave a prefix. Discard it before retrying.
Serialization of scoped `Transaction` or `AutoCommit` does not close pending work.
There is no invented document-deserialization contract for `AutoSerde`.

Sync message serialization emits only `heads`, `need`, `have`, and `changes`.
Each `Have` emits `last_sync` and `bloom`.
Wire flags and message version remain wire metadata, not extra serde fields.

# Known gaps

The target native public surface is implemented. These are compatibility and proof limits, not absent-method claims.

- The preceding checkpoint passed Debug, slow-path and ReleaseSafe gates, native target replay, standalone public consumers,
  reference conformance/live interoperability, static and dynamic C consumers, and fresh matched CLI correctness.
  These results predate the optimization wave and do not prove the changed source passes those gates.
  Exact counts, fingerprints, and proof scope remain in the
  [authoritative STATUS checkpoint](docs/STATUS.md#latest-observed-checkpoint-2026-10-08).
- The optimization-wave ledger (`integrated-wave1-verified.json`, `focused_checks`) records 52/52 passes in Debug and ReleaseSafe, with no reported leaks.
  Selected-history tests cover duplicate order, independent ownership after disposal, normalized reference operations, hashes, bodies, actor tables, and `max_op`.
  They also use `checkAllAllocationFailures` on selected unique and duplicate batches (`src/doc.zig` selected-history tests).
  This focused evidence does not replace full suites, API replay119, C160/dynamic18, conformance12/live6, or the 26-cell matched gates.
  It does not prove allocation-failure atomicity for every input or operation.
- The API corpus includes retained-tail apply success followed by the reference renderer's panic
  versus native checked `InvalidActorIndex`. This is an explicit compatibility exception, not suppressed failure.
- A bounded ownership audit found no residual finding in its inspected scope.
  Static review and passing consumers do not prove all malformed-input or allocation-refusal states.
- Existing consumer ledgers still bound case-for-case upstream coverage and encoding exceptions.
  The preceding checkpoint completed correctness and matched-comparison gates within its recorded scope, not for the changed source.
  The historical [final performance comparison](bench/README.md#final-matched-results) does not establish Rust performance parity.
  Faster cached-diff phases do not offset the measured setup and whole-process costs.

## Compatibility and capacity exceptions

The format, change hashes, columns, and sync bytes target the pinned reference.
Compressed document saves need not match byte-for-byte. Check reload state, heads, and normalized bodies.
Package and compiler provenance deliberately describe Zig, not Rust's Cargo package or MSRV.

Stable named IDs and wire cursors accept `u64` counters.
Resident `OpId`, actor indices, and operation storage remain bounded by `u32`.
Wide IDs can round-trip without being valid live objects.
Expanded encoding and live resolution check that boundary instead of truncating it.
`OpId.prev`, `next`, and actor-shift primitives retain their documented arithmetic preconditions.
They are low-level caller obligations, not unlimited-capacity parsers.

The port does not reproduce Rust panics for malformed odd-hex imports or oversized hydrated sequence deletion.
It returns typed refusals and preserves the valid prefix.
Unverified-head loading does not promise that a damaged head graph can subsequently save.
The observed reference can load such metadata and later panic during save.
This is not permission for a native parser or writer to panic.

## API design decisions

Branch: **evolve**. The contract separates raw and automatic owners and migrates callers without shims.
The source baseline is the current uncommitted working tree.
The reference and compiler pins are stated at the top.
Source reading, reached compilation, runtime observations, and measurements remain separate evidence.
The manifest version is not the upstream version.

The following records are analyst-authored contract judgments, not recovered upstream motives.
Their obligations are documented contracts. Their consumer costs come from the source shape.

| Decision | Priority and constraint | Consumer cost | Counterchoice and winning setting |
| --- | --- | --- | --- |
| Separate raw and automatic owners | Match change boundaries. One journal must span automatic writer calls. | Keep an open facade at its final address. Use its barriers rather than mutate embedded raw state. | Per-call transactions suit applications that deliberately want one change per operation. |
| Retain `std.Io` | Later actor creation needs the same live provider without a weak fallback. | Keep allocator and provider live. Handle entropy and cancellation errors. | Per-call capability arguments suit objects with no retained provider-dependent state. |
| Return owned logs and recovery | Fallible commit and rollback cannot discard ownership or replace the primary error. | Release terminal logs. Retain and retry a progressed recovery journal. | Full-document snapshots suit bounded state where copying buys a simpler atomic contract. |
| Retain historical clocks | Returned walks borrow clock slots and callers can select another cone. | Mutation invalidates all borrowed walks. Clock storage lives until invalidation. | Per-call clocks suit readers that return no borrowed walks. |
| Store native text units | UTF-8 bytes and UTF-16 surrogate halves need independent editing. Grapheme boundaries must persist. | Render an owned lossy UTF-8 string and release it. | A plain UTF-8 buffer suits consumers restricted to complete scalar boundaries. |
| Deep-own span blocks and iterator outputs | Outputs must survive source mutation and teardown. | Pay explicit copy costs and dispose once. | Borrowed views suit short reads that finish before mutation. |
| One-entry automatic diff cache | Repeated range queries must retain durable keys and independent results. | Hits still copy owned patches. No universal speed claim. | Uncached diffs suit mostly rotating ranges or callers that cannot justify retained cache storage. |
| Preserve C ABI and global provider | Existing signatures have no capability parameter. | Serialize calls globally and follow bounded callback borrow rules. | Explicit context handles suit a new ABI that can expose provider ownership. |
| Separate production and ABI check roots | Header layout checks must not become production dependencies. | Link the actual artifact and compile the real header under the stated ABI configuration. | Generated bindings suit targets where the generator also validates the authored header contract. |

No const receiver, field accessibility rule, or assignment operation enforces these ownership duties for the caller.
The named final correctness and comparison gates passed; their exact scope is recorded in STATUS and the benchmark README.