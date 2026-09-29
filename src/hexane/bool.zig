//! Boolean slab codec: alternating run counts and no value bytes at all.
//!
//! A boolean slab is a sequence of unsigned LEB128 counts:
//!
//! ```text
//!   run0: uleb128  (false count)
//!   run1: uleb128  (true count)
//!   run2: uleb128  (false count)
//!   ...
//! ```
//!
//! No boolean is stored. The value is implicit in the run's index: even
//! runs are `false`, odd runs are `true` (upstream `bool.rs:13-25`). An
//! empty slab is an empty column; an all-`true` slab is `[0, N]`
//! (`bool.rs:1657-1660`).
//!
//! # Run-header convention
//!
//! A slab is cut between runs, never inside one, and the writer emits each
//! maximal run of equal values once. Only the very first run may have
//! count zero: that is the padding that lets a slab start on `true`
//! (`bool.rs:988-1002`). No interior or trailing zero run is ever produced,
//! so a zero run in the middle of a slab would mean two neighbours carry the
//! same value and should have been merged (`bool.rs:776-783`). Counting
//! segments is therefore just counting the varints (`bool.rs:756-772`).
//!
//! Decoding rejects a truncated varint, an overlong one, and a set of counts
//! whose sum does not fit a `usize` (upstream checks the same sum with
//! `checked_add` at `bool.rs:817-820`). Canonical-form checks beyond that
//! (the zero-count rules) belong to the column loader, which is the only
//! place upstream runs them, on whole columns rather than on slabs.

const std = @import("std");
const leb128 = @import("../leb128.zig");
const err = @import("../error.zig");

const ParseError = err.ParseError;

/// One run of a boolean slab: `count` copies of `value`.
const Run = struct {
    value: bool,
    count: usize,
};

/// Walks a sequence of booleans in the slab wire format: maximal runs of
/// equal values, each prefixed by the count of the opposite value that has
/// to come first. Only a leading `true` produces a zero-count run, because
/// the first run of a slab is always `false`.
const RunIter = struct {
    values: []const bool,
    pos: usize,
    /// Whether the leading run has been considered. The padding run does
    /// not consume an item, so the position cannot say on its own that it
    /// has been emitted.
    padded: bool,

    /// A cursor over the runs of `values`.
    fn init(values: []const bool) RunIter {
        return .{ .values = values, .pos = 0, .padded = false };
    }

    /// The next run, or null once the sequence is used up.
    fn next(self: *RunIter) ?Run {
        if (self.pos >= self.values.len) return null;
        if (!self.padded) {
            self.padded = true;
            // A slab has to open on a `false` run, so a sequence that starts
            // on `true` is padded with a zero-count `false` run.
            if (self.values[0]) return .{ .value = false, .count = 0 };
        }
        const value = self.values[self.pos];
        const start = self.pos;
        self.pos += 1;
        while (self.pos < self.values.len and self.values[self.pos] == value) self.pos += 1;
        return .{ .value = value, .count = self.pos - start };
    }
};

