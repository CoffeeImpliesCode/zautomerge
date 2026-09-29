//! The column layer: a column of values split into slabs and indexed by a
//! B+tree (`rust/hexane/src/column.rs`, `rust/hexane/src/encoding.rs`).
//!
//! A column owns an ordered list of [slabs](slab.zig) and a
//! [`btree.Tree`](btree.zig) over their weights. Every read that needs a
//! position walks the tree in O(log S); every write re-encodes the runs a
//! splice touched and nothing else.
//!
//! # The two type parameters
//!
//! `Column(T, E)` names the column's value type `T` and its slab codec `E`.
//! Upstream reaches the same place through `T::Encoding<C>`, a type-level
//! map from a value type to its byte layout (`encoding.rs:15-140`); in Zig
//! the codec is a type parameter, so the dispatch is a comptime choice
//! rather than a vtable (plan §3.2). `E` carries three things:
//!
//! * the **wire domain** — what a slab's bytes decode to. For the RLE,
//!   boolean and prefix codecs that is the value itself; for a delta
//!   column it is the difference from the previous row.
//! * the **encoder** — how to write a run of wire values back out, with the
//!   boolean codec's run parity as an extra argument.
//! * the **weight** — what the index stores per slab, which is the
//!   `WeightFn` seam of `column.rs:81-137`.
//!
//! # The weight seam
//!
//! Three weights, one shape (`A.Aggregate.{identity, merge, itemCount,
//! eql}`):
//!
//! | codec | weight | what the index can answer |
//! | --- | --- | --- |
//! | RLE, boolean | [`LenWeight`] | which slab holds row `i` |
//! | prefix | [`PrefixWeight`] | the same, plus the sum of the lengths before it |
//! | delta | `btree.SlabAgg` | the same, plus the value range a slab spans |
//!
//! Upstream picks between them with a type parameter and keeps the prefix
//! sum in the tree (`prefix.rs:541-566`, `delta/indexed.rs:15-20`); the tree
//! here is generic over the weight, so the same code serves all three.
//!
//! # The base of a slab
//!
//! A delta column stores differences, so a row's value is the sum of every
//! difference before it *in the column*, not just in its slab. Each slab
//! therefore has a base — the running value in front of it — and the column
//! keeps the merged weight of the slabs before each slab, which is that base
//! in O(1). It is rebuilt after every structural change, so the reindex
//! after a splice is O(slabs) from the first touched slab rather than
//! O(log S); the alternative is a prefix-sum query on the index, which the
//! tree does not have yet.
//!
//! # Cross-slab seams
//!
//! Two neighbouring slabs may end and start with the same value: the slab
//! layout is not required to be canonical across a boundary, only each slab
//! on its own. `encode` is what closes the gap, coalescing the boundary run
//! as it goes — upstream's `save_to` does the same with `do_merge`
//! (`column.rs:1360-1376`, `rle/splice.rs:1083-1115`). So
//! `load(encode())` round trips whatever the layout was.

const std = @import("std");
const err = @import("../error.zig");
const leb128 = @import("../leb128.zig");
const rle = @import("rle.zig");
const bool_codec = @import("bool.zig");
const btree = @import("btree.zig");
const slabmod = @import("slab.zig");

const Slab = slabmod.Slab;
const ParseError = err.ParseError;

/// The default run budget for one slab (`column.rs:21`).
pub const default_max_segments: usize = slabmod.default_max_segments;

// ── Weights ───────────────────────────────────────────────────────────────

/// The weight of a slab that carries no aggregate: its item count. What an
/// RLE or boolean column's index holds (`LenWeight`, `column.rs:115-137`).
pub const LenWeight = struct {
    /// The number of items in the slab.
    len: usize = 0,

    /// The weight of no slabs at all.
    pub const zero: LenWeight = .{};

    pub const Aggregate = struct {
        pub const identity: LenWeight = .zero;
        pub fn merge(l: LenWeight, r: LenWeight) LenWeight {
            return .{ .len = l.len + r.len };
        }
        pub fn itemCount(w: LenWeight) usize {
            return w.len;
        }
        pub fn eql(a: LenWeight, b: LenWeight) bool {
            return a.len == b.len;
        }
    };
};

/// The weight of a prefix column's slab: its item count and the sum of the
/// row lengths it holds. `(len, prefix)` is the weight a prefix index
/// navigates by (`prefix.rs:541-566`); the sum is signed so the same shape
/// serves a column whose lengths can decrease.
pub const PrefixWeight = struct {
    /// The number of items in the slab.
    len: usize = 0,
    /// The sum of the slab's item values.
    prefix: i64 = 0,

    /// The weight of no slabs at all.
    pub const zero: PrefixWeight = .{};

    /// How far the prefix sum advances over the slab.
    pub fn increment(self: PrefixWeight) i64 {
        return self.prefix;
    }

    pub const Aggregate = struct {
        pub const identity: PrefixWeight = .zero;
        pub fn merge(l: PrefixWeight, r: PrefixWeight) PrefixWeight {
            return .{ .len = l.len + r.len, .prefix = l.prefix + r.prefix };
        }
        pub fn itemCount(w: PrefixWeight) usize {
            return w.len;
        }
        pub fn eql(a: PrefixWeight, b: PrefixWeight) bool {
            return a.len == b.len and a.prefix == b.prefix;
        }
    };
};

// ── Shared helpers ────────────────────────────────────────────────────────

/// The realized-value domain of a delta column of `T`, as `i64`. A nullable
/// column realizes every value of its payload, so the domain is the
/// payload's, and a `u64` payload is clamped to what the wire can carry.
fn deltaDomain(comptime T: type) struct { min: i64, max: i64 } {
    return switch (payloadOf(T)) {
        u32 => .{ .min = 0, .max = std.math.maxInt(u32) },
        u64 => .{ .min = 0, .max = std.math.maxInt(i64) },
        i32 => .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) },
        i64 => .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) },
        else => @compileError("a delta column holds u32, u64, i32, i64, or an optional of one"),
    };
}

/// The value type behind a nullable column type.
fn payloadOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Whether a column type can hold absent values.
fn isNullable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => true,
        else => false,
    };
}

/// `a + b`, reported rather than wrapped: hostile bytes can steer a wrapped
/// sum back into a plausible-looking range.
fn addChecked(a: i64, b: i64) ParseError!i64 {
    return std.math.add(i64, a, b) catch error.Overflow;
}

/// The wire values a splice inserts, and the running value they leave
/// behind. Every codec answers; only the delta one changes it.
fn Inserted(comptime Wire: type) type {
    return struct {
        /// The values to write, in the codec's wire domain.
        wires: []Wire,
        /// The running value in front of whatever follows the insert.
        running: i64,
    };
}

/// A slab over `wires`, measured. The caller owns it.
///
/// A slab is a run sequence read from its own start, where the first run
/// is a `false` run, so the codec is told the region opens on `false` and
/// opens the pad itself when the slab has to start on `true`.
fn slabOf(gpa: std.mem.Allocator, comptime E: type, wires: []const E.Wire) ParseError!Slab {
    if (wires.len == 0) return .empty;
    const bytes = try E.wireEncode(gpa, wires, false);
    errdefer gpa.free(bytes);
    const m = try slabmod.measure(gpa, E, bytes);
    return .{ .data = bytes, .len = wires.len, .segments = m.segments, .tail = m.tail };
}

/// Every value of a slab, in wire form, through the run walk. Only a run
/// with a value has items, so the value-less run — the boolean pad —
/// contributes nothing.
fn wireAll(gpa: std.mem.Allocator, comptime E: type, bytes: []const u8) ParseError![]E.Wire {
    const segs = try E.segmentsOf(gpa, bytes);
    defer gpa.free(segs);
    var total: usize = 0;
    for (segs) |s| total = std.math.add(usize, total, s.itemCount()) catch return error.Overflow;
    const out = try gpa.alloc(E.Wire, total);
    errdefer gpa.free(out);
    var at: usize = 0;
    for (segs) |s| {
        const n = s.itemCount();
        if (s.first_value) |v| {
            @memset(out[at..][0..n], v);
            at += n;
        } else if (n != 0) {
            return error.InvalidValue;
        }
    }
    if (at != out.len) return error.InvalidValue;
    return out;
}

// ── The RLE-shaped wire layer ─────────────────────────────────────────────

/// The wire layer every RLE-shaped codec shares: the run format, the
/// segment walk, the tail, and the checks the splice machinery makes.
///
/// `Payload` is the integer a value packs as, and `Nullable` says whether a
/// null run is part of the format — the whole difference between `Rle` and
/// `RleOption`, and the reason a nullable column's wire element is
/// `?Payload`.
fn WireRle(comptime Payload: type, comptime Nullable: bool) type {
    return struct {
        const Self = @This();

        /// What one slab entry decodes to.
        pub const Wire = if (Nullable) ?Payload else Payload;

        /// A reader over a slab's wire entries.
        pub const WireDecoder = if (Nullable) rle.RleOption(Payload).Decoder else rle.Rle(Payload).Decoder;

        /// The element a null run yields, and a refusal for a format that
        /// has no null to yield.
        fn nullWire() ParseError!Wire {
            if (comptime Nullable) {
                const absent: Wire = null;
                return absent;
            }
            return error.UnexpectedNull;
        }

        /// The last value of the run `seg` describes and its byte width, or
        /// null when the run carries no value. One walk of a literal run;
        /// O(1) for a repeat or null run.
        fn lastOfRun(bytes: []const u8, seg: slabmod.Segment(Wire)) ParseError!?struct { value: Payload, len: usize } {
            const hdr = try leb128.readSigned(bytes[seg.byte_start..]);
            if (hdr.value == 0) return null;
            if (hdr.value > 0) {
                const v = try payloadRead(Payload, bytes, seg.byte_start + hdr.len);
                return .{ .value = v.value, .len = v.len };
            }
            const count = std.math.cast(usize, -hdr.value) orelse return error.Overflow;
            var pos = seg.byte_start + hdr.len;
            var last: Payload = undefined;
            var last_len: usize = 0;
            for (0..count) |_| {
                const v = try payloadRead(Payload, bytes, pos);
                last = v.value;
                last_len = v.len;
                pos += v.len;
            }
            return .{ .value = last, .len = last_len };
        }

        /// Every run of a slab, in wire order.
        pub fn segmentsOf(gpa: std.mem.Allocator, bytes: []const u8) ParseError![]slabmod.Segment(Wire) {
            var out: std.ArrayList(slabmod.Segment(Wire)) = .empty;
            errdefer out.deinit(gpa);
            var pos: usize = 0;
            var item: usize = 0;
            while (pos < bytes.len) {
                const hdr = try leb128.readSigned(bytes[pos..]);
                const payload = pos + hdr.len;
                var count: usize = undefined;
                var value: Wire = undefined;
                var end: usize = undefined;
                if (hdr.value > 0) {
                    const v = try payloadRead(Payload, bytes, payload);
                    count = std.math.cast(usize, hdr.value) orelse return error.Overflow;
                    value = v.value;
                    end = payload + v.len;
                } else if (hdr.value == 0) {
                    if (comptime !Nullable) return error.UnexpectedNull;
                    const n = try leb128.readUnsigned(bytes[payload..]);
                    count = std.math.cast(usize, n.value) orelse return error.Overflow;
                    value = try nullWire();
                    end = payload + n.len;
                } else {
                    count = std.math.cast(usize, -hdr.value) orelse return error.Overflow;
                    var p = payload;
                    const first = try payloadRead(Payload, bytes, p);
                    value = first.value;
                    p += first.len;
                    var k: usize = 1;
                    while (k < count) : (k += 1) p += (try payloadRead(Payload, bytes, p)).len;
                    end = p;
                }
                try out.append(gpa, .{
                    .byte_start = pos,
                    .byte_end = end,
                    .item_start = item,
                    .item_end = item + count,
                    .first_value = value,
                    .opens_with_true = false,
                    .kind = if (hdr.value == 0) .absent else if (hdr.value > 0) .repeat else .literal,
                });
                item = std.math.add(usize, item, count) catch return error.Overflow;
                pos = end;
            }
            return out.toOwnedSlice(gpa);
        }

        /// The values of items `[from, to)` of a slab, in wire form. The
        /// caller owns the slice.
        ///
        /// A repeat or absent run's items are all one value, so they are
        /// filled; a literal run's are read back off the wire, which is the
        /// only place a distinct value can come from.
        pub fn wireRange(
            gpa: std.mem.Allocator,
            bytes: []const u8,
            from: usize,
            to: usize,
        ) ParseError![]Wire {
            const segs = try segmentsOf(gpa, bytes);
            defer gpa.free(segs);
            var len: usize = 0;
            for (segs) |s| len = std.math.add(usize, len, s.itemCount()) catch return error.Overflow;
            if (to > len or from > to) return error.InvalidValue;
            const out = try gpa.alloc(Wire, to - from);
            errdefer gpa.free(out);
            var written: usize = 0;
            for (segs) |s| {
                if (from >= s.item_end or s.item_start >= to) continue;
                const lo = if (from > s.item_start) from - s.item_start else 0;
                const hi = if (to < s.item_end) to - s.item_start else s.itemCount();
                const n = hi - lo;
                if (n == 0) continue;
                switch (s.kind) {
                    .repeat => @memset(out[written..][0..n], s.first_value.?),
                    .absent => @memset(out[written..][0..n], try nullWire()),
                    .literal => try readLiteralRun(bytes, s, lo, n, out[written..][0..n]),
                    .pad => return error.InvalidValue,
                }
                written += n;
            }
            if (written != out.len) return error.InvalidValue;
            return out;
        }

        /// Items `lo .. lo + n` of the literal run `seg`, read off the wire.
        fn readLiteralRun(bytes: []const u8, seg: slabmod.Segment(Wire), lo: usize, n: usize, out: []Wire) ParseError!void {
            const hdr = try leb128.readSigned(bytes[seg.byte_start..]);
            var pos = seg.byte_start + hdr.len;
            var i: usize = 0;
            while (i < lo + n) : (i += 1) {
                const v = try payloadRead(Payload, bytes, pos);
                if (i >= lo) out[i - lo] = v.value;
                pos += v.len;
            }
        }

        /// The canonical encoding of `wires`. `opens_with_true` is the value
        /// the region's first run has to carry, which only the boolean codec
        /// reads; the RLE format stores every value and does not care which
        /// run it lands in.
        pub fn wireEncode(gpa: std.mem.Allocator, wires: []const Wire, opens_with_true: bool) ParseError![]u8 {
            _ = opens_with_true;
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            try appendRuns(gpa, &out, Payload, Nullable, wires);
            return out.toOwnedSlice(gpa);
        }

        /// One run of `len` copies of `value`, in O(1).
        pub fn wireFill(gpa: std.mem.Allocator, len: usize, value: Wire, opens_with_true: bool) ParseError![]u8 {
            _ = opens_with_true;
            if (len == 0) return gpa.alloc(u8, 0);
            if (len > std.math.maxInt(i64)) return error.TooLarge;
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            if (value) |v| {
                if (len == 1) {
                    try leb128.appendSigned(&out, gpa, -1);
                    try appendValue(gpa, &out, Payload, v);
                } else {
                    try appendRepeat(gpa, &out, Payload, len, v);
                }
            } else {
                try appendNullRun(gpa, &out, len);
            }
            return out.toOwnedSlice(gpa);
        }

        /// The runs `bytes[from..to]` describes, as a standalone slab. The
        /// parity argument is read only by the boolean codec.
        pub fn wireSlice(
            gpa: std.mem.Allocator,
            bytes: []const u8,
            from: usize,
            to: usize,
            opens_with_true: bool,
        ) ParseError![]u8 {
            _ = opens_with_true;
            return gpa.dupe(u8, bytes[from..to]);
        }

        /// The value the run `seg` closes on. This is the one value the
        /// splice machinery cannot read off a run's first value, because a
        /// literal run's last value is not its first.
        pub fn lastValueOfRun(bytes: []const u8, seg: slabmod.Segment(Wire)) ParseError!?Wire {
            const last = try lastOfRun(bytes, seg);
            if (last == null) return try nullWire();
            return last.?.value;
        }

        /// The byte width of the last value of the run `seg` describes, or
        /// zero when the run is a repeat or null run.
        pub fn litTail(bytes: []const u8, seg: slabmod.Segment(Wire)) ParseError!u32 {
            const last = try lastOfRun(bytes, seg);
            const width = if (last) |l| l.len else 0;
            if (width > std.math.maxInt(u32)) return error.TooLarge;
            return @intCast(width);
        }

        /// Whether two adjacent runs would carry the same value, so
        /// canonical form has to merge them.
        pub fn sameValue(a: ?Wire, b: ?Wire) bool {
            if (a == null or b == null) return false;
            if (comptime Nullable) {
                const x = a.?;
                const y = b.?;
                if (x == null or y == null) return x == null and y == null;
                return x.? == y.?;
            }
            return a.? == b.?;
        }

        /// Two runs of these kinds standing next to each other are not a
        /// canonical run sequence whatever their values: a canonical one
        /// never has two adjacent literal runs (`rle/decoder.rs:438-497`
        /// rules 4 and 6).
        pub fn mustMergeKinds(left_kind: slabmod.RunKind, right_kind: slabmod.RunKind) bool {
            return left_kind == .literal and right_kind == .literal;
        }

        /// Whether `bytes` is a well-formed canonical run sequence. The
        /// rules are upstream's `validate_after` (`rle/decoder.rs:438-497`),
        /// which is also exactly the check a column load has to make: a
        /// whole column is one run sequence.
        pub fn canonicalSlab(bytes: []const u8) ParseError!void {
            if (comptime Nullable) {
                return rle.RleOption(Payload).canonical(bytes);
            }
            return rle.Rle(Payload).canonical(bytes);
        }
    };
}

