# zautomerge API

The native module is `zautomerge`. The C header is `automerge.h`.
See [README.md](README.md) for requirements, package integration, and build commands.
The compatibility target is Automerge 0.12.0 at `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`.
Source declarations contain the complete signatures and error sets.

## Ownership and execution

- Allocators and borrowed `std.Io` providers must outlive their documents.
- A shallow assignment transfers cleanup responsibility. It does not clone owned storage.
- Use `clone`, `fork`, or `forkAt` for independent raw documents.
- Keep open transactions and automatic documents at stable addresses.
- Serialize native reads and writes. Const receivers can update caches and shared scratch.
- Do not mutate a document while a borrowed iterator or payload remains live.
- Output-only readers take an allocator. Release output through its documented allocator or retained owner.
- `Keys.deinit()` uses the document allocator.

`Document.init(gpa, io)` and `initWithEncoding(gpa, io, encoding)` return `InitError`:
`Allocator.Error || std.Io.RandomSecureError`.
`Document.load(gpa, io, bytes, encoding)` returns `LoadError`.
Automatic constructors use the same initialization and loading rules.
Fresh actors use 16 secure random bytes. `Canceled` and `EntropyUnavailable` propagate without a weaker fallback.
`setActorId` supplies deterministic identities without random draws.
Raw `Document.setActorId` borrows uninterned input bytes. `AutoCommit.setActorId` copies them.

## Types and identity

| Type | Meaning and cleanup |
| --- | --- |
| `doc.Document` | Raw committed document with explicit transactions. Release with `deinit()`. |
| `AutoCommit` | Document with one lazy held transaction. Release with `deinit()`. |
| `Transaction` | Borrowed document transaction. Disposal can require fallible rollback. |
| `ExId`, alias `ObjId` | Root, resident identity, or named counter/actor identity. |
| `ActorId`, `Author` | Arbitrary bytes. `init` borrows. Copy/hex/random constructors own their output. |
| `OpId`, `ElemId` | Resident operation and sequence identities. |
| `ChangeHash` | SHA-256 wrapper with `bytes: [32]u8`. |
| `ObjType` | `map`, legacy `table`, `list`, or `text`. |
| `Prop` | Map `key: []const u8` or sequence `index: usize`. |
| `ScalarValue` | Scalar tag and payload. Byte payloads normally borrow. |
| `Value` | Scalar or object kind. An object value does not carry its identity. |
| `Change` | Header over borrowed encoded body bytes. |
| `doc.Built` | Owned change header, body, and actor table. Release with `deinit(gpa)`. |
| `doc.Changes` | Collection of owned changes. Release with `deinit(gpa)`. |
| `Stats` | Document counters, package name/version, and compiler version. |

`root` is `ExId.root`. Stable spellings use `_root` or `counter@hex-actor`.
Named equality and hashing use actor bytes and counter, not the cached actor hint.
`ExId.parse`, `fromBytes`, and `dup` own actor bytes. Release them with `deinitOwned(gpa)`.
Named counters and wire cursors accept `u64`. Resident counters and actor indices remain bounded by `u32`.
`ExId.opId()` returns null outside resident capacity. Wide IDs need not resolve to live objects.
`importObj` parses and resolves an ID. `import` also verifies its live object type.

`ActorId`, `Author`, and `ChangeHash` provide hex, formatting, and JSON codecs.
A `std.json.Parsed` arena owns its parsed views. Do not free those views separately.
Owned scalar conversions copy bytes. Release `OwnedScalarValue` and `value.OwnedValue` with `deinit(gpa)`.
`Value.object` carries only an `ObjType`. `asObject` and `asScalar` return optional payloads.
`fromCodepoint(gpa, cp)` owns UTF-8 and returns `InvalidCharacter` for an invalid scalar.

## Reads and scopes

