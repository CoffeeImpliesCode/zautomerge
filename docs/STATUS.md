# Status: where the port is, and what comes next

The plan of record is [plan.md](plan.md); this is the state of it.

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
  (`src/storage/chunk.zig:97-131`). And the streaming is `Document.load`'s, not
  the format's: `chunk.parseChunks` (`src/storage/chunk.zig:497`) is still the
  reader in four places — `src/storage/totality_test.zig:312`, `splitStream` in
  `src/sync/protocol.zig:1245` and in `src/v1.zig:789`, and `chunk.zig`'s own
  tests — and `splitStream` runs **per sync message**, so a message still
  materialises a chunk list. "No chunk list is materialised" is true of
  `Document.load` and of nothing else.
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

**Text red/green evidence:** before the range repair, the new tests observed suffix loss,
split-surrogate acceptance, partial deletion after allocation refusal, and index overflow.
The focused run passes after the repair.
`ConcreteTextValue` remains UTF-8-backed. It refuses split scalar boundaries and recomputes current grapheme segmentation.
Rust's native-unit trees and lossy rendering have a different contract.
See [survey/05](survey/05-iter-query-patch.md#traits-and-generics) for the cited representation gap.

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


**The instrument, stated first because a ranking whose instrument is unstated is
not a measurement.** Count coverage by this port's own
`test "<upstream file>: <English name>"` convention: one such block per upstream
case, and **no upstream-name-based measure is sound here**, because the port
renames every ported case into English. Name-presence under-counted this tree by
a factor of three — `diff_marks` read 13 of 36 by name and is 36 of 36 by
convention — and counting blocks that cite the upstream file failed the other
way, reporting 9 of 36 for `diff_marks` and 25 for `text.rs` when upstream has
15. **Both instruments were used to rank the gates here, both were wrong, and
the ranking they produced was retracted.** The convention is the only one of the
three that measures this tree; a name match remains a floor rather than proof —
it says a case exists, not that it asserts upstream's expectations.

| Upstream file | `#[test]` | Ported | |
| --- | --- | --- | --- |
| `tests/test.rs` | 140 | **140** | `test/upstream_doc_test.zig` and others |
| `tests/batch_insert.rs` | 46 | **46** | one file, two row-order assertions |
| `tests/diff_marks.rs` | 36 | **36** | `src/marks.zig`, prefix `diff_marks:` |
| `tests/text.rs` | 21 | **26 blocks** | prefix `text:`, in `src/read.zig`, `src/iter/spans.zig`, `test/upstream_text_more.zig` |
| `tests/text_encoding.rs` | 15 | **16 blocks** | prefix `text_encoding:`, in `src/read.zig` |
| `tests/block_tests.rs` | 19 | **19** | `test/upstream_block_tests.zig`, all green |
| `tests/convert_string_to_text.rs` | 3 | **3** | `test/upstream_convert_string.zig` |
| `tests/rich_text_fuzz_crash.rs` | 9 | **9** | `test/upstream_rich_text_fuzz.zig` |
| `tests/test_mark_patches.rs` | 1 | **1** | `test/mark_patches_test.zig` |
| `tests/test_save_load_orphans.rs` | 3 | **3** | `test/upstream_save_load_orphans.zig` |

**Every one of the ten upstream integration files is ported, every case** —
re-measured 2026-10-01, `FAIL=0`.

**And one of them had a recorded gap whose blocker landed later in the same
session, which is the pattern worth keeping.** `update_spans_uses_expand_config`
(upstream `block_tests.rs:676-726`) was recorded as blocked on
`UpdateSpansConfig`; that type arrived afterwards, for a different reason and a
different slice, and the recorded gap became stale rather than closing itself.
**A recorded gap whose blocker is later fixed is a gap that must be revisited,
and nothing in the gap announces that its reason has expired.** This one was
caught only because the table above was re-measured rather than assumed — the
same reason the retracted ranking was worth keeping visible. Neither announced
itself.

**A record whose reason has expired is a defect, so expired records are deleted
rather than amended.** The next reader who needs this one will not be the one
who finds it today, and the reason it existed is already in the history.

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

## What is done and verified

"Verified" means a test or an execution in this tree demonstrated it, not that
the file exists.

| Phase | State | Evidence |
| --- | --- | --- |
| P0 conformance harness | done | 18 corpus files, a manifest of what loading each must do, and a Rust oracle that drives the reference. The manifest/corpus agreement test passes (6/6). |
| P1 foundation | done | `error.zig`, `types.zig`, `value.zig`, `clock.zig`, `leb128.zig`, `unicode.zig`. |
| P2 hexane | **done; gate met 2026-10-04** | The final Debug gate passed all test roots and the forced slow-path root: 3722 passed, one default skip, no failures. The source ledger accounts for all 286 upstream occurrences: 272 covered, 14 reasoned exclusions, no missing occurrence. All five private BeLen cases run; the seed-799 vector replays Rust's actual 19-row, ten-splice fixture. All 1989 codec records match the reference; 1966 are native encoder byte cases. The existing exhaustive boolean test caught and now protects the merged-true-tail repair. See [plan.md](plan.md#p2--hexane) and [hexane-cases.json](hexane-cases.json). |
| P3 columnar and format | done | `parse.zig`, `chunk.zig`, `column_spec.zig`, `columnar/encoding.zig`, `columnar/columns.zig`, `storage/change_chunk.zig`, `storage/document_chunk.zig`. The document chunk reproduces the oracle's 446-byte `save()` output byte for byte. |
| P4 change graph and encoding | done | `change.zig`, `author.zig`, `change_graph.zig`, `change_queue.zig`, `storage/change_chunk.zig`. |
| P5 op set and merge | **done; gate met 2026-10-04** | The two named upstream files are ported: `tests/test.rs` 140/140 and `tests/batch_insert.rs` 46/46. The eight native save tests pass. The strengthened `zig build save-interop` passed 7/7 steps and verified six deterministic scripts: map, list, text, marks, conflicts, merge. Zig saves load in Rust; Rust re-saves load in Zig. Zig compares both the re-save and the independently built Rust save from `reference_hex`, byte for byte after column inflation. This caught and fixed the change-extra metadata tag (`0x56`: Null `0` instead of Bytes `7`). Actor/head order, column IDs/order/data, and the head-index suffix remain in the comparison. Values, heads, hashes, change metadata, and raw change bytes also match. The list case requires actual on-wire DEFLATE on both sides. |
| P6 document API | **done; signatures changed this revision** | `doc.zig` (the document, actor table, change graph, op set, `load`/`save`/`commit`/`merge`/`applyChanges`/`fork`/`forkAt`/`clone`/`isolate`, the diff surface, the bundle and fragment surface), `read.zig` (the whole `ReadDoc` surface — the unsuffixed readers, the eleven `_at` readers, `iter`/`iterAt`, the three cursor readers and `getCursorPositionFor`), `transact.zig` (the `Transactable` bodies and the manual `Transaction`), `transaction.zig` (`CommitOptions`, `Success`/`Failure`/`Outcome`, `enclose`/`encloseWith`, the accessors). **This row said "`read.zig` (twenty methods)"; that count was a snapshot and is not maintained** — the list of names is in `API.md` §Read, which is the thing to read. The crate-root address-book example **compiled and passed** (3/3, measured 2026-10-01) — the "`src/c/sync.zig` does not compile" claim this row used to carry is false. **Every constructor on this surface now takes a borrowed `std.Io`**, which is a signature change across the whole row and the reason every count in *Test state* is dated rather than current. |
| P7 iteration | **done; gate clause re-measured 2026-10-01 and met bar two named cases** | `sequence_tree.zig` and all six of upstream's iterators: `iter/tools.zig` (`Unshift`, `PeekShift`, `SkipIter`, `Diff`, `DiffKernel`, `Shiftable`), `iter/map_range.zig`, `iter/list_range.zig`, `iter/spans.zig`, `iter/keys.zig`, `iter/values.zig`, `iter/doc.zig` (`ObjIdIter`, `DiffIter`) and `iter/slice.zig`. The claim that "one of the ported text tests fails" is **false**: the library suite is **1469 passed, 1 skipped, 0 failed**. **This row said the gate's other clause was not met, on a name-presence count of 8 for `tests/text.rs` and 10 for `tests/text_encoding.rs`, and that count was wrong** — it is the same instrument this file has already retracted once, and the port renames every ported case into English. Verified case by case against both upstream files: **all 21 `text.rs` cases and all 15 `text_encoding.rs` cases are in the tree**, and the instrument that settles it is that case-by-case comparison rather than any name match. **34 of the 36 run under all four `TextEncoding`s**, so the gate's "the 15 tests each run under 4 encodings" holds for 34, and the two exceptions are named: `empty_marks_before_block_marker_dont_repeat_text` (`text.rs:321-348`) and the `marks_are_okay` proptest driver (`text.rs:658-710`). **Both build their model in ASCII-plus-`'\n'`, and a block marker is three units wide under `utf8_code_unit`** — upstream measures every non-`Set(Str)` action as `text_encoding.width("\u{fffc}")` (`op_set2/op_set.rs:443-447`) — so a `'\n'`-wide model does not describe that document. `src/read.zig:7971-7981` is the port's own record of the same two. |
| P8 sync | **done, measured 2026-10-01** | `sync/bloom.zig`, `sync/message.zig`, `sync/state.zig`, `sync/protocol.zig` and `sync/v1.zig`: the message codec, the peer state, the document-side state machine and the frozen v1 path. The gate's third clause names "the five round-trip tests from `sync/v1_compat_test/`"; upstream has **three** (`src/sync/v1_compat_test/mod.rs:473`, `:496`, `:519` — `bloom.rs` and `state.rs` declare none), and the directory is **907** lines as the plan says. The port's `src/sync/v1.zig` carries 9 tests, covering both directions and a v1-only peer. |
| P9 patches, marks, cursors, text diff, hydrate | **done; gate met** | `marks.zig`, `textdiff.rs` (the vendored Myers diff, byte-identical to upstream's), `patches.zig` (all nine `PatchAction` variants, the expose queue's ordering asserted as a property), `cursor.zig` (the v1 codec pinned as literal bytes in both directions, plus the legacy v0 parser), `hydrate.zig` (the round trip), and both `anonymize.zig` and `autoserde.zig`. **Both named files are ported: `tests/diff_marks.rs` 36 of 36** (`src/marks.zig`, one `test "diff_marks: …"` block per upstream case, all green) **and `tests/test_mark_patches.rs` 1 of 1** (`test/mark_patches_test.zig`, wired). The hydrate clause holds. **This row said "partly met, the weakest gate in the plan" until 2026-10-01, on a name-presence count of 12/36 that was measuring the wrong thing — the port renames every case into English.** **The hydrate dispatch arms are now measured, and the measurement is what closed the defect `plan.md` §1.1a records.** That section had one mutation: three tests all hydrating `.root`, a root is a map, so the `text` and `list` arms were never reached, and rewriting the `.text` arm to build an empty string left all three green. **It is now a sweep — 25 mutations applied at once, one per candidate arm, over the whole suite reachable from `src/hydrate.zig` — and 23 of the 25 arms were invisible to the entire tree while 2 were detected.** What closed it is the **nine tests now covering the uncovered arms**. `plan.md` §1.1a still carries the single-mutation account and has not been amended. |
| P10 C ABI | **current API-design evidence above** | `include/automerge.h`, production root `src/c/root.zig`, separate ABI check `test/c/cabi.zig`, and the C result/document/sync modules. The historical run passed 153 cmocka cases. The current guard reflects 187 physical function signatures, 37 enum names across five enums, and five exposed struct layouts. `AMbyteSpan` and `AMitems` cross by value. `zig build` installs `libzautomerge.a` and `automerge.h`. The suite links that artifact, not the check library. |
| bundle engine | **done, and the two halves are now both present** | **The bundle chunk codec works and is proved against the reference.** `storage/bundle.zig` carries **9** test blocks, among them `a bundle the reference wrote reads field by field, at literal offsets` and `a written bundle is byte for byte the bundle the reference wrote`, and the file is in the library suite through `src/root.zig`'s test block. **This row said the fragment API did not exist; it does.** `Fragment` is `src/change_graph.zig`'s, and the document surface `Document.bundle(gpa, hashes)`, `Document.fragments(gpa, levels)`, `Document.getFragment(gpa, head)` and `Document.bundleFragments(gpa, wanted)` are all declared, alongside the graph's own `cacheFragment` and `looseCommit`. `Automerge::get_fragment` / `Automerge::fragments` / `Automerge::bundle_fragments` are ported. |

## The API contract

`API.md` is the target public surface. It was audited against the tree on
2026-09-30, re-measured against both trees on 2026-10-01, and **re-audited for
this revision**. Its
[audit table](../API.md#audit-every-declaration-in-this-file-against-the-port)
records, for every declaration, whether it is present, renamed, absent or
deliberately different. **The Location column is now symbol-based, not a line
number** — four separate re-measurements found the numeric locators stale
because the port grew under them, and a locator that must be re-derived every
release is not a locator. Rust citations keep their `path:line` form, because
the reference checkout is pinned and read-only. The short version of
what the audit found:

- `Automerge::diff` and its five siblings were missing from `API.md` entirely,
  for a method thirteen upstream tests need.
- The manual `Transaction` surface was one sentence and no names.
- `getMarks` was documented as upstream's single-index `MarkSet` read and is in
  fact a half-open window over `[]Mark`. **Upstream's single-index read is now
  ported** — `read.markSetAtIndex` / `read.markSetAtScope` — and the window
  stays as `API.md`'s own method with its audit row saying which is which;
  `Transaction.get` and `Transaction.markSetAtIndex` are ported beside it. The
  gap that replaced the first two was "a transaction opened at historical heads
  does not always read at them"; **that gap is closed** — the transcription in
  `test/upstream_doc_test.zig:3126` asserts upstream's own values at every line
  and passes. The last recorded gap there — **a missing method**, the `_at`
  historical variants — **is closed too** (2026-10-01): `src/read.zig` carries
  all fourteen upstream spellings. **That sentence counted a second name the
  upstream crate does not have.** Upstream carries `at` on the three cursor
  methods themselves (`read.rs:203`, `:228`, `:241`), so the port's
  `getCursorAt` / `getCursorMovingAt` / `getCursorPositionAt` were a port-only
  split and **have been removed**; `getCursor`, `getCursorMoving` and
  `getCursorPosition` now carry `heads: ?[]const ChangeHash` in upstream's own
  argument position, and `API.md` § Conventions, §Read and §Known gaps item 2
  record the cutover. The same fold relabelled one refusal —
  `getCursorPosition` answers `error.InvalidCursor` where it used to answer
  `error.InvalidIndex` unscoped (`automerge.rs:1778-1781`).
- The actor block (`getAuthors`, `setActor`, `getActor`,
  `getAuthorForActor`, `getActorForAuthor`) was wrong against the **Rust** as
  well as against the port.
- `split` matched nothing at all, upstream or here; `rollback` is a
  transaction's method upstream and here, not a document's; `bundle` upstream
  takes a hash list and **there is now a document-level one** —
  `Document.bundle(gpa, hashes)`. **That sentence was correct when written and
  is wrong now**: the method was added to the tree and this file kept the old
  verdict.

- **Re-measured 2026-10-01, three more declarations wrong against the Rust, not
  only against the port.** `parents` was declared as
  `pub fn parents(doc, obj) Parents` — upstream `read.rs:35` returns a
  `Result<Parents<'_>, AutomergeError>` and the port's own `read.parents`
  returns `ReadError!Parents`, so the contract dropped an error union that
  *both* implementations have. §Write's "twenty … one for one" counts
  **twenty-one** declarations against upstream's **twenty** methods, and
  `mark` / `unmark` do not match `transactable.rs:103-117` in arity or order.
  All three are fixed in `API.md` with the upstream `path:line` beside them.
- **The numeric locators are gone rather than refreshed.** `API.md` cited
  `path:line` into this repository in 184 places, and 149 of them were wrong at
  the 2026-10-01 re-measurement. This revision replaces every one with the
  declaration's symbol, so there is no count of correct line citations left to
  keep in step.
- **Three known gaps were closed in the tree while the gap list still carried
  them** — `read.iter` / `read.iterAt`, `Document.getAuthors`, and
  `Document.bundle` with the fragment API beside it. **A gap the tree has
  already answered is a defect in the contract**, because the alternative is a
  caller declining to use a declaration that is sitting right there.

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
clock. The one thing that did need building is
`Document.clockAtScope` (`src/doc.zig`), upstream's `Automerge::clock_at`
(`automerge.rs:1236-1247`): the unsuffixed readers resolve their clock through
`readScope`, which reads the **isolation's** heads, and six of the new readers
hand a walk back — and a walk copies the `Clock` by value and borrows only its
`slots`, so the clock has to outlive the call. It shares the document's one
existing cache rather than adding a second.

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