//! Test runner for every test root `build.zig` declares.
//!
//! It speaks the same `std.zig.Server` protocol as the compiler's own
//! `compiler/test_runner.zig`, message for message, so the build runner's
//! accounting is the accounting this project has always had: the same
//! `test_metadata` table, the same `test_started` before every case, and the
//! same `test_results` flags — which is where `Build Summary: 3722/3723 tests
//! passed (1 skipped)` comes from and where the per-case `--test-timeout`
//! attribution and the leak and `std.log` counts come from. **No case is
//! added, removed, filtered or reordered, and no assertion is touched**; the
//! only thing this file changes is that it also writes down what the run cost.
//!
//! WHY THE COST HAS TO BE RECORDED
//! `zig build test` runs fifteen test roots, and two of them are the library
//! suite itself: once as shipped, and once more with `-Dslow-path` forced on
//! (`zig build slow-path`). Each is 1730 cases, and a Debug build of the
//! library root at one core is a ~40-47 minute step. Until this runner
//! existed, the entire evidence such a step produced was one line after the
//! fact — `run test 1729 pass, 1 skip (1730 total) 47m` — so a run that was
//! making progress and a run that was wedged in one case were the same
//! observation for three quarters of an hour, and the only way to learn which
//! cases were expensive was to re-run with a filter, which is precisely the
//! narrowing this project does not do.
//!
//! WHERE EACH OF THE THREE OUTPUTS GOES, AND WHY IT GOES THERE
//!
//! - **stdout is the protocol and nothing else.** The build runner reads it
//!   as a message stream; a stray byte there is a protocol error, not a
//!   message.
//! - **The case record is a file**, named by `build.zig` in
//!   `--zautomerge-progress=<path>` and appended line by line, flushed as it
//!   goes. A run that is killed mid-case therefore still leaves that case as
//!   its last line, which is what makes a timed-out or cancelled run
//!   readable afterwards. The file is declared to the build system with
//!   `addWriteFiles` before the root runs, so its directory exists and so a
//!   finished root's record is an input of the step that prints it.
//! - **stderr carries one line per case slower than
//!   `--zautomerge-slow-ms`** (default 10s) and nothing else. The build
//!   runner hands a failed or timed-out child's stderr to the operator with
//!   the error, so a few lines of "this case took 41.3s" are the context that
//!   survives a kill; a line per case would instead bury the failure in
//!   1700 lines of its own.
//!
//! **The record is best-effort and never load-bearing.** If the file cannot
//! be opened, or a line does not fit the record buffer, the runner says so
//! once on stderr and runs every case exactly as it otherwise would. Losing
//! the timing evidence must not be able to lose a test.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const panic = std.debug.panic;

const TestResults = std.zig.Server.Message.TestResults;

/// `std.log` errors are counted per case because the protocol reports that
/// count in `test_results.flags.log_err_count`, and the build runner turns a
/// nonzero one into a build error. Without this `std_options` the count would
/// be zero whatever the tests logged.
pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);
var fba_buffer: [8192]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
var stdin_reader: Io.File.Reader = undefined;
var stdout_writer: Io.File.Writer = undefined;
const runner_threaded_io: Io = Io.Threaded.global_single_threaded.io();

/// The open case record, or null when `build.zig` named no path for it.
var record: ?Record = null;

/// How many of the slowest cases the record's footer keeps. Ten is enough to
/// name the hot path of a root whose slowest case is three orders of
/// magnitude above its median, and small enough that the footer stays a
/// paragraph rather than a page.
const slowest_kept = 10;

/// A case that took at least this long is named on stderr. 10s is chosen so
/// that an ordinary Debug run of one of the small roots says nothing at all,
/// and a 40-minute library root says something about each of its few
/// expensive cases.
const default_slow_ms: u64 = 10_000;

