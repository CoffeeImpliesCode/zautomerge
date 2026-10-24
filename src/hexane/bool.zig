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
//!
//!
//! # Packing
//!
//! Those counts are written through a **packing**: [`BoolWith`] takes one as a
//! `comptime` parameter and [`Bool`] is it on the default wire, which is
//! `rle.Leb128` — the `../leb128.zig` module under a name. There is exactly one
//! packing this port ships; the second exists so `column.zig`'s `alt_codec`
//! cases can drive the parameter through every path. Because a boolean slab is
//! *nothing but* counts, this module is where a packing that reached the
//! payloads but not the counts would be caught first.
//!
//! # Import route and the shortest sequence that works
//!
//! `@import("hexane/bool.zig")`, or `zautomerge.hexane.bool_codec` through the root
//! module. Zig 0.16.0. What a column imports from here is [`Bool`] and its
//! [`Bool.Decoder`] — and [`BoolWith`] for a codec on another wire.
//!
//! ```zig
//! var out: std.ArrayList(u8) = .empty;
//! try Bool.append(&out, gpa, &.{ true, false, false }); // canonical bytes
//! var it = try Bool.Decoder.init(out.items);             // borrows `out`
//! while (try it.next()) |v| { _ = v; }
//! ```
//!
//! # What it deliberately does not do
//!
//! It carries no payload. A value costs no bytes of its own, so a boolean slab
//! is a bare sequence of run counts and the codec has nothing to copy out of
//! it — [`Bool.Decoder`] hands back `bool` values, never windows.
//!
//! # What it hands back whole
//!
//! [`Bool.Decoder.nth`] reaches a row without reading the ones in front of
//! it, and [`Bool.Decoder.nextRunMax`] goes one step further and hands back
//! the *runs* — the shape upstream's `RunDecoder` gives a boolean column
//! (`bool.rs:598-617`). A boolean run stores a count and nothing else, so a
//! run is O(1) whatever its count is: there is no payload for a skip to walk
//! and no payload for it to stop validating.

const std = @import("std");
const rle = @import("rle.zig");
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

