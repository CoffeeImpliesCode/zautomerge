# Automerge API survey

Eight sections, one per slice of the reference implementation. Every claim
carries a `path:line` citation into the Rust source at commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`. Read the section that covers your
change before working on it; the [plan](../plan.md) cites them by section.

Source: `../github-automerge-automerge`, read-only. Crate `automerge` 0.12.0
(64,979 lines, 163 files) and `hexane` 1.0.0-alpha.5 (32,664 lines, 39 files),
plus the binding layers.

| Section | Covers |
| --- | --- |
| [01 Core public API and value model](01-core-api.md) | the crate root and its 57 re-exports, `ReadDoc` (**34** methods), `Transactable` (**20** methods), `ExId` / `ActorId` / `OpId` / `ObjType` / `Prop` / `ScalarValue` / `Value`, `Clock` and `SeqClock`, `Change` metadata, all 13 error types |
| [02 Transaction machinery and the op set](02-transaction-opset.md) | `Transaction` and `TransactionInner`, `Automerge` and `AutoCommit`, `ChangeGraph`, `ChangeQueue`, the whole `op_set2` tree, the 16 op columns, `MapWalker` and `Untangler`, `BatchApply` |
| [03 Storage engine and the columnar format](03-storage-columnar.md) | chunk framing, `ColumnSpec`, raw and composite columns, the document chunk, the change chunk, compression, the parse combinators, bundle storage |
| [04 Sync protocol and change exchange](04-sync.md) | `SyncDoc`, `Message` v1 (`0x42`) and v2 (`0x43`), `State`, `BloomFilter`, the message byte layouts, the state machine, the v1 compatibility layer |
| [05 Iteration, queries, patches, text diff](05-iter-query-patch.md) | the diff iterators, `ReadDoc`, `PatchLog` and `PatchBuilder`, the vendored Myers diff, `Mark`, `Cursor`, `hydrate`, `autoserde`, `anonymize` |
| [06 hexane, the storage engine](06-hexane.md) | the B = 64 slab btree, `Column` and `Slab`, the RLE, boolean, delta and prefix codecs, `RawColumn`, the edit cursor, `splice` |
| [07 Bindings](07-bindings.md) | the 166-function `automerge-c` ABI, the wasm-bindgen surface, the JavaScript package, the CLI, `interop/`, the Nix flake |
| [08 Conformance, test topology, history](08-conformance-history.md) | 293 integration tests, the in-file test modules, 17 upstream fixtures, the fuzz targets, the changelog as the compatibility contract, the feature matrix, CI |

## What the survey found that changes the plan

- The on-disk format is a bare stream of self-delimiting chunks. There is no
  chunk table, no index, no footer, and no format-version field, so every
  encoder constant is a compatibility boundary and the change hash is the
  content hash (03).
- `automerge` stores its op set in `hexane` columns, so `hexane` is not an
  optional extra; it is the storage engine (02, 06).
- The text diff is a vendored Apache-2.0 port of `mitsuhiko/similar`, not
  diff-match-patch, despite the directory name (05).
- UTF-8 versus UTF-16 indexing is a silent cross-binding divergence in the
  upstream bindings, with no test reading a document through both (07).
- `interop/exemplar` is the only cross-implementation artefact in the
  repository, and nothing asserts against it (08).
- Three chunks of upstream are dead code and are not ported:
  `op_set2/skip_list.rs` (20,160 bytes), `query/` (`list_state.rs`,
  `seek_mark.rs`, 372 lines) and `indexed_cache.rs` (02, 05, 06). The fourth
  entry this list used to carry — "two `hexane` features" — **was wrong**:
  `bijou64` is read at `hexane/src/codec.rs:358` and `:362` and `deep_fuzz` at
  `edit_fuzz.rs:493`, `:1142` and four places in `tests.rs`. Neither is dead;
  `Bijou64` is simply a codec nothing selects.

## Re-measured 2026-10-01

A gate-by-gate audit of `docs/plan.md` re-derived the survey's claims against
the reference. The survey's **content** held up well — every wire format,
column id, bit position and field width in 03 and 06 was re-checked and is
correct, and `Automerge::exid_to_opid` now carries the `lookup_actor` fallback
the reference has. What did not hold up was the bookkeeping, and it is
corrected here and in the section files:

- **25 count and path claims were wrong** — including `AutomergeError` at 31
  variants (not 30), `TextEncoding`'s real variant names in 02
  (`Utf8CodeUnit` / `Utf16CodeUnit`, not `Utf8` / `Utf16`), three file paths
  that do not exist upstream, and three slice totals that do not match their
  own tables. `ReadDoc` has **34** methods and `Transactable` **20**, not 30
  and 21.
- **`path:line` citations are the remaining risk and were not all fixed.**
  Of 144 sampled, **65** point at the wrong code. The drift is file-local and
  one-directional in each file (01 runs 10–25 lines early on `marks.rs`,
  `cursor.rs` and `patch.rs`; 05 runs 10–25 lines late on `lib.rs` and
  `read.rs`; 04 runs 10–14 lines late past `sync.rs:200`), which is the
  signature of a survey written against an earlier checkout. **Trust a survey
  claim; re-derive its line number from the reference.**
