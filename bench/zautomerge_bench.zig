//! End-to-end benchmark for the `zautomerge` port, driven the way a consumer
//! drives it.
//!
//! WHAT THIS IS FOR
//!
//! The port's own Debug suite already says which cases are expensive; it does
//! not say what the expensive part of an expensive case *is*, and it cannot be
//! asked for an instruction count without a forty-minute run. This executable
//! takes the seven most expensive cases in that suite, rebuilds each one's
//! workload against the **public module surface only** — the same
//! `@import("zautomerge")` a downstream project writes — and reports, per
//! workload, a nanosecond figure that can be diffed between two builds.
//!
//! FOUR MORE, FOR WHAT THE SUITE EXERCISES BUT NEVER ISOLATES
//!
//! A data-oriented audit of the port named four costs that no case measures,
//! so no change to them could be honestly accepted or rejected. They are the
//! sync message generation's growing `sent_hashes` set, `hashForOpid` lookup,
//! and list element-width traversal. Their current subjects are a bulk sorted
//! merge, an actor-change binary search and one held element cursor, not the
//! original per-hash memmove, node-table scan or fresh cursors. The fourth
//! finding is the per-change arena in `anonymize`, whose gate is peak RSS rather
//! than instructions and which `bench/README.md` §8 gives as a standalone
//! command line. The three that can
//! be gated through the public surface are three of the last four workloads
//! here; the fourth, `insert-loop`, is a fifth gate and not one of the audit's
//! four — it measures a cost the audit did not name, which another gate here
//! found by accident while measuring its own fixture.
//!
//! By default, every successful workload prints one machine-readable line on **stdout**:
//!
//!     BENCH <name> <iters> <total_ns> <ns_per_iter>
//!
//! and nothing else goes to stdout in default mode, so `grep '^BENCH '` over a
//! default run is the complete result set. Everything else — the input shape,
//! phase breakdown, warnings, the leak count — goes to **stderr**, where
//! `std.debug.print` already puts it in this repository's idiom
//! ([`test/save_interop.zig`](../test/save_interop.zig)).
//!
//! With `--region-instructions list-width`, the only stdout metric is instead:
//!
//!     REGION list-width read-list <elements> <walks> <element_visits> <read_ns> <instructions> <time_enabled_ns> <time_running_ns>
//!
//! ONE LINE IS NOT ENOUGH ON ITS OWN
//!
//! `total_ns` is wall clock, and a shared busy host moves wall clock by several
//! percent between identical runs while the instruction count does not move at
//! all. **Take the instruction count as the primary metric** and the
//! nanoseconds as the secondary one:
//!
//!     perf stat -e instructions ./zautomerge_bench segmentation
//!
//! Run one workload per process and `perf stat`'s instruction count belongs to
//! that workload alone, which is what makes it diffable across a before/after
//! build. Always report the load average next to any wall-clock number.
//!
//! Two things that sentence leaves out, both measured, both of which have
//! bitten this file:
//!
//! **`zig build bench` does not forward its arguments and installs no binary.**
//! `zig build bench -- --list` runs all eleven workloads and prints all eleven
//! `BENCH` lines. Build the executable once with the `zig build-exe` line in
//! `bench/README.md` §7 — `-O ReleaseFast` goes **before** the first `-M`, or
//! the binary comes out `Debug` — and call it directly.
//!
//! **A `perf stat` instruction count belongs to the process, not the timed region.**
//! By default, `list-width` refuses runs below `list_width_subject_floor_pct`.
//! `--region-instructions list-width` instead counts only the complete read-list
//! loop on the calling thread, including range setup, validation and checksum.
//! It excludes fixture construction, independent verification and teardown.
//! Counter control/read overhead remains in wall time; small user-space counter
//! boundary overhead remains in the unadjusted instruction count.
//!
//! USAGE
//!
//!     zautomerge_bench [--repeat N] [--full] [--list] [--region-instructions] [workload ...]
//!
//! With no workload named, every workload runs. `--repeat N` runs each one N
//! times and reports the **median** sample. `--full` uses the original test-case
//! sizes for the seven case-derived workloads and larger documented scaling
//! points for the four added workloads, which have no corresponding test case.
//! See `bench/README.md` for the size pairs and their shapes.

const std = @import("std");
const builtin = @import("builtin");
const perf_instructions = @import("perf_instructions.zig");

/// The module under test, imported by the name a consumer imports it by.
const am = @import("zautomerge");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Document = am.doc.Document;
const OpId = am.OpId;
const TextEncoding = am.TextEncoding;
const ChangeHash = am.ChangeHash;

/// The buffer stdout is written through. Eleven short lines would not need one;
/// a reader that wants the file before the process has exited does.
const stdout_buffer_len = 8 * 1024;

const usage =
    \\usage: zautomerge_bench [--repeat N] [--full] [--list] [--region-instructions] [workload ...]
    \\
    \\  --repeat N   run each named workload N times and report the median
    \\               sample (default 1). Wall clock on a busy host moves a few
    \\               percent between samples; the median is the least-bad
    \\               summary and `perf stat -e instructions` is the good one.
    \\  --full       use original test-case sizes for the seven case-derived
    \\               workloads and larger scaling points for the four added
    \\               workloads; see bench/README.md for sizes and pass counts.
    \\  --region-instructions
    \\               count user-space instructions in the complete read-list
    \\               loop; requires list-width as the sole named workload.
    \\               Emit REGION, not BENCH; fail if an exact count is unavailable.
    \\  --list       print the workload names and exit
    \\
    \\workloads, all of which are optional positionally:
    \\
;

pub fn main(init: std.process.Init) !u8 {
    // Retain a checking allocator in every mode. Its final deinit returns the leak
    // count; write-after-free checks are disabled for fast and small builds.
    var arbiter: std.heap.SafeAllocator = .init(init.gpa, .{
        .check_write_after_free = builtin.mode != .fast and builtin.mode != .small,
    });
    const gpa = arbiter.allocator();
    var allocator_live = true;
    defer {
        if (allocator_live) _ = arbiter.deinit();
    }

    // ── The output stream ─────────────────────────────────────────────────
    //
    // Buffered, and the only thing that ever reaches stdout.
    var stdout_buffer: [stdout_buffer_len]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    // ── The command line ──────────────────────────────────────────────────
    //
    // Parsed out of `init.arena`, which `std.start` frees after `main`
    // returns, so nothing here outlives the program and nothing here needs a
    // `defer`.
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var repeat: usize = 1;
    var full = false;
    var region_instructions = false;
    var names: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--list")) {
            for (workloads) |w| try out.print("{s}\n", .{w.name});
            try out.flush();
            return 0;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print("{s}", .{usage});
            for (workloads) |w| try out.print("  {s}\n", .{w.name});
            try out.flush();
            return 0;
        }
        if (std.mem.eql(u8, arg, "--full")) {
            full = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--region-instructions")) {
            region_instructions = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--repeat=")) {
            repeat = std.fmt.parseUnsigned(usize, arg["--repeat=".len..], 10) catch {
                std.debug.print("zautomerge_bench: --repeat wants a count, got '{s}'\n", .{arg});
                return 2;
            };
            if (repeat == 0) {
                std.debug.print("zautomerge_bench: --repeat must be at least 1\n", .{});
                return 2;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--repeat")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("zautomerge_bench: --repeat wants a count and got nothing\n", .{});
                return 2;
            }
            repeat = std.fmt.parseUnsigned(usize, args[i], 10) catch {
                std.debug.print("zautomerge_bench: --repeat wants a count, got '{s}'\n", .{args[i]});
                return 2;
            };
            if (repeat == 0) {
                std.debug.print("zautomerge_bench: --repeat must be at least 1\n", .{});
                return 2;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("zautomerge_bench: unknown option '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        }
        try names.append(arena, arg);
    }

    if (region_instructions and
        (names.items.len != 1 or !std.mem.eql(u8, names.items[0], "list-width")))
    {
        std.debug.print(
            "zautomerge_bench: --region-instructions requires list-width as the sole named workload\n",
            .{},
        );
        return 2;
    }

    const sizes = if (full) Sizes.full else Sizes.default;
    const ctx: Ctx = .{
        .gpa = gpa,
        .io = init.io,
        .sizes = sizes,
        .region_instructions = region_instructions,
    };

    std.debug.print(
        "zautomerge_bench: optimize={s} sizes={s} repeat={d}\n",
        .{ @tagName(builtin.mode), if (full) "full" else "default", repeat },
    );

    // A workload named on the command line that is not in the table is a typo,
    // and a typo that silently runs nothing is a benchmark that measures
    // nothing. Named workloads run in the order they were named; with none
    // named, every workload runs in table order.
    var selected: std.ArrayList(Workload) = .empty;
    if (names.items.len == 0) {
        try selected.appendSlice(arena, &workloads);
    } else {
        for (names.items) |want| {
            var found = false;
            for (workloads) |w| {
                if (!std.mem.eql(u8, w.name, want)) continue;
                try selected.append(arena, w);
                found = true;
                break;
            }
            if (!found) {
                std.debug.print("zautomerge_bench: no workload named '{s}'\n", .{want});
                return 2;
            }
        }
    }

    // Repeat storage belongs to `init.arena`, not the leak arbiter: the leak
    // check runs before main's defers. Keep each sample's metadata paired with
    // its wall time, but allocate nothing for the default single sample.
    const samples: []Result = if (repeat > 1) try arena.alloc(Result, repeat) else &.{};
    const sorted: []u64 = if (repeat > 1) try arena.alloc(u64, repeat) else &.{};

    // Every byte of work every workload did is folded into one running total
    // and printed at the end, so nothing below can be optimised away on the
    // grounds that the answer is unused.
    var sink: u64 = 0;
    var region_result: Result = .{};

    for (selected.items) |w| {
        std.debug.print("\n# {s}\n#   reproduces: {s}\n", .{ w.name, w.case });

        var last: Result = .{};
        var ok = true;
        for (0..repeat) |rep| {
            const started = Timer.start(ctx.io);
            if (w.run(ctx)) |ran| {
                var r = ran;
                if (!r.measures_own_time) r.ns = started.stop();
                if (repeat > 1) {
                    samples[rep] = r;
                    sorted[rep] = r.ns;
                } else {
                    last = r;
                }
            } else |err| {
                std.debug.print("# FAILED on repeat {d}: {s}\n", .{ rep, @errorName(err) });
                ok = false;
                break;
            }
        }
        if (!ok) return 1;

        // The median, by the lower-middle convention: for an even number of
        // samples the smaller of the two central ones, which is a real
        // observation rather than an average of two.
        if (repeat > 1) {
            std.mem.sort(u64, sorted, {}, lessThanU64);
            const median = sorted[(repeat - 1) / 2];
            for (samples) |sample| {
                if (sample.ns != median) continue;
                last = sample;
                break;
            }
        }
        const median = last.ns;
        const iters: u64 = @intCast(last.iters);
        const per_iter = if (iters == 0) 0 else median / iters;

        sink +%= last.checksum;

        if (region_instructions) {
            // Publish only after the independent checks and leak check pass.
            region_result = last;
        } else {
            try out.print("BENCH {s} {d} {d} {d}\n", .{ w.name, last.iters, median, per_iter });
            try out.flush();
        }

        std.debug.print(
            "#   {d} iteration(s), median {d} ns over {d} sample(s), {d:.3} ms/iter\n",
            .{ last.iters, median, repeat, @as(f64, @floatFromInt(per_iter)) / std.time.ns_per_ms },
        );
        for (last.phases[0..last.phase_count]) |p| {
            std.debug.print(
                "#     phase {s}: {d} ns ({d:.3} ms)\n",
                .{ p.name, p.ns, @as(f64, @floatFromInt(p.ns)) / std.time.ns_per_ms },
            );
        }
        if (last.measures_own_time) {
            std.debug.print(
                "#   the timed region is the workload's own, not the whole iteration; see bench/README.md\n",
                .{},
            );
        }
        std.debug.print("#   checksum {x}\n", .{last.checksum});
    }

    std.debug.print("\n# checksum sink {x}\n", .{sink});

    const leaked = arbiter.deinit();
    allocator_live = false;
    std.debug.print("# LEAKS {d}\n", .{leaked});
    if (leaked != 0) {
        std.debug.print(
            "# a leak here is a bug in the benchmark rather than in the port: every workload frees what it takes\n",
            .{},
        );
        return 1;
    }
    if (region_instructions) {
        const reading = region_result.counter_reading orelse return error.MissingRegionReading;
        const elements = ctx.sizes.list_width_elements;
        try out.print(
            "REGION list-width read-list {d} {d} {d} {d} {d} {d} {d}\n",
            .{
                elements,
                region_result.iters,
                elements * region_result.iters,
                region_result.ns,
                reading.instructions,
                reading.time_enabled_ns,
                reading.time_running_ns,
            },
        );
        try out.flush();
    }
    return 0;
}

fn lessThanU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

/// The wall clock, read the way `test/verification_runner.zig` reads it, so
/// this executable and the suite's own case record use one clock.
const Timer = struct {
    io: Io,
    at: Io.Clock.Timestamp,

    fn start(io: Io) Timer {
        return .{ .io = io, .at = Io.Clock.Timestamp.now(io, .awake) };
    }

    fn stop(self: Timer) u64 {
        return @intCast(self.at.untilNow(self.io).raw.nanoseconds);
    }
};

/// How many sub-regions a workload may report. Enough for every workload here;
/// a workload that wants more is a workload that wants its own executable.
const phase_max = 4;

const Phase = struct {
    name: []const u8,
    ns: u64,
};

/// What one workload's `run` hands back.
///
/// `iters` is the number of *unit* iterations the workload performed, which is
/// not the number of times the harness ran it: the `indexed-delta` workload
/// reports its twenty trials, so `ns_per_iter` is the cost of one trial rather
/// than the cost of all twenty.
const Result = struct {
    iters: usize = 1,
    /// Set by the workload itself, and only when `measures_own_time` is true.
    ns: u64 = 0,
    checksum: u64 = 0,
    /// True when `ns` is a region the workload chose rather than the whole
    /// call, which is how `update-object` times the hot call without its
    /// fixture.
    measures_own_time: bool = false,
    counter_reading: ?perf_instructions.Reading = null,
    phases: [phase_max]Phase = @splat(.{ .name = "", .ns = 0 }),
    phase_count: u8 = 0,

    /// Records a sub-region. Silently drops anything past `phase_max`, because
    /// a benchmark that crashes on the fifth phase is worse than one that
    /// reports four and says nothing about the rest.
    fn addPhase(self: *Result, name: []const u8, ns: u64) void {
        if (self.phase_count >= phase_max) return;
        self.phases[self.phase_count] = .{ .name = name, .ns = ns };
        self.phase_count += 1;
    }

    /// Folds a value into the running checksum. **Every observation a workload
    /// makes goes through here**, both so nothing can be optimised away and so
    /// one integer summarises what the run produced. The mix is a multiply so
    /// that a workload cannot pass by producing the same total in a different
    /// order.
    fn mix(self: *Result, value: anytype) void {
        self.checksum = self.checksum *% 0x9E3779B97F4A7C15 +% @as(u64, @intCast(value));
    }
};

const Workload = struct {
    name: []const u8,
    /// The port test case this workload reproduces, for the reader who has to
    /// check that the shape was not quietly changed.
    case: []const u8,
    run: *const fn (Ctx) anyerror!Result,
};

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    sizes: Sizes,
    region_instructions: bool = false,
};

