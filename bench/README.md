# `zautomerge` end-to-end benchmark

`bench/zautomerge_bench.zig` is a standalone executable that measures the port's
real workloads the way a downstream project would drive them: through
`@import("zautomerge")` and the public module surface only, with no private
reachable and no fixture file.

It exists because the port's own suite says *which* cases are expensive but not
*what inside them* is expensive, and because a forty-minute Debug run cannot
answer "did that change help?" with the precision a before/after comparison
needs.

---

## 1. Building it

`zig build bench` builds and runs this file. The step is `build.zig:869-885`,
and it is worth reading rather than trusting:

```zig
    // The benchmark is built against the published `zautomerge` module by the
    // name a consumer imports it by, so it cannot reach a private and cannot
    // drift from the public surface without failing to build.
    const bench_bin = b.addExecutable(.{
        .name = "zautomerge-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/zautomerge_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_bin);
    run_bench.has_side_effects = true;
    run_bench.step.dependOn(b.getInstallStep());
    const bench_step = b.step(
        "bench",
        "Measure the seven dominant workloads and print a machine-readable line each",
    );
    bench_step.dependOn(&run_bench.step);
```

Three of those lines are load-bearing for everything in this file. **`.imports`
reuses the published `mod`**, so the library's `build_options` module — and
therefore the `check_slow_paths` gate `-Dslow-path` sets — is the same one the
tests see, and the only door into the library is the name a consumer imports.
**`link_libc` stays off**, as it does for every step except `example` and the
C ABI's own: nothing here reaches for a C symbol. And
**`run_bench.has_side_effects`**, so the measurements reach the operator as
they are printed rather than through a pipe the build runner keeps for a
failure report.

`target` and `optimize` are the existing `b.standardTargetOptions(.{})` and
`b.standardOptimizeOption(.{})` locals at the top of `build.zig`, and
`.optimize` is passed through rather than pinned: the whole point is that
`-Doptimize=ReleaseFast` on the command line reaches this step like it reaches
every other one.

**`bench/anonymize_rss.zig` is not in this step**, deliberately: its gate is
peak RSS, and it is a different kind of program from a `BENCH` workload. §8
gives the `zig build-exe` line that builds it.

The exact import name is **`zautomerge`**, the same name `b.addModule`
publishes it under at `build.zig:8` and that `test/example_test.zig:20` and
`test/save_interop.zig:33` use.

### Building and running it

```
zig build bench -Doptimize=ReleaseFast                       # every workload, reduced sizes
```

**That command takes no arguments.** `zig build bench -- segmentation` does
**not** run one workload: the `bench` step forwards nothing after `--`, and
`zig build` installs no executable, so a run with a workload name runs all
eleven and prints all eleven lines. That was measured — `zig build bench --
--list` ran the whole gate instead of printing the names — and it is why §7
builds the executable with `zig build-exe` and calls it directly for anything
that wants one workload per process.

`zig build bench` builds and runs in one step, so a plain
`zig build bench -Doptimize=ReleaseFast` is the right thing for "did anything
break"; §7's built executable is the right thing for a number.

**Use `ReleaseFast`.** The case times this benchmark is derived from are Debug
times, and Debug is roughly an order of magnitude slower on this code; a Debug
build of these defaults is usable but the numbers are not comparable with a
ReleaseFast before/after pair. Conversely a ReleaseFast number here is *not*
comparable with the Debug case record — this benchmark is for diffing two
ReleaseFast builds against each other, and for `perf` attribution.

`-Doptimize=ReleaseSafe` or `Debug` both work and additionally give the leak
arbiter's per-allocation checks (see §3).

---

## 2. Reading the output

Every workload prints exactly one line on **stdout**:

```
BENCH <name> <iters> <total_ns> <ns_per_iter>
```

| field | meaning |
|---|---|
| `name` | the workload name, as `--list` prints it |
| `iters` | **unit iterations inside one sample**, not the number of samples. `indexed-delta 20 …` means twenty trials, so `ns_per_iter` is the cost of one trial |
| `total_ns` | the median sample's nanoseconds (lower-middle of the sorted samples) |
| `ns_per_iter` | `total_ns / iters` |

Nothing else goes to stdout, so:

```
zig build bench -Doptimize=ReleaseFast 2>/dev/null | grep '^BENCH '
```

is the complete result set and diffs cleanly between builds.

Everything else — the size table, the per-phase nanoseconds, the checksum, the
leak count — goes to **stderr** through `std.debug.print`, which is this
repository's existing idiom (`test/save_interop.zig:85`).

### The primary metric is not on that line

This host is shared and busy. Wall clock on an identical program moves a few
percent between runs; the instruction count does not move at all. So:

```
perf stat -e instructions "$buildhost_SCRATCH_ROOT/bench/zautomerge-bench" segmentation
```

`zig build bench` does **not** produce an installed binary and does **not**
forward the arguments after `--` to the workload run — `zig build bench --
--list` runs all eleven workloads and prints all eleven lines, which was
measured, not assumed. So the executable is built once, outside the repo, with
§7's `zig build-exe` line. Put `-O ReleaseFast` **before** the first `-M` flag;
after them the build runner reads it as a per-module option and the binary
comes out `Debug`, which this same file's §8 recipe used to get wrong.

Run **one workload per process** and `perf stat`'s instruction count belongs to
that workload alone. Quote instruction counts, not wall clock. When you do quote
wall clock, quote the load average next to it.

**One workload per process is necessary and not sufficient.** It makes the count
belong to one workload; it does not make the count belong to the workload's
*subject*, because the count covers whatever the workload built before it
started the clock. `list-width` is the one that got this wrong and §7 says what
it cost: its fixture was about 98% of the count, so `perf stat` was reporting
the fixture while the `BENCH` line reported the walk. It now prints the share
every phase had of the process and **fails the run** unless the subject is at
least `list_width_subject_floor_pct` of what it measured. When you read a
`perf stat` line for any workload here, find its stderr block first: if the
workload times a region rather than its whole iteration, the count is
subject plus fixture until the workload says otherwise.

**`insert-loop` is the same rule pointing the other way.** Its fixture *is* its
subject — the insert loop is the whole workload — but its correctness read-back
is a `listRange` walk over every element, which `list-width` measures at tens
of microseconds per element. So the read-back, not the subject, is the large
share of that process, and a whole-process instruction count is **not** a
measurement of `Transaction.insert`. §7 says so on the workload, and the
workload prints its phases so the split is on the record. What it does print
that survives the caveat is the **growth ratio**, because that is computed from
the two timed subject regions and nothing else.

All eleven workload names are what `--list` prints. §7 gives the per-workload
`perf stat` lines for the four that are here because a specific cost had no
gate, rather than because a test case was slow.

For attribution:

```
perf record -F 999 -g --call-graph dwarf \
    -o "$buildhost_SCRATCH_ROOT/seg.data" \
    "$buildhost_SCRATCH_ROOT/bench/zautomerge-bench" segmentation
perf report -i "$buildhost_SCRATCH_ROOT/seg.data" --stdio
```

Write that data file to `"$buildhost_SCRATCH_ROOT"`, not to `/tmp` — this host's
`/tmp` is shared, and a `perf.data` of a few hundred megabytes does not belong
there.

---

## 3. `std.Io` and the allocator — everything a fresh reader needs

