# `zautomerge` benchmarks

The benchmark executables use `@import("zautomerge")` and the public API.
They do not import private source files.

- `bench/zautomerge_bench.zig` provides eleven native workloads and their existing correctness and growth guards.
- `bench/matched_bench.zig` and the Rust `matched_bench` binary compare one workload and size per fresh process.
- `bench/anonymize_rss.zig` measures a separate peak-RSS workload.

Sections 1–9 describe the native workload driver.
Section 10 records a frozen historical optimization round.
Section 11 gives the matched Rust contract, frozen baseline, and current optimization-loop checkpoint.
Section 12 records frozen native-only guard and profile evidence.
Historical numbers below do not measure the new optimization candidate.

---

## 1. Building it

`zig build bench` builds and runs all eleven native workloads.
It does not forward arguments after `--` and does not install the workload executable.
Use the direct build recipe in section 7 for one workload per process.
The benchmark imports the published `zautomerge` module and shares its `build_options`.
`-Dslow-path` enables the same slow-path checks as the test builds.

### Local scratch and caches

Run the commands from the repository root.
Use an approved local scratch directory with sufficient free space.
On this host, the helper selects that directory.
On other hosts, set `HOST_SCRATCH_ROOT` to an approved local directory before these commands.

```sh
if [ -f "$HOME/.local/lib/host-scratch.sh" ]; then
    . "$HOME/.local/lib/host-scratch.sh" || exit 1
fi
: "${HOST_SCRATCH_ROOT:?Set HOST_SCRATCH_ROOT to approved local scratch storage}"
export TMPDIR="$HOST_SCRATCH_ROOT/tmp"
export TMP="$TMPDIR" TEMP="$TMPDIR"
export XDG_CACHE_HOME="$HOST_SCRATCH_ROOT/cache"
export ZIG_LOCAL_CACHE_DIR="$XDG_CACHE_HOME/zig-local"
export ZIG_GLOBAL_CACHE_DIR="$XDG_CACHE_HOME/zig"
export CARGO_HOME="$XDG_CACHE_HOME/cargo"
export CARGO_TARGET_DIR="$HOST_SCRATCH_ROOT/scratch/cargo-target"
export BENCH_ROOT="$HOST_SCRATCH_ROOT/scratch/zautomerge-bench"
mkdir -p "$TMPDIR" "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR" \
    "$CARGO_HOME" "$CARGO_TARGET_DIR" "$BENCH_ROOT"
```

Do not put build output, temporary files, caches, or profiles on NFS, `/tmp`, or `/var/tmp`.
These examples use local Zig caches and the local oracle Cargo manifest.
Do not build or modify the upstream checkout.

### Building and running the native driver

```sh
zig build bench -Doptimize=ReleaseFast \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    --prefix "$BENCH_ROOT/install"
```

This command can fail a workload guard.
A failure is not an accepted measurement of that workload.
Use `ReleaseFast` for before/after comparisons.
Do not compare it with Debug test-case timings.
Debug and `ReleaseSafe` also enable the allocator's per-allocation safety checks.

`bench/anonymize_rss.zig` is separate.
Section 8 gives its direct build recipe.
Section 11 gives the libc-linked matched driver recipe.

### Public transaction and read contracts

`Document.init`, `initWithEncoding`, and `load` have no mode argument.
Use `am.transaction.Transaction` or the root `am.Transaction` for explicit write groups.
Use `AutoCommit` for a held automatic transaction.
Do not move its owner while that transaction remains open.

Ordinary `AutoCommit` and `am.read` readers do not close the pending transaction.
The `AutoCommit.document()` accessor closes pending work before it returns a borrowed document.
Save, heads, history, and other explicit barriers also close pending work.
The matched diff fixtures use `AutoCommit`.
The remaining matched fixtures use `am.doc.Document` with explicit transactions.

`tx.commitWith` returns an owned `CommitResult`, not a hash alone.
Read `result.hash` and release `result.patch_log` with `result.deinit(gpa)`.
`AutoCommit.commitWith` instead returns an optional hash and manages its held transaction's patch log internally.
After commit or rollback, use `tx.deinitClosed()` to release the closed transaction.
An open transaction needs fallible `tx.deinit()` rollback.
Do not use `deinitClosed()` to skip rollback on a live document.

Native concrete text preserves the document's configured code units.
Use `makeString(gpa)` for an owned, lossy UTF-8 conversion when a string is required.
Release all owned results with their documented allocator.

---

## 2. Reading the output

In default mode, each successful workload prints one line on **stdout**:

```
BENCH <name> <iters> <total_ns> <ns_per_iter>
```

| field | meaning |
|---|---|
| `name` | the workload name, as `--list` prints it |
| `iters` | **unit iterations inside one sample**, not the number of samples. `indexed-delta 20 …` means twenty trials, so `ns_per_iter` is the cost of one trial |
| `total_ns` | the median sample's nanoseconds (lower-middle of the sorted samples) |
| `ns_per_iter` | `total_ns / iters` |

Capture both streams from the directly built driver:

```sh
"$BENCH_ROOT/zautomerge-bench" \
    > "$BENCH_ROOT/native.stdout" 2> "$BENCH_ROOT/native.stderr"
native_status=$?
printf '%s\n' "$native_status" > "$BENCH_ROOT/native.exit"
```

Keep stderr and the exit status.
A later guard failure can leave earlier workloads' `BENCH` records on stdout.
Those records do not establish a successful full run.

Everything else — the size table, the per-phase nanoseconds, the checksum, the
leak count — goes to **stderr** through `std.debug.print`, which is this
repository's existing idiom (`test/save_interop.zig:85`).

