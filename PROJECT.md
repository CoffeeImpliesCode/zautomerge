# zautomerge

A direct Zig 0.16 translation of the `automerge` library: a JSON-like CRDT
that several devices can edit concurrently and merge without conflict
resolution code, with an efficient binary document format and a sync protocol
for any reliable in-order transport.

The upstream reference is `automerge` 0.12.0 plus its `hexane` storage engine,
checked out read-only at `../github-automerge-automerge` (commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`, MIT, with one Apache-2.0 vendored
file). This repository is the Zig port, not a wrapper.

## Implemented

**1228** tests pass in the library suite, **6** in the fixture suite, **3** in
the crate-root example suite and **117** in the ported upstream
`tests/test.rs` suite (`zig test -ODebug -Mroot=src/root.zig`, measured
2026-10-01). What exists today:

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
  built on. The forward-only edit cursor holds one slab open across a batch —
  one partition, one byte splice, one index update — and abandoning it
  mid-batch leaves the column sound.
- **The wire formats.** The sync message, the bloom filter and the per-peer
  sync state: the payload-bearing records in `test/golden/sync.jsonl` decode and
  re-encode byte-identically. The mark value types and the fold; the vendored
  Myers text diff with its Apache-2.0 notice.
- **The op set and the merge.** Fifteen modules under `src/opset/`: the row
  and its `Op.step` row-order invariant, the sixteen data columns and five
  index columns, the mark index and its cache, the row iterators, the index
  rebuild, the visibility and winner iterators, the query surface, the op set
  root with both invariant checkers, and the merge with its two walkers. Both
  checkers are demonstrated failing, and a merge is checked against the same
  operations applied one change at a time.
- **The C binding's contract.** `include/automerge.h` and `src/c/result.zig`,
  with every enum discriminant proved by generating the reference's own header
  with cbindgen at the pinned version and diffing.

- **The iteration toolkit and the range readers.** `Unshift`, `PeekShift`,
  `SkipIter`, `Diff`, `DiffIter` and `Shiftable`; a map's keys, a sequence's
  visible elements with their widths, and the text spans a caller renders.
- **The patch layer and the hydrate mirror.** All nine patch actions, the
  expose queue, and a patch stream replayed into a materialised mirror — with
  the log dropped before the mirror is read, so the round trip is a test of
  the patch layer rather than of the mirror.
- **The cursor**, with the v1 codec pinned as literal bytes in both
  directions and the legacy v0 parser alongside.

**What is not written** is narrower than it was, and the list below has
**shrunk three times over** — a record whose reason has expired is a defect, so
expired records are deleted rather than amended. Still open, and named in
`API.md` §Known gaps: `Automerge::get_authors` (`automerge.rs:410`, which is
`&[Author]`, not the actor-id list this port has), a document-level `hydrate`,
a document-level `bundle`, and `AutoCommit::diff_cache` (deliberately, and
§Diffing of `API.md` says why).

**Three of the six items this list used to carry are now closed.** The `_at`
historical variants are ported — fourteen readers plus
`Document.clockAtScope`, upstream's `Automerge::clock_at`
(`automerge.rs:1236-1247`). `UpdateSpansConfig` is `src/marks.zig:731`, and
`transact.updateSpansWithConfig` / `Transaction.updateSpansWithConfig` thread it
to the mark pass without changing any other signature.
`ReadDoc::iter_at` and `DocIter` are **not the same gap and must not be counted
as one**: the walk itself is ported — `DocIter` and its six item types in
`src/iter/doc.zig`, upstream's `doc_iter` (`iter/doc.rs:532-602`) transcribed
with all 22 answers — while the document-layer **entry point**
`Automerge::iter` (`automerge.rs:1669-1674`) is still not ported. `DocIter.init`
takes the op-set-and-encoding handle instead, which is all `iter/doc.rs` ever
reaches a document for (`iter/doc.rs:44,100,186`).
The read, transact and transaction surfaces, all six iterators, sync's state
machine, `anonymize.zig`, `autoserde.zig` and the C ABI are all written, wired
and passing — including `src/doc.zig`'s change encoder, proved byte-exact
against the reference in both directions. **The gates, and what does and does
not meet them, are in [docs/STATUS.md](docs/STATUS.md) and
[docs/plan.md](docs/plan.md).**

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
| P6 | the document and transaction API | every `ReadDoc` and `Transactable` method tested |
| P7 | iterators and historical reads | `text.rs` **21/21** and `text_encoding.rs` **15/15** ported, verified case by case; **34 of the 36 run under all four `TextEncoding`s**, the two exceptions named and reasoned in `docs/STATUS.md`. **The `8/21` and `10/15` this row carried until 2026-10-01 were wrong in both halves** — the cases were already in the tree. |
| P8 | sync, including v1 compatibility | convergence, cross-implementation sync both ways |
| P9 | patches, marks, cursors, text diff, hydrate, serde | `diff_marks.rs` **36/36** and `test_mark_patches.rs` **1/1** — gate met |
| P10 | the C ABI | the upstream C test suite passes: **153/153** cmocka cases |

## Compatibility contract

- A document written by `automerge` 0.12.0 loads here, and one written here
  loads there.
- Sync states interoperate in both directions, including with a v1-only peer.
- Change hashes match the reference byte for byte, because a change hash is
  SHA-256 over the encoded change.
- `save()` output is **not** byte-identical: DEFLATE is not reproducible across
  implementations, and equivalence is checked by loading and comparing the
  materialized document instead.

## Commands

Run at the repository root:

- `zig build` makes the `zautomerge` module available to consumers. It
  installs no artifact.
- `zig build test` runs the unit tests.
- `zig build conformance` drives the oracle once per vector and checks each
  against the copy committed in `test/golden/`; `zig build conformance --
  <name>` checks one. `-Dconformance-record` rewrites them from the reference
  instead. `zig build conformance -- fixtures` prints the 18 corpus results the
  manifest records.
- `zig build ctest` builds and runs the upstream cmocka suite. It needs
  `-Dcmocka-prefix` (pointing at a cmocka built by `test/c/build-cmocka.sh`)
  **and an absolute** `LD_LIBRARY_PATH` including that prefix's `lib64`, because
  the step sets no rpath. **The step's working directory is `test/c/suite`, so a
  relative path on either variable resolves against that directory**: the binary
  compiles and then fails to launch with `libcmocka.so.0: cannot open shared
  object file` and the step reports **exit 127** — a build failure that is not
  one.
- `zig fmt --check .` checks formatting. `gate` runs the house gate.
- `jj st` shows working-copy status. Use `jj`, not raw Git, for mutations.

The read-only reference checkout is `$AUTOMERGE_REF` when that names a
checkout, and otherwise the one beside this repository,
`../github-automerge-automerge`; `tools/link-oracle.sh` names both when it
finds neither. Never build in the checkout and never modify it.

This project declares its development dependencies in `devenv.nix`. Do not
install system or development libraries imperatively. Use direnv or
`devenv shell`; run `direnv allow` after changing the environment.