/// Every size every workload takes, in one place, so `bench/README.md`'s table
/// of what is reduced and `Sizes.full` cannot drift apart.
const Sizes = struct {
    /// How many times the record is repeated to make the segmentation body.
    seg_reps: usize,
    /// How many times the single-pass segmentation runs over that body. It is
    /// O(n), so one pass over a reduced body is below the clock's floor and
    /// this is what lifts it above.
    seg_single_passes: usize,
    /// Trials of the delta-column fuzz sweep.
    delta_trials: usize,
    /// Trials of the slab-merge sweep.
    merge_trials: usize,
    /// Trials of the boolean prefix-column sweep.
    prefix_trials: usize,
    /// The depth the `fuzzMap` generator is asked for.
    hydrate_depth: u8,
    /// Rows in the mark-index column.
    mark_rows: usize,
    /// Marks placed over those rows.
    mark_count: usize,
    /// Sampled positions queried before and after the undo sweep.
    mark_queries: usize,
    /// How many times the record is repeated to make the long text.
    text_reps: usize,
    /// Rounds of the two-peer sync exchange. Each generation bulk-sorts its
    /// payload hashes and merges them into the growing `sent_hashes` set.
    /// The first round adds `sync_chunk + 1` hashes, later rounds `sync_chunk`.
    /// The peer receives every message but withholds acknowledgements until
    /// the measured rounds end, so the set is not pruned between rounds.
    sync_rounds: usize,
    /// Changes the local document gains, and the peer is sent, per round.
    sync_chunk: usize,
    /// One-put committed changes in the actor's change list searched by
    /// `hashForOpid`. Graph construction is outside the lookup timer.
    opid_changes: usize,
    /// How many `hashForOpid` calls each arm is timed over.
    opid_calls: usize,
    /// Elements in the list `list-width` walks. Neither size changed; the
    /// fixture is one batched splice rather than the old per-element inserts.
    /// The phase timings show whether the subject clears the process-wide
    /// attribution floor; a cheaper fixture does not guarantee that it does.
    list_width_elements: usize,
    /// Complete held-cursor walks. The larger `--full` point uses one pass
    /// instead of the default's two; element count and pass count both matter
    /// when interpreting a whole-process instruction ratio.
    list_width_passes: usize,

    /// Ascending `Transaction.insert` calls in ONE transaction and ONE commit:
    /// the **small** of the two sizes `insert-loop` builds, so the per-insert
    /// cost has a smaller point to be flat against. **Scaled by the same factor
    /// as `insert_large` under `--full`**, because the ratio between the two
    /// sizes is the measurement and a run whose ratio moved would be measuring
    /// something else.
    insert_small: usize,
    /// The **large** of the two: exactly `insert_loop_size_ratio` times
    /// `insert_small`, and the run fails if it is not
    /// (`error.SizesAreNotAtTheDocumentedRatio`). **The ratio between the two
    /// sizes IS the finding**: a per-insert cost flat in `n` reads about the
    /// same at both, and one that grows with `n` — an O(rows) walk per insert —
    /// reads `insert_loop_size_ratio` times as much at the large size. The
    /// guard is `insert_loop_growth_ceiling`, which sits between the two.
    insert_large: usize,

    // The four added workloads have **no test case behind them**, so `full`
    // below is not "the case's exact size" for them; it is a larger documented
    // size of the same shape. `bench/README.md` §4 says which is which.

    /// The reduced sizes. Chosen so one full pass over every workload fits
    /// well inside a minute on a native ReleaseFast build, with every workload
    /// still long enough to time. `bench/README.md` says which are reduced and
    /// why each reduction measures the same thing.
    const default: Sizes = .{
        .seg_reps = 50,
        .seg_single_passes = 1024,
        .delta_trials = 20,
        .merge_trials = 20,
        .prefix_trials = 20,
        .hydrate_depth = 42,
        .mark_rows = 40_000,
        .mark_count = 1000,
        .mark_queries = 200,
        .text_reps = 10_000,
        .sync_rounds = 24,
        .sync_chunk = 200,
        .opid_changes = 20_000,
        .opid_calls = 400,
        .list_width_elements = 50_000,
        .list_width_passes = 2,
        .insert_small = 2_500,
        .insert_large = 10_000,
    };

    /// The sizes the port's own test cases use, exactly, for the seven cases
    /// there are seven test cases for — and a larger documented size of the
    /// same shape for the four added workloads, which have none. `--full`.
    const full: Sizes = .{
        .seg_reps = 500,
        .seg_single_passes = 1024,
        .delta_trials = 200,
        .merge_trials = 200,
        .prefix_trials = 200,
        .hydrate_depth = 42,
        .mark_rows = 100_000,
        .mark_count = 2500,
        .mark_queries = 200,
        .text_reps = 10_000,
        .sync_rounds = 48,
        .sync_chunk = 400,
        .opid_changes = 50_000,
        .opid_calls = 1_000,
        .list_width_elements = 200_000,
        // One pass at the larger element count, rather than the default's two.
        // `--full` increases fixture size, not the number of walk samples.
        // Do not transfer the old fresh-cursor runtime to this held-cursor path.
        .list_width_passes = 1,
        .insert_small = 5_000,
        .insert_large = 20_000,
    };
};

// ── Workload 1: segmentation ─────────────────────────────────────────────────
//
// The case is `src/textdiff.zig:1679`, "the single-pass segmentation is the
// per-prefix count it replaced", and it is the port's most expensive single
// case. Its cost is **not** in `graphemes`; it is in `byPerPrefixCount`, the
// O(n²) oracle the case holds `graphemes` against, which calls
// `am.unicode.countGraphemes` once per code point over the whole prefix.
//
// `byPerPrefixCount` is private to `src/textdiff.zig`, but everything it calls
// is public, so this workload **reproduces it** rather than approximating it:
// same loop, same oracle, same record, and therefore the same hot path.
//
// Its two phases are reported separately because they answer two different
// questions. The oracle phase is where the 164.87 s went. The single-pass
// phase is what a real consumer pays per segmentation, and it is the only one
// of the two that should ever be on a hot path.

/// The record the test case repeats, byte for byte: 21 ASCII bytes, the ZWJ
/// family sequence (U+1F469 200D U+1F469 200D U+1F467 200D U+1F466), and one
/// trailing space — 47 bytes, 29 code points.
const segmentation_record = "the quick brown fox. \u{1f469}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466} ";

/// The nine short cases the test case checks before its long body, verbatim.
const segmentation_cases = [_][]const u8{
    "",
    "a",
    "e\u{0301}f",
    "\u{1f1e6}\u{1f1e7}\u{1f1e8}",
    "\u{1f469}\u{200d}\u{1f469}\u{200d}\u{1f467}",
    "\u{1100}\u{1161}\u{11a8}",
    "a\r\nb",
    "\u{0600}a\u{0301}\u{200d}\u{1f469}",
    "\u{1f3f4}\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}",
};

fn segmentationBody(gpa: Allocator, reps: usize) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    try body.ensureTotalCapacity(gpa, reps * segmentation_record.len);
    for (0..reps) |_| try body.appendSlice(gpa, segmentation_record);
    return body.toOwnedSlice(gpa);
}

/// `src/textdiff.zig:1652` `byPerPrefixCount`, rebuilt on the public
/// `am.unicode.countGraphemes`. Line for line the original, because the line
/// count *is* the cost: one `countGraphemes` over the whole prefix per code
/// point, which is what makes it O(n²) and what makes it this case's hot path.
fn byPerPrefixCount(
    gpa: Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var before: usize = 0;
    var at: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidCharacter;
        if (i + len > text.len) return error.InvalidCharacter;
        const stop = i + len;
        const seen = try am.unicode.countGraphemes(text[0..stop]);
        if (seen > before) {
            if (i > at) try out.append(gpa, text[at..i]);
            at = i;
            before = seen;
        }
        i = stop;
    }
    if (at < text.len) try out.append(gpa, text[at..]);
}

fn segmentation(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    const body = try segmentationBody(gpa, ctx.sizes.seg_reps);
    defer gpa.free(body);

    var out: Result = .{};

    // Phase 1: the oracle. One pass over the nine short cases and one over the
    // body — the case's exact input domain.
    {
        const started = Timer.start(ctx.io);
        for (segmentation_cases) |text| {
            var want: std.ArrayList([]const u8) = .empty;
            defer want.deinit(gpa);
            try byPerPrefixCount(gpa, text, &want);
            out.mix(want.items.len);
        }
        {
            var want: std.ArrayList([]const u8) = .empty;
            defer want.deinit(gpa);
            try byPerPrefixCount(gpa, body, &want);
            out.mix(want.items.len);
        }
        out.addPhase("oracle-by-per-prefix-count", started.stop());
    }

    // Phase 2: the single pass, over the *same* body, repeated enough times to
    // clear the clock's floor. Same input as phase 1, so the ratio between the
    // two phases is a statement about the two implementations and not about two
    // different texts.
    {
        const started = Timer.start(ctx.io);
        for (0..ctx.sizes.seg_single_passes) |_| {
            const got = try am.textdiff.graphemes(gpa, body);
            defer gpa.free(got);
            out.mix(got.len);
        }
        out.addPhase("single-pass-graphemes", started.stop());
    }

    return out;
}

// ── Workload 2: indexed delta column ─────────────────────────────────────────
//
// The case is `src/hexane/column.zig:15125`, `fuzz_indexed_delta_column`: 200
// trials of 400 splices into a `Column(u64, Delta(u64))`, then the indexed
// queries that column exists for, then an encode/load/re-encode round trip.
//
// **The whole point of the case is that the column ends up in several slabs.**
// A delta column over a five-hundred-value alphabet canonically collapses into
// a single literal run, and the case says so: every fourth insert is three
// copies of one value, because a run of three equal values is two zero
// differences and that is the shortest thing that puts a repeat run behind the
// insert. That detail is reproduced unchanged; the trial count is the only
// thing `--full` restores.

