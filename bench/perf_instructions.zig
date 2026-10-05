const std = @import("std");
const builtin = @import("builtin");

pub const Reading = struct {
    instructions: u64,
    time_enabled_ns: u64,
    time_running_ns: u64,
};

pub const Error = error{
    UnsupportedPlatform,
    CounterPermissionDenied,
    CounterUnavailable,
    CounterOpenFailed,
    CounterControlFailed,
    CounterReadFailed,
    InvalidCounterState,
    IncompleteCounterRead,
    EmptyCounterReading,
    IncompleteCounterCoverage,
};

/// Owns one calling-thread, user-space hardware event for exactly one sample.
/// Keep this value on its opening thread and defer deinit immediately after open.
pub const Counter = struct {
    fd: ?i32,
    state: enum { ready, enabled, finished } = .ready,

    pub fn open() Error!Counter {
        if (comptime builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var attr: linux.perf_event_attr = .{
                .type = .HARDWARE,
                .config = @intFromEnum(linux.PERF.COUNT.HW.INSTRUCTIONS),
                // PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING.
                .read_format = (1 << 0) | (1 << 1),
                .flags = .{
                    .disabled = true,
                    .inherit = false,
                    .pinned = true,
                    .exclude_kernel = true,
                    .exclude_hv = true,
                },
            };
            while (true) {
                const rc = linux.perf_event_open(&attr, 0, -1, -1, linux.PERF.FLAG.FD_CLOEXEC);
                switch (linux.errno(rc)) {
                    .SUCCESS => return .{ .fd = @intCast(rc) },
                    .INTR => continue,
                    .ACCES, .PERM => return error.CounterPermissionDenied,
                    .NOENT, .NODEV, .NOSYS, .OPNOTSUPP, .INVAL, .BUSY => {
                        return error.CounterUnavailable;
                    },
                    else => return error.CounterOpenFailed,
                }
            }
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Enables the new event once; enabled/running times are never reused or reset.
    pub fn enable(self: *Counter) Error!void {
        errdefer self.deinit();
        if (comptime builtin.os.tag == .linux) {
            if (self.state != .ready) return error.InvalidCounterState;
            const fd = self.fd orelse return error.InvalidCounterState;
            try control(fd, std.os.linux.PERF.EVENT_IOC.ENABLE);
            self.state = .enabled;
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Disables before reading, and rejects any count without full scheduling coverage.
    pub fn finish(self: *Counter) Error!Reading {
        errdefer self.deinit();
        if (comptime builtin.os.tag == .linux) {
            if (self.state != .enabled) return error.InvalidCounterState;
            const fd = self.fd orelse return error.InvalidCounterState;
            try control(fd, std.os.linux.PERF.EVENT_IOC.DISABLE);
            self.state = .finished;
            var words: [3]u64 = undefined;
            const bytes = std.mem.asBytes(&words);
            while (true) {
                const rc = std.os.linux.read(fd, bytes.ptr, bytes.len);
                switch (std.os.linux.errno(rc)) {
                    .SUCCESS => return validateRead(&words, rc),
                    .INTR => continue,
                    else => return error.CounterReadFailed,
                }
            }
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Closing also stops an enabled event after a workload/control/read failure.
    pub fn deinit(self: *Counter) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.fd) |fd| {
                self.fd = null;
                // Linux releases the descriptor even on EINTR; retry could close another FD.
                _ = std.os.linux.close(fd);
            }
        }
        self.state = .finished;
    }
};

fn control(fd: i32, request: u32) Error!void {
    while (true) {
        const rc = std.os.linux.ioctl(fd, request, 0);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.CounterControlFailed,
        }
    }
}

fn validateRead(words: *const [3]u64, bytes_read: usize) Error!Reading {
    if (bytes_read != @sizeOf([3]u64)) return error.IncompleteCounterRead;
    if (words[0] == 0) return error.EmptyCounterReading;
    if (words[1] == 0) return error.EmptyCounterReading;
    if (words[2] == 0) return error.EmptyCounterReading;
    if (words[2] != words[1]) return error.IncompleteCounterCoverage;
    return .{
        .instructions = words[0],
        .time_enabled_ns = words[1],
        .time_running_ns = words[2],
    };
}

test "instruction reading rejects zero counts and unscheduled coverage" {
    // A nonzero count alone does not establish that this sample actually ran.
    const cases = [_][3]u64{
        .{ 0, 100, 100 },
        .{ 1, 0, 0 },
        .{ 1, 100, 0 },
    };
    for (cases) |words| {
        try std.testing.expectError(error.EmptyCounterReading, validateRead(&words, 24));
    }
}

test "instruction reading rejects multiplexed and inconsistent coverage" {
    // Both partial coverage and an impossible running time must fail without scaling.
    const cases = [_][3]u64{
        .{ 900, 100, 99 },
        .{ 900, 100, 101 },
    };
    for (cases) |words| {
        try std.testing.expectError(error.IncompleteCounterCoverage, validateRead(&words, 24));
    }
}

test "instruction reading rejects incomplete payloads before examining words" {
    // Short reads must not interpret the unwritten words; extra bytes are invalid too.
    const words: [3]u64 = undefined;
    for ([_]usize{ 0, 23, 25 }) |bytes_read| {
        try std.testing.expectError(
            error.IncompleteCounterRead,
            validateRead(&words, bytes_read),
        );
    }
}
