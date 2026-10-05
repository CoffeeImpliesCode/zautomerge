# Status: where the port is, and what comes next

The plan of record is [plan.md](plan.md); this is the state of it.

## Current API cutover and optimization loop

Reference: Automerge 0.12.0 at `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`.
Compiler scope: Zig 0.16.0, x86-64 Linux.
Package provenance is `0.0.0`; the separate upstream target is `0.12.0`.
Earlier dated results below do not certify this working tree.

The raw document is mode-less. Native and C automatic consumers now use one
`AutoCommit` owner with a lazy held transaction, stable open address, declared close barriers,
owned terminal logs, and retained recovery on refusal.
Source also implements complete load policies and owned-value rescue, generic nonclosing readers,
stable historical clocks, full hydrated span blocks, borrowed writer span inputs,
native encoded text trees, detached row/value output, expanded changes, JSON and token serialization,
external-log ownership checks, imports and diagnostics, exact shared-head checks, and the diff cache.
[API.md](../API.md) supplies the complete public contract.
Presence in source is not a passing compilation or runtime claim.

### Latest observed checkpoint — 2026-10-08

The new source wave implements counted prefix-run splicing and interned byte-string indexing.
Earlier focused checks, actual consumers, and reference checks passed in their named scope.
Candidate 4 completed a matched three-sample diagnostic and 24 profiles with 144 offline reports for its earlier frozen snapshot.
Its binaries and profiles are historical after the RLE parser repair below. It has no final acceptance.

Current source repairs minimum signed RLE literal-count overflow in [src/hexane/column.zig](../src/hexane/column.zig).
Private `literalCount(i64) ParseError!usize` computes `-(header + 1)` and checked `+1`, avoiding signed-negation overflow.
All four former `-hdr.value` branches use it: `lastOfRun`, `segmentsOf`, `runAtOrAfter`, and `LoadCursor.next`.
The permanent regression uses `{0x80 × 9, 0x7f, 0x01}`: a minimum signed `i64` header followed by one `u32` value.
It expects typed refusal across cursor, segments, last-value, search, and load paths.
Before repair, the public probe observed `Column.load` refusal but a unary-negation panic in `LoadCursor.next`.
The expanded permanent regression also reproduced pre-repair panics in `lastOfRun` and `segmentsOf`, not all four old branches.

The post-repair column selection and public refusal probe passed within the scope recorded below.
Earlier focused checks and eight public workflows certify their earlier snapshot, not this repair or a final candidate freeze.
No post-repair candidate benchmark build, benchmark, or final acceptance has run. No new performance result follows.
The pre-loop complete gates and 156-execution matched matrix are frozen baseline evidence, not current-source proof.
Candidate 3's one-sample diagnostic is historical. It does not establish an isolated percentage gain against candidate 4.
All 26 final acceptance cells and complete gates remain pending.