/// One value's byte width and how to read it. An unsigned integer packs as
/// unsigned LEB128 and a signed one signed, matching the upstream per-type
/// rules (`lib.rs:566-595`).
fn payloadRead(comptime Payload: type, bytes: []const u8, pos: usize) ParseError!struct { value: Payload, len: usize } {
    if (@typeInfo(Payload).int.signedness == .signed) {
        const v = try leb128.readSigned(bytes[pos..]);
        const narrow = std.math.cast(Payload, v.value) orelse return error.Overflow;
        return .{ .value = narrow, .len = v.len };
    }
    const v = try leb128.readUnsigned(bytes[pos..]);
    const narrow = std.math.cast(Payload, v.value) orelse return error.Overflow;
    return .{ .value = narrow, .len = v.len };
}

fn appendValue(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime Payload: type, v: Payload) !void {
    if (@typeInfo(Payload).int.signedness == .signed) {
        try leb128.appendSigned(out, gpa, v);
    } else {
        try leb128.appendUnsigned(out, gpa, v);
    }
}

fn appendRepeat(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime Payload: type, count: usize, v: Payload) !void {
    try leb128.appendSigned(out, gpa, @as(i64, @intCast(count)));
    try appendValue(gpa, out, Payload, v);
}

fn appendNullRun(gpa: std.mem.Allocator, out: *std.ArrayList(u8), count: usize) !void {
    try leb128.appendSigned(out, gpa, 0);
    try leb128.appendUnsigned(out, gpa, count);
}

/// The canonical run encoding of `wires`: a maximal run of two or more equal
/// values becomes a repeat run, a value that appears once joins the literal
/// run in progress, and a run of absent values becomes a null run. That is
/// the grouping `rle.zig`'s segmenter uses and the only one canonical form
/// admits, since two adjacent literal runs are not canonical
/// (`rle/decoder.rs:438-497`).
fn appendRuns(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime Payload: type,
    comptime Nullable: bool,
    wires: []const rleElement(Payload, Nullable),
) !void {
    var pos: usize = 0;
    var lit_start: usize = 0;
    var lit_len: usize = 0;
    while (pos < wires.len) {
        // The maximal run of equal values at `pos`.
        var j: usize = pos + 1;
        while (j < wires.len and eqlWire(Payload, Nullable, wires[j], wires[pos])) j += 1;
        const run = j - pos;
        if (comptime Nullable) {
            if (wires[pos]) |v| {
                if (run >= 2) {
                    lit_start = try flushLiteral(gpa, out, Payload, Nullable, wires, lit_start, lit_len);
                    lit_len = 0;
                    try appendRepeat(gpa, out, Payload, run, v);
                } else {
                    if (lit_len == 0) lit_start = pos;
                    lit_len += 1;
                }
            } else {
                lit_start = try flushLiteral(gpa, out, Payload, Nullable, wires, lit_start, lit_len);
                lit_len = 0;
                try appendNullRun(gpa, out, run);
            }
        } else {
            if (run >= 2) {
                lit_start = try flushLiteral(gpa, out, Payload, Nullable, wires, lit_start, lit_len);
                lit_len = 0;
                try appendRepeat(gpa, out, Payload, run, wires[pos]);
            } else {
                if (lit_len == 0) lit_start = pos;
                lit_len += 1;
            }
        }
        pos = j;
    }
    _ = try flushLiteral(gpa, out, Payload, Nullable, wires, lit_start, lit_len);
    lit_len = 0;
}

/// Writes the literal run in progress, if there is one, and returns the
/// start the next one begins at. Every value in it is present, because an
/// absent value ends the group.
fn flushLiteral(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime Payload: type,
    comptime Nullable: bool,
    wires: []const rleElement(Payload, Nullable),
    lit_start: usize,
    lit_len: usize,
) !usize {
    if (lit_len == 0) return lit_start;
    try leb128.appendSigned(out, gpa, -@as(i64, @intCast(lit_len)));
    for (wires[lit_start..][0..lit_len]) |v| {
        if (comptime Nullable) {
            try appendValue(gpa, out, Payload, v.?);
        } else {
            try appendValue(gpa, out, Payload, v);
        }
    }
    return lit_start + lit_len;
}

fn rleElement(comptime Payload: type, comptime Nullable: bool) type {
    return if (Nullable) ?Payload else Payload;
}

fn eqlWire(comptime Payload: type, comptime Nullable: bool, a: rleElement(Payload, Nullable), b: rleElement(Payload, Nullable)) bool {
    if (comptime Nullable) {
        if (a == null or b == null) return a == null and b == null;
        return a.? == b.?;
    }
    return a == b;
}

// ── Codecs ────────────────────────────────────────────────────────────────

/// The run-length codec for a non-nullable column of `T`. `T` is an
/// integer: unsigned types pack unsigned LEB128, signed types signed.
pub fn Rle(comptime T: type) type {
    if (@typeInfo(T) != .int) @compileError("Rle values must be an integer type");
    return struct {
        const Base = WireRle(T, false);

        pub const Value = T;
        pub const Wire = Base.Wire;
        pub const Weight = LenWeight;
        pub const tracks_prefix = false;
        pub const WireDecoder = Base.WireDecoder;

        pub const segmentsOf = Base.segmentsOf;
        pub const wireRange = Base.wireRange;
        pub const wireEncode = Base.wireEncode;
        pub const wireFill = Base.wireFill;
        pub const wireSlice = Base.wireSlice;
        pub const lastValueOfRun = Base.lastValueOfRun;
        pub const litTail = Base.litTail;
        pub const sameValue = Base.sameValue;
        pub const mustMergeKinds = Base.mustMergeKinds;
        pub const canonicalSlab = Base.canonicalSlab;

        /// The item count: a run of a run-length column has nothing to
        /// aggregate (`LenWeight::compute`, `column.rs:122`).
        pub fn weightOf(gpa: std.mem.Allocator, slab: *const Slab) ParseError!Weight {
            _ = gpa;
            return .{ .len = slab.len };
        }

        pub fn weightIncrement(w: Weight) i64 {
            _ = w;
            return 0;
        }

        /// The column value a wire entry stands for.
        pub fn valueOfWire(w: Wire, running: *i64) ParseError!Value {
            _ = running;
            return w;
        }

        /// Folds a wire value into a running sum, without realizing it. A
        /// delta column's differences are measured from the value in front
        /// of their slab, so the partial sums inside a slab can be negative
        /// and are not values; the running *value* of a row needs
        /// `valueOfWire` with the slab's base, and a running *sum* needs
        /// this.
        pub fn accumulate(w: Wire, running: *i64) ParseError!void {
            running.* = try addChecked(running.*, @as(i64, @intCast(w)));
        }

        /// The wire values `values` take, and the running value they leave
        /// behind — which is the input, unchanged.
        pub fn wireOfInsert(gpa: std.mem.Allocator, running: i64, values: []const Value) ParseError!Inserted(Wire) {
            const out = try gpa.dupe(Wire, values);
            return .{ .wires = out, .running = running };
        }

        /// Nothing to re-anchor: a run-length column stores the values.
        pub fn reanchor(wire: Wire, before: i64, after: i64) ParseError!?Wire {
            _ = wire;
            _ = before;
            _ = after;
            return null;
        }
    };
}

/// The run-length codec for a nullable column of `T`: an absent value rides
/// in the run header and never in a payload (`lib.rs:406-437`).
pub fn RleOption(comptime T: type) type {
    if (@typeInfo(T) != .int) @compileError("RleOption values must be an integer type");
    return struct {
        const Base = WireRle(T, true);

        pub const Value = ?T;
        pub const Wire = Base.Wire;
        pub const Weight = LenWeight;
        pub const tracks_prefix = false;
        pub const WireDecoder = Base.WireDecoder;

        pub const segmentsOf = Base.segmentsOf;
        pub const wireRange = Base.wireRange;
        pub const wireEncode = Base.wireEncode;
        pub const wireFill = Base.wireFill;
        pub const wireSlice = Base.wireSlice;
        pub const lastValueOfRun = Base.lastValueOfRun;
        pub const litTail = Base.litTail;
        pub const sameValue = Base.sameValue;
        pub const mustMergeKinds = Base.mustMergeKinds;
        pub const canonicalSlab = Base.canonicalSlab;

        pub fn weightOf(gpa: std.mem.Allocator, slab: *const Slab) ParseError!Weight {
            _ = gpa;
            return .{ .len = slab.len };
        }

        pub fn weightIncrement(w: Weight) i64 {
            _ = w;
            return 0;
        }

        pub fn valueOfWire(w: Wire, running: *i64) ParseError!Value {
            _ = running;
            return w;
        }

        /// Folds a wire value into a running sum, without realizing it: a
        /// row with no length contributes nothing to the sum.
        pub fn accumulate(w: Wire, running: *i64) ParseError!void {
            if (comptime isNullable(T)) {
                if (w) |v| running.* = try addChecked(running.*, @as(i64, @intCast(v)));
            } else {
                running.* = try addChecked(running.*, @as(i64, @intCast(w)));
            }
        }

        pub fn wireOfInsert(gpa: std.mem.Allocator, running: i64, values: []const Value) ParseError!Inserted(Wire) {
            const out = try gpa.dupe(Wire, values);
            return .{ .wires = out, .running = running };
        }

        pub fn reanchor(wire: Wire, before: i64, after: i64) ParseError!?Wire {
            _ = wire;
            _ = before;
            _ = after;
            return null;
        }
    };
}