The file uses `pub fn main(init: std.process.Init) !u8`, the same entry point
`test/save_interop.zig:64` uses. `std.start` builds the argument and fills it in
(`std/start.zig:696-747`).

### The capability

```zig
pub fn main(init: std.process.Init) !u8 {
    const gpa = /* see below */;
    const io = init.io;
```

`init.io` is a `std.Io` handed over by a `std.Io.Threaded` that `std.start`
creates for you. **`Document.init`, `Document.initWithEncoding` and
`Document.load` all take one**, and they retain it, so it must outlive every
document — which it does, because `std.start` closes the thread pool after
`main` returns. A benchmark that built its own would have to outlive its own
threaded-IO instance, which is one more thing to get wrong for no benefit.

`std.testing.io` (what the tests use) **does not exist in an executable**: it is
installed by the test runner, not by `std.start`.

### The allocator — and why `init.gpa` alone is not enough

`init.gpa` is a real allocator, but **it is not a leak arbiter in
`ReleaseFast`**. `std.start` only installs its own `DebugAllocator` when
`use_debug_allocator` holds, which needs either a non-`ReleaseFast` mode, or
`link_libc` plus `single_threaded` (`std/start.zig:689-713`). A plain
`ReleaseFast` native build falls through to `smp_allocator`, which detects
nothing at all.

So the file builds its own arbiter over it:

```zig
    var arbiter: std.heap.DebugAllocator(.{ .safety = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall }) = .{
        .backing_allocator = init.gpa,
    };
    const gpa = arbiter.allocator();
    defer arbiter.deinitWithoutLeakChecks();
    // …
    const leaked = arbiter.detectLeaks();   // runs in every mode, safety or not
```

- `safety` mirrors what `std.start` would have chosen. The per-allocation checks
  are what you want in Debug and ReleaseSafe and are a measurable tax on a
  benchmark that performs tens of thousands of allocations per iteration.
- `detectLeaks` is called **directly** rather than relying on `deinit`, because
  `deinit` only scans when `safety` is on. So `LEAKS n` on stderr is on the
  record in every optimize mode. With `safety` off the count is still right and
  the per-leak stack traces are not.
- Two small scratch arrays (`samples`, `sorted`) are deliberately taken from
  `init.arena` instead of the arbiter, because `detectLeaks` runs before any
  `defer` in `main` has fired and an arbiter-owned buffer freed by a `defer`
  would be reported as a leak of the benchmark's own.

`std.testing.allocator` is likewise a test-runner install and **must not** be
used here.

Every workload gets `gpa` through `Ctx` and frees everything it takes:
documents via `deinit`, column slices via `gpa.free`, `hydrate.Map` via
`deinit`, saved bytes via `gpa.free`. The arbiter is the check on that claim.

### The clock

```zig
const started = Io.Clock.Timestamp.now(io, .awake);
// … work …
const ns: u64 = @intCast(started.untilNow(io).raw.nanoseconds);
```

Read exactly the way `test/verification_runner.zig:203` and `:221` read it, so
this executable and the suite's own case record are on one clock. `std.time.nanoTimestamp`
is the old clock and is not what this port uses.

### The streams

```zig
    var stdout_buffer: [stdout_buffer_len]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};
```

The buffered writer's `interface` field is the `std.Io.Writer`. `out.print`,
`out.writeAll` and `out.flush` are the writer's own methods. stderr needs no
setup at all — `std.debug.print` writes there.

### Arguments

```zig
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
```

`init.arena` is an `ArenaAllocator` over `page_allocator` that `std.start` frees
after `main` returns, so parsed arguments need no `defer`.

---

## 4. The workloads, and which sizes are reduced

Seven workloads, one per expensive case, and four more that have no case
behind them at all. The table below is the first seven: it says exactly what
is different from the test case, and why the reduced shape measures the same
thing. §7 is the other four.

| workload | test case | default | test | reduced? |
|---|---|---|---|---|
| `segmentation` | `src/textdiff.zig:1679` | 50-record body, 1024 single passes | 500-record body | **10× smaller** |
| `indexed-delta` | `src/hexane/column.zig:15125` | 20 trials × 400 splices | 200 trials × 400 | **10× fewer trials** |
| `slab-merge` | `src/hexane/hexane_test.zig:474` | 20 trials × 500 ops | 200 trials × 500 | **10× fewer trials** |
| `prefix-bool` | `src/opset/columns.zig:3700` | 20 trials × 300 ops | 200 trials × 300 | **10× fewer trials** |
| `update-object` | `test/upstream_doc_test.zig:1403` | depth 42 | depth 42 | **no** |
| `mark-index` | `src/opset/mark_index.zig:2459` | 40 000 rows, 1000 marks | 100 000 rows, 2500 marks | **2.5× smaller** |
| `mark-at-end` | `src/read.zig:6537` | 210 000 chars, 1 encoding | 210 000 chars, 4 encodings | **4× fewer encodings** |

`--full` restores every "test" column above, and gives the four of §7 their
larger documented size.

### Why each reduction is the same measurement

**`segmentation` — 10× smaller, and it is the only O(n²) workload here.** The
case's cost is in `byPerPrefixCount` (`src/textdiff.zig:1652`), which calls
`am.unicode.countGraphemes` once per code point over the whole prefix. That
makes it Θ(n²) in the body length: 500 records is 23 500 bytes and 14 500 code
points, so 105 132 250 prefix visits; 50 records is 2 350 bytes and 1 450 code
points, so 1 051 975 — **99.9× fewer, from 10× fewer records**, which is the
signature of a quadratic and the reason the reduction is safe. The record,
the nine short cases, the loop and the oracle are all identical; only the
repeat count changed, and it changed by the one factor that makes the total fit
the budget.

The workload reports two phases. `oracle-by-per-prefix-count` is where the
164.87 s went. `single-pass-graphemes` is `am.textdiff.graphemes` — the
production path, what a consumer actually pays — repeated 1024 times over the
same body because one O(n) pass over a reduced body is below the clock's floor.
Same input in both phases, so the ratio between them is a statement about the
two implementations and not about two different texts.

`byPerPrefixCount` is private to `src/textdiff.zig`, but everything it calls is
public (`am.unicode.countGraphemes`), so the benchmark **reproduces it line for
line** rather than approximating it. That matters: it is the only way to
measure this case's actual hot path from outside the library.

**The three column fuzzers — 10× fewer trials, per-trial sizes untouched.** In
all three the expensive object is what happens *inside* one trial: 400 splices
into a growing delta column, 500 splices and removes into a growing RLE column
with a full layout read-back after every one, 300 splices and removes into a
boolean prefix column with a prefix fold and a full row check after every one.
A trial is self-contained — it builds its own column, draws from its own
seeded generator and tears the column down — so 20 trials exercise exactly the
same code 20 times as 200 do. Trial count changes the sample count, not the
per-trial shape, and `iters` is the trial count so `ns_per_iter` is
per-trial either way.

The per-trial generators are reproduced verbatim, and they are the reason a
trial is expensive at all:

- `indexed-delta` uses upstream's `DefaultPrng` seeded `0x0DE1A` and, every
  fourth insert, writes **three copies of one value** — because a run of three
  equal values is two zero differences behind each other, which is the
  shortest sequence that forces a repeat run and stops the column canonically
  collapsing into one literal run. Without it the column stays in a single slab
  and the indexed queries are trivial. The workload asserts `slabCount() >= 2`
  so a regression there fails rather than measuring nothing.