/// The boolean slab codec under an explicit packing. The count is the only
/// thing this format stores, so this is the narrowest place the packing shows:
/// a run count packed one way and the opening pad packed another is not a
/// second boolean wire, it is an unreadable one.
pub fn BoolWith(comptime P: type) type {
    return struct {
        /// The number of bytes `write` will emit for `values`.
        pub fn encodedSize(values: []const bool) usize {
            var total: usize = 0;
            var runs = RunIter.init(values);
            while (runs.next()) |run| total += P.unsignedSize(@as(u64, @intCast(run.count)));
            return total;
        }

        /// Writes `values` into `out`, which must hold `encodedSize` bytes.
        pub fn write(out: []u8, values: []const bool) void {
            var pos: usize = 0;
            var runs = RunIter.init(values);
            while (runs.next()) |run| {
                pos += P.writeUnsigned(out[pos..], @as(u64, @intCast(run.count)));
            }
        }

        /// Appends the encoding of `values` to `list`.
        pub fn append(list: *std.ArrayList(u8), gpa: std.mem.Allocator, values: []const bool) !void {
            var runs = RunIter.init(values);
            while (runs.next()) |run| try P.appendUnsigned(list, gpa, @as(u64, @intCast(run.count)));
        }

        /// Decodes every value in a slab. The caller owns the returned slice.
        pub fn decodeAll(bytes: []const u8, gpa: std.mem.Allocator) ParseError![]bool {
            // Two passes: the first sums the run counts so the exact allocation
            // is made once, and it rejects a slab whose total does not fit a
            // `usize` before any memory is touched.
            const total = try countValues(P, bytes);
            const out = try gpa.alloc(bool, total);
            errdefer gpa.free(out);
            var pos: usize = 0;
            var written: usize = 0;
            var value = false;
            while (pos < bytes.len) {
                const run = try P.readUnsigned(bytes[pos..]);
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
        /// time, so this never materialises the whole slab. A walk that has
        /// to *reach* a row without reading the ones before it uses
        /// [`nth`](Decoder.nth), which steps over whole runs instead, and a
        /// walk that wants the runs themselves — a weight to sum, a slab to
        /// reindex — uses [`nextRunMax`](Decoder.nextRunMax), which is O(1)
        /// per run whatever the run's count is.
        pub const Decoder = struct {
            /// The slab being walked, borrowed: it must stay alive and unmodified
            /// for as long as this decoder is used, and its owner must outlive the
            /// decoder. Nothing a boolean column hands back points into it — the
            /// wire form carries no value bytes — so this is the only borrow a
            /// caller has to honour.
            bytes: []const u8,
            /// The offset of the next unread run count.
            pos: usize,
            /// Items left in the current run.
            remaining: usize,
            /// The current run's value. Starts as `true` so that the first
            /// flip yields the `false` the wire format opens with
            /// (upstream `bool.rs:490-502`).
            value: bool,

            /// A cursor standing at the start of `bytes`, which it borrows; see
            /// the `bytes` field.
            pub fn init(bytes: []const u8) ParseError!Decoder {
                return .{ .bytes = bytes, .pos = 0, .remaining = 0, .value = true };
            }

            /// The next value, null at the end of the slab. A malformed run
            /// count part-way through the slab is reported here, not swallowed.
            pub fn next(self: *Decoder) ParseError!?bool {
                while (self.remaining == 0) {
                    if (self.pos >= self.bytes.len) return null;
                    try self.advanceRun();
                }
                self.remaining -= 1;
                return self.value;
            }

            /// The value `n` values ahead, consuming the `n` in front of it,
            /// or null at the end of the slab (`Iterator::nth`,
            /// `bool.rs:579-595`).
            ///
            /// **O(runs skipped)** — each run is skipped in O(1) by
            /// decrementing the count, so reaching the last of a slab of a
            /// few long runs reads a few LEB128 counts rather than every
            /// value before it. A `n` past the end answers null and leaves
            /// the cursor spent, exactly as `n` calls to
            /// [`next`](Decoder.next) would (`self.remaining -= n; return
            /// self.next()`).
            ///
            /// Every refusal `next` raises is raised here at the same run:
            /// this module has no unchecked count reader, so a truncated or
            /// overlong varint and a count too wide for a `usize` are all
            /// reported rather than swallowed the way upstream's
            /// `advance_run` drops them (`bool.rs:552-558`).
            pub fn nth(self: *Decoder, n: usize) ParseError!?bool {
                var left = n;
                while (true) {
                    if (self.remaining > 0) {
                        if (left < self.remaining) {
                            self.remaining -= left;
                            return self.next();
                        }
                        left -= self.remaining;
                        self.remaining = 0;
                    }
                    if (self.pos >= self.bytes.len) return null;
                    try self.advanceRun();
                }
            }

            /// One run of a slab taken whole: `count` copies of `value`
            /// (`Run<bool>`, `lib.rs:195-198`).
            pub const RunValue = struct {
                /// How many values the run holds, never more than the budget
                /// the caller handed in.
                count: usize,
                /// The value every one of them carries.
                value: bool,
            };

            /// The next run of values, at most `max` of them, or null once the
            /// slab is exhausted (`RunDecoder::next_run_max`,
            /// `bool.rs:598-617`).
            ///
            /// **O(1) per run, whatever the run is.** A boolean run stores a
            /// count and nothing else — there is no run header and no payload
            /// behind one — so a run of one and a run of a million cost the
            /// same single varint read. That is what the same walk is only
            /// *partly* worth in `rle.zig:575-584`, where a literal run's
            /// values sit packed behind its header and have to come back one
            /// at a time. Here there is no third kind of run to worry about.
            ///
            /// **The value is a parity, not a read.** `self.value` already
            /// carries the current run's value because
            /// [`advanceRun`](Decoder.advanceRun) flips it once per count, so
            /// answering for it costs nothing — the field is the decoder's
            /// own state, initialised to `true` so the first flip yields the
            /// `false` the wire opens with (`bool.rs:457-460`,
            /// `bool.zig:195-198`).
            ///
            /// **The opening zero-count pad is stepped over, never served.**
            /// A count of zero leaves `remaining` at zero, so the loop takes
            /// another header — which is what [`next`](Decoder.next) and
            /// [`nth`](Decoder.nth) do, and what upstream does
            /// (`bool.rs:604-615`). An interior zero count is dropped and
            /// flips the parity the same way here as there, so the runs this
            /// hands back are the runs [`decodeAll`](BoolWith.decodeAll)
            /// writes and [`segmentsOf`](column.zig:2557) counts.
            ///
            /// **Past the end is null, with the slab spent**: `remaining` at
            /// zero and `pos` at `bytes.len`, byte for byte the state
            /// `next` leaves and where a further `nextRunMax` answers null
            /// again. A budget of zero answers null where upstream's
            /// `remaining.min(0)` hands back a zero-count run
            /// (`bool.rs:606`), and that is the one difference: a run that
            /// spends nothing is a run a caller looping on the count would
            /// never leave, so this takes the same guard `rle.zig:589-590`
            /// takes. Nothing is consumed by it, so the call after reads the
            /// run the first one would have.
            ///
            /// **No refusal is lost.** The only refusals a boolean run can
            /// carry are the three [`advanceRun`](Decoder.advanceRun) raises
            /// — a truncated varint, an overlong one, and a count too wide
            /// for a `usize` — and every one of them is a property of the
            /// run's own count varint, which this walk **has** to read to
            /// learn how long the run is. There is no payload behind a
            /// boolean run for a skip to step over unchecked, which is
            /// exactly what blocks the same walk in `rle.zig` (`rle.zig:
            /// 518-531`): a literal run's declared length and its UTF-8 live
            /// in its payload, so a count-only skip there would step over a
            /// refusal. Here every refusal is raised at the run that carries
            /// it, where the same number of `next` calls raises it.
            pub fn nextRunMax(self: *Decoder, max: usize) ParseError!?RunValue {
                if (max == 0) return null;
                while (true) {
                    if (self.remaining > 0) {
                        const count = @min(self.remaining, max);
                        self.remaining -= count;
                        return .{ .count = count, .value = self.value };
                    }
                    if (self.pos >= self.bytes.len) return null;
                    try self.advanceRun();
                }
            }

            /// Reads the run count at `pos`, flips the value it stands for
            /// and loads how many items the run owes — the run step
            /// [`next`](Decoder.next), [`nth`](Decoder.nth) and
            /// [`nextRunMax`](Decoder.nextRunMax) all take (`advance_run`,
            /// `bool.rs:547-559`).
            fn advanceRun(self: *Decoder) ParseError!void {
                const run = try P.readUnsigned(self.bytes[self.pos..]);
                self.pos += run.len;
                self.value = !self.value;
                self.remaining = std.math.cast(usize, run.value) orelse return error.Overflow;
            }
        };
    };
}

/// The boolean slab codec on the default wire. Upstream's `Codec` is a type
/// parameter with `Leb128` as its default everywhere (`codec.rs:228-246`), and
/// this is that default made explicit at the one place it is chosen.
pub const Bool = BoolWith(rle.Leb128);

/// The total number of values in `bytes`, or an error if the run counts do
/// not sum to something a `usize` can hold.
fn countValues(comptime P: type, bytes: []const u8) ParseError!usize {
    var total: usize = 0;
    var pos: usize = 0;
    while (pos < bytes.len) {
        const run = try P.readUnsigned(bytes[pos..]);
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
        const bytes = try encode(gpa, &(@as([127]bool, @splat(false))));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{0x7f}, bytes);
    }
    // 128 is the smallest two-byte count.
    {
        const bytes = try encode(gpa, &(@as([128]bool, @splat(false))));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, bytes);
    }
    // 300 = 0b10_0101100: low 7 bits 0101100, then 0b10.
    {
        const bytes = try encode(gpa, &(@as([300]bool, @splat(false))));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x02 }, bytes);
    }
    // 16383 is the largest two-byte count, 16384 the smallest three-byte one.
    {
        const bytes = try encode(gpa, &(@as([16383]bool, @splat(false))));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x7f }, bytes);
    }
    {
        const bytes = try encode(gpa, &(@as([16384]bool, @splat(false))));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x01 }, bytes);
    }
    // A run that follows another run keeps the same width rule, with the
    // padding run for the leading `true`.
    {
        const values: []const bool = &([_]bool{true} ++ @as([128]bool, @splat(false)));
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
    const second: []const bool = &(@as([300]bool, @splat(false)));
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

/// Holds [`Bool.Decoder.nth`] against `next` over `values`, which is what
/// `bytes` encodes: for every `i`, `nth(i)` is `values[i]`, the cursor is
/// left standing on that value, and the walk from there is unchanged.
///
/// **Every `i`, not a sample.** A run-level skip that mis-lands inside a run
/// still agrees at some offsets and fails at others, so a spot check cannot
/// stand in for the sweep.
fn checkNthParity(values: []const bool, bytes: []const u8) !void {
    for (values, 0..) |want, i| {
        var jumped = try Bool.Decoder.init(bytes);
        try std.testing.expectEqual(@as(?bool, want), try jumped.nth(i));
        // The cursor stands on `i`, so `next` answers `i + 1`.
        for (values[i + 1 ..]) |rest| {
            try std.testing.expectEqual(@as(?bool, rest), try jumped.next());
        }
        try std.testing.expectEqual(@as(?bool, null), try jumped.next());
    }
}

test "nth reaches every value of a slab, over a run or not" {
    const gpa = std.testing.allocator;
    const cases = [_][]const bool{
        // The empty slab: no runs at all, so `nth(0)` is already past the end.
        &.{},
        // The single-run slabs, which are where a skip that walks runs
        // instead of subtracting counts has nothing else to fall back on.
        &.{false},
        &.{true},
        &(@as([7]bool, @splat(false))),
        &(@as([300]bool, @splat(true))),
        // Two runs, and the same slab opened on `true` — so the zero-count
        // pad is a run of its own that a skip steps over rather than serves.
        &.{ false, true },
        &.{ true, false },
        &.{ false, false, false, true, true },
        &.{ true, true, true, false, false, false },
        // Every value its own run: the skip pays one varint read per run, and
        // a count of one is where an off-by-one lands on the next run.
        &.{ true, false, true, false, true, false },
        &.{ false, true, false, true },
        // A count that crosses the LEB128 width boundary, so a run's count is
        // read from two bytes rather than one. Kept short on purpose: the
        // parity sweep is quadratic, and a two-byte count does not need a
        // 16k-value slab to be exercised.
        &(@as([200]bool, @splat(true))),
    };
    for (cases) |slice| {
        const bytes = try encode(gpa, slice);
        defer gpa.free(bytes);
        try checkNthParity(slice, bytes);
    }
    // The empty slab answers `nth` the way it answers `next`.
    {
        var dec = try Bool.Decoder.init(&[_]u8{});
        try std.testing.expectEqual(@as(?bool, null), try dec.nth(0));
        try std.testing.expectEqual(@as(?bool, null), try dec.next());
    }
    // A wide slab over many runs, at every offset.
    {
        var wide: [400]bool = undefined;
        pseudoRandom(&wide, 4242);
        const bytes = try encode(gpa, &wide);
        defer gpa.free(bytes);
        try checkNthParity(&wide, bytes);
    }
    // Past the end, by one and by a wide margin, and spent either way.
    {
        const bytes = try encode(gpa, &.{ false, false, true });
        defer gpa.free(bytes);
        var past = try Bool.Decoder.init(bytes);
        try std.testing.expectEqual(@as(?bool, null), try past.nth(3));
        try std.testing.expectEqual(@as(?bool, null), try past.next());
        var far = try Bool.Decoder.init(bytes);
        try std.testing.expectEqual(@as(?bool, null), try far.nth(3 + 1000));
        try std.testing.expectEqual(@as(?bool, null), try far.next());
    }
}

test "nth raises the refusals next does" {
    // A truncated varint behind a run the skip walks over: the same
    // `error.UnexpectedEnd` a `next` past the run's last value raises. This
    // is the refusal a count-only skip would swallow — upstream's
    // `advance_run` sets `remaining = 0` and ends the iteration instead
    // (`bool.rs:552-558`), where this module's reader reports.
    {
        var dec = try Bool.Decoder.init(&.{ 0x02, 0x80 });
        try std.testing.expectEqual(@as(?bool, false), try dec.nth(1));
        try std.testing.expectError(error.UnexpectedEnd, dec.nth(0));
    }
    // An overlong LEB128, refused as a malformed encoding rather than read
    // as a count.
    {
        var dec = try Bool.Decoder.init(&(@as([11]u8, @splat(0x80))));
        try std.testing.expectError(error.InvalidLeb128, dec.nth(0));
    }
    // A count the tenth byte cannot hold: refused as an overflow, which is
    // what `decodeAll` and `countValues` raise for the same bytes.
    {
        var dec = try Bool.Decoder.init(
            &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 },
        );
        try std.testing.expectError(error.Overflow, dec.nth(0));
    }
    // A slab that decodes cleanly decodes the same walked by `nth` alone,
    // with the cursor landing on each row in turn.
    //
    // **Each offset is asked of its OWN cursor.** A `nth(n)` consumes `n + 1`
    // rows from wherever the cursor stands, so a cursor carried round the loop
    // lands iteration `i` on row `2i - 1`, not row `i` — the two agree only
    // for `i <= 1`. This is the shape `expectNth` in column.zig already uses,
    // for the same reason.
    {
        const gpa = std.testing.allocator;
        var values: [300]bool = undefined;
        pseudoRandom(&values, 7);
        const bytes = try encode(gpa, values[0..]);
        defer gpa.free(bytes);
        for (values, 0..) |want, i| {
            var fresh = try Bool.Decoder.init(bytes);
            try std.testing.expectEqual(@as(?bool, want), try fresh.nth(i));
        }
        // And past the end, from a cursor that has never been moved.
        var past = try Bool.Decoder.init(bytes);
        try std.testing.expectEqual(@as(?bool, null), try past.nth(values.len));
    }
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
    try std.testing.expectError(error.InvalidLeb128, Bool.decodeAll(&(@as([11]u8, @splat(0x80))), gpa));
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
    try std.testing.expectError(error.Overflow, countValues(rle.Leb128, &slab));
}

