# Benchmarks

Run commands from the repository root with Zig 0.17.0.
The native drivers import the public `zautomerge` module.

## Build steps

```sh
zig build bench -Doptimize=fast
zig build bench-matched -Doptimize=fast -- insert-growth small
zig build bench-test
```

`bench` runs all native workloads without forwarding command-line arguments.
`bench-matched` forwards `WORKLOAD small|large` and defaults to `insert-growth small`.
The matched driver links libc and uses `std.heap.c_allocator`.
Neither build step installs its benchmark executable.
`bench-test` tests counter validation without requiring hardware-counter access.

## Direct executables

Build once before collecting process timings or hardware counters.
This example puts generated options and executables outside the checkout:

```sh
BENCH_DIR=$(mktemp -d)
printf '%s\n' \
    'pub const check_slow_paths = false;' \
    'pub const package_name = "zautomerge";' \
    'pub const package_version = "0.0.0";' \
    'pub const text_indexing = "unicode_code_point";' \
    > "$BENCH_DIR/build_options.zig"

zig build-exe -O fast \
    --dep zautomerge -Mroot=bench/zautomerge_bench.zig \
    --dep build_options -Mzautomerge=src/root.zig \
    -Mbuild_options="$BENCH_DIR/build_options.zig" \
    -femit-bin="$BENCH_DIR/zautomerge-bench"

zig build-exe -O fast -mcpu=native -lc \
    --dep zautomerge -Mroot=bench/matched_bench.zig \
    --dep build_options -Mzautomerge=src/root.zig \
    -Mbuild_options="$BENCH_DIR/build_options.zig" \
    -femit-bin="$BENCH_DIR/zautomerge-matched-bench"
```

Code-generation options precede the first `-M` argument.
Keep the generated package version consistent with `build.zig.zon`.
Use matching CPU and optimization settings when comparing binaries.

## Native workloads

```sh
"$BENCH_DIR/zautomerge-bench" --list
"$BENCH_DIR/zautomerge-bench" --repeat 5 insert-loop
"$BENCH_DIR/zautomerge-bench" --full insert-loop
```

Workloads are `segmentation`, `indexed-delta`, `slab-merge`, `prefix-bool`, `update-object`,
`mark-index`, `mark-at-end`, `sync-roundtrip`, `hash-for-opid`, `list-width`, and `insert-loop`.
`--full` selects larger fixtures. `--repeat N` reports the lower-middle elapsed-time sample.

Successful workloads emit this stdout record:

```text
BENCH <name> <iters> <total_ns> <ns_per_iter>
```

`iters` counts work units within one sample, not sample count.
Stderr contains sizes, named phases, checksums, and the `LEAKS` count.
Require exit zero and `LEAKS 0` before using a result.
Keep stderr and exit status. Earlier output can remain when a later workload fails.
Compare checksums only for identical workloads and sizes.

The list workload requires its read phase to reach 90% of measured elapsed time.
The insert workload compares two sizes at a fixed 4:1 ratio.
It rejects per-insert growth above 2.0.
A rejected run is not a timing sample. Do not weaken these checks to obtain numbers.

### Linux read-region counters

```sh
"$BENCH_DIR/zautomerge-bench" --region-instructions list-width
"$BENCH_DIR/zautomerge-bench" --region-instructions --full list-width
```

This mode requires `list-width` as the sole workload and Linux hardware-counter permission.
It emits `REGION`, not `BENCH`, with visits, elapsed time, instructions, and enabled/running counter durations.
It counts only the calling thread's user-space read-list loop, including cursor checks and checksum updates.
Setup, separate verification, and teardown remain outside that counter.
Counter denial or incomplete coverage fails without a metric record.
A region result does not satisfy the ordinary workload's elapsed-time attribution check.

## Matched Rust comparison

The matched drivers run one workload and size per process:

```sh
"$BENCH_DIR/zautomerge-matched-bench" insert-growth small
"$BENCH_DIR/zautomerge-matched-bench" diff-repeat large
```

| Workloads | Subject |
| --- | --- |
| `insert-growth`, `text-edits`, `map-updates` | Mutation and separate commit phases |
| `list-range-seq`, `list-range-batch` | List traversal after sequential or batched fixture construction |
| `save`, `load`, `merge` | Named document operation |
| `sync-roundtrip` | Separate generation and receipt phases |
| `diff-first`, `diff-repeat`, `diff-rotate`, `diff-subtree` | Cold, cached, rotating, or nonrecursive subtree diffs |

Both sizes use deterministic actors, inputs, and transaction boundaries.
Repeated and subtree diff workloads time 32 calls after a cache prime.
The subtree fixture is flat and does not measure deep-tree pruning.

For Rust, first configure the reference checkout as described in the [root README](../README.md).
The Rust driver uses its system allocator. Build through the local Cargo manifest:

```sh
sh tools/link-oracle.sh
RUSTFLAGS="-C target-cpu=native" cargo build --release --locked \
    --manifest-path tools/oracle/Cargo.toml --bin matched_bench
"${CARGO_TARGET_DIR:-tools/oracle/target}/release/matched_bench" insert-growth small
```

A successful matched driver emits one JSON record with workload, size, cardinality, phases, checksum, heads, and `verified`.
Require exit zero, `verified: true`, and matching workload, size, `n`, checksum, and complete sorted heads across engines.
Do not compare checksums alone. Compressed save bytes can differ.
Matched drivers do not report allocation counts or `LEAKS 0`.

Collect multiple fresh processes per engine and cell. Alternate engine order on the same CPU.
Record toolchain versions, source revision, build options, allocator, CPU affinity, raw output, stderr, and exit status.
Report minimum, median, and maximum. Keep failed samples separate from timing results.
External `perf stat -e instructions:u,cycles:u` counts the complete process, including setup, verification, output, and disposal.
Do not attribute those counts to a subject phase. Do not include compilation in measured execution.

## Anonymization memory workload

`anonymize_rss.zig` builds a document and anonymizes it.
Build it with the native direct-build recipe, replacing the root with `bench/anonymize_rss.zig`.
Set the output name to `anonymize-rss`, then compare peak RSS at fixed operations per change:

```sh
/usr/bin/time -v "$BENCH_DIR/anonymize-rss" --changes 2000 --ops 20
/usr/bin/time -v "$BENCH_DIR/anonymize-rss" --changes 8000 --ops 20
"$BENCH_DIR/anonymize-rss" --changes 200 --ops 5 --check
```

Run the small `--check` case separately. Its validation can dominate peak memory and must not enter the RSS comparison.