// No step in this build enables fuzzing (`b.addTest` does not, and there is
// no `zig build fuzz`), so the fuzz arm of the protocol is not implemented
// here. If that ever changes this file must grow it rather than silently
// skip cases.
comptime {
    if (builtin.fuzz) @compileError("test/verification_runner.zig does not implement the fuzz server protocol");
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const args = init.args.toSlice(fba.allocator()) catch |err| panic("unable to parse command line args: {t}", .{err});

    var listen = false;
    var progress_path: ?[]const u8 = null;
    var slow_ms: u64 = default_slow_ms;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            // Always passed by `Run.enableTestRunnerMode`. Accepted and
            // unused: the record path arrives in `--zautomerge-progress`,
            // already made relative to this process's working directory by
            // the build system, so it needs no cache root of its own.
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--zautomerge-progress=")) {
            progress_path = arg["--zautomerge-progress=".len..];
        } else if (std.mem.startsWith(u8, arg, "--zautomerge-slow-ms=")) {
            slow_ms = std.fmt.parseUnsigned(u64, arg["--zautomerge-slow-ms=".len..], 10) catch
                @panic("unable to parse --zautomerge-slow-ms command line argument");
        } else {
            panic("unrecognized command line argument: {s}", .{arg});
        }
    }

    if (listen) return mainServer(init, progress_path, slow_ms) catch |err| {
        panic("internal test runner failure: {t}", .{err});
    };
    mainSimple(init, slow_ms);
}