// `Delta` is the COLUMN-level codec, `column.Delta`, not the slab-level
// `hexane.delta.Delta`: the column's own `DeltaBase` wraps a `WireRle` and is
// what publishes the `Weight` the btree index needs (column.zig:2005-2012).
// The slab-level `hexane.delta.Delta` is the wire writer and has no `Weight`,
// so naming that one here is a compile error rather than a slow benchmark.
const DeltaU64 = am.hexane.column.Column(u64, am.hexane.column.Delta(u64));

fn indexedDelta(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    var out: Result = .{ .iters = ctx.sizes.delta_trials };

    var prng: std.Random.DefaultPrng = .init(0x0DE1A);
    const rand = prng.random();

    for (0..ctx.sizes.delta_trials) |_| {
        var col = try DeltaU64.init(gpa);
        defer col.deinit();
        var model: std.ArrayList(u64) = .empty;
        defer model.deinit(gpa);

        var buf: [3]u64 = undefined;
        for (0..400) |k| {
            const len = model.items.len;
            const at = if (len == 0) 0 else rand.intRangeAtMost(usize, 0, len);
            const v = rand.intRangeAtMost(u64, 0, 500);
            const n = if (k % 4 == 0) buf.len else 1;
            @memset(buf[0..n], v);
            try col.splice(gpa, at, 0, buf[0..n]);
            try model.insertSlice(gpa, at, buf[0..n]);
        }

        // Upstream's own row check (`tests.rs:4428`): the column holds the rows
        // the model says it does.
        const rows = try col.toSlice(gpa);
        defer gpa.free(rows);
        if (model.items.len != rows.len) return error.RowCountDiffers;
        for (model.items, rows) |want, have| {
            if (want != have) return error.RowDiffers;
        }
        out.mix(rows.len);
        out.mix(col.slabCount());
        // The case's premise, and the reason every fourth insert above is
        // three copies of one value: a column that stayed in one slab would
        // make every index query below trivial and measure nothing.
        if (col.slabCount() < 2) return error.NotManySlabs;

        // `find_by_value` over the whole value domain, and the slab the index
        // names walked back through the column — the case's read side.
        var target: u64 = 0;
        while (target < 500) : (target += 97) {
            var find = try col.findByValue(@intCast(target));
            defer find.deinit();
            while (try find.next()) |hit| {
                const slab = col.slabAt(hit.slab) orelse return error.InvalidValue;
                var it = try col.iterRange(.{
                    .start = hit.items_before,
                    .end = hit.items_before + slab.len,
                });
                var at_row: usize = 0;
                while (try it.next()) |v| {
                    if (v == target) out.mix(hit.items_before + at_row);
                    at_row += 1;
                }
            }
        }

        // And the bytes it re-encodes to are the bytes it loaded.
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        var back = try DeltaU64.load(gpa, bytes);
        defer back.deinit();
        const again = try back.encode(gpa);
        defer gpa.free(again);
        if (!std.mem.eql(u8, bytes, again)) return error.RoundTripDiffers;
    }
    return out;
}

// ── Workload 3: slab merge invariant ─────────────────────────────────────────
//
// The case is `src/hexane/hexane_test.zig:474`, `fuzz_slab_merge_invariant`:
// 200 trials of 500 inserts and removes against `Column(u64, Rle(u64))`, with
// the layout re-read after every single one of the hundred thousand
// operations.
//
// The generator is upstream's `xorshift` from the fixed state 98765, with the
// three shifts in upstream's order, including the draw that is *not* made while
// the column is empty — that is what keeps the two sequences the same
// sequence. All of that is reproduced here.
//
// The case's per-operation predicate (`expectSlabMergePolicy`) and its model
// comparison are private to that file. The public half of what they read is the
// full column walk and the slab count, and both run after every operation here
// too, so the operation count, the column sizes, the number of slab merges and
// the read-back load are the case's.

const RleU64 = am.hexane.column.Column(u64, am.hexane.column.Rle(u64));

/// `tests.rs:4090-4095`, spelled the same in `src/hexane/hexane_test.zig:822`
/// and `src/opset/columns.zig:3691`; both produce the same stream and this is
/// the first of them.
fn xorshift(state: *u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return state.*;
}

fn slabMerge(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    var out: Result = .{ .iters = ctx.sizes.merge_trials };

    var rng: u64 = 98765;
    for (0..ctx.sizes.merge_trials) |_| {
        var col = try RleU64.init(gpa);
        defer col.deinit();
        // The case asserts this and so does the benchmark: the merge policy is
        // only the same question while the column is on the default budget.
        if (col.maxSegmentsOf() != am.hexane.column.default_max_segments) return error.UnexpectedBudget;

        var model: std.ArrayList(u64) = .empty;
        defer model.deinit(gpa);

        for (0..500) |_| {
            const len = model.items.len;
            const r = xorshift(&rng);
            if (len == 0 or r % 3 != 0) {
                const pos = if (len == 0) 0 else @as(usize, @intCast(xorshift(&rng))) % (len + 1);
                const val = xorshift(&rng) % 20;
                try col.splice(gpa, pos, 0, &.{val});
                try model.insert(gpa, pos, val);
            } else {
                const pos = @as(usize, @intCast(xorshift(&rng))) % len;
                try col.removeN(gpa, pos, 1);
                _ = model.orderedRemove(pos);
            }

            // The read-back after every operation, as the case does.
            out.mix(col.slabCount());
            var it = try col.iterator();
            while (try it.next()) |v| out.mix(v);
        }
        out.mix(model.items.len);
    }
    return out;
}

// ── Workload 4: boolean prefix column ────────────────────────────────────────
//
// The case is `src/opset/columns.zig:3700`, `fuzz_prefix_column_bool`: 200
// trials of 300 inserts and removals against a `PrefixColumn<bool>`, with the
// prefix total and every row checked after **every** operation, and a
// save/load/save byte comparison at the end of each trial.
//
// This is the op set's own boolean prefix codec rather than the column
// layer's, because a boolean column's weight has to count its `true` rows and
// the column layer's codecs are integer-valued. `BoolPrefixColumn` is that
// codec's column and is what the case runs.

const BoolPrefixColumn = am.opset.columns.BoolPrefixColumn;

fn prefixBool(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    var out: Result = .{ .iters = ctx.sizes.prefix_trials };

    var rng: u64 = 44444;
    for (0..ctx.sizes.prefix_trials) |_| {
        var col = try BoolPrefixColumn.init(gpa);
        defer col.deinit();
        var mirror: std.ArrayList(bool) = .empty;
        defer mirror.deinit(gpa);

        for (0..300) |_| {
            const len = mirror.items.len;
            const r = xorshift(&rng);
            if (len == 0 or r % 3 != 0) {
                const pos = if (len == 0) 0 else @as(usize, @intCast(xorshift(&rng))) % (len + 1);
                const val = xorshift(&rng) % 2 == 0;
                try col.splice(gpa, pos, 0, &[_]bool{val});
                try mirror.insert(gpa, pos, val);
            } else {
                const pos = @as(usize, @intCast(xorshift(&rng))) % len;
                try col.splice(gpa, pos, 1, &.{});
                _ = mirror.orderedRemove(pos);
            }

            // The prefix total after every operation, and every row beside it.
            const total = try col.getPrefix(mirror.items.len);
            var true_count: usize = 0;
            for (mirror.items) |v| true_count += @intFromBool(v);
            if (total != @as(i64, @intCast(true_count))) return error.PrefixDiffers;
            out.mix(total);
            for (mirror.items, 0..) |want, k| {
                if ((try col.get(k)).? != want) return error.RowDiffers;
            }
        }

        // The per-trial save/load/save byte comparison (`tests.rs:4401-4405`).
        const saved = try col.encode(gpa);
        defer gpa.free(saved);
        var loaded = try BoolPrefixColumn.load(gpa, saved);
        defer loaded.deinit();
        const resaved = try loaded.encode(gpa);
        defer gpa.free(resaved);
        if (!std.mem.eql(u8, saved, resaved)) return error.RoundTripDiffers;
    }
    return out;
}

// ── Workload 5: updateObject over a deep hydrated root ───────────────────────
//
// The case is `test/upstream_doc_test.zig:1403`, "rollback after a save and
// load of a deep hydrated root map", and 47 s of its 66 s is inside
// `AutoCommit.updateObject` over the root a `fuzzMap(0, 42)` builds.
//
// **This is the one workload that times a region rather than a whole call.**
// Building the hydrated mirror and creating the document are setup and sit
// outside the clock; `updateObject` itself is inside it, because
// `updateObject` is the hot call and timing it together with a fixture build
// would bury it. The read-back afterwards is outside the clock too, and is what
// keeps the workload honest: if `updateObject` stopped writing the document,
// the checksum would change and the phase figures would be meaningless.
//
// The generator is `test/upstream_doc_test.zig:1342-1401`, transcribed with
// `am.hydrate` in place of the file's own `gpa`. Every `hydrate.Map`,
// `hydrate.List` and `hydrate.Text` it builds is released by the `Map.deinit`
// at the top, and the document releases what it took.

fn updateObject(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    var out: Result = .{ .measures_own_time = true };

    // ── setup, untimed ──
    var root_value: am.hydrate.Value = .{
        .object = .{ .map = try fuzzMap(gpa, 0, ctx.sizes.hydrate_depth) },
    };
    defer root_value.deinit();

    var doc = try am.AutoCommit.init(gpa, ctx.io);
    defer doc.deinit();
    try doc.setActorId(.{ .bytes = "bench-update-object" });

    // ── the hot call, timed ──
    const started = Timer.start(ctx.io);
    try doc.updateObject(am.root, &root_value);
    _ = try doc.commitWith(.none);
    const hot = started.stop();
    out.addPhase("updateObject", hot);
    out.ns = hot;

    // ── read-back, untimed ──
    const after_started = Timer.start(ctx.io);
    if (try am.read.objectType(&doc, am.root) != .map) return error.RootIsNotAMap;
    var walk = try am.read.mapRange(&doc, am.root, am.read.KeyRange.all());
    var keys: usize = 0;
    while (try walk.next()) |item| {
        keys += 1;
        out.mix(item.key.len);
        out.mix(item.opId().counter);
    }
    out.mix(keys);
    out.addPhase("read-back", after_started.stop());

    return out;
}

/// `test/upstream_doc_test.zig:1320`.
const fuzz_strings = [_][]const u8{
    "",
    "a",
    "hello",
    "hello world",
    "\u{1F98A}\u{1F43B}",
    "multi\nline",
    "abcdefghijklmnopqrstuvwxyz",
};

/// `test/upstream_doc_test.zig:1337`.
fn fuzzText(slot: u8) []const u8 {
    if (slot % 8 == 0) return "the quick brown fox jumps over the lazy dog";
    return fuzz_strings[@as(usize, slot) % fuzz_strings.len];
}

/// The three fuzz generators are mutually recursive, so an inferred error set
/// is a dependency loop. This is the same explicit set the upstream port uses
/// at `test/upstream_doc_test.zig:1335`, and it is the whole of what these can
/// return: a failed allocation, or a hydration that refused the value.
const FuzzError = Allocator.Error || am.hydrate.ApplyError;

/// `test/upstream_doc_test.zig:1342`.
fn fuzzValue(gpa: Allocator, seed: u8, depth: u8) FuzzError!am.hydrate.Value {
    if (depth == 0) return am.hydrate.Value.scalar(.{ .int = @as(i64, seed) - 128 });
    return switch (seed % 4) {
        0 => am.hydrate.Value{ .object = .{ .map = try fuzzMap(gpa, seed, depth - 1) } },
        1 => am.hydrate.Value{ .object = .{ .list = try fuzzList(gpa, seed, depth - 1) } },
        2 => try am.hydrate.Value.text(gpa, .unicode_code_point, fuzzText(seed)),
        else => am.hydrate.Value.scalar(.{ .str = "a" }),
    };
}