| Current observed check | Result and scope |
| --- | --- |
| Focused Debug | 52/52 cases passed, no skips, failures, or reported leaks. Wall time: 11.46 seconds. |
| Focused ReleaseSafe | 52/52 cases passed, no skips, failures, or reported leaks. Wall time: 145.22 seconds. |
| Rebuilt actual public-API executable | Four workflows passed with allocator cleanup. Wall time: 4.55 seconds. |
| First candidate compilation | ReleaseFast/native, libc CAllocator. `native-candidate-1` built at `2026-10-08T10:53:10Z` in 122.76 seconds. SHA-256: `f5a2e3712fabce2a2556e26a73664e026044a1d5d62a0be192241db8719c33f0`. |
| Capture preflight | Failed before any benchmark in 2.09 seconds. The read-only Cargo executable has two legitimate hardlinks. No new timing result exists. |
| Subsequent broader subsystem Debug compile | Parent observed exit 1 in 8.41 seconds, before any cases. Two new slab tests incorrectly qualified `Slab.fromParts` at lines 1495/3218. The existing `op_iter` catch at line 1676 omitted the new `Overflow` error. This is not broader green evidence. |
| Earlier broader Debug execution after compile repairs | The 911-case selection aborted after 284.59 seconds at case 896, before completion. Four assertion failures preceded the abort: many-slab `Delta(u32)` decoded-byte budget (189), beyond-data prefix `InvalidValue` (351), alternative `BeLenRle` decoded-byte budget (467), and propagated `OpIter` `UnexpectedEnd` versus `InvalidValue` (602). This aborted run has no completed pass total. |
| Second candidate compilation | ReleaseFast/native, libc CAllocator. `native-candidate-2` built at `2026-10-08T11:40:58Z` in 122.40 seconds. SHA-256: `ed556169a9defd1ef017a84f3d3e24bce909e319e4a9779a58ef566d4db0992e`. Unmeasured. It predates the confirmed strict-load repair and must not serve as the acceptance candidate. |
| Expanded Debug compilation | First compile failed in 7.58 seconds because a fixture used nonexistent `types.ObjId` at line 4110. Parent corrected it to `ExId` before the successful expanded run. |
| Latest expanded Debug selection | Exit zero in 698.07 seconds. Of 921 selected cases, 920 passed and one skipped, with zero failures. Includes the four earlier assertion failures, retained-key regression, new root/reference-hash tests, and allocation-failure cases. This is not a full Debug, slow-path, or ReleaseSafe gate. Parent output: `artifact://852`, 933 lines. |
| Latest actual public executable checks | Exit zero in 6.37 seconds. `native-hydrate-public-smoke` passed absent/overlap/repeat/child workflows with exact Rust heads and retained conflicts `[1,2]` and `[1,2,2]`. `public-api-wave2` passed the unchanged four public capabilities. Both reported allocator cleanup: eight actual workflows total. |
| Public strict snapshot-order probe, before repair | Exit zero in 3.85 seconds confirmed the bug, not a passing load contract. Canonical control loaded `a=1,b=2` with the expected head. A normally saved snapshot with two complete valid rows swapped loaded successfully with unchanged history head, but `get[b]` was missing instead of 2. |
| Public strict snapshot-order probe, after repair | Exit zero in 3.95 seconds. Malformed order rejected with typed `InvalidValue`. Canonical control still loaded `a=1,b=2` and the expected head. |
| Post-repair focused Debug and ReleaseSafe | Each passed 10/10 cases. Combined wall time: 375.44 seconds. Includes strict/recovery/rescue and `Set` allocation-failure coverage, root ordering/retained ownership, scoped/held automatic paths, four Rust hashes, load control, and retained-key checks. Not a full-suite result. |
| Second-candidate capture controls | Descriptor completed in 2.07 seconds and preflight in 3.12 seconds, without benchmarks. The runner accepts the actual read-only, two-hardlink Rust executable without modifying it. Candidate 2 remains pre-order-gate and will not be measured. |
| Third candidate compilation | ReleaseFast/native, libc CAllocator. `native-candidate-3` built at `2026-10-08T12:20:45Z` in 120.17 seconds. SHA-256: `496d2deddc79132b38984619c5dbbd7e3f02b5275c38db4a21059046fae0cb2c`. Frozen for the one-sample diagnostic, not final acceptance. |
| Candidate-3 conformance and live saves | Exit zero in 11.60 seconds, 32/32 build steps. All 12 vectors matched unchanged goldens exactly. All six live save scenarios verified. Output: `artifact://874`, footer at line 4522. The step count is not a semantic-case count. |
| Candidate-3 matched diagnostic | All 52 fresh processes and 26 pairs valid, with all 104 user-only counter observations at 100% coverage. Zero errors, stderr, retries, or provenance drift. One sample per engine/cell only. Aggregate subject, process-wall, and best-phase preservation checks are false. No final acceptance. |
| Profile helper checks and first invocation | Five pure helper tests passed in 0.002 seconds. The first profile invocation failed before benchmarks because outer CPU-2 affinity excluded required entry CPU 0. Zero benchmark processes ran. These checks do not establish successful profiles. |
| Candidate-3 actual profiles and offline reports | All eight large insert/map/load/merge Native/Rust profiles passed full identity checks with empty benchmark stderr. Offline recovery produced 48 reports, with zero new benchmark/profile processes and no retries. Reports-only exit zero: 151.40 seconds, with nine pure helper tests passed. Diagnostic evidence only. |
| First new-wave focused Debug run | Of 28 selected cases, 26 passed and two failed in 69.98 seconds. Both composite successor failures came from fixture-borrowed pointers into a function-local runtime array. The owner repaired fixture lifetime, preserving independent successor, all-column, and allocation-failure assertions. Production boolean/string code did not change for these failures. The corrected checks passed within the scope below. |
| Generalized diagnostic helper | Fifteen pure tests passed in 6.791 seconds, 8.05 seconds total. Extra rounds are test fixtures, not timing data. This does not establish a new candidate's performance. |
| Verified new-wave focused and bounded consumers | Debug 28/28 and ReleaseSafe 28/28 passed. Command exit zero in 256.45 seconds, including three actual fixed-buffer-allocator proofs. Canonical bytes, cut windows, strict reload and allocator cleanup matched. The [canonical bounded-proof table](../bench/README.md#verified-source-wave-candidate-4-bounded-proofs) records exact scenario sizes and capacities, not a universal memory bound. |
| Pre-RLE-repair actual public workflows | Exit zero in 6.48 seconds. Four unchanged public capabilities and absent/overlap/repeat/child root workflows passed with allocator cleanup. |
| Pre-RLE-repair reference conformance and live saves | Exit zero in 11.19 seconds, 32/32 build steps. All 12 goldens remained unchanged and matched exactly. All six live saves verified. Output: `artifact://913`, footer at line 4522. Not 32 semantic cases. |
| Candidate-4 frozen native build | ReleaseFast/native with libc CAllocator built in 118.23 seconds at `2026-10-08T13:51:34Z`. The 80-file source contents and full provenance matched before/after that historical build. This binary predates the RLE parser repair. [Build hashes and receipt](../bench/README.md#verified-source-wave-candidate-4-bounded-proofs). |
| Candidate-4 three-sample matched diagnostic | Descriptor/preflight/capture exited zero in 365.92 seconds combined. All 156 processes, 78 pairs, and 312 PMU observations were valid, stable, and retry-free, with 100% counter coverage. Subject, process-wall, and strict best-preservation aggregate checks are all false. [All 26 cells and raw-tail evidence](../bench/README.md#candidate-4-three-sample-diagnostic-not-final-acceptance). Not final five-sample acceptance. |
| Candidate-4 profiles and offline reports | Eight fresh large insert/map/load/merge profiles and 48 offline reports exited zero in 134.43 seconds. Benchmark stderr was empty. Inputs stayed frozen, with no retries. [Canonical sample/loss table and scope limits](../bench/README.md#candidate-4-large-stack-profiles-diagnostic-only). Incomplete native unwinding remains. |
| Additional candidate-4 profiles and reports | Sixteen profiles of eight additional cells and 96 offline reports completed in 317.75 seconds, exit zero, without rerunning the first eight profiles. All profiles were valid, inputs stayed equal, and no retries occurred. Benchmark stderr was empty. Full 80-file contents/provenance matched the pre-build snapshot at that capture, before the RLE repair. [Canonical additional-cell table and independent receipt](../bench/README.md#candidate-4-remaining-path-profiles-diagnostic-only). Not medians, phase attribution, or ≤2 acceptance. |
| Completed helper validation and label repair | Parent observed 10/10 pure checks in 0.039 seconds and 21/21 in 8.067 seconds, 9.67 seconds combined. Current labels reflect actual baseline/current modes and counts. The receipt records an executor-only proof transition. All other source/build/binary/compiler/options proofs stayed equal, without timing/threshold changes or historical receipt rewriting. |
| Post-RLE-repair formatting | `zig fmt --check src/hexane/column.zig` exited zero with no output. Only this file's formatting was checked. |
| Post-RLE-repair focused Debug | Direct `zig test` with filter `hexane.column.` passed 329/329 cases in 159.02 seconds, exit zero. Not a complete Debug gate. |
| Post-RLE-repair focused ReleaseSafe | Direct `zig test` with filter `hexane.column.` passed 329/329 cases in 188.15 seconds, exit zero. Not a complete ReleaseSafe gate. |
| Post-RLE-repair public refusal probe | The standalone public executable compiled and exited zero. Observed outputs: `public_column_refusal=LengthExceedsInput` and `public_load_cursor_refusal=UnexpectedEnd`. This checks the malformed literal header, not all public workflows. |

Evidence: [integrated-wave1-verified.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/integrated-wave1-verified.json).
The later builds, checks, and strict-load probe are subsequent parent observations, not results in that integrated ledger.
Case 896 read null for the retained `keep` key during normal raw hydrate initialization after a successful batch commit.
The parent observed this at `src/doc.zig:14291`.
Stale OOM context from earlier allocation tests does not establish OOM at this normal trigger.
The [benchmark checkpoint](../bench/README.md#current-optimization-loop-checkpoint) records the named algorithms, candidate identity, and full acceptance contract.
Changes include lexical map bounds/lookahead, codec-aware prefixes, bounded literal maintenance, affected-range weights, and cached tree bases.
They also include checked tree/Fenwick and prepared raw publication, rebased row/value/successor streams, batched selected-history reconstruction, and strict V2 payload selection.
Checked short LEB paths and finite unrolling complete the wave.
Signed tracked columns retain legacy whole-header behavior.
The checked-column signed panic repair uses private exact cached tree-prefix aggregation, not disabled safety.
Fixture ownership repairs preserve empty-array disposal and stateless-allocator contracts without inspecting undefined context pointers.
Change hashes, save interoperability, and private collector meaning remain required.

A pinned Rust probe checked four existing-root hydrate paths and fresh replay of identical-head changes.
Direct production had broken physical query results. Fresh replay preserved absent keys and retained conflicts `[1,2]` and `[1,2,2]`.
The native source repair changes only physical publication order.
It preserves empty predecessors, same-value repeats, sorted/BFS creation order, and encoded hashes.
Evidence: [reference-hydrate-observations.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/reference-hydrate-observations.json).
The Rust probe establishes four-path reference behavior, not universal correctness.
The latest native root executable passed those four workflows with exact Rust heads and allocator cleanup.
Evidence binaries: `/tmp/tmp/zautomerge-perf-loop-tYJOfU/native-hydrate-public-smoke` and `/tmp/tmp/zautomerge-perf-loop-tYJOfU/public-api-wave2`.

The public standalone `Document.load` probe confirmed the strict snapshot-order gate gap.
It swapped complete valid `ChangeOp` rows through `Set.fromDocOps` and normal `saveWithOptions(deflate=false)`, preserving each row and graph.
The loader accepted this malformed order and hid a live key despite an unchanged head.
Evidence source: [snapshot-order-public-smoke.zig](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/snapshot-order-public-smoke.zig).
The repair uses allocation-free `OpStepper` validation in the existing `rebuildIndexWithMarkValidation` iterator before index-builder grouping and processing.
It adds no scan, error type, or wire change.
`allow_invalid_marks` does not bypass row-order validation.
The post-repair standalone probe rejected the same malformed snapshot with `InvalidValue`.
Ten focused cases passed in each of Debug and ReleaseSafe.
These checks do not certify a full suite or a final source freeze.
Candidate 3 completed descriptor/build-record/preflight and the diagnostic on frozen source.
All eight candidate-3 profiles completed, closing its source freeze.
Original partial ledgers remain preserved in owned scratch, not public receipts.
The [canonical profile table and caveats](../bench/README.md#candidate-3-large-stack-profiles-diagnostic-only) retain sample, unwinding, and separate loss-accounting limits.
Evidence: [allowlisted sanitized profile-ledger.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-candidate3-reports-20261008T130959Z-7892a1039a1548fdb0a5cdb027809cdc/profile-ledger.json).
Sampled self symbols do not establish native callers, phases, or timing gains.
The binary has unwind/DWARF sections. The cause of incomplete native unwinding remains unknown.
The new source uses counted metadata/boolean writers and an authoritative insertion-ordered byte-string index.
It preserves stable `u32` IDs, owned keys, clone order, and existing codec/hash contracts.
The fixture lifetime repair retains all-column, independent successor, and allocation-failure assertions.
Corrected focused, bounded fixed-buffer, public workflow, and reference checks passed before the later RLE parser repair.
Evidence: [integrated-wave3-verified.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/integrated-wave3-verified.json).
Bounded static reviews reported no findings in string/counting scope, with confidence 0.93/0.94, without execution.
They are not gates or universal correctness proof.
The 80-file source stayed frozen through candidate 4's build and both completed profile groups.
That freeze describes the earlier capture only. Current source differs after the RLE parser repair.
Candidate-4 binaries, diagnostics, and profiles remain historical evidence for that snapshot, not current-source proof.
Its complete diagnostic has three fresh samples per engine/cell, not the five required for final acceptance.
It is distinct from both the frozen pre-loop matrix and candidate 3's one-sample diagnostic.
The [canonical candidate-4 table](../bench/README.md#candidate-4-three-sample-diagnostic-not-final-acceptance) records all 26 cells and both independent sync subjects.
Only small repeated diff meets both observed strict preservation factors. This is not statistical best-case regression proof.
Load and merge meet their diagnostic subject/process limits, not final acceptance.
Use recorded sample counts, not the historical ledger label that mentions five final samples.
The [additional profiles](../bench/README.md#candidate-4-remaining-path-profiles-diagnostic-only) are complete, with 24 profiles and 144 offline reports across independent receipts.
Recorded buffer/final-counter losses are zero. Native unwinding remains incomplete, so source callers and benchmark phases are unresolved.
Sparse small-batch samples do not support quantitative priority claims.
Native source citations qualify suffix handling: changed signed tracked-prefix totals can require suffix-byte validation.
Remaining complete gates and all 26 final acceptance cells remain pending.
Candidate 3's build-record SHA-256 remains `7b322c553aec439bcf3fbaa0b612a968b35271cca7b366bf0b251d9a2415b8b6`.
The [historical candidate-3 table](../bench/README.md#candidate-3-single-sample-diagnostic-not-final-acceptance) records its separate one-sample diagnostic.
Evidence: [candidate-3 capture-ledger.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-diagnostic-20261008T122629Z-fdf3cea06b79405c9c4a62ea7c2339c3/capture-ledger.json).
Neither shared-host diagnostic proves statistical regression, no regression, universal scaling, or CPU/frequency isolation.
Candidate-2 controls: [descriptor capture](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-describe-20261008T114857Z-1752171a010f4cf3a0b8bf446f3ccf1a)
and [preflight capture](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-preflight-20261008T115218Z-8e6a201d22b344479777cc2904743aa7).
A bounded static maintenance audit reported no findings in column/slab/btree scope, confidence 0.86.
That audit does not establish runtime correctness.

Ten kernel variants passed 4,014,848 independent differential cases each in Debug, ReleaseSafe, and ReleaseFast.
The [balanced ledger](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/kernel-order-balanced-ledger.json) retains 600 timing rows, checksums, order positions, and all tails.
Actual [codegen evidence](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/kernel-codegen-observation.json) shows bounded safe/off exports alias in ReleaseSafe and ReleaseFast.
Scalar production was best on short streams. No unconditional SIMD or production safety-off annotation was merged.
These finite synthetic checks establish no end-to-end Native/Rust speed gain.

Final acceptance retains all 26 unchanged cells, subject and whole-process Native/Rust wall-time ratios ≤2, and independent sync generation/receipt limits.
It requires five fresh samples per engine/cell: 260 processes, balanced serial order, CPU 0, runner CPU 2.
Retain all raw phases, counters, and tails.
Preserve best cached repeat/subtree diff and sync receipt results in absolute time and relative ratio.
Complete Debug/slow-path/ReleaseSafe, 119-record API replay, static C 160/dynamic C 18, and all-cell gates remain pending.
Pre-RLE-repair 12-vector conformance and six live-save checks passed within their named scope.
No universal-input or CPU/frequency-isolation claim follows.

### Frozen complete gates and matched baseline

The following results precede the current optimization-loop source changes.
They preserve their original snapshots, numbers, and evidence anchors.
They do not certify the new candidate.
The baseline normal root's skipped deep-fuzz case passed in its complete slow-path root.
The failed roots below remain historical red checkpoints.
Scope is the named source snapshot, compiler, target, command, and consumer—not universal correctness.

| Frozen baseline check | Result and scope |
| --- | --- |
| Full Debug and slow-path gate | `zig build test slow-path -Doptimize=Debug` passed 84/84 build steps and 4386/4387 actual cases, one skip. Normal library: 2046 passes and one skip from 2047 cases. Slow-path library: 2047/2047 passes. All 293 external consumer cases passed. No failure, crash, or leak was reported. |
| Native typed API replay | Latest run passed all 119 records, consumed once with complete-field comparison, through three root cases. Includes the original target corpus, genuine incompatible-table refusals, and the retained-tail apply-success/checked-render-refusal reference-panic case. |
| Root declaration sweep | Passed on the current source. This checks reached declarations, not every runtime state. |
| Standalone public executable | Four non-test workflows passed with allocator cleanup. Executable SHA-256: `8329b0eee1819136fd2bbe7bb8a6627fa930350535f95cd89c452b8c9a67d32f`. Evidence: `standalone-public-api-smoke-proof.json`. |
| Reference conformance and live save interoperability | All 12 vectors, including the API corpus, and six live save scenarios passed. Build summary: 32/32 steps—not 32 semantic cases. |
| Static production C and real-header ABI | All 160 cmocka cases across 13 groups passed; 7/7 build steps. The real-header guard includes 187 physical function declarations. |
| Dynamic production C corpus | All 18 outcomes passed: five valid documents and 13 expected load errors; 9/9 build steps. Each valid document exercised save/reload, commit/hash/value and encoded sync. |
| Fresh matched CLI correctness smoke | All 26 cells matched Rust heads, checksum, count, schema, and phase names. Source fingerprints were unchanged before and after. Evidence: `native-oom-smoke-20261008T071838Z-231a48cb/native-oom-smoke-ledger.json`. This is correctness, not performance evidence. |
| Zig formatting | Latest `zig fmt --check .` passed. |
| Full ReleaseSafe gate | Passed 78/78 build steps and 2339/2340 actual cases, one skip. Library: 2046 passes and one skip from 2047 cases. All 293 external consumer cases passed. No failure, crash, or leak was reported. |
| Final repeated matched Rust/native matrix | Completed: all 156 executions valid, all 26 cells with six valid executions each, three fresh samples per engine. All 312 user-only counter observations and all schedule records were valid. Zero nonzero exits, errors, stderr, spawn failures, parity mismatches or retries. The source and binary fingerprints were unchanged. |

The measured Native ReleaseFast binary SHA-256 is
`2fc5d5bfa94e655e44268f910cdca920827c242a2c3c6905739551ed1f08c59f`.
Its source-file fingerprint is
`89ba06bf97c489800a423ff421bbcb8d9f21833162d74629d4692fdc0ee9d4f4`.
Binary/source provenance does not substitute for measured workload counters.

The matrix used the same 80 source-file contents as the correctness smoke.
Its manifest uses a different serialization and SHA-256:
`bf5d41912549d696c3983306669d1dd1f681356eafbf66ad8b4462abcc62f13f`.
All per-file hashes matched; a different manifest hash is not a source change.
The run covered all workload/size cells on CPU 0 through runner 2,
with a balanced 39 Native-first and 39 Rust-first schedules.
Evidence: `matched-final-20261008T075031Z-4c9545c5/matched-final-ledger.json`,
SHA-256 `0cf553ae68156376672c65ef9dc4b74597d16f3f98ae92a6ad912d7953cba63c`.
The canonical [matched results and provenance](../bench/README.md#final-matched-results)
and [all-cell numerical table](../bench/README.md#all-26-cells) live in the benchmark README.
The comparison is complete, but performance parity is not achieved.
Large map mutation, sync generation and cold diff are substantially slower in Native.
Repeated cached full/subtree diff phases are faster; their setup and whole-process costs remain worse.
Phase gains do not imply whole-process gains.

The bounded ownership audit's final static recheck found no residual finding in its inspected scope.
It confirmed sidecar reservation before graph/op/log publication and aligned metadata readers
(`src/doc.zig:4767-4825,5853-5856`), not runtime safety in every source state.

Native diagnostic capture also completed without source-fingerprint changes.
Its ledger records 16 attempts and 11 unique legacy-default smokes:
ten exited successfully with `LEAKS 0`; list-width normalization refused 50.39% coverage
against the unchanged 90% floor, an expected diagnostic refusal.
The insert guard passed, both direct regions reported `running`, and the profile recorded
318 samples with none lost. These are native diagnostic observations, not matched Rust results.
Evidence: `native-profile-20261008-WUTP4o/capture-ledger.json`.
The original hash-for-op-ID wrapper-path attempt has an unknown exit status.
The separate corrected-wrapper attempt captured child exit zero, hash `95791aa42f3360a0`,
and `LEAKS 0`; it does not retrospectively certify the original attempt.

The final production-C-allocator large-map and large-sync diagnostic profiles also completed
successfully, matched their frozen matrix outputs, and left source/binary fingerprints unchanged.
They are single whole-process profiles—not new matrix timings, speedups, or phase/caller attribution.
Counters exclude kernel execution; unresolved `[k]`/`[other]` labels do not establish kernel cost or resolved callers.
The [canonical benchmark results](../bench/README.md#final-matched-results) retain the profile detail.
Evidence: `matched-diagnostic-20261008-vuHQOy/capture-ledger.json`.

Earlier merge/sync CLI crashes exposed an invalid empty-array free and unsafe allocator-context comparisons.
A valid stateless allocator can leave its context pointer undefined.
The source repairs use the actual allocator/owner contract rather than inspect that undefined pointer.
The baseline correctness smoke and public allocator regression passed.
Native test roots intentionally link libc for the real `std.heap.c_allocator` fixture.
The production CRDT remains a Zig implementation.

Retained-log replay required two separate repairs: publish the prepared path map with its owned storage,
and canonicalize cached resident IDs through the same checked selected-document export used for events.
The seven-patch first-render record now passes.
The frozen complete Debug gate passed, but specific consumer fixes do not prove every failure path.
Inherent automatic `getMissingDeps` and `getChangeByHash` close pending work.
Their generic `ReadDoc` routes do not close. The Rust oracle now records the explicit trait route, not a mislabeled inherent call.
Malformed individual author decoding returns null; corrupt footer column encoding still returns typed `ParseError`.
Opaque footer bytes remain authoritative across reconstruction.

cmocka discovery is a development gate through the declared package environment.
The Rust oracle declares `sha2` directly rather than rely on an undeclared transitive dependency.
Checksum-corrupt fixtures are deliberate parser-refusal inputs, not damaged goldens to silently repair.

The target native public API is implemented.
The complete correctness gates and matched comparison above apply only to the frozen baseline, not the new candidate.
This is not an all-target build, complete case-for-case integration proof,
universal allocation-refusal or leak-safety proof, or blanket performance-parity claim.
The bounded static ownership review has no residual finding in its inspected scope.
The earlier native RLE before/after result is not a Rust speedup.

### Historical red checkpoints — superseded by the Debug gate above

The earlier full normal root had 2040 cases: 1991 passes, one skip, 44 failures, four crashes, and 209 leaks.
The earlier slow-path root had 2040 cases: 1990 passes, 46 failures, four crashes, and 209 leaks.
An intermediate root run still reported five leaks.
Those snapshots motivated production ownership repairs and stale-fixture corrections.
They do not describe the frozen complete Debug run. Focused failure-set runs also passed on earlier snapshots.
Their filtered helper-case counts are not complete-root counts or proof for the new optimization candidate.

## Historical round records

The following dated rounds preserve their original source, command, and measurement scope.
They are not the current API cutover's result.

## API, coverage, and uniform-splice round (2026-10-08)

Reference: Automerge 0.12.0 at `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`. Compiler: Zig 0.16.0.
`doc.ChangeMetadata` and `ChangeMetas` own their bytes, with explicit `deinit(gpa)` contracts.
`Document.getChangesMeta`, `getChangeMetaByHash`, and `hashForOpid` expose the reference reader surface.
Named operation lookup now repairs actor slots. The owned public consumer passed after document teardown.

The metadata consumer checks six Rust changes, seven frontier sets, ownership, allocation failures, and actor renumbering.
The clock consumer checks seven subsets, 49 coverage pairs, and 49 merge pairs.
Three upstream regressions now cover marked bundles, losing text iteration, and UTF-16 incremental bundle loading.
Six splice regressions cover canonical boundaries, fallback, borrowed bytes, bounds, and allocation failure.
The existing real recovery case also checks metadata refusal and resumed reads.

The general uniform-run splice keeps eligible data compressed instead of materializing and re-encoding it.
Default insertion used 46.8% fewer whole-process instructions across three accepted processes per build.
Full-size growth failures remain recorded. They do not support an accepted full-size median.
The [measured round](../bench/README.md#10-measured-uniform-splice-round--2026-10-08) records fingerprints, profiles, guards, and raw evidence.
The separate post-verification full-size control still rejected all three baseline runs and one of three final runs.
It provides no accepted paired full-size median. No guard changed and no process was rerun.

| Exercised check | Result |
|---|---|
| Full native Debug suite | 74/74 steps. 2,105 pass, one skip. |
| Full native ReleaseSafe suite | 74/74 steps. 2,105 pass, one skip. |
| Forced slow-path ReleaseSafe suite | 6/6 steps. 1,832/1,832 pass. |
| Reference conformance and live save interoperability | 30/30 steps. All 11 vectors and six live save cases pass. |
| Production shared C corpus and header ABI gate | 9/9 steps. 18 fixtures, five valid, no failures. |
| ReleaseFast production install | 4/4 steps. |
| Zig formatting | `zig fmt --check .` passed. |

At that snapshot, held native lifecycle, full load options, rescue, and the shared-head predicate were absent.
Those prerequisites now exist in source; current public parity remains unchecked.
The [integration ledger](#integration-coverage-ledger-2026-10-08) replaces unsupported total-coverage claims with exact cases and prerequisites.

## List traversal region measurement

`--region-instructions list-width` now counts the existing `read-list` region through Linux `perf_event_open`.
It keeps the original element counts, walk counts, correctness checks, and default-mode 90% guard.
The separate `REGION` record does not qualify a whole-process `perf stat` count.
The counter excludes setup, separate verification, teardown, kernel execution, and child threads.
Missing permissions, unavailable counters, short reads, and incomplete scheduling coverage fail without a metric.

Three independent ReleaseFast processes passed at each size on logical CPU 0.
The [region measurement table](../bench/README.md#measured-region-counts) records paired counts, elapsed times, load, and binary hash.
Instruction cost was nearly proportional to element visits at these two points.
No traversal algorithm changed, and no speedup or general complexity bound is claimed.

`zig build bench-test` and its ReleaseSafe variant each passed 5/5 steps and 3/3 deterministic cases.
Those cases also participate in `zig build test`.
The focused ReleaseSafe held-cursor control passed 3/3 cases including root declarations.
The default ReleaseFast static build passed 4/4 steps.
The full benchmark passed a compile-only `x86_64-windows-gnu` check.
`zig fmt --check .` passed.

Three- and four-repeat traces confirmed that each reported count belongs to the selected elapsed-time median.
The odd-repeat check selected a non-last sample and compared its count directly with the kernel read.
Child-only seccomp checks denied open, enable, disable, and read calls.
All four checks failed without a metric. Failure traces confirmed counter-descriptor cleanup.
CLI checks rejected missing, different, mixed, and duplicate workload selections.
Help/list behavior and a normal `BENCH segmentation` run still passed.

The stderr `ms/iter` diagnostic previously printed the entire sample's elapsed time.
An arithmetic smoke failed before the repair.
The diagnostic now divides by the iteration count.
All six final region samples passed that check without a new wording-pinned test.

## GitHub issue repair (2026-10-07)

The clean local parent and fetched GitHub `main` both resolved to `1e9f6a1e`.
GitHub had six open issues and no open pull requests.

- **#1:** remeasured all four scaling workloads at default and full sizes.
  [The fresh benchmark table](../bench/README.md#fresh-process-counts-and-guard-results--2026-10-07)
  records instruction counts, load averages, phases, and guard results.
  Both list runs rejected subject attribution. The full insert run rejected its growth ratio.
  The guards and workload sizes remain unchanged. Rejected counts are not accepted subject measurements.
- **#2:** removed the incorrect fixed chunk size from `src/doc.zig`.
  Its issue body duplicates #3, but its title describes this separate comment.
- **#3:** both sync `splitStream` fixture helpers now use `ChunkStream`.
  The helpers are test-only, not production message readers.
  Their allocation witnesses failed before the fix: six required output allocations versus seven actual allocations.
  Both pass after the fix, including allocation-failure sweeps and cleanup after a malformed later header.
  No live sync performance gain is claimed.
- **#4:** `src/hydrate.zig` records why `winnerKey` retains sequence formatting.
  Valid map hydration uses map keys. The direct helper test checks the sequence buffer's ownership.
  The issue's op-module citation does not identify this helper.
- **#5:** no code change. The optional cross-check deliberately walks the object.
  Historical reads also use the slow algorithm independently of `-Dslow-path`.
  The existing source contract in `OpSet.seekListOpid` records both decisions.
- **#6:** `zig build ctest-shared` passed all 18 corpus entries.
  All five valid documents passed save/reload, commit/hash/value checks, and bidirectional encoded sync.
  The consumer has a `libzautomerge.so` dependency and a build-generated RUNPATH.
  Its fixture table comes from the canonical Zig manifest through a deferred host generator.
  The package-only build passed without `test/` and installed only the static library and header.

The focused Debug command passed seven cases.
It covered both allocation witnesses, both fixture callers, the hydration key test, and two root declarations.
The forced slow-path command passed five cases, including the invariant cross-check and both allocation witnesses.
The new shared C gate passed nine build steps. It requires libc but not cmocka or the Rust oracle.
These checks do not certify the existing cmocka suite.

### Mark borrow repair found during verification

The first integrated ReleaseSafe run passed 2087/2089 cases, with one skip and one failure.
The failing patch replay case lost `bold`: the mirror had no marks while the document had one.
An isolated Debug run passed. The isolated ReleaseSafe run reproduced the failure.

`src/opset/batch.zig` returned a mark-set pointer from a by-value optional parameter.
That pointer did not refer to the caller's live set.
The repair removes the helper and borrows the caller's local payload until the sink finishes its synchronous copy.
The existing replay regression and two mark controls now pass in ReleaseSafe, five cases including root declarations.

A public ReleaseSafe consumer also passed merge, active incremental diff, and mirror replay with exact text `ab` and `bold=true`.
It destroyed the receiver before replay to check the returned patches' ownership.
No new permanent test duplicates the existing failing consumer-visible regression.

The final `test ctest-shared -Doptimize=ReleaseSafe` run passed 70/70 build steps.
It passed 2088/2089 tests, with one skip and no failures.
The shared C consumer passed all 18 fixtures, including all five valid documents.

After the repair, `conformance save-interop -Doptimize=ReleaseSafe` passed 28/28 build steps.
All ten golden vectors matched. Live save interop verified all six cases.
The final default static build passed 4/4 steps, and `zig fmt --check .` passed.

## P2/P5 repair evidence (2026-10-04)

Scope: Zig 0.16.0, x86-64 Linux, reference commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`. Each row certifies only its named
source path and execution.

| Check | Observed result |
| --- | --- |
| Final integrated Debug command | 69/69 steps succeeded; 3722/3723 Zig tests passed, one default-run skip, no failures. Includes `test slow-path ctest conformance save-interop`. |
| Optimized-tree integrated Debug command | `zig build test`: 2006/2007 Zig tests passed with one default-run skip (62/62 steps). `zig build slow-path ctest conformance save-interop`: 1744/1744 passed (40/40 steps). Includes the ~14 new optimization tests. All ten golden vectors matched the reference; live save interop 6/6; the C ABI suite ran. |
| Optimization round 1-8 (2026-10-05) | `zig build test`: 2035/2036 passed, one skip (62/62 steps). `zig build slow-path ctest conformance save-interop`: 1773/1773 passed (40/40 steps). All ten goldens matched; live save interop 6/6; the C ABI suite ran. ~35 new tests. |
| Native benchmark, ReleaseSafe, `perf stat -e instructions` | Seven workloads in `bench/zautomerge_bench.zig`, each reproducing a suite-dominating case. Instructions retired, optimized tree: segmentation 0.89 B (was 10.57 B, **11.85x**); indexed-delta 1.61 B (was 2.54 B, **1.57x**); slab-merge 0.46 B (was 0.58 B, **1.26x**); prefix-bool 0.65 B (was 0.87 B, **1.33x**); update-object 12.47 B (was 18.76 B, **1.50x**). Checksums byte-identical across the pair wherever both were measured. |
| Four-target cross matrix, optimized tree | `x86_64-linux` 2006 tests `tests_complete`; `powerpc64-linux` 2006 tests `tests_complete`; `x86_64-windows` build pass, run `runtime_unavailable` (no wine64); `aarch64-linux` `per_build_timeout`. The big-endian row is a gain over the pre-optimization run, which timed out there too. |
| Default native test roots, Debug | 1992 passed, one skipped. The library root passed 1729 with one skip; all 118 upstream document cases passed. |
| Forced slow-path library root, Debug | 1730/1730 passed, including the case skipped in the default run. |
| Ten golden vectors and live save interop | Every golden file matched the reference; the live verifier reported 6/6 cases verified. |
| Unfiltered hexane integration module, Debug | All 8 cases passed, including both exhaustive splice sweeps and the 100,000-operation slab-merge invariant case. |
| Real boolean column CLI | All 187 deletion prefixes, lengths 14 through 200, produced exact canonical bytes and loaded rows. Before the repair, the 18-row prefix encoded the wrong rows; the 200-row exhaustive case refused an interior zero count. |
| Final shipped-header and generic diagnostic probes | 9/9 verified: one positive compile and eight intended diagnostic refusals. |
| Fetched native and C consumers, Debug | 8/8 build steps succeeded; both executables ran against the final URL-and-hash package. |
| Fetched native and C consumers, ReleaseFast | 8/8 build steps succeeded; explicit runtime checks remained active. |
| Final hexane source ledger | All 272 covered declaration anchors resolve; 14 occurrences have explicit exclusion reasons. This is source-review evidence, not runtime proof. |

## Optimization round 3, measured (2026-10-05)

Two library changes and three new gates. Baseline is round 2's post-change
figure (commit 00569a54), ReleaseSafe `perf stat -e instructions`.

| Workload | Round 2 | Round 3 | Change |
| --- | --- | --- | --- |
| update-object | 11.522 B | 11.532 B | -0.09% |
| slab-merge | 463.2 M | 461.0 M | **+0.48%** |
| indexed-delta | 1.616 B | 1.615 B | +0.06% |
| prefix-bool | 656.9 M | 656.5 M | +0.07% |
| mark-index | 712.4 M | 713.4 M | -0.14% |
| segmentation | 891.5 M | 891.5 M | flat |
| mark-at-end | 1019.5 B | 1019.5 B | flat |

**This round bought nothing measurable on instructions, and that is the honest
result.** The two changes are real but aimed elsewhere:

* **#4, streaming the load chunk list** (implemented this round; it had been
  dropped in round 2 as "the caller blocks it"). `ChunkStream` frames one chunk
  at a time and `doc.zig`'s load path adopts it, so a document load no longer
  holds one entry per chunk. It removes **allocations and retained bytes on
  load**, not instructions on a benchmark that never loads in a loop. Its gate
  is the `doc.jsonl` conformance vector and the totality cut sweep, both green,
  not an instruction count.

  **Two corrections, recorded 2026-10-06 (round 5).** The entry is
  `@sizeOf(chunk.Chunk)` = **72 bytes**, not 40: two `[]const u8` (`data` and
  `frame`), a 33-byte `?ChangeHash`, four checksum bytes and the type byte
  (`src/storage/chunk.zig:97-131`). The earlier claim that `splitStream`
  materialized a list per live sync message was incorrect: both callers are fixture tests.
  The 2026-10-07 repair streams those helpers too.
  `parseChunks` remains in its own tests, their allocation comparisons, and the storage totality harness.
  This does not establish a production sync allocation reduction.
* **`rebuildAggs` no longer slack-fills.** `shrinkRetainingCapacity`
  (`std/array_list.zig:1186-1189`) is the length assignment plus
  `@memset(slack, undefined)`, and nothing reads past the length. The removed
  fill was `old` entries — the bases carried INTO the rebuild, one per slab —
  so about 32 bytes an entry on a delta column: hundreds of bytes per splice,
  not kilobytes. The round-2 comment claiming it was a high-water mark of the
  largest slab count ever held was wrong and is corrected in the source.

**And the round found a real defect by the way.** `ChunkStream.verifyPartial`
handed its `Verified` the cursor position where the verify walk **stopped**
instead of where it **started**, so every second pass framed a header out of
the bytes behind the prefix. It broke 35 tests at once and had never been
exercised, because no committed test used the load path's own shape — take the
head, verify the remainder, read the remainder. A test for that shape is now in
`chunk.zig`.

## The new gates, and what one of them found

Three audit findings had no gate and were therefore unmeasurable. All three are
reachable through the public module surface, so all three are now measured:

| Gate | Instructions | What it measures |
| --- | --- | --- |
| `sync-roundtrip` | 119.7 B | the per-hash sorted insert into `State.sent_hashes` |
| `hash-for-opid` | 627.8 B | the O(C) scan behind `hashForOpid` |
| `list-width` | **4 690.8 B** | `elementWidth` -> `elemidAt`'s five cursors per element |

**`list-width` is the largest number in this document and it is the next
round's target.** At 50 000 elements and 2 walks it retires about **4.7e7
instructions per list element**, which is quadratic behaviour, not a constant
factor: `elemidAt` is reached once per element and a read of an N-element list
does not go like the number of elements it returns. That is 3.8 million times
`update-object`, and it is the same `elemidAt` optimization 8 hoisted the
five cursors of in round 2 without removing the walk behind them. Round 2's
change made the cursor reusable; it did not make the position query O(1).

## Round 3 gates on this tree

`zig build test`: 2042/2043 passed, one default skip (62/62 steps).
`zig build slow-path ctest conformance save-interop`: 1780/1780 passed (40/40
steps). All ten goldens matched the reference, live save interop 6/6, the C ABI
suite ran, `zig fmt --check` clean, and the benchmark reports `LEAKS 0` across
all ten workloads.


## Optimization round 1-8, measured (2026-10-05)

Eight audit findings were dispatched in parallel across disjoint modules. The
result is stated without inflation: **one of the eight moved the instruction
count and the other seven did not.** Figures are ReleaseSafe
`perf stat -e instructions`, stable to 0.0002% on this host.

| Workload | Before | After | Change |
| --- | --- | --- | --- |
| update-object | 12.464 B | 11.522 B | **-7.6% (1.08x)** |
| segmentation | 0.892 B | 0.892 B | flat |
| indexed-delta | 1.615 B | 1.616 B | flat |
| slab-merge | 0.463 B | 0.463 B | flat |
| prefix-bool | 0.653 B | 0.657 B | flat |
| mark-index | 0.712 B | 0.712 B | flat |
| mark-at-end | 1019.3 B | 1019.5 B | flat |

**Where the win came from.** Optimization 5 — skipping `refitScratch` when the
successor edge list is empty — is the only change a profile can see:
`refitScratch` and `maxSuccCount` no longer appear in `update-object` at all,
and the 7.6% is exactly that.

**And why the other seven did not, which is the useful part.**

* **1, hydrate double-copy.** Removed one copy per map key and one per text.
  The copies were not what the profile was in, and the borrow that would have
  removed the second is illegal: `transact.zig` parks mirror maps across a
  commit that interns new keys into the arena they would point at.
* **2, batch the update writes. Not implemented, and that is the finding.**
  `Batch` does preserve DFS — op ids are position in `pending` — but a staged
  row is invisible to the `seekOpsByMapKey`/`queryInsertAt` that place the next
  one, so batching would break register row order (R2/R3). The runs it would
  merge are length 1 on this workload anyway.
* **3, hash once.** Removed a second SHA-256 per change body **on load**. No
  benchmark workload loads in a loop, so it cannot show here; its gate is the
  `change.jsonl` conformance vector, which stays byte-identical.
* **4, stream the chunk list. Dropped.** The three `chunks[0].typ` reads in
  `doc.zig` make a pure iterator impossible without restructuring the caller,
  and the list is 7 allocations per load of which only one scales.
* **6, anonymize arena.** A retained-bytes win, not an instruction win. Its
  gate is peak RSS on a doc-building script, which no benchmark here runs.
* **7 and 8.** Correctness-preserving and effect-neutral here: `prefix-bool`
  moved -0.7% and `mark-at-end` flat.

**The real remaining cost, for the next round.** `update-object` is still 40.5%
`compiler_rt.memset`, and that is per **splice**, not per row: `Columns.splice`
stages 21-22 columns and `Column.stageSplice` does a `tree.clone`,
`owned.resize(slabs.len+1)` and an `agg_before`/`slabs` `appendSlice` per
column, after which `rebuildAggs` reweighs every slab from the first touched.
That belongs to `src/hexane/column.zig` and is not reachable from
`transact.zig`.

**A latent defect this round found, not by optimizing.** `splitToBudget` cut at
`max_segments` runs of the run table, so a **boolean** piece cut out of a `true`
run came one run over budget once its own leading pad was written, and
`checkInvariants` refused the column. No committed test had ever run a budget
below default, so nothing had caught it. Upstream counts the pad inside the
budget (`bool.rs:312-317`, `:322-326`); the cut now spends it. Ledger entry 28.

## Optimization round 5 (2026-10-06)

Round 5 optimized the paths the four benchmark gates had just made visible,
gated the last ungated fast/slow cross-check, and found that three of the
round-3 audit's own claims were wrong. **No instruction count appears in this
section.** The `insert-loop`, `hash-for-opid` and `list-width` figures are being
re-measured, and the numbers recorded for them in *The new gates, and what one
of them found* and in *Optimization round 1-8* are left exactly as they stand
until that re-measurement replaces them. **The "what it measures" column of
that gate table is superseded along with its figures**: all three of its
subjects changed mechanism in round 5, and this section says what each is now.
What follows is source inventory: every change with the site a reader can check,
plus the corrections. Whether a change moved a count is the re-measurement's
statement to make, not this section's.

### What changed, and where

| Change | Site | Shape |
| --- | --- | --- |
| `copyFold` copies a mark fold | `src/iter/spans.zig:269` | `O(names²)` per call → `O(names)` |
| Span mark flattening is stamped, not walked | `src/iter/spans.zig:906`, read at `:733`, counter at `:801` | `O(R·M)` over a run of `R` rows under `M` names → `O(R+M)`, through `SpanState.marks_epoch` |
| `ChangeGraph.updateHeads` marks then compacts once | `src/change_graph.zig:2141-2168`; scratch `:485`, `:491` | `Θ(C²)` → `Θ(C+H)` per change, through `heads_stamp`/`heads_epoch` |
| `Column.weightOf` folds a slab once | `src/hexane/column.zig:1962`, `:2176`, `:2423`, `:3001`; `src/opset/columns.zig:269`, `:428` | `O(rows)` per slab → `O(1)`, for the prefix, delta and meta-prefix codecs |
| `OpSet.addSucc` takes its successor width from the edges it just wrote | `src/opset/op_set.zig:2433`, the count from `writeSuccColumns` (`:2706`), applied through `reserveScratchTo` (`:2452`, `:2816`) | one pass over `succ_count` per row, gone — and `OpSet.undoSucc` (`:2606`) still calls `refitScratch` (`:2659`), correctly, because an undo cannot name the width it needs |
| `ListRange` holds one element cursor | `src/iter/list_range.zig:1005`, used at `:923-941` | ten column cursors per element → one, moved |
| `sync` merges a message's hashes in one pass | `src/sync/state.zig:396`, called at `src/sync/protocol.zig:588` | `O(k·n)` element moves per message → `O(k log k + n + k)` |
| The storage chunk walk allocates nothing | `src/storage/chunk.zig:524`, adopted at `src/doc.zig:3857-3860` | 13–25 allocations and a 5.1 MB peak at 50 000 chunks → zero |
| `document_chunk`'s compressing writer never holds the uncompressed body | `src/storage/document_chunk.zig:984`, asserted by the test at `:2760` | peak 333 370 → 74 961 bytes |
| `cursor.getCursor` dropped its second descent | `src/cursor.zig:784-795`, module doc at `:142-146` | one `O(rows in the object)` `seekListOpid` per cursor resolve, gone |
| `PatchBuilder.appendMarks` appends to the array it already names | `src/patches.zig:2051`, doc at `:2029-2051` | `O(n²)` → `O(n)` in a patch's mark count |

**Three of those rows are not instruction counts, and are not offered as
substitutes for them.** The `sync` row's cost is element *moves*, which the
round-5 measurement put at 50× fewer at the gate's default size and 100× fewer
at `--full`. The two storage rows are allocator counters: a peak live-byte
high-water mark, and an allocation count. A `perf stat` pair is still the only
evidence that any of this moved the instruction count, and none of it is
recorded here.

### The gates: five cross-checks, not two readers

| Cross-check | Gate in this port | Upstream |
| --- | --- | --- |
| `OpSet.seekOpsByIndex` | `src/opset/op_set.zig:3746` | `#[cfg(feature = "slow_path_assertions")]`, `op_set.rs:645-649` |
| `OpSet.calculateMarksAt` | `src/opset/op_set.zig:4788` | the same feature, `automerge.rs:1587-1591` |
| `OpSet.markSetAtIndex` | `src/opset/op_set.zig:4976` | the same feature, `automerge.rs:1939-1943` |
| `OpSet.seekListOpid` | `src/opset/op_set.zig:3953` | a plain `debug_assert_eq!`, `op_set.rs:846` |
| `OpSet.queryInsertAt` | `src/opset/op_set.zig:4346` | a plain `debug_assert_eq!`, `op_set.rs:583-598` |

Upstream pays nothing for the last two only because its release profile leaves
`debug-assertions` off (`rust/Cargo.toml:14-16`), not because it gates them.
Round 5 added `seekListOpid`'s gate, and that was the last ungated cross-check
on a hot path: its slow arm is `iterObjAndFind` plus a `Grouped` walk over
**every** register in the object, so an always-on comparison is
`O(rows in the object)` on `Transaction.joinBlock`, on `OpSet.parentObject`'s
`.seq` arm (`Parents.next` and `read.parents`) and on `PatchBuilder.getPath`
through `doc.objectParent`. Three tests call `seekListOpidFast` and
`seekListOpidSlow` directly and compare both answers in every build, so the gate
decides who pays for the comparison, not whether it is made.

**One cross-check is still ungated**, and it is the cheap one:
`OpSet.findOpByIdAndVis`, whose slow arm stops at the end of the row's own
register (`op_set.rs:1131-1132`).

### Three of the round-3 audit's claims were wrong

* **"`ChangeGraph.opidToHash` has no public entry point at all."** False. It is
  `pub` at `src/change_graph.zig:1704` and has been since that file was written;
  `Transaction.hashForOpid` (`src/transaction.zig:433-436`) now delegates to it,
  and it was already called from `src/change_graph.zig:3279` and, from a test,
  `src/change.zig:1142-1146`. No new `pub` was needed and none was added.
* **"A document load no longer holds one 40-byte entry per chunk."** The size
  was wrong: 72 bytes, as above.
* **"The chunk list is never materialised."** True of `Document.load` and of
  nothing else, as above.

### The fixtures that were measuring the wrong thing

* **The sync sent-hashes equivalence fixture generated its hashes ascending.**
  `hashFor` (`src/sync/state.zig:818`) is ascending in `n`, so inserting them
  one at a time landed every insert at the tail of the sorted list and the
  memmove the comparison exists to exercise never ran. The test now feeds the
  one-at-a-time arm a scattered permutation — `hashFor((n * 37) % count)`
  (`:846`) — and still requires the bulk merge to produce the same set
  (`:834`).
* **The benchmark's phase accounting dropped a phase.** `phase_max` in
  `bench/zautomerge_bench.zig:341` is 4 and `addPhase` (`:366-372`) returns
  silently on the fifth, so a workload recording five phases reports four. No
  sentence in this file or in `bench/README.md` quotes a phase count, so nothing
  above needed correcting; the harness is not this document's to change, and the
  count of phases a workload records is the harness's own business.

## Data-oriented audit (2026-10-05)

A read-only audit of the optimized tree: twenty slices across disjoint modules,
following the `data-oriented-design` skill — workload shape and cardinality,
access matrix, authority and lifetime per structure, then at most two proposals
each with a causal mechanism, a countercondition, and a validation gate. Nothing
was implemented from it. Every number below is either measured on this tree or
marked as needing a gate that does not exist yet.

**The load-bearing negative result.** A layout rewrite is not available here.
`Segment` is 56 bytes and already cache-line aligned; `Columns.splice` writes
every field of all 21 columns, so field order is not a lever; the btree holds two
to three slabs on every measured workload. SoA and ECS were rejected everywhere:
these are single-owner, bounded-lifetime structures with no recurring
cross-cutting scans. One more is ruled out by the port's own tested contract —
`rle.skipLiterals` may **not** become a length-only walk, because the suite
documents that this port chose to keep the refusals a full decode raises, and
upstream's `.unwrap()` only gets away with it on a column validated at load.

**Ranked by measured leverage on the seven benchmark workloads.**

| # | Finding | Mechanism | Countercondition | Gate |
| --- | --- | --- | --- | --- |
| 1 | The hydrated mirror copies every map key and every text **twice**; the op set already interns those bytes (`hydrate.zig:1077`, `:1324`) | fewer bytes and fewer dependent loads per hydrated value | `transact.zig` holds `*Map` addresses, so mirror maps must stay stable | `update-object` + instructions |
| 2 | `updateMapValue`/`updateListValue` bypass the `Batch` layer that already splices in bulk (`transact.zig:1716`, `:1784` vs `:2486`) | one splice per batch instead of per row | DFS→BFS op-id order would change every change hash; forbidden | `update-object` + instructions, hashes byte-identical |
| 3 | Load SHA-256s the same change body twice — header checksum then change hash (`chunk.zig:531` vs `change.zig:431`); upstream computes it once | one fewer pass over identical bytes | the header keeps 4 bytes, so the hash must be published rather than recomputed | `conformance` `change.jsonl` |
| 4 | `Document.load` materializes the whole chunk list where upstream streams (`doc.zig:3859`) | less retained memory and fewer reallocs per load | `loadIntoWith` reads `chunks[0].typ` three times | `conformance` `doc.jsonl` + save-interop |
| 5 | `refitScratch` runs per row from `addSuccWithUndo` even for an empty edge list (`op_set.zig:2487`) | one fewer allocation and pass per row | must keep every path that widens a successor span | `update-object` + instructions |
| 6 | `Anonymize`'s arena never resets, so high-water is O(all changes) | retained bytes, not instructions | no arena slice may escape `rewriteChange` | peak RSS on a doc-building script — **runnable without the benchmark** |
| 7 | `bool.Decoder` has no `nextRunMax`; the boolean prefix weight re-runs per item per slab | O(items) → O(runs) per splice | unlike `rle`, bool carries no payload, so the refusal-parity argument does not transfer | `prefix-bool` (0.65 B) + instructions |
| 8 | `elemidAt` builds five column cursors per call (`op_set.zig:3397`) | fewer dependent loads per element | a hoisted cursor must stay valid across the diff kernel's advance | `mark-at-end` + instructions |

Three more are real but have **no gate today** and stay proposals until one
exists: the per-hash sorted insert in sync's `sent_hashes`, `hashForOpid`'s
linear scan, and `listRange`'s six locates per element.

**Superseded, 2026-10-06.** All three were gated in round 3, as
`sync-roundtrip`, `hash-for-opid` and `list-width` in
`bench/zautomerge_bench.zig`. The sentence is left as the audit wrote it on
2026-10-05, because "no gate today" was true that day. Two of the three
subjects have since changed mechanism — `sync-roundtrip` times a bulk merge and
`hash-for-opid` an interval query — and the round-5 section records that.

**Limits on this audit.** It is source analysis plus the instruction counts
already measured; no proposal was built or timed. Every row above is an
unvalidated hypothesis until its gate runs. The audit also cannot speak to the
`aarch64-linux` row: that target's evidence is a phase timeout, not a profile.

**The next suite-time win is library code, not test code.** A separate read-only
slice measured the harness side. The suite's largest case, the segmentation
oracle, is entirely test code, and the optimization round already took it from
164.87 s to an inferred floor; what remains is ~100% its own `O(n²)` prefix
visits (105 132 250 of them), and **no safe faster oracle exists** — the only
`O(n)` primitive available is the `GraphemeBoundaryIter` the code under test is
itself built on, so reusing it would make the test tautological. Its slice
appends are 11 501 steps, 0.011% of that. Two genuine test-side quadratics
remain and both are small: `fuzz_slab_merge_invariant`
(`src/hexane/hexane_test.zig:474`) re-slices and re-reads the whole column after
every operation, and `fuzz_prefix_column_bool`
(`src/opset/columns.zig:3743-3747`) runs a `Theta(len)` `Column.get` sweep after
every operation. Meanwhile 88.7% of the rollback case is library (`updateObject`
is 47.0 s of 52.96 s). So the ranked table above is the right place to spend the
next round, and no test-cost work is proposed on the strength of this audit.

**Final native/C package snapshot:**
`zautomerge-0.0.0-FlN8sHVpkgD8pe8q5n02h8J7rKw9D_J7N-YJneM1JmV9`.
The consumer manifest used an HTTP URL and this hash, not a path dependency.
The local package server was stopped after both consumer modes passed.

**Boolean seam defect:** a standalone merged count decodes from false parity,
even when it belongs to a true run in the column. `Column.encode` now retains
the preceding tail value when equal boolean runs merge
(`rust/hexane/src/bool.rs:855-857`). The existing exhaustive case failed before
the repair and passed afterward.

## Verification recovery evidence (2026-10-04)

This section records what a timed-out and then cancelled verification run
actually measured, and what was changed in response. It supersedes nothing
above: the P2/P5 rows describe the source those checks ran against, and this
section adds the test runner, the profiling they enabled, and the limits that
are still open.

| Check | Observed result |
| --- | --- |
| Cancelled `zig-gate` cross section | `x86_64-linux` finished at 1992 tests passed; `aarch64-linux` hit `per_build_timeout` (3600 s); `powerpc64-linux` was cancelled in flight. Cancelled work is not a pass. |
| The aarch64 timeout, named | `upstream_doc_test.test.rollback after a save and load of a deep hydrated root map` — 117 of 118 passed, that case alone timed out after 15m 0.82 s against `--test-timeout 900s`. |
| The same case natively, Debug | 52.96 s of that root's 100.3 s total. Per-step, `updateObject` over the hydrated root is 47.0 s; `hydrate` twice is 2.4 s each; save, load and rollback together are under 0.3 s. |
| Why that is not a slow path but a slow host | 47.0 s of Debug at one core is roughly 850 s under `qemu-aarch64` user-mode emulation, which is what the 900 s per-case budget measures. The budget is not raised to fit it and the case is not cut down. |
| Custom test runner, `zig build c-abi-test` | 6/6 steps, 21/21 cases, and the printed record footer and slowest-case table match the run. |
| Custom test runner, upstream document root | 118/118 cases; the three cases over the 10 s stderr threshold were named with their durations, and the footer ranked all ten slowest. |
| Custom test runner, `x86_64-windows` | The `c-abi` root compiles to `test.exe`; the run step then refuses to spawn a foreign binary, which is the state the cross profile already expects for that row. |
| `zig fmt --check .` | Exit 0 after the runner was formatted. |
| `zig-pkg/` fetch cache | Three extracted copies of the served package were untracked and deleted, and `.gitignore` now names the directory. It is a `zig fetch` cache, not source. |
| `zig build test`, Debug, all fifteen roots | The fifteen case-record footers read after that run summed to **1992 pass and 1 skip across 1993 cases, 0 fail** — the same 1993 the gate has always run. The library root reported 1729 pass + 1 skip of 1730 in 1579 s; the upstream document root 118/118 in 146 s. A later duplicate run of the same step, cancelled at its own deadline, re-entered the library root and truncated that root's record file, so only the other fourteen footers are still on disk. |
| `zig build slow-path ctest conformance save-interop` | **40/40 steps succeeded.** The forced slow-path library root passed **1730/1730** in 1287 s, including the case the default run skips; the C ABI suite ran; all ten golden vectors matched the reference (`doc`, `change`, `sync`, `diff`, `converge`, `converge-parallel`, `codec`, `clock`, `hexane-regression`, `save-interop`); the live save verifier reported 6/6. The slow-path root's own record names its slowest case, `hexane.column.test.fuzz_column_save_load_after_mutations`, at 43.4 s. |

**The changes that measurement justified, and the one it did not.**
`Column.reanchorAfter` now reads the row's wire value out of the run sequence
the walk already holds instead of calling `wireRange` to rebuild it, removing
one allocation and one full slab walk per prefix/delta splice. `zig test`
against `hexane.column.test.fuzz_indexed_delta_column` — 200 trials × 400
splices, the heaviest `reanchorAfter` caller — passes at 163.60 s. A
candidate that gave single-row `Columns.splice` stack buffers was measured,
showed no effect on the 47.0 s (`updateObject` stayed at 48.6 s), and was
reverted rather than kept on a hunch.

**What is still open.** No release-mode (`ReleaseSafe` or `ReleaseFast`) run
of the library root has completed on this source, and the four-target cross
matrix has not been re-run since the runner landed. Both are named as gaps
here rather than counted as passes.

## API-design checkpoint evidence (2026-10-04)

The API-design repair was checkpointed as `5b4b36e4`, without a push.
The measurements in this section describe that source snapshot, before the P2
and P5 changes below. The package hash identifies its frozen native/C sources.
The read-only reference is Automerge 0.12.0 at
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`.
The compiler is Zig 0.16.0 on x86-64 Linux.
No result here certifies another compiler or target.

The repair closes 194 individually tracked findings across 17 audit slices.
The source review covers all 15 topics in `zig-api-design`.
[API.md](../API.md#api-design-decisions) records the contracts and eight contested decisions.
Those judgments have grade **analyst-inferred**, authored by the coding assistant.
Caller obligations have grade **documented-contract**.
The checks below provide version-scoped compilation or runtime evidence for named paths, not universal enforcement.

| Check, measured 2026-10-04 | Proof label | Observed result and scope |
| --- | --- | --- |
| Focused native text and encoding run | Runtime observation, Debug | 80/80 passed. Includes all eleven new range regressions, patch coalescing, hydrated deletion, and document reads in four encodings. |
| Shipped-header and generic diagnostic probes | Exercised compilation | 9/9 verified. The real header compiled. Eight malformed contracts failed compilation with the intended diagnostic. |
| Fetched native and C consumers, Debug | Exercised compilation and runtime observation | 8/8 build steps succeeded. Both executables ran against the URL-and-hash dependency. |
| Fetched native and C consumers, ReleaseFast | Exercised compilation and runtime observation | 8/8 build steps succeeded. Both executables used explicit runtime checks, not debug-only assertions. |
| `zig build` with a local scratch install prefix | Exercised compilation and install observation | 4/4 steps succeeded. The production C library and header installed. |
| `zig fmt --check .` | Formatter runtime observation | Exit 0 after all source writers finished. |
| Integrated `test slow-path conformance ctest` run | Exercised compilation and runtime observation, Debug | 58/58 steps succeeded. 3682/3683 Zig tests passed, with one default-run skip and no failures. |
| Native `test` roots | Runtime observation, Debug | 1965 passed, one skipped. The library root had 1716 passed and one skipped. All 118 upstream document cases passed. |
| `slow-path` library root | Runtime observation, Debug | 1717/1717 passed, including the case skipped in the default run. |
| Rust conformance comparisons | Runtime observation | All eight golden files matched: doc, change, sync, diff, converge, converge-parallel, codec, and clock. |
| C runtime suite | Runtime observation, Debug | 160/160 cases passed across 13 groups, against the production library. The shipped-header guard compiled in the same gate. |

The complete integrated command was:

```sh
zig build test slow-path conformance ctest -Dcmocka-prefix=../cmocka-prefix -j1 --summary all
```

The direct C report used the same built executable with its declared working directory, `test/c/suite`.
An initial direct launch from the repository root failed to open the relative load fixture.
The corrected fixture context passed all 160 cases. No source change was needed.
The integrated gate already supplies that working directory.

The diagnostic refusals cover function-width mismatch, an uncovered header function,
an uncovered enum tag, and malformed hydrate, Values, Shiftable, batch, and diff sink types.
The header guard checks 187 physical function signatures, 37 enum names across five enums, and five struct layouts.
Only `AMbyteSpan` and `AMitems` cross by value.
It does not check semantic pointer constness, nullability, sentinels, nominal enum identity, or reordered same-typed parameters.

**Historical text red/green evidence:** the range repair's focused run passed on that snapshot.
It covered the then-current UTF-8-buffer representation and its split-boundary refusal.
That owner has since been replaced with native-unit trees and owned lossy rendering.
The old refusal observations are not the current text contract or verification evidence.

**Package snapshot:** the final source archive has package hash
`zautomerge-0.0.0-FlN8sAVekAAUKQiHaBhEAd2noutJSvO2t5tLnDbwjqsJ`.
The consumer manifest uses an HTTP URL and that hash, not a relative path.
The archive contains the package's declared source, header, build files, and MIT notice.
One uninstrumented fresh fetch reported an illegal `unknown` file type for `src/hydrate.zig`.
The traced retry fetched the archive successfully. The ordinary cached fetch also succeeded.
This is an observed transport limit, not evidence of a source-file type change or a resolved compiler defect.

The native executable exercised entropy refusal, independent default actors, merge,
save/load, a local incremental patch, and truncated UTF-8 refusal.
Its allocation-refusal scenario freed the caller's payload, refused recovery once,
retried rollback, wrote one unique operation ID, and verified save/load.
Its UTF-16 scenario refused a split surrogate without mutation, deleted the complete supplementary scalar,
preserved the suffix, and retained the borrowed buffer on an out-of-range no-op.
The conflict scenario merged two branches, deleted one conflicting value, and replayed the resulting patches.
All eight combinations of actor order and text encoding retained the exact survivor.
The replayed mirror matched fresh hydration, and save/load preserved the merged document.
The C executable exercised null-input refusal, secure default creation, write/read,
a retained result concatenation borrow, the variadic join, and cleanup.

## Historical measurements

The sections below preserve measurements from 2026-09-30 and 2026-10-01.
Their commands and dates define their scope. They do not certify the repaired working tree.
The current evidence above supersedes those test totals.

## The shape of the thing

`zautomerge` is a direct Zig 0.16 translation of the `automerge` CRDT library
and its `hexane` storage engine, targeting a library that must read and write
the same document bytes, produce the same change hashes, and speak the same
sync protocol.

The upstream size, measured 2026-10-01. **Two scopes, both correct; they were
being compared as if they were one.** Over the two `src` trees alone
(`find …/src -name '*.rs' | xargs wc -l`):

| Crate | `src/` only | whole crate (`src` + `tests` + benches) |
| --- | --- | --- |
| `rust/automerge` | 54,589 | **64,979** in 163 files |
| `rust/hexane` | 29,683 | **32,664** in 39 files |
| **both** | **84,272** | **97,643** |

`plan.md` §2 quotes the right-hand column and `automerge-c` is 7,507,
`automerge-wasm` 6,708, `automerge-cli` 1,395, `automerge-test` 487 — all six
re-measured and all six correct. This file's earlier "about 98,000 lines, which
was wrong" was wrong about the *table*, not about the number: 97,643 is the
whole-crate total that `plan.md` §9 risk 8 rounds to 98k, and it is a different
measurement from the 84,272 this table now leads with.

Two things are normative and must be byte-exact: the document format, and
change hashes, which are SHA-256 over an encoded change. `save()` output is
deliberately *not* byte-identical, because DEFLATE is not reproducible across
implementations; equivalence is checked by loading the output with the Rust
reference and comparing the materialized document. See `plan.md` §1.

## Test state

**The library suite completes and is green.** That is the headline, and it
replaces everything this section said before it — "the library suite does not
complete", "905 passed; 13 failed", "861 tests pass", "1,130 tests pass" — all
of which were wrong in the way this section is written to prevent. The
non-terminating `a mark at the end of a long text is found at the end`
(`tests/text.rs:1121-1154`) and the `updateText inside an isolation keeps both
sides` failure are both gone; neither is skipped or filtered to achieve that,
because `src/root.zig`'s test block names the module each lives in and the run
below is the whole binary.

All four test roots and both gates, measured 2026-10-01:

```
$ zig test -ODebug -Mroot=src/root.zig
1604 passed; 1 skipped; 0 failed

$ zig test -ODebug -Mroot=test/fixtures_test.zig
All 6 tests passed.

$ zig test -ODebug -lc --dep zautomerge -Mroot=test/example_test.zig -Mzautomerge=src/root.zig
All 3 tests passed.

$ zig test -ODebug --dep zautomerge -Mroot=test/upstream_doc_test.zig -Mzautomerge=src/root.zig
All 117 tests passed.                      real 80s

$ zig build --summary all conformance
Build Summary: 18/18 steps succeeded

$ zig build -Dcmocka-prefix=../cmocka-prefix --summary all ctest
Build Summary: 5/5 steps succeeded          153 cmocka cases, 0 failed
```

| What | Measured | Command |
| --- | --- | --- |
| library suite | **1604 passed, 1 skipped, 0 failed** | `zig test -ODebug -Mroot=src/root.zig`, option off |
| fixture suite | **6 / 6 pass** | `zig test -ODebug -Mroot=test/fixtures_test.zig` |
| crate-root example suite | **3 / 3 pass** | as above, `-lc` and `--dep zautomerge` |
| ported upstream `tests/test.rs` | **117 / 117 pass** | `zig test … -Mroot=test/upstream_doc_test.zig` |
| conformance vectors | **8 vectors, all checked against the reference** | `zig build conformance` |
| C ABI cmocka cases | **153 run, 153 pass** (last measured; `abi_coverage.c` has grown since) | `zig build ctest -Dcmocka-prefix=<dir>` |

The example suite needs `-lc` because its third test reads one document through
`AMmapRange` and through `read.mapRange` in the same process
(the example step's own comment says why); `zig build test` passes it.
`zig build ctest` needs `-Dcmocka-prefix`, and **nothing else**: the prefix is
absolutised inside the build and the executable sets `each_lib_rpath`, so
`libcmocka.so.0` resolves from the binary's own RUNPATH whatever the working
directory is. **`LD_LIBRARY_PATH` is not required and this file previously said
it was** — that was true while the step set no rpath and absolutised nothing,
and it is stale now.

**What `zig build ctest` builds, in order**: the production static library
`libzautomerge.a` from `src/c/root.zig`; the **separate** ABI-check library
from `test/c/cabi.zig`, which compiles the real header and compares names,
by-value layouts and enum discriminants at comptime; then the suite executable,
linked against **the artifact and not the check**. A header/library mismatch in
the check is a build failure; a header/suite mismatch at link time is a link
error; a by-value struct whose layout diverged is neither, and only the check
catches it.

**The failure mode when the prefix is wrong is exit 127, not a compile error.**
`run_ctest` sets the step's working directory to `test/c/suite`, so a `-L`
directory that reached the binary as a **relative** RUNPATH entry resolves
against that directory rather than the repository root. The binary still
compiles; it then fails to launch:

```
error while loading shared libraries: libcmocka.so.0: cannot open shared object file
error: process exited with code 127 (expected exited with code 0)
```

**That is a build failure that is not one**, and the `...FAIL`-count rule does
not apply: this is neither a failing test nor a blocked run but a process that
never started. The build now absolutises the prefix before it reaches the
module, so `-Dcmocka-prefix=../cmocka-prefix` works and the historical advice to
pass an absolute path is belt-and-braces rather than a requirement.


## Integration coverage ledger (2026-10-08)

Count coverage from each case's operations and assertions, not names or declaration counts.
A declaration can omit an upstream assertion, replace a prerequisite, or occur inside a comment.
The earlier name-based and citation-based rankings were wrong and remain retracted.
The English-name convention helps locate cases. It does not prove case-for-case parity.

**Historical inventory, 2026-10-01.** The table below preserves the earlier count report.
Its ported totals are unvalidated as behavioral totals. They are not current gate proof.

| Upstream file | Reported upstream count | Reported port count | Source location |
| --- | --- | --- | --- |
| `tests/test.rs` | 140 | 140, unvalidated | `test/upstream_doc_test.zig` and others |
| `tests/batch_insert.rs` | 46 | 46, unvalidated | one file, two row-order assertions |
| `tests/diff_marks.rs` | 36 | 36, unvalidated | `src/marks.zig`, prefix `diff_marks:` |
| `tests/text.rs` | 21 | 26 blocks, not a case total | `src/read.zig`, `src/iter/spans.zig`, `test/upstream_text_more.zig` |
| `tests/text_encoding.rs` | 15 | 16 blocks, not a case total | `src/read.zig`, prefix `text_encoding:` |
| `tests/block_tests.rs` | 19 | 19, unvalidated | `test/upstream_block_tests.zig` |
| `tests/convert_string_to_text.rs` | 3 | 3, unvalidated | `test/upstream_convert_string.zig` |
| `tests/rich_text_fuzz_crash.rs` | 9 | 9, incorrect | That snapshot omitted the rescue case. Its source prerequisite now exists; exact current case coverage remains unchecked. |
| `tests/test_mark_patches.rs` | 1 | 1, unvalidated | `test/mark_patches_test.zig` |
| `tests/test_save_load_orphans.rs` | 3 | 3, unvalidated | `test/upstream_save_load_orphans.zig` |

The claim that all ten integration files cover every case is retracted.
The old `FAIL=0` report does not prove absent cases or unported API prerequisites.
One nominal `test.rs` case, `conflicting_unicode_text_with_different_widths`, is inside an upstream block comment.
Do not infer a new total by subtracting gaps from the historical 140.

### Selected proof from the 2026-10-08 round

The following three exact upstream regressions passed in that selected ReleaseSafe run.
Their assertion scope is described below. These are not current cutover gate results.

| Upstream case | Asserted behavior |
| --- | --- |
| `bundle_with_mark_columns_decodes_from_fuzz_trace` (`test.rs:135-152`) | A one-character text with a bold `ExpandMark::Both` mark bundles, decodes, and retains text, marks, and heads. |
| `doc_iter_spans_skip_losing_conflicting_text_overwrites_after_object_shift` (`test.rs:722-755`) | After concurrent text overwrites and merge, root-to-text iteration excludes the losing text and matches `text()`. |
| `incremental_load_preserves_text_encoding_for_all_change_chunk_types` (`test.rs:4144-4178`) | Uncompressed change, compressed change, and bundle loads retain UTF-16 encoding, heads, and materialized state. |

Bundle creation, document iteration, and compressed change loading are implemented.
They are not missing API prerequisites. The compressed-change case also has assertions in `upstream_doc_more.zig`, case 8.
That source evidence is separate from the three selected runtime results above.

The public Zig clock consumer passed 1/1 in ReleaseSafe.
`test/upstream_clock_test.zig` reads the Rust-generated `test/golden/clock.jsonl`.
It checks all seven dependency-closed subsets, 49 `covers` pairs, and 49 `merge` pairs.
It also checks heads and missing dependencies through the public document API.

The Rust metadata oracle generated six change rows and seven frontier-query rows.
`metadata` is registered as the eleventh golden vector.
The native metadata consumer passed 5/5 in ReleaseSafe.
It checks fields, frontier sets, independent ownership, allocation failures, and named-id actor-slot repair.
The standalone public consumer also passed after document teardown, including author bytes and an empty operation interval.

The first metadata run failed during fixture setup: Rust `raw_bytes()` includes framing, but `parseChange` expects the body.
The test now parses the chunk before its change body (`change.rs:118-120`).
The first smoke check assumed `setAuthor` retained the previous actor.
It now captures the author-associated actor that `setAuthor` selects (`automerge.rs:381-396`).
Neither failure required a production field-mapping change.
Review did find a production lookup defect: named operation ids bypassed actor-slot repair.
`Document.hashForOpid` now resolves those ids before graph lookup (`automerge.rs:744-758,1554-1567`).

The earlier automatic-recovery consumer passed its selected run on the old lifecycle.
It checked metadata refusal during retained recovery and follow-on committed history.
The current held-journal lifecycle replaces that recovery route.
Its actual current consumer result must be recorded separately.

### Behavioral coverage pending after source migration

These source prerequisites are implemented. Only execution of each full upstream case closes its coverage gap.

| Case or surface | Current prerequisite and remaining proof |
| --- | --- |
| External patch-log compatibility | The original four foreign-document cases are actor-compatible successes, not mismatches. Added incompatible-table cases require `PatchLogMismatch` with unchanged caller state. Sorted insertion/prefix rules can retain a trailing actor suffix; rendering through a shorter selected document must then return checked `InvalidActorIndex`, not fabricate an identity. |
| `current_state_diff_with_block_applies_to_hydrated_value_from_fuzz_trace` | `SpanInput.block` accepts a full borrowed hydrated map; emitted `Span.block` owns its full map. Verify nested content and ordered mirror replay. |
| `test_change_encoding_expanded_change_round_trip` | Owned structured decode, JSON and production wire encoding exist. Verify every upstream operation and independent hash/body agreement. |
| `save_and_load_incremented_counter` | Expanded changes and scalar datatype JSON codecs exist. Verify the full change-list round trip, not just native save/reload. |
| `round_trip_change_with_extra_bytes` | Structured encoding preserves complete authoritative `extra_bytes`. Verify both distinct opaque footers from the upstream case. |
| `has_our_changes` | Raw exact ordered shared-head equality and closing automatic predicate exist. Execute the predicate's full protocol scenario, not just convergence. |
| Rich-text rescue | The lenient mark-order loader returns owned hydration. Verify the exact upstream rescue map and disposal; strict parser rejection is not rescue proof. |
| AutoCommit lifecycle | One held transaction spans writer calls. Verify pending reads, close barriers, no-write commit, isolated writes, refusal recovery, and final-address clone. |
| Native load options | Partial-load, verification, migration, borrowed log, encoding, and author options exist. Verify policy combinations and follow-on state through real loaders. |

Fixture inventory checks, generic loads, and exact upstream cases are different evidence.
`test/fixtures_test.zig` checks inventory and magic.
`src/doc.zig` also loads all 18 manifest fixtures and checks outcomes, invariants, and recorded heads.
`upstream_doc_more.zig`, cases 10–13, adds the upstream-specific refusals and `ROOT.a.a == "b"` assertions.
Neither inventory nor generic fixture loading alone proves those exact assertions.

Rich-text mutation also has a fixed-seed model sweep in `src/read.zig` (`marks_are_okay`, 64 scenarios).
It checks text and consolidated spans across three compatible encodings.
This is property coverage, not arbitrary Unicode-offset coverage or a substitute for the exact rescue case.

**Historical expired blocker.** `update_spans_uses_expand_config` (`block_tests.rs:676-726`) once lacked `UpdateSpansConfig`.
That type arrived later in the same session.
The old record did not close itself when its prerequisite changed.
Reviewers found the stale blocker through source review.
The same rule applies to bundle, iterator, and compressed-change records.
Only the exact case's assertions close a behavioral gap.

Remove an expired blocker from the current ledger.
Retain a real missing assertion or API prerequisite with its source.
Keep dated evidence separate from the current coverage claim.

The port declares **1541 test blocks** in total (1316 under `src/`, 225 under
`test/`) — **not re-measured for this revision and therefore not to be relied
on**; the number is here because deleting it would lose the shape of the tree
and no current figure was available to replace it.

**Hexane case inventory, 2026-10-04:** [hexane-cases.json](hexane-cases.json)
records all **286 `#[test]` occurrences**, across **284 distinct names**.
**272 are covered, 14 are excluded, and none is partial or missing.**
The two duplicated names identify separate `BeLen` and `Bijou64` occurrences;
the ledger keeps their module-qualified IDs rather than merging them.

Coverage rests on each declaration's operations, values, and refusals, not name
presence. There are 266 same-named declarations and six named substitutes.
All 272 current source anchors resolve. Each record stores the pinned reference
input/assertion lines and the Zig assertion digest; 42 mappings also have a
recorded body read. These are source-review claims, not test-run results.

The exclusions are explicit: nine `bijou64` feature cases, three ignored
`deep_fuzz` cases, one ignored benchmark without assertions, and one Rust-only
`Copy` trait check. The five ungated alternate-packing cases use a private
test-only `BeLen` codec. The default wire remains LEB128. The seed-799 regression
replays the reference's recorded rows and bytes after all ten splices.

**There is no unaccounted test block.** This section used to report a residue
of two — `grep -rhoE '^\s*test "' src/` counting more than the runner held, less
the sixteen `src/c/doc.zig` and `src/c/sync.zig` blocks it could account for —
and called it "two blocks the binary holds that `grep` does not see", the same
unexplained pair it had recorded before. **That residue was never evidence of a
gap, and the instrument cannot distinguish the two cases**: a file carrying
tests reaches the runner three ways, and the `grep` side sees only the first.

- **a direct import.** `src/root.zig`'s test block names the module —
  `src/root.zig:168` names `storage/parse.zig` and `src/root.zig:172` names
  `storage/bundle.zig`, among the rest. Both sides see this route.
- **a transitive import.** `src/storage/parse.zig:726` is `_ =
  @import("totality_test.zig");` in that file's own test block, so the **7**
  test blocks of `src/storage/totality_test.zig` run in the library suite and
  **no line of `src/root.zig` names that file**.
- **a dedicated build step.** `build.zig:201-210` is a second `b.addTest`
  whose root is `src/hexane/hexane_test.zig` (`build.zig:203`), run as
  `run_hexane_tests` (`build.zig:209`) off `test_step` (`build.zig:210`).
  Nothing imports that file, and it is in the `zig build test` gate while being
  in no `zig test -Mroot=src/root.zig` run at all.

**So the two counts were never measuring the same set**, which is why their
difference could not mean "declared and never run". The lesson is the
instrument's rather than the arithmetic's: **a difference of two counts is a
claim about a gap, and the difference of two counts cannot tell "the gap is
there" from "the second count is blind".**

Both of the two "findings about what runs at all" recorded previously are
**resolved**:

- `test/upstream_doc_test.zig` **is** wired. The `upstream_doc_tests` step declares it,
  `:99-109` declares `upstream_doc_more.zig`, `:126-135` declares
  `upstream_text_more.zig`, and all three run under `zig build test`.
- `src/_slabgate_scratch.zig` **no longer exists**.

## The reference checkout

`../github-automerge-automerge` is the upstream tree, read-only and never built
in or modified. It is present at commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd` (measured, `git rev-parse HEAD` in
the checkout).

**`AUTOMERGE_REF` in this environment is unset** (measured, 2026-10-01), so
anything that reads the variable rather than the relative path falls back
correctly through `tools/link-oracle.sh` to the sibling checkout. Where it is
*set* it has pointed at an absolute path from elsewhere rather than the sibling
`../github-automerge-automerge`, and that path does not exist here; the script
refuses it by name and says so, so a stale export is a warning rather than a
wrong source.

`test/fixtures/` holds **18** corpus files (measured: regular files at depth 1,
excluding `manifest.zig`). `test/fixtures/manifest.zig` records **5** entries
`.load_ok` and **13** `.load_err`. `test/golden/{doc,change,sync}.jsonl` are
generated from the oracle; `doc.jsonl` records `"bytes":446` for the
interoperability exemplar, which is the document chunk reproduced byte for byte.

`test/golden/` holds **ten** vectors, and every one of them is regenerated
into the build cache and `cmp`-ed against the committed copy on every
`zig build conformance` (`addGoldenVector` in `build.zig`), so a vector cannot drift from the
reference without the build failing on the file that drifted. All ten vectors
matched in the 2026-10-04 conformance run, with 22/22 build steps successful.
Record counts measured in the same tree: `codec.jsonl` **1989**, `clock.jsonl`
**110**, `converge-parallel.jsonl` **20**, `converge.jsonl` **19**,
`sync.jsonl` **18**, `diff.jsonl` **6**, `change.jsonl` **2**, `doc.jsonl` **1**,
`save-interop.jsonl` **6** (one scripted document per case, `map`, `list`,
`text`, `marks`, `conflicts`, `merge`), `hexane-regression.jsonl` **1** (the
reference's own seed-799 round, 19 initial rows and ten splices).
**Total: 2172 records.** The codec file contains 1966 encoder cases, 22 B-tree
results, and one generator record; all 1989 records are byte-compared.

**The two `sync.jsonl` records that carry no `sent` field are not a defect, and
this file recorded them as an unexplained residue. They are `kind:
"sync-final"`, one per side, and `kind` discriminates them.** The oracle emits
two different record shapes on purpose: `sync_record`
(`tools/oracle/src/main.rs:417-427`) writes
`{kind, round, from, to, sent, bytes, hex}` for one direction of one round, and
the document each side ends the exchange holding is written separately as
`{kind, side, bytes, hex}` with `"kind": "sync-final"`
(`tools/oracle/src/main.rs:405`), after the rounds are done. So `sync.jsonl` is
**16 sync messages — 5 `sent: true`, 11 `sent: false` — plus 2 final
documents**, and the 5/11/2 split is the whole of the eighteen. The old
"the eleven-plus-five split alone does not account for all eighteen" was an
artefact of reading a `sent` split as if `sent` were the record's only
discriminator.

## Current phase ledger

"Verified" requires an observed execution of the named gate on the current source.
Source implementation and previous dated success remain separate.

| Phase | Current state | Proof limits |
| --- | --- | --- |
| P0 conformance harness | Current reference vectors and native API replay pass | Corpus scope is explicit; it is not proof of every possible input. |
| P1 foundation | Current Debug, slow-path and ReleaseSafe gates pass | Malformed inputs retain operation-specific obligations; passing roots do not prove all states. |
| P2 hexane | Current Debug, slow-path and ReleaseSafe gates and final comparison pass; historical source ledger retained | Preserve the ledger's reasoned exclusions. Native before/after improvements are not Rust-relative gains. |
| P3 columnar and format | Current full roots, corpus and live interoperability checks pass | Named corpus/scenario scope is not total format proof. |
| P4 change graph and encoding | Current full roots, reference vectors and API replay pass | Preserve independent hashes and authoritative footer bytes. |
| P5 op set and merge | Complete Debug, slow-path and ReleaseSafe roots and current public consumers pass | Case-for-case integration scope remains bounded by the consumer ledgers. |
| P6 document API | Current native target replay, standalone consumer and full roots pass | Passing target consumers do not imply universal input/state coverage. |
| P7 iteration | Current complete Debug, slow-path and ReleaseSafe consumers pass | Preserve encoding exceptions and borrowed/owned item boundaries. |
| P8 sync | Current full roots, reference/C consumers and fresh matched CLI correctness pass | Correctness smoke does not establish performance. |
| P9 patches, marks, cursors, hydrate, serde | Current replay, complete roots and final comparison pass | Corpus, encoding, ownership and reference-panic exceptions stay explicit. Cache-phase gains do not imply whole-process gains. |
| P10 C ABI | Current static/header and dynamic runtime gates pass | Exact C case and corpus scope is recorded above, not broadened to every C behavior. |
| Bundle and fragments | Current Debug, reference and public consumer checks pass | Existing case ledgers define behavior coverage; no universal integration total is inferred. |
| Matched performance comparison | Final matrix completed with valid correctness, scheduling and counters | Results establish measured differences, not performance parity. See the benchmark README's current comparison. |

## The API contract

[API.md](../API.md) records the current source contracts and full declaration ledger.
Its ledger groups every reader, writer, document, transaction, sync, patch, and value surface.
It does not claim that a source declaration passed its consumer.
Port anchors use file and symbol; pinned Rust citations retain `path:line`.

The migration removes deprecated lifecycle flags, per-call automatic free writers,
obsolete transaction aliases, object-ID scalar values, incomplete span blocks,
and UTF-8-buffer ownership examples.
Raw, transaction, automatic, closure, owned-value, and parser owners have distinct disposal rules.
`CommitOptions` contains message and time. Logged transaction opening, not an invented options field,
transfers an external log on successful construction.

Historical changes explain defects; they are not alternate supported caller contracts.
Use root `transaction`, `sync.state.State`, `sync.message.Message`, and `change_record`.
The complete public signature and barrier definitions belong in API.md.
Current execution limits belong at the top of this file, not in an inferred aggregate parity count.

## The slab merge budget, and why the previous account of it was wrong

This file previously said that `slab.merge` could leave a merged slab over the
64-segment budget, that the fix was to port upstream's `rewrite_lit_header`,
and that the characterization test would then fail with 65 found and 64
expected. It also said, in the same document, both that the defect had been
fixed and that it was the first thing to fix.

All three statements were wrong in the same way: they assumed the merged slab's
run count could be one lower than it is.

**The run count is 65, and 65 is correct.** The inputs are `a` = 11 runs ending
in the literal run `[11, 12]` and `b` = 53 runs opening with the literal run
`[12, 13]`, so the merged values at the seam are `11, 12, 12, 13`. Canonical RLE
cannot encode those four values in two runs: a literal value equal to the
previous one is not canonical (`rle/decoder.rs:452-455`) and two adjacent
literal runs are not canonical either (`rle/decoder.rs:444-451`). The encoding
is `lit[11] + run(2,12) + lit[13]` — three runs, which is upstream's own bytes.

**Upstream never reaches the case.** Upstream's `Slab.segments` counts a
literal run as its number of *values* (`rle/load.rs:131-138`,
`rle/state.rs:229-231`), so `a.segs = 12` and `b.segs = 54` and
`Column::try_merge`'s pre-check `a + b <= max`
(`hexane/src/column.rs:1789`) refuses the merge outright. This port's metric is
the run count, and it is not additive across the seam: 1 + 1 seam runs can
become 3.

What landed:

- `slab.zig` has `rewrite_lit_header` under the upstream name
  (`hexane/src/codec.rs:207-219`), and `merge` builds the seam from bytes
  through it rather than by decoding and regrouping the two runs' items.
- `litSeam` had a real defect of its own, which the account above never
  mentioned: at the b side it rewrote the run's count header but did not remove
  the first value's bytes, so the seam it produced would not parse. It now drops
  that value, and `Base.litHead` — the mirror of `Base.litTail` — is what
  measures the value that goes.
- The characterization test is now `a merge at the segment budget stays inside
  it`, which uses a `b` of 52 runs so the pre-check gives 63 and the result is
  64, and it carries the budget assertion. The +1 case has its own test,
  `a merge whose seam values meet costs one run more than the two it replaces`,
  which asserts 65 and explains the arithmetic.
- The genuine over-budget case is `Column.tryMerge`'s pre-check, not the seam.
  It now splits the merged slab exactly as `settle` does, and a test reaches it
  through the public column API.

## Defects found and fixed during the port

Recorded because they are the kind of thing that recurs if nobody writes them
down. Every `path:line` in this list was re-checked against the reference on
2026-09-30 and still resolves.

1. **The encoding field of a column specification is three bits, and bit three
   is the DEFLATE flag.** The port masks the whole 32-bit word, not upstream's
   8-bit literal, because upstream's literal discards the high bits of a column
   id of 128 or more.
2. **A compressed chunk's checksum covers the inflated body, hashed as a change
   chunk, not the DEFLATE stream.** `parseChunk` therefore cannot verify a
   compressed chunk at all; the load layer must route every compressed chunk
   through `decompressChunk`.
3. **The boolean codec is not the RLE codec.** Applying the RLE rule that two
   adjacent single-item literal runs are not canonical to a boolean column
   merges runs of *different* values at a slab boundary and shifts every value
   after it.
4. **The leading boolean pad belongs when the region's first value is `true`
   and the run at its position is a `false` run.**
5. **The column merge policy was enforced over too small a range.**
6. **`slab.merge` rebuilt the seam from items instead of rewriting the run
   header, and the seam it built did not parse.** Both halves are described
   above.
7. **Rust's `sequence_tree.rs` is a positional b-tree, not an interval tree**,
   and it has no cursors. A cursor is resolved through the op set.
8. **`writeOpsBlock` wrote the column count after the descriptors**, so every
   body it produced was unreadable by `parseChangeChunk`. It was not a compile
   error and the round-trip test had never run.
9. **`opTypeFromActionAndValue` could never return `OpType.mark_end`.** A mark
   row is a begin when its `mark_name` column holds a name and an end when that
   column is null, and the column is nullable (`op_set2/columns.rs:32`,
   `op_set2/types.rs:177-186`). The port returned `error.InvalidValue` instead,
   so the `mark_end` variant was unreachable. `OpType.MarkEnd` also carried a
   name and a value that upstream's `MarkEnd(bool)` does not have.
10. **Six kernel methods were declared `!?T` and returned `!T`,** which does
    not type-check, and nothing noticed for the life of the file. A comptime
    check that instantiates a generic — `column.Shiftable(I)` resolves the type
    and leaves every method body **unanalyzed**, so a malformed body passes it
    cleanly. The bodies were only analyzed when a sibling module tried to call
    one. A test that drives every kernel method on a real fixture is now the
    instrument; it is not scaffolding, and it found four of the six.
11. **`&.{…}` inside a loop is a pointer to that iteration's stack frame.**
    `Row.succs` is `[]const OpId`, and a one-element slice literal with a
    runtime element taken inside a loop body is not a constant — it is an
    address the next iteration overwrites. Two op-set fixtures did this, and
    the symptom was three measurements of the same fixture disagreeing: a
    column read, an indexed walk and a scan walk gave three different answers,
    and the third varied between runs because it was reading reused stack.
    It looked exactly like a cursor bug and the column layer was sound: the
    same 500 values spliced directly into the column round-tripped
    correctly. Fixtures now own their successor ids in one allocation sized
    once.
    **The lesson is about the test, not the fixture.** A comparison test does
    *not* catch this: the clock and the columns are built from the same rows, so
    a fixture that is wrong in one place is wrong in both and they agree with
    each other. What catches it deterministically is a **premise** assertion —
    that the ids are N distinct values, in row order, with specific values at
    specific rows. Assert the premise, then the conclusion.
12. **A helper that is never instantiated has never been type-checked.** Two
    visibility helpers were dead, and instantiating them produced two const
    errors that lazy analysis had been hiding. The same shape as item 10 and
    the same fix: a check that resolves a type is not a check that a body
    compiles, so the body has to be reached.
13. **`ElemId` was collapsed to `OpId`, and a list's first element could not be
    written at all.** Upstream's `ElemId(OpId)` wrapper exists for exactly one
    reason: to carry the head. `ElemId::actor()` returns `None` for the head and
    `icounter()` does not (`automerge/src/types.rs:664-674`), so **a
    sequence key's actor is optional** and the port's bare alias could not
    express that. An insert anchored at the head of a list then wrote
    `key_actor = 0` where the reference writes absent, and a reader takes
    absent as the head.
    The load path was unaffected — the stored bytes already say absent — which
    is why a green suite never caught it, and the local-write path is where it
    bit.
    The restoring fix has three parts worth keeping separate, because the first
    is not the one that matters:
    - **the type.** `ElemId` is a struct again, with `fromOpId` and `head`. The
      head is the distinguished *value* `OpId(0, 0)`, reused from the root
      sentinel, because a counter of zero is not an operation's counter — so
      nothing can construct an almost-head.
    - **the two shapes.** A sequence row is `(actor, counter)` for a normal
      element and `(absent, 0)` for the head. `(absent, absent)` is the third
      shape and it is a **map key**. Getting that wrong produces a row that
      round-trips cleanly and is not a head anchor at all, which is why it is
      called out here rather than left to the code.
    - **the proof, which took three passes and had a gap.** The ordering half —
      the head is the minimum, so a head-anchored insert sorts first — is
      proven by the stepper tests. The round trip through `tryLoadElemId` was
      already proven. Neither is the same as the encoding half. The two existing
      proofs were coupled by a shared literal and a cross-reference rather than
      by a shared execution, and the only production path from stored bytes to
      the reader — `KeyIter`'s nullable widening — was crossed by neither. It
      is now, with and without a clock.
14. **The LEB128 reader accepted an over-long encoding, so a document the
    reference refuses loaded here.** `readUnsigned` stopped at the first byte
    with the high bit clear and never asked whether that byte was the last one
    the value needed; `readSigned` did the same and had no `prev` byte at all.
    `test/fixtures/counter_value_is_overlong.automerge` is exactly this, and
    the manifest records that the reference refuses it.
    **The module doc at `leb128.zig:9-10` already promised it** — "an overlong
    encoding is a parse error, not a silently accepted value" — and
    `readUnsigned`'s own doc claimed it. The contract was written and the
    implementation never followed, and the tests only covered an eleven-byte
    encoding. The reference's rule is `storage/parse/leb128.rs:32-33` for the
    unsigned form and `:62-65` for the signed one.
15. **A prefix descent could not land inside a multi-unit element.**
    `findPrefixInSlab` walked whole segments and read each as `count` copies
    of its first value, so it over-counted a literal run and every landing fell
    one run late. A text element carrying `"ab"` has width 2, so asking for
    unit 1 landed on the element *after* it, and `seekTextOpsByIndexFast`
    refused with `error.Invariant` rather than naming the wrong element. The
    cursor took a grouping arm — O(object) per cursor where the descent is
    O(log n) — until this was fixed at source.
    Upstream's decoder hands a literal group back as a run of **one item per
    value** (`rle/decoder.rs:516-522`), so it only ever divides by a single
    item's length and never over-counts. The port's `RunAt` is a whole
    segment, and the arithmetic followed the port's shape instead of
    upstream's.
16. **A patch stored a payload owned by the log that built it.**
    `PatchBuilder.insert` put the `Event`'s value verbatim into the patch's
    arena, but that value belongs to the **`PatchLog`'s** allocator — so a
    `Patches` outliving its log read freed memory. Three more instances of the
    same class turned up in the sweep: a `Patch.path`'s map key (document-
    owned), a mark's `ScalarValue` (log-owned), and a leak in
    `MarkRuns.deinit` that dropped every byte-carrying mark value.
    **The doc comment that let two arms through claimed the tree "was built
    with the arena, so it allocates with it"** — true of the *nodes*, false of
    the *payload*. A comment that is half-true about ownership is worse than
    none, because it reads as a reason.
17. **The change decoder dropped the change-local to document actor mapping.**
    `actorAt` returned the local index instead of mapping it through
    `actors[i]`, so a second change's ops named objects the document does not
    hold. **Invisible while a document has one actor**, because then the table
    is the identity — 790 tests passed and only two-actor fixtures failed. It
    arrived six tests away, as upstream's
    `panic!("Obj {:?} Missing from Index")` (`op_set2/change/batch.rs:920`) arriving on
    time as an `error.Invariant`.
18. **A decoded column was indexed without a bound.** `graphStr` read `cells[i]`
    with no length check and panicked on the corpus fixtures. That is the third
    place in the document loader where a decoded length disagreeing with the
    reader's expectation needed a check — `decodeColumn` for the four
    change-block columns, `cellAt` for the fourteen op columns, and now this.
    **One discipline, not three ad-hoc checks:** every read of a decoded column
    is bounded by the actor column's row count, and a group column's flattened
    half is bounded by the sum of its counts. That sentence belongs where a
    column reader is written, not in each reader.
19. **A mark's closing run was reported past the end of its object.**
    `calculateMarks` subtracted `base` at the closing line, where upstream
    subtracts it at two. Upstream's `base` is the **absolute** prefix of the
    whole column at `range.start`; the port's was **zero**, because
    `prefixIterRange` parks the absolute prefix in the cursor and starts its sum
    at 0. Inside the loop the two forms agree — `pv.prefix()` is already
    object-relative — so `- base` looked like a no-op subtraction of zero, and
    at the one line where an absolute number is subtracted it produced an
    absolute end against an object-relative start. **A subtraction of a value
    that looks like zero hides the question of which coordinate space it is in.**
20. **A document chunk was validated only when it was compressed.** The check
    lived inside the DEFLATE helper, so the DEFLATE decision decided whether a
    document was checked at all, and an uncompressed document with a repeated
    column specification loaded. Upstream has no such coupling: decompression
    and validation are separate steps. `ColumnLayoutParser`
    (`storage/columns.rs:153-355`) is ported with it, so a half-present logical
    group is now refused too.
21. **The span fold flattened each mark fold on its own, so every mark read as
    an unmark.** `SpanState.refreshMarks` copied the document fold and the merge
    fold separately, and did it through `batch.MarkDiff.exportSet` — which is
    `Pop::Before` for the document fold alone (`spans.rs:360-366`), and rewrites
    every name to `ScalarValue::Null`. Upstream keeps the two sets apart for
    exactly this reason: `RichTextDiff::current` returns
    `MarkDiff::Diff(b.clone(), a.clone())` (`spans.rs:653-660`) and flattens once,
    at export (`spans.rs:389-400`).
    **The symptom was a mark reported where the reference reports none, and a
    run split at every mark boundary** — a `Same` text span carrying a mark set
    becomes a patch (`spans.rs:32-36`), so four of upstream's five mark-patch
    tests went red with a spurious `Mark` patch in the stream. The companion
    defect was in the comparison rather than the copy: `flattenedEql` compared a
    one-fold `.before`/`.after` view by its raw entries instead of by its
    flattening, which is a different question whenever the fold holds a
    tombstone (`spans.rs:360-372`) — so an unmark split a run that had not
    changed. **The lesson is that `Pop::Before` is a statement about the
    difference between two folds, and applying it to one of them inverts it.**

22. **A float reached the wire in the host's byte order, and the round-trip
    test could not have caught it.** `appendPayload`'s float arm
    (`src/columnar/encoding.zig:1424`) wrote `@bitCast(f)` into `[8]u8` and
    `ValueDecoder.next`'s float arm (`:813-819`) read it back with `@bitCast`
    of the payload's bytes, while the two op-column writers in the same tree
    spelled `std.mem.writeInt(..., .little)`
    (`src/columnar/columns.zig:526`, `src/opset/types.zig:371`), upstream
    encodes with `self.to_le_bytes()`
    (`columnar/encoding/encodable_impls.rs:74-78`), and upstream decodes with
    `f64::from_le_bytes(raw)` (`columnar/column_range/value.rs:245`).
    **Every little-endian row agreed with itself, and the bytes disagreed with
    the reference.** `1.5` came out of a `powerpc64-linux-musl` build under
    `/bin/qemu-ppc64` as `{0x3f, 0xf8, 0, …}`, where it is
    `{0, …, 0xf8, 0x3f}` everywhere else; after the fix it is the latter on
    both endians.
    **The lesson is the one the round-trip instrument cannot express: two
    halves that are wrong in the same direction agree with each other on every
    host.** `a value column pair round trips every scalar` encodes and decodes
    with the same two arms, so it passed on powerpc64 too — it measures
    self-consistency, not the wire. The test that pins this one
    (`a float value column's payload is the reference's eight little-endian
    bytes`) asserts the **bytes** and feeds the reader a literal array it did
    not write. That is the general form: **a byte-order contract is only
    measured against bytes the test did not produce, and the row that measures
    it is the one that is not the host's** — which is why
    `test/cross-test.profile.sh` names this site as the reason powerpc64 is in
    the matrix.

23. **A bulk index replacement built a root larger than the branch factor
    permits.** `propagateSplits`'s terminal root-overflow case put every
    replacement slot into one new internal node. `makeLeaves` makes one slot
    per leaf, so replacing a whole tree with more than `branch_factor` slabs
    arrived there with more than `branch_factor` slots and the new root was
    itself overfull — **65 children at 4097 slabs, 66 at 4167, 128 at 8192**.
    A straight `fromSlice` build cannot produce that shape, because it adds a
    level at a time (`buildLevel`), so a load-then-edit column was sound and an
    edit that grew one past a leaf boundary was not. The slots are now grouped
    into internal nodes first, the way a straight build does.
24. **A slab split left a guard naming a destroyed list.** `Column.settle`
    armed an `errdefer` over `spilled`, called `spilled.deinit(gpa)` on the
    success path, and only then made two more fallible calls. A refusal below
    read `spilled.items` out of the `undefined` an `ArrayList.deinit` leaves
    behind and freed garbage — **the general protection fault the apply-route
    allocation sweep hit at refusal 56 of 787**. `spilled` has one owner now
    and no guard outlives it.
25. **The batch screen's accept path left a double free.** A change the screen
    accepted was appended into `accepted` and the `incoming` slot it came from
    was **not** blanked, so that slot still aliased the buffer `accepted` now
    owned. On a refusal the guard released the accepted copies and the
    caller's release walked the same buffers again. The skip path already
    blanked its slot for exactly this reason; the accept path did not, and two
    screen tests reported the double free through `DebugAllocator` while their
    assertions passed.
26. **`Document.reset` aborted the process on a refused allocation.** It tore
    `self` down and only then allocated the replacement, under
    `catch unreachable`. Building the fresh document first costs nothing —
    `initWithEncoding` neither reads nor writes `self` — and makes the refusal
    a `ParseError` the caller can hold a whole document against.
27. **A taken predecessor list leaked when its shrink was refused.** `take`
    pulled the entry out of the map and then returned
    `kv.value.toOwnedSlice(gpa)`; that call shrinks the buffer and the realloc
    is fallible, so on a refusal the entry was already out of the map and a
    local was the only thing still naming the buffer. The collector's sweep
    found it, and the release belongs on the failure path beside the
    successful one.
28. **A split at the run budget handed out boolean pieces one run over it.** The
    leading pad — the zero-count `false` run a slab opening on `true` carries
    (`bool.rs:988-1002`) — is a run the wire spends and `measure` counts
    (`src/hexane/column.zig:2584`), and a piece cut out of a `true` run has to
    write it again. `splitToBudget` cut at `max_segments` runs of the run table
    either way, so every piece behind the first stood one run over the budget
    and `Column.checkInvariants` refused the column on it
    (`src/hexane/column.zig:6881-6882`). Upstream never makes that correction
    because it cuts the run out of the rebuild rather than out of a finished
    slab, and the pad is counted there (`bool.rs:312-317`, `:322-326`); the
    loader is the one place this port already left room for it, by cutting at
    half the budget. The cut now spends the pad (`slab.zig:1007-1048`), and the
    room a column reserves before it cuts is that same rule
    (`slab.zig:1063-1068`, `column.zig:6291`, `:6387`, `:6541`, `:6608`).

### The pattern under 14 to 18

Three of these five are invisible to a green suite for the same reason: **the
port only ever exercised one of something.** One actor, one mark value that
borrows nothing, one eleven-byte LEB, one literal run. A test that passes is
evidence about the cases it covered and nothing else, which is the same lesson
as the three classes of uninstantiated code earlier in this list.

And 14 is its own lesson: **a doc comment promising a rule the code does not
implement is a defect that reads as a specification.** Two of them, in this
case — the module doc and the method doc — and both were believed, by me and by
an agent writing against them.

### The two rules under all of it

They are stated here because they are the most transferable things this
session produced about how the port goes wrong, and both cost real rounds.

**A reader that is more permissive than its writer hides the writer's bug.**
`encodeGraphCols` wrote an unsigned cell into a delta column, and the column's
reader had been deliberately made sign-lenient so the load path would accept
the reference's data. The leniency was correct on its own terms and it meant
the writer's error could not surface — every `save` of any document with a
change died at one line, and a passing load path said nothing was wrong.
**The things written to be forgiving are the things that hide the errors.**

**An `errdefer` written before a value moves into a longer-lived owner frees it
twice.** It has cost this port four double frees, in four files, and each was
found only because a downstream test aborted and the abort was chased rather
than dismissed. The errdefer fires on the path that returns; the move means
the new owner also frees.

**An `errdefer` covers failure, and a path that succeeds by giving up still owns
what it was handed.** The collector's `place()` had an `errdefer` and three
plain `return`s, and **every op it dropped** — the common case, not the edge —
leaked its predecessor list, because a plain `return` is a success. This is the
same class as the rule above seen from the other side: both are about an
`errdefer` being treated as if it covered a path it does not.

## Traps found and not yet fixed

Next to the list above because they have the same character — the wrong
answer looks right — but these are open, not closed.

1. **`MarkIndexColumn.iter().next()` answers `null` both for "no more" and for
   "this row carries no mark."** `MarkIndexColumn.ValueIter.next` decodes a
   nullable word and hands back `?MarkIdx`, so those two cases are one value
   (`src/opset/mark_index.zig:488-496`). A row-at-a-time read stops at the
   first unmarked row. It is correct where it is used — the cursor says so,
   and `calculate_marks_fast` walks it run at a time for that reason
   (`op_set2/op_set.rs:981-987`) — and it is a trap for the query surface,
   which is where marks turn into per-row answers. The fix, when someone wants
   it, is a distinct accessor beside `next`, not a change to what `next` means:
   `next` is the column's own cursor shape (`src/opset/mark_index.zig:252-260`)
   and `nextRun` already covers the run-at-a-time walk.
2. **`src/opset/op_iter.zig` is the counter-example, and the property is worth
   keeping there.** Every sub-iterator in it has a *total* item type — `bool`,
   `Action`, `KeyRef`, `ObjId`, `ScalarValue`, `SuccCursors`, `OpId` — so
   "this row carries nothing" is a value and only the walk's own end is
   `null` (`src/opset/op_iter.zig:117-133`). A row with no mark is
   `MarkInfo{ .name = null, … }`, a row with no successors is an empty
   `SuccCursors`, and a row naming no property at all is `error.MissingKey`.
   Do not copy the mark index's shape when a new sub-iterator is added.

3. **`src/c/sync.zig` did not compile, and no longer does** — *closed 2026-10-01*.
   The `gpa` shadowing at `src/c/sync.zig:197` is gone; the file compiles.
   The reason it is kept here rather than deleted is the way it hid, which is
   the transferable part: the library test block keeps most of `src/c/**` out
   (`src/root.zig`'s test block) because those files are `extern "C"` over libc, so
   the library suite could not have seen it, and the one test that *does* pull
   the module in is a single example file. **A file excluded from the main
   suite has exactly one other place it can fail, and it should not be the
   crate-root example.** It passes now — `test/example_test.zig` is 3/3.
4. **The 20-target portability matrix has no verdict yet — its one run was
   interrupted, not failed.** Run `20261002-115542-31452-24919` (Zig 0.16.0,
   `test/cross-test.profile.sh`, `zig build test`) covered 12 of the 20
   runnable targets before the harness was stopped (exit 143): 0 pass /
   20 fail with `bookkeeping_failure=false` is the shape of an aborted run,
   not of twenty broken targets. The per-target logs stay outside the repo;
   re-run per the profile and record the outcome here before claiming any
   platform verdict.

## Traps found and fixed

4. **An isolated write's ops carried the base actor's index, not the
   concurrency fork's, so every clock-filtered read was blind to them.**
   `Document.isolate` and `Document.integrate` call `Document.patchTo`,
   upstream's `AutoCommit::patch_to` (`autocommit.rs:816-824`). With that in
   place the isolate round trip emitted **five** of the reference's seven
   patches under all four encodings, and the three it missed were the three
   that mention `"color"`. The cause was one line in `Document.commit`:
   it opened with `var args = try self.transactionArgs(gpa, self.isolation)` —
   it re-derived the transaction's arguments because the port's transactions
   did not carry them into it — **after `Transaction.insertLocalOp` had
   already spliced the change's rows into the op set**. The re-derivation
   reaches `Document.isolatedActorIndex`, which interns a concurrency actor,
   and `Document.insertActor` then runs `rewriteWithNewActor`, renumbering
   every row at or above the insertion point — **including the rows this very
   change just wrote**. The change's header named the new actor and its rows
   named the old one; `ChangeGraph.clockAt` reads the header, so the clock put
   the fork's `max_op` in the fork's slot while the rows answered to the base
   actor's.

   **How it looked, measured.** A document holding `"name"` = `"abc"` and,
   under an isolation, `"color"` = `"red"` had two actors (`actor[0]` = the
   8-byte concurrency fork, `actor[1]` = `"aaaaaa"`) and a clock at its real
   heads of `[8, 4]`, which covers both changes. `hydrateMap` at those heads
   answered **one** register (`name`) where the same document read unscoped
   answered **two**. Raising only the clock's **second** slot made `color`
   appear, at exactly the counter its op id carries — the rows were at actor
   1, whose slot held 4. `OpSet.validateOpOrder()` was `true` and
   `OpSet.validateTopIndex()` was `null`, so the op set's index was sound and
   the rows' actor index was the fault.

   **Two defects, not one, and the second was found only by the first.** With
   `Document.commit` taking the transaction's `TransactionArgs` — upstream
   builds them once per transaction, in `AutoCommit::ensure_transaction_open`
   (`autocommit.rs:445-457`), and `TransactionInner::commit_impl` reads that
   same struct (`inner.rs:146-172`) — the fork happened and the stream went to
   **nine** patches, every `color` patch present and the `name` pair re-emitted
   at the front. The cause of that was the range `Document.commit` walks for
   the change's own patches: it used `graph.getHeads()` as `after`, which is
   the same list as the change's own hash for a sequential change and **not**
   the same under an isolation, where the graph keeps every concurrent branch.
   It reported the concurrent branch's `name` and its hundred-character splice
   as this change's own, and flagged the contested `color` as conflicted on
   the `PutMap` that introduces it. **`after` is `[this change's hash]`.**

   **A third thing was the fixture, and it is the transferable part.** The
   actor a change is written as is decided when the transaction is **opened**,
   so a caller that isolates and then opens through `Transaction.openAt` with
   `null` — the low-level door, `Automerge::transaction`, which reads no
   isolation — gets a sequential change no matter what the document holds.
   `Document.commit` cannot paper over it and must not: the actor index in the
   arguments is the one every op was written against, and overriding it is the
   trap above. **Two doors that each re-derive "which actor is this" is the
   same shape as the mark-anchor and skip-unit traps above**, and the test that
   would have caught it did not, because every assertion in the file was
   self-consistent with the fixture.

   **The seven, and which half of `patch_to` emits them.** The oracle's
   `isolateprobe` runs the reference's own case with the log drained at every
   step, which attributes the stream: the walk (`DiffIter::log`) emits
   **five** of the seven and `finish_current_view` emits **none** of them,
   being a no-op at that case's `isolate()` because the previous
   `diff_incremental` left the log empty. The close half's job there is to
   *finalise* the four events the walk and the isolated commit recorded, which
   is what puts them ahead of the three the `integrate()` walk records.
   `integrate()` is not a no-op either: after a commit the isolation is
   `Some([that change])` (`autocommit.rs:735-736`) while the graph holds every
   concurrent head, so `patch_to`'s `before != after` test fires and the walk
   is what sees a contested key twice over and raises the conflict.
   `test/upstream_text_more.zig` pins all seven, by name and in order, under
   all four encodings, and passes.

## Where the document slice stands

P6 is written, the crate-root example that drives it end to end compiles and
passes, and **the whole library suite is green** — **1469 passed, 1 skipped, 0
failed**, 2026-10-01. The
failure and the non-terminating test this section used to report at the top of
the file are both gone.

**What is proved.** A change chunk the **Rust reference wrote** decodes,
re-encodes, and reproduces the reference's own bytes and all 32 hash bytes — so
`writeChangeOps`, the `ActorMapper` ordering, the column-dropping rule, the
value-pair split, the predecessor group and the delta ordering are byte-exact.
The reference's own document loads and change 0's hash `108741df…` is reproduced
exactly. The document chunk reproduces the oracle's 446-byte `save()` output
byte for byte. Commit determinism, `forkAt`, and the duplicate-sequence refusal
through both `applyChanges` and `merge` all pass.

**The direction that matters most, re-measured.** The three tests that prove
the *write* path — not only the read-back — are named in the tree and pass
(`zig test … --test-filter "reference"`, 2026-10-01, 20/20):

- `src/doc.zig:9003` `this port's write path produces the reference's own change
  chunks, byte for byte`. It builds the oracle's document through this port's
  own transactions, asks for its two changes, and asserts **two** things per
  change: the encoded body equals the reference's bytes
  (`expectEqualSlices(owned.parsed.change.bytes, built.body)`) and the hash
  equals the reference's own 32 bytes (`expectEqualStrings(want, got)` against
  `reference_change_0_hash` / `reference_change_1_hash`). It also asserts
  `changes.len == 2`, so it cannot pass by comparing an empty list.
- `src/doc.zig:6425` and `:6442` — a change chunk the reference *wrote*
  re-encodes to the reference's bytes **and** hash, for the plain and the
  compressed framing.
- `src/doc.zig:6500` — every change in the reference's own 446-byte document
  comes back with the reference's hashes.

**Corrections to earlier claims:** `tests/batch_insert.rs` is ported 46 of 46
in `test/upstream_batch_insert.zig`. The fragment API exists; its document and
graph entry points are listed in the bundle row above. The hexane case
accounting is now explicit in [hexane-cases.json](hexane-cases.json): 272 covered
occurrences and 14 reasoned exclusions, with no missing occurrence.
`can_transaction_at` (`test.rs:2507-2546`) is transcribed with upstream's
expected values and passes (`test/upstream_doc_test.zig:3126`).

**Three walls this session turned out to be one wrong assertion each**, and in
all three the instrument was the reference rather than a re-reading of the port:
a mark fixture whose begin and end were anchored to the same op, so it spanned
zero graphemes and the reference reports no mark either; a string comparison
across two documents' intern tables, where the same string has two ids; and a
fifth test that passed either way because the reader does not sort. **When a
wall is certain, ask the reference the same question and write down its answer.**

## Next steps, in order

### 1. Port `tests/batch_insert.rs`

**Closed 2026-10-01, and this entry recorded the opposite twice.** It said
"none of its **46** cases exists in the port and the string `batch_insert`
occurs nowhere in `src/` or `test/`". **Both halves are false**, and the same
file's coverage table said 46 of 46 while this entry said zero; the table was
right. Established by reading the files rather than by trusting either number:
upstream's `tests/batch_insert.rs` holds **46** `#[test]` functions, and
`test/upstream_batch_insert.zig` holds a `test "batch: <upstream name>"` block
for each of the 46 — one per upstream case — plus one port-only test, and the
string `batch_insert` occurs in `src/hexane/hexane_test.zig`, `src/read.zig`,
`test/upstream_block_tests.zig`, `test/upstream_batch_insert.zig` and
`test/upstream_save_load_orphans.zig`. P5's save-format clause is now closed:
`zig build save-interop` passed 7/7 steps and verified all six cases in both
directions, including byte equality after column inflation.

### 2. The `_at` historical variants

**Closed 2026-10-01.** `API.md` §Known gaps item 2 said this was "one optional
`?[]const ChangeHash` per read signature, and every walk underneath already takes
a `?Clock`, so no body changes" — and that is **what happened**, with one
exception the gap did not foresee. `src/read.zig` now answers at caller-named
heads on **fourteen** readers: the
eleven `_at` readers (`getAt` `read.rs:266-271`, `getAllAt` `:293-298`,
`lengthAt` `:149`, `keysAt` `:55`, `valuesAt` `:137`, `textAt` `:180-184`,
`spansAt` `:190-194`, `marksAt` `:158-162`, `mapRangeAt` `:99-104`,
`listRangeAt` `:118-123`, `parentsAt` `:40-44`) and the three cursor readers
`getCursor`, `getCursorMoving` and `getCursorPosition`, with `hydrate`,
`markSetAtIndex` and `getMissingDeps` beside them. **This entry then named
`getCursorAt` (`:199-204`), `getCursorMovingAt` (`:224-230`) and
`getCursorPositionAt` (`:237-242`) as three further spellings, and that is
wrong.** Upstream carries `at` **on those three methods themselves** (`:203`,
`:228`, `:241`) and has no second name for any of them, so the port's three
`_at` names were a port-only split and **have been removed**; the heads are in
the three signatures, in upstream's own argument position. **The same cutover
relabelled one refusal**: `getCursorPosition` answers `error.InvalidCursor` for
a cursor naming a row of another object where it used to answer
`error.InvalidIndex` unscoped, which is upstream's own
`.ok_or_else(|| InvalidCursor(cursor.clone()))` on the seek's empty answer
(`automerge.rs:1778-1781`) and is what the same cursor already answered with a
clock. `Document.clockAtScope` supplies committed historical clocks (`automerge.rs:1236-1247`).
The current implementation retains heap-stable clock slots across other head selections.
Returned walks borrow those slots until document mutation invalidates them.
It no longer shares one replaceable scope clock across all returned historical walks.

### 3. Case accounting

**Closed 2026-10-04.** Name-presence counts did not establish coverage.
[hexane-cases.json](hexane-cases.json) accounts for all 286 upstream test
occurrences, representing 284 distinct names: 272 covered and 14 excluded.
The covered entries map to 266 same-named declarations and six named
substitutes. All 272 declaration anchors resolve in the final source.

The exclusions are nine optional Bijou64 cases, three ignored deep-fuzz
cases, one ignored benchmark without assertions, and one Rust-only `Copy`
trait check. The last case runs in Rust's default build but has no Zig
behaviour to port. Source review is not runtime proof; the P2 verdict in
[plan.md](plan.md#p2--hexane) records the separate execution gate.


#### `tests/rich_text_fuzz_crash.rs` — the other half of the totality gate

**Closed 2026-10-01, 8 of upstream's 9, and it is not a second copy of the
8-fixture suite.** `src/storage/totality_test.zig` **mutates** well-formed
documents — 885 truncations, 7,144 bit flips, 1,413 hostile DEFLATE streams — so
what it proves is that the framing and column decoders are total. Seven of these
nine cases build their document **through the writer**, from the operation
sequence a fuzzer produced and a human minimised, and the defect each one guards
is **semantic**: a `MarkEnd` spliced before its `MarkBegin`
(`rich_text_fuzz_crash.rs:194`), a `length` counting a conflicted text element
twice (`:164`), a zero-width mark leaking into a different text object (`:118`),
and a **panic** in `BatchApply::apply` while validating op order when a
zero-width unmark on an *empty* text object is synced (`:64`). **A byte mutation
cannot reach any of them**, because the input is a *valid* document whose
*operation order* is what is under test.

**No panic, no hang, no unbounded allocation.** All eight run in **0.64 s and
0.78 s wall clock at 10.5 MB and 12.6 MB peak RSS** over two runs of the whole
debug binary (`/usr/bin/time -v`). The boundedness is **argued, not timed**: the
only untrusted bytes in the file are the 207 of
`test/fixtures/broken_zero_width_mark.automerge` (byte-compared against the
reference before use — identical), whose framing holds the magic **once**, so
`parseChunks` runs once against a ceiling of `207 / 10`; and its chunk type is
`0x00` (`document`), **not** `compressed`, so **the DEFLATE decoder — the one
loop whose trip count is not a function of the input — is never entered**.

**Every named error is asserted by name**, not as "it did not succeed":
`error.InvalidMarkOrder` (`opset/index.zig`; upstream's
`ReconstructError::InvalidMarkOrder{Doc,Changes}`, both of which render
`"invalid mark operation order: …"`) and `error.InvalidValueType`
(`transact.joinTextValues`; upstream `InvalidValueType { expected: "a string",
unexpected: "Scalar(Int(1))" }`). A third-party probe of the reference for all
nine answers is `tools/oracle`'s new `richfuzz` subcommand.

**The one gap is `Automerge::rescue`** (`:232-243`), recorded at its own
upstream line. `rescue` is "load with `MarkOrderValidation::AllowInvalid`, then
`hydrate(None)`" (`automerge.rs:894-904`) and **the port has neither**: no public
load door skips the mark-order check, and `API.md` §Known gaps item 5 records
that there is no document-level `hydrate`. `src/root.zig` does not export
`storage.document`, so a consumer cannot build an op set from a document chunk
at all — **the gap cannot be closed by hand from outside the crate**. The
refusal half of the pair, case 8, is ported and green.

### 4. The `-Dslow-path` build option — closed 2026-10-01

There is now a `-Dslow-path` option in `build.zig`, carried into the library
module as `build_options.check_slow_paths` and read by both checks upstream
gates behind `slow_path_assertions`: `OpSet.seekOpsByIndex`'s fast/slow
cross-check (`src/opset/op_set.zig`) and `SlabBTree.assertSound`
(`src/hexane/btree.zig`). `zig build slow-path` runs the unit tests in a build
where the option cannot be off, so the checker is never a check nobody runs.
Both halves are demonstrated: a corrupted tree is `error.InvariantViolation`
with the option and silent without it, and each half fails if the gate is
removed. What is left is **not** the mechanism: it is the finding the option
made on its first run, and the cost.

**Superseded in part, round 5 (2026-10-06).** This paragraph named two readers
of `check_slow_paths`. There are **six** now: five op-set fast/slow
cross-checks — `OpSet.seekOpsByIndex` (`src/opset/op_set.zig:3746`),
`OpSet.seekListOpid` (`:3953`), `OpSet.queryInsertAt` (`:4346`),
`OpSet.calculateMarksAt` (`:4788`) and `OpSet.markSetAtIndex` (`:4976`) — and
`SlabBTree.assertSound` in `src/hexane/btree.zig`. Round 5 added
`seekListOpid`'s, which was the last ungated cross-check on a hot path; the
round-5 section has the full table with the upstream citations.

**And two of the five are not upstream's `slow_path_assertions` at all.**
`OpSet.seekListOpid` (`op_set.rs:846`) and `OpSet.queryInsertAt`
(`op_set.rs:583-598`) are plain `debug_assert_eq!`s that upstream compiles out
because its release profile leaves `debug-assertions` off
(`rust/Cargo.toml:14-16`). Porting them behind this option was a port decision,
not an upstream one. The one cross-check still ungated is
`OpSet.findOpByIdAndVis`, cheap because its slow arm stops at the end of the
row's own register (`op_set.rs:1131-1132`).

**It found a defect.** With the option off the library suite is 1229 passed /
1 skipped / 0 failed / 4m58s. With it on: 1228 passed / 0 skipped / **2 failed
/ 2 leaked** / 8m17s, both failures in `src/cursor.zig` and both from
`OpSet.seekOpsByIndex`'s fast/slow cross-check (`op_set.zig:2852`,
`expected error.InvalidCursorOp, found error.Invariant` on a text cursor at
`cursor.zig:1840`). That arm was comptime-dead until the option existed, so the
default build could not see it; re-running the frozen test binary reproduces
`1228 passed; 0 skipped; 2 failed` and `2 tests leaked memory`, so it is the
source state and not a concurrent edit. **Diagnosing it is a separate slice
and is not done.**

**Cost.** The `src/hexane/btree.zig` suite goes 2.46 s / 29 passed / 1 skipped
to 4.72 s / 30 passed / 0 skipped — that is the deep sweep the option buys. The
whole library suite goes 4m58s to 8m17s, the rest being the cross-check on
every `seekOpsByIndex` call site. Both Debug, both on the machine measured,
2026-10-01.

**`zig build ctest -Dslow-path` is green: 17/17, exit 0.** That combination is
new rather than a repeat — `cabi_lib` in `build.zig` imports `zautomerge`,
reaching the C ABI since it was added, with no wiring. The option-off run is
also 17/17, so the C surface does not move. `zig build conformance` is the one
gate the option cannot touch: it builds no Zig code (only `sh
tools/link-oracle.sh`, `cargo run` and `cmp`), and its subject is bytes from the
reference, which no comptime flag changes. The tests that *read* those vectors
are in the library test binary, which `zig build test -Dslow-path` already
covers.

**One environment fact the note below states without its mechanism, which is
the part worth keeping.** `LD_LIBRARY_PATH` must be **absolute**, and the reason
is the *working directory*, not the variable. `run_ctest` sets it to
`test/c/suite` (the `run_ctest.setCwd` line in `build.zig`), because upstream's
own CMake step arranges it that way for the four fixture-reading cases. So a
relative `LD_LIBRARY_PATH` resolves against `test/c/suite`, the loader does not
find `libcmocka.so.0`, and the step dies with exit 127 — reported as
`ctest transitive failure → run exe automerge-c-test failure`, which reads as a
build failure and is not one.

**The trap in it is that the two halves of one command line resolve
differently, and only the runtime half breaks.** `-Dcmocka-prefix` is consumed
at *build* time — `addIncludePath`/`addLibraryPath` on the module — so a
relative prefix works. `LD_LIBRARY_PATH` is consumed at *run* time by the
child, whose cwd is `test/c/suite`. So an agent who passes both relatively
sees the prefix succeed at link time, concludes the shape is right, and meets
the failure only after the whole link has finished. That is the same shape as
§1.1 one layer out: exit 127 and a red step are each compatible with "the code
is fine and the invocation is wrong", and only the message tells them apart.

**The durable fix is two changes, not one, and the measurement is why.** The
obvious one is the missing rpath — `each_lib_rpath = true` on the
`automerge-c-test` `Step.Compile`, the zig flag being `-feach-lib-rpath`
("ensure adding rpath for each used dynamic library") — and it is **not
sufficient on its own**. Measured on a two-line executable linked against the
prefix's `libcmocka.so.0`:

- `-L <absolute>/lib64 -feach-lib-rpath` → `RUNPATH: [<prefix>/lib64]`, runs from any working directory with no `LD_LIBRARY_PATH`, exit 0.
- `-L ../cmocka-prefix/lib64 -feach-lib-rpath` → `RUNPATH: [../cmocka-prefix/lib64]`, and from `test/c/suite` it fails with **the same `libcmocka.so.0` message and the same exit 127**.

So the rpath supplies the *entry* and the prefix supplies its *value*, and a
relative prefix produces a relative entry that is just as cwd-dependent as the
environment variable was. The pair is: **absolutise `cmocka_prefix` once**
(`b.pathFromRoot(prefix)`, public but documented as low-level) before it reaches
`addIncludePath`/`addLibraryPath`, **and** set `each_lib_rpath`. **Done, both
halves**: `build.zig` takes `b.pathFromRoot(prefix)` unless
`std.fs.path.isAbsolute(prefix)` is true, and sets
`ctest_bin.each_lib_rpath = true`. No test changes, and it deletes a requirement
from the invoker: the `LD_LIBRARY_PATH` export described above is obsolete, the
prefix is all the step takes, and a relative `-Dcmocka-prefix=../cmocka-prefix`
now works. **The `each_lib_rpath` line is a stated requirement rather than a
measured fix**: `readelf -d` reports the same RUNPATH with it set and unset on
this toolchain, because the linker already copies every `-L` directory into the
RUNPATH by itself. It is there so that if a future toolchain changes that
default, this is the line that says not to.

### 5. Gates measured, and one environment note

`zig build test`, `zig build conformance` and `zig build ctest` were all
**not measured** in the previous revision of this file; all three are measured
now, at the top of this file. `zig build ctest` needs `-Dcmocka-prefix=<dir>`
naming the directory holding `lib64/libcmocka.so` (here `../cmocka-prefix`, a
sibling of this repository, which is the default `test/c/build-cmocka.sh`
derives from the repository's own location); **without it the step does not
fail at the launch, it fails at the link**, with `unable to find dynamic system
library 'cmocka' using strategy 'paths_first'` and a search list that does not
include the prefix — which reads like a missing dependency rather than a
missing flag. That is the whole of the long-standing "`zig build ctest`
FAILS, reason never captured": there is no defect in the C ABI or the suite,
only an argument the gate does not pass. With the prefix the suite links,
runs and passes. The house gate was not run.

## How to work on this

- Read `AGENTS.md` first, then `plan.md` §6 for the phase you are in, then the
  matching section of `docs/survey/`. Every claim in the survey carries a
  `path:line` into the Rust source; do not work from memory of the Rust code.
- The test command is `zig build test`, or
  `zig test -ODebug -Mroot=src/root.zig` for the library suite alone. A module
  that `src/root.zig`'s test block does not name does not have its tests run —
  and a test that fails to compile in a module the block *does* name takes the
  whole suite down, which is what `src/c/sync.zig` demonstrates from the other
  direction.
- A test that instantiates a generic wrapper is not a test that calls its
  methods. `column.Shiftable(I)` resolves the *type* and leaves every method
  body unanalyzed, so `op_iter.zig`'s `assertShiftable` passed over six
  sub-iterator methods whose declared return type (`! ?T`) did not match
  their body (`!T`); an error union does not narrow into an optional payload.
  They surfaced only when a consumer wrapped a sub-iterator and forwarded the
  kernel, because that is what finally forced the analysis. Where a
  conformance mark exists for a type, something has to call through it.
- The repository is on a network export and the build cache should not be: put
  `ZIG_GLOBAL_CACHE_DIR` and `--cache-dir` on a large local scratch volume, and
  never let two builds share one. A system volume's `/tmp` is small; a dozen
  agents each with a private cache will fill it.
- `zig build conformance -- fixtures` runs the Rust reference against the
  corpus and prints the same 18 results the manifest records. `doc`, `change`,
  `codec`, `diff`, `converge` and `sync` emit the golden vectors to compare a
  Zig implementation against.
- The reference checkout is read-only. Never build in it, never modify it. And
  **do not trust `AUTOMERGE_REF`**: it points at another machine's path here.
  Use `../github-automerge-automerge`, or fix the export.