/// The prefix codec: an ordinary RLE column of row lengths, with an index
/// that also carries their sum, so the offset of any row is one lookup
/// away. `T` is an integer or an optional of one; an absent length
/// contributes nothing to the sum (`prefix.rs:287-312`).
pub fn Prefix(comptime T: type) type {
    const Base = WireRle(payloadOf(T), isNullable(T));
    return struct {
        pub const Value = T;
        pub const Wire = Base.Wire;
        pub const Weight = PrefixWeight;
        pub const tracks_prefix = true;
        pub const WireDecoder = Base.WireDecoder;

        pub const segmentsOf = Base.segmentsOf;
        pub const wireRange = Base.wireRange;
        pub const wireEncode = Base.wireEncode;
        pub const wireFill = Base.wireFill;
        pub const wireSlice = Base.wireSlice;
        pub const lastValueOfRun = Base.lastValueOfRun;
        pub const litTail = Base.litTail;
        pub const sameValue = Base.sameValue;
        pub const mustMergeKinds = Base.mustMergeKinds;
        pub const canonicalSlab = Base.canonicalSlab;

        /// The item count and the sum of the row lengths. A sum that leaves
        /// `i64` is `error.Overflow` rather than a wrapped value.
        pub fn weightOf(gpa: std.mem.Allocator, slab: *const Slab) ParseError!Weight {
            _ = gpa;
            var sum: i64 = 0;
            var dec = try WireDecoder.init(slab.data);
            var i: usize = 0;
            while (i < slab.len) : (i += 1) {
                const w = (try dec.next()) orelse return error.InvalidValue;
                if (comptime isNullable(T)) {
                    // A row with no length contributes nothing to the sum.
                    if (w) |v| sum = try addChecked(sum, @as(i64, @intCast(v)));
                } else {
                    sum = try addChecked(sum, @as(i64, @intCast(w)));
                }
            }
            return .{ .len = slab.len, .prefix = sum };
        }

        pub fn weightIncrement(w: Weight) i64 {
            return w.increment();
        }

        pub fn valueOfWire(w: Wire, running: *i64) ParseError!Value {
            _ = running;
            return w;
        }

        /// Folds a wire value into a running sum, without realizing it: a
        /// row with no length contributes nothing to the sum.
        pub fn accumulate(w: Wire, running: *i64) ParseError!void {
            if (comptime isNullable(T)) {
                if (w) |v| running.* = try addChecked(running.*, @as(i64, @intCast(v)));
            } else {
                running.* = try addChecked(running.*, @as(i64, @intCast(w)));
            }
        }

        pub fn wireOfInsert(gpa: std.mem.Allocator, running: i64, values: []const Value) ParseError!Inserted(Wire) {
            const out = try gpa.dupe(Wire, values);
            return .{ .wires = out, .running = running };
        }

        pub fn reanchor(wire: Wire, before: i64, after: i64) ParseError!?Wire {
            _ = wire;
            _ = before;
            _ = after;
            return null;
        }
    };
}

/// The delta codec: the column's values stored as differences from the
/// previous row, with the index carrying the value range each slab spans
/// (`delta/mod.rs`, `delta/indexed.rs:15-20`).
///
/// A slab's differences are measured from the value standing in front of
/// the slab, so its first difference is the jump from the previous slab's
/// last value. That is what lets a delta column be stored as a flat run
/// sequence and read as one: the decoder's running value carries across the
/// slab boundaries on its own.
pub fn Delta(comptime T: type) type {
    const Base = WireRle(i64, true);
    const Payload = payloadOf(T);
    const Nullable = isNullable(T);

    return struct {
        pub const Value = T;
        /// A difference, or absent for a row that holds no value and so
        /// leaves the running value alone.
        pub const Wire = ?i64;
        pub const Weight = btree.SlabAgg;
        pub const tracks_prefix = true;
        pub const WireDecoder = Base.WireDecoder;

        pub const segmentsOf = Base.segmentsOf;
        pub const wireRange = Base.wireRange;
        pub const wireEncode = Base.wireEncode;
        pub const wireFill = Base.wireFill;
        pub const wireSlice = Base.wireSlice;
        pub const lastValueOfRun = Base.lastValueOfRun;
        pub const litTail = Base.litTail;
        pub const sameValue = Base.sameValue;
        pub const mustMergeKinds = Base.mustMergeKinds;
        pub const canonicalSlab = Base.canonicalSlab;

        /// The realized-value domain, as `i64`. A `u64` column is clamped
        /// to the wire's own range, which is where the wire format closes
        /// (`delta.zig` `domainOf`, upstream `delta/mod.rs:99-100`).
        pub const domain = deltaDomain(T);
        /// The smallest value the column can realize.
        pub const min_i64: i64 = domain.min;
        /// The largest value the column can realize.
        pub const max_i64: i64 = domain.max;

        fn widen(v: Payload) ParseError!i64 {
            const wide: i128 = v;
            if (wide < min_i64 or wide > max_i64) return error.Overflow;
            return @intCast(v);
        }

        fn realize(running: i64) ParseError!T {
            const wide: i128 = running;
            if (wide < min_i64 or wide > max_i64) return error.Overflow;
            const p: Payload = @intCast(running);
            return p;
        }

        /// The item count, the sum of the differences, and the range the
        /// realized values span — which is what lets the index prune a
        /// subtree that cannot hold the value being searched for
        /// (`delta/indexed.rs:15-20`).
        ///
        /// A literal run's items carry a difference each, so its extremes
        /// are not at the run's endpoints and the walk visits every one of
        /// them. Upstream's loader folds runs in as they stream past
        /// (`WeightFn::accumulate_run`, `column.rs:105-113`) and never pays
        /// this; a splice does, once per slab it touches.
        pub fn weightOf(gpa: std.mem.Allocator, slab: *const Slab) ParseError!Weight {
            _ = gpa;
            if (slab.len == 0) return .zero;
            var dec = try WireDecoder.init(slab.data);
            // The running value starts at zero, because a slab's differences
            // are measured from the value in front of it — the slab's base,
            // which the index carries as the preceding slabs' total.
            var partial: i64 = 0;
            var lo: i64 = 0;
            var hi: i64 = 0;
            var n: usize = 0;
            while (n < slab.len) : (n += 1) {
                const w = (try dec.next()) orelse return error.InvalidValue;
                // An absent value holds the running value where it is.
                try accumulate(w, &partial);
                lo = @min(lo, partial);
                hi = @max(hi, partial);
            }
            return .{ .len = slab.len, .total = partial, .min_offset = lo, .max_offset = hi };
        }

        pub fn weightIncrement(w: Weight) i64 {
            return w.total;
        }

        /// The column value a difference stands for, given the running value
        /// in front of it. A non-nullable column has no absent row to
        /// realize.
        pub fn valueOfWire(w: Wire, running: *i64) ParseError!Value {
            if (w) |d| {
                running.* = std.math.add(i64, running.*, d) catch return error.Overflow;
                return realize(running.*);
            }
            if (comptime Nullable) return null;
            return error.UnexpectedNull;
        }

        /// Folds a difference into a running sum, without realizing it. A
        /// slab's differences are measured from the value in front of it, so
        /// the partial sums inside a slab can be negative and are not
        /// values; the running *value* of a row needs `valueOfWire` with the
        /// slab's base, and a running *sum* needs this.
        pub fn accumulate(w: Wire, running: *i64) ParseError!void {
            if (w) |d| running.* = try addChecked(running.*, d);
        }

        /// The differences `values` take when they land on a column whose
        /// running value is `running`, and the running value they leave
        /// behind — which is what the first row after the splice has to be
        /// re-anchored from (`delta/mod.rs:1384-1400`).
        pub fn wireOfInsert(gpa: std.mem.Allocator, running: i64, values: []const Value) ParseError!Inserted(Wire) {
            const out = try gpa.alloc(Wire, values.len);
            errdefer gpa.free(out);
            var acc = running;
            for (values, 0..) |v, i| {
                if (comptime Nullable) {
                    const maybe = v orelse {
                        out[i] = null;
                        continue;
                    };
                    const wide = try widen(maybe);
                    out[i] = std.math.sub(i64, wide, acc) catch return error.Overflow;
                    acc = wide;
                } else {
                    const wide = try widen(v);
                    out[i] = std.math.sub(i64, wide, acc) catch return error.Overflow;
                    acc = wide;
                }
            }
            return .{ .wires = out, .running = acc };
        }

        /// The difference the first row after the splice has to carry: its
        /// own value, which the splice did not move, measured from the value
        /// the inserted rows left behind. Null when that row is itself
        /// absent, since an absent row holds no difference.
        pub fn reanchor(wire: Wire, before: i64, after: i64) ParseError!?Wire {
            const d = wire orelse return null;
            const value = std.math.add(i64, before, d) catch return error.Overflow;
            return std.math.sub(i64, value, after) catch return error.Overflow;
        }
    };
}

/// The nullable delta codec the op set's counter column uses.
pub const DeltaOption = Delta(?u32);