/// Holds [`Bool.Decoder.nextRunMax`] against `next` and `nth` over `values`,
/// which is what `bytes` encodes: every value a run carries is the one
/// `next` reads at the same offset, and every offset is also the one `nth`
/// lands on.
///
/// **Every value, not a sample.** A run-level walk that mis-lands inside a
/// run still agrees at some offsets and fails at others, so a spot check
/// cannot stand in for the sweep.
///
/// The budget handed in is `values.len`, which is past the end of every slab
/// this is called with: no run is ever cut short, so what it compares are
/// the runs the format declares. A budget short enough to cut one is
/// `nextRunMax past the end, on a budget, and spent`'s question.
fn checkNextRunMaxParity(values: []const bool, bytes: []const u8) !void {
    var runs = try Bool.Decoder.init(bytes);
    var items = try Bool.Decoder.init(bytes);
    var seen: usize = 0;
    while (try runs.nextRunMax(values.len)) |run| {
        // A count of zero would spend nothing and the walk would never end.
        // The format has the one, and it is stepped over rather than served.
        try std.testing.expect(run.count > 0);
        for (0..run.count) |_| {
            try std.testing.expect(seen < values.len);
            try std.testing.expectEqual(@as(?bool, values[seen]), try items.next());
            // **A fresh cursor per offset.** `nth(n)` consumes the `n` in
            // front of the target, so a cursor carried round the loop would
            // land on row `2n` rather than row `n` — the reason
            // `nth raises the refusals next does` asks each offset of its own
            // cursor too.
            var jumped = try Bool.Decoder.init(bytes);
            try std.testing.expectEqual(@as(?bool, values[seen]), try jumped.nth(seen));
            seen += 1;
        }
    }
    try std.testing.expectEqual(values.len, seen);
    // Both walks are spent, and the run walk says so where `next` does.
    try std.testing.expectEqual(@as(?bool, null), try items.next());
    try std.testing.expectEqual(@as(?Bool.Decoder.RunValue, null), try runs.nextRunMax(1));
}