/// The boolean slab codec. Same shape as the run-length codecs: size a
/// buffer, write into it, append to a list, or decode a whole slab.
pub const Bool = struct {
    /// The number of bytes `write` will emit for `values`.
    pub fn encodedSize(values: []const bool) usize {
        var total: usize = 0;
        var runs = RunIter.init(values);
        while (runs.next()) |run| total += leb128.unsignedSize(run.count);
        return total;
    }

    /// Writes `values` into `out`, which must hold `encodedSize` bytes.
    pub fn write(out: []u8, values: []const bool) void {
        var pos: usize = 0;
        var runs = RunIter.init(values);
        while (runs.next()) |run| {
            pos += leb128.writeUnsigned(out[pos..], run.count);
        }
    }

    /// Appends the encoding of `values` to `list`.
    pub fn append(list: *std.ArrayList(u8), gpa: std.mem.Allocator, values: []const bool) !void {
        var runs = RunIter.init(values);
        while (runs.next()) |run| try leb128.appendUnsigned(list, gpa, run.count);
    }

    /// Decodes every value in a slab. The caller owns the returned slice.
    pub fn decodeAll(bytes: []const u8, gpa: std.mem.Allocator) ParseError![]bool {
        // Two passes: the first sums the run counts so the exact allocation
        // is made once, and it rejects a slab whose total does not fit a
        // `usize` before any memory is touched.
        const total = try countValues(bytes);
        const out = try gpa.alloc(bool, total);
        errdefer gpa.free(out);
        var pos: usize = 0;
        var written: usize = 0;
        var value = false;
        while (pos < bytes.len) {
            const run = try leb128.readUnsigned(bytes[pos..]);
            pos += run.len;
            const count = std.math.cast(usize, run.value) orelse return error.Overflow;
            const end = std.math.add(usize, written, count) catch return error.Overflow;
            // `countValues` summed exactly these counts, so `end` is at most
            // `total`; the check keeps the slice below in bounds whatever
            // the input claims.
            if (end > total) return error.Overflow;
            @memset(out[written..end], value);
            written = end;
            value = !value;
        }
        return out;
    }

    /// A cursor over a slab that yields values one at a time.
    ///
    /// Each run yields its value repeatedly; crossing into the next run
    /// reads one LEB128 count. The document walk pulls booleans one at a
    /// time, so this never materialises the whole slab.
    pub const Decoder = struct {
        bytes: []const u8,
        /// The offset of the next unread run count.
        pos: usize,
        /// Items left in the current run.
        remaining: usize,
        /// The current run's value. Starts as `true` so that the first
        /// flip yields the `false` the wire format opens with
        /// (upstream `bool.rs:490-502`).
        value: bool,

        /// A cursor standing at the start of `bytes`.
        pub fn init(bytes: []const u8) ParseError!Decoder {
            return .{ .bytes = bytes, .pos = 0, .remaining = 0, .value = true };
        }

        /// The next value, null at the end of the slab. A malformed run
        /// count part-way through the slab is reported here, not swallowed.
        pub fn next(self: *Decoder) ParseError!?bool {
            while (true) {
                if (self.remaining > 0) {
                    self.remaining -= 1;
                    return self.value;
                }
                if (self.pos >= self.bytes.len) return null;
                const run = try leb128.readUnsigned(self.bytes[self.pos..]);
                self.pos += run.len;
                self.value = !self.value;
                self.remaining = std.math.cast(usize, run.value) orelse return error.Overflow;
            }
        }
    };
};

/// The total number of values in `bytes`, or an error if the run counts do
/// not sum to something a `usize` can hold.
fn countValues(bytes: []const u8) ParseError!usize {
    var total: usize = 0;
    var pos: usize = 0;
    while (pos < bytes.len) {
        const run = try leb128.readUnsigned(bytes[pos..]);
        pos += run.len;
        const count = std.math.cast(usize, run.value) orelse return error.Overflow;
        total = std.math.add(usize, total, count) catch return error.Overflow;
    }
    return total;
}

// ── Tests ────────────────────────────────────────────────────────────────────

/// Encodes `values` with `Bool.write` and returns the slab bytes.
fn encode(gpa: std.mem.Allocator, values: []const bool) ![]u8 {
    const bytes = try gpa.alloc(u8, Bool.encodedSize(values));
    errdefer gpa.free(bytes);
    Bool.write(bytes, values);
    return bytes;
}

test "the empty slab is zero bytes and holds no values" {
    const gpa = std.testing.allocator;
    const empty: []const bool = &.{};
    try std.testing.expectEqual(@as(usize, 0), Bool.encodedSize(empty));

    const bytes = try encode(gpa, empty);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{}, bytes);

    const decoded = try Bool.decodeAll(bytes, gpa);
    defer gpa.free(decoded);
    try std.testing.expectEqual(@as(usize, 0), decoded.len);

    var dec = try Bool.Decoder.init(bytes);
    try std.testing.expectEqual(@as(?bool, null), try dec.next());
}