/// `test/upstream_doc_test.zig:1352`. At depth 42 this builds 43 maps, 861
/// lists and 905 values, and that is what the case hydrates and what
/// `updateObject` walks.
fn fuzzMap(gpa: Allocator, seed: u8, depth: u8) FuzzError!am.hydrate.Map {
    var out = am.hydrate.Map.init(gpa, .root);
    errdefer out.deinit();
    {
        const key = try std.fmt.allocPrint(gpa, "m{}", .{seed % 8});
        defer gpa.free(key);
        const value = try fuzzValue(gpa, seed, depth);
        out.putOwned(key, .{ .value = value, .conflict = false }) catch |e| {
            var owned = value;
            owned.deinit();
            return e;
        };
    }
    {
        const key = try std.fmt.allocPrint(gpa, "n{}", .{seed % 8});
        defer gpa.free(key);
        const value = try fuzzValue(gpa, seed +% 1, if (depth == 0) 0 else depth - 1);
        out.putOwned(key, .{ .value = value, .conflict = false }) catch |e| {
            var owned = value;
            owned.deinit();
            return e;
        };
    }
    return out;
}

/// `test/upstream_doc_test.zig:1380`.
fn fuzzList(gpa: Allocator, seed: u8, depth: u8) FuzzError!am.hydrate.List {
    var out = am.hydrate.List.init(gpa, .root);
    errdefer out.deinit();
    {
        const value = try fuzzValue(gpa, seed, depth);
        out.push(value, false) catch |e| {
            var owned = value;
            owned.deinit();
            return e;
        };
    }
    {
        const value = try fuzzValue(gpa, seed +% 1, if (depth == 0) 0 else depth - 1);
        out.push(value, false) catch |e| {
            var owned = value;
            owned.deinit();
            return e;
        };
    }
    return out;
}

// ── Workload 6: a mark index column of many slabs ────────────────────────────
//
// The case is `src/opset/mark_index.zig:2459`, "a column of many slabs answers
// every position, before and after an undo", ported from upstream's
// `large_column_multi_slab` (`mark_index.rs:691-819`), which is `#[ignore]`d
// there for its size.
//
// Three things are the case and all three are here: a column whose rows span
// **many slabs**, so the prefix fold has to cross slab boundaries; **every
// third mark undone, last one first**, so the undo sweep crosses them too; and
// the same kind of positions queried **before and after**.
//
// The placement generator is the case's SplitMix64
// (`src/opset/mark_index.zig:1758`) from seed 42, and finding a mark's rows is
// a full column walk per undone mark, which is where most of this workload's
// time goes — both of them exactly as the case has them.

const MarkIdx = am.opset.mark_index.MarkIdx;
const MarkIndexBuilder = am.opset.mark_index.MarkIndexBuilder;
const MarkIndexColumn = am.opset.mark_index.MarkIndexColumn;
const MarkData = am.opset.types.MarkData;

/// One placed mark, as `src/opset/mark_index.zig:1593`.
const Placed = struct { id: OpId, start: usize, end: usize };

/// `src/opset/mark_index.zig:1758`, verbatim.
const MarkRng = struct {
    state: u64,

    fn next(self: *MarkRng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// A value in `[lo, hi)`.
    fn between(self: *MarkRng, lo: usize, hi: usize) usize {
        std.debug.assert(hi > lo);
        return lo + @as(usize, @intCast(self.next() % @as(u64, @intCast(hi - lo))));
    }
};

fn mkMark(name: []const u8) MarkData {
    return MarkData.init(name, .{ .bool_value = true });
}

/// The builder one modelled row arrives as (`src/opset/mark_index.zig:1620`).
/// A `Start` and an `End` occupy rows that already exist; they insert nothing.
fn builderOf(model: ?MarkIdx) ?MarkIndexBuilder {
    const v = model orelse return null;
    return switch (v) {
        .start => |begin| .{ .start = .{ .id = begin, .data = mkMark("m") } },
        .end => |begin| .{ .end = begin },
    };
}

fn markIndex(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    const n = ctx.sizes.mark_rows;
    var out: Result = .{};

    const model = try gpa.alloc(?MarkIdx, n);
    defer gpa.free(model);

    // ── placement ──
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(gpa);

    for (model) |*v| v.* = null;
    var rng = MarkRng{ .state = 42 };
    for (0..ctx.sizes.mark_count) |i| {
        const op_id = OpId.init(@intCast(i + 1), 0);
        const start = rng.between(0, n - 2);
        const end = rng.between(start + 1, n);
        if (model[start] == null and model[end] == null) {
            model[start] = .{ .start = op_id };
            model[end] = .{ .end = op_id };
            try placed.append(gpa, .{ .id = op_id, .start = start, .end = end });
        }
    }
    if (placed.items.len <= 100) return error.TooFewMarksPlaced;

    // ── the column ──
    const builders = try gpa.alloc(?MarkIndexBuilder, n);
    defer gpa.free(builders);
    // A row with no mark is a NULL BUILDER, not an error: ~95% of the rows
    // here are unmarked. This is the port's own semantics — `columnFor`
    // at src/opset/mark_index.zig:1630-1640 assigns the builder plainly and a
    // null builder is a null word with no cache entry — so the harness does
    // the same rather than refusing what the port accepts.
    for (builders, model) |*value, m| {
        value.* = builderOf(m);
    }
    var col = try MarkIndexColumn.init(gpa);
    defer col.deinit();
    try col.extend(0, builders);
    if (col.len() != n) return error.RowCountDiffers;
    // The premise of the whole case: more than one slab, so the fold crosses.
    if (col.data.slabCount() <= 1) return error.NotManySlabs;
    out.mix(col.data.slabCount());
    out.mix(col.len());

    // ── before the undo ──
    {
        const started = Timer.start(ctx.io);
        try sweepPositions(gpa, &col, n, ctx.sizes.mark_queries, 7, &out);
        out.addPhase("queries-before-undo", started.stop());
    }

    // ── the undo sweep ──
    const undo_started = Timer.start(ctx.io);
    var undone: std.AutoHashMapUnmanaged(OpId, void) = .empty;
    defer undone.deinit(gpa);

    var index = placed.items.len;
    while (index > 0) {
        index -= 1;
        const mark = placed.items[index];
        if (index % 3 != 0) continue;
        const rows = try findMarkPositions(gpa, &col, mark.id);
        defer gpa.free(rows);
        if (rows.len != 2) return error.MarkRowsNotTwo;
        try col.undo(rows[1], &[_]?MarkIndexBuilder{.{ .end = mark.id }});
        try col.undo(rows[0], &[_]?MarkIndexBuilder{.{
            .start = .{ .id = mark.id, .data = mkMark("m") },
        }});
        if (col.markData(mark.id) != null) return error.MarkDataSurvivedUndo;
        try undone.put(gpa, mark.id, {});
    }
    out.addPhase("undo-sweep", undo_started.stop());
    out.mix(undone.count());

    // ── after the undo ──
    {
        const started = Timer.start(ctx.io);
        try sweepPositions(gpa, &col, col.len(), ctx.sizes.mark_queries, 11, &out);
        out.addPhase("queries-after-undo", started.stop());
    }

    return out;
}

/// The case's query list: `queries` sampled positions plus the boundaries.
/// Every one goes through `marksAt`, which is the prefix fold over the slabs
/// the case exists to cover.
fn sweepPositions(
    gpa: Allocator,
    col: *const MarkIndexColumn,
    len: usize,
    queries: usize,
    seed: u64,
    out: *Result,
) !void {
    if (len < 2) return error.NoRowsToQuery;
    var rng = MarkRng{ .state = seed };
    var at: usize = 0;
    while (at < queries) : (at += 1) {
        try marksAtOne(gpa, col, rng.between(0, len), out);
    }
    for ([_]usize{ 0, 1, len / 4, len / 2, 3 * len / 4, len - 2, len - 1 }) |p| {
        try marksAtOne(gpa, col, p, out);
    }
}

fn marksAtOne(gpa: Allocator, col: *const MarkIndexColumn, p: usize, out: *Result) !void {
    var ids = try col.marksAt(gpa, p, null);
    defer ids.deinit();
    while (ids.next()) |begin| {
        out.mix(begin.counter);
        // Every id `marksAt` yields has an entry in the cache, and saying so
        // here is what makes the read mean something.
        if (col.markData(begin) == null) return error.OpenMarkWithoutData;
    }
}

/// `src/opset/mark_index.zig:1716`: the rows a mark's `Start` and `End` occupy,
/// found by walking the column. A full-column walk per undone mark, which is
/// why it is here and why the undo sweep is this workload's biggest phase.
fn findMarkPositions(gpa: Allocator, col: *const MarkIndexColumn, target: OpId) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    // Walk RUNS, not rows, exactly as the case does: `nextRun` at
    // src/opset/mark_index.zig:1716 skips a whole run's items per step, so a
    // walk costs one step per run. A row-at-a-time `ValueIter` here would cost
    // ~100 000 cursor steps per undone mark and would measure the harness
    // rather than the index.
    var it = try col.iter();
    var pos: usize = 0;
    while (try it.nextRun()) |run| {
        if (run.value) |value| switch (value) {
            .start => |begin| if (begin.eql(target)) {
                for (0..run.count) |k| try out.append(gpa, pos + k);
            },
            .end => |begin| if (begin.eql(target)) {
                for (0..run.count) |k| try out.append(gpa, pos + k);
            },
        };
        pos += run.count;
    }
    return out.toOwnedSlice(gpa);
}

// ── Workload 7: a mark at the end of a long text ─────────────────────────────
//
// The case is `src/read.zig:6537`, "a mark at the end of a long text is found
// at the end", from `tests/text.rs:1121-1154`: 210 000 ASCII characters, a mark
// over the last four, four single-position reads — two that must carry the mark
// and two that must not — and a whole-object mark read that pins the range.
//
// The whole point is that the mark is **far past the first page of the op
// tree**, so the index it is read through is far past the first hundred
// patches. That is why the text length is not reduced here.
//
// The case loops over all four text encodings and says the answers are the same
// under all four because the text is pure ASCII; this runs one of them
// (`.unicode_code_point`, the port's default) because four encodings measure
// the same work four times over the same bytes.

fn markAtEnd(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    var out: Result = .{};
    const enc: TextEncoding = .unicode_code_point;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    const record = "the quick brown fox. ";
    try body.ensureTotalCapacity(gpa, ctx.sizes.text_reps * record.len);
    for (0..ctx.sizes.text_reps) |_| try body.appendSlice(gpa, record);

    // ── fixture ──
    const build_started = Timer.start(ctx.io);
    var doc = try am.AutoCommit.initWithEncoding(gpa, ctx.io, enc);
    defer doc.deinit();
    try doc.setActorId(.{ .bytes = "bench-mark-at-end" });
    const text = try doc.putObject(am.root, .{ .key = "text" }, .text);
    _ = try doc.commitWith(.none);
    try doc.spliceText(text, 0, 0, body.items);
    _ = try doc.commitWith(.none);
    const len = try am.read.length(&doc, text);
    if (len != body.items.len) return error.UnexpectedLength;
    out.mix(len);
    out.addPhase("build-document", build_started.stop());

    // ── the mark ──
    const mark_started = Timer.start(ctx.io);
    try doc.mark(text, len - 4, len, "bold", .none, .{ .bool_value = true });
    _ = try doc.commitWith(.none);
    out.addPhase("write-mark", mark_started.stop());

    // ── the reads ──
    const read_started = Timer.start(ctx.io);
    for ([_]usize{ len - 1, len - 4 }) |index| {
        const got = try am.read.getMarks(&doc, text, index, index + 1, gpa);
        defer gpa.free(got);
        if (got.len != 1) return error.MarkNotFound;
        if (!std.mem.eql(u8, got[0].name, "bold")) return error.WrongMarkName;
        out.mix(got.len);
    }
    for ([_]usize{ len - 5, len }) |index| {
        const got = try am.read.getMarks(&doc, text, index, index + 1, gpa);
        defer gpa.free(got);
        if (got.len != 0) return error.MarkFoundWhereThereIsNone;
    }
    // The mark really is over the last four positions, so the windows above
    // are not all empty by accident.
    const all = try am.read.marks(&doc, text, gpa);
    defer gpa.free(all);
    if (all.len != 1) return error.UnexpectedMarkRunCount;
    if (all[0].start != len - 4 or all[0].end != len) return error.UnexpectedMarkRange;
    if (!std.mem.eql(u8, all[0].name, "bold")) return error.WrongMarkName;
    out.mix(all.len);
    out.addPhase("read-marks", read_started.stop());

    // And a whole-text walk, so the workload is not only four windowed reads
    // and the walk over the op tree the case exists to exercise is measured.
    const walk_started = Timer.start(ctx.io);
    var walk = try am.read.listRange(&doc, text, am.read.IndexRange.all());
    var wide: usize = 0;
    var elements: usize = 0;
    while (try walk.next()) |item| {
        wide += item.width;
        elements += 1;
    }
    // Widths are the text's measure in this encoding, and the mark's own
    // elements carry none, so the widths and not the element count are what
    // add up to the length.
    if (wide != len) return error.UnexpectedTextWidth;
    out.mix(elements);
    out.addPhase("walk-text", walk_started.stop());

    return out;
}