`read.ReadDoc(R)` adapts `Document`, `Transaction`, and `AutoCommit` at compile time.
The `read` namespace supplies generic functions. Transactions and automatic documents also expose reader methods.
Core readers include `get`, `getAll`, `keys`, `values`, `length`, `text`, `marks`, `spans`,
`parents`, `mapRange`, `listRange`, `iter`, and cursor lookup.

Ordinary automatic reads see pending work without committing it.
Explicit historical heads select committed rows and exclude pending operations, including at current graph heads.
An empty head set selects empty history.
Nullable heads normally select the current read scope.
`hydrate(null)` instead reads raw current rows, including pending work, without an isolation clock.
Historical clocks remain stable across other reads. Mutation, actor remapping, isolation changes, and disposal invalidate them.
`ValueTerm` is caller-held query scratch. Separate `Values` walks must not share it.

| Result | Lifetime or cleanup |
| --- | --- |
| `DocItem` | Value and identity borrow the document. |
| `getAll` | Owns its outer array. Inner payloads can borrow. |
| `text`, `textAt` | Owned UTF-8 buffers, freed with the reader allocator. |
| `marks`, `marksAt` | Owned run array. Ordinary names and scalar payloads borrow. |
| `MarkSet` | `deinit()` frees set storage. `dup(gpa)` makes an independent copy. |
| `Keys.nextOwned(gpa)` | Owned key. A failed copy consumes the iterator step. |
| `MapRangeItem.intoOwned(gpa)`, `ListRangeItem.intoOwned(gpa)` | Copy keys, payloads, and identity actor bytes. Release with `deinit(gpa)`. |
| `DocObjItem.valueOwned(gpa)` | Copies only the value. Identity and key still borrow separately. |
| `Span` | Owns text, marks, or a complete hydrated block map. Release each with `deinit(gpa)`. |
| `Spans` | `deinit()` frees the iterator, not previously returned spans. |
| `hydrate` | Independent tree. Release with `hydrate.Value.deinit()`. |

`IndexRange { start, end }` is half-open. Null `end` means the object's end.
An inverted range yields no items.
`KeyRange` supports included, excluded, and unbounded byte-string bounds.
`between` is half-open. `through` is closed. Both range types provide `all()`.
`getCursorPosition` returns `InvalidCursor` for another object's cursor or an unrepresentable counter.
`getCursor` returns `InvalidIndex` for an invalid requested position.

## Writes and transactions

Writes are methods on `Transaction` or `AutoCommit`.
They include `put`, `putObject`, `insert`, `insertObject`, `increment`, `delete`, `splice`, `spliceText`,
`mark`, `unmark`, block edits, `updateText`, `updateObject`, and `updateSpans`.
A raw document requires an explicit transaction.
`put` returns null when no operation is created. `delete` returns an operation count, not text width.
`unmark(..., null)` removes the mark. A non-null value applies that value.
`SpanInput` borrows text, marks, or a full hydrated block map through the call.
`updateSpansWithConfig` applies per-mark expansion before the default expansion.

Open a borrowed transaction with `open(gpa, doc)`, `openAt(gpa, doc, heads)`, or `openWithPatchLog`.
Keep its document at the same address and do not mutate through another route.
`openWithPatchLog` transfers the log only after successful opening.
`baseHeads()` borrows transaction dependencies until disposal.
`textFor` borrows transaction-owned text until its next successful call or disposal.

`commit()` and `commitWith(options)` return an owned `transaction.CommitResult`:

- `hash: ?ChangeHash`, null for no writes.
- `patch_log: PatchLog`, the transaction's actual log.

Release the result with `deinit(gpa)`, including null-hash results.
`CommitOptions` has optional `message` bytes and signed Unix-second `time`.
The message must remain live through commit. Null time uses the transaction timestamp, initially zero.
`takePatchLog` requires a closed transaction.

Commit failure keeps the transaction open. A partial write failure can make it rollback-only.
Rollback is resumable. On failure, retain the journal and retry before reading document rows.
Writes and commit refuse during rollback.
`Transaction.deinit()` attempts rollback and can fail without consuming the transaction.
After successful commit or rollback, call `deinitClosed()`.
Do not use it to abandon pending rows in a live document.
`transaction.abort(tx)` provides an idempotent rollback helper.

