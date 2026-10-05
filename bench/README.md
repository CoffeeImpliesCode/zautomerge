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
zig build bench -Doptimize=ReleaseFast -- segmentation       # one workload
zig build bench -Doptimize=ReleaseFast -- --repeat 5         # five samples, median reported
zig build bench -Doptimize=ReleaseFast -- --full             # the cases' exact sizes, §7's larger
```

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
perf stat -e instructions ./zig-out/bin/zautomerge-bench segmentation
```

Run **one workload per process** and `perf stat`'s instruction count belongs to
that workload alone. Quote instruction counts, not wall clock. When you do quote
wall clock, quote the load average next to it.

All ten workload names are what `--list` prints. §7 gives the per-workload
`perf stat` lines for the three that are here because a specific cost had no
gate, rather than because a test case was slow.

For attribution:

```
perf record -F 999 -g --call-graph dwarf \
    -o /tmp/seg.data ./zig-out/bin/zautomerge-bench segmentation
perf report -i /tmp/seg.data --stdio
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

Seven workloads, one per expensive case, and three more that have no case
behind them at all. The table below is the first seven: it says exactly what
is different from the test case, and why the reduced shape measures the same
thing. §7 is the other three.

| workload | test case | default | test | reduced? |
|---|---|---|---|---|
| `segmentation` | `src/textdiff.zig:1679` | 50-record body, 1024 single passes | 500-record body | **10× smaller** |
| `indexed-delta` | `src/hexane/column.zig:15125` | 20 trials × 400 splices | 200 trials × 400 | **10× fewer trials** |
| `slab-merge` | `src/hexane/hexane_test.zig:474` | 20 trials × 500 ops | 200 trials × 500 | **10× fewer trials** |
| `prefix-bool` | `src/opset/columns.zig:3700` | 20 trials × 300 ops | 200 trials × 300 | **10× fewer trials** |
| `update-object` | `test/upstream_doc_test.zig:1403` | depth 42 | depth 42 | **no** |
| `mark-index` | `src/opset/mark_index.zig:2459` | 40 000 rows, 1000 marks | 100 000 rows, 2500 marks | **2.5× smaller** |
| `mark-at-end` | `src/read.zig:6537` | 210 000 chars, 1 encoding | 210 000 chars, 4 encodings | **4× fewer encodings** |

`--full` restores every "test" column above, and gives the three of §7 their
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

The three of §7 have no case to copy, so their assertions were written for the
same purpose and are named there: an ascending duplicate-free `sent_hashes`,
`element.width == 1` for every list element, and a `hashForOpid` answer that
equals the commit that wrote the operation.

---

## 6. Verifying a run

1. `zig build bench -Doptimize=ReleaseFast` and check which `#   the timed
   region is the workload's own` lines appear. **Four** workloads time a
   region rather than a whole iteration — `update-object`, `sync-roundtrip`,
   `hash-for-opid` and `list-width` — and for each of those the phases on
   stderr say how the untimed part was spent. Every other workload times its
   whole iteration.
2. Check stderr ends with `# LEAKS 0`. A nonzero count is a bug in the
   benchmark, not in the port.
3. Compare `#   checksum` before and after. **The checksums must be identical
   across a before/after pair.** If they are not, the optimization changed
   behaviour and the timings mean nothing.
4. Compare `BENCH` lines with `diff`, and instruction counts with `perf stat`.

---

## 7. The three gates that had no case

A data-oriented audit of the port named three costs the suite exercises but
never isolates, and therefore three that no change could be honestly accepted
or rejected against. Each is a workload here, reached **through the public
module surface only**: nothing in the three imports a private, and where a
check needed a field the port would otherwise have to expose for the
benchmark's benefit, the field was already public and is cited.

| workload | subject | default | `--full` |
|---|---|---|---|
| `sync-roundtrip` | the sorted insert into `sent_hashes` | 24 rounds × 200 changes | 48 rounds × 400 changes |
| `hash-for-opid` | `hashForOpid`'s linear scan | 20 000 changes, 400 calls | 50 000 changes, 1000 calls |
| `list-width` | `elementWidth`'s five cursors per element | 50 000 elements, 2 walks | 200 000 elements, 4 walks |