/// The boolean codec: alternating run counts and no value bytes at all
/// (`bool.rs:13-25`). A count is a position, so a slab cut at a run
/// boundary has to be told which value its first run now carries — the
/// `opens_with_true` argument every codec's encoder takes.
pub const Bool = struct {
    pub const Value = bool;
    pub const Wire = bool;
    pub const Weight = LenWeight;
    pub const tracks_prefix = false;
    pub const WireDecoder = bool_codec.Bool.Decoder;

    /// Every run of a boolean slab. The first count is the number of
    /// `false`s, so a slab that starts on `true` opens with a count of zero
    /// — a run with no items, and the only such run the format has
    /// (`bool.rs:988-1002`).
    pub fn segmentsOf(gpa: std.mem.Allocator, bytes: []const u8) ParseError![]slabmod.Segment(Bool.Wire) {
        var out: std.ArrayList(slabmod.Segment(Bool.Wire)) = .empty;
        errdefer out.deinit(gpa);
        var pos: usize = 0;
        var item: usize = 0;
        var value: bool = false;
        var first = true;
        while (pos < bytes.len) {
            const c = try leb128.readUnsigned(bytes[pos..]);
            const count = std.math.cast(usize, c.value) orelse return error.Overflow;
            try out.append(gpa, .{
                .byte_start = pos,
                .byte_end = pos + c.len,
                .item_start = item,
                .item_end = item + count,
                .first_value = if (count == 0) null else value,
                .opens_with_true = value,
                .kind = if (count == 0) .pad else if (count == 1) .literal else .repeat,
            });
            item = std.math.add(usize, item, count) catch return error.Overflow;
            pos += c.len;
            // Only the very first run may hold no items, and it does not
            // flip the parity: it is the pad that lets a slab open on
            // `true` (`bool.rs:988-1002`). Every other run alternates,
            // including one that happens to be empty.
            if (!first or !value) value = !value;
            first = false;
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn wireRange(gpa: std.mem.Allocator, bytes: []const u8, from: usize, to: usize) ParseError![]Wire {
        const all = try wireAll(gpa, Bool, bytes);
        defer gpa.free(all);
        if (to > all.len or from > to) return error.InvalidValue;
        return gpa.dupe(Wire, all[from..to]);
    }

    /// The canonical encoding of `wires`, as a run sequence read from a
    /// position whose first run carries `true` when `opens_with_true` is
    /// set and `false` otherwise.
    ///
    /// A run's value is its position, and a run sequence read from its own
    /// start opens on a `false` run, so a region that has to open on
    /// `true` at an even position is written with the zero-count `false`
    /// run in front of it — the pad a boolean slab that starts on `true`
    /// opens with (`bool.rs:988-1002`). At an odd position the first run
    /// is a `true` run already, so the same values go out unpadded. That
    /// is the whole of the argument the encoder takes: where the region
    /// lands in the sequence it is written into.
    pub fn wireEncode(gpa: std.mem.Allocator, wires: []const Wire, opens_with_true: bool) ParseError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (wires.len != 0 and wires[0] and !opens_with_true) {
            try leb128.appendUnsigned(&out, gpa, 0);
        }
        var i: usize = 0;
        while (i < wires.len) {
            var n: usize = i + 1;
            while (n < wires.len and wires[n] == wires[i]) n += 1;
            try leb128.appendUnsigned(&out, gpa, n - i);
            i = n;
        }
        return out.toOwnedSlice(gpa);
    }

    /// One run of `len` copies of `value`, in O(1), placed the way
    /// `wireEncode` places a region that opens on `value`.
    pub fn wireFill(gpa: std.mem.Allocator, len: usize, value: Wire, opens_with_true: bool) ParseError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (len == 0) return out.toOwnedSlice(gpa);
        if (value and !opens_with_true) try leb128.appendUnsigned(&out, gpa, 0);
        try leb128.appendUnsigned(&out, gpa, len);
        return out.toOwnedSlice(gpa);
    }

    /// The runs `bytes[from..to]` describes, as a slab of its own: the
    /// bytes, plus the pad when the first of those runs is a `true` run,
    /// because a slab's own run sequence opens on a `false` run
    /// (`bool.rs:988-1002`).
    pub fn wireSlice(
        gpa: std.mem.Allocator,
        bytes: []const u8,
        from: usize,
        to: usize,
        opens_with_true: bool,
    ) ParseError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (opens_with_true) try leb128.appendUnsigned(&out, gpa, 0);
        try out.appendSlice(gpa, bytes[from..to]);
        return out.toOwnedSlice(gpa);
    }

    /// Every run of a boolean slab carries one value, so its last value is
    /// its first.
    pub fn lastValueOfRun(bytes: []const u8, seg: slabmod.Segment(Bool.Wire)) ParseError!?Wire {
        _ = bytes;
        return seg.first_value;
    }

    /// A boolean run stores no value, so there is no literal tail to record.
    pub fn litTail(bytes: []const u8, seg: slabmod.Segment(Bool.Wire)) ParseError!u32 {
        _ = bytes;
        _ = seg;
        return 0;
    }

    /// Whether two adjacent runs would carry the same value, so canonical
    /// form has to merge them.
    pub fn sameValue(a: ?Wire, b: ?Wire) bool {
        if (a == null or b == null) return false;
        return a.? == b.?;
    }

    /// No kinds of runs stand next to each other uneasily: a boolean run
    /// of one item is a run like any other, and two adjacent runs always
    /// carry different values because a run's value is its position in
    /// the sequence (`bool.rs:13-25`, `bool.rs:776-783`).
    pub fn mustMergeKinds(left_kind: slabmod.RunKind, right_kind: slabmod.RunKind) bool {
        _ = left_kind;
        _ = right_kind;
        return false;
    }

    /// A boolean run sequence is canonical when only the first run may hold
    /// no items: an interior or trailing zero count would mean two
    /// neighbouring runs carry the same value and should have been one
    /// (`bool.rs:776-783`).
    pub fn canonicalSlab(bytes: []const u8) ParseError!void {
        var pos: usize = 0;
        var run: usize = 0;
        while (pos < bytes.len) {
            const c = try leb128.readUnsigned(bytes[pos..]);
            pos += c.len;
            // A zero count anywhere but the opening pad means two
            // neighbouring runs carry the same value and should have been
            // one, and a trailing one means the slab holds nothing at all
            // (`bool.rs:784-824`).
            if (c.value == 0 and (run > 0 or pos >= bytes.len)) return error.InvalidValue;
            run += 1;
        }
    }

    pub fn weightOf(gpa: std.mem.Allocator, slab: *const Slab) ParseError!Weight {
        _ = gpa;
        return .{ .len = slab.len };
    }

    pub fn weightIncrement(w: Weight) i64 {
        _ = w;
        return 0;
    }

    pub fn valueOfWire(w: Wire, running: *i64) ParseError!Value {
        _ = running;
        return w;
    }

    /// Folds a wire value into a running sum, without realizing it.
    pub fn accumulate(w: Wire, running: *i64) ParseError!void {
        running.* = try addChecked(running.*, @as(i64, @intCast(w)));
    }

    pub fn wireOfInsert(gpa: std.mem.Allocator, running: i64, values: []const Value) ParseError!Inserted(Wire) {
        const out = try gpa.dupe(Wire, values);
        return .{ .wires = out, .running = running };
    }

    pub fn reanchor(wire: Wire, before: i64, after: i64) ParseError!?Wire {
        _ = wire;
        _ = before;
        _ = after;
        return null;
    }
};

// ── The column ────────────────────────────────────────────────────────────