// ── Workload 8: sync generation and the `sent_hashes` bulk merge ─────────────
//
// `generateSyncMessage` calls `State.extendSent(builder.payloadHashes())`:
// one sort of the message's hashes and one merge with the ascending,
// duplicate-free set. This replaces the original per-hash `insertSent`
// binary search and memmove. With acknowledgements withheld, the set grows
// across rounds, so the subject includes merging into an accumulated session.
// Receive-side reset and acknowledgement pruning can shrink that set.
//
// ── WHY THE PEER DOES NOT ANSWER DURING THE RUN ──
//
// A peer that answers every message empties the set every round, so it would
// not exercise merging into an accumulated session.
// `receiveSyncMessage` **is** the acknowledgement — there is no ack message at
// this commit — and it keeps only the hashes the peer's advertised heads do
// not cover (`src/sync/protocol.zig:708-713`, `sync.rs:430-431`). A peer that
// has just applied what we sent advertises heads that cover all of it, so a
// fully answered round is
//
//     generate -> the set holds this round's chunk -> receive the answer ->
//     the set is empty again
//
// and the merge then only ever sees one chunk, rather than a growing set.
//
// So the measured rounds below are the **push** side of a session the peer
// has not answered yet, which is a real path — a `SyncSession` that only ever
// pushes, or a peer that has gone quiet for a few rounds — and the only one on
// which the list grows. The peer still *receives* every message, so the
// session is a real round trip, the peer really does converge, and the checks
// at the end still have something to check. The withheld answer is delivered
// once, after the last round, and "the local side has nothing left to send"
// then holds for the same reason it always did.
//
// Everything below is public and is driven exactly as
// `test/upstream_doc_test.zig:4955-4969` drives it:
//
//   * `am.sync.state.State.new`             (`src/sync/state.zig:181`)
//   * `am.sync.protocol.generateSyncMessage` (`src/sync/protocol.zig:430`)
//   * `am.sync.protocol.receiveSyncMessage`  (`src/sync/protocol.zig:658`)
//
// No private is reached, including for the check below: **`sent_hashes` is a
// public field** (`src/sync/state.zig:156`), so the set the merge maintains
// can be inspected from outside.
fn syncRoundtrip(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    const rounds = ctx.sizes.sync_rounds;
    const chunk = ctx.sizes.sync_chunk;
    // `iters` is the number of generated messages that carried changes, which
    // is the unit the bulk merge runs in. `measures_own_time` because the
    // subject is one `generateSyncMessage`, not the whole round: the fixture
    // growth and the peer's half of the exchange are phases, not the clock.
    var out: Result = .{ .iters = rounds, .measures_own_time = true };

    var local = try am.AutoCommit.init(gpa, ctx.io);
    defer local.deinit();
    try local.setActorId(.{ .bytes = "bench-sync-roundtrip-local" });
    var peer = try am.AutoCommit.init(gpa, ctx.io);
    defer peer.deinit();
    try peer.setActorId(.{ .bytes = "bench-sync-roundtrip-peer" });

    var ls: am.sync.state.State = am.sync.state.State.new(gpa);
    defer ls.deinit();
    var rs: am.sync.state.State = am.sync.state.State.new(gpa);
    defer rs.deinit();

    const list = try local.putObject(am.root, .{ .key = "l" }, .list);
    _ = try local.commitWith(.none);

    // ── the handshake, once, outside every clock ──
    //
    // Four messages, and the run below depends on all four:
    //
    //   1. the peer advertises its empty document. The flags section is what
    //      tells the local side that the peer reads V2
    //      (`State.capabilitiesFor`, `src/sync/state.zig:409-412`), and the
    //      empty head list is what arms `sendDoc`
    //      (`src/sync/state.zig:341-344`), so that message 2 answers with
    //      the document instead of with an empty payload;
    //   2. the local side answers. Before it, `buildPayload` answers an empty
    //      payload because `State.their()` is null
    //      (`src/sync/protocol.zig:962`), so this is the first message that
    //      can carry anything, and its payload hashes go through the bulk
    //      merge;
    //   3. the peer applies it, so the peer is a document with history rather
    //      than a stub;
    //   4. the peer answers. **This message empties `sent_hashes`**
    //      (`src/sync/protocol.zig:709-712`), and it is also what leaves the
    //      local side holding a non-empty `their_heads`, so `sendDoc` is not
    //      armed again and every round below computes a delta.
    //
    // The set is checked on both sides of that acknowledgement, because the
    // acknowledgement taking all of it back out is the whole reason the
    // rounds below do not feed the peer's answers in.
    {
        const advertised = try peer.generateSyncMessage(gpa, &rs);
        const hello = advertised orelse return error.PeerWentQuietOnFirstMessage;
        try local.receiveSyncMessage(gpa, &ls, hello);

        const offered = try local.generateSyncMessage(gpa, &ls);
        const snapshot = offered orelse return error.LocalWentQuietInHandshake;
        // A whole document, so every hash the document holds is a hash the
        // bulk merge just recorded. If this ever stops holding, message 2
        // stopped being the message the comment above describes.
        if (ls.sent_hashes.items.len != local.doc.graph.len()) return error.HandshakeCarriedNoHashes;
        try peer.receiveSyncMessage(gpa, &rs, snapshot);

        const answered = try peer.generateSyncMessage(gpa, &rs);
        const ack = answered orelse return error.PeerWentQuietInHandshake;
        try local.receiveSyncMessage(gpa, &ls, ack);
    }
    if (ls.sent_hashes.items.len != 0) return error.HandshakeDidNotPrune;

    var gen_ns: u64 = 0;
    var peer_ns: u64 = 0;
    var written: usize = 0;
    var sent_before: usize = 0;

    for (0..rounds) |round| {
        // ── fixture growth, outside every clock ──
        //
        // One autocommit per element, so the local document gains exactly
        // `chunk` changes the peer has never seen and no hash of this round's
        // is one an earlier round already recorded. From the third round on
        // the payload is a change list; the port answers a whole document
        // instead while the payload is more than a third of the graph
        // (`src/sync/protocol.zig:992-996`), which is rounds 0 and 1 at these
        // sizes. Either way the hashes are the fixture's own.
        for (0..chunk) |_| {
            _ = try local.insert(list, written, .{ .int = @intCast(written) });
            _ = try local.commitWith(.none);
            written += 1;
        }

        // ── the subject: `generateSyncMessage`, bulk merge included ──
        //
        // `in_flight` is latched from this message on and nothing in the
        // measured run clears it, which is safe for one reason and one
        // reason only: the fixture moved the heads, so `heads_unchanged` is
        // false and the `if (state.in_flight) return null` arm inside it
        // (`src/sync/protocol.zig:556-564`) is never reached. A round that
        // did not move the heads would get `NoMessageFromLocal` below rather
        // than a quiet zero-length payload.
        const gen_started = Timer.start(ctx.io);
        const generated = try local.generateSyncMessage(gpa, &ls);
        const this_gen = gen_started.stop();
        gen_ns += this_gen;
        const message = generated orelse return error.NoMessageFromLocal;

        // **Exactly** one chunk of new hashes, and not one pruned away.
        //
        // The first round records `chunk + 1` rather than `chunk`, and the
        // one is the handshake's: message 2 put that change on the wire as a
        // whole document and the acknowledgement then took it back out of the
        // set, so round 0's payload — which is a whole document too, because
        // a payload of more than a third of the graph is cheaper as one
        // snapshot (`src/sync/protocol.zig:992-996`) — records it again. Every
        // round after it carries exactly its own chunk. The same
        // `sent_hashes.items.len == local.doc.graph.len()` the run ends on
        // depends on that one hash being back, so the two checks are two ends
        // of the same fact.
        //
        // Exact growth checks that every payload hash was recorded, with no
        // prune or clear between rounds. Counting the first snapshot's
        // already-advertised hash again is intentional; subsequent rounds
        // add only their own fresh chunk.
        const want = if (round == 0) chunk + 1 else chunk;
        const sent_now = ls.sent_hashes.items.len;
        if (sent_now != sent_before + want) return error.NoHashesRecorded;
        sent_before = sent_now;
        out.mix(sent_now);

        // The peer applies every message, so the whole session really is
        // delivered and the convergence checks at the end have something to
        // check. It is a phase, not the clock, and it is deliberately not
        // answered: see the note at the head of this workload.
        const recv_started = Timer.start(ctx.io);
        try peer.receiveSyncMessage(gpa, &rs, message);
        peer_ns += recv_started.stop();
    }

    out.addPhase("local-generate", gen_ns);
    out.addPhase("peer-exchange", peer_ns);

    // ── correctness ──
    //
    // **The set, not just the count.** The bulk merge must preserve the
    // ascending, duplicate-free `BTreeSet` invariant that `State.encode`
    // asserts and `sentContains` binary-searches. Appending unsorted hashes
    // or dropping deduplication can pass a length check and fail this one.
    const sent = ls.sent_hashes.items;
    for (sent, 0..) |hash, i| {
        if (i == 0) continue;
        if (ChangeHash.order(sent[i - 1], hash) != .lt) return error.SentHashesUnsorted;
    }
    // Every change the document holds went on the wire exactly once, which is
    // the whole point of a set: the count is the graph's, not a running tally.
    if (sent.len != local.doc.graph.len()) return error.SentHashCountDiffers;

    // ── convergence ──
    //
    // Both peers hold the same heads and the peer's copy of the list has
    // every element the local one has. The last check, below, is the one that
    // would fail if a payload were dropped or truncated.
    const local_heads = try local.getHeads(gpa);
    defer gpa.free(local_heads);
    const peer_heads = try peer.getHeads(gpa);
    defer gpa.free(peer_heads);
    if (local_heads.len != peer_heads.len) return error.HeadCountDiffers;
    for (local_heads, peer_heads) |a, b| {
        if (!a.eql(b)) return error.HeadsDiffer;
    }
    const peer_list = (try am.read.get(&peer, am.root, .{ .key = "l" })) orelse
        return error.NoListOnPeer;
    if (try am.read.length(&peer, peer_list.id) != written) return error.PeerListLengthDiffers;
    out.mix(written);

    // The answer the rounds above withheld, delivered once. Receiving it is
    // what clears `in_flight` (`src/sync/protocol.zig:664`) and empties the
    // set, and with the peer's heads now equal to ours and nothing left to
    // send, the next generate is null
    // (`src/sync/protocol.zig:556-559`).
    {
        const final_advertised = try peer.generateSyncMessage(gpa, &rs);
        const final_hello = final_advertised orelse return error.PeerWentQuietAtTheEnd;
        try local.receiveSyncMessage(gpa, &ls, final_hello);
    }
    // A `var` optional so the capture is a mutable pointer and `deinit` has a
    // message it can actually free (`test/upstream_doc_test.zig:5444-5445`).
    var leftover = try local.generateSyncMessage(gpa, &ls);
    if (leftover) |*spare| {
        spare.deinit();
        return error.LocalStillHasChangesToSend;
    }

    out.ns = gen_ns;
    return out;
}

// ── Workload 9: `hashForOpid` actor-change binary search ──────────────────────
//
// `hashForOpid` delegates to `ChangeGraph.opidToHash`, which binary-searches
// the actor's own change list by operation-counter interval, like upstream
// `ChangeGraph::opidToHash`. The fixture holds many one-operation changes;
// newest and oldest operation queries exercise both ends of that same search.
// The former whole-node-table linear scan is not the current subject.
//
// **Public surface, reached the way `src/transaction.zig:1446-1472` reaches
// it** — a raw document, `Transaction.open`, and the module-level
// `hashForOpid` exported in the canonical `am.transaction` namespace:
//
//   * `am.Transaction.open`
//   * `Transaction.commitWith`
//   * `am.transaction.hashForOpid`
//   * `doc.ops.idToExid`                      (`src/opset/op_set.zig:3240`)

/// The first eight bytes of a change hash, big-endian, so the checksum folds
/// an answer rather than its address.
fn hashFold(h: ChangeHash) u64 {
    return std.mem.readInt(u64, h.bytes[0..8], .big);
}

