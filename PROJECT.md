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

279 tests pass. What exists today:

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

`src/storage/change_chunk.zig` is half-written and does not compile; it is kept
on disk, unwired, and [docs/STATUS.md](docs/STATUS.md) records exactly what is
wrong with it. Everything else in the tree builds and passes.

**Not yet written:** the op set, the document API, the iterators, sync, patches,
and the C ABI. The order and the gates are in [docs/STATUS.md](docs/STATUS.md).

## Planned

The full port of the `automerge` and `hexane` crates, phase by phase, is in
[docs/plan.md](docs/plan.md). The short version:

| Phase | Delivers | Gate |
| --- | --- | --- |
| P0 | scaffold, fixtures, Rust oracle for differential testing | `zig build test`, `zig build conformance` |
| P1 | types, values, errors, clocks, LEB128, SHA-256, DEFLATE | property tests against the oracle |
| P2 | `hexane`: slabs, columns, RLE, bool, delta, prefix, the btree, the edit cursor | codec round trips, btree invariants |
| P3 | columnar encoding, chunk framing, document and change chunks | all 17 fixtures, all 8 fuzz crashers rejected |
| P4 | change graph, change encoding | change hashes byte-identical to the reference |
| P5 | the op set, merge, batch apply | 186 ported upstream tests, save bytes match |
| P6 | the document and transaction API | every `ReadDoc` and `Transactable` method tested |
| P7 | iterators and historical reads | 35 ported text and encoding tests |
| P8 | sync, including v1 compatibility | convergence, cross-implementation sync both ways |
| P9 | patches, marks, cursors, text diff, hydrate, serde | 37 ported mark and patch tests |
| P10 | the C ABI | the upstream C test suite passes |

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
- `zig build conformance` runs the oracle and regenerates the golden vectors
  under `test/golden/` (P0 and later; the step does not exist yet).
- `zig fmt --check .` checks formatting. `gate` runs the house gate.
- `jj st` shows working-copy status. Use `jj`, not raw Git, for mutations.

`AUTOMERGE_REF` points at the read-only upstream checkout and is set by the Nix
environment. Never build in it and never modify it.

This project declares its development dependencies in `devenv.nix`. Do not
install system or development libraries imperatively. Use direnv or
`devenv shell`; run `direnv allow` after changing the environment.