/// A column of `T` values, stored as [`Slab`]s and indexed by their
/// weights. `E` is the slab codec, which names the wire format, the encoder
/// and the per-slab weight.
///
/// Every entry point that allocates takes the allocator, because the
/// column's slabs, the index's arena and the per-slab weight array all live
/// in it and `deinit` has to give every byte back.
pub fn Column(comptime T: type, comptime E: type) type {
    if (T != E.Value) @compileError("a column's value type is its codec's value type");
    return struct {
        const Self = @This();

        /// The column's value type.
        pub const Value = T;
        /// The slab codec.
        pub const Codec = E;
        /// What a slab's bytes decode to.
        pub const Wire = E.Wire;
        /// What the index stores per slab.
        pub const Weight = E.Weight;
        /// The run budget one slab may hold.
        pub const max_segments: usize = default_max_segments;

        const Tree = btree.Tree(Weight);
        const identity = Weight.Aggregate.identity;

        gpa: std.mem.Allocator,
        slabs: std.ArrayList(Slab),
        tree: Tree,
        total_len: usize,
        /// The merged weight of the slabs before each slab, plus one slot
        /// for the whole column. Only a codec whose weight carries a prefix
        /// keeps it: that is a slab's base, in O(1).
        agg_before: std.ArrayList(Weight),

        /// A column with no values and no slabs.
        pub fn init(gpa: std.mem.Allocator) ParseError!Self {
            return .{
                .gpa = gpa,
                .slabs = .empty,
                // The tree's own error set has an out-of-range variant a
                // fresh tree never reaches — it has no slabs to be out of
                // range of — so it becomes the refusal the column reports.
                .tree = Tree.init(gpa) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidIndex => return error.InvalidValue,
                },
                .total_len = 0,
                .agg_before = .empty,
            };
        }

        /// Frees every slab, the index and the weight array.
        pub fn deinit(self: *Self) void {
            for (self.slabs.items) |*s| s.deinit(self.gpa);
            self.slabs.deinit(self.gpa);
            self.tree.deinit();
            self.agg_before.deinit(self.gpa);
            self.* = undefined;
        }

        /// How many values the column holds.
        pub fn len(self: *const Self) usize {
            return self.total_len;
        }

        /// Whether the column holds no values.
        pub fn isEmpty(self: *const Self) bool {
            return self.total_len == 0;
        }

        /// How many slabs the values are spread over.
        pub fn slabCount(self: *const Self) usize {
            return self.slabs.items.len;
        }

        /// The slab at `index`, for a caller that walks the layout.
        pub fn slabAt(self: *const Self, index: usize) ?*const Slab {
            if (index >= self.slabs.items.len) return null;
            return &self.slabs.items[index];
        }

        /// The run count of every slab, which is what the budget is about.
        pub fn slabSegments(self: *const Self, gpa: std.mem.Allocator) ParseError![]usize {
            const out = try gpa.alloc(usize, self.slabs.items.len);
            errdefer gpa.free(out);
            for (self.slabs.items, 0..) |s, i| out[i] = s.segments;
            return out;
        }

        // ── Reading ─────────────────────────────────────────────────────

        /// The value at `index`, or null past the end. O(log S) to find the
        /// slab, then a walk of the runs before the row inside it.
        pub fn get(self: *const Self, index: usize) ParseError!?T {
            if (index >= self.total_len) return null;
            const hit = self.tree.findByPrefix(index) orelse return null;
            const s = &self.slabs.items[hit.slab];
            const offset = index - hit.items_before;
            var dec = try E.WireDecoder.init(s.data);
            // A delta column's values are measured from its slab's base; the
            // other codecs do not read `running` at all.
            var running = self.baseOf(hit.slab);
            var i: usize = 0;
            while (i < offset) : (i += 1) {
                const w = (try dec.next()) orelse return error.InvalidValue;
                _ = try E.valueOfWire(w, &running);
            }
            const w = (try dec.next()) orelse return error.InvalidValue;
            return try E.valueOfWire(w, &running);
        }

        /// A cursor over every value, in order. Crossing a slab boundary
        /// re-reads one decoder and allocates nothing, so a full walk costs
        /// one decoder setup per slab.
        pub fn iterator(self: *const Self) ParseError!Iterator {
            if (self.slabs.items.len == 0) {
                return .{
                    .col = self,
                    .slab_idx = 0,
                    .dec = try E.WireDecoder.init(&.{}),
                    .items_left = 0,
                    .running = 0,
                };
            }
            return .{
                .col = self,
                .slab_idx = 0,
                .dec = try E.WireDecoder.init(self.slabs.items[0].data),
                .items_left = self.total_len,
                .running = self.baseOf(0),
            };
        }

        /// The column's values, in order. The caller owns the slice.
        pub fn toSlice(self: *const Self, gpa: std.mem.Allocator) ParseError![]T {
            const out = try gpa.alloc(T, self.total_len);
            errdefer gpa.free(out);
            var it = try self.iterator();
            var i: usize = 0;
            while (try it.next()) |v| {
                if (i >= out.len) return error.InvalidValue;
                out[i] = v;
                i += 1;
            }
            if (i != out.len) return error.InvalidValue;
            return out;
        }

        /// The running value in front of row `index`. Which value that is
        /// depends on the codec, because the two index weights mean
        /// different things by it:
        ///
        /// * a **prefix** column's is the sum of the row lengths before the
        ///   row — its grand total at `len()`, which is how the op-set
        ///   loader sizes a companion column
        ///   (`op_set2/columns.rs:294-300`, `prefix.rs:541-566`);
        /// * a **delta** column's is the running *value*: the last realized
        ///   value in front of the row, because its differences are measured
        ///   from that, not a sum of the values the column holds
        ///   (`delta/mod.rs:1160-1200`). An absent row holds no difference
        ///   and so realizes nothing.
        ///
        /// Only a codec whose weight carries a prefix has one;
        /// `error.Unsupported` for the rest.
        pub fn runningAt(self: *const Self, index: usize) ParseError!i64 {
            if (!comptime E.tracks_prefix) return error.Unsupported;
            if (self.slabs.items.len == 0) return 0;
            const clamped = @min(index, self.total_len);
            var si: usize = undefined;
            var offset: usize = undefined;
            if (clamped < self.total_len) {
                const hit = self.tree.findByPrefix(clamped) orelse return error.InvalidValue;
                si = hit.slab;
                offset = clamped - hit.items_before;
            } else {
                si = self.slabs.items.len - 1;
                offset = self.slabs.items[si].len;
            }
            const s = &self.slabs.items[si];
            var running: i64 = 0;
            var dec = try E.WireDecoder.init(s.data);
            var i: usize = 0;
            while (i < offset) : (i += 1) {
                const w = (try dec.next()) orelse return error.InvalidValue;
                try E.accumulate(w, &running);
            }
            return try addChecked(self.baseOf(si), running);
        }

        // ── Writing ─────────────────────────────────────────────────────

        /// Appends one value. O(1) when the last slab has room.
        pub fn append(self: *Self, gpa: std.mem.Allocator, v: T) ParseError!void {
            try self.splice(gpa, self.total_len, 0, &[_]T{v});
        }

        /// Appends `values`, in order.
        pub fn extend(self: *Self, gpa: std.mem.Allocator, values: []const T) ParseError!void {
            try self.splice(gpa, self.total_len, 0, values);
        }

        /// Replaces the value at `index`.
        pub fn set(self: *Self, gpa: std.mem.Allocator, index: usize, v: T) ParseError!void {
            if (index >= self.total_len) return error.InvalidValue;
            try self.splice(gpa, index, 1, &[_]T{v});
        }

        /// Removes `n` values from `index`.
        pub fn removeN(self: *Self, gpa: std.mem.Allocator, index: usize, n: usize) ParseError!void {
            if (index > self.total_len or n > self.total_len - index) return error.InvalidValue;
            try self.splice(gpa, index, n, &.{});
        }

        /// Replaces the values `[index, index + del)` with `values`. This is
        /// what a remote change does when it inserts rows, so every boundary
        /// is a real case: an empty column, a splice at either end, a
        /// splice that removes everything, and a splice that spans slabs.
        ///
        /// `index + del` past the end is `error.InvalidValue`, matching
        /// upstream's out-of-bounds assertion (`column.rs:1773`).
        pub fn splice(
            self: *Self,
            gpa: std.mem.Allocator,
            index: usize,
            del: usize,
            values: []const T,
        ) ParseError!void {
            if (index > self.total_len or del > self.total_len - index) return error.InvalidValue;
            if (del == 0 and values.len == 0) return;
            if (self.slabs.items.len == 0) {
                try self.slabs.append(gpa, .empty);
                try self.reindex();
            }

            const s0 = self.slabHolding(index);
            const s1 = self.slabHolding(index + del);
            if (s0 == s1) {
                try self.spliceOneSlab(gpa, index, del, values, s0);
            } else {
                try self.spliceAcrossSlabs(gpa, index, del, values, s0, s1);
            }
            try self.rebuildAggs();
            self.total_len = self.total_len - del + values.len;
        }

        // ── The wire form ───────────────────────────────────────────────

        /// The column's wire form: every slab's bytes, coalesced across the
        /// slab boundaries so the result is one canonical run sequence
        /// whatever the layout was (`column.rs:1360-1376`).
        ///
        /// Coalescing is also what puts a boolean column's run parity
        /// back. A boolean run's value is its position in the sequence, and
        /// the sequence a concatenation makes is not the sequence each
        /// slab's own bytes describe: a slab that opens on `true` spends a
        /// run on the pad that lets it (`bool.rs:988-1002`), and its runs
        /// land at whatever index the slabs before it left off at. So the
        /// pad is dropped at a boundary, and the run count is kept, and
        /// the one run that coalescing removes is what shifts the runs
        /// behind it back onto the values this column holds — which is
        /// exactly what upstream's `do_merge` does, case for case
        /// (`bool.rs:845-925`).
        ///
        /// The caller owns the slice.
        pub fn encode(self: *const Self, gpa: std.mem.Allocator) ParseError![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            // The last run written, so the next slab can be coalesced with
            // it, and the run count, which is the index a boolean run's
            // value is read from.
            var last_value: ?E.Wire = null;
            var last_bytes: usize = 0;
            var last_items: usize = 0;
            var last_kind: slabmod.RunKind = .repeat;
            var runs: usize = 0;

            for (self.slabs.items) |s| {
                if (s.data.len == 0) continue;
                const segs = try E.segmentsOf(gpa, s.data);
                defer gpa.free(segs);
                if (segs.len == 0) continue;
                // A boundary is read from the first run that carries
                // items — except at the head of the column, where the
                // wire form opens on the pad itself, because a column
                // that starts on `true` is written as `[0, N]`
                // (`bool.rs:1657-1660`).
                const first = if (last_value == null) 0 else slabmod.firstItemRun(E, segs);
                const b_first = segs[first];
                // How many of this slab's runs come behind the seam.
                const after = segs.len - first - 1;
                // The boundary is canonical only when the two runs cannot
                // be one: different values, and — for the RLE codecs —
                // not both single-item literals, because a canonical run
                // sequence never has two adjacent literal runs at all
                // (`rle.zig` rules 4, 6, 8).
                const merge = last_value != null and slabmod.collide(
                    E,
                    last_value,
                    b_first.first_value,
                    last_kind,
                    b_first.kind,
                );
                var merged: []u8 = &.{};
                defer gpa.free(merged);
                var merged_segs: []slabmod.Segment(E.Wire) = &.{};
                defer gpa.free(merged_segs);
                if (merge) {
                    // The run at the end of what is written so far and the
                    // slab's first run become one.
                    var mid: std.ArrayList(E.Wire) = .empty;
                    defer mid.deinit(gpa);
                    {
                        const head = try E.wireRange(gpa, out.items[out.items.len - last_bytes ..], 0, last_items);
                        defer gpa.free(head);
                        try mid.appendSlice(gpa, head);
                    }
                    {
                        const tail = try E.wireRange(gpa, s.data, b_first.item_start, b_first.item_end);
                        defer gpa.free(tail);
                        try mid.appendSlice(gpa, tail);
                    }
                    // The merged run takes the place of the run already
                    // written, so it is read from that run's parity.
                    merged = try E.wireEncode(gpa, mid.items, ((runs - 1) % 2) == 1);
                    merged_segs = try E.segmentsOf(gpa, merged);
                    out.shrinkRetainingCapacity(out.items.len - last_bytes);
                    try out.appendSlice(gpa, merged);
                    try out.appendSlice(gpa, s.data[b_first.byte_end..]);
                } else {
                    // Past the pad, if this slab has one, and on.
                    try out.appendSlice(gpa, s.data[b_first.byte_start..]);
                }
                runs = (runs - @intFromBool(merge)) + merged_segs.len + after;

                if (after != 0 or !merge) {
                    // The slab's own last run is the one the wire form ends
                    // on: it was copied through, tail and all.
                    const last = segs[segs.len - 1];
                    last_value = try E.lastValueOfRun(s.data, last);
                    last_bytes = s.tail.bytes;
                    last_items = last.itemCount();
                    last_kind = last.kind;
                } else {
                    // Nothing of the slab stood behind the seam, so the run
                    // the wire form ends on is the one just written.
                    const last = merged_segs[merged_segs.len - 1];
                    const mid_tail = try slabmod.tailAt(E, merged.len, last, try E.litTail(merged, last));
                    last_value = try E.lastValueOfRun(merged, last);
                    last_bytes = mid_tail.bytes;
                    last_items = last.itemCount();
                    last_kind = last.kind;
                }
            }
            // The wire form is what a load validates, so it is checked here
            // rather than left to fail later: `load(encode())` has to be
            // total, and this is the one place that can prove it.
            try E.canonicalSlab(out.items);
            return out.toOwnedSlice(gpa);
        }

        /// A column over the wire form. The bytes are validated as a whole —
        /// a run sequence with the canonical rules — and then cut into slabs
        /// at half the run budget, so a later insert has room
        /// (`rle/load.rs:185-196`).
        pub fn load(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Self {
            try E.canonicalSlab(bytes);
            var self = try Self.init(gpa);
            errdefer self.deinit();

            const segs = try E.segmentsOf(gpa, bytes);
            defer gpa.free(segs);
            const target = @max(default_max_segments / 2, 1);
            var from: usize = 0;
            while (from < segs.len) {
                const to = @min(from + target, segs.len);
                const piece = try E.wireSlice(gpa, bytes, segs[from].byte_start, segs[to - 1].byte_end, segs[from].opens_with_true);
                errdefer gpa.free(piece);
                const m = try slabmod.measure(gpa, E, piece);
                try self.slabs.append(gpa, .{ .data = piece, .len = m.len, .segments = m.segments, .tail = m.tail });
                self.total_len = std.math.add(usize, self.total_len, m.len) catch return error.Overflow;
                from = to;
            }
            try self.reindex();
            try self.rebuildAggs();
            return self;
        }

        // ── Internals ───────────────────────────────────────────────────

        /// The slab holding item `item`, or the last one when `item` is at
        /// the end of the column: a splice at the end lands in the last slab
        /// rather than starting one of its own (`edit.rs:170-175`).
        fn slabHolding(self: *const Self, item: usize) usize {
            if (item >= self.total_len) return self.slabs.items.len - 1;
            const hit = self.tree.findByPrefix(item) orelse return self.slabs.items.len - 1;
            return hit.slab;
        }

        /// The merged weight of the slabs before `si` — a slab's base.
        fn aggWeight(self: *const Self, si: usize) Weight {
            if (comptime E.tracks_prefix) {
                if (si < self.agg_before.items.len) return self.agg_before.items[si];
            }
            return identity;
        }

        /// The running value in front of slab `si`.
        fn baseOf(self: *const Self, si: usize) i64 {
            if (!comptime E.tracks_prefix) return 0;
            return E.weightIncrement(self.aggWeight(si));
        }

        /// The first surviving row behind a splice whose difference has to be
        /// re-anchored, and the difference it has to carry.
        const Reanchor = struct {
            /// The column row whose difference changes.
            at: usize,
            /// How many absent rows stand between the cut and it. They hold
            /// no difference, so the row to fix is the first one past them,
            /// and a cut inside the same slab has to take them and put them
            /// back to reach it.
            skip: usize,
            /// The difference the row has to carry.
            wire: Wire,
        };

        /// The row to re-anchor after a splice that replaces
        /// `[index, index + del)` and leaves `after` as the running value in
        /// front of the rows behind the cut. Null when there is nothing to
        /// fix: no row behind the cut, no row among them that carries a
        /// difference, or a difference already the one it has to carry.
        ///
        /// A splice moves the running value in front of every row behind it
        /// even when it only deletes, because the differences it removed
        /// were part of that sum — which is what makes a pure deletion at a
        /// slab boundary need a re-anchor, and what upstream's
        /// `SpliceDeltaIter` carries a boundary row for whether it inserts
        /// or not (`delta/mod.rs:1066-1120`).
        fn reanchorAfter(
            self: *const Self,
            gpa: std.mem.Allocator,
            index: usize,
            del: usize,
            after: i64,
        ) ParseError!?Reanchor {
            if (!comptime E.tracks_prefix) return null;
            const from = index + del;
            if (from >= self.total_len) return null;
            var si = self.slabHolding(from);
            // The row the walk stands on, as an index inside slab `si`. The
            // runs of a slab tile its items with no gaps, so stepping to a
            // run's end never moves the row backwards.
            var row = from - self.tree.itemsBeforeSlab(si);
            var skip: usize = 0;
            while (si < self.slabs.items.len) {
                const s = &self.slabs.items[si];
                const segs = try E.segmentsOf(gpa, s.data);
                defer gpa.free(segs);
                var k = slabmod.runAt(E, segs, row);
                while (k < segs.len) : (k += 1) {
                    if (segs[k].kind == .absent) {
                        // Step to the far end of the absent run. A cut can
                        // land inside one, and only the rows *behind* the
                        // cut are skipped: the head of the run stood in
                        // front of it, and an absent row carries no
                        // difference, so it is anchored whatever ran before
                        // it.
                        skip += segs[k].item_end - row;
                        row = segs[k].item_end;
                        continue;
                    }
                    // The row's own difference, which is the head of its run
                    // only when the run starts there: a cut can land inside a
                    // run, and a run the walk reached by stepping over absent
                    // rows starts wherever it starts.
                    const at = self.tree.itemsBeforeSlab(si) + row;
                    const d = try E.wireRange(gpa, s.data, row, row + 1);
                    defer gpa.free(d);
                    const fix = (try E.reanchor(d[0], try self.runningAt(at), after)) orelse return null;
                    // `sameValue` on two values that both carry one is the
                    // test "are these the same", which is what says the row
                    // is already anchored.
                    if (E.sameValue(d[0], fix)) return null;
                    return .{ .at = at, .skip = skip, .wire = fix };
                }
                si += 1;
                row = 0;
            }
            return null;
        }

        /// Puts `wire` on the row at `at`, re-encoding the runs around it and
        /// settling the layout again. The row's own value did not move, but
        /// the value in front of it did.
        fn reanchorRow(self: *Self, gpa: std.mem.Allocator, at: usize, wire: E.Wire) ParseError!void {
            const si = self.slabHolding(at);
            const in_slab = at - self.tree.itemsBeforeSlab(si);
            try slabmod.splice(gpa, E, &self.slabs.items[si], in_slab, 1, &.{wire}, null);
            try self.settle(si, 1);
        }

        /// A splice that lands inside one slab: the slab-level rebuild, with
        /// the delta re-anchor as the postfix.
        fn spliceOneSlab(
            self: *Self,
            gpa: std.mem.Allocator,
            index: usize,
            del: usize,
            values: []const T,
            si: usize,
        ) ParseError!void {
            const s = &self.slabs.items[si];
            const in_slab = index - self.tree.itemsBeforeSlab(si);
            // Only a delta column measures its values against a running
            // value; the others store them as they are.
            const running = if (comptime E.tracks_prefix) try self.runningAt(index) else 0;
            const ins = try E.wireOfInsert(gpa, running, values);
            var insert: []E.Wire = ins.wires;
            defer gpa.free(insert);

            const fix = try self.reanchorAfter(gpa, index, del, ins.running);
            // A cut that reaches past the absent rows to the row to re-anchor
            // takes them and puts them back, so that row is the head of its
            // own run when the postfix lands on it.
            var del_now = del;
            var postfix: ?[]E.Wire = null;
            var one: [1]E.Wire = undefined;
            var in_this_slab = false;
            if (fix) |f| {
                if (f.at - self.tree.itemsBeforeSlab(si) < s.len) {
                    in_this_slab = true;
                    if (f.skip != 0) {
                        const absent = try E.wireRange(gpa, s.data, in_slab + del, in_slab + del + f.skip);
                        defer gpa.free(absent);
                        const both = try gpa.alloc(E.Wire, insert.len + absent.len);
                        @memcpy(both[0..insert.len], insert);
                        @memcpy(both[insert.len..], absent);
                        gpa.free(insert);
                        insert = both;
                        del_now = del + f.skip;
                    }
                    one[0] = f.wire;
                    postfix = one[0..];
                }
            }

            try slabmod.splice(gpa, E, &self.slabs.items[si], in_slab, del_now, insert, postfix);
            try self.settle(si, 1);
            if (fix) |f| {
                if (!in_this_slab) {
                    // The row to re-anchor stood past this slab, so the
                    // splice has already moved it: put its difference on
                    // it where it now stands.
                    try self.reanchorRow(gpa, f.at + values.len - del, f.wire);
                }
            }
        }

        /// A splice whose deleted range spans slabs: everything from the head
        /// of the first slab to the tail of the last is rebuilt, and the
        /// slabs in between are dropped without being decoded.
        fn spliceAcrossSlabs(
            self: *Self,
            gpa: std.mem.Allocator,
            index: usize,
            del: usize,
            values: []const T,
            s0: usize,
            s1: usize,
        ) ParseError!void {
            var pieces: std.ArrayList(Slab) = .empty;
            defer pieces.deinit(gpa);

            // The head of the first slab, the inserted values, the tail of
            // the last, in that order: the column order.
            const head = try E.wireRange(gpa, self.slabs.items[s0].data, 0, index - self.tree.itemsBeforeSlab(s0));
            defer gpa.free(head);
            if (head.len != 0) {
                try pieces.append(gpa, try slabOf(gpa, E, head));
            }

            const running = if (comptime E.tracks_prefix) try self.runningAt(index) else 0;
            const ins = try E.wireOfInsert(gpa, running, values);
            defer gpa.free(ins.wires);
            try self.appendBudgeted(gpa, &pieces, ins.wires);

            // The first row behind the cut: its own value did not move, but
            // the running value in front of it did, so its difference has
            // to be re-anchored — and an absent row carries none, so the row
            // to fix may be further into the tail than the cut.
            const fix = try self.reanchorAfter(gpa, index, del, ins.running);

            var anchored_in_tail = false;
            const tail_s = &self.slabs.items[s1];
            const tail_from = index + del - self.tree.itemsBeforeSlab(s1);
            if (tail_from < tail_s.len) {
                const tail = try E.wireRange(gpa, tail_s.data, tail_from, tail_s.len);
                defer gpa.free(tail);
                if (fix) |f| {
                    if (f.skip < tail.len) {
                        const anchored = try gpa.dupe(E.Wire, tail);
                        defer gpa.free(anchored);
                        anchored[f.skip] = f.wire;
                        try pieces.append(gpa, try slabOf(gpa, E, anchored));
                        anchored_in_tail = true;
                    }
                }
                if (!anchored_in_tail) try pieces.append(gpa, try slabOf(gpa, E, tail));
            }

            // Drop the slabs the cut spanned, then put the pieces in their
            // place. The old slabs are freed by hand because the list is
            // holding them, not copies of them.
            const placed = pieces.items.len;
            for (self.slabs.items[s0 .. s1 + 1]) |*old| old.deinit(gpa);
            try self.slabs.replaceRange(gpa, s0, s1 + 1 - s0, &.{});
            try self.slabs.insertSlice(gpa, s0, pieces.items);
            pieces.items.len = 0;
            // The rebuilt range is every piece, not the first one: a cut
            // that spans slabs puts a whole run of budgeted slabs where the
            // old range stood, and the merge policy is a property of the
            // range that was rebuilt, not of the slab that started it.
            try self.settle(s0, placed);
            if (fix) |f| {
                if (!anchored_in_tail) {
                    // The tail of the last slab was absent all the way, so
                    // the row to re-anchor stands in a later slab, which the
                    // splice has already moved: put its difference on it
                    // where it now stands.
                    try self.reanchorRow(gpa, f.at + values.len - del, f.wire);
                }
            }
        }

        /// Split `wires` into slabs at the run budget and append them.
        fn appendBudgeted(
            self: *Self,
            gpa: std.mem.Allocator,
            pieces: *std.ArrayList(Slab),
            wires: []const E.Wire,
        ) ParseError!void {
            _ = self;
            if (wires.len == 0) return;
            const bytes = try E.wireEncode(gpa, wires, false);
            defer gpa.free(bytes);
            const segs = try E.segmentsOf(gpa, bytes);
            defer gpa.free(segs);
            var from: usize = 0;
            while (from < segs.len) {
                const to = @min(from + max_segments, segs.len);
                try pieces.append(gpa, try cutPiece(gpa, E, bytes, segs, from, to));
                from = to;
            }
        }

        /// Cut the first rebuilt slab back to the budget, coalesce the
        /// neighbours of the whole rebuilt range, and bring the index and
        /// the weight array back into step.
        ///
        /// `count` is how many slabs the rebuild put in place of the old
        /// ones: one for a splice inside a slab, and one per piece for a
        /// cut that spanned slabs. The merge policy is a property of the
        /// range that was rebuilt, so the range has to be the whole of it
        /// and not the slab the rebuild started at. Upstream's edit cursor
        /// closes one slab at a time and so only ever holds one slab plus
        /// its spills (`Editor::close`, `edit.rs:565-592`); a cut that spans
        /// slabs is the one place the two designs differ, and the pieces it
        /// leaves behind are as much a rebuilt range as a spill is.
        fn settle(self: *Self, lo: usize, count: usize) ParseError!void {
            if (self.slabs.items.len == 0) {
                // A cut that spanned every slab and put nothing in its
                // place. An empty column still keeps one empty slab, the
                // one the next splice lands in (`column.rs:1298-1306`).
                try self.slabs.append(self.gpa, .empty);
                try self.reindex();
                return;
            }
            var spilled = try slabmod.splitToBudget(self.gpa, E, &self.slabs.items[lo], max_segments);
            errdefer {
                for (spilled.items) |*p| p.deinit(self.gpa);
                spilled.deinit(self.gpa);
            }
            const spill = spilled.items.len;
            if (spill != 0) {
                try self.slabs.insertSlice(self.gpa, lo + 1, spilled.items);
                spilled.items.len = 0;
            }
            spilled.deinit(self.gpa);

            const range = try self.tryMergeRange(lo, lo + count + spill);
            try self.reindexFrom(@min(lo, range.start));
        }

        /// Merge slab `b` into slab `a` when one of them is undersized and
        /// the pair fits the budget (`Column::try_merge`,
        /// `column.rs:1782-1797`).
        fn tryMerge(self: *Self, a: usize, b: usize) ParseError!bool {
            if (a >= self.slabs.items.len or b >= self.slabs.items.len) return false;
            const min_seg = @max(max_segments / 4, 1);
            const sa = self.slabs.items[a].segments;
            const sb = self.slabs.items[b].segments;
            if (!((sa < min_seg or sb < min_seg) and sa + sb <= max_segments)) return false;
            try slabmod.merge(self.gpa, E, &self.slabs.items[a], &self.slabs.items[b]);
            self.slabs.items[b].deinit(self.gpa);
            _ = self.slabs.orderedRemove(b);
            return true;
        }

        /// Walk the four slab boundaries around a rebuilt range and merge
        /// undersized neighbours. Only the edges of a rebuilt range can be
        /// short — the spills in the middle were cut at the budget — so the
        /// walk stays short however many slabs the splice touched
        /// (`try_merge_range_skeleton`, `column.rs:185-229`).
        fn tryMergeRange(self: *Self, lo: usize, hi: usize) ParseError!struct { start: usize, end: usize } {
            var start = lo;
            var end = hi;
            if (end > start) {
                if (end >= start + 3 and try self.tryMerge(end - 3, end - 2)) end -= 1;
                if (end >= start + 2 and try self.tryMerge(end - 2, end - 1)) end -= 1;
                // The last slab of the range against the first slab after
                // it. The pair straddles the boundary, so the merge removes
                // a slab *outside* the range and `end` stays put: this is
                // the outward walk to the right, and it has to go on after
                // the range has collapsed onto its first slab, or the
                // merged slab is left beside a short one that upstream folds
                // in as well. Every pass takes a slab out of the column, so
                // the walk ends (`try_merge_range_skeleton`,
                // `column.rs:215-216`).
                while (try self.tryMerge(end - 1, end)) {}
                if (end >= start + 2 and try self.tryMerge(start, start + 1)) end -= 1;
                while (start > 0 and try self.tryMerge(start - 1, start)) {
                    start -= 1;
                    end -= 1;
                }
            }
            return .{ .start = start, .end = end };
        }

        /// Replace the index's slabs `[start, end)` with the weights of the
        /// column's slabs `[start, slabCount())`.
        ///
        /// The index is only correct from the first slab a splice touched:
        /// everything before it kept both its bytes and its weight, and the
        /// merge policy only reaches outwards from the range.
        fn reindexFrom(self: *Self, start: usize) ParseError!void {
            if (start >= self.slabs.items.len) return;
            var weights: std.ArrayList(Weight) = .empty;
            defer weights.deinit(self.gpa);
            for (self.slabs.items[start..]) |*s| {
                try weights.append(self.gpa, try E.weightOf(self.gpa, s));
            }
            self.tree.splice(start, self.tree.len(), weights.items) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidIndex => return error.InvalidValue,
            };
        }

        /// Rebuild the whole index from the slabs. `load` uses it; a splice
        /// reconciles from the first slab it touched instead.
        fn reindex(self: *Self) ParseError!void {
            var weights: std.ArrayList(Weight) = .empty;
            defer weights.deinit(self.gpa);
            for (self.slabs.items) |*s| try weights.append(self.gpa, try E.weightOf(self.gpa, s));
            self.tree.deinit();
            self.tree = Tree.fromSlice(self.gpa, weights.items) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidIndex => return error.InvalidValue,
            };
        }

        /// Rebuild the per-slab weight prefixes. Only a codec whose weight
        /// carries a prefix keeps them.
        fn rebuildAggs(self: *Self) ParseError!void {
            if (!comptime E.tracks_prefix) {
                self.agg_before.clearRetainingCapacity();
                return;
            }
            self.agg_before.clearRetainingCapacity();
            var acc = identity;
            for (self.slabs.items) |*s| {
                try self.agg_before.append(self.gpa, acc);
                acc = Weight.Aggregate.merge(acc, try E.weightOf(self.gpa, s));
            }
            try self.agg_before.append(self.gpa, acc);
        }

        // ── The invariants ──────────────────────────────────────────────

        /// What a failed invariant check found. Mirrors the assertions of
        /// `Column::check_invariants` (`column.rs:1292-1345`), which a test
        /// turns into a report rather than a panic.
        pub const Violation = struct {
            what: []const u8,
            at: usize,
        };

        /// Whether two adjacent slabs are one the merge policy would have
        /// coalesced: one of them undersized and the pair inside the budget
        /// (`column.rs:1782-1797`).
        ///
        /// The policy is the splice path's, so a column that came from
        /// `load` may hold such a pair — a load cuts at half the budget and
        /// its last slab can be a run long.
        pub fn mergeableNeighbours(self: *const Self) ?Violation {
            const min_seg = @max(max_segments / 4, 1);
            for (self.slabs.items, 0..) |s, i| {
                if (i == 0) continue;
                const prev = self.slabs.items[i - 1].segments;
                if ((prev < min_seg or s.segments < min_seg) and prev + s.segments <= max_segments) {
                    return .{ .what = "adjacent slabs should have been merged", .at = i };
                }
            }
            return null;
        }

        /// Checks the structural invariants a save cannot catch, because a
        /// save re-encodes canonically and so hides the slab layout: no
        /// empty slab, no slab over the budget, every slab's cached
        /// metadata matching a fresh measure of its own bytes, and the
        /// index and the weight array agreeing with the slab list.
        ///
        /// `null` when the column is sound. The merge policy is a separate
        /// check — see `mergeableNeighbours`.
        pub fn checkInvariants(self: *const Self) ParseError!?Violation {
            if (self.total_len == 0 and self.slabs.items.len > 1) {
                return .{ .what = "an empty column keeps at most one slab", .at = self.slabs.items.len };
            }
            var total: usize = 0;
            for (self.slabs.items, 0..) |*s, i| {
                if (self.total_len != 0 and s.len == 0) return .{ .what = "empty slab", .at = i };
                if (!(s.segments <= max_segments or s.segments == 1)) {
                    return .{ .what = "slab over the run budget", .at = i };
                }
                const m = try slabmod.measure(self.gpa, E, s.data);
                if (m.len != s.len) return .{ .what = "slab length disagrees with its bytes", .at = i };
                if (m.segments != s.segments) return .{ .what = "slab run count disagrees with its bytes", .at = i };
                if (!slabmod.Tail.eql(m.tail, s.tail)) return .{ .what = "slab tail disagrees with its bytes", .at = i };
                total = std.math.add(usize, total, s.len) catch return error.Overflow;
            }
            if (total != self.total_len) return .{ .what = "column length is not the sum of its slabs", .at = 0 };
            if (self.tree.len() != self.slabs.items.len) return .{ .what = "index length is not the slab count", .at = 0 };
            var before: usize = 0;
            for (self.slabs.items, 0..) |s, i| {
                if (self.tree.itemsBeforeSlab(i) != before) return .{ .what = "index disagrees on items before a slab", .at = i };
                before = std.math.add(usize, before, s.len) catch return error.Overflow;
            }
            if (self.tree.findByPrefix(self.total_len) != null) {
                return .{ .what = "the index resolves a position past the end", .at = 0 };
            }
            const tree_bad = self.tree.checkInvariants() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidIndex => return .{ .what = "the slab index is out of range", .at = 0 },
            };
            if (tree_bad) |v| {
                return .{ .what = "the slab index is not sound", .at = v.node orelse 0 };
            }
            if (comptime E.tracks_prefix) {
                // One slot per slab plus the whole column's — or nothing at
                // all, for a column that has no slabs: a splice that
                // removed the last one leaves the array to be seeded again.
                if (self.agg_before.items.len != self.slabs.items.len + 1 and
                    !(self.slabs.items.len == 0 and self.agg_before.items.len == 0))
                {
                    return .{ .what = "weight prefix array is the wrong length", .at = 0 };
                }
                if (self.slabs.items.len == 0) return null;
                var acc = identity;
                for (self.slabs.items, 0..) |*s, i| {
                    if (!Weight.Aggregate.eql(self.agg_before.items[i], acc)) {
                        return .{ .what = "weight prefix disagrees with the slabs before it", .at = i };
                    }
                    acc = Weight.Aggregate.merge(acc, try E.weightOf(self.gpa, s));
                }
                if (!Weight.Aggregate.eql(self.agg_before.items[self.slabs.items.len], acc)) {
                    return .{ .what = "weight prefix disagrees with the whole column", .at = 0 };
                }
            }
            return null;
        }

        /// A forward cursor over the column's values, one at a time.
        pub const Iterator = struct {
            col: *const Self,
            slab_idx: usize,
            dec: E.WireDecoder,
            items_left: usize,
            /// The realized value in front of the current row. Only a delta
            /// column reads it, and it starts at the current slab's base.
            running: i64,

            /// The next value, or null at the end of the column.
            pub fn next(self: *Iterator) ParseError!?T {
                while (self.items_left != 0) {
                    if (try self.dec.next()) |w| {
                        self.items_left -= 1;
                        return try E.valueOfWire(w, &self.running);
                    }
                    self.slab_idx += 1;
                    if (self.slab_idx >= self.col.slabs.items.len) {
                        self.items_left = 0;
                        return null;
                    }
                    self.dec = try E.WireDecoder.init(self.col.slabs.items[self.slab_idx].data);
                    self.running = self.col.baseOf(self.slab_idx);
                }
                return null;
            }
        };
    };
}