fn hashForOpidWorkload(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    const changes = ctx.sizes.opid_changes;
    const calls = ctx.sizes.opid_calls;
    // Zero of either would leave the loop below with nothing to iterate and
    // `last_hash` uninitialised, and a benchmark that measures nothing must
    // fail rather than report a clean zero.
    if (changes == 0 or calls == 0) return error.NothingToMeasure;
    // `iters` is one `hashForOpid` call. `measures_own_time` because the
    // subject is the lookup, not graph construction. Both endpoint arms use
    // the same actor-change binary search; the legacy phase names are retained
    // for comparison with earlier benchmark output.
    var out: Result = .{ .iters = calls, .measures_own_time = true };

    var doc = try Document.init(gpa, ctx.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "bench-hash-for-opid" });

    // ── fixture: `changes` committed changes, one operation each ──
    //
    // The cheapest shape a change can have, and deliberately so: the cost
    // under test is one actor-change interval query, so every extra operation
    // would be fixture work the question does not require.
    const build_started = Timer.start(ctx.io);
    var first_hash: ?ChangeHash = null;
    var last_hash: ChangeHash = undefined;
    var first_id: OpId = undefined;
    var last_id: OpId = undefined;
    var key_buf: [24]u8 = undefined;
    for (0..changes) |i| {
        var tx = try am.Transaction.open(gpa, &doc);
        defer tx.deinitClosed(); // The entire document dies on error.
        const key = try std.fmt.bufPrint(&key_buf, "k{d}", .{i});
        // `Transaction.put` answers `?OpId` (`src/transact.zig:935`): null for
        // a repeated put on the same register, and every key here is new, so
        // a null would be the port refusing to write what it was asked to.
        const id = (try tx.put(am.root, .{ .key = key }, .{ .int = @intCast(i) })).?;
        var result = try tx.commitWith(.none);
        defer result.deinit(gpa);
        const hash = result.hash orelse return error.EmptyCommit;
        if (first_hash == null) {
            first_hash = hash;
            first_id = id;
        }
        last_hash = hash;
        last_id = id;
    }
    out.addPhase("build-graph", build_started.stop());
    out.mix(doc.graph.len());

    const first_exid = doc.ops.idToExid(first_id);
    const last_exid = doc.ops.idToExid(last_id);

    // A transaction to ask through. It writes nothing; `hashForOpid` reads
    // `tx.doc.graph` (`src/transaction.zig:413`) and nothing else on the
    // transaction, so an open one is all the call needs.
    var probe = try am.Transaction.open(gpa, &doc);
    defer probe.deinitClosed(); // Read-only journal; the document dies with it.

    // ── newest operation: query the actor's last change interval ──
    const last_started = Timer.start(ctx.io);
    for (0..calls) |_| {
        const got = am.transaction.hashForOpid(&probe, last_exid) orelse
            return error.NoHashForTheLastOperation;
        if (!got.eql(last_hash)) return error.WrongHashForTheLastOperation;
        out.mix(hashFold(got));
    }
    const last_ns = last_started.stop();
    out.addPhase("scan-last-op", last_ns);

    // ── oldest operation: query the actor's first change interval ──
    //
    // Same call, document and search; only the queried interval differs.
    // Compare these timed phases, not whole-process setup instructions.
    const first_started = Timer.start(ctx.io);
    for (0..calls) |_| {
        const got = am.transaction.hashForOpid(&probe, first_exid) orelse
            return error.NoHashForTheFirstOperation;
        if (!got.eql(first_hash.?)) return error.WrongHashForTheFirstOperation;
        out.mix(hashFold(got));
    }
    out.addPhase("scan-first-op", first_started.stop());

    // ── absent-id checks and a repeated valid lookup ──
    if (am.transaction.hashForOpid(&probe, am.root) != null) {
        return error.RootNamedAChange;
    }
    const absent = am.ExId.fromParts(9_000_000, probe.actor) orelse return error.BadExId;
    if (am.transaction.hashForOpid(&probe, absent) != null) {
        return error.AbsentIdNamedAChange;
    }
    if (am.transaction.hashForOpid(&probe, last_exid) == null) {
        return error.LostHashForTheLastOperation;
    }

    out.ns = last_ns;
    return out;
}

// ── Workload 10: list traversal with one held element cursor ────────────────
//
// The public chain is `am.read.listRange` → `ListRange.next` →
// `ListDiffItem.exportItem` → `elementWidth` → the held `ListRange.elems`.
// Each walk owns one element cursor; it advances its five columns instead of
// rebuilding fresh cursors for every element. The two delta columns still
// carry encoded counter data, but the former ten-cursors-per-element account
// does not describe this implementation.
// `mark-at-end` walks text through the same `ListRange`; this workload walks
// the integer list that `elementWidth` is written for.
//
// ── And the fixture is not what this gate measures ──────────────────────────
//
// The first version of this workload built its 50 000 elements with
// `for (0..n) |i| try tx.insert(list, i, ...)` and timed the walk with
// `measures_own_time`. `perf stat -e instructions` **counts the whole
// process**, so that run reported the loop: 4.69e12 instructions over 1027 s
// of wall clock against a subject timer of 16.1 s — about 98% of the count was
// the fixture, and the `BENCH` line, which carried the subject, could not be
// reconciled with the instruction count a reader was told to quote. A gate
// whose headline number and whose headline metric disagree is worse than no
// gate, because both look authoritative.
//
// Two things fix it, and both are here.
//
// **The lever was not "append at the end".** `tx.insert(list, i, …)` over
// `i = 0..n` into an empty list *already* appends at the end every time: at
// step `i` the list holds `i` elements, so `i` is the last index. The obvious
// cheaper build was the one already in the file.
//
// **The lever is one call instead of `n`.** `Transaction.splice` is the door
// upstream's `Transactable::splice` goes through (`inner.rs:673-799`), and it
// reaches the list batch kernel: **one**
// `queryInsertAt` for the whole run and one `Batch.finish`
// (`src/transact.zig:1343`, `:1373`), against **one** `queryInsertAt` and
// **one** `insertLocalOp` per element for the loop, which goes through
// `Transaction.insert` (`src/transact.zig:975-985`) → `doInsert`
// (`src/transact.zig:866-897`) and so re-queries and re-splices the growing
// op set once per element.
//
// **And the guard, so this cannot be misread again.** The workload fails with
// `error.SubjectIsNotTheCost` unless the subject is at least
// `list_width_subject_floor_pct` of everything the workload measured,
// fixture and teardown included. A run whose fixture outweighs its subject
// stops the run rather than printing a number that reads like a statement
// about `elementWidth` and is not one.

/// Thirteen bytes, eleven code points: the sibling text object's length under
/// `.unicode_code_point` and under `.utf8_code_unit` are different numbers, so
/// reading it back proves the document really is under the encoding asked for
/// rather than under whichever one it defaulted to.
const list_width_sample = "h\u{e9}llo w\u{f6}rld";

/// **The floor the subject has to clear, as a percentage of everything this
/// workload measured.** `perf stat -e instructions` counts the whole process,
/// so default runs below this subject-share floor are refused. A region count
/// does not use this guard to qualify its instruction attribution.
/// Ninety is well above the old fixture's ~1.5% subject share. This measured
/// wall-time share is not an instruction attribution or a guarantee against
/// scheduler noise; inspect the phase split for each accepted run.
const list_width_subject_floor_pct = 90;

/// How many elements the two fixture builders are compared over. Sixty-four is
/// well past "long enough to have predecessors, successors and a visible
/// tail", and small enough that the comparison costs nothing beside a walk of
/// `list_width_elements`.
const list_width_agree_elements = 64;

/// The actor **both** fixture builders stamp on their document, so the two
/// saved byte strings are comparable: the actor is in the footer of every
/// change, so two documents built by different actors never save alike.
const list_width_fixture_actor = "bench-list-width-fixture";

/// One region's share of another, as a percentage. Only ever called with a
/// non-zero `whole`; the total here is a document build plus a teardown.
fn sharePct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole)) * 100.0;
}

/// **Proves the batched fixture reads back as the sequential one.**
///
/// Two raw documents of `elements` integers under key `"l"`: one built
/// by `elements` `Transaction.insert` calls at ascending positions — what this
/// workload used to do, and what a consumer that appends one element at a time
/// still does — and one built by a single `Transaction.splice`. Both
/// are read back through the same `am.read.listRange` the subject uses, and
/// every element has to agree: its index, a width of exactly 1, no conflict,
/// not an object, and the integer written at that position. So a batch that
/// made the walk cheaper by making it wrong fails here, at 64 elements, before
/// the timed region is entered.
///
/// The saved bytes are **reported, not required**. The bytes are the
/// document's identity on the wire and this workload's contract is the
/// *materialized* document, so a difference there is a fact about the
/// encoding and not a failure — and printing it puts the fact on the record
/// rather than leaving the next reader to assume they are equal.
///
/// Returns `elements`, for the checksum.
fn listFixtureAgreement(
    gpa: Allocator,
    io: Io,
    enc: TextEncoding,
    elements: usize,
) !u64 {
    var seq = try Document.initWithEncoding(gpa, io, enc);
    defer seq.deinit();
    seq.setActorId(.{ .bytes = list_width_fixture_actor });
    var seq_tx = try am.Transaction.open(gpa, &seq);
    var seq_tx_live = true;
    defer if (seq_tx_live) seq_tx.deinitClosed();
    const seq_list = try seq_tx.putObject(am.root, .{ .key = "l" }, .list);
    for (0..elements) |i| _ = try seq_tx.insert(seq_list, i, .{ .int = @intCast(i) });
    var seq_result = try seq_tx.commitWith(.none);
    const seq_has_hash = seq_result.hash != null;
    seq_result.deinit(gpa);
    if (!seq_has_hash) return error.EmptyCommit;
    seq_tx.deinitClosed();
    seq_tx_live = false;

    var batch = try Document.initWithEncoding(gpa, io, enc);
    defer batch.deinit();
    batch.setActorId(.{ .bytes = list_width_fixture_actor });
    var batch_tx = try am.Transaction.open(gpa, &batch);
    defer batch_tx.deinitClosed();
    const batch_list = try batch_tx.putObject(am.root, .{ .key = "l" }, .list);
    {
        const values = try gpa.alloc(am.hydrate.Value, elements);
        defer gpa.free(values);
        for (values, 0..) |*slot, i| slot.* = .{ .int = @intCast(i) };
        try batch_tx.splice(batch_list, 0, 0, values);
    }
    var batch_result = try batch_tx.commitWith(.none);
    defer batch_result.deinit(gpa);
    if (batch_result.hash == null) return error.EmptyCommit;

    var seq_walk = try am.read.listRange(&seq, seq_list, am.read.IndexRange.all());
    var batch_walk = try am.read.listRange(&batch, batch_list, am.read.IndexRange.all());
    var seen: usize = 0;
    while (true) {
        const a = try seq_walk.next();
        const b = try batch_walk.next();
        if (a == null or b == null) {
            if (a != null or b != null) return error.FixturesDisagreeOnLength;
            break;
        }
        if (a.?.index != seen or b.?.index != seen) return error.FixturesDisagreeOnIndex;
        if (a.?.width != 1 or b.?.width != 1) return error.FixturesDisagreeOnWidth;
        if (a.?.conflict or b.?.conflict) return error.FixtureConflicts;
        const av = switch (a.?.value) {
            .object => return error.FixtureElementIsAnObject,
            .scalar => |s| switch (s) {
                .int => |got| got,
                else => return error.FixtureElementIsNotAnInt,
            },
        };
        const bv = switch (b.?.value) {
            .object => return error.FixtureElementIsAnObject,
            .scalar => |s| switch (s) {
                .int => |got| got,
                else => return error.FixtureElementIsNotAnInt,
            },
        };
        if (av != @as(i64, @intCast(seen))) return error.FixtureValueDiffers;
        if (bv != av) return error.FixturesDisagreeOnValue;
        seen += 1;
    }
    if (seen != elements) return error.FixturesDisagreeOnCount;
    if (try am.read.length(&seq, seq_list) != elements) return error.FixtureLengthDiffers;
    if (try am.read.length(&batch, batch_list) != elements) return error.FixtureLengthDiffers;

    const seq_bytes = try seq.save(gpa);
    defer gpa.free(seq_bytes);
    const batch_bytes = try batch.save(gpa);
    defer gpa.free(batch_bytes);
    std.debug.print(
        "#   list-width: the sequential and the batched {d}-element fixtures read back identically; their saved bytes are {s}\n",
        .{
            elements,
            if (std.mem.eql(u8, seq_bytes, batch_bytes)) "identical" else "not identical",
        },
    );
    return elements;
}

