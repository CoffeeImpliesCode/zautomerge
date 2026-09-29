# zautomerge API

The target public surface of the Zig port. This is a contract, not a
description of what exists: as of the first commit nothing below is
implemented. See [PROJECT.md](PROJECT.md) for status and
[plan.md](docs/plan.md) for the phase that produces each part.

Method names, argument order, and semantics follow the Rust crate
(`automerge` 0.12.0) so the two trees are diffable. Where Zig forces a
different shape, the deviation is marked **deviation** and justified.

## Conventions

- Every entry point that can allocate takes a `std.mem.Allocator` as its first
  argument.
- Every fallible function returns `Error!T` (`ParseError!T` on the untrusted
  input paths).
- Values that borrow from the document are slices into the document's own
  storage, valid until the next mutation. Values that a caller may hold across a
  mutation are returned by copy.
- Historical reads take `?[]const ChangeHash`; `null` means "current". Upstream
  has an `_at` variant per method; **deviation**: one method with an optional
  argument instead, because a name that exists in two forms is a name that is
  documented in two places.
- `root` is the root object id, matching `automerge::ROOT`.

```zig
pub const root: ExId = .root;
```

## Types

| Rust | Zig | Notes |
| --- | --- | --- |
| `ExId` / `ObjId` | `ExId` | `union(enum) { id, root }`; upstream re-exports `exid::ExId` as `ObjId`, a rename that changes the meaning — the port uses one name |
| `ActorId` | `ActorId` | external byte string, never stored in a column |
| `OpId` | `OpId` | `{ counter: u32, actor: ActorIdx }` |
| `ObjType` | `ObjType` | `map`, `list`, `text` |
| `Prop` | `Prop` | `key`, `index`, or a sequence type |
| `TextEncoding` | `TextEncoding` | `utf8_code_point`, `utf16_code_unit`, `utf8_byte` |
| `ScalarValue` | `ScalarValue` | tagged union, §Values |
| `Value` | `Value` | `scalar` or `object` |
| `Change` | `Change` | metadata plus the encoded bytes |
| `ChangeHash` | `ChangeHash` | 32 bytes, SHA-256 |
| `Mark`, `MarkSet` | `Mark`, `MarkSet` | |
| `Cursor` | `Cursor` | |
| `Patch`, `PatchAction` | `Patch`, `PatchAction` | |
| `Stats` | `Stats` | |

## Read

The `ReadDoc` surface. `doc: *const Document`, so a read never needs a mutable
borrow, which is what lets iterators be plain values.

```zig
pub fn get(doc: *const Document, obj: ExId, prop: Prop) Error!?DocItem;
pub fn getAll(doc: *const Document, obj: ExId, prop: Prop) Error![]DocItem;
pub fn objectType(doc: *const Document, obj: ExId) Error!ObjType;
pub fn length(doc: *const Document, obj: ExId) usize;
pub fn text(doc: *const Document, obj: ExId, gpa: Allocator) Error![]u8;
pub fn keys(doc: *const Document, obj: ExId) Keys;
pub fn values(doc: *const Document, obj: ExId) Values;
pub fn spans(doc: *const Document, obj: ExId) Error!Spans;
pub fn marks(doc: *const Document, obj: ExId) Error![]Mark;
pub fn getMarks(doc: *const Document, obj: ExId, from: usize, max: usize) Error![]Mark;
pub fn parents(doc: *const Document, obj: ExId) Parents;
pub fn getCursor(doc: *const Document, obj: ExId, pos: CursorPosition) Error!Cursor;
pub fn getCursorMoving(doc: *const Document, obj: ExId, pos: CursorPosition, bias: Bias) Error!Cursor;
pub fn getCursorPosition(doc: *const Document, obj: ExId, cursor: Cursor) Error!CursorPosition;
pub fn getMissingDeps(doc: *const Document, heads: []const ChangeHash) []ChangeHash;
pub fn getChangeByHash(doc: *const Document, hash: ChangeHash) ?Change;
pub fn stats(doc: *const Document) Stats;
pub fn textEncoding(doc: *const Document) TextEncoding;
```

`mapRange`, `listRange`, and `iterAt` take an explicit half-open range
(`struct { start: usize, end: ?usize }`) instead of upstream's
`RangeBounds<String>`, **deviation**: Zig has no range-bounds protocol and
reproducing it with an enum costs more than it saves.

## Write

The `Transactable` surface, on a `Document` in autocommit mode. A manual
`Transaction` is a separate type that borrows the document and commits or rolls
back explicitly.

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
pub fn batchCreateObject(doc: *Document, obj: ExId, prop: Prop, t: ObjType) Error!ExId;
pub fn initRootFromHydrate(doc: *Document, value: hydrate.Map) Error!void;
pub fn pendingOps(doc: *const Document) usize;
pub fn baseHeads(doc: *const Document) []ChangeHash;
```

## Document

```zig
pub const Document = struct { ... };