/// A standalone slab over the runs `[from, to)` of `bytes`.
fn cutPiece(
    gpa: std.mem.Allocator,
    comptime E: type,
    bytes: []const u8,
    segs: []const slabmod.Segment(E.Wire),
    from: usize,
    to: usize,
) ParseError!Slab {
    const piece = try E.wireSlice(gpa, bytes, segs[from].byte_start, segs[to - 1].byte_end, segs[from].opens_with_true);
    errdefer gpa.free(piece);
    const m = try slabmod.measure(gpa, E, piece);
    return .{ .data = piece, .len = m.len, .segments = m.segments, .tail = m.tail };
}
// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A generated value at `i`: runs of three, then a spread, so a column of
/// them is neither one run nor all runs. An optional column is absent every
/// seventh row, which is what a nullable codec's null run is for.
fn genValue(comptime T: type, i: usize) T {
    if (T == bool) return (i / 3) % 2 == 1;
    if (@typeInfo(T) == .optional) {
        if (i % 7 == 3) return null;
        return genValue(payloadOf(T), i);
    }
    const v: i64 = if (i % 5 == 0) @intCast(i / 4) else @intCast(i % 4);
    return @intCast(v);
}

/// A value distinct from every other tag, so a run of one tag is a run and a
/// run boundary sits where the tag changes.
fn tagValue(comptime T: type, tag: usize) T {
    if (T == bool) return tag % 2 == 1;
    if (@typeInfo(T) == .optional) {
        if (tag == 11) return null;
        return tagValue(payloadOf(T), tag);
    }
    return @intCast(tag);
}