test "nextRunMax hands back every run of a slab whole" {
    const gpa = std.testing.allocator;
    const cases = [_][]const bool{
        // The empty slab: no runs at all, so the walk answers null at once.
        &.{},
        // **Runs of 0.** Only the very first count may be zero — the pad that
        // lets a slab open on `true` — and it is stepped over rather than
        // served, so a slab that opens on `true` starts with a *real* run.
        &.{true},
        &.{ true, true },
        // **Runs of 1 and of 2**, where a run-level walk and a value-level
        // walk differ by the least there is to tell.
        &.{false},
        &.{ false, false },
        &.{ false, true },
        &.{ true, false },
        &.{ true, false, true, false, true, false },
        &.{ false, false, true, true },
        // **Runs of 300.** A count whose LEB128 takes two bytes, so the run's
        // length is not the length of the run's own header, on its own and
        // behind another run.
        &(@as([300]bool, @splat(false))),
        &(@as([300]bool, @splat(true))),
        &(@as([300]bool, @splat(false)) ++ @as([300]bool, @splat(true))),
        &(@as([300]bool, @splat(true)) ++ @as([300]bool, @splat(false))),
        // A slab that opens on `true` and then alternates: the pad, a wide
        // run and a count of 1 all in one slab, which is the shape where a
        // skip that treats the pad as a run or forgets to flip its parity
        // shows.
        &(@as([2]bool, @splat(true)) ++ [_]bool{false} ++ [_]bool{true} ++ @as([300]bool, @splat(false))),
        &([_]bool{true} ++ @as([3]bool, @splat(false)) ++ [_]bool{true}),
    };
    for (cases) |slice| {
        const bytes = try encode(gpa, slice);
        defer gpa.free(bytes);
        try checkNextRunMaxParity(slice, bytes);
    }
    // A slab of many runs, at every run boundary.
    {
        var wide: [400]bool = undefined;
        pseudoRandom(&wide, 2024);
        const bytes = try encode(gpa, &wide);
        defer gpa.free(bytes);
        try checkNextRunMaxParity(&wide, bytes);
    }
    // **The opening pad is not a run.** `[true, true]` is two counts and one
    // run, and the walk says so before it says anything about the values.
    {
        const bytes = try encode(gpa, &.{ true, true });
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0, 2 }, bytes);
        var dec = try Bool.Decoder.init(bytes);
        const run = (try dec.nextRunMax(16)).?;
        try std.testing.expectEqual(@as(usize, 2), run.count);
        try std.testing.expectEqual(true, run.value);
        try std.testing.expectEqual(@as(?Bool.Decoder.RunValue, null), try dec.nextRunMax(16));
    }
    // The empty slab answers a run the way it answers a value.
    {
        var dec = try Bool.Decoder.init(&[_]u8{});
        try std.testing.expectEqual(@as(?Bool.Decoder.RunValue, null), try dec.nextRunMax(1));
        try std.testing.expectEqual(@as(?bool, null), try dec.next());
    }
}