pub fn init(gpa: Allocator) Document;
pub fn deinit(doc: *Document) void;
pub fn load(gpa: Allocator, bytes: []const u8) LoadError!Document;
pub fn loadIncremental(doc: *Document, bytes: []const u8) LoadError!void;
pub fn save(doc: *Document, gpa: Allocator) LoadError![]u8;
pub fn saveIncremental(doc: *Document, gpa: Allocator) LoadError![]u8;
pub fn commit(doc: *Document, gpa: Allocator, message: []const u8, timestamp: ?i64) Error!Change;
pub fn emptyCommit(doc: *Document, gpa: Allocator, message: []const u8, timestamp: ?i64) Error!Change;
pub fn merge(doc: *Document, other: *Document) Error!void;
pub fn applyChanges(doc: *Document, gpa: Allocator, changes: []const Change) Error!usize;
pub fn getHeads(doc: *const Document, gpa: Allocator) Error![]ChangeHash;
pub fn getChanges(doc: *const Document, gpa: Allocator, have: []const ChangeHash) Error![]Change;
pub fn getChangesAdded(doc: *const Document, gpa: Allocator, other: *const Document) Error![]Change;
pub fn getLastLocalChange(doc: *const Document) ?Change;
pub fn getChangeByHash(doc: *const Document, hash: ChangeHash) ?Change;
pub fn setActorId(doc: *Document, actor: ActorId) void;
pub fn getActorId(doc: *const Document) ActorId;
pub fn setActor(doc: *Document, actor: usize) void;
pub fn getActor(doc: *const Document) usize;
pub fn getAuthors(doc: *const Document, gpa: Allocator) Error![]ActorId;
pub fn getAuthorForActor(doc: *const Document, actor: usize) Error!ActorId;
pub fn getActorForAuthor(doc: *const Document, author: ActorId) ?usize;
pub fn forkAt(doc: *const Document, gpa: Allocator, heads: []const ChangeHash) Document;
pub fn fork(doc: *const Document, gpa: Allocator) Document;
pub fn split(doc: *Document, gpa: Allocator, heads: []const ChangeHash) !Document;
pub fn clone(doc: *const Document, gpa: Allocator) !Document;
pub fn rollback(doc: *Document) Error!usize;
pub fn bundle(doc: *const Document, gpa: Allocator) !Bundle;
pub fn anonymize(doc: *const Document, gpa: Allocator) AnonymizeError!Document;
```

## Sync

```zig
pub const SyncState = struct { ... };
pub const SyncMessage = union(enum) { ... };

pub fn initSyncState() SyncState;
pub fn generateSyncMessage(doc: *const Document, state: *SyncState) ?SyncMessage;
pub fn receiveSyncMessage(doc: *Document, state: *SyncState, msg: SyncMessage) Error!void;
pub fn encodeSyncMessage(state: *const SyncState, msg: SyncMessage, gpa: Allocator) ParseError![]u8;
pub fn decodeSyncMessage(state: *SyncState, bytes: []const u8, gpa: Allocator) ParseError!SyncMessage;
pub fn encodeSyncState(state: *const SyncState, gpa: Allocator) ParseError![]u8;
pub fn decodeSyncState(bytes: []const u8, gpa: Allocator) ParseError!SyncState;
pub fn markSyncStateReadOnly(state: *SyncState) void;
```

The message type byte is `0x42` for v1 and `0x43` for v2, and a v2-capable peer
must fall back to v1 when the other side does not advertise v2. **deviation**:
`SyncDoc` does not exist; `Document` has the four functions above.

## Patches

```zig
pub const PatchLog = struct { ... };

pub fn initPatchLog() PatchLog;
pub fn initPatchLogWithCapacity(gpa: Allocator, capacity: usize) PatchLog;
pub fn deinitPatchLog(log: *PatchLog, gpa: Allocator) void;
pub fn makePatches(doc: *const Document, log: PatchLog, gpa: Allocator) Error![]Patch;
pub fn makeCurrentPatches(doc: *const Document, log: PatchLog, gpa: Allocator) Error![]Patch;
```

## Errors

```zig
pub const Error = error{ ... };        // document API, §3.1 of the plan
pub const ParseError = error{ ... };    // untrusted bytes
pub const InternalError = error{ ... }; // asserts upstream treats as impossible
```

`ParseError` is the set that must be total over untrusted input: every fixture
in `tests/fuzz-crashers/` and every truncated or corrupted document must return
a `ParseError`, never panic and never loop.

## C ABI

Not part of the Zig API. P10 only, and it mirrors `automerge-c`: the
`AMresult` convention, one destructor, pinned enum discriminants. See
[plan.md](docs/plan.md) §6 P10 and
[survey/07](docs/survey/07-bindings.md).