fn listWidth(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    const n = ctx.sizes.list_width_elements;
    const passes = ctx.sizes.list_width_passes;
    // Same rule as the workload above: a zero is a broken measurement, not a
    // fast one.
    if (n == 0 or passes == 0) return error.NothingToMeasure;
    // The subject wall timer is independent of the process-share guard.
    // Default mode still requires that guard; region mode directly counts the
    // complete read-list loop without claiming whole-process attribution.
    var out: Result = .{ .iters = passes, .measures_own_time = true };
    // The guard's own denominator: every region below, fixture and teardown
    // included.
    const total = Timer.start(ctx.io);

    // The port's default encoding, and the one `mark-at-end` uses, so the two
    // list walks are on the same measure.
    const enc: TextEncoding = .unicode_code_point;

    // ── fixture ──
    const build_started = Timer.start(ctx.io);
    var doc = try Document.initWithEncoding(gpa, ctx.io, enc);
    var doc_live = true;
    defer if (doc_live) doc.deinit();
    doc.setActorId(.{ .bytes = "bench-list-width" });

    var tx = try am.Transaction.open(gpa, &doc);
    var tx_live = true;
    defer if (tx_live) tx.deinitClosed();
    const list = try tx.putObject(am.root, .{ .key = "l" }, .list);
    const probe_text = try tx.putObject(am.root, .{ .key = "t" }, .text);
    try tx.spliceText(probe_text, 0, 0, list_width_sample);
    {
        // **One splice, not `n` inserts.** Same list, same one transaction,
        // same one commit; see the note at the head of this workload for what
        // this replaces and what that cost.
        const values = try gpa.alloc(am.hydrate.Value, n);
        defer gpa.free(values);
        for (values, 0..) |*slot, i| slot.* = .{ .int = @intCast(i) };
        try tx.splice(list, 0, 0, values);
    }
    var commit_result = try tx.commitWith(.none);
    var commit_result_live = true;
    defer if (commit_result_live) commit_result.deinit(gpa);
    if (commit_result.hash == null) return error.EmptyCommit;
    const build_ns = build_started.stop();
    out.addPhase("build-list", build_ns);

    // Open a fresh disabled event per sample so enabled/running times cannot
    // accumulate across repeats. Closing also stops it on any loop error.
    var counter: ?perf_instructions.Counter = if (ctx.region_instructions)
        try perf_instructions.Counter.open()
    else
        null;
    defer if (counter) |*event| event.deinit();

    // ── the subject ──
    const read_started = Timer.start(ctx.io);
    if (counter) |*event| try event.enable();
    for (0..passes) |_| {
        var walk = try am.read.listRange(&doc, list, am.read.IndexRange.all());
        var seen: usize = 0;
        while (try walk.next()) |item| {
            // The index the element reports must be its position, in order.
            if (item.index != seen) return error.ElementIndexDiffers;
            // **Every list element is one unit wide, under every encoding**
            // (`src/opset/op.zig:2178-2181`), so a width read that reached the
            // wrong row, or that took the `elemidAt` walk's answer off the
            // element's first row instead of its last, does not go unnoticed:
            // it shows up as a count that is not `seen`.
            if (item.width != 1) return error.ElementWidthDiffers;
            if (item.conflict) return error.ElementConflicts;
            switch (item.value) {
                .object => return error.ElementIsAnObject,
                .scalar => |v| switch (v) {
                    .int => |got| {
                        if (got != @as(i64, @intCast(seen))) return error.ElementValueDiffers;
                    },
                    else => return error.ElementIsNotAnInt,
                },
            }
            out.mix(item.index);
            out.mix(item.width);
            seen += 1;
        }
        if (seen != n) return error.ElementCountDiffers;
        out.mix(seen);
    }
    if (counter) |*event| out.counter_reading = try event.finish();
    const read_ns = read_started.stop();
    out.addPhase("read-list", read_ns);

    // ── everything that is not the subject, in one phase ──
    //
    // The encoding proof, the two fixture builders compared against each
    // other, and the independent oracle: `length` counts the object's visible
    // elements without going anywhere near `elementWidth`, so the walk's own
    // count agreeing with it is a second, separate statement about the same
    // document.
    const verify_started = Timer.start(ctx.io);
    if (am.read.textEncoding(&doc) != enc) return error.WrongTextEncoding;
    if (try am.read.length(&doc, probe_text) != enc.width(list_width_sample)) {
        return error.TextLengthIsNotInThisEncoding;
    }
    const sample_bytes = try am.read.text(&doc, probe_text, gpa);
    defer gpa.free(sample_bytes);
    if (!std.mem.eql(u8, sample_bytes, list_width_sample)) return error.TextBytesDiffer;
    out.mix(try listFixtureAgreement(gpa, ctx.io, enc, @min(n, list_width_agree_elements)));
    if (try am.read.length(&doc, list) != n) return error.ListLengthDiffers;
    out.mix(n);
    const verify_ns = verify_started.stop();
    out.addPhase("verify", verify_ns);

    // ── the teardown, which `perf stat` counts and nothing timed ──
    //
    // Freeing a document this size is work the instruction count sees, so it
    // belongs in the denominator the guard divides by rather than outside it.
    const free_started = Timer.start(ctx.io);
    commit_result.deinit(gpa);
    commit_result_live = false;
    tx.deinitClosed();
    tx_live = false;
    doc.deinit();
    doc_live = false;
    const free_ns = free_started.stop();
    out.addPhase("teardown", free_ns);

    // ── the guard ──
    const total_ns = total.stop();
    std.debug.print(
        "#   list-width: subject {d} ns of {d} ns measured = {d:.2}%" ++
            " (floor {d}%); fixture {d:.2}%, verify {d:.2}%, teardown {d:.2}%\n",
        .{
            read_ns,
            total_ns,
            sharePct(read_ns, total_ns),
            list_width_subject_floor_pct,
            sharePct(build_ns, total_ns),
            sharePct(verify_ns, total_ns),
            sharePct(free_ns, total_ns),
        },
    );
    if (read_ns * 100 < list_width_subject_floor_pct * total_ns) {
        std.debug.print(
            "#   list-width: subject share is below the {d}% floor; " ++
                "process-wide instruction attribution is not qualified\n",
            .{list_width_subject_floor_pct},
        );
        if (!ctx.region_instructions) {
            std.debug.print("#   refusing to report a BENCH result\n", .{});
            return error.SubjectIsNotTheCost;
        }
    }
    if (ctx.region_instructions) {
        std.debug.print(
            "#   region count covers read-list only; no BENCH or accepted whole-process attribution\n" ++
                "#   wall time includes counter control/read overhead; instruction boundary overhead is not subtracted\n",
            .{},
        );
    }

    out.ns = read_ns;
    return out;
}

// ── Workload 11: n single-row inserts in ONE transaction, ONE commit ────────
//
// **This is the shape that measured about 1011 s.** 50 000
// `tx.insert(list, i, …)` calls at ascending positions inside **one**
// transaction, committed **once**, cost **about 1011 s of wall clock and
// roughly 4.69e12 instructions** — the `list-width` fixture, quoted at
// `bench/README.md` §7 and again at `src/opset/op_set.zig:4245-4253`. Two
// O(rows)-per-insert stages sat on this path: `queryInsertAtSlow`'s
// whole-object cross-check, now behind `check_slow_paths`
// (`src/opset/op_set.zig:4264`), and `Column.rebuildAggs`, now narrowed to the
// range the splice touched (`src/hexane/column.zig:6776`, called from
// `Column.splice`'s settled arm at `src/hexane/column.zig:4303`).
//
// **And nothing measured it.** `list-width`'s fixture measured it as a
// by-product and was deleted, because a gate that reports its own fixture's
// cost is not a gate (`:1663-1673`). So the largest number this repository ever
// recorded for a write path survived only as a comment about a *different*
// workload, and a change could put either stage back with no gate noticing.
// This one is that gate, and it differs from `list-width` in the way that
// matters: **here the cost is the subject**, so there is no fixture for it to
// be confused with, and nothing in this file measured it by accident.
//
// **The public chain**, all of it reachable from `@import("zautomerge")` and
// none of it a private import:
//
//   * `am.Transaction.open`                        `src/transact.zig`
//   * `am.Transaction.putObject`                   `src/transact.zig`
//   * `am.Transaction.insert`                      `src/transact.zig`
//     → `Transaction.doInsert`                     `src/transact.zig:866`
//       → `OpSet.queryInsertAt`                    `src/opset/op_set.zig:4213`
//         → `OpSet.queryInsertAtSlow`              `src/opset/op_set.zig:4297`,
//           reached on the fast path only behind `check_slow_paths`
//           (`src/opset/op_set.zig:4264`) — the dominant of the two stages
//       → `Transaction.insertLocalOp`              `src/transact.zig:632`
//         → `OpSet.splice` → `Column.splice` → `Column.rebuildAggs`
//                                                `src/hexane/column.zig:6776`
//   * `Transaction.commitWith`                     `src/transact.zig`
//
// `hash-for-opid` (`:1530-1533`) opens and commits the same way, so the three
// manual-transaction doors a consumer uses are all in this file.

/// The map key the list is written under, on **both** arms. Reading it back by
/// key in the reloaded document rather than reusing the id the transaction
/// handed out is what proves the register itself survived the save.
const insert_loop_key = "l";

/// The actor **both** arms stamp on their documents. Fixed bytes, and a
/// `CommitOptions.none` commit — whose time is **zero, not "now"**
/// (`src/transaction.zig:178-180`) — make the change hash the same on every
/// run, which is what lets the committed hash go into the checksum.
const insert_loop_actor = "bench-insert-loop";

/// **The factor `insert_loop_large` is `insert_loop_small` times.** Fixed, and
/// checked at run time (`error.SizesAreNotAtTheDocumentedRatio`), because the
/// growth guard below is a quadratic detector only at a *known* size ratio.
const insert_loop_size_ratio = 4;

/// **The per-insert cost at `insert_loop_large` may not exceed this multiple of
/// the per-insert cost at `insert_loop_small`.**
///
/// The measurement is the *ratio*, not either number, because both numbers move
/// with the host and the ratio does not:
///
/// * a per-insert cost **flat in `n`** — what a write path with no O(rows)
///   stage costs — reads about **1.00**, and that is the finding;
/// * a per-insert cost that **grows with `n`**, which is exactly what an
///   O(rows)-per-insert stage is, reads about **4.00**: the size ratio.
///
/// Two sits between them with room for the wall clock's few percent on a busy
/// host and for the fixed cost of opening a transaction and committing, which
/// is a larger share of the small arm's total and so pulls the measured ratio
/// *below* its true value — the direction that cannot hide a regression.
/// A run past the ceiling **fails** and prints no `BENCH` line, the same
/// refusal `list-width` makes when its fixture outweighs its subject
/// (`error.SubjectIsNotTheCost`, `:1999`): a benchmark that cannot tell a flat
/// cost from a quadratic one must not report a number that reads like a
/// statement about which of the two it measured.
const insert_loop_growth_ceiling = 2.0;

/// What one arm cost, split by what the clock covered.
const InsertLoopTiming = struct {
    /// `Transaction.open` through the `commitWith` that returns. **The
    /// subject**, and the region the ~1011 s figure was measured over.
    build_ns: u64,
    /// The save, the reload and the read-back of every element. Correctness,
    /// deliberately outside `build_ns`.
    verify_ns: u64,
    /// Freeing the reloaded document, the saved bytes, the transaction and the
    /// document. `perf stat` counts it and nothing timed it.
    free_ns: u64,
};