### Closure and owned transactions

`enclose`, `encloseWith`, and `encloseWithPatchLog` accept a synchronous callback returning `E!O`.
Opening errors return without invoking it. The result is `TransactionError!Outcome(O, E)`.

- `success` owns the callback result, optional hash, and patch log.
- `failure` preserves the primary error, cancellation count, optional rollback error, optional recovery transaction,
  optional retained callback result, and terminal log.

A retained recovery transaction owns the real log. The separate failure log is inactive in that case.
Dispose callback results as their types require. Release each log or recovery transaction once.
Callbacks must not retain transaction pointers or reenter document mutation.
Options callbacks receive `*const O`. Returned message bytes must survive commit.

`OwnedTransaction.init(self, gpa, doc, heads)` consumes the source document only after successful opening.
Initialize it at its final address. Read and write through its `transaction` field.
Commit returns a document and `CommitResult`. Rollback returns a document, cancelled count, and log.
Failures retain recovery state. Its fallible `deinit()` rolls back before document disposal.

## Automatic documents

`AutoCommit` opens one transaction lazily and holds it across writes.
`commitWith` returns an optional hash and manages the transaction log internally.
`emptyChange(options)` creates a zero-operation change.
`rollback` retains progress on failure. `deinit` destroys the held journal and document together.
`cloneInto(gpa, destination)` copies pending state without closing the source.
Initialize the destination at its final address. Failure leaves it uninitialized and preserves the source.
`fromDocument` consumes a raw document without an externally held transaction.

| Operation | Pending transaction policy |
| --- | --- |
| Ordinary and historical readers | Stay open. Historical readers exclude pending work. |
| Inherent heads, changes, metadata, and change lookup | Close first. |
| Generic `read.getMissingDeps` and `read.getChangeByHash` | Stay open. |
| Save, incoming changes, incremental load, merge | Close first. Merge closes both documents. |
| Diff, diff cursor update/reset, isolate/integrate, setters, `document`, `dump` | Close first. |
| Sync generation/receive and `hasOurChanges` | Close first. |
| `cloneInto`, `pendingOps`, `baseHeads`, `diffCursor`, `makePatches`, identity getters, stats, imports, fragments, bundles | Stay open. |

`getHeads` reports the isolated view when isolated.
`hasOurChanges` compares ordered peer shared heads against full committed heads, ignoring isolation.
Automatic isolated commits advance the isolated view to the new change.

## Loading, storage, and history

`LoadOptions` defaults to refusal of partial loads, checked heads, no string migration, no external log,
platform-default text encoding, and no supplied author.
`verification_mode = .dont_check` skips stored-versus-derived head equality only.
Checksums, framing, columns, and physical operation order still require validation.
`loadUnverifiedHeads` forces that mode. Damaged head metadata need not remain saveable.
`loadIntoWithOptions` replaces the document only after successful preparation.
`rescue` relaxes mark-order validation and returns an independent hydrated value, without original history.

Full-load `.ignore` discards decoded tail changes after a partial decode.
It retains the first snapshot, or an empty document for a change-first stream.
Incremental loading into a nonempty document applies a decoded prefix and ignores a malformed tail.
Allocation and application failures remain errors.
Incoming apply, incremental load, and merge can retain a valid published prefix on failure.
Do not assume batch atomicity.

External-log variants borrow the log through the operation.
They reject incompatible sorted actor-table order with `PatchLogMismatch` before incoming mutation.
A log from another document can be compatible.
`validateActors` allocates nothing. `migrateActors` stages copied bytes and remapping before replacement.
A compatible retained trailing actor can still cause later patch rendering to return `InvalidActorIndex`.