test "nextRunMax past the end, on a budget, and spent" {
    const gpa = std.testing.allocator;
    // A budget cuts a run short and the rest of it comes back on the next
    // call under the same value, so 300 values are served by three reads of
    // one two-byte varint rather than 300 reads of one value.
    {
        const bytes = try encode(gpa, &(@as([300]bool, @splat(false))));
        defer gpa.free(bytes);
        var dec = try Bool.Decoder.init(bytes);
        for ([_]usize{ 100, 100, 100 }) |want| {
            const run = (try dec.nextRunMax(want)).?;
            try std.testing.expectEqual(want, run.count);
            try std.testing.expectEqual(false, run.value);
        }
        // Past the end, with a budget that would have fitted.
        try std.testing.expectEqual(@as(?Bool.Decoder.RunValue, null), try dec.nextRunMax(300));
        try std.testing.expectEqual(@as(?bool, null), try dec.next());
    }
    // A budget that crosses a run boundary hands back one run at a time, and
    // a budget of one is one value: the same five answers `next` gives.
    {
        const bytes = try encode(gpa, &.{ false, false, true, true, true });
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, bytes);
        var wide = try Bool.Decoder.init(bytes);
        const first = (try wide.nextRunMax(3)).?;
        try std.testing.expectEqual(@as(usize, 2), first.count);
        try std.testing.expectEqual(false, first.value);
        const second = (try wide.nextRunMax(3)).?;
        try std.testing.expectEqual(@as(usize, 3), second.count);
        try std.testing.expectEqual(true, second.value);
        try std.testing.expectEqual(@as(?Bool.Decoder.RunValue, null), try wide.nextRunMax(3));

        var ones = try Bool.Decoder.init(bytes);
        var items = try Bool.Decoder.init(bytes);
        while (try ones.nextRunMax(1)) |run| {
            try std.testing.expectEqual(@as(usize, 1), run.count);
            try std.testing.expectEqual(@as(?bool, run.value), try items.next());
        }
        try std.testing.expectEqual(@as(?bool, null), try items.next());
    }
    // Past the end by a wide margin, and spent either way: byte for byte the
    // state `next` leaves behind.
    {
        const bytes = try encode(gpa, &.{ false, false, true });
        defer gpa.free(bytes);
        const whole = std.math.maxInt(usize);
        // Past the end by a wide margin, and spent either way: byte for byte
        // the state `next` leaves behind. **The decoder is walked out first** —
        // a fresh one answers its first run, which is the point of the next
        // block.
        var past = try Bool.Decoder.init(bytes);
        _ = (try past.nextRunMax(whole)).?;
        _ = (try past.nextRunMax(whole)).?;
        try std.testing.expectEqual(@as(?Bool.Decoder.RunValue, null), try past.nextRunMax(whole));
        try std.testing.expectEqual(@as(?bool, null), try past.next());
        // Part way in, a run comes back whole and the next call reads the
        // run behind it rather than the rest of the one in hand.
        var mid = try Bool.Decoder.init(bytes);
        const head = (try mid.nextRunMax(whole)).?;
        try std.testing.expectEqual(@as(usize, 2), head.count);
        try std.testing.expectEqual(false, head.value);
        const tail = (try mid.nextRunMax(whole)).?;
        try std.testing.expectEqual(@as(usize, 1), tail.count);
        try std.testing.expectEqual(true, tail.value);
        try std.testing.expectEqual(@as(?Bool.Decoder.RunValue, null), try mid.nextRunMax(whole));
        try std.testing.expectEqual(@as(?bool, null), try mid.next());
    }
    // **A budget of zero answers null**, where upstream's `remaining.min(0)`
    // hands back a zero-count run (`bool.rs:606`). The difference is the
    // guard `rle.zig:589-590` takes: a run that spends nothing is a run a
    // caller looping on the count would never leave. Nothing is consumed, so
    // the very next call reads the run the first one would have.
    {
        const bytes = try encode(gpa, &.{ false, false, true });
        defer gpa.free(bytes);
        var dec = try Bool.Decoder.init(bytes);
        try std.testing.expectEqual(@as(?Bool.Decoder.RunValue, null), try dec.nextRunMax(0));
        // The zero budget consumed nothing, so the run behind it is still
        // whole — but the budget of one cuts that run to one row, and the
        // row left in hand is the `false` the next call answers.
        try std.testing.expectEqual(@as(usize, 1), (try dec.nextRunMax(1)).?.count);
        try std.testing.expectEqual(@as(?bool, false), try dec.next());
        try std.testing.expectEqual(@as(?bool, true), try dec.next());
    }
}