test "a single value pads the false run only when it is true" {
    const gpa = std.testing.allocator;
    {
        const bytes = try encode(gpa, &.{false});
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{1}, bytes);
    }
    {
        const bytes = try encode(gpa, &.{true});
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, bytes);
    }
}

test "an all-false slab is one count; an all-true slab pads it to zero" {
    const gpa = std.testing.allocator;
    {
        const bytes = try encode(gpa, &.{ false, false, false, false, false });
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{5}, bytes);
    }
    {
        const bytes = try encode(gpa, &.{ true, true, true, true, true });
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0, 5 }, bytes);
    }
}

test "alternating values emit one count per run" {
    const gpa = std.testing.allocator;
    // Upstream `bool.rs:1663-1668`: [true, true, false, true] is
    // [0 false, 2 true, 1 false, 1 true].
    const bytes = try encode(gpa, &.{ true, true, false, true });
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 1, 1 }, bytes);

    const decoded = try Bool.decodeAll(bytes, gpa);
    defer gpa.free(decoded);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, decoded);

    const alt = try encode(gpa, &.{ true, false, true, false, true });
    defer gpa.free(alt);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 1, 1, 1, 1 }, alt);
}

test "counts crossing the LEB128 boundary take their continuation byte" {
    const gpa = std.testing.allocator;
    // 127 is the largest one-byte count.
    {
        const bytes = try encode(gpa, &([_]bool{false} ** 127));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{0x7f}, bytes);
    }
    // 128 is the smallest two-byte count.
    {
        const bytes = try encode(gpa, &([_]bool{false} ** 128));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, bytes);
    }
    // 300 = 0b10_0101100: low 7 bits 0101100, then 0b10.
    {
        const bytes = try encode(gpa, &([_]bool{false} ** 300));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x02 }, bytes);
    }
    // 16383 is the largest two-byte count, 16384 the smallest three-byte one.
    {
        const bytes = try encode(gpa, &([_]bool{false} ** 16383));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x7f }, bytes);
    }
    {
        const bytes = try encode(gpa, &([_]bool{false} ** 16384));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x01 }, bytes);
    }
    // A run that follows another run keeps the same width rule, with the
    // padding run for the leading `true`.
    {
        const values: []const bool = &([_]bool{true} ++ [_]bool{false} ** 128);
        const bytes = try encode(gpa, values);
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x80, 0x01 }, bytes);
        const decoded = try Bool.decodeAll(bytes, gpa);
        defer gpa.free(decoded);
        try std.testing.expectEqualSlices(bool, values, decoded);
    }
}

/// A deterministic pseudo-random boolean sequence, so the round-trip tests
/// cover more shapes than a hand-written case list.
fn pseudoRandom(out: []bool, seed: u64) void {
    var state: u64 = seed;
    for (out) |*slot| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        slot.* = (state >> 33) & 1 == 1;
    }
}

test "write fills exactly encodedSize bytes and decodeAll reads them back" {
    const gpa = std.testing.allocator;
    var values: [512]bool = undefined;
    for ([_]u64{ 1, 2, 3, 4, 5 }, 0..) |seed, round| {
        pseudoRandom(&values, seed);
        const slice = values[0 .. round * 37];
        const size = Bool.encodedSize(slice);

        // One byte past the slab must survive: a writer that overruns its
        // size is caught here even where a bounds check would not fire.
        const bytes = try gpa.alloc(u8, size + 1);
        defer gpa.free(bytes);
        bytes[size] = 0xaa;
        Bool.write(bytes[0..size], slice);
        try std.testing.expectEqual(@as(u8, 0xaa), bytes[size]);

        const decoded = try Bool.decodeAll(bytes[0..size], gpa);
        defer gpa.free(decoded);
        try std.testing.expectEqualSlices(bool, slice, decoded);
    }
}

