# zautomerge

A direct translation of the `automerge` library into **Zig 0.16.0**: a
JSON-like CRDT that several devices can edit concurrently and merge without
conflict resolution code, with an efficient binary document format and a sync
protocol for any reliable in-order transport. **0.16.0 is the only toolchain
this repository claims**, and `build.zig.zon` says so in its
`minimum_zig_version`. Nothing here asserts anything about a later or earlier
Zig, a different target, or a different compiler: if a claim about the
toolchain cannot be checked by running something on 0.16.0, it does not go in.

The upstream reference is `automerge` 0.12.0 plus its `hexane` storage engine,
checked out read-only at `../github-automerge-automerge` (commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`, MIT, with one Apache-2.0 vendored
file). This repository is the Zig port, not a wrapper.

## Implemented

The current API-design repair uses Zig 0.16.0 on x86-64 Linux.
[docs/STATUS.md](docs/STATUS.md) records its source, compilation, and runtime evidence.
Earlier measurements remain labeled with their dates. They do not certify this revision.
The published contract and consumer costs are in [API.md](API.md#api-design-decisions).

- **The contract.** `error.zig` with the three error sets, `types.zig` with the
  identity and value types, `value.zig`, `clock.zig`, `leb128.zig` written from
  scratch because Zig's std has none, and `unicode.zig` with UAX #29 grapheme
  clustering.
- **The conformance harness.** The 18 upstream fixture files with a manifest of
  what loading each must do, and a Rust oracle that drives the reference
  implementation for byte-for-byte comparison.
- **The storage engine.** The four slab codecs, the B=64 slab btree with its
  invariant checker, the slab and the generic column, and the columnar
  encoding layer that maps the document's eight column tags onto them.
- **The change layer.** The change record, the actor table, the change graph
  with its cached clocks, and the topological sort that puts arriving changes
  in dependency order.

- **The format layer.** `storage/parse.zig`, `storage/chunk.zig`,
  `storage/column_spec.zig`, `storage/change_chunk.zig`,
  `storage/document_chunk.zig` and `storage/bundle.zig`. The document chunk
  reproduces the reference's own `save()` output byte for byte, and a bundle
  written here loads in the Rust reference and one the reference writes loads
  here, both proved by running the reference.
- **The hexane completion.** The byte arena, the Fenwick weight index, and the
  column read surface — ranged iteration, prefix arithmetic, run iteration,
  position scoping, value and range search, actor remapping, default-suppressing
  export, and the `Shiftable` repositioning abstraction the iteration phase is
  built on. The forward-only edit cursor holds one rebuild across a batch.
  Publication stages replacement buffers and slab/index metadata. Abandoning
  the cursor discards its held rebuild, not batches already published.
- **The wire formats.** The sync message, the bloom filter and the per-peer
  sync state: the payload-bearing records in `test/golden/sync.jsonl` decode and
  re-encode byte-identically. The mark value types and the fold; the vendored
  Myers text diff with its Apache-2.0 notice.
- **The op set and the merge.** Fifteen modules under `src/opset/`: the row
  and its `Op.step` row-order invariant, the sixteen data columns and the five
  index columns maintained alongside them (the mark index's extra resource is a
  cache, not a column), the mark index and its cache, the row iterators, the index
  rebuild, the visibility and winner iterators, the query surface, the op set
  root with both invariant checkers, and the merge with its two walkers. Both
  checkers are demonstrated failing, and a merge is checked against the same
  operations applied one change at a time.
- **The C binding, as a shipped artifact.** `include/automerge.h` (installed as
  `automerge.h`) and `src/c/result.zig`, with every enum discriminant proved by
  generating the reference's own header with cbindgen at the pinned version and
  diffing. `zig build` installs the static library `libzautomerge.a` from the
  production root `src/c/root.zig`; `test/c/cabi.zig` is a **separate** library
  that compiles the real header and checks name existence, by-value layout, enum
  discriminants and the comparable signatures; `zig build ctest` links the
  artifact and runs the cmocka suite. **Calls from different threads must share
  one caller-owned global serialization boundary**, even across distinct handles,
  because the bridge binds one process-wide
  `std.Io.Threaded.global_single_threaded.io()`. Hold the lock through the outer
  call and its callbacks. An invoked `AMstackCallback` may synchronously inspect
  its live stack/result and advance a local borrowed cursor on the invoking
  thread under that already-held lock, without reacquiring or releasing it.
  Preserve stack/result ownership and links; no general mutation, other
  reentrancy or cross-thread entry is permitted. The header's callback contract
  states the keep-live rules, including the temporary null-stack path.
  Inspection includes result diagnostics and an `AMstrdup` diagnostic copy,
  released with `free`, not destruction of the borrowed stack or result.

- **The iteration toolkit and the range readers.** `Unshift`, `PeekShift`,
  `SkipIter`, `Diff`, `DiffIter` and `Shiftable`; a map's keys, a sequence's
  visible elements with their widths, and the text spans a caller renders.
- **The patch layer and the hydrate mirror.** All nine patch actions, the
  expose queue, and a patch stream replayed into a materialised mirror — with
  the log dropped before the mirror is read, so the round trip is a test of
  the patch layer rather than of the mirror.
- **The cursor**, with the v1 codec pinned as literal bytes in both
  directions and the legacy v0 parser alongside.

**What is not written is narrower than it was, and the list below has shrunk
repeatedly** — a record whose reason has expired is a defect, so expired records
are deleted rather than amended. **Exactly one item remains, and it is a
deliberate omission rather than a hole**: `AutoCommit::diff_cache` is not
ported, `API.md` §Diffing argues why from the port's `Patches` ownership, and
that argument makes **no performance claim** — nothing in this repository
measures a cached diff against an uncached one.

**Six items this list used to carry are closed**, and three of them were closed
in the tree before this paragraph was last read:
  - `Automerge::get_authors` (`automerge.rs:410`) is `Document.getAuthors(gpa)
    Error![]const []const u8` — the array is the caller's, the names are the
    document's arena — and it sits beside `getActors(gpa) Error![]ActorId` for
    the actor-id list. **Both** exist; the earlier version of this file claimed
    neither did the first.
  - The document-level **entry point** `Automerge::iter` /
    `ReadDoc::iter_at` (`automerge.rs:1669-1674`, `read.rs:60`) is
    `read.iter(doc, gpa)` and `read.iterAt(doc, obj, heads, gpa)`; the walk it
    returns is `src/iter/doc.zig`'s `DocIter` with its six item types,
    upstream's `doc_iter` (`iter/doc.rs:532-602`). The claim that only the walk
    existed and the door did not was out of date.
  - The document-level **bundle** `Automerge::bundle(hashes)`
    (`automerge.rs:1141`) is `Document.bundle(gpa, hashes)
    DocumentError!Bundle`, and the fragment API beside it —
    `Document.fragments`, `getFragment`, `bundleFragments` over
    `change_graph.zig`'s `Fragment` — is ported too. The caller owns the bundle,
    the fragment array and each fragment's buffers.
  - The `_at` historical variants: fourteen readers plus
    `Document.clockAtScope`, upstream's `Automerge::clock_at`
    (`automerge.rs:1236-1247`).
  - `UpdateSpansConfig` is `src/marks.zig`'s `UpdateSpansConfig`, and
    `transact.updateSpansWithConfig` / `Transaction.updateSpansWithConfig` thread
    it to the mark pass without changing any other signature.
  - The entry point into the hydrate mirror, `read.hydrate`, is
    `ReadDoc::hydrate` (`read.rs:273-277`).

The read, transact and transaction surfaces, all six iterators, sync's state
machine, `anonymize.zig`, `autoserde.zig` and the C ABI are all written and
wired — including `src/doc.zig`'s change encoder, proved byte-exact against the
reference in both directions by running the reference. "Passing" is a dated
measurement: see the note at the top of this section and
[docs/STATUS.md](docs/STATUS.md). **The gates, and what does and does not meet
them, are in [docs/STATUS.md](docs/STATUS.md) and [docs/plan.md](docs/plan.md).**

### Six contract decisions and their consumer costs

1. **A constructor takes a borrowed `std.Io` and the document keeps it.**
   `Document.init(gpa, io, mode)` and `initWithEncoding(gpa, io, encoding, mode)`
   answer `InitError` — exactly `Allocator.Error || std.Io.RandomSecureError` —
   and `load(gpa, io, bytes, encoding, mode)` answers `LoadError`, because it
   parses after it builds. **Caller cost: hold a live capability for the
   document's lifetime.** A test passes `std.testing.io`; an executable passes
   its own; the C bridge passes its process-wide single-threaded provider.
2. **A fresh document draws a secure 16-byte actor id and a refusal is an
   error.** `ActorId.random(gpa, io)` has no weaker fallback, and
   `error.Canceled` / `error.EntropyUnavailable` are `Error` variants rather
   than the panic upstream raises. **Caller cost: handle two refusals that used
   to be impossible**, and use `Document.setActorId` wherever the id must be
   deterministic.
3. **A refused commit leaves the transaction open and a rollback is resumable.**
   **Caller cost: `Failure(O)` is a five-field struct, not `{ err, cancelled }`**
   — `rollback_error`, a recovery `transaction` and the retained `result` all
   have to be read. A refused rollback hands the caller a progressed
   transaction to finish, not an unusable document.
   Native automatic wrappers retain published or queued work in
   `Document.auto_recovery` without allocating. `recoverAuto()` retries rollback;
   the next native write recovers before assigning new IDs. Keep the document
   at its address and do not read rows until recovery finishes. Disposal frees
   the retained owner without attempting rollback.
4. **`Document` is single-owner.** No shallow copy; a move only while no borrow
   of its address remains. **Caller cost: hold a `*Document`, and use `clone` /
   `fork` / `forkAt` for a second owner.**
5. **The C ABI is a shipped artifact with a global threading contract.**
   **Caller cost: a C consumer links `libzautomerge.a` and `automerge.h`, and
   uses one global serialization boundary for calls from different threads,
   even across distinct handles**, because the bridge's `std.Io` provider is
   process-wide and single-threaded. Synchronous stack/result inspection by an
   invoked `AMstackCallback` on the invoking thread stays under the outer call's
   already-held lock and must not reacquire or release it. Keep the stack/result
   live and preserve ownership and links; this is not general mutation, other
   reentrancy or cross-thread entry. The Rust crate's `Send`/`Sync` story does
   not transfer.
6. **Text values remain UTF-8-backed.** `ConcreteTextValue.removeRange` deletes a complete encoded span atomically.
   **Caller cost:** use scalar or current grapheme boundaries. A split UTF-16 surrogate returns `error.InvalidCharacter`.
   An ordinary owner releases the old buffer only after a replacement changes its pointer.
   Zero-length and out-of-range deletions retain the buffer.
   `hydrate.Text` handles this ownership itself.
   This representation does not support arbitrary native-unit edits or preserve Rust's stored grapheme units.

## Planned

The full port of the `automerge` and `hexane` crates, phase by phase, is in
[docs/plan.md](docs/plan.md). The short version:

| Phase | Delivers | Gate |
| --- | --- | --- |
| P0 | scaffold, fixtures, Rust oracle for differential testing | `zig build test`, `zig build conformance` |
| P1 | types, values, errors, clocks, LEB128, SHA-256, DEFLATE | property tests against the oracle |
| P2 | `hexane`: slabs, columns, RLE, bool, delta, prefix, the btree, the edit cursor | codec round trips, btree invariants |
| P3 | columnar encoding, chunk framing, document and change chunks | all 17 corpus fixtures load with the recorded outcome, all 8 fuzz crashers return `ParseError` |
| P4 | change graph, change encoding | change hashes byte-identical to the reference |
| P5 | the op set, merge, batch apply | `tests/test.rs` **140/140** and `tests/batch_insert.rs` **46/46** ported; the gate's `save()`-modulo-DEFLATE clause is not asserted |
| P6 | the document and transaction API | every `ReadDoc` and `Transactable` method tested, and every constructor call site supplies a live `std.Io` — a test with `std.testing.io`, an executable with its own, the C bridge with its process-wide provider |
| P7 | iterators and historical reads | `text.rs` **21/21** and `text_encoding.rs` **15/15** ported, verified case by case; **34 of the 36 run under all four `TextEncoding`s**, the two exceptions named and reasoned in `docs/STATUS.md`. **The `8/21` and `10/15` this row carried until 2026-10-01 were wrong in both halves** — the cases were already in the tree. |
| P8 | sync, including v1 compatibility | convergence, cross-implementation sync both ways |
| P9 | patches, marks, cursors, text diff, hydrate, serde | `diff_marks.rs` **36/36** and `test_mark_patches.rs` **1/1** — gate met |
| P10 | the C ABI | `zig build ctest` runs the upstream C suite against the production artifact and compiles the real header's 187 function signatures, 37 enum names across five enums, and five exposed struct layouts. **A green suite alone is not this gate**: linking does not prove layout or signature parity. |

## Compatibility contract

- A document written by `automerge` 0.12.0 loads here, and one written here
  loads there.
- Sync states interoperate in both directions, including with a v1-only peer.
- Change hashes match the reference byte for byte, because a change hash is
  SHA-256 over the encoded change.
- `save()` output is **not** byte-identical: DEFLATE is not reproducible across
  implementations, and equivalence is checked by loading and comparing the
  materialized document instead.


**Licensing.** The root `LICENSE` is the MIT licence of the Automerge
contributors and ships with the package (`build.zig.zon`'s `paths` includes
it). `src/textdiff/LICENSE` is a **separate, vendored Apache-2.0** notice for
the Myers text diff ported from `mitsuhiko/similar`, and
`test/c/suite/LICENSE` is upstream's own for the vendored C test tree. **Three
licences, three files, and none of them may be merged or dropped**: the MIT
root licence does not cover the vendored Apache code and does not cover the
vendored C suite.

## Commands

Run at the repository root:

- `zig build` makes the `zautomerge` module available to consumers **and
  installs one artifact plus one header**: the static library
  `libzautomerge.a`, built from the production root `src/c/root.zig`, and
  `automerge.h` from `include/`. The package's `paths` in `build.zig.zon` list
  `build.zig`, `build.zig.zon`, `src`, `include` and `LICENSE`, so a consumer
  that takes the package takes the header and the licence with it. **The native
  module's name is unchanged** — `zautomerge` — and it is a separate thing from
  the C library that happens to share the name.
- `zig build test` runs the unit tests.
- `zig build conformance` drives the oracle once per vector and checks each
  against the copy committed in `test/golden/`; `zig build conformance --
  <name>` checks one. `-Dconformance-record` rewrites them from the reference
  instead. `zig build conformance -- fixtures` prints the 18 corpus results the
  manifest records.
- `zig build ctest` builds the production library, **builds the separate ABI
  check library against the real header**, links the suite against the
  production artifact, and runs the cmocka suite. It needs `-Dcmocka-prefix`
  (pointing at a cmocka built by `test/c/build-cmocka.sh`); the prefix is
  absolutised inside the build and `each_lib_rpath` is set, so
  `libcmocka.so.0` resolves from the binary's own RUNPATH and **`LD_LIBRARY_PATH`
  is not required**. A relative `-Dcmocka-prefix` works for that reason. **The
  step's working directory is `test/c/suite`**, which is why an absolute path
  used to be needed at all, and why a prefix that reached the binary as a
  relative RUNPATH entry produced exit 127 — a build failure that is not one.
  A usable prefix is the sibling `../cmocka-prefix`.
- `zig fmt --check .` checks formatting. `gate` runs the house gate.
- `jj st` shows working-copy status. Use `jj`, not raw Git, for mutations.

The read-only reference checkout is `$AUTOMERGE_REF` when that names a
checkout, and otherwise the one beside this repository,
`../github-automerge-automerge`; `tools/link-oracle.sh` names both when it
finds neither. Never build in the checkout and never modify it.

This project declares its development dependencies in `devenv.nix`. Do not
install system or development libraries imperatively. Use direnv or
`devenv shell`; run `direnv allow` after changing the environment.