test "nextRunMax raises the refusals next does" {
    const whole = std.math.maxInt(usize);
    // A truncated varint behind a run the walk steps over: the same
    // `error.UnexpectedEnd` the `next` past that run's last value raises.
    // Upstream's `advance_run` sets `remaining = 0` and ends the iteration
    // instead (`bool.rs:552-558`), so this is the refusal a run-level walk
    // would swallow if it did not have to read the count to know how long
    // the run is.
    {
        var dec = try Bool.Decoder.init(&.{ 0x02, 0x80 });
        const run = (try dec.nextRunMax(whole)).?;
        try std.testing.expectEqual(@as(usize, 2), run.count);
        try std.testing.expectEqual(false, run.value);
        try std.testing.expectError(error.UnexpectedEnd, dec.nextRunMax(whole));
        // And the walk is not spent by the refusal: the cursor is where the
        // error left it, exactly as `next` leaves it.
        try std.testing.expectError(error.UnexpectedEnd, dec.next());
    }
    // An overlong LEB128, refused as a malformed encoding rather than read
    // as a count.
    {
        var dec = try Bool.Decoder.init(&(@as([11]u8, @splat(0x80))));
        try std.testing.expectError(error.InvalidLeb128, dec.nextRunMax(whole));
    }
    // A count the tenth byte cannot hold: refused as an overflow, which is
    // what `decodeAll` and `countValues` raise for the same bytes.
    {
        var dec = try Bool.Decoder.init(
            &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 },
        );
        try std.testing.expectError(error.Overflow, dec.nextRunMax(whole));
    }
    // **A refusal behind a wide budget, not just behind a count of one.** A
    // slab's weight is summed under a budget of the whole slab, so the
    // refusal has to survive it: it is the walk that must read every count,
    // not the budget that has to be small.
    {
        var dec = try Bool.Decoder.init(&.{ 0x05, 0x05, 0x80 });
        try std.testing.expectEqual(@as(usize, 5), (try dec.nextRunMax(whole)).?.count);
        try std.testing.expectEqual(@as(usize, 5), (try dec.nextRunMax(whole)).?.count);
        try std.testing.expectError(error.UnexpectedEnd, dec.nextRunMax(whole));
    }
    // A slab that decodes cleanly decodes the same walked run by run, with
    // every value landing where `next` puts it.
    {
        const gpa = std.testing.allocator;
        var values: [300]bool = undefined;
        pseudoRandom(&values, 11);
        const bytes = try encode(gpa, values[0..]);
        defer gpa.free(bytes);
        var runs = try Bool.Decoder.init(bytes);
        var items = try Bool.Decoder.init(bytes);
        while (try runs.nextRunMax(values.len)) |run| {
            for (0..run.count) |_| {
                try std.testing.expectEqual(@as(?bool, run.value), try items.next());
            }
        }
        try std.testing.expectEqual(@as(?bool, null), try items.next());
        try std.testing.expectEqual(@as(?Bool.Decoder.RunValue, null), try runs.nextRunMax(values.len));
    }
    // The runs the walk hands back add up to the values `decodeAll` writes,
    // which is the invariant every consumer of a weight rests on.
    {
        const gpa = std.testing.allocator;
        var values: [301]bool = undefined;
        pseudoRandom(&values, 4321);
        const bytes = try encode(gpa, values[0..]);
        defer gpa.free(bytes);
        const decoded = try Bool.decodeAll(bytes, gpa);
        defer gpa.free(decoded);
        var total: usize = 0;
        var dec = try Bool.Decoder.init(bytes);
        while (try dec.nextRunMax(whole)) |run| total += run.count;
        try std.testing.expectEqual(decoded.len, total);
        try std.testing.expectEqual(values[0..].len, total);
    }
}