test "append matches write and can be called repeatedly" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    const first: []const bool = &.{ true, true, false, true };
    const second: []const bool = &([_]bool{false} ** 300);
    try Bool.append(&list, gpa, first);
    try Bool.append(&list, gpa, second);

    const whole = try encode(gpa, first ++ second);
    defer gpa.free(whole);
    try std.testing.expectEqualSlices(u8, whole, list.items);

    const decoded = try Bool.decodeAll(list.items, gpa);
    defer gpa.free(decoded);
    try std.testing.expectEqualSlices(bool, first ++ second, decoded);
}

test "the decoder yields the same sequence as decodeAll" {
    const gpa = std.testing.allocator;
    var values: [300]bool = undefined;
    pseudoRandom(&values, 99);
    const slice = values[0..300];

    const bytes = try encode(gpa, slice);
    defer gpa.free(bytes);

    var dec = try Bool.Decoder.init(bytes);
    for (slice) |expected| {
        try std.testing.expectEqual(@as(?bool, expected), try dec.next());
    }
    try std.testing.expectEqual(@as(?bool, null), try dec.next());
    // Exhausted, and still exhausted.
    try std.testing.expectEqual(@as(?bool, null), try dec.next());
}

test "the decoder holds a run's value until the run ends" {
    const gpa = std.testing.allocator;
    // One false run of two, one true run of five: two counts, no padding.
    const bytes = try encode(gpa, &.{ false, false, true, true, true, true, true });
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 2, 5 }, bytes);

    var dec = try Bool.Decoder.init(bytes);
    for (0..2) |_| try std.testing.expectEqual(@as(?bool, false), try dec.next());
    for (0..5) |_| try std.testing.expectEqual(@as(?bool, true), try dec.next());
    try std.testing.expectEqual(@as(?bool, null), try dec.next());
}

test "truncated input is rejected" {
    const gpa = std.testing.allocator;
    // A varint whose continuation bit is set at the end of the slab.
    try std.testing.expectError(error.UnexpectedEnd, Bool.decodeAll(&.{0x80}, gpa));
    try std.testing.expectError(error.UnexpectedEnd, Bool.decodeAll(&.{ 0x05, 0x80 }, gpa));
    try std.testing.expectError(
        error.UnexpectedEnd,
        Bool.decodeAll(&.{ 0x05, 0x05, 0x80, 0x80 }, gpa),
    );

    // The same slab read as a stream: the first run decodes, the second does
    // not, and the error surfaces instead of being swallowed.
    var dec = try Bool.Decoder.init(&.{ 0x02, 0x80 });
    try std.testing.expectEqual(@as(?bool, false), try dec.next());
    try std.testing.expectEqual(@as(?bool, false), try dec.next());
    try std.testing.expectError(error.UnexpectedEnd, dec.next());
}

test "an overlong LEB128 is rejected" {
    const gpa = std.testing.allocator;
    // Eleven continuation bytes: one more than a u64 can occupy.
    try std.testing.expectError(error.InvalidLeb128, Bool.decodeAll(&([_]u8{0x80} ** 11), gpa));
    // The tenth byte of a u64 carries one bit; two is an overflow.
    try std.testing.expectError(
        error.Overflow,
        Bool.decodeAll(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 }, gpa),
    );
}

test "run counts that overflow the total are rejected" {
    const gpa = std.testing.allocator;
    // Two runs of 2^63 each: each count is a valid u64, their sum is not a
    // valid `usize`. Upstream refuses the same sum with `checked_add`
    // (bool.rs:817-820).
    const two_to_63 = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };
    const slab = two_to_63 ++ two_to_63;
    try std.testing.expectError(error.Overflow, Bool.decodeAll(&slab, gpa));
    try std.testing.expectError(error.Overflow, countValues(&slab));
}