/// The column's structural invariants, with a report rather than a panic.
fn expectSound(comptime T: type, comptime E: type, col: *const Column(T, E)) !void {
    if (try col.checkInvariants()) |v| {
        std.debug.print("invariant broken: {s} {s} (slab {d} of {d})\n", .{ @typeName(E), v.what, v.at, col.slabCount() });
        return error.TestUnexpectedResult;
    }
    if (col.mergeableNeighbours()) |v| {
        std.debug.print("merge policy broken: {s} {s} (slab {d} of {d})\n", .{ @typeName(E), v.what, v.at, col.slabCount() });
        return error.TestUnexpectedResult;
    }
}

/// The column against a plain array, by index and in order, and its length.
fn expectModel(comptime T: type, comptime E: type, col: *const Column(T, E), model: []const T) !void {
    const gpa = testing.allocator;
    try testing.expectEqual(model.len, col.len());
    try testing.expectEqual(model.len == 0, col.isEmpty());
    for (model, 0..) |want, i| {
        const got = (try col.get(i)) orelse {
            std.debug.print("no value at {d}\n", .{i});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(want, got);
    }
    try testing.expect((try col.get(model.len)) == null);

    const all = try col.toSlice(gpa);
    defer gpa.free(all);
    try testing.expectEqualSlices(T, model, all);

    var it = try col.iterator();
    var i: usize = 0;
    while (try it.next()) |v| {
        if (i >= model.len) return error.TestUnexpectedResult;
        try testing.expectEqual(model[i], v);
        i += 1;
    }
    try testing.expectEqual(model.len, i);
}

/// The column's wire form, loaded back into a fresh column: the same values,
/// the same bytes again, and a sound layout on the other side.
fn expectRoundTrip(comptime T: type, comptime E: type, col: *const Column(T, E), model: []const T) !void {
    const gpa = testing.allocator;
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    var back = try Column(T, E).load(gpa, bytes);
    defer back.deinit();
    // A load cuts its slabs at half the budget, so its last slab can be a
    // run long: the merge policy is the splice path's, not the load's.
    if (try back.checkInvariants()) |v| {
        std.debug.print("reloaded column broken: {s} {s} (slab {d})\n", .{ @typeName(E), v.what, v.at });
        return error.TestUnexpectedResult;
    }
    try expectModel(T, E, &back, model);
    const again = try back.encode(gpa);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

/// A column of `runs` runs of `3` values each, the tags running 0, 1, 2, ….
fn buildRuns(comptime T: type, comptime E: type, runs: usize) !struct { col: Column(T, E), model: std.ArrayList(T) } {
    const gpa = testing.allocator;
    var col = try Column(T, E).init(gpa);
    errdefer col.deinit();
    var model: std.ArrayList(T) = .empty;
    errdefer model.deinit(gpa);
    for (0..runs) |r| {
        for (0..3) |_| {
            const v = tagValue(T, r);
            try col.append(gpa, v);
            try model.append(gpa, v);
        }
    }
    return .{ .col = col, .model = model };
}

/// Applies one splice to the column and the model, then holds both to the
/// value list, the layout and the wire form.
fn step(
    comptime T: type,
    comptime E: type,
    col: *Column(T, E),
    model: *std.ArrayList(T),
    index: usize,
    del: usize,
    values: []const T,
) !void {
    const gpa = testing.allocator;
    try col.splice(gpa, index, del, values);
    try model.replaceRange(gpa, index, del, values);
    try expectSound(T, E, col);
    try expectModel(T, E, col, model.items);
    try expectRoundTrip(T, E, col, model.items);
}

/// Appends `n` generated values, reads them back, and round trips them.
fn exerciseAppend(comptime T: type, comptime E: type, n: usize) !void {
    const gpa = testing.allocator;
    var col = try Column(T, E).init(gpa);
    defer col.deinit();
    var model: std.ArrayList(T) = .empty;
    defer model.deinit(gpa);

    for (0..n) |i| {
        const v = genValue(T, i);
        try col.append(gpa, v);
        try model.append(gpa, v);
    }
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, model.items);
    try expectRoundTrip(T, E, &col, model.items);

    // `extend` is a splice at the end, so it must behave like one.
    var more: std.ArrayList(T) = .empty;
    defer more.deinit(gpa);
    for (0..17) |i| try more.append(gpa, genValue(T, n + i));
    try col.extend(gpa, more.items);
    try model.appendSlice(gpa, more.items);
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, model.items);
    try expectRoundTrip(T, E, &col, model.items);

    // `set` replaces one row.
    const v = tagValue(T, 5);
    try col.set(gpa, 0, v);
    model.items[0] = v;
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, model.items);
    try expectRoundTrip(T, E, &col, model.items);
}

/// Every splice boundary, on a small column whose runs are known.
fn exerciseBoundaries(comptime T: type, comptime E: type) !void {
    const gpa = testing.allocator;
    const three = [_]T{ tagValue(T, 0), tagValue(T, 1), tagValue(T, 2) };

    // Into an empty column, which starts with no slabs at all.
    {
        var col = try Column(T, E).init(gpa);
        defer col.deinit();
        try expectSound(T, E, &col);
        try expectModel(T, E, &col, &.{});
        try expectRoundTrip(T, E, &col, &.{});
        var model: std.ArrayList(T) = .empty;
        defer model.deinit(gpa);
        try step(T, E, &col, &model, 0, 0, &three);
    }
    // At the start of a column, at its end, and in its middle.
    for ([_]struct { index: usize, del: usize }{
        .{ .index = 0, .del = 0 },
        .{ .index = 0, .del = 1 },
        .{ .index = 0, .del = 9 },
        .{ .index = 3, .del = 0 }, // a run boundary
        .{ .index = 4, .del = 0 }, // inside a run
        .{ .index = 3, .del = 3 }, // exactly one run
        .{ .index = 4, .del = 2 }, // across a run boundary
        .{ .index = 8, .del = 1 }, // the last row
        .{ .index = 9, .del = 0 }, // the very end
    }) |at| {
        const built = try buildRuns(T, E, 3);
        var col = built.col;
        defer col.deinit();
        var model = built.model;
        defer model.deinit(gpa);
        try expectSound(T, E, &col);
        try step(T, E, &col, &model, at.index, at.del, &three);
    }
    // Removing everything, from a column and from a one-value column.
    {
        const built = try buildRuns(T, E, 4);
        var col = built.col;
        defer col.deinit();
        var model = built.model;
        defer model.deinit(gpa);
        try step(T, E, &col, &model, 0, model.items.len, &.{});
        try testing.expectEqual(@as(usize, 0), col.len());
        try testing.expect(col.isEmpty());
        // And a column that is empty again still takes an insert.
        try step(T, E, &col, &model, 0, 0, &three);
    }
    {
        var col = try Column(T, E).init(gpa);
        defer col.deinit();
        var model: std.ArrayList(T) = .empty;
        defer model.deinit(gpa);
        const one = [_]T{tagValue(T, 0)};
        try step(T, E, &col, &model, 0, 0, &one);
        try step(T, E, &col, &model, 0, 1, &.{});
    }
    // A splice that repeats the value the run before it ends on, which is
    // the seam the rebuild has to close.
    {
        const built = try buildRuns(T, E, 3);
        var col = built.col;
        defer col.deinit();
        var model = built.model;
        defer model.deinit(gpa);
        const repeat = [_]T{tagValue(T, 0)};
        try step(T, E, &col, &model, 3, 0, &repeat);
        const repeat_end = [_]T{tagValue(T, 2)};
        try step(T, E, &col, &model, col.len(), 0, &repeat_end);
    }
}

/// A column long enough to span several slabs, spliced in the middle of it
/// often enough that the index, the merge policy and the budget all have to
/// hold at once.
fn exerciseManySlabs(comptime T: type, comptime E: type) !void {
    const gpa = testing.allocator;
    const built = try buildRuns(T, E, 400); // 1200 rows, far more runs than one slab holds
    var col = built.col;
    defer col.deinit();
    var model = built.model;
    defer model.deinit(gpa);

    try testing.expect(col.slabCount() > 1);
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, model.items);
    try expectRoundTrip(T, E, &col, model.items);

    const inserts = [_][]const T{
        &.{tagValue(T, 9)},
        &.{ tagValue(T, 1), tagValue(T, 1) },
        &.{},
        &.{ tagValue(T, 7), tagValue(T, 8), tagValue(T, 9) },
        &.{tagValue(T, 0)},
    };
    for (0..40) |round| {
        const at = (round * 137 + 5) % model.items.len;
        const ins = inserts[round % inserts.len];
        const del = round % 3;
        try step(T, E, &col, &model, at, del, ins);
        try testing.expect(col.slabCount() >= 1);
    }
    // A bulk insert, big enough to overflow the budget several times over.
    var bulk: std.ArrayList(T) = .empty;
    defer bulk.deinit(gpa);
    for (0..500) |i| try bulk.append(gpa, tagValue(T, i % 3));
    try step(T, E, &col, &model, 100, 50, bulk.items);
    // And a bulk delete of the same size.
    try step(T, E, &col, &model, 100, 400, &.{});
    try expectSound(T, E, &col);
}

/// A deterministic walk of random splices against a plain array. The
/// strongest check there is: every mutation is compared to the model, the
/// layout is checked after each one, and the wire form is round tripped at
/// the end.
fn exerciseRandomSplices(comptime T: type, comptime E: type, seed: u64) !void {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();

    var col = try Column(T, E).init(gpa);
    defer col.deinit();
    var model: std.ArrayList(T) = .empty;
    defer model.deinit(gpa);
    for (0..180) |i| {
        const v = genValue(T, i);
        try col.append(gpa, v);
        try model.append(gpa, v);
    }
    try expectSound(T, E, &col);

    var scratch: std.ArrayList(T) = .empty;
    defer scratch.deinit(gpa);
    for (0..300) |_| {
        scratch.clearRetainingCapacity();
        const index = if (model.items.len == 0) 0 else rand.intRangeAtMost(usize, 0, model.items.len);
        const del = rand.intRangeAtMost(usize, 0, @min(model.items.len - index, 24));
        for (0..rand.intRangeAtMost(usize, 0, 10)) |_| {
            try scratch.append(gpa, genValue(T, rand.intRangeAtMost(usize, 0, 96)));
        }
        try col.splice(gpa, index, del, scratch.items);
        try model.replaceRange(gpa, index, del, scratch.items);
        try expectSound(T, E, &col);
    }
    try expectModel(T, E, &col, model.items);
    try expectRoundTrip(T, E, &col, model.items);
}