`save`, `saveWithOptions`, `saveAfter`, and `saveIncremental` return owned buffers.
Compressed save bytes need not match the reference. Compare reloaded state, heads, and normalized change bodies.
Change hashes and sync encoding target the reference format.
`getChanges` excludes the supplied heads and their dependencies, with dependencies before dependents.
`getChangesByHashes` preserves request order and repeated hashes, returning independent owners for every occurrence.
An unknown requested hash returns `MissingDeps`. Release the collection with `Changes.deinit(gpa)`.
`getChangeByHash` returns null for an absent hash.

`doc.ChangeMetadata` owns actor bytes, author, message, dependencies, and extra bytes.
Release it with `deinit(gpa)` or its collection with `ChangeMetas.deinit(gpa)`.
`timestamp` is signed Unix seconds. Operation intervals are inclusive.
An empty change has `max_op = start_op - 1`.
`Change.author(gpa)` returns null for an absent, unknown, or malformed author footer.
Footer column parsing errors still propagate. Opaque footer bytes remain authoritative.
`getActors`, `getAuthors`, and `getActorForAuthor` return owned outer arrays with borrowed byte views.
`setAuthor` copies bytes and draws a new actor when the author changes.
Entropy failure preserves the current author and actor.

`hashForOpid` allocates nothing. Root, unknown, and pending IDs return null.
`bundleFragments` returns an owned outer array and owned buffers.
It omits unrebuildable fragments but propagates `OutOfMemory`.
`initFromHydrate` returns a complete transaction outcome and retains existing keys absent from the input.
`dump` and `diffOpSet` write diagnostics through a caller writer. A writer failure can leave partial output.
`anonymize` takes an explicit 32-byte seed.

## Text, patches, and hydrated values

Native text indexing supports code points, UTF-8 units, UTF-16 units, and grapheme clusters.
`TextEncoding.platformDefault()` follows the build option, defaulting to `unicode_code_point`.
Document files do not store that choice.
`ConcreteTextValue` stores native units. UTF-8 bytes and UTF-16 surrogate halves can survive individual edits.
Stored grapheme boundaries do not change after adjacent edits.
`makeString(gpa)` returns owned lossy UTF-8. `len()` counts native units.
`initOwned` consumes input bytes only on success. Grapheme views borrow until mutation or disposal.

`diff` and `diffObj` return independent `Patches` owners. Release them with `deinit()`.
Automatic diffs cache one canonical range/object key. Cache hits still return deep copies.
Mutation invalidates the cache. Failed replacement preserves its previous contents.
`diffIncremental` advances its cursor only after successful output.
`makePatches` borrows a compatible log and returns independent patches.
`Patches` owns output paths, identities, scalars, marks, and native text trees.

`PatchLog.active`, `inactive`, `nullLog`, and `init` retain their allocator.
Release logs with `deinit()`.
`prepareLocal` returns an owned stage. Release it on failure or transfer it to `commitLocal`.
A `PatchBuilder` consumes its seed `PathMap`.
Patch rendering can consume the log's first-use path-map seed.
Batch stages require the same target log address at preparation and publication.
Do not move a log with a live stage.

`hydrate.Value` has flat scalar tags and map/list/text composite payloads.
`Value.init` and `dup` return `hydrate.OwnedValue`, whose `deinit()` uses its retained allocator.
`Map.putOwned` copies keys and unowned scalar bytes, then transfers composite storage on success.
On failure the caller retains the register. Use `dup` when the source must remain independent.
Patch application preserves a valid action prefix on failure.
`MarkSet.nonDeletedMarks()` is an allocation-free borrowed view that ignores null tombstones.
Keep the source live and unchanged.

## Sync and serialization

