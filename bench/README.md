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

`build.zig` does not know about this file yet. The orchestrator adds this, next
to the other `addExecutable` step (`build.zig:777` is the model — it is the
only existing executable that imports the library by name):

```zig
    // The end-to-end benchmark. Its own module, `zautomerge` imported by name,
    // for the same reason every other step does: nothing in it may reach into a
    // private, so the file can only use the surface a consumer gets. **Reuses
    // `mod`**, so the library's `build_options` module (and therefore the
    // `check_slow_paths` gate `-Dslow-path` sets) is the same one the tests see.
    //
    // `link_libc` stays off, as it does for every step except `example` and the
    // C ABI's own: nothing here reaches for a C symbol, and `src/c/**` is only
    // analyzed if something references `am.c_abi`.
    const bench_bin = b.addExecutable(.{
        .name = "zautomerge-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/zautomerge_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zautomerge", .module = mod }},
        }),
    });

    const bench_step = b.step("bench", "Run the end-to-end benchmark");
    const run_bench = b.addRunArtifact(bench_bin);
    // The measurements go to stdout and the narration to stderr, and both have
    // to reach the operator as they are printed rather than through a pipe the
    // build runner keeps for a failure report.
    run_bench.has_side_effects = true;
    run_bench.step.dependOn(&bench_step.step);
```

`target` and `optimize` are the existing `b.standardTargetOptions(.{})` and
`b.standardOptimizeOption(.{})` locals at the top of `build.zig`. **Do not pass
`.optimize` explicitly** — the whole point is that `-Doptimize=ReleaseFast` on
the command line reaches this step like it reaches every other one.

The exact import name is **`zautomerge`**, the same name `b.addModule`
publishes it under at `build.zig:8` and that `test/example_test.zig:20` and
`test/save_interop.zig:33` use.

### Building and running it

```
zig build bench -Doptimize=ReleaseFast                       # every workload, reduced sizes
zig build bench -Doptimize=ReleaseFast -- segmentation       # one workload
zig build bench -Doptimize=ReleaseFast -- --repeat 5         # five samples, median reported
zig build bench -Doptimize=ReleaseFast -- --full             # the test cases' exact sizes
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

For attribution:

```
perf record -F 999 -g --call-graph dwarf \
    -o /tmp/seg.data ./zig-out/bin/zautomerge-bench segmentation
perf report -i /tmp/seg.data --stdio
```

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

Seven workloads, one per expensive case. The table says exactly what is
different from the test case, and why the reduced shape measures the same thing.

| workload | test case | default | test | reduced? |
|---|---|---|---|---|
| `segmentation` | `src/textdiff.zig:1679` | 50-record body, 1024 single passes | 500-record body | **10× smaller** |
| `indexed-delta` | `src/hexane/column.zig:15125` | 20 trials × 400 splices | 200 trials × 400 | **10× fewer trials** |
| `slab-merge` | `src/hexane/hexane_test.zig:474` | 20 trials × 500 ops | 200 trials × 500 | **10× fewer trials** |
| `prefix-bool` | `src/opset/columns.zig:3700` | 20 trials × 300 ops | 200 trials × 300 | **10× fewer trials** |
| `update-object` | `test/upstream_doc_test.zig:1403` | depth 42 | depth 42 | **no** |
| `mark-index` | `src/opset/mark_index.zig:2459` | 40 000 rows, 1000 marks | 100 000 rows, 2500 marks | **2.5× smaller** |
| `mark-at-end` | `src/read.zig:6537` | 210 000 chars, 1 encoding | 210 000 chars, 4 encodings | **4× fewer encodings** |

`--full` restores every "test" column above.

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

---

## 6. Verifying a run

1. `zig build bench -Doptimize=ReleaseFast` and check every `BENCH` line is
   preceded by `#   the timed region is the workload's own` **only** for
   `update-object`; every other workload times its whole iteration.
2. Check stderr ends with `# LEAKS 0`. A nonzero count is a bug in the
   benchmark, not in the port.
3. Compare `#   checksum` before and after. **The checksums must be identical
   across a before/after pair.** If they are not, the optimization changed
   behaviour and the timings mean nothing.
4. Compare `BENCH` lines with `diff`, and instruction counts with `perf stat`.