// ── Upstream `hexane/src/tests.rs`, the frozen byte fixtures ──────────────────

test "golden_format_bool" {
    // **`tests.rs:4834-4839`.** Both arms of upstream's `golden_rle::<bool>`,
    // against the frozen bytes.
    //
    // **A single-slab column's `save()` *is* its codec's bytes** — the column
    // wire format carries no column-level header above the run sequence, so
    // the fixture is the codec's output and pinning it needs no `Column`.
    // Upstream froze these at `tests.rs:4762-4771` and says outright that a
    // failure here is a compatibility break with every existing automerge
    // document; the bytes are written out for that reason rather than read
    // from the corpus.
    {
        // `[2, 3, 1]`: two false, three true, one false. A boolean slab is a
        // bare sequence of run counts with no value bytes at all
        // (`bool.rs:33-49`), so three bytes are three counts.
        const values = [_]bool{ false, false, true, true, true, false };
        const bytes = try encode(std.testing.allocator, &values);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 2, 3, 1 }, bytes);

        const back = try Bool.decodeAll(bytes, std.testing.allocator);
        defer std.testing.allocator.free(back);
        try std.testing.expectEqualSlices(bool, &values, back);
    }
    {
        // `[0, 2, 1]`: a column starting **true** carries the zero-count false
        // pad, because the first count describes the false run and this
        // sequence begins with a value that is not false.
        const values = [_]bool{ true, true, false };
        const bytes = try encode(std.testing.allocator, &values);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, &.{ 0, 2, 1 }, bytes);

        const back = try Bool.decodeAll(bytes, std.testing.allocator);
        defer std.testing.allocator.free(back);
        try std.testing.expectEqualSlices(bool, &values, back);
    }
}

// ── The differential corpus ──────────────────────────────────────────────────

const corpus = @import("codec_golden.zig");

/// The boundary cases the boolean corpus has to carry.
///
/// The run counts are where a count's own LEB128 width changes, the
/// `run_*_true` cases are the ones that open on a zero-count pad, and
/// `sandwich_*` are three runs with a single opposite value in the middle —
/// the shape where a leading pad and a real run are easy to confuse.
const bool_boundary_cases = [_][]const u8{
    "empty",
    "one_false",
    "one_true",
    "run_2_false",
    "run_2_true",
    "run_63_false",
    "run_64_true",
    "run_127_false",
    "run_128_true",
    "run_16383_false",
    "run_16384_true",
    "run_16385_false",
    "alternating_odd",
    "alternating_even",
    "sandwich_false_1",
    "sandwich_true_1",
    "sandwich_false_128",
    "sandwich_true_16384",
    "random_0",
    "random_12",
    "random_23",
};