/// The mode every root in `build.zig` runs under: the build runner drives
/// this process over stdio and this process answers for one case at a time.
fn mainServer(init: std.process.Init.Minimal, progress_path: ?[]const u8, slow_ms: u64) !void {
    @disableInstrumentation();
    stdin_reader = .initStreaming(.stdin(), runner_threaded_io, &stdin_buffer);
    stdout_writer = .initStreaming(.stdout(), runner_threaded_io, &stdout_buffer);
    var server = try std.zig.Server.init(.{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
        .zig_version = builtin.zig_version_string,
    });

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                closeRecord();
                return std.process.exit(0);
            },
            .query_test_metadata => {
                testing.allocator_instance = .{};
                defer if (testing.allocator_instance.deinit() == .leak) {
                    @panic("internal test runner memory leak");
                };

                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(testing.allocator);
                try string_bytes.append(testing.allocator, 0); // Reserve 0 for null.

                const test_fns = builtin.test_functions;
                const names = try testing.allocator.alloc(u32, test_fns.len);
                defer testing.allocator.free(names);
                const expected_panic_msgs = try testing.allocator.alloc(u32, test_fns.len);
                defer testing.allocator.free(expected_panic_msgs);

                for (test_fns, names, expected_panic_msgs) |test_fn, *name, *expected_panic_msg| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.ensureUnusedCapacity(testing.allocator, test_fn.name.len + 1);
                    string_bytes.appendSliceAssumeCapacity(test_fn.name);
                    string_bytes.appendAssumeCapacity(0);
                    // The port has no `std.testing.expect_panic`, so no case
                    // expects one and the build runner requests every index.
                    expected_panic_msg.* = 0;
                }

                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });

                openRecord(progress_path, @intCast(test_fns.len));
            },
            .run_test => {
                testing.environ = init.environ;
                testing.allocator_instance = .{};
                testing.io_instance = .init(testing.allocator, .{
                    .argv0 = .init(init.args),
                    .environ = init.environ,
                });
                log_err_count = 0;
                const index = try server.receiveBody_u32();
                const test_fn = builtin.test_functions[index];

                // Tell the build server the case is starting now: the
                // per-test `--test-timeout` is measured from this message to
                // the `test_results` below, and a case with no `test_started`
                // would leave it unattributed.
                try server.serveStringMessage(.test_started, &.{});

                const started = Io.Clock.Timestamp.now(runner_threaded_io, .awake);
                if (record) |*rec| rec.beginCase(index, test_fn.name);

                const status: TestResults.Status = if (test_fn.func()) |v| s: {
                    v;
                    break :s .pass;
                } else |err| switch (err) {
                    error.SkipZigTest => .skip,
                    else => s: {
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpErrorReturnTrace(trace);
                        }
                        break :s .fail;
                    },
                };
                // The case's own body only: the allocator leak check and the
                // `std.testing` teardown below are the runner's, not the
                // test's, and counting them would blame a case for them.
                const elapsed_ns: u64 = @intCast(started.untilNow(runner_threaded_io).raw.nanoseconds);

                testing.io_instance.deinit();
                const leak_count = testing.allocator_instance.detectLeaks();
                testing.allocator_instance.deinitWithoutLeakChecks();

                if (record) |*rec| rec.finishCase(index, test_fn.name, elapsed_ns, status, slow_ms);

                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .status = status,
                        .fuzz = false,
                        .log_err_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "log_err_count"),
                            log_err_count,
                        ),
                        .leak_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "leak_count"),
                            leak_count,
                        ),
                    },
                });
            },
            else => {
                std.debug.print("unsupported message: {x}\n", .{@intFromEnum(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

/// The mode a person gets from `zig test --test-runner
/// test/verification_runner.zig …`, which is how this file can be exercised
/// against one root in seconds rather than through a 40-minute build step.
/// `build.zig` never selects it: it declares `mode = .server`, so the build
/// runner always passes `--listen=-`.
fn mainSimple(init: std.process.Init.Minimal, slow_ms: u64) void {
    @disableInstrumentation();

    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;

    for (test_fn_list, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) leaks += 1;
        }
        testing.log_level = .warn;
        testing.environ = init.environ;
        log_err_count = 0;

        std.debug.print("{d}/{d} {s}...", .{ i + 1, test_fn_list.len, test_fn.name });
        const started = Io.Clock.Timestamp.now(runner_threaded_io, .awake);
        if (test_fn.func()) |_| {
            ok_count += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                std.debug.print("SKIP\n", .{});
                continue;
            },
            else => {
                fail_count += 1;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                continue;
            },
        }
        const elapsed_ns: u64 = @intCast(started.untilNow(runner_threaded_io).raw.nanoseconds);
        std.debug.print("OK ({d:.2} s)", .{@as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s});
        if (elapsed_ns >= slow_ms * std.time.ns_per_ms) {
            std.debug.print(" [slow]", .{});
        }
        std.debug.print("\n", .{});
    }

    if (ok_count == test_fn_list.len) {
        std.debug.print("\nAll {d} tests passed.\n", .{ok_count});
    } else {
        std.debug.print("\n{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    }
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }
    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

/// Open the case record `build.zig` named, or say once on stderr why there
/// will not be one. The caller is the metadata arm, so the case count is
/// already known and every later line can say `n/total`.
fn openRecord(path: ?[]const u8, total: u32) void {
    if (record != null) return;
    const path_str = path orelse return;
    // `Dir.createFile` on the cwd directory resolves an absolute path as it
    // stands and a relative one against the working directory, and the build
    // system hands this process a path that is already relative to it.
    const file = Io.Dir.cwd().createFile(runner_threaded_io, path_str, .{}) catch |err| {
        std.debug.print(
            "zautomerge-test: no case record at {s} ({t}); the cases still run, only the timing evidence is lost\n",
            .{ path_str, err },
        );
        return;
    };
    record = .{ .io = runner_threaded_io, .file = file, .line_buf = undefined, .total = total };
    record.?.write("# zautomerge test case record: {d} cases\n", .{total});
}

/// Write the footer and close the file. Reached only on the build runner's
/// `exit` message, so a run that was killed leaves the record without one —
/// which is the point: the tail is then the case it was in.
fn closeRecord() void {
    if (record) |*rec| {
        rec.close();
        record = null;
    }
}

/// One appended line per case event, plus a footer. Tab-separated so the file
/// is greppable and sortable, and written with `writeStreamingAll` per line
/// so a killed process has every line it wrote and no partial one.
const Record = struct {
    io: Io,
    file: Io.File,
    line_buf: [1024]u8,
    total: u32,

    done: u32 = 0,
    passed: u32 = 0,
    skipped: u32 = 0,
    failed: u32 = 0,
    sum_ns: u64 = 0,
    slowest: [slowest_kept]Slowest = undefined,
    slowest_len: usize = 0,

    const Slowest = struct {
        ns: u64,
        /// Borrowed from `builtin.test_functions`, which is static data.
        name: []const u8,
    };

    fn write(rec: *Record, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.bufPrint(&rec.line_buf, fmt, args) catch {
            std.debug.print(
                "zautomerge-test: a record line does not fit {d} bytes; it is dropped\n",
                .{rec.line_buf.len},
            );
            return;
        };
        rec.file.writeStreamingAll(rec.io, line) catch {};
    }

    /// Written *before* the case runs, so the record names the case a killed
    /// or cancelled run died in rather than the last one it finished.
    fn beginCase(rec: *Record, index: u32, name: []const u8) void {
        rec.write("{d}/{d}\tbegin\t-\t{s}\n", .{ index + 1, rec.total, name });
    }

    fn finishCase(
        rec: *Record,
        index: u32,
        name: []const u8,
        ns: u64,
        status: TestResults.Status,
        slow_ms: u64,
    ) void {
        rec.write("{d}/{d}\t{d}\t{s}\t{s}\n", .{ index + 1, rec.total, ns, @tagName(status), name });
        rec.done += 1;
        rec.sum_ns += ns;
        switch (status) {
            .pass => rec.passed += 1,
            .fail => rec.failed += 1,
            .skip => rec.skipped += 1,
        }
        if (ns >= slow_ms * std.time.ns_per_ms) {
            // Bounded by construction: one line per case over the threshold,
            // and the build runner only ever shows this when a case failed or
            // the run was killed.
            std.debug.print(
                "zautomerge-test: {d}/{d} {s} took {d:.2} s\n",
                .{ index + 1, rec.total, name, @as(f64, @floatFromInt(ns)) / std.time.ns_per_s },
            );
        }
        rec.keepSlowest(ns, name);
    }

    /// Keep the `slowest_kept` largest durations, descending. Insertion
    /// into a ten-slot array costs less than the case it is timing.
    fn keepSlowest(rec: *Record, ns: u64, name: []const u8) void {
        if (rec.slowest_len == slowest_kept and ns <= rec.slowest[slowest_kept - 1].ns) return;
        var i: usize = if (rec.slowest_len < slowest_kept) rec.slowest_len else slowest_kept - 1;
        rec.slowest_len = @min(rec.slowest_len + 1, slowest_kept);
        while (i > 0 and rec.slowest[i - 1].ns < ns) : (i -= 1) {
            rec.slowest[i] = rec.slowest[i - 1];
        }
        rec.slowest[i] = .{ .ns = ns, .name = name };
    }

    /// The part `build.zig`'s reporting step prints: what the root cost, and
    /// which cases cost it. `#`-prefixed so that step can print the footer
    /// with one `grep` and the tail with one `tail`.
    fn close(rec: *Record) void {
        rec.write(
            "#   {d} of {d} cases ran: {d} pass, {d} skip, {d} fail, {d:.1} s total\n",
            .{
                rec.done,
                rec.total,
                rec.passed,
                rec.skipped,
                rec.failed,
                @as(f64, @floatFromInt(rec.sum_ns)) / std.time.ns_per_s,
            },
        );
        rec.write("#   slowest cases:\n", .{});
        var i: usize = rec.slowest_len;
        while (i > 0) {
            i -= 1;
            rec.write("#     {d:>12} ns  {s}\n", .{ rec.slowest[i].ns, rec.slowest[i].name });
        }
        rec.file.close(rec.io);
    }
};