/// Out of bounds is a refusal, not a trap.
fn exerciseBounds(comptime T: type, comptime E: type) !void {
    const gpa = testing.allocator;
    var col = try Column(T, E).init(gpa);
    defer col.deinit();
    const v = tagValue(T, 0);
    try col.append(gpa, v);
    try testing.expectError(error.InvalidValue, col.splice(gpa, 2, 0, &.{}));
    try testing.expectError(error.InvalidValue, col.splice(gpa, 0, 2, &.{}));
    try testing.expectError(error.InvalidValue, col.set(gpa, 1, v));
    try testing.expectError(error.InvalidValue, col.removeN(gpa, 1, 1));
    try testing.expectEqual(@as(usize, 1), col.len());
}

/// A prefix column answers the sum question, and a delta column's running
/// value is its own column: the two weights the index carries are the point
/// of the seam.
fn exercisePrefixSums(comptime T: type, comptime E: type, comptime sums_values: bool) !void {
    if (!comptime E.tracks_prefix) return;
    const gpa = testing.allocator;
    var col = try Column(T, E).init(gpa);
    defer col.deinit();
    var model: std.ArrayList(T) = .empty;
    defer model.deinit(gpa);

    for (0..200) |i| {
        const v = genValue(T, i);
        try col.append(gpa, v);
        try model.append(gpa, v);
    }
    try expectSound(T, E, &col);
    // What `runningAt` answers depends on the codec, and so does the model.
    // A prefix column's running value is the sum of the row lengths before
    // the row (`prefix.rs:541-566`); a delta column's is the running
    // *value* — the last realized value in front of it, because its
    // differences are measured from that (`delta/mod.rs:1160-1200`). The
    // two agree only where the values happen to accumulate.
    var running: i64 = 0;
    for (model.items, 0..) |want, i| {
        try testing.expectEqual(running, try col.runningAt(i));
        // The step from one row's running value to the next: a prefix
        // column adds the row's own length, while a delta column's running
        // value is the value the row realizes — and an absent row realizes
        // nothing, so it holds the running value where it is.
        var value: ?i64 = null;
        if (comptime @typeInfo(T) == .optional) {
            if (want) |pv| value = @intCast(pv);
        } else {
            value = @intCast(want);
        }
        if (comptime sums_values) {
            running = try addChecked(running, value orelse 0);
        } else if (value) |v| {
            running = v;
        }
    }
    try testing.expectEqual(running, try col.runningAt(model.items.len));
}

//  Every codec the op set instantiates, through every case above.
test "every codec appends, reads back, splices at every boundary and round trips" {
    try exerciseAppend(u64, Rle(u64), 300);
    try exerciseAppend(i64, Rle(i64), 300);
    try exerciseAppend(u32, Rle(u32), 300);
    try exerciseAppend(?u64, RleOption(u64), 300);
    try exerciseAppend(?u32, RleOption(u32), 300);
    try exerciseAppend(?i64, RleOption(i64), 300);
    try exerciseAppend(bool, Bool, 300);
    try exerciseAppend(u32, Delta(u32), 300);
    try exerciseAppend(u64, Delta(u64), 300);
    try exerciseAppend(i32, Delta(i32), 300);
    try exerciseAppend(i64, Delta(i64), 300);
    try exerciseAppend(?u32, DeltaOption, 300);
    try exerciseAppend(u32, Prefix(u32), 300);
    try exerciseAppend(u64, Prefix(u64), 300);
    try exerciseAppend(?u32, Prefix(?u32), 300);
    try exerciseAppend(?u64, Prefix(?u64), 300);
}

test "every codec splices at the start, the middle, the end, and around nothing" {
    try exerciseBoundaries(u64, Rle(u64));
    try exerciseBoundaries(i64, Rle(i64));
    try exerciseBoundaries(?u32, RleOption(u32));
    try exerciseBoundaries(?i64, RleOption(i64));
    try exerciseBoundaries(bool, Bool);
    try exerciseBoundaries(u32, Delta(u32));
    try exerciseBoundaries(i64, Delta(i64));
    try exerciseBoundaries(?u32, DeltaOption);
    try exerciseBoundaries(u32, Prefix(u32));
    try exerciseBoundaries(?u64, Prefix(?u64));
}

test "a column of many slabs keeps its index, its budget and its values" {
    try exerciseManySlabs(u64, Rle(u64));
    try exerciseManySlabs(?u32, RleOption(u32));
    try exerciseManySlabs(bool, Bool);
    try exerciseManySlabs(u32, Delta(u32));
    try exerciseManySlabs(?u32, DeltaOption);
    try exerciseManySlabs(u64, Prefix(u64));
    try exerciseManySlabs(?u32, Prefix(?u32));
}

/// A cut that spans every slab of a many-slab column. The rebuild takes
/// the whole slab list with it and puts one piece, or none, in its place:
/// the column has to land back on the single empty slab it keeps for the
/// next splice, and take an insert after it.
fn exerciseSpanWholeColumn(comptime T: type, comptime E: type) !void {
    const gpa = testing.allocator;
    const three = [_]T{ tagValue(T, 0), tagValue(T, 1), tagValue(T, 2) };
    {
        const built = try buildRuns(T, E, 400);
        var col = built.col;
        defer col.deinit();
        var model = built.model;
        defer model.deinit(gpa);
        try testing.expect(col.slabCount() > 1);

        try step(T, E, &col, &model, 0, model.items.len, &three);
        try testing.expectEqual(model.items.len, col.len());

        try step(T, E, &col, &model, 0, model.items.len, &.{});
        try testing.expectEqual(@as(usize, 0), col.len());
        try testing.expectEqual(@as(usize, 1), col.slabCount());

        try step(T, E, &col, &model, 0, 0, &three);
    }
}

test "a splice that spans every slab leaves a column that still takes an insert" {
    try exerciseSpanWholeColumn(u64, Rle(u64));
    try exerciseSpanWholeColumn(i64, Rle(i64));
    try exerciseSpanWholeColumn(?u32, RleOption(u32));
    try exerciseSpanWholeColumn(bool, Bool);
    try exerciseSpanWholeColumn(u32, Delta(u32));
    try exerciseSpanWholeColumn(i64, Delta(i64));
    try exerciseSpanWholeColumn(?u32, DeltaOption);
    try exerciseSpanWholeColumn(u32, Prefix(u32));
    try exerciseSpanWholeColumn(?u32, Prefix(?u32));
}

/// A cut whose end lands inside an absent run. Every row behind the cut
/// inside that run is absent as well, so the row to re-anchor is the first
/// one past it: the walk has to step to the run's end and no further.
fn exerciseCutInsideAbsentRun(comptime E: type) !void {
    const gpa = testing.allocator;
    const vals = [_]?u32{ 1, 1, 2, 2, 3, 3, 3, 3, null, null, 4 };
    // The cut's end on the first of the two absent rows leaves one absent
    // row behind it, and on the second it leaves none. Both land inside the
    // same run, and the row to re-anchor is the value behind it either way.
    for ([_]usize{ 7, 8 }) |index| {
        var col = try Column(?u32, E).init(gpa);
        defer col.deinit();
        var model: std.ArrayList(?u32) = .empty;
        defer model.deinit(gpa);
        try col.extend(gpa, &vals);
        try model.appendSlice(gpa, &vals);
        try expectSound(?u32, E, &col);
        try step(?u32, E, &col, &model, index, 1, &.{});
    }
}

test "a cut inside an absent run re-anchors the first row behind it" {
    try exerciseCutInsideAbsentRun(DeltaOption);
    try exerciseCutInsideAbsentRun(Prefix(?u32));
}

test "a seed sweep holds the merge policy over many slab layouts" {
    var seed: u64 = 0x9E3779B97F4A7C15;
    for (0..6) |_| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        try exerciseRandomSplices(u64, Rle(u64), seed);
        try exerciseRandomSplices(?u32, RleOption(u32), seed ^ 0x5A5A);
        try exerciseRandomSplices(bool, Bool, seed ^ 0x1234);
        try exerciseRandomSplices(u32, Delta(u32), seed ^ 0xBEEF);
        try exerciseRandomSplices(?u32, DeltaOption, seed ^ 0xC0FFEE);
        try exerciseRandomSplices(u32, Prefix(u32), seed ^ 0x31337);
    }
}

test "random splices agree with a plain array" {
    try exerciseRandomSplices(u64, Rle(u64), 0x51CE);
    try exerciseRandomSplices(i64, Rle(i64), 0xBEEF);
    try exerciseRandomSplices(?u32, RleOption(u32), 0xC0FFEE);
    try exerciseRandomSplices(bool, Bool, 0xDEAD);
    try exerciseRandomSplices(u32, Delta(u32), 0x1234);
    try exerciseRandomSplices(i64, Delta(i64), 0x9ABC);
    try exerciseRandomSplices(?u32, DeltaOption, 0x77);
    try exerciseRandomSplices(u32, Prefix(u32), 0x31337);
    try exerciseRandomSplices(?u64, Prefix(?u64), 0x5150);
}

test "an out of bounds splice is a refusal, not a trap" {
    try exerciseBounds(u64, Rle(u64));
    try exerciseBounds(u32, Delta(u32));
    try exerciseBounds(?u32, DeltaOption);
    try exerciseBounds(bool, Bool);
}

test "a prefix column answers the sum question and a delta column realizes it" {
    try exercisePrefixSums(u32, Prefix(u32), true);
    try exercisePrefixSums(?u32, Prefix(?u32), true);
    try exercisePrefixSums(u32, Delta(u32), false);
    try exercisePrefixSums(?u32, DeltaOption, false);
}

//  The wire form is the document format, so the bytes are pinned: the same
//  values must always produce the same encoding, whatever order the slabs
//  were built in.
test "the wire form is the canonical one the load accepts" {
    const gpa = testing.allocator;
    {
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ 1, 1, 1, 2, 3, 3, 3, 3, 4 });
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        // A repeat run of three, a literal of one, a repeat run of four, a
        // literal of one: signed(3) 1, signed(-1) 2, signed(4) 3, signed(-1)
        // 4. The 2 is a run of its own — it cannot join the literal run the
        // threes open, and it cannot be part of a repeat run of its own,
        // because a run of one value is a literal (`rle/decoder.rs:438-497`
        // rules 4 and 6, and `validate_after`'s "boundary values match
        // (should be merged)").
        try testing.expectEqualSlices(u8, &.{ 0x03, 0x01, 0x7F, 0x02, 0x04, 0x03, 0x7F, 0x04 }, bytes);
    }
    {
        var col = try Column(bool, Bool).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ true, true, false, true });
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        // A slab that opens on `true` pads: zero falses, two trues, one
        // false, one true.
        try testing.expectEqualSlices(u8, &.{ 0, 2, 1, 1 }, bytes);
    }
    {
        var col = try Column(u32, Delta(u32)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ 10, 13, 13, 14 });
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        // One literal run of four — the differences 10, 3, 0 and 1 are four
        // distinct values, so they are four items of one literal run:
        // signed(-4) then 10, 3, 0, 1.
        try testing.expectEqualSlices(u8, &.{ 0x7C, 0x0a, 0x03, 0x00, 0x01 }, bytes);
    }
}

//  The load refuses a non-canonical stream: a run sequence with two adjacent
//  runs carrying the same value is what the loader is there to reject.
test "the load refuses a non-canonical run sequence" {
    const gpa = testing.allocator;
    // signed(2) 1, signed(2) 1 — two repeat runs of the same value.
    try testing.expectError(error.InvalidValue, Column(u64, Rle(u64)).load(gpa, &.{ 0x02, 0x01, 0x02, 0x01 }));
    // A one-element repeat run is never canonical.
    try testing.expectError(error.InvalidValue, Column(u64, Rle(u64)).load(gpa, &.{ 0x01, 0x01 }));
    // A null run in a non-nullable column.
    try testing.expectError(error.UnexpectedNull, Column(u64, Rle(u64)).load(gpa, &.{ 0x00, 0x02 }));
    // An interior zero count in a boolean slab.
    try testing.expectError(error.InvalidValue, Column(bool, Bool).load(gpa, &.{ 1, 0, 1 }));
    // Truncated bytes.
    try testing.expectError(error.UnexpectedEnd, Column(u64, Rle(u64)).load(gpa, &.{0x80}));
}

//  An empty column holds at most one slab, and a column built by appends has
//  no slab over the budget.
test "the slab layout holds the budget the column claims" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 0), col.slabCount());
    try col.append(gpa, 1);
    try testing.expectEqual(@as(usize, 1), col.slabCount());

    var many: std.ArrayList(u64) = .empty;
    defer many.deinit(gpa);
    // 2500 repeat runs of two, not 5000 runs: adjacent *distinct* values
    // join one literal run, which is a single run however long it is
    // (`appendRuns`, `rle/decoder.rs:438-497` rule 4), so only a repeated
    // value makes a run of its own.
    for (0..5000) |i| try many.append(gpa, i / 2);
    try col.extend(gpa, many.items);
    try expectSound(u64, Rle(u64), &col);
    try testing.expect(col.slabCount() > 1);

    const segs = try col.slabSegments(gpa);
    defer gpa.free(segs);
    for (segs) |n| try testing.expect(n <= default_max_segments or n == 1);
}
