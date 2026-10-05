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

The Zig package manifest version is `0.0.0`, not the upstream crate version.
Root `version` and `Stats.package_version` describe that package.
`upstream_version` describes the separate `0.12.0` compatibility target.
`Stats.compiler_version` records the actual Zig compiler, not Rust's MSRV.

## Implemented

The current API-design repair uses Zig 0.16.0 on x86-64 Linux.
The [current STATUS checkpoint](docs/STATUS.md#latest-observed-checkpoint-2026-10-08) is the single latest observed evidence record.
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
  `storage/document_chunk.zig` and `storage/bundle.zig`. Document and bundle
  codecs target reference framing, columns, hashes, and reload behavior.
  Compressed saves need not be byte-identical. Prior interoperability results
  apply only to their named scenarios and recorded revisions.
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
  artifact and runs the cmocka suite. `zig build ctest-shared` separately links
  a dynamic production library and checks the 18-file corpus, save/reload,
  commit, and encoded sync. The default install remains static.
  **Calls from different threads must share
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

### Current native API implementation

The following contracts are implemented in source. Full integration verification remains open.
[API.md](API.md) gives signatures, ownership, barriers, errors, and capacity exceptions.

- **Raw and automatic lifecycles.** Mode-less `Document` owns committed state.
  Native `AutoCommit` owns one lazy held `Transaction` across writer calls.
  Ordinary reads do not close it. History, save, diff, setters, and sync have explicit close barriers.
  The C `AMdoc` now uses this same facade, including final-address pending clones.
- **Transaction ownership.** Manual construction borrows the document.
  `commit` and `commitWith` return owned optional-hash results and the transaction's real patch log.
  Fallible rollback and disposal retain progressed recovery on refusal.
  Closure outcomes preserve callback errors, retained results, and exactly one recovery or log owner.
  `OwnedTransaction` consumes a document only after successful initialization.
- **Loading and incoming changes.** `LoadOptions` supplies partial-load, head verification,
  string migration, patch logging, encoding, and author policies.
  `loadWithOptions`, `loadUnverifiedHeads`, and replacement loading use these policies.
  `rescue` returns an independent owned hydrated value, not history.
  Incoming logged methods borrow their sinks and reject incompatible actor-table order before incoming mutation.
  Compatible foreign documents are accepted. A retained trailing log actor can still make later rendering return `InvalidActorIndex`.
  Exact staged-publication target ownership remains a separate requirement.
  Prefix publication and allocation refusal remain operation-specific contracts.
- **Generic reads and clocks.** `ReadDoc(R)` and generic free readers accept raw,
  transaction, and automatic owners without a runtime vtable.
  Explicit historical heads exclude pending operations.
  Historical clocks stay stable across other reads until mutation.
  `hydrate(null)` reads raw current rows even under isolation.
- **Owned values and rich text.** Public `Value.object` carries an object kind.
  Hydrated values have flat scalar tags and map/list/text composite payloads.
  Owned map/list range extraction detaches actor identity and payload bytes.
  `DocObjItem.valueOwned` copies only the value, not the whole item, object identity, or key.
  `Map.putOwned` copies unowned scalar bytes and transfers composite owners on success.
  Use `dup` when both source and inserted composite must stay independent.
  `Span` owns full hydrated block maps, text, and marks.
  Writer `SpanInput` borrows its full map and text only through the call.
  `MarkSet.nonDeletedMarks` is a borrowed allocation-free tombstone-filtered view.
- **Native text units.** `ConcreteTextValue` stores UTF-8 units, UTF-16 units,
  Unicode code points, or owned grapheme units in native trees.
  Individual byte or surrogate halves can survive edits.
  `makeString(gpa)` returns caller-owned lossy UTF-8.
  Inserted grapheme boundaries persist; adjacent edits do not resegment old units.
- **Changes, metadata, and serialization.** Structured expanded changes and operations
  own their decoded payloads and implement reference JSON and wire reconstruction.
  Complete `extra_bytes` is authoritative; parsed `author` and `hash` are informational.
  Document metadata can inherit actor authors. Individual change author decoding
  returns null for an absent, unknown, or malformed author footer.
  Corrupt footer column encoding still returns a typed parse error.
  Generic `AutoSerde` supports JSON and a separate owned token-stream backend.
  Sync message serde emits only its four reference fields.
- **Remaining major facade methods.** Owned metadata, committed operation-hash lookup,
  author lists, document iteration, historical readers, bundles and fragments,
  configurable span updates, imports, hydrated initialization, dump/diff diagnostics,
  and exact `hasOurChanges` are present.
  Root `transaction` is the manual namespace; there is no deprecated alias route.
- **Automatic diff cache.** The facade owns one canonical range/object key and deep patch batch.
  Repeated queries return independent owned copies.
  Source implementation and semantic smoke do not establish a speedup.

### Current observed evidence and limits

The new source wave implements counted prefix-run splicing and an authoritative insertion-ordered byte-string index.
Earlier focused Debug/ReleaseSafe and actual bounded/public/reference checks passed in their named scope.
Candidate 4's three-sample diagnostic and 24 profiles/144 offline reports are complete for its earlier frozen snapshot.
Its binaries and profiles are historical after the RLE parser repair. They no longer represent current source.
No final acceptance exists. Candidate-3 one-sample results do not establish an isolated percentage gain against candidate 4.

Current source repairs minimum signed RLE literal-count overflow in [src/hexane/column.zig](src/hexane/column.zig).
Private `literalCount(i64) ParseError!usize` computes `-(header + 1)` and checked `+1`, avoiding signed-negation overflow.
All four former `-hdr.value` branches use it: `lastOfRun`, `segmentsOf`, `runAtOrAfter`, and `LoadCursor.next`.
The permanent regression uses `{0x80 × 9, 0x7f, 0x01}`: a minimum signed `i64` header followed by one `u32` value.
It expects typed refusal across cursor, segments, last-value, search, and load paths.
Before repair, the public probe observed `Column.load` refusal but a unary-negation panic in `LoadCursor.next`.
The expanded permanent regression also reproduced pre-repair panics in `lastOfRun` and `segmentsOf`, not all four old branches.
Post-repair `zig fmt --check src/hexane/column.zig` exited zero with no output.
Direct `zig test` with filter `hexane.column.` passed 329/329 Debug cases in 159.02 seconds, exit zero.
The same ReleaseSafe selection passed 329/329 cases in 188.15 seconds, exit zero.
The standalone public executable compiled and exited zero.
It reported `public_column_refusal=LengthExceedsInput` and `public_load_cursor_refusal=UnexpectedEnd`.
These checks cover the named column selection and malformed-header probe, not complete gates or all public workflows.
No post-repair candidate benchmark build, benchmark, or final acceptance has run. No new performance result follows.

Earlier focused checks passed 52/52 Debug and 52/52 ReleaseSafe cases without reported leaks.
The earlier rebuilt public executable passed four workflows with allocator cleanup.
The latest expanded Debug selection passed 920 cases, skipped one, and failed none from 921 selected cases in 698.07 seconds.
It covers the earlier runtime failures and root/reference-hash and allocation-failure regressions, but is not a full gate.
The latest actual native root and public-API executables passed eight workflows total with allocator cleanup in 6.37 seconds.
The second ReleaseFast/native libc-CAllocator candidate compiled, but remains unmeasured and predates the confirmed strict-load repair.
It must not serve as the acceptance candidate.
The first candidate's capture preflight failed before any benchmark because the read-only Cargo executable has two legitimate hardlinks.
A subsequent broader subsystem Debug compile failed before any cases.
After compile repairs, the 911-case Debug selection aborted at case 896 after four assertion failures.
Those decoded-budget, prefix/iterator, and retained-key failures remain historical records.
Their regressions passed in the latest expanded selection.
The focused passes certify their earlier snapshot, not subsequent repairs or a final candidate freeze.
All 26 final acceptance cells and remaining complete gates remain pending after the source changes.
Expanded Debug compilation first refused a nonexistent fixture type.
The parent corrected it to `ExId` before the successful expanded selection.
The new native root executable passed absent/overlap/repeat/child workflows with exact Rust heads and retained conflicts.
The unchanged four public capabilities also passed in the separate executable.
Pinned Rust hydrate observations support a physical-order-only native repair, preserving empty predecessors, same-value repeats, sorted/BFS creation order, and hashes.
The four-path Rust probe and native executable establish those named behaviors, not universal correctness.
A public before-repair strict-load probe confirmed malformed snapshot-order acceptance with unchanged history head and a hidden live key.
The canonical control loaded both keys correctly. Probe exit zero confirmed the bug, not a passing load contract.
After repair, the same probe rejected malformed order with typed `InvalidValue` and preserved the valid control.
The source uses allocation-free row validation in its existing index/mark-validation walk, without another scan, new errors, or wire changes.
Post-repair focused Debug and ReleaseSafe each passed 10/10 cases, not full suites.
Candidate-2 descriptor/preflight completed without benchmarks and accepted the unchanged read-only two-hardlink Rust executable.
Candidate 2 remains pre-order-gate and will not be measured.
Candidate 3 built at `2026-10-08T12:20:45Z` in 120.17 seconds, ReleaseFast/native with libc CAllocator.
Candidate-3 reference conformance passed all 12 unchanged golden vectors, and live save interoperability verified all six scenarios.
The combined command exited zero in 11.60 seconds with 32/32 build steps, not 32 semantic cases.
Frozen candidate 3 completed all 52 fresh diagnostic processes and 26 matched pairs without errors, stderr, retries, or provenance drift.
All 104 user-only counter observations had 100% coverage.
This is one sample per engine/cell, not the five-sample, 260-process final matrix.
Aggregate subject, process-wall, and best-phase preservation checks are false. All 26 final acceptance cells remain pending.
The [single canonical diagnostic table](bench/README.md#candidate-3-single-sample-diagnostic-not-final-acceptance) records the complete measured scope.
All eight candidate-3 large-stack Native/Rust profiles completed with full identity checks and empty benchmark stderr.
Their reports completed offline from the same recordings, without a benchmark or profile retry.
The first invocation's pre-benchmark failure and subsequent parser/report corrections remain preserved.
The [canonical profile table and caveats](bench/README.md#candidate-3-large-stack-profiles-diagnostic-only) retain separate loss records and incomplete native unwinding.
Self symbols do not prove native caller/phase attribution or timing gains.
Candidate-3 source capture is closed. Candidate 4 has measured diagnostic results, not final acceptance or isolated gains.
The first focused Debug run passed 26 of 28 cases, with two new successor-fixture lifetime failures.
The owner repaired borrowed-array lifetime without changing production boolean/string code for these failures.
Corrected Debug and ReleaseSafe each passed 28/28 cases.
Three actual fixed-buffer consumers also passed their exact compressed-splice/window scenarios, not a universal 4-KiB bound.
The [canonical proof table](bench/README.md#verified-source-wave-candidate-4-bounded-proofs) records sizes, capacities, and results.
The actual public and retained-root executables passed eight workflows with allocator cleanup in 6.48 seconds.
Pre-RLE-repair conformance passed 12 unchanged goldens and live saves verified six scenarios in 11.19 seconds, with 32/32 build steps.
Evidence: [integrated-wave3-verified.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/integrated-wave3-verified.json).
Bounded static reviews and pure helper tests do not close full gates.
Candidate 4 built in 118.23 seconds with identical 80-file source contents/provenance before and after that historical build.
Its three-sample diagnostic completed with 156 valid processes, 78 pairs, and 312 PMU observations at 100% coverage.
The descriptor/preflight/capture command exited zero in 365.92 seconds, without retries or input drift.
The [canonical candidate-4 table](bench/README.md#candidate-4-three-sample-diagnostic-not-final-acceptance) retains all 26 cells, independent sync subjects, and raw-tail evidence.
Aggregate subject, process-wall, and strict best-preservation checks are all false.
Load and merge meet diagnostic limits. Only small repeated diff meets both observed preservation factors.
Those observations are not final acceptance or statistical regression proof.
The run is distinct from the frozen historical matrix and candidate 3's one-sample diagnostic.
Actual counts are three per engine/cell, despite historical ledger label text mentioning five final samples.
All 26 final cells remain pending, with five fresh samples per engine/cell and 260 balanced serial processes required.
Eight additional cells completed 16 profiles and 96 offline reports in 317.75 seconds, exit zero, without rerunning the initial eight profiles.
All 16 profiles were valid. Profile/report processes exited zero without retries or input drift. Benchmark stderr was empty.
The 80-file contents/provenance matched the pre-build snapshot at that capture, before the RLE parser repair.
The [canonical additional-profile table](bench/README.md#candidate-4-remaining-path-profiles-diagnostic-only) retains signed-leaf evidence and incomplete-unwind/sparse-sample limits.
Total: 24 profiles and 144 offline reports, with independent group receipts. No new timing medians or final acceptance follow.
Pure helper validation passed 10/10 and 21/21 in 9.67 seconds combined.
The recorded executor-only transition repairs mode/count labels, not timing math or thresholds. All other input proofs remained equal.
Historical receipts remain unchanged.
The [candidate-4 profile table](bench/README.md#candidate-4-large-stack-profiles-diagnostic-only) records eight fresh profiles and 48 offline reports completed in 134.43 seconds.
Recorded buffer/final-counter losses were zero. Native unframed samples remain, so native callers and phase costs are unresolved.
Whole-process sampled-IP self percentages include setup and disposal. They do not identify the subject phase or prove speed gains.
Candidate 4's capture freeze is complete for its earlier snapshot. Current source differs after the RLE parser repair.
Its diagnostics and profiles do not establish a post-repair gain or current-source performance result.
Full Debug/slow-path/ReleaseSafe and C/API gates also remain pending.
The shared-host diagnostics establish no statistical regression/no-regression result, universal input bound, or CPU/frequency isolation.

The [authoritative STATUS checkpoint](docs/STATUS.md#latest-observed-checkpoint-2026-10-08) records candidate identity, counts, and proof limits.
The [benchmark checkpoint](bench/README.md#current-optimization-loop-checkpoint) records lexical bounds/lookahead, codec prefixes, bounded literal maintenance, and affected-range weights.
It also records cached tree bases, checked tree/Fenwick and prepared raw publication, rebased row/value/successor streams, and batched selected-history reconstruction.
Strict V2 selection precedes payload reconstruction. Checked short LEB paths use finite unrolling.
Signed tracked columns retain legacy whole-header behavior.
The signed checked-column panic repair uses private exact cached tree-prefix aggregation, not disabled safety.
Fixture ownership repairs preserve empty-array and stateless-allocator contracts.

Ten finite kernel variants passed 4,014,848 differential cases each in Debug, ReleaseSafe, and ReleaseFast.
The balanced ledger retains 600 timing rows and all tails.
Scalar production was best on short streams. No unconditional SIMD or production safety-off annotation was merged.
Actual safe/off export aliases establish no annotation benefit or end-to-end Rust speed gain.

Final acceptance retains all 26 unchanged cells and Native/Rust subject and whole-process wall-time ratios ≤2.
Sync generation and receipt must pass independently.
It requires five fresh samples per engine/cell, or 260 processes, in balanced serial order on CPU 0 with runner CPU 2.
Retain all raw phases, counters, and tails.
Preserve best cached repeat/subtree diff and sync receipt results in absolute time and relative ratio.

Earlier complete gates and the 156-process three-sample matrix remain frozen baseline evidence.
Candidate-3 conformance/live-save results certify only their named checks, not the new source wave, remaining gates, or final matched performance.
Earlier failures and leak reports remain preserved in STATUS.
The target native public API is implemented, but new complete-gate and all-cell proof remains pending.
This does not prove all targets, every upstream integration case, or universal malformed-input,
allocation-refusal and leak-safety behavior. The bounded ownership audit is static evidence only.
The [frozen final matched comparison](bench/README.md#final-matched-results) showed no performance parity.
Large map mutation, sync generation, and cold diff were slower.
Cached-diff phases were faster, but setup and whole-process costs remained worse.
No current-candidate speed, universal-input, or CPU/frequency-isolation claim follows from historical results or bounded checks.

### Contract decisions and consumer costs

1. **Keep a live capability.** `Document.init(gpa, io)` and
   `initWithEncoding(gpa, io, encoding)` return
   `Allocator.Error || std.Io.RandomSecureError`.
   Loading returns `LoadError`. Keep both allocator and borrowed provider live until disposal.
2. **Handle entropy refusal.** Fresh actors use secure 16-byte draws without a weak fallback.
   Cancellation returns no partially drawn actor.
   Use deterministic `setActorId` when the identity must be fixed.
3. **Keep exactly one recovery owner.** A refused commit retains its journal.
   `Failure(O,E)` includes the primary error, cancelled count, rollback error,
   optional recovery transaction, retained result, and owned terminal log.
   Retry progressed rollback or dispose the whole owning document.
   Do not use a closed-only journal disposer while another live document still contains its pending rows.
4. **Keep owner addresses stable.** Never shallow-copy owning documents or facades.
   A move requires no address borrow. An open `AutoCommit` cannot relocate.
   Use raw `clone` or facade `cloneInto` for independent owners.
5. **Respect the C boundary.** Link the production artifact and installed header.
   Serialize calls globally, even across distinct handles.
   Synchronous callback inspection remains under the existing lock and borrow rules.
6. **Pay explicit output ownership costs.** Native text rendering, detached iterator rows,
   span blocks, expanded changes, metadata, and cache-hit patches are owned output.
   Release each through its documented allocator or retained owner.
   Caller-side copying costs do not imply an observed performance result.


## Planned

The port plan for the `automerge` and `hexane` crates is in
[docs/plan.md](docs/plan.md). The short version:

| Phase | Delivers | Gate |
| --- | --- | --- |
| P0 | scaffold, fixtures, Rust oracle for differential testing | `zig build test`, `zig build conformance` |
| P1 | types, values, errors, clocks, LEB128, SHA-256, DEFLATE | property tests against the oracle |
| P2 | `hexane`: slabs, columns, RLE, bool, delta, prefix, the btree, the edit cursor | codec round trips, btree invariants, and 272 covered upstream occurrences with 14 reasoned exclusions in [docs/hexane-cases.json](docs/hexane-cases.json) |
| P3 | columnar encoding, chunk framing, document and change chunks | corpus fixtures load with their recorded outcomes; malformed-input crashers return the specified typed refusal |
| P4 | change graph, change encoding | change hashes byte-identical to the reference |
| P5 | the op set, merge, batch apply | Behavioral ports and live save interoperability provide broad coverage. The former `test.rs` 140/140 claim does not establish case-for-case coverage. Consumer ledgers define exact scope; passing roots do not imply full upstream integration parity. |
| P6 | the document and transaction API | Frozen baseline major API replay, standalone executable and complete roots passed. New candidate complete gates remain pending. Coverage stays bounded by consumer ledgers. Constructors retain a live `std.Io`. |
| P7 | iterators and historical reads | Frozen baseline complete roots passed. New candidate complete gates remain pending. Preserve the case ledger, four-encoding exceptions, and owned-value versus whole-item boundaries. |
| P8 | sync, including v1 compatibility | Frozen baseline full roots, reference/C consumers and matched CLI correctness passed. New candidate complete gates remain pending. Smoke is not performance proof. |
| P9 | patches, marks, cursors, text diff, hydrate, serde | Frozen baseline replay, complete roots and matched comparison passed their correctness checks. New candidate complete gates remain pending. Corpus and reference-panic exceptions stay explicit. Cache-phase gains do not imply whole-process gains. |
| P10 | the C ABI | `zig build ctest` runs the upstream C suite against the production artifact and compiles the real header's 187 function signatures, 37 enum names across five enums, and five exposed struct layouts. **A green suite alone is not this gate**: linking does not prove layout or signature parity. |

**Coverage is not total integration-suite parity.**
Test declarations, fixture loads, and API names do not prove each upstream case's semantics.
The consumer ledgers bound case-for-case coverage for rescue, hydrated block payloads,
expanded-change/serde representations, and mismatched external patch logs.
Those prerequisites now have source implementations. Current runtime closure must be measured.
The former rich-text fuzz 9/9 claim included an absent rescue case and remains invalid historical evidence.

Selected new ports close exact behavior gaps, not an inferred aggregate count:
- The Both-expanding bold-mark bundle decodes and retains text and marks (`tests/test.rs:135-152`).
- Document iteration skips losing text overwrites after the object shift (`:722-755`).
- UTF-16 incremental loading covers uncompressed changes, compressed changes, and bundles (`:4144-4178`).
These consumers are in `test/upstream_doc_more.zig`.
`test/upstream_clock_test.zig` also consumes the reference clock corpus at the document boundary.
It checks dependency-closed subsets, pairwise coverage and merges, heads, and missing dependencies.
Current check results belong in [docs/STATUS.md](docs/STATUS.md), not an invented port total.

## Compatibility contract

- A document written by `automerge` 0.12.0 loads here, and one written here
  loads there.
- Sync states interoperate in both directions, including with a v1-only peer.
- Change hashes match the reference byte for byte, because a change hash is
  SHA-256 over the encoded change.
- `save()` output is **not** byte-identical: DEFLATE is not reproducible across
  implementations. Equivalence is checked by loading and comparing the
  materialized document. Six shared save scenarios also compare document bodies
  byte for byte after column inflation, retaining actor/head order, column
  IDs/order/data, and the head-index suffix.


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
- `zig build ctest-shared` runs a C consumer against a separate dynamic
  production library and the canonical 18-file fixture corpus. Each valid
  document exercises save/reload, transaction commit, and bidirectional
  encoded sync. It needs libc, but not cmocka or the reference checkout.
  The fixture-table generator runs only for this explicit gate.
- `zig fmt --check .` checks formatting. `gate` runs the house gate.
- `jj st` shows working-copy status. Use `jj`, not raw Git, for mutations.

The read-only reference checkout is `$AUTOMERGE_REF` when that names a
checkout, and otherwise the one beside this repository,
`../github-automerge-automerge`; `tools/link-oracle.sh` names both when it
finds neither. Never build in the checkout and never modify it.

This project declares its development dependencies in `devenv.nix`. Do not
install system or development libraries imperatively. Use direnv or
`devenv shell`; run `direnv allow` after changing the environment.