`--region-instructions list-width` uses a different record: `REGION`.
It measures the `read-list` region directly and does not qualify a whole-process counter.
See [region instruction counters](#region-instruction-counters) for its fields and limits.

### Whole-process instruction counts

This host is shared and busy. Elapsed time changes with load.
Instruction counts are usually more stable for a fixed workload, but can still vary.
Record the measurement scope and counter coverage:

```
perf stat -e instructions:u "$BENCH_ROOT/zautomerge-bench" segmentation
```

`zig build bench` does not install the benchmark executable or forward workload arguments.
Build the executable once with section 7's direct recipe.
Put root code-generation options before the first `-M` flag.
Check the emitted optimization-mode diagnostic before using a measurement.

Run one workload per process.
Keep phase wall times and whole-process counters separate.
Record host load, CPU affinity, counter coverage, and build fingerprints with both.

**One workload per process is necessary and not sufficient.** It makes the count
belong to one workload; it does not make the count belong to the workload's
*subject*, because the count covers whatever the workload built before it
started the clock. `list-width` is the one that got this wrong and §7 says what
it cost: its fixture was about 98% of the count, so `perf stat` was reporting
the fixture while the `BENCH` line reported the walk. In default mode it prints
each phase's elapsed-time share and **fails the run** below the 90% subject floor.
That elapsed-time check is a proxy, not an instruction-share measurement.
The opt-in region counter avoids that proxy for its own count.
An external `perf stat` count still includes setup, verification, and teardown,
even when the program emits a successful `REGION` record.

`insert-loop` has two timed insert arms and a separate correctness read-back.
Whole-process counters include both arms, save/reload, verification, and teardown.
They do not measure `Transaction.insert` alone.
The growth ratio uses only the two timed write regions.
Read-back dominated an earlier binary, not every later run.

All eleven workload names are what `--list` prints. §7 gives the per-workload
`perf stat` lines for the four that are here because a specific cost had no
gate, rather than because a test case was slow.

For attribution:

```
perf record -F 999 -g --call-graph dwarf \
    -o "$BENCH_ROOT/seg.data" \
    "$BENCH_ROOT/zautomerge-bench" segmentation
perf report -i "$BENCH_ROOT/seg.data" --stdio
```

Keep profile files, build output, and caches on approved local scratch storage.
Do not use `/tmp`, `/var/tmp`, or NFS for these files.

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

**`update-object` — unchanged fixture size, with a timed write region.**
Depth 42 builds 43 maps, 861 lists, and 905 hydrated values.
Fixture creation stays outside the clock.
The timer includes `AutoCommit.updateObject` and its following `commitWith`.
The independent read-back stays outside the clock.
Historical Debug case times do not predict the current region's duration.

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
calls and once with a single `tx.splice` — and reads both back
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
2. Require `# LEAKS 0` on each successful native run.
   A nonzero count identifies a resource-ownership defect and invalidates the run.
3. Compare `#   checksum` before and after. **The checksums must be identical
   across a before/after pair.** If they are not, the optimization changed
   behaviour and the timings mean nothing.
4. Compare `BENCH` lines with `diff`, and instruction counts with `perf stat`.
5. On a `list-width` run, find the subject-share line on stderr.
   The subject must reach 90% of measured fixture, read, verification, and teardown wall time.
   This is an elapsed-time guard, not a measured instruction share.
   Below the floor, the run returns `error.SubjectIsNotTheCost` and prints no `BENCH` line.
   An external counter from that rejected process is not an accepted traversal measurement.
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
| `sync-roundtrip` | `sent_hashes` bulk sort and sorted merge during message generation | 24 rounds × 200 changes | 48 rounds × 400 changes |
| `hash-for-opid` | actor-change binary search through `hashForOpid` | 20 000 changes, 400 calls | 50 000 changes, 1000 calls |
| `list-width` | list walk using one held element cursor | 50 000 elements, 2 walks | 200 000 elements, 1 walk |
| `insert-loop` | `Transaction.insert`'s per-insert write path | 2 500 + 10 000 inserts, one transaction each | 5 000 + 20 000 inserts |

These are the current subjects, after the round-5 changes (2026-10-06).
The historical results below describe earlier implementations; they are not
fresh measurements of these subjects. In particular, the old per-hash
memmove, node-table scan and fresh-cursor descriptions do not describe the
current code.

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
(`src/sync/state.zig:489`) and receive-side acknowledgement pruning could
empty the list; with acknowledgements withheld the memmove cost accumulated.
Round 5 replaced it with the batch: one sort and one merge per message instead
of one memmove of half the list per carried hash. `State.insertSent`
(`src/sync/state.zig:484`) is still `pub` and still correct; it has no caller
left on this path.

**The public chain.** Create two `am.AutoCommit` owners and two `am.sync.state.State.new` sync states.
Use the owners' `generateSyncMessage` and `receiveSyncMessage` methods.
Check the public `State.sent_hashes` field.
Message receipt consumes the message.

**The shape.** Keep both `AutoCommit` owners at stable addresses.
After the priming exchange, each round inserts `sync_chunk` items.
Call `local.commitWith(.none)` after every insert, so every item creates one change.
The peer receives every payload but withholds its answer until the measured
rounds finish, so acknowledgements do not prune the local `sent_hashes`.
The first round records `sync_chunk + 1` hashes (including the initial change);
later rounds add exactly `sync_chunk`. Each generation bulk-sorts the payload
hashes and merges them with the growing sorted set. Early payloads may be whole
documents; later ones are change deltas. A final acknowledgement and quiet
generation check close the session.

**Timed region.** `ns` is the sum of the `local-generate` phases only — one
`generateSyncMessage` per round, including payload construction and the bulk
merge. `peer-exchange`, fixture growth and correctness checks are not that
timed region; whole-process `perf stat` includes them.

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

**The public chain.** Open `am.transaction.Transaction` on a mode-less `Document`.
Use `tx.put`, `tx.commitWith`, and `am.transaction.hashForOpid(&tx, exid)`.
`commitWith` returns an owned `CommitResult` with `hash` and `patch_log`.
Release it with `result.deinit(gpa)`.
After a successful commit, release the closed transaction with `tx.deinitClosed()`.
`doc.ops.idToExid` converts returned operation IDs to `ExId` values.

**The shape.** One document with a fixed actor and `opid_changes`
committed changes, one new-key map put per transaction and commit. An empty
probe transaction asks `hashForOpid` for the newest operation `opid_calls`
times, then for the oldest operation the same number of times. Both use the
same actor-change interval binary search; neither arm is a node-table scan.

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

**The shape.** A mode-less `Document` under `.unicode_code_point`, holding
one list of `list_width_elements` integers and one sibling text object.
One explicit transaction builds the text, inserts the integers with `tx.splice`,
and commits once. The timed region makes
`list_width_passes` complete list walks; each walk owns one held element
cursor that advances with the walk. The text, independent length checks and
64-element sequential/batched fixture comparison are verified outside that
region.

The integers enter through one public `tx.splice` call.
Its batch path performs one insertion query and chains the inserted elements by `ElemId`.
Upstream uses the same batch shape through `Transactable::splice`
(`rust/automerge/src/transaction/transactable.rs:85-91`, `inner.rs:673-799`).

### Historical fixture measurements and the guard

These fixture measurements precede the held-cursor change and the 2026-10-08 public-API cutover.
They describe frozen earlier binaries, not the current executable.
The recorded host load average was approximately 120.

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
The 90% floor distinguishes subject-dominated runs from the old fixture's
~1.6% share. This is a measured wall-time share, not an instruction attribution
counter or a guarantee against scheduler noise; read every run's phase split.

### The two fixture builders, checked against each other

Outside the timed region — in the `verify` phase, so it costs the subject
nothing — the workload builds the same 64-element list **twice** in two
throwaway documents: once with 64 `Transaction.insert` calls at ascending
positions, which is what this workload used to do and what a consumer
appending one element at a time still does, and once with a single
`tx.splice`. Both are read back through the same
`am.read.listRange` the subject uses. Every element has to agree on its index,
its width being exactly 1, not conflicting, not being an object, and its
integer value; `am.read.length` has to say 64 for both. **So the batch cannot
make the walk cheap by making it wrong**, and the fixture change is checked
rather than argued.

The two documents' saved bytes are reported, not required to match.
The historical run reported identical bytes.
The acceptance contract requires equal materialized documents, not identical compressed saves.

### The library finding, reported on its own

**The historical ~1011 s does not enter this gate's result.**
That frozen binary measured 50,000 sequential inserts in one transaction and one commit.
It exposed repeated insertion queries and column splices in the growing op set.
The upstream batch alternative is `Transactable::splice`
(`transactable.rs:78-84`, `inner.rs:673-799`).
The separate `insert-loop` workload measures the sequential path in current binaries.
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

**Checksum.** Each element's index and width, the per-walk count, `n`, and the agreement check's element count.
Historical default runs reported `e41686857f8055e0`.

**Sizes.** Unchanged from what they were, and that is the point: **50 000
elements and 2 walks by default**. Nothing had to shrink for the fixture to
become cheap, because the fixture was never the right thing to shrink — it was
the wrong *way* to build the list. `--full` is 200 000 elements and **1** walk
(`Sizes.full`). It increases the element count but reduces the number of
passes, so whole-process default/full ratios must account for both changes.
The current held-cursor walk must be measured rather than assigned the old
fresh-cursor walk's runtime or complexity.


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
am.transaction.Transaction.open
  → tx.putObject
  → tx.insert
  → tx.commitWith
  → result.deinit(gpa)
  → tx.deinitClosed()
```

**The shape.** Two independent mode-less documents with the same fixed actor:
first `insert_small`, then `insert_large` ascending inserts into one list,
each in one transaction and one commit. At step `i`, index `i` is the end
of the list, so these are single-element appends, not a batched splice.
Each arm saves, reloads and walks its list after the insert clock stops.
The timed write path no longer includes the unconditional whole-object slow
cross-check or a whole-column aggregate rebuild; the guard checks whether
per-insert cost still grows across the two sizes.

**Two sizes in one run, and why that is the point.** The workload builds the
shape twice — at `insert_small` and at `insert_large` — and prints the
**per-insert nanoseconds at both**. Their within-run ratio reduces some
host-wide timing effects, but the two arms can still experience different load:

* a per-insert cost **flat in `n`** reads about **1.00**, and that is the
  finding;
* a per-insert cost that **grows with `n`** — which is what an
  O(rows)-per-insert stage is — reads about **4.00**, the size ratio.

One run therefore checks growth across two points without two whole
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
first**, so the arm that inherits the warm allocator is the large one.
That can bias the ratio downward; a passing timing guard is evidence for
this run, not a proof that every regression or scheduling effect is excluded.

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
* **`commitWith` returned a non-null `CommitResult.hash`.**
  A transaction with no pending operations returns no hash.
  The caller releases the owned `patch_log` with `CommitResult.deinit(gpa)`.
* **the transaction's final state**, checked through `tx.closed`,
  `Transaction.count()`, and `am.transaction.maxOp`.
  The closed transaction has no staged operations and rejects `maxOp` with `error.InvalidOp`.
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

**Sizes.** **2 500 and 10 000 inserts by default**, **5 000 and 20 000
under `--full`** — each pair has the same 4× arm-size ratio, one transaction
and one commit per arm. The guard's interpretation is unchanged between
these pairs. The historical fixture's cost does not predict the current
arms' runtime; use their measured phases below.

**Measurement interpretation.** The `verify` phase includes save, reload and
list read-back for both arms. It is outside the insert timer but inside
whole-process `perf stat`, along with teardown and the small arm. Quote
`insert-large` and the within-run per-insert growth ratio for insert cost.
Neither a default/full instruction ratio nor the historical verification
share establishes the current insert path's complexity.

### Running them

`zig build bench` starts the complete eleven-workload driver without forwarding arguments.
The driver stops if a workload fails.
Build it once and call it directly for one workload per measured process:

```sh
# Use the scratch and cache setup from section 1.
printf '%s\n' \
    'pub const check_slow_paths = false;' \
    'pub const package_name = "zautomerge";' \
    'pub const package_version = "0.0.0";' \
    'pub const text_indexing = "unicode_code_point";' \
    > "$BENCH_ROOT/build_options.zig"

# Put root code-generation options before the first -M.
zig build-exe \
    -O ReleaseFast \
    --dep zautomerge \
    -Mroot=bench/zautomerge_bench.zig \
    --dep build_options \
    -Mzautomerge=src/root.zig \
    -Mbuild_options="$BENCH_ROOT/build_options.zig" \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    -femit-bin="$BENCH_ROOT/zautomerge-bench"
```

Run it from the repository root: `-Mzautomerge=src/root.zig` is relative.
Check the mode on the first line of stderr — `zautomerge_bench: optimize=…` —
before quoting anything. Run these eight processes in order, recording
`/proc/loadavg` immediately before and after each (the first three values are
the 1-, 5- and 15-minute averages):

```
cat /proc/loadavg
perf stat -e instructions:u "$BENCH_ROOT/zautomerge-bench" sync-roundtrip
cat /proc/loadavg
perf stat -e instructions:u "$BENCH_ROOT/zautomerge-bench" --full sync-roundtrip
cat /proc/loadavg
perf stat -e instructions:u "$BENCH_ROOT/zautomerge-bench" hash-for-opid
cat /proc/loadavg
perf stat -e instructions:u "$BENCH_ROOT/zautomerge-bench" --full hash-for-opid
cat /proc/loadavg
perf stat -e instructions:u "$BENCH_ROOT/zautomerge-bench" list-width
cat /proc/loadavg
perf stat -e instructions:u "$BENCH_ROOT/zautomerge-bench" --full list-width
cat /proc/loadavg
perf stat -e instructions:u "$BENCH_ROOT/zautomerge-bench" insert-loop
cat /proc/loadavg
perf stat -e instructions:u "$BENCH_ROOT/zautomerge-bench" --full insert-loop
cat /proc/loadavg
```

Each successful process must exit zero, print one `BENCH` line and report
`# LEAKS 0`. Keep the checksum and named phases with the counter output.
Expected `iters`, default/full, are `24/48`, `400/1000`, `2/1` and
`10000/20000` in the order above. Checksums are deterministic for a given
workload and size, not required to match across sizes. `list-width` must clear
its 90% subject-share floor; `insert-loop` must report a 4× arm-size ratio and
per-insert growth no greater than 2.0×. A failed guard provides no accepted
measurement, even if `perf` prints a count.

For a separate timing stability check, `--repeat 5` reports the median
`BENCH` sample, but a process-wide `perf` count then includes all five samples,
not only the median. Do not mix that count with a single-sample table.

### Region instruction counters

Use the directly built executable from the recipe above:

```
"$BENCH_ROOT/zautomerge-bench" --region-instructions list-width
"$BENCH_ROOT/zautomerge-bench" --region-instructions --full list-width
"$BENCH_ROOT/zautomerge-bench" --region-instructions --repeat 5 list-width
```

The flag requires `list-width` as the sole named workload.
Default/full still use 50,000 elements with two walks and 200,000 elements with one walk.
No element count, walk count, or 90% threshold changes.

This mode prints one stdout record after the correctness and leak checks pass:

```
REGION list-width read-list <elements> <walks> <element_visits> <read_ns> <instructions> <time_enabled_ns> <time_running_ns>
```

`element_visits` is `elements * walks`.
`--repeat` selects the lower-middle elapsed-time sample.
Its instruction count, event durations, checksum, and phase diagnostics all belong to that same sample.
It does not sum counts across repeats or select the smallest instruction count.

The Linux counter uses `perf_event_open` for the calling thread's user-space hardware instructions.
It does not inherit into child threads or count kernel/hypervisor execution.
It starts disabled and counts only the complete `read-list` loop.
That loop includes cursor creation, per-element validation, and checksum updates.
Fixture construction, the separate verification phase, and teardown remain outside the counter.

Each sample owns a fresh, pinned event.
The program rejects short reads, zero counts, and incomplete or inconsistent enabled/running coverage.
It never scales a partial count or substitutes elapsed time.
Permission denial, unavailable hardware, and unsupported platforms fail without a metric record.
See [perf_event_open(2)](https://man7.org/linux/man-pages/man2/perf_event_open.2.html) for the kernel contract.

Counter control adds small user-space boundary overhead to the instruction count.
The wall timer also includes counter control and read overhead.
Neither value subtracts a guessed overhead.
The event durations need not equal `read_ns`.
Equal enabled/running durations establish event coverage, not CPU isolation.
The two sizes use different walk counts, so normalize by element visits and keep cache conditions in view.
This measures the benchmark's read region, not `elementWidth` in isolation or end-to-end document cost.

Default mode still emits `BENCH` and applies its 90% elapsed-time guard.
Region mode emits no `BENCH`, even when its instruction count is valid.
Do not attribute an outer `perf stat` process count to traversal from a `REGION` success.

The deterministic counter-validity tests also run under `zig build test`.
Run them alone without PMU permissions:

```
zig build bench-test \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
zig build bench-test -Doptimize=ReleaseSafe \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
```

#### Historical region counts — before the 2026-10-08 API cutover

Three independent processes ran at each size with Zig 0.16.0, ReleaseFast, and `check_slow_paths = false`.
All runs used logical CPU 0 on the shared Intel Xeon Gold 6134 host.
CPU frequency was not fixed, and the host was not isolated.
Each row is the actual median `read_ns` sample, with that sample's instruction count.
Both rows observed load averages of 10.77/14.12/15.94 before and after the process.

| Size | Element visits | Region instructions | Instructions/visit | Read time (ms) |
|---|---:|---:|---:|---:|
| default | 100 000 | 558 729 476 | 5 587.295 | 96.362644 |
| full | 200 000 | 1 120 864 902 | 5 604.325 | 192.147429 |

The default instruction range was 558,729,475–558,729,514.
The full instruction range was 1,120,864,902–1,120,864,976.
Every sample had equal positive enabled/running durations and reported `# LEAKS 0`.
Total instructions grew 2.006× for 2× element visits.
Instructions per visit grew 1.003×.
These two points support near-proportional read-region instruction cost, not a general complexity proof or a speedup claim.

The frozen measured binary SHA-256 was `4eea8596ee8f006f47cd7eb48f48b7c0d267aba6084da69344c2917c5a890034`.
These rows include the corrected per-iteration time diagnostic.
Separate three- and four-sample traced runs checked median/count pairing against the kernel's returned words.
The three-sample run selected the first sample, not the last.
Those ptrace-instrumented timings are validation evidence, not rows in the measurement table.

Child-only seccomp checks denied counter open, enable, disable, and read calls.
Each denial failed with no metric record.
Traces confirmed one counter-descriptor close after enable, disable, or read failure.
The checks did not change the host's perf policy.

### Historical fresh-process counts and guard results — 2026-10-07

These eight points used the **same rebuilt binary**, Zig 0.16.0, ReleaseFast,
`check_slow_paths = false`, one sample per point, on an Intel Xeon Gold 6134
with nominal 3.20 GHz frequency, Linux 6.12.0-160000.38-default x86_64.
The counter was `perf stat -e instructions`, reported as `instructions:u`.
The runs did not use CPU pinning. Optimized integrated verification overlapped
the full `hash-for-opid` run and subsequent points on the shared host.
These counts predate the separate marked-text borrow repair in
`src/opset/batch.zig`. They describe the recorded binary, not a later rerun.

The wall clocks are `perf`'s whole-process elapsed times, **not** `BENCH`
timed regions. Load triples are 1-/5-/15-minute averages immediately before
and after each process. “Not recorded” means the after-load observation was
skipped when the command failed; it is not an estimated value.

| Workload | Size | Process instructions | Process wall clock (s) | Load before → after (1/5/15 min) | Result |
|---|---|---:|---:|---|---|
| `sync-roundtrip` | default | 44 305 413 504 | 18.674565690 | 18.46/15.08/11.59 → 15.49/14.62/11.51 | accepted, exit 0 |
| `sync-roundtrip` | full | 677 239 410 686 | 209.847611208 | 14.83/14.50/11.50 → 15.14/13.93/11.81 | accepted, exit 0 |
| `hash-for-opid` | default | 319 556 487 297 | 106.455910829 | 14.97/13.91/11.81 → 12.48/13.74/12.01 | accepted, exit 0 |
| `hash-for-opid` | full | 2 444 856 884 058 | 675.940867363 | 11.96/13.62/11.97 → 11.16/12.17/11.84 | accepted, exit 0 |
| `list-width` | default | 725 232 203 | 0.218779957 | 10.13/11.87/11.75 → not recorded | **rejected**, exit 1 |
| `list-width` | full | 1 748 265 904 | 0.514643961 | 7.95/10.72/11.35 → 7.95/10.72/11.35 | **rejected**, exit 1 |
| `insert-loop` | default | 18 106 999 833 | 16.840244977 | 7.95/10.67/11.33 → 7.89/10.48/11.25 | accepted, exit 0 |
| `insert-loop` | full | 67 464 330 950 | 51.212708623 | 7.75/10.37/11.21 → not recorded | **rejected**, exit 1 |

| Workload | Full/default process-instruction ratio | What changed between points |
|---|---:|---|
| `sync-roundtrip` | 15.286× | rounds 24 → 48, chunk 200 → 400; total fresh changes 4 800 → 19 200 |
| `hash-for-opid` | 7.651× | changes 20 000 → 50 000; calls per endpoint 400 → 1000 |
| `list-width` | 2.411×, **rejected attribution** | elements 50 000 → 200 000; walks 2 → 1 |
| `insert-loop` | 3.726×, **full run rejected** | both insert arms double; within-run arm-size ratio stays 4× |

These are ratios of **whole-process user-space retired instructions**,
including setup, verification and teardown, not complexity estimates for
the named subject. In particular, the sync process includes untimed fixture
growth and receive work; hash's graph construction dominates its count.
The rejected rows retain raw process counts for reproducibility, but are
**not accepted subject measurements**. None of these counts reuse the issue
comment's historical round-5 measurements.

The following phase observations belong to the same runs and load conditions
in the table above. Values are nanoseconds; `scan-*` are retained output
names for binary-search endpoint queries, not linear scans.

| Workload/size | Reported phases or guard denominator (ns) | Interpretation |
|---|---|---|
| sync/default | `local-generate` 4 535 647 098; `peer-exchange` 8 770 658 905 | `BENCH` times generation only |
| sync/full | `local-generate` 63 064 176 993; `peer-exchange` 102 140 448 386 | fixture growth is also outside `BENCH` |
| hash/default | `build-graph` 106 446 917 105; `scan-last-op` 10 901; `scan-first-op` 12 157 | process count is overwhelmingly fixture work |
| hash/full | `build-graph` 675 920 083 554; `scan-last-op` 26 296; `scan-first-op` 31 069 | same interpretation; tiny endpoint timers are not robust scaling evidence |
| list/default | subject 112 301 114 / total 215 520 526 | 52.11% subject, 39.65% fixture, 7.52% verify, 0.72% teardown |
| list/full | subject 193 642 207 / total 511 642 379 | 37.85% subject, 57.28% fixture, 4.38% verify, 0.50% teardown |
| insert/default | `insert-small` 2 182 983 163; `insert-large` 14 617 001 627; `verify` 35 282 705; `teardown` 1 090 360 | per-insert growth 1.674×, passes 2.0× ceiling |
| insert/full | small arm 5 376 635 126; large arm 45 764 091 834 | per-insert growth 2.128×, fails 2.0× ceiling |

Both list runs returned `SubjectIsNotTheCost`: the held-cursor subject is now
too small a share of the process to clear the unchanged **90% floor**.
No `BENCH` line, checksum or leak footer was emitted for either rejection.
The guard was not weakened and neither fixture size nor walk count was
changed to obtain an accepted count.

The full insert run returned `InsertCostStillGrowsWithTheDocument` and likewise
emitted no `BENCH`, checksum or leak footer. Its raw process count is not an
accepted growth-gate result. The default insert run passed, but its phases
also supersede the historical claim that read-back dominates: the two insert
regions sum to **16 799 984 790 ns**, versus **35 282 705 ns** for verification,
under that row's recorded load. This still does not attribute the process
counter to the large insert arm alone, and one passing default point does
not override the full point's refusal.

Only the five accepted runs printed `# LEAKS 0` and these checksums:

| Workload | Size | `BENCH` iters | Observed checksum |
|---|---|---:|---|
| `sync-roundtrip` | default | 24 | `5d00c51c29d8e4e8` |
| `sync-roundtrip` | full | 48 | `2e325feb51502110` |
| `hash-for-opid` | default | 400 | `95791aa42f3360a0` |
| `hash-for-opid` | full | 1000 | `14d62e27cc12fd70` |
| `insert-loop` | default | 10000 | `6f1c9a0a37fe708` |


For attribution, with a scratch file outside `/tmp`:

```
perf record -F 999 -g --call-graph dwarf \
    -o "$BENCH_ROOT/bench-sync.data" \
    "$BENCH_ROOT/zautomerge-bench" sync-roundtrip
perf report -i "$BENCH_ROOT/bench-sync.data" --stdio
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
file, so build it directly and write these build options **outside the repo**:

```sh
# Use the scratch and cache setup from section 1.
printf '%s\n' \
    'pub const check_slow_paths = false;' \
    'pub const package_name = "zautomerge";' \
    'pub const package_version = "0.0.0";' \
    'pub const text_indexing = "unicode_code_point";' \
    > "$BENCH_ROOT/build_options.zig"

zig build-exe \
    -O ReleaseFast \
    --dep zautomerge \
    -Mroot=bench/anonymize_rss.zig \
    --dep build_options \
    -Mzautomerge=src/root.zig \
    -Mbuild_options="$BENCH_ROOT/build_options.zig" \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    -femit-bin="$BENCH_ROOT/anonymize-rss"
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
/usr/bin/time -v "$BENCH_ROOT/anonymize-rss" --changes 2000 --ops 20 \
    2>&1 | grep -E 'Maximum resident set size|# ANONYMIZE_RSS'

/usr/bin/time -v "$BENCH_ROOT/anonymize-rss" --changes 8000 --ops 20 \
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
"$BENCH_ROOT/anonymize-rss" --changes 200 --ops 5 --check
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

---

## 10. Historical uniform-splice round — 2026-10-08

This section records frozen binaries from before the current public-API cutover and matched comparison.
“Final source” below means the final snapshot of this historical round only.
Do not combine these numbers with later builds or a Rust comparison.
This round reduced `insert-loop` instruction cost.
It did not establish linear insertion cost or full performance parity.
Some full-size runs failed the unchanged growth guard.

### Profile, change, and safety

The baseline full-size profile put nullable RLE wire encoding among the largest
self-cost entries. The generic splice path expanded a constant compressed run
at the seam and then encoded it again. The change preserves eligible uniform
runs in the wire domain instead.

[`uniformRunValue` and `spliceUniformRun`](../src/hexane/slab.zig#L594)
recognize a constant compressed run and use the existing codec `wireFill`.
This is a general slab operation, not an `insert-loop` special case.
Different wire values, nonuniform literals, and empty old slabs retain the
generic seam path. A delta postfix must also match in the wire domain.

The helper allocates and measures the replacement before publication.
It publishes bytes, length, segment count, and tail together.
Borrowed payloads stay live until publication. Allocation failure leaves the
old slab intact. No codec, document, change, or sync format changed.
The [boundary, fallback, borrowed-payload, bounds, and allocation-failure
regressions](../src/hexane/slab.zig#L1311) cover these contracts.

The profile comparison uses `perf report --no-children --sort=symbol -n`.
These percentages use sampled, period-weighted `cycles:u` self cost as their
denominator, including unresolved entries. They are not raw sample fractions.

| Profile entry | Baseline self share | Final-source self share |
|---|---:|---:|
| `WireRle(u32,true,false,leb128).wireEncode` | 23.85% | 30.08% |
| `WireRle(i64,true,false,leb128).wireEncode` | 11.42% | 5.39% |
| `WireRle(u64,false,false,leb128).wireEncode` | 2.69% | 4.66% |
| Total samples | 12,388 | 7,624 |
| Lost samples | 0 | 0 |
| Unresolved samples / total samples | 1,705 / 12,388 (13.7633%) | 1,030 / 7,624 (13.5100%) |

A larger relative share does not mean greater absolute CPU cost.
These profiles locate remaining hot code. They do not measure a speedup.
The final profile follows the hash lookup repair. The repeated measurements
below use the earlier candidate binary.

### Accepted insertion measurements

Each replicate is a fresh process with `--repeat 1`. The default-size series
has three accepted baseline processes and three accepted pre-hash-repair
candidate processes. Every raw insertion counter reports 100% running time.

| Default-size metric | Baseline, n=3 | Pre-hash-repair candidate, n=3 |
|---|---:|---:|
| Whole-process `instructions:u`, median | 18,107,882,789 | 9,631,404,848 |
| Whole-process `instructions:u`, range | 18,106,991,237–18,107,892,014 | 9,631,311,333–9,631,632,078 |
| Large-arm elapsed ns, median | 20,223,010,874 | 9,270,739,579 |
| Large-arm elapsed ns, range | 15,947,502,586–32,096,354,616 | 8,640,718,194–17,364,504,292 |

The accepted default instruction median decreased **46.810983%**.
The counter includes both insertion arms, verification, and teardown.
It is not a large-arm-only counter. The phase clock measures the large arm.
Its wide range exposes contention, so it is not a stable speedup estimate.

Full-size results do **not** provide an accepted three-process comparison.
No full-size median is reported.

| Full-size series | Accepted processes / attempts | Rejected growth ratios |
|---|---:|---|
| Baseline | 1 / 3 | Replicate 2: 2.178×. Replicate 3: 2.306× |
| Pre-hash-repair candidate | 2 / 3 | Replicate 2: 2.135× |

Rejected rows remain in the evidence as diagnostics, not accepted results.
The accepted replicate-1 pair counts 67,464,558,733 versus 34,233,606,262
instructions, a 49.256903% decrease for **one pair only (n=1)**.
This is neither a median nor proof that the full-size guard is stable.

The final binary includes the `Document.hashForOpid` repair.
Its separate one-off insertion runs passed:

| Final-source one-off | Whole-process `instructions:u` | Large-arm elapsed ns | Growth | Checksum | Leaks |
|---|---:|---:|---:|---|---:|
| Default, n=1 | 9,631,410,972 | 11,762,267,089 | 1.493× | `6f1c9a0a37fe708` | 0 |
| Full, n=1 | 34,233,377,931 | 34,451,499,855 | 1.871× | `58a37e6296ef960f` | 0 |

Do not combine these one-offs with the earlier candidate medians.
The insertion ceiling remains **2.0×** per-insert growth for **4×** arm sizes.
The rejected full-size runs remain an open performance result.

### Post-verification full-size control

A separate six-process series ran after every native verification job finished.
It used the same CPU 0, launcher, full sizes, and unchanged growth guard.
The order was baseline/final, repeated three times. No process was rerun.
The host still had other load and no fixed-frequency control.

| Snapshot | Accepted / attempted | Growth ratios, in order |
|---|---:|---|
| Baseline | 0 / 3 | 2.304× reject, 2.171× reject, 2.223× reject |
| Final source | 2 / 3 | 1.816× pass, 1.598× pass, 2.084× reject |

All six hardware counters had 100% running coverage.
The two accepted final runs returned checksum `58a37e6296ef960f` and `LEAKS 0`.
The rejected runs printed no `BENCH`, checksum, or leak footer.
There is still no accepted paired full-size median or instruction delta.
Removing our verification jobs did not clear the growth rejections.
The separate rows and raw output are in `post-verification-full.csv` and
`post-verification-full-summary.json` under the same evidence directory.

### Read-region check and broader workload proof

Each read-region series has three processes. All twelve REGION records have
equal enabled and running durations, correct visits, matching checksums, and
`LEAKS 0`. The sequential and batched fixtures read back identically.

| Read-region metric | Default baseline → candidate | Full baseline → candidate |
|---|---:|---:|
| Visits per process | 100,000 → 100,000 | 200,000 → 200,000 |
| Region `instructions:u`, median | 558,729,467 → 558,729,469 | 1,120,864,911 → 1,120,864,907 |
| Checksum, both snapshots | `e41686857f8055e0` | `2485b42219224460` |
| Normal elapsed subject share, baseline range | 40.20–40.38% | 26.84–27.29% |
| Normal elapsed subject share, candidate range | 41.41–43.71% | 27.31–28.51% |

There is no measured read-region instruction regression or speedup.
REGION counts only the complete read-list loop.
Every normal elapsed subject-share check failed the unchanged **90%** floor.
There is no accepted normal list `BENCH` result or whole-process read attribution.
The valid REGION records do not override that rejection.

The final binary also passed these separate runs with exit 0 and `LEAKS 0`.
These are correctness and workload-guard checks, not before/after speed comparisons.

| Workload | Size | Checksum |
|---|---|---|
| `segmentation` | Default | `7245e3fce02b9ead` |
| `indexed-delta` | Default | `db5fba6acd4b2375` |
| `slab-merge` | Default | `4444602a1505e9dd` |
| `prefix-bool` | Default | `fe24f4eea3f66da2` |
| `update-object` | Default | `5c40dd6d66a25c86` |
| `mark-index` | Default | `2fca352236fe2078` |
| `mark-at-end` | Default | `9f197e16fb445d9d` |
| `sync-roundtrip` | Default | `5d00c51c29d8e4e8` |
| `hash-for-opid` | Default | `95791aa42f3360a0` |
| `hash-for-opid` | Full | `14d62e27cc12fd70` |

### Reproduction and evidence limits

These snapshots used Zig 0.16.0, ReleaseFast, and `check_slow_paths = false`.
Section 7 shows the equivalent build recipe for current source.
To reproduce this historical table, use the archived snapshot executables below, not a current-source rebuild.
The measured host was an Intel Xeon Gold 6134 at nominal 3.20 GHz.
The shared host had no fixed-frequency control.
The collector could use CPUs 0–31 and pinned benchmark processes to CPU 0.
CPU 16 is CPU 0's SMT sibling. Concurrent native checks allowed CPU 16.
This permits SMT contention, but does not prove where those checks actually ran.

| Snapshot | Executable SHA-256 |
|---|---|
| Baseline | `4eea8596ee8f006f47cd7eb48f48b7c0d267aba6084da69344c2917c5a890034` |
| Candidate before hash repair | `abfebb5e7b6b147d37431f455029f26e6da10c085c4c9e9c49a1328f35326222` |
| Final source after hash repair | `bac9fa14332b8d61b0109a97642645629cd823140d8bec92e5bd6f5618b6662f` |

The private round root is `/tmp/tmp/zautomerge-improvement-2DK57G`.
Its `evidence/` directory retains CSV rows, raw output, counters, profile
reports, runner scripts, fingerprints, topology, and per-run load averages.
Use `measurement-summary.json`, `insert-runs.csv`, `insert-summary.csv`,
`region-summary.csv`, `profile-summary.csv`, and `candidate-sweep.csv`.
No rejected artifact was deleted.

From that round root, reproduce one process with these commands.
Use each snapshot executable in turn. Add `--full` before the workload for
full-size runs. Repeat each insertion and region command in three fresh processes.

```sh
taskset -c 0 perf stat -x, -e instructions:u -o evidence/repro-insert.stat -- \
    ./final-candidate-bench --repeat 1 insert-loop
taskset -c 0 ./final-candidate-bench --repeat 1 --region-instructions list-width
taskset -c 0 perf record -N -m8 -F199 -g --call-graph dwarf,2048 \
    -e cycles:u -o evidence/repro-insert.data -- \
    ./final-candidate-bench --repeat 1 --full insert-loop
perf report -i evidence/repro-insert.data --stdio --no-children --sort=symbol -n
```

Record stdout, stderr, exit status, fingerprint, and load averages with each run.
Check the guard, checksum, leak footer, and counter coverage before acceptance.
The baseline profile came from the parent capture. Its report command and
sample counts remain recorded, but its capture provenance is less complete.
Some initial insertion rows retain transcript values and raw `.stat` files
without copied stdout, stderr, or complete collector metadata.
The CSV marks those missing fields. Do not infer missing provenance from later runs.

---

## 11. Matched Rust comparison — 2026-10-08

The frozen 156-process baseline passed every cell's correctness and counter checks.
It does not establish overall performance parity with Rust or verify the new optimization candidate.
Baseline native writes and cold paths were slower.
Baseline cached diff phases were faster, but their fixture costs prevented an overall win.
The comparison uses Automerge 0.12.0 at revision `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`.
The toolchains are Zig 0.16.0 and Rust 1.98.1.
Use the same host CPU, native CPU targeting, and release builds.
Zig uses `std.heap.c_allocator` with libc.
Rust uses its default `System` allocator.
Neither matched driver reports allocation counts or `LEAKS 0`.

### Current optimization-loop checkpoint

Candidate 4 completed a matched three-sample diagnostic, not the required five-sample final acceptance.
All 26 final acceptance cells remain pending.
The pre-loop 156-execution matrix and [complete gates](../docs/STATUS.md#frozen-complete-gates-and-matched-baseline) are frozen baseline evidence.
They do not certify this candidate.
The new source wave implements counted prefix-run splicing and interned byte-string indexing.
Focused Debug/ReleaseSafe, bounded actual consumers, public workflows, and reference checks passed within their named scope.
Candidate 4 is built and measured diagnostically. Candidate-3 one-sample results do not establish an isolated percentage gain.

Candidate-3 source changes include:

- Lexical map bounds and preserved `ElemWalk` lookahead.
- Codec-aware prefix accumulation and bounded unsigned/untracked literal maintenance.
  Signed tracked columns retain the legacy whole-header behavior.
- Affected-range weights, cached tree bases, checked tree/Fenwick updates, and prepared raw publication.
- Row streams with rebased value and successor cursors.
- One batched selected-history reconstruction per unique change, with independent owned results for duplicates.
- Strict V2 threshold selection before payload reconstruction.
- Checked one-/two-byte LEB paths and finite unrolling.

The checked-column signed panic repair uses private exact cached tree-prefix aggregation, not disabled runtime safety.
Fixture ownership repairs preserve empty-array disposal and stateless-allocator contracts without inspecting undefined context pointers.
Existing change hashes, save interoperability, and private collector meaning remain required.

The focused checks passed 52/52 cases each: Debug in 11.46 seconds and ReleaseSafe in 145.22 seconds.
Neither reported leaks.
The rebuilt public-API executable passed four actual workflows with allocator cleanup in 4.55 seconds.
These are bounded checks, not complete-root or all-cell proof.
The parent subsequently observed a broader subsystem Debug compile failure in 8.41 seconds, before any cases.
It found two invalid slab-test qualifications and an existing iterator catch that omitted the new `Overflow` error.
After compile repairs, the 911-case Debug selection aborted at case 896 after 284.59 seconds, before completion.
Four assertions failed first: two decoded-byte budgets, beyond-data prefix behavior, and propagated iterator error behavior.
The abort followed a null retained-key read after normal raw hydrate initialization and successful batch commit.
Stale earlier OOM context does not identify the normal trigger's cause.
That aborted run has no completed pass total. The latest expanded selection passed the affected regressions.
The focused passes certify their earlier snapshot, not subsequent repairs or a final candidate freeze.

The first ReleaseFast/native libc-CAllocator candidate is `native-candidate-1`, built in 122.76 seconds at `2026-10-08T10:53:10Z`.
Its SHA-256 is `f5a2e3712fabce2a2556e26a73664e026044a1d5d62a0be192241db8719c33f0`.
Capture preflight then failed before any benchmark, because the read-only Cargo executable has two legitimate hardlinks.
Evidence: [integrated-wave1-verified.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/integrated-wave1-verified.json).
The parent then built `native-candidate-2` at `2026-10-08T11:40:58Z` in 122.40 seconds, with the same build mode and allocator.
Its SHA-256 is `ed556169a9defd1ef017a84f3d3e24bce909e319e4a9779a58ef566d4db0992e`.
It remains unmeasured and predates the confirmed strict-load repair. It must not serve as the acceptance candidate.
Expanded Debug compilation first failed on a nonexistent fixture `types.ObjId`.
The parent corrected it to `ExId`.
The latest expanded Debug run exited zero in 698.07 seconds: 920 passes, one skip, zero failures from 921 selected cases.
It includes the earlier failures, root/reference-hash tests, and allocation-failure cases.
This is expanded selection evidence, not full Debug/slow-path/ReleaseSafe proof.
Parent output: `artifact://852`, 933 lines.
The latest actual executable checks passed eight workflows with allocator cleanup in 6.37 seconds.
`native-hydrate-public-smoke` passed absent/overlap/repeat/child paths, exact Rust heads, and retained conflicts `[1,2]` and `[1,2,2]`.
`public-api-wave2` passed the unchanged four public capabilities.
Both binaries remain in the owned scratch directory below.

A [four-path pinned Rust hydrate probe](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/reference-hydrate-observations.json) compared direct results with fresh replay of identical-head changes.
Replay retained absent keys and conflicts where the direct producer had broken physical query results.
The native repair changes only physical ordering, preserving empty predecessors, same-value repeats, sorted/BFS creation order, and hashes.
The separate latest native executable now passes those four reference paths. Neither result establishes universal behavior.
The subsequent public strict-load probe confirmed malformed snapshot-order acceptance before repair.
Its canonical control loaded `a=1,b=2` and the expected head.
A normally saved snapshot with two complete valid rows swapped retained its history head but hid live key `b`.
The before-repair probe exited zero in 3.85 seconds, confirming the bug rather than a passing load contract.
Evidence: [snapshot-order-public-smoke.zig](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/snapshot-order-public-smoke.zig).
After repair, the same public probe exited zero in 3.95 seconds and rejected malformed order with typed `InvalidValue`.
The canonical control still loaded both keys and the expected head.
The repair uses allocation-free `OpStepper` validation within the existing index/mark-validation walk, before index-builder grouping and processing.
It adds no scan, error type, or wire change. `allow_invalid_marks` cannot bypass row order.
Post-repair focused Debug and ReleaseSafe each passed 10/10 cases, with combined wall time 375.44 seconds.
This is targeted strict-load/recovery/rescue, ownership, ordering, and reference-hash evidence, not a full-suite result.
Candidate-2 descriptor and preflight completed in 2.07 and 3.12 seconds, without benchmarks.
They accept the actual read-only two-hardlink Rust executable without modifying it.
Captures: [descriptor](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-describe-20261008T114857Z-1752171a010f4cf3a0b8bf446f3ccf1a)
and [preflight](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-preflight-20261008T115218Z-8e6a201d22b344479777cc2904743aa7).
Candidate 2 remains pre-order-gate and will not be measured.
Candidate 3 built in 120.17 seconds at `2026-10-08T12:20:45Z`, ReleaseFast/native with libc CAllocator.
Its SHA-256 is `496d2deddc79132b38984619c5dbbd7e3f02b5275c38db4a21059046fae0cb2c`.
The build record SHA-256 is `7b322c553aec439bcf3fbaa0b612a968b35271cca7b366bf0b251d9a2415b8b6`.
The diagnostic completed on frozen source without provenance drift. Final acceptance remains pending.
Candidate-3 reference conformance and live save interoperability passed in 11.60 seconds, with 32/32 build steps.
All 12 vectors matched unchanged goldens exactly, and all six live save scenarios verified.
Output: `artifact://874`, footer at line 4522. Build steps do not count semantic cases.
Read-only upstream Rust unused-import warnings remain reference diagnostics, not native benchmark stderr.
All optimization-loop evidence remains in owned scratch `/tmp/tmp/zautomerge-perf-loop-tYJOfU`, not new repository artifacts.

Final acceptance retains all 26 unchanged workload/size cells, verifiers, phase boundaries, and coverage limits.
Each cell must meet Native/Rust ≤2 for its subject wall time and whole-process wall time.
Sync `generate` and `receive` must meet their subject limits independently.
The final matrix requires five fresh samples per engine and cell: 260 processes, serial balanced order, CPU 0, runner CPU 2.
Retain every raw result, applicable phase, counter, and timing tail, with median, minimum, and maximum.
Preserve the best cached `diff-repeat`, `diff-subtree`, and sync `receive` results in both absolute time and Native/Rust ratio.
Complete Debug/slow-path/ReleaseSafe, API replay, C, and all-cell gates remain pending after these source changes.
No ≤2 success, universal-input guarantee, or CPU/frequency-isolation claim follows from this checkpoint.

#### Candidate 3 single-sample diagnostic: not final acceptance

All 52 fresh processes completed validly, covering all 26 matched pairs.
All 104 user-space instruction/cycle observations had 100% counter coverage.
The run had no errors, stderr, retries, parity mismatches, or source/binary provenance drift.
It ran serially on CPU 0 with runner CPU 2, balanced 13 Native-first and 13 Rust-first pairs.
All eight large-stack Native/Rust profiles completed against frozen candidate 3, closing that source capture.
Five pure profile-helper tests passed in 0.002 seconds, not five workload profiles.
The first profile invocation failed before benchmarks because outer CPU-2 affinity excluded required entry CPU 0.
It ran zero benchmark processes.
Original incomplete ledgers remain preserved in owned scratch.
Reports later completed offline from the same recordings, without a benchmark or profile retry.

This capture has one sample per engine and cell, not the required five-sample, 260-process final matrix.
Its aggregate subject, process-wall, and best-phase preservation checks are all false.
All 26 final acceptance cells remain pending.
Process wall includes launch/helper/perf overhead through disposal, without subtraction.
User-space counters cover the whole process, not its subject phase.
The ledger retains all phases, raw output, counters, and historical comparison fields.
With one sample, minimum, median, and maximum coincide and give no estimate of repeated-run variation.

The table contains all 26 cells. All ratio columns are Native/Rust.
Subject times are Native/Rust milliseconds. Sync lists generation then receipt, which have independent limits.
The last column records the ledger's absolute/relative preservation flags against the frozen three-sample baseline.
Those flags are observations, not statistical regression or no-regression proof.

| Workload | Size | Subject | Subject ms Native/Rust | Subject ratio | Process wall ratio | Process instructions/cycles ratios | Baseline preservation absolute/relative |
|---|---|---|---:|---:|---:|---:|---|
| `insert-growth` | small | mutation | 182.722/35.615 | 5.130 | 1.699 | 3.650/3.720 | — |
| `insert-growth` | large | mutation | 1555.146/239.166 | 6.502 | 3.543 | 5.514/4.850 | — |
| `list-range-seq` | small | read | 0.846/0.394 | 2.148 | 1.409 | 3.846/3.724 | — |
| `list-range-seq` | large | read | 9.487/1.896 | 5.003 | 3.346 | 5.863/4.572 | — |
| `list-range-batch` | small | read | 3.853/0.500 | 7.707 | 0.999 | 1.130/0.948 | — |
| `list-range-batch` | large | read | 6.336/5.095 | 1.244 | 1.163 | 1.116/1.105 | — |
| `text-edits` | small | mutation | 339.760/39.469 | 8.608 | 1.989 | 4.895/5.689 | — |
| `text-edits` | large | mutation | 1548.234/213.734 | 7.244 | 3.369 | 5.828/5.309 | — |
| `map-updates` | small | mutation | 1112.677/295.079 | 3.771 | 2.470 | 4.944/4.043 | — |
| `map-updates` | large | mutation | 6626.579/1259.390 | 5.262 | 4.542 | 7.988/5.456 | — |
| `save` | small | save | 1.643/0.532 | 3.088 | 1.544 | 5.057/3.661 | — |
| `save` | large | save | 7.440/4.790 | 1.553 | 4.860 | 10.863/7.017 | — |
| `load` | small | load | 52.413/6.151 | 8.522 | 1.827 | 5.057/3.666 | — |
| `load` | large | load | 589.177/27.630 | 21.324 | 4.515 | 10.865/6.764 | — |
| `merge` | small | merge | 23.631/5.837 | 4.049 | 1.600 | 3.886/3.259 | — |
| `merge` | large | merge | 311.515/19.185 | 16.237 | 3.591 | 7.169/5.362 | — |
| `sync-roundtrip` | small | generate, receive | 141.453/198.041, 118.680/171.651 | 0.714, 0.691 | 1.229 | 1.833/1.865 | receive: no/yes |
| `sync-roundtrip` | large | generate, receive | 952.295/1256.053, 466.565/652.829 | 0.758, 0.715 | 1.508 | 2.096/1.984 | receive: no/yes |
| `diff-first` | small | diff | 2.863/1.977 | 1.448 | 1.767 | 4.204/4.189 | — |
| `diff-first` | large | diff | 10.480/8.215 | 1.276 | 3.732 | 5.662/5.580 | — |
| `diff-repeat` | small | diff | 4.995/7.711 | 0.648 | 1.396 | 3.397/3.195 | yes/yes |
| `diff-repeat` | large | diff | 25.961/36.800 | 0.705 | 4.059 | 4.572/4.734 | no/no |
| `diff-rotate` | small | diff | 101.981/103.593 | 0.984 | 1.880 | 2.320/2.489 | — |
| `diff-rotate` | large | diff | 453.719/518.205 | 0.876 | 2.868 | 3.043/3.175 | — |
| `diff-subtree` | small | diff | 12.906/20.561 | 0.628 | 2.101 | 3.397/3.475 | no/no |
| `diff-subtree` | large | diff | 45.740/64.577 | 0.708 | 3.858 | 4.572/4.639 | no/no |

The shared host used `powersave`, without exclusive CPU or fixed-frequency control.
The small/large batch-read contrast must not become a statistical regression, scaling, or isolation claim.
Evidence: [candidate-3 diagnostic capture-ledger.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-diagnostic-20261008T122629Z-fdf3cea06b79405c9c4a62ea7c2339c3/capture-ledger.json).
The source-tree fingerprint is `f68ca51c7e2085b689b30d86dff8fe5411fd2b26cae584d148514934da8be74c`.
The frozen historical matrix below remains a separate three-sample experiment.

#### Candidate 3 large-stack profiles: diagnostic only

Eight actual profiles covered large insert, map update, load, and merge once per engine.
Every process passed full identity checks and had empty benchmark stderr.
The offline continuation produced 48 reports, with zero new benchmark or profile processes.
The parent observed reports-only exit zero in 151.40 seconds and nine passing pure helper tests.
The [allowlisted sanitized profile receipt](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-candidate3-reports-20261008T130959Z-7892a1039a1548fdb0a5cdb027809cdc/profile-ledger.json)
is the public evidence record. Original full-environment ledgers are not public receipts.

Profiles sample whole-process `cycles:u` at frequency 199 with 16-KiB DWARF stacks.
Self percentages use period weights, not raw sample counts.
The table keeps buffer-loss records, final lost-sample counters, and independent perf-report loss totals separate.
A dash means no final lost-sample counter record.
Buffer/counter cells record their own record-type counts after the slash.
Self symbol names omit module paths and anonymous instantiation suffixes.

| Workload, large | Engine | Samples | Unframed | Buffer lost samples/records | Final `LOST_SAMPLES` value/records | Perf-report lost samples | Selected native self symbols, period-weight % |
|---|---|---:|---:|---:|---:|---:|---|
| `insert-growth` | Native | 162 | 127 | 0/0 | —/0 | 0 | `RunWriter(u64,false,leb128).append` 22.20%, `BoolCodec.wireEncode` 8.89% |
| `insert-growth` | Rust | 38 | 0 | 0/0 | —/0 | 0 | — |
| `map-updates` | Native | 896 | 750 | 2/1 | 2/1 | 2 | `mem.eql` 13.40%, `BoolCodec.wireRangeFromSegs` 6.52%, `RunWriter(u64,false,leb128).append` 6.42%, `BoolCodec.wireEncode` 4.33% |
| `map-updates` | Rust | 154 | 0 | 32/1 | 32/1 | 32 | — |
| `load` | Native | 290 | 247 | 0/0 | —/0 | 0 | `mem.eql` 36.15%, `Strings.intern` 10.02% |
| `load` | Rust | 44 | 0 | 1/1 | 1/1 | 1 | — |
| `merge` | Native | 164 | 132 | 0/0 | —/0 | 0 | `mem.eql` 31.64%, `Strings.intern` 5.11% |
| `merge` | Rust | 36 | 0 | 0/0 | —/0 | 0 | — |

The loss columns must not be added. They do not establish disjoint losses or a combined total.
Zero recorded loss does not prove zero unreported throttling or unwind loss.
Self symbols resolve from sampled instruction addresses and reports, including samples without decoded stacks.
They do not establish native callers or phase attribution.
The parent observed `.eh_frame`, `.eh_frame_hdr`, and full DWARF sections in candidate 3.
Incomplete native unwinding has an unknown cause, not evidence of missing sections.
Sparse Rust samples and recorded losses limit comparative statistics.
These profiles are not timing samples, benchmark medians, or ≤2 acceptance proof.

Earlier partial attempts retain the entry-affinity error, blank-native-frame parser failure, and mid-edit report-hash refusal.
They also retain the unsupported `--no-call-graph` refusal and later `--hide-call-graph` correction.
Spaced loss fields and different loss-record types required separate accounting corrections.
The offline reports preserve those failures without rerunning a benchmark or recording.

Source inspection found that slabs already use counted dispatch when a codec exposes `WireSpliceWriter`.
`MetaPrefixCodec` and `BoolPrefixCodec` lacked that writer.
Boolean range publication expanded the whole slab rather than use a boolean counted writer.
String interning scanned all retained byte strings.
The new source exposes the existing counted metadata writer and reuses the boolean encoder for counted ranges/opening parity.
String interning now uses one authoritative `StringArrayHashMap` with arena-owned immutable keys and stable insertion-order `u32` IDs.
It reserves before key publication, performs allocation-free duplicate lookup, and retains IDs across clones.
Focused and actual-consumer checks passed, but no measured gain exists.
The first focused Debug run selected 28 cases: 26 passed and two failed in 69.98 seconds.
Both failures came from a new composite fixture that returned borrowed successor pointers into a function-local runtime array.
The fixture repair gives successor/increment arrays the full callback lifetime, while retaining independent successor, all-column, and allocation-failure assertions.
The parent did not change production boolean/string code for those fixture failures.
Earlier capture-shadow, comptime tuple-type, and missing fallible-length errors were fixture-only compile repairs.
After fixture repair, Debug and ReleaseSafe each passed all 28 selected cases.
The focused/bounded-consumer command exited zero in 256.45 seconds.
Static string/counting reviews reported no findings with confidence 0.93/0.94, not runtime proof.

#### Verified source wave: candidate 4 bounded proofs

Three actual public fixed-buffer-allocator consumers passed the exact scenarios below.
These are reached compressed-run and window proofs, not a universal memory bound.

| Actual consumer | Logical rows | Encoded bytes | Fixed-buffer capacity | Observed result |
|---|---:|---:|---:|---|
| Boolean counted splice | 1,000,002 | 8 | 4,096 bytes | Prefix 3, canonical bytes exact, cut window exact, strict reload exact, allocator clean |
| Metadata counted splice | 1,000,002 | 12 | 4,096 bytes | Prefix 1,000,002, canonical bytes exact, cut window exact, strict reload exact, allocator clean |
| Boolean requested window | 1,000,000 | 4, padded wire | 3 bytes | Three `true` values, allocator clean |

The window consumer's zero-capacity allocator returned `InvalidValue` for invalid bounds and `OutOfMemory` for a valid request.
No universal 4-KiB allocation bound follows.
The current public and retained-root executables passed eight actual workflows with allocator cleanup in 6.48 seconds.
Current conformance matched all 12 unchanged goldens and live saves verified all six scenarios in 11.19 seconds.
The build summary was 32/32 steps, not 32 semantic cases. Output: `artifact://913`, footer at line 4522.
Evidence: [integrated-wave3-verified.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/integrated-wave3-verified.json).

Candidate 4's 80-file source stayed frozen throughout its build and completed captures.
Its source-tree SHA-256 is `68aaea45617797d9cb172ca96d1abcbe74405bb60b6b0ffdcb54c38ed4f46030`.
Its manifest SHA-256 is `07e398f58712ff54752f409009c625481daddceb4a0914df383e0d9dd2dd4a04`.
Build-input contents remain unchanged.
Candidate 4 built in 118.23 seconds at `2026-10-08T13:51:34Z`, ReleaseFast/native with libc CAllocator.
Its binary SHA-256 is `374609baecfa8bfbfd0dfa7975575629478b2a0f39f9f9604c079bc5570ea0b8`.
Its build-record SHA-256 is `5f059163fe643d4b390ecd31506c20329af3cbe91903d0e962626a53bbabdd20`.
Source contents and full provenance matched before and after the build.
Evidence: [candidate-4-build-observation.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/candidate-4-build-observation.json).
Full current-source gates and all final acceptance cells remain pending.


The generalized helper passed 15 pure tests in 6.791 seconds, with 8.05-second total command time.
Its test-only extra rounds are not timing samples.
Candidate 4 completed three fresh samples per engine/cell: 156 processes, 78 pairs, and 312 counter observations.
This diagnostic is neither the frozen historical 156-process matrix nor final five-sample acceptance.
Final acceptance remains five fresh samples per engine/cell, 260 processes, with unchanged limits.
All 26 final acceptance cells and full current-source gates remain pending.

#### Candidate 4 three-sample diagnostic: not final acceptance

Descriptor, preflight, and the complete diagnostic exited zero in 365.92 seconds combined.
All 156 fresh processes were valid, all 78 pairs matched, and all 312 counter observations had 100% coverage.
All 26 unchanged cells completed without retries, errors, stderr, or source/binary provenance drift.
The run used CPU 0 and runner CPU 2, serially, with 39 Native-first and 39 Rust-first pairs.
All raw samples and applicable phase/counter minima, medians, and maxima remain in the ledger.

Aggregate subject, process-wall, and best-phase preservation checks are all false.
No final acceptance cell is complete. Every unchanged cell must meet both subject and whole-process Native/Rust wall ratios ≤2.
Sync generation and receipt remain independent subjects.
Final acceptance requires five fresh samples per engine/cell: 260 balanced serial processes on CPU 0, with runner CPU 2.
It must also preserve absolute and Rust-relative repeat/subtree/receive best results and retain all raw phases and tails.
The table contains all 26 cells and 28 independent subject comparisons.
All ratio columns are Native/Rust. Subject times are milliseconds: median [minimum–maximum], three samples per engine.
Sync lists generation then receipt in each subject column.
Process wall includes launch/helper/perf overhead through disposal, without subtraction.
Process instruction/cycle ratios do not attribute cost to the subject.
Preservation factors compare absolute native time and Native/Rust ratio with the frozen baseline, respectively.
Both factors must be ≤1 for the strict preservation guard.
These observed guards are not statistical regression or no-regression proof.

| Workload | Size | Subject | Native subject ms [min–max] | Rust subject ms [min–max] | Subject ratio | Process wall ratio | Process instructions/cycles ratios | Preservation factors absolute/relative |
|---|---|---|---:|---:|---:|---:|---:|---:|
| `insert-growth` | small | mutation | 113.622 [104.577–114.384] | 44.644 [36.141–48.339] | 2.545 | 1.265 | 2.749/2.548 | — |
| `insert-growth` | large | mutation | 429.903 [420.367–440.165] | 159.032 [142.775–168.861] | 2.703 | 1.634 | 2.737/2.658 | — |
| `list-range-seq` | small | read | 0.829 [0.732–0.835] | 0.502 [0.342–0.525] | 1.652 | 1.224 | 2.872/2.518 | — |
| `list-range-seq` | large | read | 3.262 [3.005–3.529] | 1.788 [1.552–1.859] | 1.824 | 1.711 | 2.858/2.535 | — |
| `list-range-batch` | small | read | 1.340 [0.967–1.959] | 0.388 [0.341–0.918] | 3.456 | 1.089 | 1.139/1.158 | — |
| `list-range-batch` | large | read | 3.655 [2.692–3.769] | 1.836 [1.818–2.563] | 1.991 | 1.046 | 1.123/0.982 | — |
| `text-edits` | small | mutation | 95.697 [94.750–97.909] | 22.731 [22.728–27.126] | 4.210 | 1.279 | 3.407/2.792 | — |
| `text-edits` | large | mutation | 402.513 [392.628–421.016] | 108.949 [105.675–113.420] | 3.695 | 1.820 | 3.658/2.980 | — |
| `map-updates` | small | mutation | 462.820 [444.114–466.996] | 122.401 [106.986–131.614] | 3.781 | 2.007 | 3.692/3.198 | — |
| `map-updates` | large | mutation | 2027.935 [1960.980–2142.885] | 581.349 [569.227–584.210] | 3.488 | 2.859 | 3.814/3.191 | — |
| `save` | small | save | 1.345 [1.342–1.354] | 0.747 [0.584–0.837] | 1.799 | 1.311 | 2.898/2.398 | — |
| `save` | large | save | 4.060 [4.051–5.280] | 1.749 [1.747–1.796] | 2.322 | 1.665 | 3.005/2.430 | — |
| `load` | small | load | 4.419 [4.332–4.614] | 3.176 [2.958–3.178] | 1.392 | 1.308 | 2.898/2.285 | — |
| `load` | large | load | 17.405 [17.191–23.943] | 12.313 [11.790–12.575] | 1.414 | 1.706 | 3.006/2.604 | — |
| `merge` | small | merge | 2.205 [2.152–2.210] | 2.922 [2.804–3.544] | 0.755 | 1.190 | 2.775/2.337 | — |
| `merge` | large | merge | 8.356 [8.292–8.399] | 12.543 [10.466–51.814] | 0.666 | 1.684 | 2.936/2.674 | — |
| `sync-roundtrip` | small | generate, receive | 105.939 [104.736–106.398], 78.808 [75.373–83.726] | 94.029 [93.694–94.518], 82.459 [78.803–88.852] | 1.127, 0.956 | 1.339 | 1.403/1.447 | receive: 0.991/1.023 |
| `sync-roundtrip` | large | generate, receive | 854.850 [840.624–879.319], 407.432 [373.187–407.656] | 840.006 [761.298–859.542], 443.776 [418.568–466.168] | 1.018, 0.918 | 1.282 | 1.257/1.280 | receive: 1.027/1.033 |
| `diff-first` | small | diff | 2.791 [2.542–2.821] | 2.631 [2.046–2.667] | 1.061 | 1.642 | 3.498/3.149 | — |
| `diff-first` | large | diff | 10.542 [9.957–11.119] | 10.515 [8.527–12.915] | 1.002 | 2.506 | 3.641/3.421 | — |
| `diff-repeat` | small | diff | 4.944 [4.919–4.946] | 11.853 [11.815–13.022] | 0.417 | 1.435 | 2.844/2.294 | 0.848/0.591 |
| `diff-repeat` | large | diff | 20.836 [19.627–25.385] | 46.372 [38.106–50.722] | 0.449 | 2.012 | 2.978/2.622 | 0.996/1.015 |
| `diff-rotate` | small | diff | 58.863 [52.712–60.070] | 78.453 [77.505–82.688] | 0.750 | 1.382 | 1.997/1.708 | — |
| `diff-rotate` | large | diff | 217.330 [211.626–218.664] | 302.852 [291.029–335.815] | 0.718 | 1.673 | 2.095/1.812 | — |
| `diff-subtree` | small | diff | 6.432 [5.316–6.564] | 10.540 [8.165–11.896] | 0.610 | 1.543 | 2.843/2.265 | 1.209/1.197 |
| `diff-subtree` | large | diff | 23.425 [19.766–25.621] | 34.615 [32.090–46.307] | 0.677 | 2.269 | 2.977/2.922 | 1.137/1.203 |

Insert and map mutation, text edits, small batch read, and large save miss their subject limit.
Both map sizes and large cold/repeated/subtree diff miss the process-wall limit.
Only small repeated diff meets both strict preservation factors.
Load and merge meet their diagnostic subject/process limits, not final acceptance.
Keep the small batch-read timing range visible. Do not infer scaling or a statistical regression from these samples.
Some ledger comparison-label text mentions five final samples. The actual current capture has three, not five.
That label does not change sample counts, timers, ratios, or acceptance. The historical ledger is not rewritten.
The executor helper now labels actual baseline/current modes and counts. No historical receipt was rewritten.
Its recorded executor-only SHA-256 transition is `4677435af4d245e35ae0b853109e4421b62e424527f057504530080873f5deb6` →
`2a3625ea672f0c6a2e0278101281c779aee9243203f2f3614810e88ec182168f`.
Every other source, binary, build, compiler, and options proof remained equal. Thresholds, timing math, and acceptance did not change.
Parent helper checks passed 10/10 in 0.039 seconds and 21/21 in 8.067 seconds, 9.67 seconds combined.
Those pure checks do not establish candidate performance.
Native-3 one-sample versus Native-4 three-sample differences are not isolated percentage gains.
Evidence: [candidate-4-diagnostic-observation.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/candidate-4-diagnostic-observation.json)
and [complete diagnostic capture-ledger.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-diagnostic-20261008T135301Z-c7605595a34c424bb18e7cc28942e2d9/capture-ledger.json).
Ledger SHA-256: `cc0ded0bf9be77c7045cecc86f965c93074abcb9ba12ae4e2994e1fd7aa0ad0f`.

#### Candidate 4 large-stack profiles: diagnostic only

Eight fresh profiles and 48 offline reports completed with exit zero in 134.43 seconds.
Every profile and report was valid, had unchanged source/binary inputs, and exited zero.
Benchmark stderr was empty, with no retry.
These profiles use `-m64`, not candidate 3's `-m8`, with the same frequency and 16-KiB stack size.
The table records all eight large insert/map/load/merge profiles.
Self percentages below use sampled-IP period weights, not raw count percentages.
Symbol names omit module paths and anonymous suffixes.

| Workload, large | Engine | Samples | Unframed | Buffer lost samples | `LOST_SAMPLES` records | Selected native self symbols, period-weight % |
|---|---|---:|---:|---:|---:|---|
| `insert-growth` | Native | 98 | 61 | 0 | 0 | `malloc` 10.814%, `_int_malloc` 9.655%, `c_allocator_impl.alloc` 7.545% |
| `insert-growth` | Rust | 41 | 0 | 0 | 0 | — |
| `map-updates` | Native | 492 | 381 | 0 | 0 | `WireRle.LoadCursor.next` 6.148%, `_int_malloc` 5.995%, `malloc` 5.210%, `Decoder.enterRun` 5.114%, `readUnsigned` 4.923% |
| `map-updates` | Rust | 155 | 0 | 0 | 0 | — |
| `load` | Native | 108 | 75 | 0 | 0 | `cfree` 9.603%, `_int_malloc` 8.127%, `WireRle.LoadCursor.nextLiteral` 7.066%, `readUnsigned` 6.982% |
| `load` | Rust | 47 | 0 | 0 | 0 | — |
| `merge` | Native | 86 | 61 | 0 | 0 | `WireRle.LoadCursor.next` 9.705%, `cfree` 8.636%, `memcpyFast` 6.811% |
| `merge` | Rust | 42 | 0 | 0 | 0 | — |

No recorded buffer/final-counter loss does not prove zero unreported loss, complete unwinding, or resolved native callers.
Whole-process `cycles:u` sampling at 199 Hz with 16-KiB stacks includes setup, allocation/free, verification, and disposal.
It does not identify subject phases.
Column staging clones index metadata and copies slab descriptors, not decoded rows in that path ([column.zig:4995–5020](../src/hexane/column.zig#L4995-L5020)).
`Tree.clone` copies arena buffers and metadata ([btree.zig:269–299](../src/hexane/btree.zig#L269-L299)).
Untouched slab bytes remain borrowed. First mutation copies the touched slab's encoded bytes ([column.zig:4718–4725](../src/hexane/column.zig#L4718-L4725)).
RLE splice retains encoded prefix/middle/suffix handling ([slab.zig:536–580](../src/hexane/slab.zig#L536-L580)).
Prefix-base rebuilding uses retained tree weights ([column.zig:7247–7277](../src/hexane/column.zig#L7247-L7277)).
Exception: signed tracked-prefix validation can scan suffix bytes when interval totals change
([column.zig:7153–7165](../src/hexane/column.zig#L7153-L7165), [7221–7238](../src/hexane/column.zig#L7221-L7238)).
There is no unconditional “no suffix decoding” claim.
These observations are not a source-phase attribution or a new optimization result.
Source stayed frozen through both profile groups. The capture freeze is complete, with no source fix or next optimization change yet.
Evidence: [candidate-4-profile-observation.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/candidate-4-profile-observation.json)
and [sanitized profile-ledger.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-candidate-profiles-20261008T135954Z-71560779dbba4212af4247d3e1c4c1a5/profile-ledger.json).
All final acceptance cells and full current-source gates remain pending.

#### Candidate 4 remaining-path profiles: diagnostic only

The additional eight cells completed 16 fresh profiles and 96 offline reports, exit zero in 317.75 seconds.
All 16 profiles were valid. Profile/report processes exited zero, inputs stayed equal, and no retries occurred.
Benchmark stderr was empty.
The original eight profiles were not rerun.
Candidate 4 now has 24 profiles and 144 offline reports, with independent receipts for the two groups.
Its full 80-file content and provenance still matched the snapshot before its build.
The same serial CPU-0/runner-2, `-m64`, 199-Hz `cycles:u`, 16-KiB DWARF setup applied.

| Additional cell | Size | Native samples/unframed | Rust samples/unframed | Buffer lost samples / `LOST_SAMPLES` records, each engine | Native signed leaf self %, next / nextLiteral / readSigned (sum) |
|---|---|---:|---:|---:|---:|
| `list-range-batch` | small | 9/3 | 6/0 | 0/0 | — |
| `text-edits` | small | 31/23 | 18/0 | 0/0 | 21.341 / 12.588 / 15.992 (49.921) |
| `text-edits` | large | 100/78 | 40/0 | 0/0 | 9.747 / 12.209 / 9.487 (31.443) |
| `save` | large | 110/69 | 46/0 | 0/0 | — |
| `sync-roundtrip` | large | 448/369 | 352/0 | 0/0 | — |
| `diff-first` | large | 202/161 | 71/0 | 0/0 | — |
| `diff-repeat` | large | 214/177 | 79/0 | 0/0 | — |
| `diff-subtree` | large | 228/174 | 75/0 | 0/0 | — |

Signed leaf names mean `WireRle(i64, ...).LoadCursor.next`, `nextLiteral`, and `leb128.readSigned`.
Percentages are whole-process sampled-IP period weights. They do not prove subject-phase costs, callers, or a speed result.
Unsigned decode and allocation also remain sampled in whole-process cold/cached diff profiles.
The small batch profile has too few samples for quantitative priority claims.
Recorded loss counts are zero, but native unwinding remains incomplete. Unreported loss and unresolved callers remain possible.

Read-only native source inspection supplies mechanism limits, not profile phase attribution:

- `LoadCursor` first finds a literal's end, then walks its items from the start ([column.zig:1333–1388](../src/hexane/column.zig#L1333-L1388)).
- `Decoder.nth` continues from its current position. It does not rewind each literal item ([rle.zig:532–585](../src/hexane/rle.zig#L532-L585)).
- Budget scans occur before rewriting ([column.zig:6757–6765](../src/hexane/column.zig#L6757-L6765)), during spill-bound calculation
  ([6937–6945](../src/hexane/column.zig#L6937-L6945)), and in the split guard ([slab.zig:1316–1335](../src/hexane/slab.zig#L1316-L1335)).
  These are source paths, not measured call counts.

No external Rust algorithm comparison or predicted optimization gain is claimed.
No new benchmark medians or ≤2 acceptance result come from these profiles.
Source remains unchanged since candidate 4's build. Full current-source gates and all 26 final acceptance cells remain pending.
Evidence: [candidate-4-remaining-path-profile-observation.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/candidate-4-remaining-path-profile-observation.json)
and [independent sanitized profile-ledger.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/evidence/matched-loop-candidate-profiles-20261008T141517Z-99ec829c3f164f22b40bc03092430b3d/profile-ledger.json).
Ledger SHA-256: `12b510b2bcce0a5ef3e91a7bd04121faae36193b1653ef38a1cdb9566896e6c7`.





#### Finite LEB kernel evidence

Ten variants passed 4,014,848 independent differential cases each in Debug, ReleaseSafe, and ReleaseFast.
The balanced ledger retains 600 timing rows: ten samples × six streams × ten variants.
Each variant occupied every order position once per stream, after two untimed warmups per sample.
Checksums, raw samples, minima, maxima, and timing tails remain in the ledger.
The table gives ReleaseFast/native medians [minimum–maximum] in milliseconds, not Automerge workload timings.

| Stream | Checked production ms [min–max] | Original generic scalar ms [min–max] | Production/original median |
|---|---:|---:|---:|
| Short unsigned | 50.368 [48.634–93.707] | 82.477 [80.561–122.825] | 0.611 |
| Short signed | 55.404 [51.355–94.454] | 86.351 [79.037–184.225] | 0.642 |
| Mixed unsigned | 90.415 [87.078–96.511] | 109.178 [108.232–110.994] | 0.828 |
| Mixed signed | 113.669 [107.325–120.662] | 120.006 [112.778–127.134] | 0.947 |
| Long unsigned | 134.408 [124.286–175.539] | 156.362 [144.323–389.221] | 0.860 |
| Long signed | 121.735 [116.014–135.921] | 185.280 [166.638–197.782] | 0.657 |

Checked scalar production was best on both short streams.
Unconditional SIMD lost on short inputs, and no SIMD variant was merged from synthetic-only evidence.
Actual ReleaseSafe and ReleaseFast codegen aliases the bounded safe/off exports.
Timing differences do not establish an annotation benefit, and production has no new `@setRuntimeSafety(false)` annotation.
This finite experiment gives no end-to-end Native/Rust speed claim.
The shared host had no exclusive CPU or frequency isolation.
Evidence: [kernel-order-balanced-ledger.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/kernel-order-balanced-ledger.json)
and [kernel-codegen-observation.json](file:///tmp/tmp/zautomerge-perf-loop-tYJOfU/kernel-codegen-observation.json).

### Build and run one cell

A cell is one workload and one size.
Each sample starts a fresh driver process.
The matched binaries require exactly `WORKLOAD small|large`.
They do not accept the legacy `--full`, `--repeat`, or `--list` flags.

Use the scratch and cache setup from section 1.
The Zig build step forwards arguments and defaults to `insert-growth small` when none are supplied:

```sh
zig build bench-matched -Doptimize=ReleaseFast -Dcpu=native \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    -- insert-growth small
```

This builds and runs one cell.
It does not install the matched executable.
Do not put the build command inside a measured process.
Build the native driver once for direct measurements:

```sh
printf '%s\n' \
    'pub const check_slow_paths = false;' \
    'pub const package_name = "zautomerge";' \
    'pub const package_version = "0.0.0";' \
    'pub const text_indexing = "unicode_code_point";' \
    > "$BENCH_ROOT/build_options.zig"
zig build-exe \
    -O ReleaseFast -mcpu=native -lc \
    --dep zautomerge \
    -Mroot=bench/matched_bench.zig \
    --dep build_options \
    -Mzautomerge=src/root.zig \
    -Mbuild_options="$BENCH_ROOT/build_options.zig" \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    -femit-bin="$BENCH_ROOT/zautomerge-matched-bench"

RUSTFLAGS="-C target-cpu=native" cargo build --release --locked \
    --manifest-path tools/oracle/Cargo.toml --bin matched_bench
```

The Rust executable is `$CARGO_TARGET_DIR/release/matched_bench`.
The oracle manifest sets `default-run = "zautomerge-oracle"`.
Always select `--bin matched_bench` for benchmark Cargo commands:

```sh
RUSTFLAGS="-C target-cpu=native" cargo run --release --locked \
    --manifest-path tools/oracle/Cargo.toml --bin matched_bench \
    -- insert-growth small
```

Cargo builds only through the local oracle manifest.
Its path dependencies refer to the pinned read-only reference.
Keep Cargo output and caches in the local paths from section 1.

Capture one sample from each already-built driver:

```sh
export BENCH_CPU="${BENCH_CPU:-0}"
mkdir -p "$BENCH_ROOT/evidence"
taskset -c "$BENCH_CPU" perf stat -x, -e instructions:u,cycles:u \
    -o "$BENCH_ROOT/evidence/insert-growth.small.zig.1.stat" -- \
    "$BENCH_ROOT/zautomerge-matched-bench" insert-growth small \
    > "$BENCH_ROOT/evidence/insert-growth.small.zig.1.json" \
    2> "$BENCH_ROOT/evidence/insert-growth.small.zig.1.stderr"
zig_status=$?
printf '%s\n' "$zig_status" > "$BENCH_ROOT/evidence/insert-growth.small.zig.1.exit"

taskset -c "$BENCH_CPU" perf stat -x, -e instructions:u,cycles:u \
    -o "$BENCH_ROOT/evidence/insert-growth.small.rust.1.stat" -- \
    "$CARGO_TARGET_DIR/release/matched_bench" insert-growth small \
    > "$BENCH_ROOT/evidence/insert-growth.small.rust.1.json" \
    2> "$BENCH_ROOT/evidence/insert-growth.small.rust.1.stderr"
rust_status=$?
printf '%s\n' "$rust_status" > "$BENCH_ROOT/evidence/insert-growth.small.rust.1.exit"
```

These commands measure one cell, not the full matrix.
Use distinct files for every workload, size, engine, and sample.
Check each exit status before accepting its JSON or counter result.

### Workloads and sizes

The matrix has 13 workloads and two sizes, or 26 cells per engine.
The `n` field has the meaning in this table.

| Workload | Small `n` | Large `n` | Work |
|---|---:|---:|---|
| `insert-growth` | 2,500 | 10,000 | Append integers `0..n-1` to root list `l`, one transaction and commit |
| `list-range-seq` | 2,500 | 10,000 | Build the same list with sequential inserts, then consume one complete range walk |
| `list-range-batch` | 2,500 | 10,000 | Build the same list with one splice, then consume one complete range walk |
| `text-edits` | 1,024 | 4,096 | Insert `.` at deterministic positions in 4,096 initial ASCII `a` characters, one commit per edit |
| `map-updates` | 2,500 | 10,000 | Replace sorted map values `0` with `i+1`, one update transaction and commit |
| `save` | 2,500 | 10,000 | Save a sorted map with values `i` |
| `load` | 2,500 | 10,000 | Load that map from save bytes prepared before the load timer |
| `merge` | 1,024 | 4,096 | Merge two branches with `n` distinct keys each and one shared base key |
| `sync-roundtrip` | 200 | 400 | Insert `n` values per round, for 24/48 rounds, withhold peer acknowledgments |
| `diff-first` | 1,024 | 4,096 | One unprimed recursive root diff over `n` changed map keys |
| `diff-repeat` | 1,024 | 4,096 | Prime one root diff, then request the same recursive diff 32 times |
| `diff-rotate` | 1,024 | 4,096 | Alternate forward and reverse recursive root diffs 32 times, without priming |
| `diff-subtree` | 1,024 | 4,096 | Prime one nonrecursive map diff, then request that subtree diff 32 times |

The first nine workloads use explicit transactions.
Both engines use identical actor bytes, timestamp zero, absent messages, and absent authors.
The list builders use actor `bench-list-width-fixture`.
They must produce the same logical change, not merely the same visible values.
The text generator starts at 98765 and applies xorshift shifts `<<13`, `>>7`, and `<<17`.
Edit `i` inserts at `state % (4096+i)`.
The verifier independently replays those edits.

The sync handshake is peer hello, local snapshot, then peer acknowledgment.
Each round commits every inserted item separately before generation and peer receipt.
The peer withholds its next acknowledgment until all rounds finish.
Final verification requires equal peer/local heads and a quiet local generator.

The four diff fixtures use `AutoCommit` at a stable address.
Actor `bench-diff-matrix` creates root map `m` with sorted keys `k00000` onward.
The first commit writes zero values.
The second commit writes `i+1` values.
The fixture stores both head sets and verifies both commits' metadata.
The subtree fixture is flat and nonrecursive.
It does not demonstrate pruning of deep nested objects.

### JSON and full correctness acceptance

A successful driver writes one JSON record to stdout.
Errors go to stderr and invalidate the sample.

| Field | Meaning |
|---|---|
| `implementation` | `zig` or `rust` |
| `workload`, `size`, `n` | Exact cell identity and cardinality |
| `phases_ns` | Applicable named phase wall times, in integer nanoseconds |
| `checksum` | Deterministic 16-digit lowercase checksum |
| `heads` | Sorted, full 64-digit lowercase change hashes |
| `verified` | `true` only after the workload's checks succeed |

Require `verified: true` and exact workload, size, `n`, checksum, and heads for every cell in both engines.
Do not compare only checksums.
Each driver checks independent expected values, scalar types, object types, conflicts, counts, and full change metadata.
List verification also checks indices, width one, and exact traversal order.
Map verification checks the complete sorted key/value set.
Save/load verification compares reloaded materialized documents and heads.
Compressed save bytes need not match because DEFLATE output can differ.

Every diff result must contain exactly `n` sorted `put_map` actions.
The verifier checks object identity, path, key, scalar type, value, conflict flag, and producing operation identity.
Forward values are `i+1`.
Reverse values are zero.
Root and subtree patches carry the global path `(ROOT, Key("m"))`.
The priming result does not enter the timed-call checksum.
Verification checks every timed result, not only the final one.

Checksum folding starts at zero and wraps `state * 0x9E3779B97F4A7C15 + value`.
Byte strings mix their length before their bytes.
Checksums supplement the full verifier.
They do not replace it.

### Phase scope and disposal

`setup` includes fixtures, keys, deterministic edit positions, and any cache prime.
`mutation` and `commit` remain separate.
Repeated edit workloads sum those phases over identical transaction boundaries in both engines.
Manual commit timers include owned commit-result and closed-transaction disposal.
Rust consumes the transaction and drops its commit result in the corresponding timer.
The legacy `insert-loop` driver instead records those releases in teardown.
Do not combine these different timer contracts.

`read` consumes the full iterator result.
Independent materialization, history checks, and checksum verification remain outside that read timer.
`save`, `load`, and `merge` time only their named library operations.
The merge result's owned head array is released after the merge timer.
`insert-growth` records save/reload in `verify`, not separate save/load phases.
Sync times accumulated mutation, commit, generation, and receipt separately.
Native receipt consumes the sync message on success and error.
Only an unsent message remains the caller's disposal responsibility.

`diff` times the library diff and returned patch-batch construction.
Patch checks and disposal belong to `verify` in both engines.
A prime and its disposal belong to `setup`.
The matched drivers do not emit a `teardown` phase.
Whole-process counters still include document destruction, deferred result release, and output.

### Fair measurement and retained failures

The frozen baseline used three fresh samples per engine and cell, serially: 156 retained process results.
The current final acceptance requires five fresh samples per engine and cell, or 260 retained process results.
Balance engine order across the series.
Use the same CPU for both engines.
For the CPU 0 series, keep our compilers, tests, and other jobs off CPUs 0 and 16.
CPU 16 is that host's SMT sibling of CPU 0.
Record host load and frequency-control limits.
Do not present CPU 2/3 smoke runs as a matched timing comparison.

Record source and binary SHA-256, toolchain versions, build commands, allocator choice, CPU affinity, and raw exit status.
Keep raw JSON, stderr, counters, and all exclusions.
Report median, minimum, and maximum for each applicable phase and each whole-process counter.
Require 100% counter scheduling coverage for accepted instruction and cycle rows.
Do not silently scale a partial count.
A failed verifier is not a timing sample.
Stop the series and repair its cause without weakening the verifier.

External `instructions:u` and `cycles:u` count the whole user-space process.
They include startup, fixture construction, verification, disposal, and output.
They are not mutation-only, read-only, or diff-only counters.
Phase wall times can change with host scheduling and CPU frequency.
Retired instructions do not prove a wall-time speedup.

The legacy default driver retains its 90% list subject-share guard and 2.0× insert-growth ceiling.
The current native capture in section 12 refused the default list result at 50.39% subject share.
That refusal is not a successful full legacy gate.
The opt-in region counter can produce a valid read-region result without accepting whole-process traversal attribution.
It does not lower or replace the default 90% threshold.
The matched list fixtures have a different measurement contract and do not bypass that legacy refusal.

### Final matched results

These final results belong to the frozen pre-loop baseline, not the new source candidate.
“Final” names the historical capture and its evidence anchors, not current acceptance.

The series ran three fresh processes per engine and cell, serially on CPU 0.
The runner used CPU 2 and did not use CPU 16.
Each engine ran first in 39 of the 78 pairs.
All 156 processes exited zero with empty stderr.
All 26 cells had six valid samples and three matching pairs.
Every pair matched `n`, checksum, complete heads, phase names, and `verified`.
All independent materialization, conflict, metadata, and patch verifiers passed.
All 312 instruction/cycle records had 100% scheduling coverage.
The series had no spawn errors, counter errors, mismatches, retries, or discarded samples.

The evidence directory is
`/tmp/tmp/zautomerge-parity-tmKdil/evidence/matched-final-20261008T075031Z-4c9545c5`.
`matched-final-ledger.json` contains all samples, phase statistics, counters, commands, and fingerprints.
Its SHA-256 is `0cf553ae68156376672c65ef9dc4b74597d16f3f98ae92a6ad912d7953cba63c`.
The `raw/` directory retains every stdout, stderr, and perf record.

| Captured input | SHA-256 |
|---|---|
| Native executable | `2fc5d5bfa94e655e44268f910cdca920827c242a2c3c6905739551ed1f08c59f` |
| Rust executable | `2c70729dc77ab76500ff8f501dfb1a6e4f12cfb4887849a76d4e5e3c271f7329` |
| Native matched driver | `0de008fd704ccb53f7b49b1e5be7263fc65cf31c4b0c6ca59d2d4180b5b69f8e` |
| Rust matched driver | `58103ba3affc39450f99f8b8a83c3282905fdcdf935090392db74a2996e40e68` |
| Matrix's serialized native source/build manifest | `bf5d41912549d696c3983306669d1dd1f681356eafbf66ad8b4462abcc62f13f` |

The before/after binaries and source inputs were unchanged.
All 80 native source-file hashes match the preceding complete smoke capture.
The matrix and smoke manifests use different serialization formats.
Their aggregate manifest hashes are not interchangeable.
The current Cargo manifest includes the `default-run` fix.
It is recorded separately from the manifest used to build the frozen Rust executable.

#### All 26 cells

Each phase entry is the median in milliseconds, followed by `[minimum–maximum]` from three fresh processes.
The phase column selects the subject shown for that workload.
Mutation rows exclude the separate commit phase.
List rows show traversal, not list construction.
Sync rows show generation, not receipt or the whole exchange.
Diff repeat/subtree rows sum 32 calls, not one call.
The ledger retains all other phases and their three samples.

Every ratio below is **Native median / Rust median**.
For phase time, greater than one means native is slower.
Less than one means only that named native phase is faster.
Counter ratios compare whole-process user-space counts, not that phase's instructions or cycles.
Greater than one means native retires more instructions or consumes more counted cycles.
The table does not attribute these counters to its subject phase.

| Workload | Size | Subject phase | Native phase ms [min–max] | Rust phase ms [min–max] | Phase Native/Rust | Process instructions Native/Rust | Process cycles Native/Rust |
|---|---|---|---:|---:|---:|---:|---:|
| `insert-growth` | small | `mutation` | 124.899224 [123.165452–145.457694] | 39.786837 [33.992213–46.404535] | 3.14× | 3.56× | 3.10× |
| `insert-growth` | large | `mutation` | 713.623640 [695.861315–726.570724] | 159.461342 [151.642606–163.366231] | 4.48× | 5.42× | 4.13× |
| `list-range-seq` | small | `read` | 2.539415 [2.326630–2.672629] | 0.480036 [0.461821–0.489534] | 5.29× | 3.75× | 3.06× |
| `list-range-seq` | large | `read` | 9.102186 [8.749847–10.960887] | 1.832181 [1.816817–2.116161] | 4.97× | 5.76× | 4.37× |
| `list-range-batch` | small | `read` | 3.040352 [2.397132–3.858252] | 0.414515 [0.387641–0.540306] | 7.33× | 2.39× | 1.99× |
| `list-range-batch` | large | `read` | 9.453302 [9.191986–11.163302] | 1.520111 [1.439557–1.810146] | 6.22× | 2.44× | 2.02× |
| `text-edits` | small | `mutation` | 152.830758 [151.431861–158.592274] | 27.303533 [26.578390–27.366931] | 5.60× | 6.13× | 4.26× |
| `text-edits` | large | `mutation` | 1158.464465 [1148.599377–1161.847982] | 106.500426 [103.507460–108.449776] | 10.88× | 11.51× | 8.42× |
| `map-updates` | small | `mutation` | 5559.698123 [5499.345111–5809.622426] | 130.367138 [123.398538–135.023145] | 42.65× | 45.78× | 38.46× |
| `map-updates` | large | `mutation` | 78811.225666 [78108.495409–81009.886440] | 576.238073 [546.484358–581.378556] | 136.77× | 175.13× | 135.77× |
| `save` | small | `save` | 1.635999 [1.398094–1.666187] | 0.798655 [0.539751–0.873329] | 2.05× | 33.91× | 30.38× |
| `save` | large | `save` | 4.357149 [4.320933–5.207881] | 1.763469 [1.750617–1.777867] | 2.47× | 126.54× | 109.85× |
| `load` | small | `load` | 24.098992 [23.892353–24.499604] | 3.192965 [3.187771–3.689656] | 7.55× | 33.91× | 27.66× |
| `load` | large | `load` | 336.029228 [323.735077–337.160718] | 12.426966 [11.782999–12.543041] | 27.04× | 126.54× | 108.13× |
| `merge` | small | `merge` | 12.655026 [12.423560–12.738699] | 3.503827 [3.013120–3.606033] | 3.61× | 15.61× | 12.87× |
| `merge` | large | `merge` | 172.141663 [171.313503–172.422760] | 13.502821 [10.466178–13.610845] | 12.75× | 55.30× | 47.99× |
| `sync-roundtrip` | small | `generate` | 4141.027431 [4078.268767–4166.920815] | 83.862400 [83.645210–97.087810] | 49.38× | 16.19× | 15.07× |
| `sync-roundtrip` | large | `generate` | 60458.787376 [59405.074498–61487.453254] | 772.415285 [708.724012–785.007246] | 78.27× | 44.29× | 37.59× |
| `diff-first` | small | `diff` | 31.825313 [26.645159–32.265793] | 2.617116 [2.609404–2.639501] | 12.16× | 19.79× | 16.27× |
| `diff-first` | large | `diff` | 420.005530 [355.856269–498.554560] | 10.625184 [8.414683–10.695965] | 39.53× | 71.07× | 54.86× |
| `diff-repeat` | small | `diff` | 5.827983 [4.919019–6.004579] | 8.262747 [7.363517–11.215829] | 0.71× | 15.58× | 14.34× |
| `diff-repeat` | large | `diff` | 20.912035 [20.189559–23.484507] | 47.223044 [42.345757–47.256321] | 0.44× | 56.19× | 43.49× |
| `diff-rotate` | small | `diff` | 761.916763 [586.050160–791.845949] | 80.288381 [61.903695–81.528290] | 9.49× | 14.66× | 11.62× |
| `diff-rotate` | large | `diff` | 14312.659378 [13017.054676–14601.948454] | 312.966769 [245.199042–326.080062] | 45.73× | 56.04× | 47.40× |
| `diff-subtree` | small | `diff` | 5.321337 [5.015276–5.441386] | 10.434326 [8.279257–11.566099] | 0.51× | 15.58× | 13.95× |
| `diff-subtree` | large | `diff` | 20.604399 [19.719016–21.190371] | 36.624210 [33.752540–44.587222] | 0.56× | 56.18× | 50.28× |

#### Interpretation and limits

The large `map-updates` mutation median is 136.77× Rust's median.
Large sync generation is 78.27× Rust's median.
These frozen gaps precede the current optimization-loop source changes.
There is no overall performance-parity claim.

Large cached `diff-repeat` and `diff-subtree` phases are faster than Rust's corresponding phases.
They are not whole-process wins.
Native large save/load setup medians are 20.942 and 21.104 seconds.
Native large merge setup is 7.440 seconds.
Native large diff setup medians range from 16.959 to 18.197 seconds.
Those fixture costs enter the process counters, not the named save/load/merge/diff timers.

Large `diff-repeat` launched-process wall medians are 17.459630 seconds native and 0.587390 seconds Rust.
Large `diff-subtree` wall medians are 18.677892 seconds native and 0.573027 seconds Rust.
These executor wall intervals include launch, wrapper, and perf overhead.
Do not treat them as phase clocks.

Large sync receipt has medians of 396.632744 ms native and 446.336790 ms Rust.
Native receipt is faster for that phase only.
It does not offset the generation gap or establish faster synchronization.

The host used the `powersave` governor without fixed-frequency or isolation control.
Before/after load averages were 11.16/12.84/13.32 and 15.43/14.59/14.04.
The three-sample ranges expose timing variation.
They are observations, not confidence intervals or a statistical guarantee.
Instruction counts are less sensitive to scheduling but still cover the complete process.
Cycles also depend on frequency and execution conditions.

The frozen native-before/after RLE result is a different experiment.
Its 60.3% large-insert instruction decrease is not a native-versus-Rust improvement.
It does not remove the frozen baseline parity gaps.
Frozen native-only diagnostic profiles appear in section 12.
Historical tables retain their original source snapshots and measurement limits.

---

## 12. Frozen native guard and profile capture — 2026-10-08

This capture used the legacy driver after the public-API cutover, before the current optimization-loop changes.
It is frozen native-only diagnostic evidence, not current-candidate proof or a matched Rust comparison.
The authoritative verification checkpoint is [docs/STATUS.md](../docs/STATUS.md).
The correctness gate and the benchmark's workload guards have different acceptance conditions.

### Source and capture identity

The legacy executable SHA-256 is `4edee320c1c45482c67fc1e273478637497de94f5868f75a9abc1e39e884a3a7`.
The driver SHA-256 is `5e25c8fea13104bc0337ade69839185e0a114efda8593eafba61d83afdd987b0`.
The external build-options SHA-256 is `594bd7f110c3e06b57701b8ffd37df6b5b22c78f28cfba53c99b59dd77eb4663`.
Before/after manifests contain the same 85 SHA-256 entries, including all 80 `src/**/*.zig` files.
No source, build, test, or formatter changes occurred during capture.

The evidence directory is
`/tmp/tmp/zautomerge-parity-tmKdil/evidence/native-profile-20261008-WUTP4o`.
`capture-ledger.json` records commands, statuses, checksums, counter scopes, and capture defects.
It references the raw stdout, stderr, profile data, host snapshots, and hash manifests.
These files identify this capture, not a future rebuild.

The host was an Intel Xeon Gold 6134, Linux 6.12.0-160000.38-default, with 32 logical CPUs.
The runner used CPU 2.
Measured driver processes used CPU 0.
The runner and measured processes did not use CPU 16.
The governor was `powersave`, without fixed-frequency control.
Before/after load averages were 15.95/17.97/16.18 and 13.32/15.50/15.64.
Native verification compilers ran concurrently on CPUs 2–15 and 18–31.
Pressure interfaces were unavailable.
These conditions permit shared-host noise even without CPU 0/16 placement overlap.

### Native workload guard outcomes

All eleven default workloads have retained records.
Ten unique workloads have accepted exit-zero records and `LEAKS 0`.
The default `list-width` workload refused attribution.
The full insert workload also passed its unchanged guard.
These are individual checks, not a successful all-eleven aggregate run.

| Workload and size | Observed guard | Exit | Checksum / leak result |
|---|---|---:|---|
| `list-width`, default | 101,811,596 / 202,034,890 ns = 50.39%, below the unchanged 90% floor | 1 | No `BENCH`, checksum, or leak footer |
| `insert-loop`, default | 2,500/10,000 inserts, per-insert growth 0.212×, ceiling 2.0× | 0 | `6f1c9a0a37fe708`, `LEAKS 0` |
| `insert-loop`, full | 5,000/20,000 inserts, per-insert growth 0.257×, ceiling 2.0× | 0 | `58a37e6296ef960f`, `LEAKS 0` |

The original `hash-for-opid` capture lost its child exit marker because of a wrapper defect.
Its `BENCH`, checksum, and leak-success records remain unchanged.
A separate sixteenth attempt captured exit 0, checksum `95791aa42f3360a0`, and `LEAKS 0`.
That attempt proves status only.
Do not infer the missing original exit status or combine the two timings.

The insert ratios are accepted guard observations from single processes.
They are not speedup estimates or proof of insertion complexity.
The small arm runs first, and shared-host scheduling can affect the arms differently.

### Direct list read-region counters

Both direct region processes exited zero and reported `LEAKS 0`.
Their positive enabled and running durations were equal.
Each counter therefore had complete scheduling coverage.

| Size | Element visits | Read ns | Region instructions | Enabled ns = running ns | Checksum |
|---|---:|---:|---:|---:|---|
| default | 100,000 | 105,964,142 | 568,465,158 | 105,949,003 | `e41686857f8055e0` |
| full | 200,000 | 216,558,707 | 1,140,432,989 | 216,223,095 | `2485b42219224460` |

These counters measure the complete read-list region described in section 7.
They do not count the whole process or `elementWidth` alone.
They do not override the normal default workload's 90% guard refusal.
One process per size does not establish a before/after speedup.

### Frozen insertion profile

The capture profiled the exact legacy executable identified above.
It used `cycles:u`, frequency 199 Hz, DWARF stacks of 2,048 bytes, eight mmap pages, and `-N`.
The measured process used CPU 0 and default `insert-loop` sizes with `--repeat 1`.
It exited zero, returned checksum `6f1c9a0a37fe708`, and reported `LEAKS 0`.
Its growth guard reported 0.199×, below the unchanged 2.0× ceiling.

`perf report --no-children --sort=symbol -n` reported 318 samples and zero lost samples.
The approximate sampled event count was 3,105,773,775 cycles.
The sample interval was 1,583.105 ms.
Self percentages use sampled event periods, not each row's raw sample count divided by 318.

| Self symbol | Reported self share | Samples |
|---|---:|---:|
| `DebugAllocator.free` | 16.37% | 50 |
| `DebugAllocator.alloc` | 13.50% | 42 |
| `RunWriter(u64,false,leb128).append` | 9.54% | 23 |
| `BoolCodec(leb128).wireEncode` | 5.53% | 11 |
| `WireRle(u64,false,false,leb128).wireEncode` | 5.12% | 11 |
| `compiler_rt.memcpy.memcpyFast` | 4.27% | 20 |
| Unknown address `0xffffffffbd601280`, displayed as `[k]` | 4.21% | 31 |
| `BoolCodec(leb128).wireRangeFromSegs` | 4.05% | 9 |
| `leb128.readSigned` | 2.60% | 6 |
| `_int_malloc` | 2.49% | 7 |

The profile header sets `exclude_kernel=1`.
The unknown `[k]` label is not evidence of measured kernel cost.
The legacy driver uses a `DebugAllocator` leak arbiter even in ReleaseFast.
The matched native driver instead uses `c_allocator`.
Thus the allocator entries include legacy-driver accounting absent from the matched allocator contract.

This profile locates remaining work in the current captured legacy process.
It does not isolate a library-only cost or establish causality.
Do not compare its self percentages with historical percentages as a speedup.
Do not treat it as the final matched Rust timing or counter series.


### Matched CAllocator profiles after the final series

Two additional diagnostic captures used the matched native driver, not the legacy DebugAllocator driver.
They followed the complete 156-process matrix and completed native verification gates.
Our verification compilers were no longer active.
They do not replace matrix samples or change its medians.

Both captures used native executable SHA-256 `2fc5d5bfa94e655e44268f910cdca920827c242a2c3c6905739551ed1f08c59f`.
The allocator was `std.heap.c_allocator`.
Both driver processes ran serially on CPU 0, with the runner on CPU 2 and no CPU 16 use.
Before/after binary, driver, build-options, and all 80 native source hashes were unchanged.
Those hashes match the final matrix inputs.

Both `perf record` commands exited zero.
Each driver returned one verified JSON record with the expected schema and phase names.
`map-updates large` used `n=10000`, checksum `92afdc9d3e4c5568`, and the exact final-matrix head.
`sync-roundtrip large` used `n=400`, checksum `8a2bb44da2e58e00`, and the exact final-matrix head.
The profiled phase clocks remain diagnostic output, not additional timing samples.

The evidence directory is
`/tmp/tmp/zautomerge-parity-tmKdil/evidence/matched-diagnostic-20261008-vuHQOy`.
Its `capture-ledger.json` records commands, parity checks, raw files, reports, and before/after hashes.
The captures used `cycles:u`, 199 Hz, `-N`, eight mmap pages, and `--call-graph dwarf,2048`.
The self reports used `perf report --stdio --no-children --sort=symbol -n`.

| Workload | Perf-reported samples | Lost samples | Approximate sampled cycle count | Raw profile / self report |
|---|---:|---:|---:|---|
| `map-updates large` | 19K | 0 | 339,137,404,357 | `map-updates-large.profile.data` / `map-updates-large.self-report.stdout` |
| `sync-roundtrip large` | 12K | 0 | 215,909,563,893 | `sync-roundtrip-large.profile.data` / `sync-roundtrip-large.self-report.stdout` |

`19K` and `12K` are perf's rounded totals, not exact integer sample counts.
Self shares use sampled cycle periods.
The following tables retain each report's top ten symbols.
Type names omit module prefixes only.

| `map-updates large` self symbol | Reported self share | Samples |
|---|---:|---:|
| `RleGeneric(u32,false,false,leb128).Decoder.nextRunMax` | 14.03% | 2,685 |
| `Column(u64,MetaPrefixCodec).runningAt` | 10.61% | 2,024 |
| `leb128.readUnsigned` | 10.08% | 1,942 |
| `Column(?u32,RleBase(u32,true,false,leb128)).Iterator.next` | 6.64% | 1,284 |
| `leb128.readSigned` | 4.75% | 920 |
| `Column(u32,PrefixBase(leb128,u32)).runningAt` | 4.29% | 826 |
| `Column(u32,DeltaBase(leb128,u32)).Iterator.skipRows` | 2.69% | 517 |
| `DeltaBase(leb128,?u32).weightOf` | 2.64% | 508 |
| `Column(u32,PrefixBase(leb128,u32)).settle` | 2.32% | 444 |
| `Column(u32,PrefixBase(leb128,u32)).rebuildAggs` | 2.10% | 400 |

| `sync-roundtrip large` self symbol | Reported self share | Samples |
|---|---:|---:|
| `Column(?u32,RleBase(u32,true,false,leb128)).Iterator.next` | 21.74% | 2,672 |
| `OpIter(ChangeOp).next` | 12.12% | 1,499 |
| `doc.collectChanges` | 10.75% | 1,335 |
| `ValueIter.tryNext` | 5.90% | 728 |
| `ActionIter.tryNext` | 5.75% | 708 |
| `opset.types.fromRaw` | 5.58% | 689 |
| `Column(?u32,DeltaBase(leb128,?u32)).Iterator.next` | 4.81% | 593 |
| `Column(u32,DeltaBase(leb128,u32)).Iterator.next` | 4.81% | 593 |
| `Column(u32,PrefixBase(leb128,u32)).Iterator.next` | 4.29% | 527 |
| `Column(u32,RleBase(u32,false,false,leb128)).Iterator.next` | 3.55% | 437 |

These are whole-process user-cycle profiles.
They include setup, mutation, commit, verification, disposal, and output, plus generation and receipt where applicable.
Do not assign the displayed percentages to mutation or generation alone.
Do not transfer the earlier legacy DebugAllocator percentages to these CAllocator captures.

The raw DWARF stack capture and focused reports remain available.
However, parent/callchain reports returned `[other]` without resolved caller names.
They do not establish causal parent paths.
The ledger references `*.focused-callchains.stdout` and `*.parent-callgraph-report.stdout` for this limitation.
Both event headers set `exclude_kernel=1`.
Small `[k]` entries outside the top ten remain unknown labels, not measured kernel cost.

The shared host retained its `powersave` governor without fixed-frequency control.
The recorded current frequency was 1.2 GHz within a 1.2–3.7 GHz range.
Load averages were 9.26/10.72/12.05 before the map capture and 9.87/10.48/11.83 afterward.
After the sync capture, they were 11.73/10.86/11.87.
Each profile is one diagnostic process, not a paired speedup or a statistical confidence result.
The final matched table and its no-overall-parity conclusion remain unchanged.