`sync.state.State` owns per-peer protocol state. `sync.message.Message` owns a message and optional body.
Create a separate state for each peer. Dispose both owners with their `deinit()` methods.
`encode` returns caller-owned bytes. `State.their()` borrows views until state mutation.
`MessageBuilder.setHeads`, `setNeed`, and `setHave` consume their input slices.
`receiveSyncMessage` consumes its message on every path, including failure.
Document and state can retain a valid applied prefix.
Logged receive borrows its log and rejects incompatible projected actor order before incoming mutation.
`AutoCommit.sync()` returns a borrowed wrapper after closing pending work.
V1 operations also exist in `sync.v1`. `State.setReadOnly(bool)` controls read-only state.

`Change.decode(gpa)` returns owned `ExpandedChange`. Release it with `deinit(gpa)`.
Expanded encoding returns `doc.Built` and recomputes the hash.
`extra_bytes` is authoritative. Parsed `hash` and `author` do not alter encoding.
`Change.fromBytes` returns owned `Built`. `rawBytes` and `compressedBytes` return owned buffers.
`actorsOwned` requires release of each actor buffer and its outer array.

`autoserde.AutoSerde(R).from(reader)` borrows a `ReadDoc` implementation.
`toJson(gpa)` returns compact owned JSON. `writeJson(gpa, writer)` borrows its writer.
Compile-time serializer backends support map, sequence, string, and scalar operations.
They must consume or copy borrowed payloads during each call. Discard partial output after a failure.
Serialization does not close pending transactions.
Sync serde emits `heads`, `need`, `have`, and `changes`. Each `Have` emits `last_sync` and `bloom`.

## Low-level packing

`hexane` exposes the RLE, boolean, delta, slab, and column modules.
Default factories use `rle.Leb128`, backed by `src/leb128.zig`.
`RleWith`, `BoolWith`, `DeltaWith`, and payload helpers accept a compile-time packing type.
It must implement the required signed/unsigned read, write, append, size, and maximum-size declarations.
Reads consume a positive in-bounds byte count and use `ParseError`.
`slab.rewrite_lit_header(P, gpa, buf, header_pos, total)` uses that same packing type.
Only LEB128 ships for document storage. Alternate packing does not select another document format.

## Errors and limits

Entry points declare their own initialization, read, write, load, diff, patch, and protocol error sets.
Parsing untrusted bytes must return typed errors rather than panic or loop.
Capacity, allocation, read, and application errors can also propagate from malformed input.
Error returns do not imply rollback of earlier application work.
Low-level operation arithmetic retains its declared preconditions.
These experimental APIs do not promise complete upstream behavior or unlimited resident capacity.

## C ABI

The default build installs `libzautomerge.a` and `include/automerge.h`.
The production root is `src/c/root.zig`. The variadic `AMresultFrom` implementation comes from `src/c/result_from.c`.
`AMdoc` uses the native automatic lifecycle. Ordinary reads leave pending writes open.
History, save, setters, and sync close pending work. `AMclone` preserves pending state independently.
`AMrollback` returns zero if rollback fails, retaining its journal for retry.
The C bridge selects UTF-8 code-unit indexing.
`AMresultFree` releases result-owned handles. Keep results live while using their borrowed items and bytes.
See the installed header for individual C signatures and callback contracts.

C calls from different threads must share one caller-owned global lock, even across distinct handles.
The bridge uses one process-wide single-threaded `std.Io` provider and has no internal lock.
Hold the lock through each outer call, its callbacks, and its return.
A synchronous `AMstackCallback` can inspect its borrowed stack/result and advance a local item cursor on the calling thread.
Nested inspection uses the existing lock without reacquiring or releasing it.
Diagnostic copies from `AMstrdup` use `free`.
The callback must preserve stack/result ownership and links until the outer call returns.
Do not pop, free, replace, or relink borrowed nodes. A false return leaves ownership with the stack.
Do not retain the stack-parameter address. The null-stack path uses temporary storage and releases the result afterward.
Keep callback code and accessed context live through their last use. No general mutation or cross-thread reentrancy is permitted.

Header checks compile separately from the production artifact.
The static C suite links the production library. The shared fixture consumer uses a separate dynamic library.
See [test/c/README.md](test/c/README.md) for their commands and scope.