/// One golden case, through the boolean codec.
fn boolCase(rec: corpus.Record, gpa: std.mem.Allocator) !void {
    if (!std.mem.eql(u8, rec.codec, "bool")) return error.CorpusCodecUnknown;
    try corpus.checkOne(Bool, bool, gpa, rec);
}

test "the boolean codec encodes the reference's bytes for every golden case" {
    const gpa = std.testing.allocator;
    var names = corpus.Names.init(gpa);
    defer names.deinit();

    const cases = try corpus.eachCase(gpa, "bool", &names, boolCase);
    try std.testing.expectEqual(@as(usize, 71), cases);
    try names.expectRequired(&bool_boundary_cases);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`golden_format_bool` is pinned at the codec, for the same reason the RLE
//   fixtures are.** A boolean slab is a bare sequence of run counts with no
//   value bytes (`bool.rs:33-49`), and there is no column-level header above
//   one, so `Column::<bool>::from_values(..).save()` over
//   `[false,false,true,true,true,false]` *is* `Bool.write` over the same
//   values: `[2, 3, 1]`. Both upstream arms are here, including the one that
//   exists because a column starting true carries the zero-count false pad.
//
// * **Neither of the two upstream boolean cases is blocked, and both need the
//   column's slab list, which is `column.zig`'s.**
//   `bool_encoder_into_column_direct_matches_load` is declared there: a
//   `Column(bool, Bool)` built through `Encoder` at a budget of four over four
//   hundred rows must `save()` the bytes a plain column's `save()` writes
//   (`column.zig:14952-14992`). **That is the multi-slab seam this file cannot
//   build** — `Bool` encodes and decodes one slab, and `Slab.splice` rewrites
//   only inside a single one. `fuzz_bool_splice_exhaustive` splices a
//   `Column<bool>` against a `Vec` model, and the port drives exactly that
//   comparison over a many-slab boolean column in `random splices agree with a
//   plain array`, `a seed sweep holds the merge policy over many slab layouts`
//   and `a column of many slabs keeps its index, its budget and its values`
//   (`column.zig:7946`, `:7935`, `:7858`). **What is not upstream's is the
//   sweep's shape**: upstream walks nine `(del, ins)` pairs at *every* position
//   of a 200-row column built at an eight-segment budget (`tests.rs:2853-2907`),
//   where the port draws the position, the delete and the insert from pinned
//   seeds and runs the column at the default budget. Which case carries which
//   status is `docs/hexane-cases.json`'s.
//
// * **The zero-count pad is a property of the *first run*, not of the first
//   value.** That is why `[true, true, false]` is `[0, 2, 1]` and not
//   `[2, 1]`: the first count describes the false run, and this sequence
//   begins with a value that is not false. `Bool.encodedSize` and `Bool.write`
//   both have to agree that it costs a byte, and the bytes are obtained
//   through `encodedSize`, so a disagreement between them would fail the byte
//   compare rather than hide inside it.
//
// * **`nextRunMax` is upstream's `RunDecoder::next_run_max`
//   (`bool.rs:598-617`) and it is here whole, not partially.** `rle.zig`'s
//   `nextRunMax` can only take a *repeat* or a *null* run whole
//   (`rle.zig:589-619`): a literal run's values sit packed behind its header,
//   so it comes back one value at a time and the walk costs O(values) for it.
//   A boolean run has no payload at all — its value is its position in the run
//   sequence (`bool.rs:13-25`) — so every run is O(1) and the walk is
//   O(runs) for the whole slab.
//
// * **The "no refusal is lost" contract transfers to `bool`, and the reason
//   is the same fact.** For `rle` it holds only because `nth` re-reads a
//   literal run's payloads (`skipLiterals`, `rle.zig:621-635`) — that is what
//   keeps `error.LengthExceedsInput` and `error.InvalidUtf8` alive under a
//   count-only skip (`rle.zig:518-531`). `bool` has neither refusal anywhere
//   in its decoder: its run header *is* its whole body, and the only three
//   refusals `advanceRun` can raise — `error.UnexpectedEnd`,
//   `error.InvalidLeb128` and `error.Overflow` — are all properties of that
//   one count varint (`advanceRun`, below `nextRunMax`), which a run-level
//   walk must read to learn the run's length. So there is nothing behind a
//   boolean run for a skip to step over unchecked, and the contract is
//   satisfied by construction rather than by a workaround.
//
// * **The one deviation from upstream is a budget of zero**, which answers
//   null here and a zero-count run there (`bool.rs:606`). It is the guard
//   `rle.zig:589-590` already takes, and it consumes nothing either way.