`--full` for these three is **not** "the test case's exact size" — there is no
test case. It is a larger size of the same shape, so that a before/after pair
has a second point on the curve rather than one.

### `sync-roundtrip`

**The line under test** is `src/sync/protocol.zig:572`,
`for (builder.payloadHashes()) |hash| try state.insertSent(hash);`, which is
`State.insertSent` at `src/sync/state.zig:368-382`: a binary search over an
ascending list, then an `ArrayList.insert` memmove, **once per hash per
generated message**. The list only grows on this path (`clearSent`,
`src/sync/state.zig:385-387`, is the only thing that empties it), so the
memmove arm is quadratic in the changes a peer has been sent in one session.

**The public chain**, driven as `test/upstream_doc_test.zig:4955-4969` drives
it: `am.sync.state.State.new` (`src/sync/state.zig:181`) →
`am.sync.protocol.generateSyncMessage` (`src/sync/protocol.zig:430`) →
`am.sync.protocol.receiveSyncMessage` (`src/sync/protocol.zig:658`). The set
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
payload while `State.their()` is null (`src/sync/protocol.zig:962`).

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

**The line under test** is `src/transaction.zig:411-423`: `hashForOpid` walks
the change graph's node table from row zero, where upstream binary-searches the
actor's own change list (`ChangeGraph::opidToHash`). The question is the `C`
in that O(C), and a document with few changes answers in constant time
whatever the algorithm — so the fixture is a document with many.

**The public chain**, reached the way `src/transaction.zig:1446-1472` reaches
it: a `.manual` document, `am.manual_transaction.Transaction.open`
(`src/transact.zig:480`), `am.manual_transaction.commitWith`
(`src/transaction.zig:553`), and `am.manual_transaction.hashForOpid`
(`src/transaction.zig:411`) — the module `src/root.zig:119` re-exports.
`doc.ops.idToExid` (`src/opset/op_set.zig:3240`) turns the operation ids the
writes returned into `ExId`s.

**The shape.** `opid_changes` committed changes, one map put each — the
cheapest shape a change can have, deliberately: the cost under test is one
pass over the node table, so every extra operation in the graph would be
fixture work the real question does not do.

**Timed region.** `ns` is the `scan-last-op` phase only: `opid_calls` calls
for the **last** operation, whose node is the last in the table. The
`scan-first-op` phase is the same call for the **first** operation, which node
zero answers immediately, and the ratio between the two phases *is* the
finding. `build-graph` is the fixture.

**The assertions**: every call returns the change hash the commit returned;
the root names nothing; an `ExId` past the graph's counters names nothing; and
the last operation's hash is still there after both scans.

**Checksum.** the graph length, then the first eight bytes of every returned
hash, big-endian, through `Result.mix`.

**Runtime.** Order 0.5–2 s at the default size, most of it the fixture. The
`scan-last-op` phase alone is tens of milliseconds, which is why the count is
400 and not 4.

### `list-width`

**The line under test** is `src/iter/list_range.zig:884-901`, `elementWidth`,
which calls `OpSet.elemidAt` (`src/opset/op_set.zig:3500-3503`) and so builds
the five column cursors of `OpSet.elemCursor` (`src/opset/op_set.zig:3524`) —
then, because a fresh cursor is never `placed`
(`src/opset/op_set.zig:5670`), has `ElemWalk.seek` (`:5738`) build all five
**again**. Two of the five are delta columns, and `iterRange` folds their wire
to reach the row asked for (`src/opset/op_set.zig:3488-3492`).

**The exact public chain**, which is the answer to "which call does this
measure":

```
am.read.listRange(doc, list, am.read.IndexRange.all())   src/read.zig:2280
  → ListRange.next()                                     src/iter/list_range.zig:984
    → ListDiffItem.exportItem(set, rows)                 src/iter/list_range.zig:603
      → elementWidth(set, pos, rows.end)                 src/iter/list_range.zig:884
        → OpSet.elemidAt(pos, end)                       src/opset/op_set.zig:3500
          → OpSet.elemCursor()   five cursors            src/opset/op_set.zig:3524
          → ElemWalk.at()                                src/opset/op_set.zig:5707
            → ElemWalk.seek()   five cursors again       src/opset/op_set.zig:5738
```

