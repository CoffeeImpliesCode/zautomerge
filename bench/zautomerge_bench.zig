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
//! Every workload prints one machine-readable line on **stdout**:
//!
//!     BENCH <name> <iters> <total_ns> <ns_per_iter>
//!
//! and nothing else goes to stdout, so `grep '^BENCH '` over a run is the
//! complete result set. Everything else — the shape of the input, the phase
//! breakdown, warnings, the leak count — goes to **stderr**, where
//! `std.debug.print` already puts it in this repository's idiom
//! ([`test/save_interop.zig`](../test/save_interop.zig)).
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
//! USAGE
//!
//!     zautomerge_bench [--repeat N] [--full] [--list] [workload ...]
//!
//! With no workload named, every workload runs. `--repeat N` runs each one N
//! times and reports the **median** sample; `--full` swaps every reduced size
//! for the exact size the test case uses, which is slow enough to want a
//! filter. See `bench/README.md` for which sizes are reduced and why the
//! reduced shape is the same shape.

const std = @import("std");
const builtin = @import("builtin");

/// The module under test, imported by the name a consumer imports it by.
const am = @import("zautomerge");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Document = am.doc.Document;
const OpId = am.OpId;
const TextEncoding = am.TextEncoding;

/// The buffer stdout is written through. Seven short lines would not need one;
/// a reader that wants the file before the process has exited does.
const stdout_buffer_len = 8 * 1024;

const usage =
    \\usage: zautomerge_bench [--repeat N] [--full] [--list] [workload ...]
    \\
    \\  --repeat N   run each named workload N times and report the median
    \\               sample (default 1). Wall clock on a busy host moves a few
    \\               percent between samples; the median is the least-bad
    \\               summary and `perf stat -e instructions` is the good one.
    \\  --full       use the exact input sizes the port's own test cases use
    \\               instead of the reduced defaults. Several workloads become
    \\               one to two orders of magnitude slower; see bench/README.md.
    \\  --list       print the workload names and exit
    \\
    \\workloads, all of which are optional positionally:
    \\
;

pub fn main(init: std.process.Init) !u8 {
    // ── The leak arbiter ──────────────────────────────────────────────────
    //
    // **`std.process.Init.gpa` is not a leak arbiter in ReleaseFast.** `std.start`
    // only installs its own `DebugAllocator` when `use_debug_allocator` holds,
    // and that needs either a non-ReleaseFast mode or `link_libc` plus
    // `single_threaded` (`std/start.zig:689-713`). A plain ReleaseFast native
    // build lands on `smp_allocator`, which detects nothing.
    //
    // So the benchmark builds its own arbiter over `init.gpa` and asks it
    // directly. `safety` mirrors what `std.start` would have chosen: the
    // per-allocation checks are the point in Debug and ReleaseSafe, and a
    // benchmark that performs tens of thousands of allocations per iteration
    // should not pay for them while it is being timed. `detectLeaks` is called
    // unconditionally at the end, so the *count* is on the record in every mode
    // even where the individual reports are less informative.
    var arbiter: std.heap.DebugAllocator(.{ .safety = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall }) = .{
        .backing_allocator = init.gpa,
    };
    const gpa = arbiter.allocator();
    defer arbiter.deinitWithoutLeakChecks();

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

    const sizes = if (full) Sizes.full else Sizes.default;
    const ctx: Ctx = .{ .gpa = gpa, .io = init.io, .sizes = sizes };

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

    // **These two come out of `init.arena`, not out of the leak arbiter.**
    // `detectLeaks` runs at the bottom of `main`, before any `defer` in this
    // function has fired, so a buffer allocated from the arbiter and freed by
    // a `defer` would still be live at the check and be reported as a leak of
    // the benchmark's own. The arena is freed by `std.start` after `main`
    // returns and is page-backed, so it costs nothing to hand it two small
    // arrays and it keeps the arbiter's answer about the *port*.
    const samples = try arena.alloc(u64, repeat);
    const sorted = try arena.alloc(u64, repeat);

    // Every byte of work every workload did is folded into one running total
    // and printed at the end, so nothing below can be optimised away on the
    // grounds that the answer is unused.
    var sink: u64 = 0;

    for (selected.items) |w| {
        std.debug.print("\n# {s}\n#   reproduces: {s}\n", .{ w.name, w.case });

        var last: Result = .{};
        var ok = true;
        for (0..repeat) |rep| {
            const started = Timer.start(ctx.io);
            if (w.run(ctx)) |ran| {
                var r = ran;
                if (!r.measures_own_time) r.ns = started.stop();
                samples[rep] = r.ns;
                last = r;
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
        @memcpy(sorted, samples);
        std.mem.sort(u64, sorted, {}, lessThanU64);
        const median = sorted[(repeat - 1) / 2];
        const iters: u64 = @intCast(last.iters);
        const per_iter = if (iters == 0) 0 else median / iters;

        sink +%= last.checksum;

        try out.print("BENCH {s} {d} {d} {d}\n", .{ w.name, last.iters, median, per_iter });
        try out.flush();

        std.debug.print(
            "#   {d} iteration(s), median {d} ns over {d} sample(s), {d:.3} ms/iter\n",
            .{ last.iters, median, repeat, @as(f64, @floatFromInt(median)) / std.time.ns_per_ms },
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

    // Ask the arbiter directly, because `deinit` only checks when `safety` is
    // on and the number must be on the record either way.
    const leaked = arbiter.detectLeaks();
    std.debug.print("# LEAKS {d}\n", .{leaked});
    if (leaked != 0) {
        std.debug.print(
            "# a leak here is a bug in the benchmark rather than in the port: every workload frees what it takes\n",
            .{},
        );
        return 1;
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
};

/// Every size the seven workloads take, in one place, so `bench/README.md`'s
/// table of what is reduced and `Sizes.full` cannot drift apart.
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

    /// The reduced sizes. Chosen so one full pass over all seven workloads fits
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
    };

    /// The sizes the port's own test cases use, exactly. `--full`.
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
            while (find.next()) |hit| {
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
// `am.transaction.updateObject` over the root a `fuzzMap(0, 42)` builds.
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
    var root_value = try fuzzMap(gpa, 0, ctx.sizes.hydrate_depth);
    defer root_value.deinit();

    var doc = try Document.init(gpa, ctx.io, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "bench-update-object" });

    // ── the hot call, timed ──
    const started = Timer.start(ctx.io);
    try am.transaction.updateObject(&doc, am.root, root_value);
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
    var doc = try Document.initWithEncoding(gpa, ctx.io, enc, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "bench-mark-at-end" });
    const text = try am.transaction.putObject(&doc, am.root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&doc, text, 0, 0, body.items);
    const len = try am.read.length(&doc, text);
    if (len != body.items.len) return error.UnexpectedLength;
    out.mix(len);
    out.addPhase("build-document", build_started.stop());

    // ── the mark ──
    const mark_started = Timer.start(ctx.io);
    try am.transaction.mark(&doc, text, len - 4, len, "bold", .none, .{ .bool_value = true });
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
};