/// Builds one arm: `n` `Transaction.insert` calls at **ascending** positions
/// inside **one** transaction and **one** commit, then everything the run has to
/// be able to claim about what that produced.
///
/// **Ascending positions are the shape that was measured**, and the note at
/// `:1677-1680` says why "append at the end instead" is not a different shape
/// at all: at step `i` the list holds `i` elements, so `i` *is* the last index.
/// That loop was already appending, and it is the loop that cost 1011 s.
///
/// Every observation goes through `out`, so nothing here can be optimised away
/// and both arms fold into one checksum.
fn insertLoopShape(
    gpa: Allocator,
    io: Io,
    n: usize,
    out: *Result,
) !InsertLoopTiming {
    var t: InsertLoopTiming = .{ .build_ns = 0, .verify_ns = 0, .free_ns = 0 };

    var doc = try Document.init(gpa, io);
    var doc_live = true;
    defer if (doc_live) doc.deinit();
    doc.setActorId(.{ .bytes = insert_loop_actor });

    // ── the subject ──
    //
    // The clock opens before `Transaction.open` and closes after `commitWith`
    // returns, so the subject is the **whole transaction**: the list's own
    // make, `n` single-row inserts, and the one commit that turns them into a
    // change. Document creation is O(1) and the verification below is a phase,
    // so neither is inside this region.
    const started = Timer.start(io);
    var tx = try am.Transaction.open(gpa, &doc);
    var tx_live = true;
    defer if (tx_live) tx.deinitClosed();
    const list = try tx.putObject(am.root, .{ .key = insert_loop_key }, .list);

    // **Every insert is an operation of its own, in order.** `insert` answers
    // `WriteError!OpId` (`src/transact.zig:975`), so there is no null to
    // confuse with a repeated write the way `put`'s `?OpId` has
    // (`src/transact.zig:930`), and the counters are contiguous because
    // `nextId` is `start_op + pending.len` (`src/transact.zig:515-518`). A loop
    // that stopped early, skipped an element or reordered two inserts fails
    // here instead of reporting a faster run.
    var first_counter: u32 = 0;
    for (0..n) |i| {
        const id = try tx.insert(list, i, .{ .int = @intCast(i) });
        if (i == 0) {
            first_counter = id.counter;
        } else if (id.counter != first_counter + @as(u32, @intCast(i))) {
            return error.InsertOpIdsAreNotContiguous;
        }
    }
    // The list's own make plus `n` inserts, staged and not yet committed.
    if (tx.count() != n + 1) return error.WrongPendingOperationCount;

    // **One commit.** A null hash is `Transaction.commit`'s answer for a
    // transaction with nothing pending (`src/transact.zig:1418-1421`), so a
    // null here would be the port refusing to write what it was asked to.
    var commit_result = try tx.commitWith(.none);
    var commit_result_live = true;
    defer if (commit_result_live) commit_result.deinit(gpa);
    const hash = commit_result.hash orelse return error.EmptyCommit;
    t.build_ns = started.stop();

    // ── the transaction's final state ──
    //
    // `commit` sets `closed` on both exits (`src/transact.zig:1420`, `:1467`),
    // and each of the three doors that can see it is asked: the field itself,
    // `count` (`src/transact.zig:500`), which must be drained, and `maxOp`
    // (`src/transaction.zig:379`), which refuses a closed transaction. A
    // transaction left open would be one whose operations never reached the
    // document; a non-empty pending list would be operations the commit did not
    // carry.
    if (!tx.closed) return error.TransactionIsNotClosedAfterCommit;
    if (tx.count() != 0) return error.CommitLeftOperationsPending;
    // Comparing the error union against the error literal is the door refusing
    // in one line: a closed transaction answers `error.InvalidOp` and nothing
    // else (`src/transaction.zig:379-380`).
    if (am.transaction.maxOp(&tx) != error.InvalidOp) {
        return error.ClosedTransactionStillAnswersMaxOp;
    }

    // **One transaction and one commit is one change**, which is what the shape
    // implies. `doc.graph` is a public field (`src/doc.zig:2616`) and
    // `hash-for-opid` reads `doc.graph.len()` the same way (`:1613`).
    if (doc.graph.len() != 1) return error.OneTransactionIsNotOneChange;
    out.mix(doc.graph.len());
    // Deterministic, because the actor above is fixed and the commit time is
    // zero: the committed hash is the same on every run, so it belongs in the
    // checksum, and it folds in every operation the change carries.
    out.mix(hashFold(hash));

    // ── the saved document, loaded back, and read ──
    //
    // **The read-back is on a reloaded document, not on `doc`.** A change that
    // made the writes cheaper by writing something the encoder loses, or that
    // the reader rebuilds differently, passes a read-back against the live
    // document and fails this one. `Document.load` (`src/doc.zig:3801`) is the
    // public door, and the encoding is the document's own — reported by
    // `am.read.textEncoding` (`src/read.zig:2168`) rather than assumed, so the
    // load cannot quietly disagree with the save about it.
    const verify_started = Timer.start(io);
    const bytes = try doc.save(gpa);
    var bytes_live = true;
    defer if (bytes_live) gpa.free(bytes);
    var loaded = try Document.load(gpa, io, bytes, am.read.textEncoding(&doc));
    var loaded_live = true;
    defer if (loaded_live) loaded.deinit();
    if (loaded.graph.len() != 1) return error.ReloadHasADifferentChangeCount;

    // **The list is found by key in the reloaded document**, not by reusing the
    // id the transaction handed out: a document that encoded the list but not
    // the register naming it has to fail here. For an object value `DocItem.id`
    // *is* that object's id (`src/read.zig:401-408`).
    const found = (try am.read.get(&loaded, am.root, .{ .key = insert_loop_key })) orelse
        return error.NoListUnderItsKey;
    const holds_a_list = switch (found.value) {
        .object => |kind| kind == .list,
        .scalar => false,
    };
    if (!holds_a_list) return error.ReloadedRegisterIsNotAList;
    const reloaded_list = found.id;

    // **`am.read.length` on both**, and it is a prefix count with nothing to do
    // with the walk below, so the two agreeing is a second and separate
    // statement about the same document.
    if (try am.read.length(&doc, list) != n) return error.ListLengthDiffers;
    if (try am.read.length(&loaded, reloaded_list) != n) return error.ReloadLengthDiffers;

    // **The list reads back with `n` elements at indices `0..n-1`, each the
    // value it was given** — on the document that came back off the wire.
    var walk = try am.read.listRange(&loaded, reloaded_list, am.read.IndexRange.all());
    var seen: usize = 0;
    while (try walk.next()) |item| {
        if (item.index != seen) return error.ElementIndexDiffers;
        // Every list element is one unit wide under every encoding
        // (`src/opset/op.zig:2178-2181`), so a width read that reached the
        // wrong row shows up as a number that is not 1.
        if (item.width != 1) return error.ElementWidthDiffers;
        if (item.conflict) return error.ElementConflicts;
        switch (item.value) {
            .object => return error.ElementIsAnObject,
            .scalar => |v| switch (v) {
                .int => |got| {
                    if (got != @as(i64, @intCast(seen))) return error.ElementValueDiffers;
                },
                else => return error.ElementIsNotAnInt,
            },
        }
        out.mix(item.index);
        out.mix(item.width);
        seen += 1;
    }
    if (seen != n) return error.ElementCountDiffers;
    out.mix(seen);
    t.verify_ns = verify_started.stop();

    // ── the teardown, which `perf stat` counts and nothing timed ──
    //
    // Freeing a document this size is work the instruction count sees, so it is
    // reported rather than assumed away.
    const free_started = Timer.start(io);
    loaded.deinit();
    loaded_live = false;
    gpa.free(bytes);
    bytes_live = false;
    commit_result.deinit(gpa);
    commit_result_live = false;
    tx.deinitClosed();
    tx_live = false;
    doc.deinit();
    doc_live = false;
    t.free_ns = free_started.stop();
    return t;
}

fn insertLoop(ctx: Ctx) !Result {
    const gpa = ctx.gpa;
    const small = ctx.sizes.insert_small;
    const large = ctx.sizes.insert_large;
    // A zero size would leave the loop inside `insertLoopShape` with nothing to
    // iterate and the growth ratio with a division by zero, and a benchmark
    // that measures nothing must fail rather than report a clean zero.
    if (small == 0 or large == 0) return error.NothingToMeasure;
    // The growth guard is a statement about a *known* size ratio, so the sizes
    // are checked against the constant its reasoning is written for rather than
    // trusted to still match it.
    if (large != small * insert_loop_size_ratio) return error.SizesAreNotAtTheDocumentedRatio;

    // `iters` is one `Transaction.insert` call **at the large size** and `ns` is
    // that arm's subject alone, so `ns_per_iter` is the per-insert cost of the
    // shape that regressed — the same division `hash-for-opid` makes, and the
    // number to diff between two builds. The small arm is the contrast that
    // says whether that cost grows with `n`.
    var out: Result = .{ .iters = large, .measures_own_time = true };

    // The small arm runs first; allocator and code-path warming can bias the
    // large arm's per-insert cost downward. The guard checks this run's timing,
    // not a proof that every regression or scheduling effect is excluded.
    const small_arm = try insertLoopShape(gpa, ctx.io, small, &out);
    out.addPhase("insert-small", small_arm.build_ns);
    const large_arm = try insertLoopShape(gpa, ctx.io, large, &out);
    out.addPhase("insert-large", large_arm.build_ns);
    out.addPhase("verify", small_arm.verify_ns + large_arm.verify_ns);
    out.addPhase("teardown", small_arm.free_ns + large_arm.free_ns);

    // ── the growth ratio, which is the finding ──
    //
    // Printed per arm and as a ratio, because the two per-insert figures are
    // the numbers comparable with the ~1011 s / 50 000 = **20.2 ms per insert**
    // the old fixture recorded at 50 000, and the ratio is the number that is
    // comparable between builds of any size.
    const small_per = small_arm.build_ns / small;
    const large_per = large_arm.build_ns / large;
    const growth = (@as(f64, @floatFromInt(large_arm.build_ns)) / @as(f64, @floatFromInt(large))) /
        (@as(f64, @floatFromInt(small_arm.build_ns)) / @as(f64, @floatFromInt(small)));
    std.debug.print(
        "#   insert-loop: {d} inserts in one transaction, one commit: {d} ns = {d} ns/insert\n",
        .{ small, small_arm.build_ns, small_per },
    );
    std.debug.print(
        "#   insert-loop: {d} inserts in one transaction, one commit: {d} ns = {d} ns/insert\n",
        .{ large, large_arm.build_ns, large_per },
    );
    std.debug.print(
        "#   insert-loop: per-insert cost grew {d:.3}x for a {d}x size change" ++
            " (1.000 is flat in n, {d}.000 is a per-insert cost that grows with n;" ++
            " ceiling {d:.3}x)\n",
        .{ growth, insert_loop_size_ratio, insert_loop_size_ratio, insert_loop_growth_ceiling },
    );

    if (growth > insert_loop_growth_ceiling) {
        std.debug.print(
            "#   insert-loop: the per-insert cost grows with the document, which is the" ++
                " O(rows)-per-insert stage this gate exists for; refusing to report a run" ++
                " that cannot tell a flat cost from a quadratic one\n",
            .{},
        );
        return error.InsertCostStillGrowsWithTheDocument;
    }

    out.ns = large_arm.build_ns;
    return out;
}

const workloads = [_]Workload{
    .{
        .name = "segmentation",
        .case = "src/textdiff.zig:1679 `the single-pass segmentation is the per-prefix count it replaced`",
        .run = segmentation,
    },
    .{
        .name = "indexed-delta",
        .case = "src/hexane/column.zig:15125 `fuzz_indexed_delta_column`",
        .run = indexedDelta,
    },
    .{
        .name = "slab-merge",
        .case = "src/hexane/hexane_test.zig:474 `fuzz_slab_merge_invariant`",
        .run = slabMerge,
    },
    .{
        .name = "prefix-bool",
        .case = "src/opset/columns.zig:3700 `fuzz_prefix_column_bool`",
        .run = prefixBool,
    },
    .{
        .name = "update-object",
        .case = "test/upstream_doc_test.zig:1403 `rollback after a save and load of a deep hydrated root map`",
        .run = updateObject,
    },
    .{
        .name = "mark-index",
        .case = "src/opset/mark_index.zig:2459 `a column of many slabs answers every position, before and after an undo`",
        .run = markIndex,
    },
    .{
        .name = "mark-at-end",
        .case = "src/read.zig:6537 `a mark at the end of a long text is found at the end`",
        .run = markAtEnd,
    },
    .{
        .name = "sync-roundtrip",
        .case = "generateSyncMessage → State.extendSent: bulk sort and sorted merge into accumulated sent_hashes — no test case; added as a gate",
        .run = syncRoundtrip,
    },
    .{
        .name = "hash-for-opid",
        .case = "hashForOpid → ChangeGraph.opidToHash: actor-change interval binary search — no test case; added as a gate",
        .run = hashForOpidWorkload,
    },
    .{
        .name = "list-width",
        .case = "listRange → elementWidth: one held element cursor per walk over a batched list fixture — no test case; added as a gate",
        .run = listWidth,
    },
    .{
        .name = "insert-loop",
        .case = "Transaction.insert: ascending single-element appends in one transaction and commit per arm; 4x arm sizes with per-insert growth guard — no test case; added as a gate",
        .run = insertLoop,
    },
};
