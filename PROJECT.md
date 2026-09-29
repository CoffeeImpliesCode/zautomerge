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

Nothing yet. The first commit is the project scaffold: the build, the Nix
environment, and the survey and plan documents.

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