- `slab-merge` uses upstream's `xorshift` from the fixed state `98765`, with
  the three shifts in upstream's order and the draw that is *not* made while
  the column is empty left out, so the two generators walk the same sequence.
  It also asserts the column is on the default segment budget, because the
  merge policy is only the same question while it is.
- `prefix-bool` uses the same `xorshift` from `44444`, and `BoolPrefixColumn` is
  the op set's own boolean prefix codec rather than the column layer's, since a
  boolean column's weight has to count its `true` rows.

**`update-object` — not reduced at all, and it is the one workload that times a
region rather than a whole call.** The depth is the case's 42, which builds 43
maps, 861 lists and 905 hydrated values. Building that mirror and creating the
document are setup and sit outside the clock; `am.transaction.updateObject` is
inside it, because that call is the hot thing (47 s of the case's 66 s) and
timing it together with a fixture build would bury it. The read-back afterwards
is also outside the clock and is what keeps the workload honest — if
`updateObject` stopped writing the document, the checksum would change.

**`mark-index` — 2.5× smaller rows and marks, same shape.** The case is about a
column whose rows span **many slabs**, so the prefix fold in `marksAt` has to
cross slab boundaries; and about **every third mark undone, last one first**, so
the undo sweep crosses them too. Both properties survive the reduction: 40 000
rows with 1000 marks over them is still several slabs (the workload asserts
`col.data.slabCount() > 1` and fails rather than measuring a one-slab column),
and the undo sweep is still every third mark, last first. The dominant cost is
the full-column walk per undone mark, which scales with rows × undos, so the
reduction is close to linear in the work done and 2.5× is ample. The placement
generator is the case's own SplitMix64 from seed 42, and finding a mark's rows
is the case's full column walk, both unchanged.

**`mark-at-end` — one encoding instead of four, and the text length is not
reduced at all.** The case's whole point is that the mark is **far past the
first page of the op tree**, so 210 000 characters stays 210 000 characters;
shrinking it would change what is being measured. What the case varies is the
encoding, and it says the answers are the same under all four because the text
is pure ASCII. Running one encoding (`.unicode_code_point`, the port's default)
measures the same work over the same bytes without doing it four times.

### What is *not* reproduced, and does not matter

Two of the seven cases do their per-operation checking through helpers that are
private to the file that owns them. Both are rebuilt here over public API:

- `fuzz_slab_merge_invariant`'s `expectSlabMergePolicy` is a predicate over the
  slab layout. The public half of what it reads — the full column walk and the
  slab count — runs after every one of the 500 operations here too.
- `fuzz_indexed_delta_column`'s `deltaRangeRows` / `deltaFindFirst` helpers are
  thin wrappers over the codec's own range and first-value queries. The column's
  own `findByValue` / `iterRange` / `encode` / `load` surface is exercised
  directly instead.

Neither omission changes which code runs inside the loop being timed; both only
drop the assertion the loop is wrapped in.

---

## 5. Timing and the median

`--repeat N` runs each workload N times and reports the **lower middle** sample
after sorting — for an even N, the smaller of the two central observations,
because that is a real measurement rather than an average of two.

On a quiet machine that is enough. On this one it is not sufficient on its own,
which is why §2 says to take instruction counts as the primary metric. Wall
clock here moved ~4% between identical runs at a load average of ~100.

### Nothing is optimised away

Every observation a workload makes is folded into a `u64` checksum through
`Result.mix`, which multiplies rather than adds so a workload cannot pass by
producing the same total in a different order. Each checksum is printed on
stderr, and they are summed into one sink printed at the end. Workloads also
assert their own results where the case does (`slabCount() >= 2`,
`prefix total == model's true count`, `encode(load(x)) == x`, the mark runs),
so a change that made the work cheaper by making it wrong fails instead of
looking like a speedup.

The four of §7 have no case to copy, so their assertions were written for the
same purpose and are named there: an ascending duplicate-free `sent_hashes`,
`element.width == 1` for every list element, a `hashForOpid` answer that equals
the commit that wrote the operation, and an insert loop whose saved document
round-trips element for element.

`list-width` has one more: outside the timed region, in its `verify` phase, it
builds the same 64-element list **twice** — once with 64 `Transaction.insert`
calls and once with a single `am.transaction.spliceHeld` — and reads both back
through the same `am.read.listRange`, requiring every element's index, width,
no conflict, not an object and integer value to agree. So the batch that
builds the fixture cannot make the walk cheap by making it wrong.

---

## 6. Verifying a run

1. `zig build bench -Doptimize=ReleaseFast` and check which `#   the timed
   region is the workload's own` lines appear. **Five** workloads time a
   region rather than a whole iteration — `update-object`, `sync-roundtrip`,
   `hash-for-opid`, `list-width` and `insert-loop` — and for each of those the
   phases on stderr say how the untimed part was spent. Every other workload
   times its whole iteration.
2. Check stderr ends with `# LEAKS 0`. A nonzero count is a bug in the
   benchmark, not in the port.
3. Compare `#   checksum` before and after. **The checksums must be identical
   across a before/after pair.** If they are not, the optimization changed
   behaviour and the timings mean nothing.
4. Compare `BENCH` lines with `diff`, and instruction counts with `perf stat`.
5. On a `list-width` run, find the `#   list-width: subject … ns of … ns
   measured = …% (floor 90%)` line on stderr. That percentage is the whole
   point of that workload: it is the fraction of the process `perf stat` is
   counting that belongs to `elementWidth`. **Below the floor the run fails**
   with `error.SubjectIsNotTheCost` and prints no `BENCH` line at all, so a
   fixture-dominated run cannot be mistaken for a subject measurement — and
   neither can a `perf stat` count taken from one.
6. On an `insert-loop` run, find the `#   insert-loop: per-insert cost grew
   …x for a 4x size change` line on stderr. That ratio **is** the measurement:
   about `1.000` means the per-insert cost is flat in `n`, which is the
   finding, and about `4.000` means an O(rows)-per-insert stage is back.
   **Past the ceiling (`2.000`) the run fails** with
   `error.InsertCostStillGrowsWithTheDocument` and prints no `BENCH` line at
   all, so a quadratic that came back cannot be read as a passing gate.

---

## 7. The gates that had no case

A data-oriented audit of the port named four costs the suite exercises but never
isolates, and therefore four that no change could be honestly accepted or
rejected against. Three of them are workloads here. The fourth, `insert-loop`,
is **not one of the audit's four**: it measures a cost the audit never named,
which the `list-width` gate found by accident while measuring its own fixture.
All four are reached **through the public module surface only**: nothing in
them imports a private, and where a check needed a field the port would
otherwise have to expose for the benchmark's benefit, the field was already
public and is cited.

| workload | subject | default | `--full` |
|---|---|---|---|
| `sync-roundtrip` | the sorted insert into `sent_hashes` | 24 rounds × 200 changes | 48 rounds × 400 changes |
| `hash-for-opid` | `hashForOpid`'s linear scan | 20 000 changes, 400 calls | 50 000 changes, 1000 calls |
| `list-width` | `elementWidth`'s five cursors per element | 50 000 elements, 2 walks | 200 000 elements, 1 walk |
| `insert-loop` | `Transaction.insert`'s per-insert write path | 2 500 + 10 000 inserts, one transaction each | 5 000 + 20 000 inserts |

**The subject column, superseded in round 5 (2026-10-06).** The four size
pairs in that table are left exactly as round 4 published them: they are being
re-measured, and the new figures belong to that re-measurement. The **subject**
column is not left, because round 5 changed what three of these four workloads
time. `sync-roundtrip` times `State.extendSent`'s sort-and-merge
(`src/sync/state.zig:396`), not a per-hash `ArrayList.insert`; `hash-for-opid`
times an answer from `ChangeGraph.opidToHash` (`src/change_graph.zig:1704`),
not a walk of the node table; and `list-width` times **one held element cursor**
per element, not ten fresh column cursors. `insert-loop`'s subject did not
change. Each heading below carries its own supersession note.

`--full` for these four is **not** "the test case's exact size" — there is no
test case. It is a larger size of the same shape, so that a before/after pair
has a second point on the curve rather than one. For `insert-loop` the factor
is the **same on both sizes**, because the growth ratio between them is the
measurement and a run whose ratio moved would be measuring something else.

### `sync-roundtrip`

**The line under test** is `src/sync/protocol.zig:588`,
`try state.extendSent(builder.payloadHashes());`, which is `State.extendSent` at
`src/sync/state.zig:396`: the message's hashes are sorted once and merged into
the ascending set in a single pass. Upstream extends a `BTreeSet`
(`sync.rs:253`), which is `O(k log n)` per message; this is the sorted-array
spelling of that same call (`src/sync/state.zig:366-395`).

**Superseded in round 5 (2026-10-06).** This paragraph used to name
`src/sync/protocol.zig:572`, `for (builder.payloadHashes()) |hash| try
state.insertSent(hash);`, and `State.insertSent` at `src/sync/state.zig:368-382`
— a binary search over an ascending list and then an `ArrayList.insert`
memmove, **once per hash per generated message**. `clearSent`
(`src/sync/state.zig:489`) was the only thing that emptied the list, so the
memmove arm was quadratic in the changes a peer had been sent in one session.
Round 5 replaced it with the batch: one sort and one merge per message instead
of one memmove of half the list per carried hash. `State.insertSent`
(`src/sync/state.zig:484`) is still `pub` and still correct; it has no caller
left on this path.

**The public chain**, driven as `test/upstream_doc_test.zig:4955-4969` drives
it: `am.sync.state.State.new` (`src/sync/state.zig:181`) →
`am.sync.protocol.generateSyncMessage` (`src/sync/protocol.zig:433`) →
`am.sync.protocol.receiveSyncMessage` (`src/sync/protocol.zig:674`). The set
itself is checked through `State.sent_hashes`, which is a **public field**
(`src/sync/state.zig:156`).

**The shape.** Two `.auto` documents and two sync states, both made by
`State.new`. The local side gains `sync_chunk` changes per round — one
autocommit each, so they are real changes with real hashes — and a peer keeps
up, so each round's payload is a real delta and `sent_hashes` is already
`round * sync_chunk` long when the insert loop runs. A priming exchange comes
first, because the peer's *first* message is what tells the local side the peer
reads V2 and holds nothing, and that is what arms `sendDoc`
(`src/sync/state.zig:341-344`); without it `buildPayload` answers an empty
payload while `State.their()` is null (`src/sync/protocol.zig:971`).

**Timed region.** `ns` is the sum of the `local-generate` phases only — one
`generateSyncMessage` per round, which is the unit the insert loop runs in.
`peer-exchange` and the fixture growth are phases, not the clock.

**The assertions**, all of which fail a change that got cheaper by being
wrong:

* `sent_hashes` is **ascending and duplicate-free** — the `BTreeSet` invariant
  `State.encode` asserts and `sentContains` binary-searches. An append-and-
  sort-later or duplicate-dropping insert passes a length check and fails this.
* `sent_hashes.items.len == local.graph.len()` — every change the document
  holds went on the wire exactly once.
* every round's payload recorded **at least one** new hash, so the run cannot
  "measure" a state in which the loop never ran.
* the two peers hold the same heads, the peer's copy of the list has every
  element the local one has, and — after one more advertisement, which is what
  clears the local `in_flight` bit — the local side has nothing left to send.

**Checksum.** the length of `sent_hashes` after every round and the element
total, through `Result.mix`.

**Runtime.** Order 1–3 s at the default size on this host, under load. The
default is 4800 changes built and exchanged; `--full` is 19 200.

### `hash-for-opid`

**The line under test** is `src/transaction.zig:433-436`: `hashForOpid`
delegates to `ChangeGraph.opidToHash` (`src/change_graph.zig:1704`), which is
the port of `change_graph.rs:300-318` and binary-searches **that actor's own**
change list. Upstream calls the same function and pays the same cost.

**Superseded in round 5 (2026-10-06).** This paragraph used to name
`src/transaction.zig:411-423` and say that `hashForOpid` walked the change
graph's node table from row zero — `O(C)` in the whole graph — where upstream
binary-searched the actor's own change list, so the question was the `C` in
that `O(C)`. Round 5 made it a delegation instead: `opidToHash` has been `pub`
since `src/change_graph.zig` was written, and `src/transaction.zig:423-431`
records why the walk was there to begin with. The fixture is still a document
with many changes, which is still what makes the call worth timing.

**The public chain**, reached the way `src/transaction.zig:1446-1472` reaches
it: a `.manual` document, `am.manual_transaction.Transaction.open`
(`src/transact.zig:480`), `am.manual_transaction.commitWith`
(`src/transaction.zig:566`), and `am.manual_transaction.hashForOpid`
(`src/transaction.zig:433`) — the module `src/root.zig:119` re-exports.
`doc.ops.idToExid` (`src/opset/op_set.zig:3240`) turns the operation ids the
writes returned into `ExId`s.

**The shape.** `opid_changes` committed changes, one map put each — the
cheapest shape a change can have, deliberately: the cost under test is one
interval query over that actor's own change list, so every extra operation in
the graph would be fixture work the real question does not do.

**Timed region.** `ns` is the `scan-last-op` phase only: `opid_calls` calls
for the **last** operation, whose change is the actor's newest. The
`scan-first-op` phase is the same call for the **first** operation, whose
change is the actor's oldest, so what the ratio between the two phases measures
is where in that actor's list the binary search lands. `build-graph` is the
fixture.

**The assertions**: every call returns the change hash the commit returned;
the root names nothing; an `ExId` past the graph's counters names nothing; and
the last operation's hash is still there after both scans.

**Checksum.** the graph length, then the first eight bytes of every returned
hash, big-endian, through `Result.mix`.

**Runtime.** Order 0.5–2 s at the default size, most of it the fixture. The
`scan-last-op` phase alone is tens of milliseconds, which is why the count is
400 and not 4.

**Superseded in round 5 (2026-10-06).** The paragraph above is the round-4
runtime, measured against a node-table walk. `scan-last-op` is no longer a
scan, so its share of this process — and the reason the call count is what it
is — belong to the re-measurement. Nothing has been invented in their place.

### `list-width`

**The line under test** is `src/iter/list_range.zig:923-941`, `elementWidth`,
which takes the caller's **held** `ElemCursor` (the parameter at
`src/iter/list_range.zig:926`, the field at `:1005`) and asks it for one
element (`:930`). That cursor is already placed, so `ElemWalk.seek`
(`src/opset/op_set.zig:5941`) takes its **move** arm — `setMax` per column and
a forward `advanceTo` — instead of building five column cursors. Two of the
five are delta columns, and `iterRange` (`src/opset/op_set.zig:2952`) folds
their wire to reach the row asked for.

**Superseded in round 5 (2026-10-06).** This paragraph used to name
`src/iter/list_range.zig:884-901` and say that `elementWidth` called
`OpSet.elemidAt` (`src/opset/op_set.zig:3500-3503`) and so built the five column
cursors of `OpSet.elemCursor` (`:3524`), and then — because a fresh cursor is
never `placed` (`:5670`) — had `ElemWalk.seek` (`:5738`) build all five
**again**: **ten** column cursors per element. Round 5 gives `ListRange` one
cursor (`src/iter/list_range.zig:1005`) and moves it, and that is the change
the sizing below re-measures.

**The exact public chain**, which is the answer to "which call does this
measure":

```
am.read.listRange(doc, list, am.read.IndexRange.all())   src/read.zig:2280
  → ListRange.next()                                     src/iter/list_range.zig:1052
    → ListDiffItem.exportItem(set, elems, rows)          src/iter/list_range.zig:612
      → elementWidth(set, elems, pos, end)               src/iter/list_range.zig:923
        → ListRange.elems.at(pos, end)   the held cursor src/iter/list_range.zig:1005
          → ElemWalk.seek()   move arm, setMax x 5      src/opset/op_set.zig:5941
```

`mark-at-end` walks a **text** through the same `ListRange`; this one walks a
**list**, which is the object `elementWidth` is written for and the shape the
audit named.

**The shape.** A `.manual` document under the `.unicode_code_point` encoding
holding one list of `list_width_elements` integers plus one sibling text
object, built by **one** transaction and **one** commit. One change, not one per
element: a committed change per element would put that many changes in the
change graph and measure that too. `mark-at-end` splices 210 000 characters
through a single `spliceText`, so a single change this size is already well
inside what the port does.

The integers go in through **one `am.transaction.spliceHeld` call**
(`src/transact.zig:2854`) — the door upstream's `Transactable::splice` goes
through (`rust/automerge/src/transaction/transactable.rs:85-91`,
`inner.rs:673-799`), which reaches `Transaction.spliceListValues`
(`src/transact.zig:1328`) and writes the whole run as one `BatchInsertion`
(`src/transact.zig:1343-1373`, upstream `inner.rs:714-737`). Upstream chains
the elements by `ElemId` in that loop (`inner.rs:723-725`), which is what makes
the batch the same list a loop of appends would produce.

### The defect this workload had, and the two things that fix it

**It was measuring its fixture.** The first version built the list with
`for (0..n) |i| try tx.insert(list, i, ...)`. At the default size that loop's
`build-list` phase measured about **1011 s** against a `read-list` subject of
16.1 s, and `perf stat -e instructions` over the whole process — the metric §2
tells a reader to quote — reported **4.69e12 instructions in about 1027 s of
wall clock**, which is 4.6e9 instructions/second, a whole process at about
1.5 IPC. Spread over the subject's own 16.1 s the same count would be 2.9e11
instructions/second, which no single core reaches. So about **98% of the
instruction count was the fixture**, and the `BENCH` line — which carried the
subject — could not be reconciled with the number a reader was told to prefer.
Both numbers were authoritative-looking and they were about different things.

**The obvious lever was already in the file.** "Build the list by appending at
the end rather than at ascending positions" changes nothing here: at step `i`
the list holds `i` elements, so `i` *is* the last index. That loop was already
appending.

**The lever is one call instead of `n`.** `Transaction.insert`
(`src/transact.zig:975-985`) goes through `doInsert`
(`src/transact.zig:866-897`), which runs a `queryInsertAt` and an
`insertLocalOp` **per element** against a growing op set.
`spliceListValues` runs **one** `queryInsertAt` for the whole run
(`src/transact.zig:1242`) and one `Batch.finish` (`:1373`). Measured on this
host, ReleaseFast, default sizes, load average ~120:

| | before | after |
|---|---|---|
| `build-list` (the fixture) | ~1011 s | **97.9 ms** / 87.0 ms / 115.6 ms on three runs |
| `read-list` (the subject) | 16.1 s | 8.64 s / 8.28 s / 9.00 s |
| subject's share of the process | ~1.6% | **98.66% / 98.70% / 98.48%** |
| whole-process instruction count | 4.69e12 | **48.37e9** |

The fixture is **about 10 000× cheaper** and the instruction count falls by
**96.9×**, which is the same 98% leaving the count. Three runs, three
subjects; the wall clock moves with the load average, the share does not.

**The guard is what stops it being misread again.** `list-width` measures its
own total — fixture, subject, the oracle and the document teardown — and
returns `error.SubjectIsNotTheCost` unless the subject is at least
`list_width_subject_floor_pct` (90) per cent of it. A workload that returns an
error prints `# FAILED` and **no `BENCH` line at all** (`main` returns 1), so a
fixture-dominated run cannot be read as a subject measurement, and neither can
a `perf stat` count taken from one. Every run prints the split:

```
#   list-width: the sequential and the batched 64-element fixtures read back identically; their saved bytes are identical
#   list-width: subject 9000666328 ns of 9139788346 ns measured = 98.48% (floor 90%); fixture 1.27%, verify 0.23%, teardown 0.03%
```

The **teardown is inside the denominator on purpose**: freeing a document this
size is work `perf stat` counts, so it is measured rather than assumed away.
90 is far under the measured share and far over the ~1.6% the old fixture
left, so an ordinary host cannot trip it by accident and a regression cannot
pass by getting slower somewhere else.

### The two fixture builders, checked against each other

Outside the timed region — in the `verify` phase, so it costs the subject
nothing — the workload builds the same 64-element list **twice** in two
throwaway documents: once with 64 `Transaction.insert` calls at ascending
positions, which is what this workload used to do and what a consumer
appending one element at a time still does, and once with a single
`am.transaction.spliceHeld`. Both are read back through the same
`am.read.listRange` the subject uses. Every element has to agree on its index,
its width being exactly 1, not conflicting, not being an object, and its
integer value; `am.read.length` has to say 64 for both. **So the batch cannot
make the walk cheap by making it wrong**, and the fixture change is checked
rather than argued.

The two documents' **saved bytes are reported, not required**: they are
identical today, and a future difference would be a fact about the encoding
rather than a failure, since this workload's contract is the materialized
document. The line is printed so the next reader does not have to assume.

### The library finding, reported on its own

**The ~1011 s is not this gate's number and is not folded into it.** It is the
cost of `Transaction.insert` — one `queryInsertAt` plus one `insertLocalOp` per
element, re-querying and re-splicing the growing op set each time — for
**50 000 inserts at ascending positions in one transaction and one commit**. A
consumer that appends to a list element at a time pays exactly that, and
`Transactable::splice` is the upstream answer to it
(`transactable.rs:78-84`: *"nested objects are created using batch insertion
for efficiency"*). It is a **finding about `src/transact.zig`**, it belongs to
the port and not to the benchmark, and it is tracked and measured separately.
The workload keeps the loop alive in one place only — the 64-element
agreement check above — so the finding stays reproducible without this gate
paying for it 50 000 times per sample.

**Timed region.** `ns` is the `read-list` phase: `list_width_passes` complete
walks. `build-list`, `verify` and `teardown` are phases and are in the guard's
denominator.

**The assertions**:

* every element reports `index == seen`, in order;
* every element's `width` is exactly 1 — `Op.width` answers `1` for every list
  element under every encoding (`src/opset/op.zig:2178-2181`) — so a width
  read that reached the wrong row, or that took the register's *first* row
  instead of its last, shows up as a wrong number rather than a right one;
* every element's value is the integer written at that position, and nothing
  conflicts;
* the walk yields exactly `n` elements, and `am.read.length` — a prefix count,
  and nothing to do with `elementWidth` — independently says `n`;
* the sibling text object reads back as `enc.width(sample)` characters and as
  its own bytes, which is what proves the document really is under the
  encoding asked for rather than under whichever one it defaulted to;
* and the two fixture builders agree element for element, as above.

**Checksum.** each element's `index` and `width`, the per-walk count, `n`, and
the agreement check's element count. Observed `e41686857f8055e0` on three
consecutive ReleaseFast runs of the default size.

**Sizes.** Unchanged from what they were, and that is the point: **50 000
elements and 2 walks by default**. Nothing had to shrink for the fixture to
become cheap, because the fixture was never the right thing to shrink — it was
the wrong *way* to build the list. `--full` is 200 000 elements and **1** walk
(`Sizes.full`), down from 4: the walk is quadratic in the element count, which
is the finding this gate exists for, so one pass over 200 000 is already about
128 s and a second buys no second point for another 128 s. `--full` is the
larger *size*, not the larger sample count.

**Runtime.** Order 9 s at the default size, and **98.5% of it is the subject** —
against a reported 1027 s before, of which 98% was the fixture.

### `insert-loop`

**The cost under test** is `Transaction.insert`
(`src/transact.zig:975`), driven the way a consumer that appends to a list one
element at a time drives it. **This is the shape that measured about 1011 s.**
50 000 `tx.insert(list, i, …)` calls at ascending positions inside **one**
transaction, committed **once**, cost **~1011 s of wall clock and roughly
4.69e12 instructions** — the `list-width` fixture this file used to carry. Two
O(rows)-per-insert stages sat on this path: `OpSet.queryInsertAtSlow`'s
whole-object cross-check, now behind `check_slow_paths`
(`src/opset/op_set.zig:4346`), and `Column.rebuildAggs`, now narrowed to the
range the splice touched (`src/hexane/column.zig:6946`, reached from
`Column.splice`'s settled arm at `src/hexane/column.zig:4322`).

**Why this gate exists at all: the cost was found by accident, by a gate
measuring its own fixture.** `list-width`'s first version built its 50 000
elements with exactly this loop, and `perf stat` reported **98% of the
instruction count as the fixture** — 4.69e12 instructions where the `BENCH`
line carried a 16.1 s subject. The fixture was deleted (it is one batched
splice now, `bench/zautomerge_bench.zig:1895-1903`), because a gate that
reports its own fixture's cost is not a gate. **The number went with it.** The
largest cost this repository ever recorded for a write path then survived only
as a comment about a *different* workload, and nothing measured the path it
named. This workload is that measurement, and it differs from `list-width` in
the way that matters: **here the cost is the subject**, so there is no fixture
for it to be confused with, and the read-back that keeps it honest is reported
as a phase rather than mistaken for the measurement.

**The public chain**, all of it reachable from `@import("zautomerge")`:

```
am.manual_transaction.Transaction.open          src/transact.zig:480
am.manual_transaction.Transaction.putObject      src/transact.zig:954
am.manual_transaction.Transaction.insert         src/transact.zig:975
  → Transaction.doInsert                         src/transact.zig:866
    → OpSet.queryInsertAt                        src/opset/op_set.zig:4295
      → OpSet.queryInsertAtSlow                  src/opset/op_set.zig:4379
        (behind check_slow_paths, :4346 — the dominant of the two stages)
    → Transaction.insertLocalOp                  src/transact.zig:632
      → OpSet.splice → Column.splice → Column.rebuildAggs
                                               src/hexane/column.zig:6946
am.manual_transaction.commitWith                 src/transaction.zig:553
```

**The shape.** `n` inserts at **ascending** positions into one list inside
**one** transaction and **one** commit. Ascending is the shape that was
measured; `list-width`'s note (`bench/zautomerge_bench.zig:1700-1703`) says why
"append at the end instead" is not a different shape at all, because at step
`i` the list holds `i` elements, so `i` *is* the last index. One transaction
and one commit, so the change graph holds **one** change and the cost under
test is the per-insert write path and not the graph.

**Two sizes in one run, and why that is the point.** The workload builds the
shape twice — at `insert_small` and at `insert_large` — and prints the
**per-insert nanoseconds at both**. The ratio between them is the measurement,
because both numbers move with the host and the ratio does not:

* a per-insert cost **flat in `n`** reads about **1.00**, and that is the
  finding;
* a per-insert cost that **grows with `n`** — which is what an
  O(rows)-per-insert stage is — reads about **4.00**, the size ratio.

One run therefore answers "is it flat?" without two runs and without two whole
processes. `insert_loop_size_ratio` is fixed at 4 and checked at run time
(`error.SizesAreNotAtTheDocumentedRatio`), because a growth guard is a
statement about a *known* size ratio.

**The guard.** `insert_loop_growth_ceiling` is **2.0**, and a run past it
**fails** with `error.InsertCostStillGrowsWithTheDocument`, prints no `BENCH`
line, and exits 1 — the same refusal `list-width` makes when its fixture
outweighs its subject. Two sits between 1.00 and 4.00 with room for the wall
clock's few percent on a busy host and for the fixed cost of opening a
transaction and committing, which is a larger share of the small arm's total
and so pulls the measured ratio *below* its true value. **The small arm runs
first**, so the arm that inherits the warm allocator is the large one and the
ratio is biased downward — the direction that cannot turn a regression into a
pass.

**Timed region.** `ns` is the **large arm's** `insert-large` phase:
`Transaction.open` through the `commitWith` that returns, and nothing else.
`iters` is that arm's insert count, so `BENCH insert-loop 10000 … ` carries
**nanoseconds per single-row insert** — the figure directly comparable with
the old fixture's 1011 s / 50 000 = **20.2 ms per insert**. The small arm, the
save/reload/read-back and the teardown are phases.

**The assertions**, all of which fail a change that got cheaper by being wrong:

* every `insert` returned its **own operation, in order** — `insert` answers
  `WriteError!OpId` (`src/transact.zig:975`), so there is no null to confuse
  with a repeated write, and the counters are contiguous because `nextId` is
  `start_op + pending.len` (`src/transact.zig:515-518`). A loop that stopped
  early, skipped an element or reordered two inserts fails here;
* `Transaction.count()` said **exactly `n + 1`** staged operations before the
  commit — the list's own make plus one per insert — so nothing was collapsed;
* **`commitWith` returned a hash.** A null is `Transaction.commit`'s answer
  for a transaction with nothing pending (`src/transact.zig:1418-1421`), so a
  null would be the port refusing to write what it was asked to;
* **the transaction's final state**, asked through all three doors that can see
  it: `tx.closed` is set, `Transaction.count()` is drained, and
  `am.manual_transaction.maxOp` answers `error.InvalidOp`, the refusal a closed
  transaction gives (`src/transaction.zig:379-380`);
* **the committed change count is what the shape implies**: one transaction and
  one commit is exactly one change, so `doc.graph.len() == 1` — on the live
  document and again on the reloaded one. `doc.graph` is a public field
  (`src/doc.zig:2616`);
* **the saved document round-trips.** `doc.save` then `Document.load`
  (`src/doc.zig:3801`), under the encoding `am.read.textEncoding` reports
  rather than one assumed, and the **reloaded** document is the one that gets
  read: the list is found by **key**, not by reusing the id the transaction
  handed out, so a document that encoded the list but lost the register naming
  it fails;
* **the list reads back with `n` elements at indices `0..n-1`**, each carrying
  the integer it was given, each with `width == 1` (every list element is one
  unit wide under every encoding, `src/opset/op.zig:2178-2181`), none
  conflicting, and none an object;
* **`am.read.length` says `n`** on the live document *and* on the reloaded one,
  and it is a prefix count with nothing to do with the walk above, so the two
  agreeing is a second and separate statement.

**Checksum.** each element's `index` and `width` as it walks back, the element
count, the change count, and the committed change hash — which is deterministic
because the actor is a fixed literal and `CommitOptions.none` leaves the commit
time at **zero, not "now"** (`src/transaction.zig:178-180`), so it is the same
on every run and belongs in a before/after comparison.

**Sizes.** **2 500 and 10 000 inserts by default** — a 4× ratio, one
transaction and one commit each. The quadratic is still unmistakable there
because the **ratio** carries it, not the absolute time: an O(rows)-per-insert
stage reads 4.00 on this pair, and the historical 1011 s at 50 000 is what sets
the ceiling on the *regressed* cost, which is 4.0e-7 · n² seconds — about
**28 s** for this pair, a loud alarm that still terminates rather than the
1011 s the same shape used to cost. The healthy cost is the tens of
milliseconds the two arms' own `insert-small`/`insert-large` phases report.
`--full` is **5 000 and 20 000**, the same 4× ratio so the guard means the same
thing; a regressed `--full` run is correspondingly longer, which is the point
of asking for `--full`.

**Runtime.** The healthy path is dominated by the read-back, not the insert
loop: `verify` is a `listRange` walk over `insert_small + insert_large`
elements, and `list-width` measures that walk at tens of microseconds per
element (`src/iter/list_range.zig:884-901`). **That is why this workload's
`perf stat` line is not a subject measurement** — unlike `list-width`, whose
subject is 98.5% of its process, here the correctness read-back dominates the
process and the insert loop is the small share of it. Quote the
`insert-large` phase and the growth ratio, not the whole-process instruction
count. The ratio is immune to this, because it is computed from the two timed
subject regions alone.

### Running them

`zig build bench -Doptimize=ReleaseFast` runs **all eleven** — it has to,
because the step forwards nothing and `zig build` installs no binary
(measured: `zig build bench -- --list` ran the whole gate). One workload per
process is what makes `perf stat`'s count belong to one workload, so build the
executable once and call it directly:

```
source ~/.local/lib/host-scratch.sh
mkdir -p "$buildhost_SCRATCH_ROOT/bench"
printf 'pub const check_slow_paths = false;\n' \
    > "$buildhost_SCRATCH_ROOT/bench/build_options.zig"

# -O ReleaseFast goes BEFORE the first -M: after it the flag is read as a
# per-module option and the binary comes out Debug.
zig build-exe \
    -O ReleaseFast \
    --dep zautomerge \
    -Mroot=bench/zautomerge_bench.zig \
    --dep build_options \
    -Mzautomerge=src/root.zig \
    -Mbuild_options="$buildhost_SCRATCH_ROOT/bench/build_options.zig" \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    -femit-bin="$buildhost_SCRATCH_ROOT/bench/zautomerge-bench"
```

Run it from the repository root: `-Mzautomerge=src/root.zig` is relative.
Check the mode on the first line of stderr — `zautomerge_bench: optimize=…` —
before quoting anything. Then:

```
perf stat -e instructions "$buildhost_SCRATCH_ROOT/bench/zautomerge-bench" sync-roundtrip
perf stat -e instructions "$buildhost_SCRATCH_ROOT/bench/zautomerge-bench" hash-for-opid
perf stat -e instructions "$buildhost_SCRATCH_ROOT/bench/zautomerge-bench" list-width
perf stat -e instructions "$buildhost_SCRATCH_ROOT/bench/zautomerge-bench" insert-loop

"$buildhost_SCRATCH_ROOT/bench/zautomerge-bench" --repeat 5 sync-roundtrip hash-for-opid list-width insert-loop
"$buildhost_SCRATCH_ROOT/bench/zautomerge-bench" --full  sync-roundtrip hash-for-opid list-width insert-loop
```

Observed at the default `list-width` size on this host, load average ~120:
**48 373 660 081 instructions over 9.8 s**, of which the workload reports
**98.5%** as its subject. The `zig build`-produced binary of the same source
measured 48 373 662 082 — the same build, so either executable is a valid
subject for a before/after pair as long as it is the same one throughout.

For attribution, with a scratch file outside `/tmp`:

```
perf record -F 999 -g --call-graph dwarf \
    -o "$buildhost_SCRATCH_ROOT/bench-sync.data" \
    "$buildhost_SCRATCH_ROOT/bench/zautomerge-bench" sync-roundtrip
perf report -i "$buildhost_SCRATCH_ROOT/bench-sync.data" --stdio
```

---

## 8. `anonymize-rss`: the arena gate, on peak resident bytes

The fourth audit finding was that `Anonymize`'s per-change arena never resets,
so its cost grows with the document. **That no longer holds in this tree**:
`Anonymize.run` resets `self.arena` at the end of every change
(`src/anonymize.zig:440`), with the reasoning at `:395-439`. What is missing is
not the reset but **a gate that would notice it going away** — and that gate
is peak RSS, not instructions, which is why it is not a `zautomerge_bench`
workload at all. `bench/anonymize_rss.zig` is a separate small executable that
builds a document, calls `am.anonymize.anonymize`, and gets out of the way so
`time -v` can read its peak.

**Why the gate is a ratio.** The reset is per change, so what it bounds is the
arena, and the arena is small next to the source document. A regression that
dropped or moved `src/anonymize.zig:440` would make peak RSS roughly
**double** — once for the source document, once for the arena's copy of all of
it — but the absolute number depends on the document, so only the *shape* of
the answer is stable. Build the same shape at two change counts and compare:
four times the changes must not much move the peak. That is why the change
count is an argument.

### Building it

The library needs a `build_options` module (`src/hexane/btree.zig:40`,
`src/opset/op_set.zig:155`) and the `bench` build step is not wired for this
file, so build it directly and write the one-line stub **outside the repo**:

```
source ~/.local/lib/host-scratch.sh
mkdir -p "$buildhost_SCRATCH_ROOT/bench-rss"
printf 'pub const check_slow_paths = false;\n' \
    > "$buildhost_SCRATCH_ROOT/bench-rss/build_options.zig"

zig build-exe \
    -O ReleaseFast \
    --dep zautomerge \
    -Mroot=bench/anonymize_rss.zig \
    --dep build_options \
    -Mzautomerge=src/root.zig \
    -Mbuild_options="$buildhost_SCRATCH_ROOT/bench-rss/build_options.zig" \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    -femit-bin="$buildhost_SCRATCH_ROOT/bench-rss/anonymize-rss"
```

Run it from the repository root: `-Mzautomerge=src/root.zig` is relative.
`--cache-dir` and `--global-cache-dir` keep every cache byte out of the repo
and off NFS.

**`-O ReleaseFast` goes before the first `-M`, and this line used to have it
after them.** The build runner reads a flag placed after a module's arguments
as belonging to that module, so the whole binary came out `Debug` — measured:
the same source line with the flag moved builds `ReleaseFast` and reaches the
same instruction count to within 2000 instructions, while the misplaced one
took **19× longer** for the same `list-width` workload (179 s against 9.8 s).
A benchmark built Debug measures Debug, and its peak-RSS sibling measures
Debug's allocator traffic.

### Running the gate

Same shape, two sizes, `--ops` held fixed:

```
time -v "$buildhost_SCRATCH_ROOT/bench-rss/anonymize-rss" --changes 2000 --ops 20 \
    2>&1 | grep -E 'Maximum resident set size|# ANONYMIZE_RSS'

time -v "$buildhost_SCRATCH_ROOT/bench-rss/anonymize-rss" --changes 8000 --ops 20 \
    2>&1 | grep -E 'Maximum resident set size|# ANONYMIZE_RSS'
```

**Four times the changes should not move the peak much.** The document itself
grows, so some movement is correct; what a dropped reset adds is a second copy
of it, which is roughly a factor of two on top. Record both peaks with this
host's load average next to them — RSS is a page count and moves far less than
wall clock, but it is not immune to a machine under pressure.

**Do not pass `--check`.** It runs `am.anonymize.checkPrivateDataChanged`, the
port's own thorough oracle, which re-encodes both documents' changes and
therefore **dominates peak RSS** — the run would measure the checker. Use it
once, on a small `--changes`, to confirm the rewrite is right:

```
"$buildhost_SCRATCH_ROOT/bench-rss/anonymize-rss" --changes 200 --ops 5 --check
```

### What it asserts without `--check`

Only checks that do not allocate in proportion to the document, because a
program measuring peak RSS must not set the peak itself:

* `am.read.length` on the root map — a prefix count — says the source has
  exactly `changes * ops` registers and the anonymized document has the same
  number;
* the register at key `k0-0` held `v0-0` before and holds neither that nor the
  source's bytes after.

It also prints `# ANONYMIZE_RSS changes=… ops=… ns=…` so the marker can be
paired with the `Maximum resident set size` line beside it.

---

## 9. Visibility: what would have been refused

**All four gates were buildable through the public surface, and none needed a
workaround.** That is a result about the port, not about the benchmark, so it
is worth being exact about where the line was:

* `elementWidth` (`src/iter/list_range.zig:923`), `OpSet.queryInsertAtSlow`
  (`src/opset/op_set.zig:4379`) and `Column.rebuildAggs`
  (`src/hexane/column.zig:6946`) are **private functions**. None is called.
  They are reached through `ListRange.next`, `Transaction.insert` and
  `OpSet.splice`, which are public, and the benchmark says so by naming the
  whole chain in each case.
* **Superseded in round 5.** This bullet used to name "the sync insert loop
  (`src/sync/protocol.zig:572`)" beside them and to call all four private. The
  call site is now `State.extendSent` (`src/sync/state.zig:396`), a **`pub`
  method** reached through the public `generateSyncMessage`
  (`src/sync/protocol.zig:433`), so "all private" no longer covers the sync
  side. Nothing about the benchmark changed: it still reads `State.sent_hashes`
  through the public field below and never reaches into `src/sync/**`.
* The one field the checks read is `State.sent_hashes`
  (`src/sync/state.zig:156`), which **is a public field**. Had it been
  private, `sync-roundtrip` would have been reduced to counting payloads it
  cannot see the shape of, or refused: a benchmark that reached into
  `src/sync/**` for it would be measuring the harness rather than the port.
* `ChangeGraph.opidToHash` (`src/change_graph.zig:1704`) **is `pub`**, and has
  been since that file was written; round 5 added no door, it used the one that
  was already there — `Transaction.hashForOpid` (`src/transaction.zig:433-436`)
  now delegates to it. This bullet used to say the function "has **no public
  entry point at all**" and that comparing against upstream "needs a new `pub`
  in `src/change_graph.zig`". That was wrong when written: the declaration is
  the port of `change_graph.rs:300-318`, and it is already called from
  `src/change_graph.zig:3279` and — from a test — `src/change.zig:1142-1146`.
  So `hash-for-opid` measures the shape upstream measures, through the public
  surface, with nothing added to reach it.
* `OpSet.queryInsertAt`'s fast/slow cross-check is **behind a build option**
  (`check_slow_paths`, `src/opset/op_set.zig:4346`), so a `-Dslow-path` build of
  the library turns the walk back on by construction. `insert-loop` is built
  with `check_slow_paths = false` like every other `BENCH` workload (§7's
  `build-exe` line), which is the point of quoting the option's name here: a
  reader who wants to see the regressed number can flip one line of the stub and
  run the same workload.
* **It is one of five, and round 5 found the last ungated one.** The cross-check
  at `OpSet.seekListOpid` (`src/opset/op_set.zig:3953`) ran on every cursor
  resolve before that gate existed. Its slow arm is `iterObjAndFind` plus a
  `Grouped` walk over **every** register in the object, so an always-on
  comparison is `O(rows in the object)`; its hot callers are
  `Transaction.joinBlock`, `OpSet.parentObject`'s `.seq` arm (`Parents.next`
  and `read.parents`) and `PatchBuilder.getPath` through `doc.objectParent`.
  Upstream spells that comparison a plain `debug_assert_eq!` (`op_set.rs:846`)
  with no `#[cfg(feature = "slow_path_assertions")]`, so upstream pays nothing
  only because its release profile leaves `debug-assertions` off
  (`rust/Cargo.toml:14-16`). Of the five now gated, three are what upstream
  gates behind that feature — `seekOpsByIndex` (`op_set.rs:645-649`),
  `calculateMarksAt` (`automerge.rs:1587-1591`) and `markSetAtIndex`
  (`automerge.rs:1939-1943`) — and two are the plain `debug_assert_eq!`s,
  `seekListOpid` (`op_set.rs:846`) and `queryInsertAt` (`op_set.rs:583-598`).
  The **only** cross-check still ungated is `OpSet.findOpByIdAndVis`, and it is
  cheap because its slow arm stops at the end of the row's own register
  (`op_set.rs:1131-1132`).
* `anonymize`'s arena (`Anonymize.arena`) is a private field. Nothing needed
  to read it: peak RSS is an observable of the process, not of a struct, which
  is exactly why that one gate is not a `BENCH` workload.