`mark-at-end` walks a **text** through the same `ListRange`; this one walks a
**list**, which is the object `elementWidth` is written for and the shape the
audit named.

**The shape.** A `.manual` document under the `.unicode_code_point` encoding
holding one list of `list_width_elements` integers, built by **one**
transaction and **one** commit. One change, not one per element: a committed
change per element would put that many changes in the change graph and measure
that too. `mark-at-end` splices 210 000 characters through a single
`spliceText`, so a single change this size is already well inside what the
port does.

**Timed region.** `ns` is the `read-list` phase — `list_width_passes` complete
walks. `build-list` is the fixture.

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
* and the sibling text object reads back as `enc.width(sample)` characters and
  as its own bytes, which is what proves the document really is under the
  encoding asked for rather than under whichever one it defaulted to.

**Checksum.** each element's `index` and `width`, the per-walk count, and `n`.

**Runtime.** Order 0.5–2 s at the default size, most of it the fixture. The
default walk is two passes over 50 000 elements, which is why `passes` is 2:
one pass is close to the clock's floor, the same reason `seg_single_passes`
exists.

### Running them

One workload per process, because that is what makes `perf stat`'s count
belong to one workload:

```
zig build bench -Doptimize=ReleaseFast

perf stat -e instructions ./zig-out/bin/zautomerge-bench sync-roundtrip
perf stat -e instructions ./zig-out/bin/zautomerge-bench hash-for-opid
perf stat -e instructions ./zig-out/bin/zautomerge-bench list-width

zig build bench -Doptimize=ReleaseFast -- --repeat 5 sync-roundtrip hash-for-opid list-width
zig build bench -Doptimize=ReleaseFast -- --full  sync-roundtrip hash-for-opid list-width
```

For attribution on the first of them, with a scratch file outside `/tmp`:

```
perf record -F 999 -g --call-graph dwarf \
    -o "$buildhost_SCRATCH_ROOT/bench-sync.data" ./zig-out/bin/zautomerge-bench sync-roundtrip
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
    --dep zautomerge \
    -Mroot=bench/anonymize_rss.zig \
    --dep build_options \
    -Mzautomerge=src/root.zig \
    -Mbuild_options="$buildhost_SCRATCH_ROOT/bench-rss/build_options.zig" \
    -O ReleaseFast \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    -femit-bin="$buildhost_SCRATCH_ROOT/bench-rss/anonymize-rss"
```

Run it from the repository root: `-Mzautomerge=src/root.zig` is relative.
`--cache-dir` and `--global-cache-dir` keep every cache byte out of the repo
and off NFS.

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

**All three gates were buildable through the public surface, and none needed a
workaround.** That is a result about the port, not about the benchmark, so it
is worth being exact about where the line was:

* `elementWidth` (`src/iter/list_range.zig:884`) and the insert loop
  (`src/sync/protocol.zig:572`) are **private functions**. Neither is called.
  They are reached through `ListRange.next` and `generateSyncMessage`, which
  are public, and the benchmark says so by naming the whole chain.
* The one field the checks read is `State.sent_hashes`
  (`src/sync/state.zig:156`), which **is a public field**. Had it been
  private, `sync-roundtrip` would have been reduced to counting payloads it
  cannot see the shape of, or refused: a benchmark that reached into
  `src/sync/**` for it would be measuring the harness rather than the port.
* `ChangeGraph.opidToHash` — upstream's O(log C) answer, the thing the audit
  compares `hashForOpid` against — has **no public entry point at all**. The
  only public door is `am.manual_transaction.hashForOpid`, which is the port's
  own linear scan. So `hash-for-opid` measures the port, and comparing it
  against upstream needs a new `pub` in `src/change_graph.zig`, not a
  benchmark that reaches further.
* `anonymize`'s arena (`Anonymize.arena`) is a private field. Nothing needed
  to read it: peak RSS is an observable of the process, not of a struct, which
  is exactly why that one gate is not a `BENCH` workload.