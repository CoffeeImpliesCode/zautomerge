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

    /// The aggregate contract [`btree.Tree`](btree.zig) and
    /// [`index.Fenwick`](index.zig) consume: four names, resolved at
    /// comptime, so one weight serves both index backends. A column picks
    /// its weight here, and the index follows.
    pub const Aggregate = struct {
        /// The weight of no slabs at all.
        pub const identity: LenWeight = .zero;
        /// The weight of two adjacent spans, in order.
        pub fn merge(l: LenWeight, r: LenWeight) LenWeight {
            return .{ .len = l.len + r.len };
        }
        /// How many column rows the weight covers. The only component a
        /// Fenwick prefix query reads.
        pub fn itemCount(w: LenWeight) usize {
            return w.len;
        }
        /// Whether two weights describe the same span.
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

    /// The aggregate contract [`btree.Tree`](btree.zig) and
    /// [`index.Fenwick`](index.zig) consume. Same four names as
    /// [`LenWeight.Aggregate`](LenWeight); the prefix sum travels beside
    /// the item count so a delta or prefix column can seek by either.
    pub const Aggregate = struct {
        /// The weight of no slabs at all.
        pub const identity: PrefixWeight = .zero;
        /// The weight of two adjacent spans, in order.
        pub fn merge(l: PrefixWeight, r: PrefixWeight) PrefixWeight {
            return .{ .len = l.len + r.len, .prefix = l.prefix + r.prefix };
        }
        /// How many column rows the weight covers. The only component a
        /// Fenwick prefix query reads.
        pub fn itemCount(w: PrefixWeight) usize {
            return w.len;
        }
        /// Whether two weights describe the same span.
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

/// One run of a column: `count` copies of `value` (`Run`, `lib.rs:196-201`).
///
/// A repeat, absent or boolean run yields its whole count. A *literal*
/// run — a run whose values are all distinct — yields `count == 1` per
/// value, because that is what the upstream decoder's `next_run` does
/// and what every caller here is written against: a run shapes what a
/// splice reads, and the ones worth splicing in bulk are the long ones
/// (`column.rs:551-556`). `Column(T, E).Run` is this type at `T`.
pub fn RunOf(comptime V: type) type {
    return struct {
        /// How many rows the run holds.
        count: usize,
        /// The value they carry. For a nullable column a null run
        /// carries `null` with its full count.
        value: V,
    };
}

/// A half-open range of column rows: `start` up to but not including
/// `end`. Upstream spells it `Range<usize>` and hands it to
/// `iter_range`, `shift` and `scope_to_value`
/// (`column.rs:1384`, `:1384-1421`, `:1495-1506`); there is no
/// `std.Range` in Zig 0.16, so it is a named struct here.
pub const RowRange = struct {
    /// The first row.
    start: usize,
    /// One past the last row.
    end: usize,
};

/// `range` clamped to `[0, len]`, with an end behind the start pulled
/// up to it. Upstream's `iter_range` clamps each end and then takes the
/// max (`column.rs:1385-1386`), and `normalize_range_max` is the same
/// rule for the `RangeBounds` callers (`column.rs:235-256`).
pub fn clampRange(range: RowRange, len: usize) RowRange {
    const start = @min(range.start, len);
    return .{ .start = start, .end = @max(@min(range.end, len), start) };
}

/// The length one row contributes to a prefix column's running sum: the
/// value itself, or nothing at all for a row with no length. A null row
/// is the prefix identity, which is what keeps the transform reversible
/// (`prefix.rs:287-312`).
fn prefixUnit(comptime T: type, v: T) i64 {
    // A boolean prefix column counts its `true` rows: a `true` is one unit
    // long and a `false` is none, which is `val as usize` upstream
    // (`prefix.rs:319-320`) and the codec's own `accumulate` spells the same
    // rule — `opset/columns.zig:193-197` for the op set's `insert` and
    // `index.top`. Without this arm `@intCast` refuses a `bool` at compile
    // time, so `PrefixIter`, `get_index_for_total` and `find_prefix_in_slab`
    // are all unreachable over a `Column(bool, …)`. The arm is the same
    // `@intFromBool` the codec uses, so the row's unit and the slab weight
    // are the same number.
    if (comptime T == bool) return @intFromBool(v);
    if (comptime @typeInfo(T) == .pointer) {
        @compileError("a prefix column's rows are integers or booleans: a byte payload has no length of its own");
    }
    if (comptime @typeInfo(T) == .optional) {
        const inner = v orelse return 0;
        return @as(i64, @intCast(inner));
    }
    return @as(i64, @intCast(v));
}

/// Whether `T` is a byte payload — a `[]const u8` or an optional of one.
/// Only the RLE-shaped codecs take one, and only they call this.
fn isBytes(comptime T: type) bool {
    const payload = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    return switch (@typeInfo(payload)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

/// The value an absent run yields, and the refusal a format with no absent
/// value gives (`WireRle.nullWire`, `column.zig`'s own spelling of the
/// rule). Named rather than written inline because the type of the absent
/// wire value is the codec's, and a non-nullable column's is not `null` at
/// all — so the call is only well formed when the format has one.
fn absentValueOf(comptime E: type, running: *i64) ParseError!E.Value {
    if (comptime @typeInfo(E.Wire) != .optional) return error.UnexpectedNull;
    return E.valueOfWire(null, running);
}

/// `a` against `b`. A null sorts before every value, which is the order
/// the op set's actor columns are in and is what makes a run of one
/// actor a contiguous range of rows.
fn compareValue(comptime T: type, a: T, b: T) std.math.Order {
    if (comptime T == bool) return if (a == b) .eq else if (a) .gt else .lt;
    if (comptime isBytes(T)) {
        // A byte payload has no numeric order, but `seek_to_value` and the
        // sorted scan need one to walk with: bytes compare
        // lexicographically, which is a total order and therefore as good
        // as any for "is the target in this run".
        const ai: []const u8 = if (comptime @typeInfo(T) == .optional) (a orelse return .lt) else a;
        const bi: []const u8 = if (comptime @typeInfo(T) == .optional) (b orelse return .gt) else b;
        return std.mem.order(u8, ai, bi);
    }
    if (comptime @typeInfo(T) == .optional) {
        // A null sorts before every value, which is what makes a run of
        // nulls a run like any other and an absent actor a prefix of the
        // column rather than a hole in it.
        if (a == null) return if (b == null) .eq else .lt;
        if (b == null) return .gt;
        if (a.? < b.?) return .lt;
        if (a.? > b.?) return .gt;
        return .eq;
    }
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

/// The first row in `slab` at which the running sum reaches `target`,
/// counted from the slab's own start — `find_prefix_in_slab`
/// (`prefix.rs:111-150`).
///
/// A run whose contribution lands the sum on or past `target` is divided
/// into by ceiling, so a run of a million equal lengths costs one step
/// and not a million. A run with no length contributes nothing and is
/// stepped over: there is nothing to divide by, and upstream's callers
/// are gated on the sum never decreasing (`prefix.rs:113-115`).
///
/// **A literal run is walked one item at a time, because its items each
/// carry their own length.** Upstream's decoder hands a literal group back
/// as a run of *one* item per value (`rle/decoder.rs:516-522`), so the
/// ceiling division there always divides by a single item's length. This
/// port's `RunAt` is a whole *segment*, and the one thing a segment does not
/// say is what its items are: `first_value` is the first of them
/// (`slab.zig:250-255`). Reading a literal as `count` copies of that first
/// value adds up a sum the column does not have, and the descent then
/// answers a row past the one holding `target` — which is how a two-unit text
/// element came back as the element behind it.
fn findPrefixInSlab(comptime E: type, slab: *const Slab, target: i64) ParseError!usize {
    var items: usize = 0;
    var acc: i64 = 0;
    while (try E.runAtOrAfter(slab.data, items)) |ra| {
        const n = ra.seg.itemCount();
        if (ra.seg.kind == .literal) {
            // One item is one run upstream, so one item is one division: the
            // loop below stops on the first item whose own width carries the
            // sum to `target`, and for that item `remaining <= each`, so
            // `divCeil(remaining, each)` is 1 — the landing is that item.
            // An item of no width cannot be the landing, and is stepped over.
            for (0..n) |k| {
                const each = prefixUnit(E.Wire, try E.literalValueAt(slab.data, ra.seg, k));
                const peek = std.math.add(i64, acc, each) catch return error.Overflow;
                if (peek >= target) return items + k + 1;
                acc = peek;
            }
            items = ra.seg.item_end;
            continue;
        }
        const p = if (ra.seg.first_value) |v| prefixUnit(E.Wire, v) else 0;
        if (p == 0) {
            items = ra.seg.item_end;
            continue;
        }
        const span = std.math.mul(i64, p, @as(i64, @intCast(n))) catch return error.Overflow;
        const peek = std.math.add(i64, acc, span) catch return error.Overflow;
        if (peek >= target) {
            const remaining = std.math.sub(i64, target, acc) catch return error.Overflow;
            // The ceiling division `find_prefix_in_slab` uses to land
            // inside the run (`prefix.rs:138-143`).
            const needed = std.math.divCeil(i64, remaining, p) catch return error.Overflow;
            if (needed < 1 or needed > @as(i64, @intCast(n))) return error.InvalidValue;
            return items + @as(usize, @intCast(needed));
        }
        acc = peek;
        items = ra.seg.item_end;
    }
    return items;
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
            fillWire(E.Wire, out[at..][0..n], v);
            at += n;
        } else if (n != 0) {
            return error.InvalidValue;
        }
    }
    if (at != out.len) return error.InvalidValue;
    return out;
}

/// `out` filled with `v`.
///
/// A byte payload's wire value is a slice, so the element is a slice
/// header and `@memset` is not the tool; the loop is spelled out so the
/// element's shape never decides whether this compiles. A slice wire value
/// is borrowed, so every entry borrows the same bytes `v` does — which is
/// why a caller may not keep the result past the storage it read.
fn fillWire(comptime Wire: type, out: []Wire, v: Wire) void {
    for (out) |*slot| slot.* = v;
}

// ── The RLE-shaped wire layer ─────────────────────────────────────────────

/// The wire layer every RLE-shaped codec shares: the run format, the
/// segment walk, the tail, and the checks the splice machinery makes.
///
/// `Payload` is what one value packs as — an integer, or a length-prefixed
/// byte string (`lib.rs:566-595` and `:696-770`) — and `Nullable` says
/// whether a null run is part of the format, which is the whole difference
/// between `Rle` and `RleOption` and the reason a nullable column's wire
/// element is `?Payload`.
///
/// `Utf8` is the byte payload's validation: a byte column reads whatever
/// bytes it holds, and a text column reads the same bytes and refuses any
/// that are not UTF-8 (`lib.rs:700-709`, whose `try_unpack` returns
/// `PackError::InvalidUtf8`). It changes nothing about the *encoding* —
/// the length prefix is the same — so a text column's bytes are a byte
/// column's bytes.
fn WireRle(comptime Payload: type, comptime Nullable: bool, comptime Utf8: bool) type {
    return struct {
        const Self = @This();

        /// What one slab entry decodes to.
        pub const Wire = if (Nullable) ?Payload else Payload;

        /// Whether this codec's literal runs carry the signed count header
        /// `slabmod.rewrite_lit_header` writes, so two of them that meet can
        /// be joined by rewriting one header instead of decoding and
        /// re-encoding their values (`Codec::rewrite_lit_header`,
        /// `codec.rs:207-219`; upstream's `do_merge` seam,
        /// `encoder.rs:288-302`).
        pub const has_lit_header = true;

        /// The run-length codec this wire layer reads and validates with.
        /// The text form is the same codec as the byte form plus the UTF-8
        /// check, so the two agree on every byte they both accept.
        pub const RleCodec = if (Utf8)
            rle.RleUtf8(Nullable)
        else if (Nullable)
            rle.RleOption(Payload)
        else
            rle.Rle(Payload);

        /// A reader over a slab's wire entries. A text column's reader
        /// refuses invalid UTF-8 on the way past it, which is where
        /// upstream validates it (`lib.rs:700-709`).
        pub const WireDecoder = RleCodec.Decoder;

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

        /// The first value of the run `seg` describes and its byte width, or
        /// null when the run carries no value. One value of a literal run;
        /// O(1) for a repeat or null run. The mirror of `lastOfRun`, and what
        /// lets a merge seam drop `b`'s first value without decoding the rest
        /// of the run (`rle/splice.rs:1104-1107`).
        fn firstOfRun(bytes: []const u8, seg: slabmod.Segment(Wire)) ParseError!?struct { value: Payload, len: usize } {
            const hdr = try leb128.readSigned(bytes[seg.byte_start..]);
            if (hdr.value == 0) return null;
            const v = try payloadRead(Payload, bytes, seg.byte_start + hdr.len);
            return .{ .value = v.value, .len = v.len };
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
                    .repeat => fillWire(Wire, out[written..][0..n], s.first_value.?),
                    .absent => fillWire(Wire, out[written..][0..n], try nullWire()),
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

        /// Where a run cursor stands inside a slab's run sequence: the run
        /// it is in, and the item inside that run.
        ///
        /// Both halves are needed because a literal run's values are read
        /// one at a time: which value comes next depends on the offset
        /// into the run and not on the run alone.
        pub const RunAt = struct {
            /// The run the cursor is in. Never a run with no items, so
            /// never the boolean codec's opening pad.
            seg: slabmod.Segment(Wire),
            /// The item the cursor stands on, inside `seg`.
            at: usize,
        };

        /// The run holding item `at`, or the first one behind it, or null
        /// once the slab has none left. Allocation-free, where
        /// `segmentsOf` builds the whole run sequence to find the same
        /// answer — which is what lets a run iterator be a value
        /// (`rle/decoder.rs:266-320`, upstream's decoder's `next_run`).
        ///
        /// A run with no items never holds anything, so a zero-count run
        /// is stepped over rather than answered.
        pub fn runAtOrAfter(bytes: []const u8, at: usize) ParseError!?RunAt {
            var pos: usize = 0;
            var item: usize = 0;
            while (pos < bytes.len) {
                const hdr = try leb128.readSigned(bytes[pos..]);
                const payload = pos + hdr.len;
                var count: usize = undefined;
                var value: Wire = undefined;
                var end: usize = undefined;
                var kind: slabmod.RunKind = undefined;
                if (hdr.value > 0) {
                    const v = try payloadRead(Payload, bytes, payload);
                    count = std.math.cast(usize, hdr.value) orelse return error.Overflow;
                    value = v.value;
                    end = payload + v.len;
                    kind = .repeat;
                } else if (hdr.value == 0) {
                    if (comptime !Nullable) return error.UnexpectedNull;
                    const n = try leb128.readUnsigned(bytes[payload..]);
                    count = std.math.cast(usize, n.value) orelse return error.Overflow;
                    value = try nullWire();
                    end = payload + n.len;
                    kind = .absent;
                } else {
                    count = std.math.cast(usize, -hdr.value) orelse return error.Overflow;
                    var p = payload;
                    const first = try payloadRead(Payload, bytes, p);
                    value = first.value;
                    p += first.len;
                    var k: usize = 1;
                    while (k < count) : (k += 1) p += (try payloadRead(Payload, bytes, p)).len;
                    end = p;
                    kind = .literal;
                }
                const stop = std.math.add(usize, item, count) catch return error.Overflow;
                if (stop > at) {
                    return .{
                        .seg = .{
                            .byte_start = pos,
                            .byte_end = end,
                            .item_start = item,
                            .item_end = stop,
                            .first_value = value,
                            .opens_with_true = false,
                            .kind = kind,
                        },
                        .at = at,
                    };
                }
                item = stop;
                pos = end;
            }
            return null;
        }

        /// The value the `k`-th item of the literal run `seg` carries.
        pub fn literalValueAt(bytes: []const u8, seg: slabmod.Segment(Wire), k: usize) ParseError!Wire {
            var one: [1]Wire = undefined;
            try readLiteralRun(bytes, seg, k, 1, one[0..]);
            return one[0];
        }

        /// The items the run cut out of a longer run sequence carries,
        /// given the value that run carries.
        ///
        /// This codec stores every value in the run's own payload, so a
        /// fragment reads back the values it was written from and `value`
        /// is not read. The argument is here rather than left to a call
        /// site's own test because a boolean run's value *is* its position
        /// in the run sequence, so the same fragment read by `Bool` has to
        /// be told where in the sequence it sits
        /// (`bool.zig:13-25`, `bool.rs:988-1002`).
        pub fn wireRunItems(
            gpa: std.mem.Allocator,
            bytes: []const u8,
            from: usize,
            to: usize,
            value: Wire,
        ) ParseError![]Wire {
            _ = value;
            return wireRange(gpa, bytes, from, to);
        }

        /// The value the first item of `bytes` carries, or null for an
        /// empty slab. Allocation-free, where `slabmod.firstValueOf`
        /// measures the whole run sequence to reach the same answer.
        pub fn firstRunValue(bytes: []const u8) ParseError!?Wire {
            if (bytes.len == 0) return null;
            const hdr = try leb128.readSigned(bytes);
            const payload = hdr.len;
            if (hdr.value > 0) return (try payloadRead(Payload, bytes, payload)).value;
            if (hdr.value == 0) {
                if (comptime !Nullable) return error.UnexpectedNull;
                return try nullWire();
            }
            return (try payloadRead(Payload, bytes, payload)).value;
        }

        /// The canonical encoding of `wires`. `opens_with_true` is the value
        /// the region's first run has to carry, which only the boolean codec
        /// reads; the RLE format stores every value and does not care which
        /// run it lands in.
        ///
        /// This is [`RunWriter`] fed one value at a time, which is what
        /// makes the whole-column encoder and the streaming encoder the same
        /// encoder: a column whose slabs were cut by `Column.Encoder` and
        /// one built in a single call are the same bytes, because there is
        /// only one grouping to produce.
        pub fn wireEncode(gpa: std.mem.Allocator, wires: []const Wire, opens_with_true: bool) ParseError![]u8 {
            _ = opens_with_true;
            var w = RunWriter(Payload, Nullable).init(gpa);
            defer w.deinit();
            try w.extend(wires);
            try w.finish();
            return w.take();
        }

        /// One run of `len` copies of `value`, in O(1).
        pub fn wireFill(gpa: std.mem.Allocator, len: usize, value: Wire, opens_with_true: bool) ParseError![]u8 {
            _ = opens_with_true;
            if (len == 0) return gpa.alloc(u8, 0);
            if (len > std.math.maxInt(i64)) return error.TooLarge;
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            // The two shapes are decided at comptime, because a
            // non-nullable column's `Wire` is the payload itself and
            // there is nothing to capture: its absent run is not part of
            // the format (`rle/decoder.rs:438-497` rule 9).
            if (comptime Nullable) {
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
            } else {
                if (len == 1) {
                    try leb128.appendSigned(&out, gpa, -1);
                    try appendValue(gpa, &out, Payload, value);
                } else {
                    try appendRepeat(gpa, &out, Payload, len, value);
                }
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

        /// The byte width of the last value of the run `seg` describes, and
        /// **zero unless that run is a literal one**.
        ///
        /// The zero is upstream's `None`: `RleTail::lit_tail` is
        /// "`None` for repeat/null runs" (`rle/mod.rs:101-103`), and the
        /// two places that clear it are exactly the two arms that are not
        /// literal runs (`rle/load.rs:47`, `:53`, and the loader's own copy
        /// of the same bookkeeping at `:146`, `:153`). It is also what
        /// `Tail.lit_tail` promises this port (`slab.zig:135-136`), so a slab
        /// whose last run is a repeat records the same width the reference
        /// does and the golden corpus compares it exactly
        /// (`codec_golden.zig:134`).
        ///
        /// A repeat run's value is one value, so its width is the run's
        /// payload width and it is *not* zero — but no caller wants it here:
        /// `Tail.lit_tail` is written, never read, and the one place that
        /// needs a run's last value width (`litSeam`) is only ever reached
        /// for a literal run.
        pub fn litTail(bytes: []const u8, seg: slabmod.Segment(Wire)) ParseError!u32 {
            switch (seg.kind) {
                .literal => {},
                .repeat, .absent, .pad => return 0,
            }
            const last = try lastOfRun(bytes, seg);
            const width = if (last) |l| l.len else 0;
            if (width > std.math.maxInt(u32)) return error.TooLarge;
            return @intCast(width);
        }

        /// The byte width of the run's first value, zero for a run that
        /// carries no value. The mirror of `litTail`, for the place a run
        /// gives up its first value rather than its last.
        pub fn litHead(bytes: []const u8, seg: slabmod.Segment(Wire)) ParseError!u32 {
            const first = try firstOfRun(bytes, seg);
            const width = if (first) |f| f.len else 0;
            if (width > std.math.maxInt(u32)) return error.TooLarge;
            return @intCast(width);
        }

        /// Whether two adjacent runs would carry the same value, so
        /// canonical form has to merge them.
        ///
        /// An absent value never equals a present one, so a nullable
        /// column's null runs never merge with the runs around them; two
        /// absent values do merge. A byte payload is compared by content,
        /// so two runs read out of two slabs merge when they hold the same
        /// bytes and not merely the same slice header.
        pub fn sameValue(a: ?Wire, b: ?Wire) bool {
            if (a == null or b == null) return false;
            if (comptime Nullable) {
                const x = a.?;
                const y = b.?;
                if (x == null or y == null) return x == null and y == null;
                return rle.payloadEql(Payload, x.?, y.?);
            }
            return rle.payloadEql(Payload, a.?, b.?);
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
        /// whole column is one run sequence. A text column's check is the
        /// same one plus the UTF-8 rule, so invalid UTF-8 is a decode
        /// error here and not a value that comes back wrong
        /// (`lib.rs:705-707`).
        pub fn canonicalSlab(bytes: []const u8) ParseError!void {
            return RleCodec.canonical(bytes);
        }
        /// Whether two wire values are equal for the canonical rules: an
        /// absent value equals an absent one and nothing else.
        fn sameElem(a: Wire, b: Wire) bool {
            if (comptime Nullable) {
                if (a == null or b == null) return a == null and b == null;
                return rle.payloadEql(Payload, a.?, b.?);
            }
            return rle.payloadEql(Payload, a, b);
        }

        /// The last value-bearing run a cursor has finished, which is what
        /// the cross-run canonical rules compare the next run against.
        const PrevRun = union(enum) {
            /// A repeat run.
            run: Wire,
            /// A literal run, recorded by its last value.
            lit: Wire,
            /// An absent run, which carries no value to compare.
            null_run,
        };

        /// One step of the incremental walk over a slab's bytes
        /// (`RunStep`, `encoding.rs:148-170`).
        pub const Step = struct {
            /// How many consecutive items carry `value`.
            count: usize,
            /// The value they carry, or null for an absent run. A byte
            /// payload borrows the input.
            value: ?Wire,
            /// Which kind of run the step came from.
            kind: slabmod.RunKind,
            /// Whether this step is the last of its run, and so whether
            /// `run_end` is the byte a slab may be cut at.
            last_of_run: bool,
            /// One past the last byte of the run, once `last_of_run` is set.
            run_end: usize,
            /// Whether the run *after* this one carries `true`, which is
            /// what a boolean slab cut here needs its pad for. Always false
            /// here: a run-length value is stored, not a position.
            after_opens_with_true: bool,
        };

        /// The incremental walk over a slab's bytes that a streaming load
        /// drives (`RleLoadIter`, `rle/load.rs:82-227`).
        ///
        /// It validates canonical form as it goes — rule for rule, the same
        /// rules [`canonicalSlab`] applies — so a caller can pull the first
        /// few runs of a malformed input, be refused on the run that breaks
        /// a rule, and never see the rest. Consuming the whole stream is
        /// the same check as validating the whole input.
        ///
        /// A literal run is served one item per step, because its items do
        /// not all carry the same value and a caller accumulating a
        /// per-item aggregate has to see each one (`rle/load.rs:131-137`).
        /// A repeat or absent run is one step with its whole count.
        /// The slab being walked, read-only. It is the caller's and must stay
        /// alive and unmodified for as long as the cursor is used; nothing
        /// the cursor hands back points into it.
        pub const LoadCursor = struct {
            bytes: []const u8,
            /// The byte offset of the next run header.
            pos: usize,
            /// Items served so far.
            item: usize,
            /// The last value-bearing run that finished, for the rules that
            /// compare across runs.
            prev: ?PrevRun,
            /// The value before the one being served, inside the run being
            /// served. Null at the start of a run, which is what makes the
            /// first item of a run check the cross-run rule and every later
            /// one check the within-run rule.
            prev_lit: ?Wire,
            /// Items left in the literal run being served, and the byte
            /// offset of the next one.
            lit_left: usize,
            /// One past the last byte of the literal run being served.
            lit_end: usize,
            /// The byte offset of the next item of the literal run being
            /// served. A literal run's payload is read one value at a time,
            /// so this walks the run rather than decoding it whole.
            lit_pos: usize,

            /// A cursor standing at the start of `bytes`. The bytes are only
            /// read, and must stay alive and unmodified for as long as the
            /// cursor is used; the cursor keeps no copy of them and hands
            /// back no slice into them.
            pub fn init(bytes: []const u8) LoadCursor {
                return .{
                    .bytes = bytes,
                    .pos = 0,
                    .item = 0,
                    .prev = null,
                    .prev_lit = null,
                    .lit_left = 0,
                    .lit_pos = 0,
                    .lit_end = 0,
                };
            }

            /// Items served so far, which is what a slab's row count is
            /// measured against.
            pub fn items(self: *const LoadCursor) usize {
                return self.item;
            }

            /// The byte offset one past the run last served — the cut point
            /// for a slab that ends there.
            pub fn bytePos(self: *const LoadCursor) usize {
                return self.pos;
            }

            /// The next step, or null at the end of the input.
            pub fn next(self: *LoadCursor) ParseError!?Step {
                if (self.lit_left != 0) return self.nextLiteral();
                if (self.pos >= self.bytes.len) return null;

                const hdr = try leb128.readSigned(self.bytes[self.pos..]);
                const payload = self.pos + hdr.len;
                if (hdr.value > 0) {
                    if (hdr.value < 2) return error.InvalidValue; // rule 1
                    const v = try payloadRead(Payload, self.bytes, payload);
                    const end = payload + v.len;
                    const value: Wire = v.value;
                    try self.checkBoundary(value); // rules 6 and 8
                    const count = std.math.cast(usize, hdr.value) orelse return error.Overflow;
                    self.item = std.math.add(usize, self.item, count) catch return error.Overflow;
                    self.pos = end;
                    self.prev = .{ .run = value };
                    self.prev_lit = null;
                    return .{
                        .count = count,
                        .value = value,
                        .kind = .repeat,
                        .last_of_run = true,
                        .run_end = end,
                        .after_opens_with_true = false,
                    };
                }
                if (hdr.value == 0) {
                    if (comptime !Nullable) return error.UnexpectedNull; // rule 9
                    const n = try leb128.readUnsigned(self.bytes[payload..]);
                    if (n.value == 0) return error.InvalidValue; // rule 2
                    if (self.prev) |p| {
                        if (std.meta.activeTag(p) == .null_run) return error.InvalidValue; // rule 5
                    }
                    const end = payload + n.len;
                    const count = std.math.cast(usize, n.value) orelse return error.Overflow;
                    self.item = std.math.add(usize, self.item, count) catch return error.Overflow;
                    self.pos = end;
                    self.prev = .null_run;
                    self.prev_lit = null;
                    return .{
                        .count = count,
                        .value = null,
                        .kind = .absent,
                        .last_of_run = true,
                        .run_end = end,
                        .after_opens_with_true = false,
                    };
                }
                const count = std.math.cast(usize, -hdr.value) orelse return error.Overflow;
                if (count == 0) return error.InvalidValue; // rule 3
                if (self.prev) |p| {
                    if (std.meta.activeTag(p) == .lit) return error.InvalidValue; // rule 4
                }
                // The literal run's payloads are walked once to find where
                // it ends; the values themselves are read again, one per
                // step, so a caller that wants each of them gets each.
                const first = try payloadRead(Payload, self.bytes, payload);
                var p = payload + first.len;
                var k: usize = 1;
                while (k < count) : (k += 1) p += (try payloadRead(Payload, self.bytes, p)).len;
                self.pos = p;
                self.lit_end = p;
                self.lit_pos = payload;
                self.lit_left = count;
                return self.nextLiteral();
            }

            /// The next item of the literal run being served.
            fn nextLiteral(self: *LoadCursor) ParseError!?Step {
                const v = try payloadRead(Payload, self.bytes, self.lit_pos);
                self.lit_pos += v.len;
                self.lit_left -= 1;
                // A literal run is served one item per step, so the row
                // count moves one at a time here too: `items` is what a
                // caller measures a slab's rows against.
                self.item = std.math.add(usize, self.item, 1) catch return error.Overflow;
                const value: Wire = v.value;
                if (self.prev_lit) |pl| {
                    // Rule 7: no two consecutive equal values inside a
                    // literal run.
                    if (sameElem(pl, value)) return error.InvalidValue;
                } else {
                    // Rule 8 at the head of the run.
                    try self.checkBoundary(value);
                }
                self.prev_lit = value;
                const last = self.lit_left == 0;
                if (last) {
                    self.pos = self.lit_end;
                    self.prev = .{ .lit = value };
                }
                return .{
                    .count = 1,
                    .value = value,
                    .kind = .literal,
                    .last_of_run = last,
                    .run_end = self.lit_end,
                    .after_opens_with_true = false,
                };
            }

            /// Rule 8: a run's first value may not equal the previous
            /// run's, in either direction. An absent run before it is no
            /// constraint, because it carries no value.
            fn checkBoundary(self: *LoadCursor, v: Wire) ParseError!void {
                const p = self.prev orelse return;
                switch (p) {
                    .run => |q| if (sameElem(q, v)) return error.InvalidValue,
                    .lit => |q| if (sameElem(q, v)) return error.InvalidValue,
                    .null_run => {},
                }
            }
        };
    };
}

/// The streaming encoder for a run-length column (`RleEncoder`,
/// `encoder.rs:116-232`).
///
/// It is [`RunWriter`] plus the bookkeeping a caller needs around it: how
/// many values went in, and — once a run budget is set — how to roll the
/// finished runs into slabs. The canonical bytes are the writer's, so the
/// streaming encoder and the whole-column one cannot drift apart.
fn RleEncoder(comptime Payload: type, comptime Nullable: bool) type {
    return struct {
        const Self = @This();

        /// What one append takes: the column value, which for a run-length
        /// column is the wire value itself.
        pub const Value = rleElement(Payload, Nullable);
        /// What one append takes, which for a run-length column is the value
        /// itself: there is no difference and no prefix to measure from.
        pub const Wire = Value;

        /// The run writer that owns the encode buffer. Everything this
        /// encoder allocates goes through it, and everything it hands back
        /// comes out of it, so the canonical bytes are one implementation's.
        writer: RunWriter(Payload, Nullable),
        /// Values appended so far. It counts every value the encoder has been
        /// given, across every buffer `take` has handed over — which is what
        /// lets a caller roll a slab and keep counting.
        total: usize,

        /// An encoder holding nothing, over one contiguous buffer. The
        /// allocator is the caller's and is not released; `deinit` is.
        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .writer = RunWriter(Payload, Nullable).init(gpa), .total = 0 };
        }

        /// Frees the encode buffer. The allocator itself is the caller's, and
        /// a buffer already handed over by `take` was not freed by it.
        pub fn deinit(self: *Self) void {
            self.writer.deinit();
            self.* = undefined;
        }

        /// Values appended so far, over every buffer this encoder has held.
        pub fn len(self: *const Self) usize {
            return self.total;
        }

        /// Whether nothing has been appended.
        pub fn isEmpty(self: *const Self) bool {
            return self.total == 0;
        }

        /// The runs written and the ones still in progress.
        pub fn segmentCount(self: *const Self) usize {
            return self.writer.segmentCount();
        }

        /// Appends one value. Malformed bytes are not a case here — this
        /// writes them — so the only error is the allocator's.
        pub fn append(self: *Self, v: Wire) ParseError!void {
            try self.writer.append(v);
            self.total += 1;
        }

        /// Appends `n` copies of `v`. For a run-length column the copies
        /// *are* one run, and a repeat run needs at least two, so a single
        /// value is written as the start of a literal run instead
        /// (`RleState`, `rle/state.rs:60-70`).
        pub fn appendN(self: *Self, v: Wire, n: usize) ParseError!void {
            try self.writer.appendN(v, n);
            self.total += n;
        }

        /// Writes the runs still in progress. Consumed by [`Self.take`].
        pub fn finish(self: *Self) ParseError!void {
            try self.writer.finish();
        }

        /// The bytes written so far. The writer is empty afterwards, so a
        /// caller that rolls a slab here can keep appending into a fresh
        /// buffer.
        pub fn take(self: *Self) ParseError![]u8 {
            return self.writer.take();
        }
    };
}

/// The streaming encoder for a boolean column (`BoolEncoder`,
/// `encoder.rs:609-800`).
///
/// A boolean run's value is its position in the sequence, so an encoder
/// only has to count how long each value lasts — which is what makes this
/// the shortest of the three: no payload is stored and no header but the
/// count is written.
fn BoolEncoder(comptime V: type) type {
    return struct {
        const Self = @This();

        /// A boolean value. The stored value is the value, so the wire value
        /// is the value and there is no payload to speak of.
        pub const Value = V;
        /// What one append takes: the value itself.
        pub const Wire = V;

        /// The allocator the encode buffer is allocated and released with: the
        /// one `init` was given. `deinit` releases the buffer, not the
        /// allocator, and a buffer already handed over by `take` was not
        /// freed by it.
        gpa: std.mem.Allocator,
        /// The bytes written so far. A run is one LEB128 count and nothing
        /// else; the value is the run's position in the sequence, which is
        /// why no payload is stored (`bool.rs:609-800`).
        out: std.ArrayList(u8),
        /// The value the run in progress carries, and how far it has grown.
        pending: ?V,
        /// How many items the run in progress holds.
        count: usize,
        /// Values appended so far. It counts every value the encoder has been
        /// given, across every buffer `take` has handed over.
        total: usize,
        /// Runs written to `out`. Reset by `take`, and it has to be: the
        /// count is what decides whether the next run is written with the
        /// opening pad, and a column's second slab starts at run zero
        /// however many runs the first one had (`bool.rs:988-1002`).
        segments: usize,

        /// An encoder holding nothing, with no run in progress. The allocator
        /// is the caller's and is not released; `deinit` is.
        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa, .out = .empty, .pending = null, .count = 0, .total = 0, .segments = 0 };
        }

        /// Frees the encode buffer. The allocator itself is the caller's, and
        /// a buffer already handed over by `take` was not freed by it.
        pub fn deinit(self: *Self) void {
            self.out.deinit(self.gpa);
            self.* = undefined;
        }

        /// Values appended so far, over every buffer this encoder has held.
        pub fn len(self: *const Self) usize {
            return self.total;
        }

        /// Whether nothing has been appended.
        pub fn isEmpty(self: *const Self) bool {
            return self.total == 0;
        }

        /// The runs already written plus the one still in progress, which is
        /// what a run budget is compared against.
        pub fn segmentCount(self: *const Self) usize {
            return self.segments + @intFromBool(self.pending != null);
        }

        /// Appends one value. A value equal to the run in progress extends
        /// that run rather than starting a new one, which is what makes the
        /// grouping canonical; a different one flushes it first, so
        /// `error.OutOfMemory` there leaves the run in progress and nothing
        /// written for the new value.
        pub fn append(self: *Self, v: V) ParseError!void {
            if (self.pending) |p| {
                if (p == v) {
                    self.count += 1;
                    self.total += 1;
                    return;
                }
                try self.flush();
            }
            self.pending = v;
            self.count = 1;
            self.total += 1;
        }

        /// Appends `n` copies of `v` as one run, extending the run in
        /// progress when it already carries `v`. `n == 0` appends nothing.
        pub fn appendN(self: *Self, v: V, n: usize) ParseError!void {
            if (n == 0) return;
            if (self.pending) |p| {
                if (p == v) {
                    self.count += n;
                    self.total += n;
                    return;
                }
                try self.flush();
            }
            self.pending = v;
            self.count = n;
            self.total += n;
        }

        /// Writes the run in progress, so every appended value is in the
        /// bytes. Consumed by [`Self.take`](BoolEncoder.take), which needs
        /// it: a slab cut at a run boundary cannot leave a run half-written.
        pub fn finish(self: *Self) ParseError!void {
            try self.flush();
        }

        /// The bytes written so far, handed over. A slab boundary: the run
        /// in progress must already be flushed with `finish`, and the run
        /// count starts again at zero. It has to: the count is what decides
        /// whether the next run is written with the opening pad, and a
        /// column's second slab starts at run zero however many runs the
        /// first one had (`bool.rs:988-1002`).
        pub fn take(self: *Self) ParseError![]u8 {
            self.segments = 0;
            return self.out.toOwnedSlice(self.gpa);
        }

        fn flush(self: *Self) ParseError!void {
            const v = self.pending orelse return;
            // A run sequence read from its own start opens on a `false`
            // run, so a column whose first value is `true` spends a run on
            // the pad that lets it (`bool.rs:988-1002`).
            if (v and self.segments == 0) try leb128.appendUnsigned(&self.out, self.gpa, 0);
            try leb128.appendUnsigned(&self.out, self.gpa, self.count);
            self.segments += 1;
            self.pending = null;
            self.count = 0;
        }
    };
}

/// One value's byte width and how to read it, and how one value is
/// written. Both are the codec's own, so an integer packs as its integer
/// and a byte payload as an unsigned LEB128 length followed by that many
/// raw bytes (`lib.rs:566-595` for the integers, `lib.rs:696-770` for
/// `String` and `Vec<u8>`).
fn payloadRead(comptime Payload: type, bytes: []const u8, pos: usize) ParseError!struct { value: Payload, len: usize } {
    const read = try rle.payloadRead(Payload, bytes, pos);
    return .{ .value = read.value, .len = read.len };
}

fn appendValue(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime Payload: type, v: Payload) !void {
    try rle.payloadAppend(gpa, out, Payload, v);
}

fn appendRepeat(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime Payload: type, count: usize, v: Payload) !void {
    try leb128.appendSigned(out, gpa, @as(i64, @intCast(count)));
    try appendValue(gpa, out, Payload, v);
}

fn appendNullRun(gpa: std.mem.Allocator, out: *std.ArrayList(u8), count: usize) !void {
    try leb128.appendSigned(out, gpa, 0);
    try leb128.appendUnsigned(out, gpa, count);
}

/// The canonical run-length encoder, one value at a time
/// (`RleState`/`RleEncoderState`, `rle/state.rs` and `encoder.rs:40-114`).
///
/// Canonical form decides the grouping, and the grouping is decided by a
/// greedy scan: a maximal run of two or more equal values is a repeat run,
/// everything else joins the literal run in progress, and a run of absent
/// values is a null run. Two adjacent literal runs are not canonical
/// (`rle/decoder.rs:438-497`), so there is exactly one grouping and this is
/// it.
///
/// The three runs in progress are held in the order they stand in the
/// output — the literal run, then the repeat run, then the null run — so
/// `flushAll` writes them in the order the bytes need them. A caller
/// appending one value at a time never holds more than those three runs,
/// which is what makes this a streaming encoder rather than a whole-column
/// re-encode.
fn RunWriter(comptime Payload: type, comptime Nullable: bool) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        out: std.ArrayList(u8),
        /// The literal run in progress. It is held rather than written
        /// because a value that turns out to open a repeat has to be pulled
        /// back out of the payload it would have joined.
        lit: std.ArrayList(Payload),
        /// The repeat run in progress, and how far it has grown. A repeat
        /// run is never written with a count of one: a single value is a
        /// literal run (`rle/state.rs:682-693`).
        rep_value: ?Payload,
        rep_count: usize,
        /// The absent run in progress.
        null_count: usize,
        /// The runs written to `out` so far.
        segments: usize,

        /// A writer holding nothing, over an empty buffer. The allocator is
        /// the caller's and is not released; `deinit` is.
        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .gpa = gpa,
                .out = .empty,
                .lit = .empty,
                .rep_value = null,
                .rep_count = 0,
                .null_count = 0,
                .segments = 0,
            };
        }

        /// Frees the encode buffer and the literal run's payload buffer. The
        /// allocator itself is the caller's.
        pub fn deinit(self: *Self) void {
            self.out.deinit(self.gpa);
            self.lit.deinit(self.gpa);
            self.* = undefined;
        }

        /// The runs written and the ones still in progress, which is what a
        /// streaming encoder sizes a slab cut against (`encoder.rs:186-196`).
        pub fn segmentCount(self: *const Self) usize {
            var n = self.segments;
            if (self.lit.items.len != 0) n += 1;
            if (self.rep_value != null) n += 1;
            if (self.null_count != 0) n += 1;
            return n;
        }

        /// Appends one value, extending the repeat run in progress when it
        /// is the same value.
        pub fn append(self: *Self, v: rleElement(Payload, Nullable)) !void {
            if (comptime Nullable) {
                const present = v orelse {
                    // An absent value ends the literal run and the repeat
                    // run; both are in front of it.
                    try self.flushLiteral();
                    try self.flushRepeat();
                    self.null_count += 1;
                    return;
                };
                // Only the absent run stands between a null run and a
                // present one: the literal and repeat runs in progress
                // carry on, which is what makes two adjacent equal values
                // one repeat run across an absent run. Flushing them
                // here would write every present value as a literal run
                // of one, and a run sequence of those is not canonical
                // (`rle/decoder.rs:438-497` rules 4 and 6).
                try self.flushNull();
                try self.appendPresent(present);
                return;
            }
            try self.appendPresent(v);
        }

        /// Appends `n` copies of `v` as one run (`EncoderApi::append_n`).
        pub fn appendN(self: *Self, v: rleElement(Payload, Nullable), n: usize) !void {
            if (n == 0) return;
            if (comptime Nullable) {
                const present = v orelse {
                    try self.flushLiteral();
                    try self.flushRepeat();
                    self.null_count += n;
                    return;
                };
                try self.startRun(present, n);
                return;
            }
            try self.startRun(v, n);
        }

        /// Appends every value of `values`, in order.
        pub fn extend(self: *Self, values: []const rleElement(Payload, Nullable)) !void {
            for (values) |v| try self.append(v);
        }

        /// Writes the runs still in progress, in output order.
        pub fn finish(self: *Self) !void {
            try self.flushAll();
        }

        /// The bytes written so far, handed over. A slab boundary: the
        /// runs in progress must already be flushed with `finish`, and the
        /// run count starts again at zero, so the next slab's budget is
        /// measured against its own runs and not against this one's.
        pub fn take(self: *Self) ![]u8 {
            self.segments = 0;
            return self.out.toOwnedSlice(self.gpa);
        }

        fn appendPresent(self: *Self, v: Payload) !void {
            if (self.rep_value) |rv| {
                if (rle.payloadEql(Payload, rv, v)) {
                    self.rep_count += 1;
                    return;
                }
                // This run of `rv` is over, and everything buffered in
                // front of it is written before it.
                try self.flushLiteral();
                try self.flushRepeat();
            }
            if (self.lit.items.len != 0 and rle.payloadEql(Payload, self.lit.items[self.lit.items.len - 1], v)) {
                // The value already in the literal run is the first of
                // this one, so it leaves the literal and joins it.
                self.lit.shrinkRetainingCapacity(self.lit.items.len - 1);
                self.rep_value = v;
                self.rep_count = 2;
                return;
            }
            try self.lit.append(self.gpa, v);
        }

        fn startRun(self: *Self, v: Payload, n: usize) !void {
            if (self.lit.items.len != 0 and rle.payloadEql(Payload, self.lit.items[self.lit.items.len - 1], v)) {
                self.lit.shrinkRetainingCapacity(self.lit.items.len - 1);
            }
            try self.flushAll();
            if (n == 1) {
                try self.lit.append(self.gpa, v);
                return;
            }
            self.rep_value = v;
            self.rep_count = n;
        }

        fn flushAll(self: *Self) !void {
            try self.flushLiteral();
            try self.flushRepeat();
            try self.flushNull();
        }

        fn flushLiteral(self: *Self) !void {
            if (self.lit.items.len == 0) return;
            try leb128.appendSigned(&self.out, self.gpa, -@as(i64, @intCast(self.lit.items.len)));
            for (self.lit.items) |v| try rle.payloadAppend(self.gpa, &self.out, Payload, v);
            self.lit.clearRetainingCapacity();
            self.segments += 1;
        }

        fn flushRepeat(self: *Self) !void {
            const v = self.rep_value orelse return;
            try leb128.appendSigned(&self.out, self.gpa, @as(i64, @intCast(self.rep_count)));
            try rle.payloadAppend(self.gpa, &self.out, Payload, v);
            self.rep_value = null;
            self.rep_count = 0;
            self.segments += 1;
        }

        fn flushNull(self: *Self) !void {
            if (self.null_count == 0) return;
            try leb128.appendSigned(&self.out, self.gpa, 0);
            try leb128.appendUnsigned(&self.out, self.gpa, self.null_count);
            self.null_count = 0;
            self.segments += 1;
        }
    };
}

fn rleElement(comptime Payload: type, comptime Nullable: bool) type {
    return if (Nullable) ?Payload else Payload;
}

/// Whether two wire values stand for the same value. An integer compares as
/// an integer; a byte payload compares **by content**, because a read
/// borrows the encoded bytes and two values read out of two different slabs
/// have different pointers.
fn eqlWire(comptime Payload: type, comptime Nullable: bool, a: rleElement(Payload, Nullable), b: rleElement(Payload, Nullable)) bool {
    if (comptime Nullable) {
        if (a == null or b == null) return a == null and b == null;
        return rle.payloadEql(Payload, a.?, b.?);
    }
    return rle.payloadEql(Payload, a, b);
}

// ── Codecs ────────────────────────────────────────────────────────────────

/// The column-facing half of the run-length codec, shared by every payload
/// and both nullabilities. `Payload` is what a value packs as, `Nullable`
/// says whether a null run is part of the format (`lib.rs:406-437`), and
/// `Utf8` is the byte payload's validation rule (`lib.rs:700-709`).
fn RleBase(comptime Payload: type, comptime Nullable: bool, comptime Utf8: bool) type {
    return struct {
        const Base = WireRle(Payload, Nullable, Utf8);

        /// The column value type, and the wire form too: a run-length column
        /// stores the values themselves, so there is no difference and no
        /// length to measure.
        pub const Value = rleElement(Payload, Nullable);
        pub const Wire = Base.Wire;
        pub const has_lit_header = Base.has_lit_header;
        pub const runAtOrAfter = Base.runAtOrAfter;
        pub const firstRunValue = Base.firstRunValue;
        pub const literalValueAt = Base.literalValueAt;
        /// The per-slab weight, and so the index type this column builds.
        /// `tracks_prefix` false means the column keeps no per-slab bases: a
        /// run-length column stores the values themselves.
        pub const Weight = LenWeight;
        /// Whether this column keeps the per-slab weight prefixes. False: a
        /// run-length column stores the values themselves.
        pub const tracks_prefix = false;
        /// Whether the stored value is a row's own *length*, so the
        /// column answers the prefix-sum questions (`PrefixValue`,
        /// `prefix.rs:44-108`). A delta column's weight carries a
        /// running value too, so `tracks_prefix` alone does not say so.
        pub const is_prefix_column = false;
        /// Whether the stored value is a difference from the row in
        /// front (`DeltaValue`, `delta/mod.rs:19-26`). Only such a
        /// column's runs are runs of equal *differences* rather than
        /// equal values, so its run iterator has to realize values.
        pub const is_delta = false;
        pub const WireDecoder = Base.WireDecoder;
        /// The incremental wire walk a streaming load drives
        /// (`ColumnEncoding::LoadIter`, `encoding.rs:129-170`).
        pub const LoadCursor = Base.LoadCursor;
        /// The streaming encoder over this column's values
        /// (`ColumnEncoding::Encoder`, `encoding.rs:126-129`).
        pub const StreamEncoder = RleEncoder(Payload, Nullable);

        pub const segmentsOf = Base.segmentsOf;
        pub const wireRange = Base.wireRange;
        pub const wireRunItems = Base.wireRunItems;
        pub const wireEncode = Base.wireEncode;
        pub const wireFill = Base.wireFill;
        /// The bytes of a slab holding `len` copies of the column *value*
        /// `value` (`Column::fill`, `column.rs:1227-1245`). A run-length
        /// column stores the value, so this is one run and O(1).
        pub fn fillBytes(gpa: std.mem.Allocator, len: usize, value: Value) ParseError![]u8 {
            return Base.wireFill(gpa, len, value, false);
        }
        pub const wireSlice = Base.wireSlice;
        pub const lastValueOfRun = Base.lastValueOfRun;
        pub const litTail = Base.litTail;
        pub const litHead = Base.litHead;
        pub const sameValue = Base.sameValue;
        pub const mustMergeKinds = Base.mustMergeKinds;
        pub const canonicalSlab = Base.canonicalSlab;

        /// The item count: a run of a run-length column has nothing to
        /// aggregate (`LenWeight::compute`, `column.rs:122`).
        pub fn weightOf(gpa: std.mem.Allocator, slab: *const Slab) ParseError!Weight {
            _ = gpa;
            return .{ .len = slab.len };
        }

        /// How far a slab's weight advances a prefix sum: zero, because a
        /// run-length column is not a prefix column and its weight carries
        /// no running value.
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
        ///
        /// A byte payload contributes nothing: its weight is the item
        /// count alone, exactly as a non-nullable integer's is, so there is
        /// no arithmetic for a row's *length* to do.
        pub fn accumulate(w: Wire, running: *i64) ParseError!void {
            if (comptime isBytes(Payload)) {
                // A byte payload carries no numeric weight of its own: the
                // item count alone is its length, so there is nothing to
                // fold into the running sum.
                return;
            }
            if (comptime Nullable) {
                if (w) |v| running.* = try addChecked(running.*, @as(i64, @intCast(v)));
            } else {
                running.* = try addChecked(running.*, @as(i64, @intCast(w)));
            }
        }

        /// The wire entry one value takes on a column whose running value
        /// in front of it is `running`, and the running value it leaves
        /// behind.
        ///
        /// A run-length column stores its values, so the two are the same
        /// number and nothing moves.
        pub fn wireOfOne(running: i64, v: Value) ParseError!struct { wire: Wire, running: i64 } {
            return .{ .wire = v, .running = running };
        }

        /// The wire values `values` take, and the running value they leave
        /// behind — which is the input, unchanged.
        ///
        /// For a byte payload the wires are the caller's own slices: the
        /// splice encodes them into the slab's bytes straight away, so no
        /// slab ever borrows storage the caller has not promised to keep.
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

/// Whether a run-length payload is one this codec accepts: an integer,
/// which packs as its own LEB128 form (`lib.rs:566-637`), or a byte
/// string, which packs as an unsigned length and the bytes
/// (`lib.rs:696-770`). Anything else has no wire form at all.
fn rlePayloadOk(comptime T: type, comptime who: []const u8) void {
    if (comptime !isBytes(T) and @typeInfo(T) != .int) {
        @compileError(who ++ " values must be an integer type or []const u8");
    }
}

/// The run-length codec for a non-nullable column of `T`. `T` is an
/// integer — unsigned types pack unsigned LEB128, signed types signed —
/// or a byte string, which packs as a length and its bytes.
pub fn Rle(comptime T: type) type {
    rlePayloadOk(T, "Rle");
    return RleBase(T, false, false);
}

/// The run-length codec for a nullable column of `T`: an absent value rides
/// in the run header and never in a payload (`lib.rs:406-437`).
pub fn RleOption(comptime T: type) type {
    rlePayloadOk(T, "RleOption");
    return RleBase(T, true, false);
}

/// The run-length codec for a column of text: the byte codec's wire, with
/// every value checked to be UTF-8 as it is read (`lib.rs:700-709`).
///
/// `Nullable` is the whole difference between the two forms, exactly as in
/// [`Rle`] and [`RleOption`]; an absent value is still carried by the run
/// header and is never a UTF-8 question.
pub fn RleUtf8(comptime Nullable: bool) type {
    return RleBase([]const u8, Nullable, true);
}

/// The prefix codec: an ordinary RLE column of row lengths, with an index
/// that also carries their sum, so the offset of any row is one lookup
/// away. `T` is an integer or an optional of one; an absent length
/// contributes nothing to the sum (`prefix.rs:287-312`).
pub fn Prefix(comptime T: type) type {
    const Payload = payloadOf(T);
    const Nullable = isNullable(T);
    const Base = WireRle(Payload, Nullable, false);
    return struct {
        /// The column value type: a row's own length. The wire form is the
        /// same number, so the two are the same type.
        pub const Value = T;
        pub const Wire = Base.Wire;
        pub const has_lit_header = Base.has_lit_header;
        pub const runAtOrAfter = Base.runAtOrAfter;
        pub const firstRunValue = Base.firstRunValue;
        pub const literalValueAt = Base.literalValueAt;
        /// The per-slab weight, and so the index type this column builds.
        /// `tracks_prefix` true means the column keeps per-slab bases, which
        /// is what turns a row length into an absolute prefix position.
        pub const Weight = PrefixWeight;
        /// Whether this column keeps the per-slab weight prefixes, and why
        /// that matters here, is said on the weight above.
        pub const tracks_prefix = true;
        /// Whether the stored value is a row's own *length*, so the
        /// column answers the prefix-sum questions (`PrefixValue`,
        /// `prefix.rs:44-108`). A delta column's weight carries a
        /// running value too, so `tracks_prefix` alone does not say so.
        pub const is_prefix_column = true;
        /// Whether the stored value is a difference from the row in
        /// front (`delta/mod.rs:19-26`).
        pub const is_delta = false;
        pub const WireDecoder = Base.WireDecoder;
        /// The incremental wire walk a streaming load drives
        /// (`ColumnEncoding::LoadIter`, `encoding.rs:129-170`).
        pub const LoadCursor = Base.LoadCursor;
        /// The streaming encoder over this column's values
        /// (`ColumnEncoding::Encoder`, `encoding.rs:126-129`).
        pub const StreamEncoder = RleEncoder(Payload, Nullable);

        pub const segmentsOf = Base.segmentsOf;
        pub const wireRange = Base.wireRange;
        pub const wireRunItems = Base.wireRunItems;
        pub const wireEncode = Base.wireEncode;
        pub const wireFill = Base.wireFill;
        /// The bytes of a slab holding `len` copies of the column *value*
        /// `value` (`Column::fill`, `column.rs:1227-1245`). A prefix
        /// column stores the length itself, so this is one run and O(1).
        pub fn fillBytes(gpa: std.mem.Allocator, len: usize, value: Value) ParseError![]u8 {
            return Base.wireFill(gpa, len, value, false);
        }
        pub const wireSlice = Base.wireSlice;
        pub const lastValueOfRun = Base.lastValueOfRun;
        pub const litTail = Base.litTail;
        pub const litHead = Base.litHead;
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

        /// How far a slab's weight advances a prefix sum: the sum of the row
        /// lengths the slab holds, which is the weight's `prefix` half.
        pub fn weightIncrement(w: Weight) i64 {
            return w.increment();
        }

        /// The column value a wire entry stands for. A prefix column stores
        /// the row length itself, so `running` is untouched and the returned
        /// value is the wire entry.
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

        /// The wire entry one value takes on a column whose running value
        /// in front of it is `running`, and the running value it leaves
        /// behind.
        ///
        /// A run-length column stores its values, so the two are the same
        /// number and nothing moves.
        pub fn wireOfOne(running: i64, v: Value) ParseError!struct { wire: Wire, running: i64 } {
            return .{ .wire = v, .running = running };
        }

        /// The wire entries an insert takes, and the running value behind
        /// them. A prefix column stores the row length itself, so the entries
        /// are the values unchanged and the running value does not move; the
        /// returned slice is the caller's to release with `gpa`.
        pub fn wireOfInsert(gpa: std.mem.Allocator, running: i64, values: []const Value) ParseError!Inserted(Wire) {
            const out = try gpa.dupe(Wire, values);
            return .{ .wires = out, .running = running };
        }

        /// Nothing to re-anchor: a prefix column stores the row length
        /// rather than a difference, so no wire entry is measured against a
        /// running value. Always null, and the column's re-anchor step reads
        /// that as "no row to fix".
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
    const Base = WireRle(i64, true, false);
    const Payload = payloadOf(T);
    const Nullable = isNullable(T);

    return struct {
        /// The column value type, and what a run's difference is measured
        /// against. The wire form is a difference rather than the value, so
        /// the two are not the same type.
        pub const Value = T;
        /// A difference, or absent for a row that holds no value and so
        /// leaves the running value alone.
        pub const Wire = ?i64;
        pub const has_lit_header = Base.has_lit_header;
        pub const runAtOrAfter = Base.runAtOrAfter;
        pub const firstRunValue = Base.firstRunValue;
        pub const literalValueAt = Base.literalValueAt;
        /// The per-slab weight, and so the index type this column builds.
        /// `tracks_prefix` true means the column keeps per-slab bases: a
        /// delta column's rows are differences measured against a running
        /// value, so every read needs the value in front of its slab.
        pub const Weight = btree.SlabAgg;
        /// Whether this column keeps the per-slab weight prefixes, and why
        /// that matters here, is said on the weight above.
        pub const tracks_prefix = true;
        /// Whether the stored value is a row's own *length*, so the
        /// column answers the prefix-sum questions (`PrefixValue`,
        /// `prefix.rs:44-108`). A delta column's weight carries a
        /// running value too, so `tracks_prefix` alone does not say so.
        pub const is_prefix_column = false;
        /// Whether the stored value is a difference from the row in
        /// front (`DeltaValue`, `delta/mod.rs:19-26`). Only such a
        /// column's runs are runs of equal *differences* rather than
        /// equal values, so its run iterator has to realize values.
        pub const is_delta = true;
        pub const WireDecoder = Base.WireDecoder;
        /// The incremental wire walk a streaming load drives
        /// (`ColumnEncoding::LoadIter`, `encoding.rs:129-170`).
        pub const LoadCursor = Base.LoadCursor;
        /// The streaming encoder over this column's values
        /// (`ColumnEncoding::Encoder`, `encoding.rs:126-129`).
        ///
        /// **Over the wire domain, not the value domain.** A delta
        /// column's wire entry is a *signed difference* from the value in
        /// front of the row, and an absent row rides in the run header as
        /// a null — which is `Base`'s own nullable run-length codec, so the
        /// encoder is `RleEncoder(i64, true)` and not one over `Payload`.
        /// A `u64` payload packs unsigned and has no way to write an
        /// absent row at all.
        pub const StreamEncoder = RleEncoder(i64, true);

        pub const segmentsOf = Base.segmentsOf;
        pub const wireRange = Base.wireRange;
        pub const wireRunItems = Base.wireRunItems;
        pub const wireEncode = Base.wireEncode;
        pub const wireFill = Base.wireFill;
        pub const wireSlice = Base.wireSlice;
        pub const lastValueOfRun = Base.lastValueOfRun;
        pub const litTail = Base.litTail;
        pub const litHead = Base.litHead;
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

        /// How far a slab's weight advances a prefix sum. A delta column's
        /// weight carries the slab's own prefix increment, so this is the
        /// sum its rows add to the running value in front of the slab.
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

        /// The wire entry one value takes, measured from the running value
        /// in front of it (`delta/mod.rs:1384-1400`). An absent row holds
        /// no difference, so it leaves the running value where it is.
        pub fn wireOfOne(running: i64, v: Value) ParseError!struct { wire: Wire, running: i64 } {
            if (comptime Nullable) {
                const maybe = v orelse return .{ .wire = null, .running = running };
                const wide = try widen(maybe);
                return .{ .wire = try std.math.sub(i64, wide, running), .running = wide };
            }
            const wide = try widen(v);
            return .{ .wire = try std.math.sub(i64, wide, running), .running = wide };
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
                    out[i] = try std.math.sub(i64, wide, acc);
                    acc = wide;
                } else {
                    const wide = try widen(v);
                    out[i] = try std.math.sub(i64, wide, acc);
                    acc = wide;
                }
            }
            return .{ .wires = out, .running = acc };
        }

        /// The bytes of a slab holding `len` copies of the column *value*
        /// `value` (`Column::fill`, `column.rs:1227-1245`).
        ///
        /// A delta column stores differences, so a run of equal values is
        /// not a run: the first row's value is measured from zero and
        /// every row after it carries a difference of zero. That is one
        /// literal run followed by one repeat run — except at `len == 2`,
        /// where the two differences are distinct values and so have to be
        /// one literal run, and at a value of zero, where the whole thing
        /// is a single repeat run (`rle/decoder.rs:438-497` rules 1, 4
        /// and 7). Three shapes, all O(1) in `len`.
        pub fn fillBytes(gpa: std.mem.Allocator, len: usize, value: Value) ParseError![]u8 {
            if (len == 0) return gpa.alloc(u8, 0);
            if (len > std.math.maxInt(i64)) return error.TooLarge;
            if (comptime Nullable) {
                // An absent row holds no difference at all, so a slab of
                // them is one null run.
                if (value == null) return Base.wireFill(gpa, len, null, false);
            }
            const v = if (comptime Nullable) (value.?) else value;
            const wide = try widen(v);
            if (wide == 0) return Base.wireFill(gpa, len, 0, false);
            if (len == 2) {
                const two = [_]Wire{ wide, 0 };
                return Base.wireEncode(gpa, &two, false);
            }
            const head = try Base.wireFill(gpa, 1, wide, false);
            defer gpa.free(head);
            const tail = try Base.wireFill(gpa, len - 1, 0, false);
            defer gpa.free(tail);
            const out = try gpa.alloc(u8, head.len + tail.len);
            @memcpy(out[0..head.len], head);
            @memcpy(out[head.len..], tail);
            return out;
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
    /// The column value type: a boolean is its own wire value.
    pub const Value = bool;
    /// The wire value type, which for a boolean column is the value itself.
    pub const Wire = bool;
    /// A boolean run is a length in the byte stream and its value is the
    /// run's position in the sequence, so there is no header behind it at
    /// all (`bool.rs:13-25`) — not even for a one-item run.
    pub const has_lit_header = false;
    /// The per-slab weight, and so the index type this column builds.
    /// `tracks_prefix` false means the column keeps no per-slab bases.
    pub const Weight = LenWeight;
    /// Whether this column keeps the per-slab weight prefixes. False: a
    /// boolean column stores the values themselves.
    pub const tracks_prefix = false;
    /// Whether the stored value is a row's own *length*, so the column
    /// answers the prefix-sum questions (`prefix.rs:44-108`). A boolean
    /// column is *not* one, even though a run of `true`s is a run of
    /// ones: upstream spells that `PrefixValue for bool`
    /// (`prefix.rs:316`) and keeps the count in the slab's own sums.
    pub const is_prefix_column = false;
    /// Whether the stored value is a difference from the row in front
    /// (`delta/mod.rs:19-26`).
    pub const is_delta = false;
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

    /// The wire values for rows `from..to` of `bytes`, as a fresh
    /// caller-owned slice. Decodes the whole slab and copies the window out
    /// of it, so `from > to` or `to` past the end is `error.InvalidValue`.
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

    /// The bytes of a slab holding `len` copies of `value`
    /// (`Column::fill`, `column.rs:1227-1245`). A boolean value is a run
    /// count and nothing else, so this is one run and O(1).
    pub fn fillBytes(gpa: std.mem.Allocator, len: usize, value: Value) ParseError![]u8 {
        return Bool.wireFill(gpa, len, value, false);
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

    /// The streaming encoder over this column's values
    /// (`ColumnEncoding::Encoder`, `encoding.rs:126-129`).
    pub const StreamEncoder = BoolEncoder(bool);

    /// A boolean run stores no value, so there is no literal tail to record.
    pub fn litTail(bytes: []const u8, seg: slabmod.Segment(Bool.Wire)) ParseError!u32 {
        _ = bytes;
        _ = seg;
        return 0;
    }

    /// A boolean run stores a length, not values, so the first value of the
    /// run has no width. The mirror of `litTail`, which is zero for the same
    /// reason.
    pub fn litHead(bytes: []const u8, seg: slabmod.Segment(Bool.Wire)) ParseError!u32 {
        _ = bytes;
        _ = seg;
        return 0;
    }

    /// The value the `k`-th item of the run `seg` carries. A boolean
    /// literal run is a run of one item (`bool.rs:13-25`: the value is the
    /// run's position, not a stored one), so the run's own value is the
    /// only one it has.
    pub fn literalValueAt(bytes: []const u8, seg: slabmod.Segment(Bool.Wire), k: usize) ParseError!Bool.Wire {
        _ = bytes;
        _ = k;
        return seg.first_value.?;
    }

    /// The items the run cut out of a longer run sequence carries.
    ///
    /// A boolean run carries no payload: its value is its position in the
    /// run sequence, so `to - from` copies of `value` **is** the run's
    /// items — and a fragment cut out of a longer sequence cannot say so
    /// for itself, because read on its own it opens on the `false` run a
    /// slab's own bytes open on and every item behind it is the other
    /// boolean than it is (`bool.zig:13-25`, `bool.rs:988-1002`).
    pub fn wireRunItems(
        gpa: std.mem.Allocator,
        bytes: []const u8,
        from: usize,
        to: usize,
        value: Bool.Wire,
    ) ParseError![]Bool.Wire {
        _ = bytes;
        if (to < from) return error.InvalidValue;
        const out = try gpa.alloc(Bool.Wire, to - from);
        errdefer gpa.free(out);
        fillWire(Bool.Wire, out, value);
        return out;
    }

    /// Where a run cursor stands inside a boolean slab's run sequence:
    /// the run it is in, and the item inside that run. See
    /// `WireRle.RunAt`; a boolean run's value is its position, so the
    /// second half is what a literal run of one item would not tell us.
    pub const RunAt = struct {
        /// The run the cursor is in. Never the opening pad, which holds
        /// no items.
        seg: slabmod.Segment(Bool.Wire),
        /// The item the cursor stands on, inside `seg`.
        at: usize,
    };

    /// The run holding item `at`, or the first one behind it, or null
    /// once the slab has none left. Allocation-free, so a run iterator
    /// over a boolean column is a value (`bool.rs:756-772`, upstream's
    /// count walk).
    ///
    /// The leading pad holds no items and so is stepped over rather than
    /// answered (`bool.rs:988-1002`).
    pub fn runAtOrAfter(bytes: []const u8, at: usize) ParseError!?RunAt {
        var pos: usize = 0;
        var item: usize = 0;
        var value: bool = false;
        var first = true;
        while (pos < bytes.len) {
            const c = try leb128.readUnsigned(bytes[pos..]);
            const count = std.math.cast(usize, c.value) orelse return error.Overflow;
            const stop = std.math.add(usize, item, count) catch return error.Overflow;
            if (stop > at) {
                return .{
                    .seg = .{
                        .byte_start = pos,
                        .byte_end = pos + c.len,
                        .item_start = item,
                        .item_end = stop,
                        .first_value = value,
                        .opens_with_true = value,
                        .kind = if (count == 1) .literal else .repeat,
                    },
                    .at = at,
                };
            }
            item = stop;
            pos += c.len;
            // Only the very first run may hold no items, and it does not
            // flip the parity (`bool.rs:988-1002`); the same rule
            // `segmentsOf` follows.
            if (!first or !value) value = !value;
            first = false;
        }
        return null;
    }

    /// The value the first item of `bytes` carries, or null for an empty
    /// slab. Allocation-free.
    pub fn firstRunValue(bytes: []const u8) ParseError!?Bool.Wire {
        var pos: usize = 0;
        var value: bool = false;
        var first = true;
        while (pos < bytes.len) {
            const c = try leb128.readUnsigned(bytes[pos..]);
            if (c.value != 0) return value;
            pos += c.len;
            if (!first or !value) value = !value;
            first = false;
        }
        return null;
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

    /// The slab's weight: its item count, which is all a boolean column's
    /// index needs (`column.rs:115-137`).
    pub fn weightOf(gpa: std.mem.Allocator, slab: *const Slab) ParseError!Weight {
        _ = gpa;
        return .{ .len = slab.len };
    }

    /// One step of the incremental walk over a boolean slab's bytes. A
    /// boolean run's items all carry its one value, so a run is one step
    /// with its whole count (`encoding.rs:148-170`).
    pub const Step = struct {
        /// How many items the run carries.
        count: usize,
        /// The value they carry, or null for the opening pad, which carries
        /// none.
        value: ?Wire,
        /// Which kind of run the step came from.
        kind: slabmod.RunKind,
        /// Always true: a boolean run is served in one step.
        last_of_run: bool,
        /// One past the run's last byte.
        run_end: usize,
        /// Whether the run *after* this one carries `true`, which is what a
        /// slab cut here needs its opening pad for (`bool.rs:988-1002`).
        after_opens_with_true: bool,
    };

    /// The incremental walk over a boolean slab's bytes that a streaming
    /// load drives (`BoolLoadIter`, `bool.rs:751`, `:988-1090`).
    ///
    /// It validates canonical form as it goes, rule for rule the same rule
    /// [`canonicalSlab`] applies: only the opening run may hold no items,
    /// and a run sequence whose first run is a pad alternates from there on
    /// without the pad flipping anything (`bool.rs:784-824`).
    pub const LoadCursor = struct {
        /// The slab being walked, read-only. It is the caller's and must
        /// stay alive and unmodified for as long as the cursor is used;
        /// nothing the cursor returns points into it.
        bytes: []const u8,
        /// The byte offset of the next run header.
        pos: usize,
        /// Items served so far.
        item: usize,
        /// The value the next run carries. A run's value is its position in
        /// the sequence, so this is the parity, not a stored byte.
        value: bool,
        /// Whether the next run is still the opening one.
        first: bool,

        /// A cursor standing at the start of `bytes`. The bytes are only
        /// read, and must stay alive and unmodified for as long as the
        /// cursor is used.
        pub fn init(bytes: []const u8) LoadCursor {
            return .{ .bytes = bytes, .pos = 0, .item = 0, .value = false, .first = true };
        }

        /// Items served so far, which is also the row the next run starts at.
        pub fn items(self: *const LoadCursor) usize {
            return self.item;
        }

        /// The byte offset one past the run last served.
        pub fn bytePos(self: *const LoadCursor) usize {
            return self.pos;
        }

        /// The next run, or null at the end of the input. A run is served
        /// whole, so every step has `last_of_run` set and a value that is
        /// null only for the opening pad. Malformed bytes are
        /// `error.InvalidValue` — a zero-count run anywhere but the opening
        /// pad, or a trailing one — and `error.Overflow` where a count
        /// will not fit a `usize`.
        pub fn next(self: *LoadCursor) ParseError!?Step {
            if (self.pos >= self.bytes.len) return null;
            const c = try leb128.readUnsigned(self.bytes[self.pos..]);
            const end = self.pos + c.len;
            // A zero count anywhere but the opening pad means two
            // neighbouring runs carry the same value and should have been
            // one, and a trailing one means the slab holds nothing at all.
            if (c.value == 0 and (!self.first or end >= self.bytes.len)) return error.InvalidValue;
            const count = std.math.cast(usize, c.value) orelse return error.Overflow;
            const value = self.value;
            self.pos = end;
            self.item = std.math.add(usize, self.item, count) catch return error.Overflow;
            // Only the opening pad stands still; every other run alternates.
            const after_value = if (!self.first or !value) !value else value;
            self.first = false;
            return .{
                .count = count,
                .value = if (count == 0) null else value,
                .kind = if (count == 0) .pad else if (count == 1) .literal else .repeat,
                .last_of_run = true,
                .run_end = end,
                .after_opens_with_true = after_value,
            };
        }
    };

    /// How far a slab's weight advances a prefix sum: zero, because a
    /// boolean column is not a prefix column and its weight carries no
    /// running value.
    pub fn weightIncrement(w: Weight) i64 {
        _ = w;
        return 0;
    }

    /// The column value one wire entry stands for. A boolean column stores
    /// the value itself, so `running` is untouched and the returned value
    /// is the wire entry.
    pub fn valueOfWire(w: Wire, running: *i64) ParseError!Value {
        _ = running;
        return w;
    }

    /// Folds a wire value into a running sum, without realizing it.
    pub fn accumulate(w: Wire, running: *i64) ParseError!void {
        running.* = try addChecked(running.*, @as(i64, @intCast(w)));
    }

    /// The wire entries an insert takes, and the running value behind them.
    /// A boolean column's value is its position in the sequence, so the
    /// wire entries are the values unchanged; the returned slice is the
    /// caller's to release with `gpa`.
    pub fn wireOfInsert(gpa: std.mem.Allocator, running: i64, values: []const Value) ParseError!Inserted(Wire) {
        const out = try gpa.dupe(Wire, values);
        return .{ .wires = out, .running = running };
    }

    /// The wire entry one value takes, and the running value it leaves
    /// behind. A boolean column's value is its position in the sequence, so
    /// the wire *is* the value and nothing moves.
    pub fn wireOfOne(running: i64, v: Value) ParseError!struct { wire: Wire, running: i64 } {
        return .{ .wire = v, .running = running };
    }

    /// Nothing to re-anchor: a boolean column stores the value itself, so
    /// no wire entry is measured against a running value. Always null, and
    /// the column's re-anchor step reads that as "no row to fix".
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
///
/// # What the column owns
///
/// * **The allocator is borrowed.** `deinit` releases what was allocated in
///   it and leaves the allocator itself alone.
/// * **A copy is a second owner of everything.** Zig has no move semantics,
///   so `var b = a;` gives two columns that both free the same slabs. Move a
///   column by pointer, or hand it back through a call that returns it.
/// * **A slab handed to the column is taken by value.** `fromWeights` and
///   `initWithBudget`'s loaders move slab lists in and leave the caller's
///   copy empty; a slab built by the caller with a different allocator is
///   freed by [`deinit`](Column.deinit) with the column's.
/// * **The allocator moves with the contents** through
///   [`remap`](Column.remap) and [`swapContents`](Column.swapContents), so
///   ask [`allocator`](Column.allocator) again after either.
/// * **Not thread-safe.** A column, its slabs and its index are one mutable
///   state with no synchronisation.
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
        /// The default run budget one slab may hold. A column may be built
        /// with another (`Column::initWithBudget`,
        /// `LoadOpts::withMaxSegments`); this is what `init` and `load`
        /// use, and it is unchanged from the budget the port has always
        /// used, so every existing slab layout and every golden byte is the
        /// same one.
        pub const max_segments: usize = default_max_segments;

        const Tree = btree.Tree(Weight);
        const identity = Weight.Aggregate.identity;

        /// The allocator every slab, the index and the weight array live
        /// in. It is not the column's to release: `deinit` gives back what
        /// was allocated here and leaves the allocator alone.
        ///
        /// It moves with the contents. [`remap`](Column.remap) and
        /// [`swapContents`](Column.swapContents) hand a column's storage to
        /// another allocator, so a value of `allocator()` taken before
        /// either call names a different allocator afterwards.
        gpa: std.mem.Allocator,
        /// The encoded slabs, in column order. Every entry's `data` belongs
        /// to `gpa`.
        slabs: std.ArrayList(Slab),
        /// The positional index: one weight per slab, answered in O(log S).
        tree: Tree,
        /// How many values the slabs hold together. It is the count
        /// `len` reports, and it is updated with the slabs it describes —
        /// every mutation that can fail stages what it needs first, so a
        /// refused mutation leaves both describing the column as it was.
        total_len: usize,
        /// The merged weight of the slabs before each slab, plus one slot
        /// for the whole column. Only a codec whose weight carries a prefix
        /// keeps it: that is a slab's base, in O(1).
        agg_before: std.ArrayList(Weight),
        /// The run budget one slab of *this* column may hold. Upstream's
        /// `Column::max_segments` is a field set by `with_max_segments`
        /// (`column.rs:1121-1135`) and read by every split, merge and copy
        /// decision; a `pub const` cannot be that.
        budget: usize,
        /// Bumped by every mutation, so a suspended cursor can tell that
        /// the column it was reading has been written since
        /// (`IterState::try_resume`, `column.rs:807-820`). It is compared,
        /// never interpreted, so one `usize` that only ever goes up is
        /// enough.
        counter: usize,

        /// Set only on the provisional column a [`StagedSplice`] builds:
        /// what the stage owns, and which slabs its rebuild detached while
        /// their buffers stayed the real column's. `null` on every ordinary
        /// column, and every check against it is a pointer test on a path a
        /// plain splice runs once per slab it rewrites.
        staging: ?*Staging = null,

        /// A column with no values and no slabs, on the default run
        /// budget.
        pub fn init(gpa: std.mem.Allocator) ParseError!Self {
            return initWithBudget(gpa, max_segments);
        }

        /// A column with no values and no slabs, holding at most
        /// `budget` runs per slab (`Column::with_max_segments`,
        /// `column.rs:1121-1126`).
        ///
        /// Upstream asserts `budget >= 2`, because its loader halves the
        /// budget to find a cut point and its splices refuse a slab over the
        /// budget, so a budget below two builds a column that panics on its
        /// next write. This port refuses it up front instead: the same
        /// check, the same message's worth of meaning, and an untrusted
        /// caller gets an error rather than a crash (`ParseError` is what
        /// every other boundary in this file reports).
        pub fn initWithBudget(gpa: std.mem.Allocator, budget: usize) ParseError!Self {
            if (budget < 2) return error.InvalidValue;
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
                .budget = budget,
                .counter = 0,
            };
        }

        /// The run budget one slab of this column may hold. The same number
        /// `with_max_segments` would have been given.
        pub fn maxSegmentsOf(self: *const Self) usize {
            return self.budget;
        }

        /// Frees every slab, the index and the weight array. The allocator
        /// itself is the caller's and is not released.
        pub fn deinit(self: *Self) void {
            for (self.slabs.items) |*s| s.deinit(self.gpa);
            self.slabs.deinit(self.gpa);
            self.tree.deinit();
            self.agg_before.deinit(self.gpa);
            self.* = undefined;
        }

        /// The allocator this column's slabs, index and weight array live
        /// in, and the one `deinit` gives every byte back with. A caller
        /// that hands the column a slab has to be handed this one, or the
        /// column frees it with an allocator it was not taken from.
        ///
        /// It is not stable across [`remap`](Column.remap) or
        /// [`swapContents`](Column.swapContents): both move a column's
        /// storage, allocator and contents together, so a cached copy names
        /// whichever allocator the column held before. Ask again after
        /// either call.
        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.gpa;
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
                    .at = 0,
                    .slab_remaining = 0,
                };
            }
            return .{
                .col = self,
                .slab_idx = 0,
                .dec = try E.WireDecoder.init(self.slabs.items[0].data),
                .items_left = self.total_len,
                .running = self.baseOf(0),
                .at = 0,
                .slab_remaining = self.slabs.items[0].len,
            };
        }

        /// A cursor over the rows in `range`, clamped to the column
        /// (`Column::iter_range`, `column.rs:1384-1421`). O(log S) to
        /// position, then the rows before the start inside its own slab,
        /// then O(1) per row. Allocates nothing.
        ///
        /// An empty range is still *positioned* at its start, decoder and
        /// slab state valid: a window is routinely re-extended later
        /// through `setMax` or `shift`, and an unpositioned cursor would
        /// yield nothing from `next` and break the forward invariant
        /// `advanceToSlab` keeps. Only a start at or past the end of the
        /// data — where there is nothing to sit on — takes the
        /// unpositioned path (`column.rs:1387-1405`).
        pub fn iterRange(self: *const Self, range: RowRange) ParseError!Iterator {
            const window = clampRange(range, self.total_len);
            if (window.start >= self.total_len or self.slabs.items.len == 0) {
                return .{
                    .col = self,
                    .slab_idx = self.slabs.items.len,
                    .dec = try E.WireDecoder.init(&.{}),
                    .items_left = 0,
                    .running = 0,
                    .at = window.start,
                    .slab_remaining = 0,
                };
            }
            const hit = self.locate(window.start);
            var it = Iterator{
                .col = self,
                .slab_idx = hit.slab,
                .dec = try E.WireDecoder.init(self.slabs.items[hit.slab].data),
                .items_left = window.end - window.start,
                .running = self.baseOf(hit.slab),
                .at = window.start,
                .slab_remaining = self.slabs.items[hit.slab].len - hit.in_slab,
            };
            // The rows in front of the window's start inside its own slab
            // belong to the decoder, not to the window: the cursor is
            // placed on `window.start` above and the decoder is walked
            // onto the same row, which is what `iter_range` does — its
            // decoder is advanced by the offset while `pos` stays at
            // `start` (`column.rs:1406-1419`). Skipping instead would
            // move the cursor to `start + offset` and take the offset
            // out of the window's length, which underflows when the
            // offset is the longer of the two.
            try it.skipRows(hit.in_slab);
            return it;
        }

        /// The column's values in `range`, in order. The caller owns the
        /// slice.
        pub fn sliceRange(self: *const Self, gpa: std.mem.Allocator, range: RowRange) ParseError![]T {
            const window = clampRange(range, self.total_len);
            const out = try gpa.alloc(T, window.end - window.start);
            errdefer gpa.free(out);
            var it = try self.iterRange(window);
            var i: usize = 0;
            while (try it.next()) |v| {
                if (i >= out.len) return error.InvalidValue;
                out[i] = v;
                i += 1;
            }
            if (i != out.len) return error.InvalidValue;
            return out;
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

        // ── Runs, scopes, searches and prefix arithmetic ────────────────

        /// One run of this column: `count` copies of `value`.
        pub const Run = RunOf(T);

        /// An adapter over [`Iterator`] that yields runs instead of rows
        /// (`Runs`, `column.rs:773-785`).
        pub const Runs = struct {
            inner: Iterator,

            /// The next run, or null at the end of the window.
            pub fn next(self: *Runs) ParseError!?Run {
                return self.inner.nextRun();
            }

            /// The row the next `next` stands on, which is what the
            /// `Shiftable` kernel needs: a run adapter positions by *row*,
            /// not by run (`shift.rs:170-204`).
            pub fn pos(self: *const Runs) usize {
                return self.inner.pos();
            }

            /// One past the last row this adapter can yield.
            pub fn maxPos(self: *const Runs) usize {
                return self.inner.maxPos();
            }

            /// Truncates the window at `at`.
            pub fn setMax(self: *Runs, at: usize) void {
                self.inner.setMax(at);
            }

            /// Moves the window to `range` and yields the row at its
            /// start (`Runs::shift_next`, `shift.rs:195-198`).
            ///
            /// **The inner `shift`'s error is propagated, not dropped.**
            /// Upstream can write this as two statements because `Iter`'s
            /// `set_max` and `advance_to` both return `()`
            /// (`column.rs:542-545`); this port's `Iterator` is fallible
            /// where upstream's is not, because its decoders are
            /// fallible where upstream's are total over a validated
            /// column. A `void` here is a silently unpositioned cursor: the
            /// caller asks for `5..9`, the reposition fails, and the run it
            /// reads next is whatever the cursor was already standing on.
            pub fn shiftNext(self: *Runs, range: RowRange) ParseError!?Run {
                try self.inner.shift(range);
                return self.next();
            }

            /// Moves the window to `range`, yielding nothing. The
            /// `Shiftable` default the run adapter inherits, which reaches
            /// the inner `Iter` for both halves (`shift.rs:174-198`).
            pub fn shift(self: *Runs, range: RowRange) ParseError!void {
                try self.inner.shift(range);
            }

            /// Advances so the next `next` is the row at `target`.
            pub fn advanceTo(self: *Runs, target: usize) ParseError!void {
                return self.inner.advanceTo(target);
            }

            /// Advances past `amount` rows.
            pub fn advanceBy(self: *Runs, amount: usize) ParseError!void {
                return self.inner.advanceBy(amount);
            }

            /// Consumes through `at`, yielding the run standing there.
            pub fn seekTo(self: *Runs, at: usize) ParseError!?Run {
                try self.inner.advanceTo(at);
                return self.next();
            }

            /// Yields the runs of `windows` in turn
            /// (`Shiftable::ranges`, `shift.rs:87-99`). This is the
            /// adapter `Column::spliceRuns` is fed from when a copy walks
            /// the source run-at-a-time (`column.rs:1571-1574`).
            pub fn ranges(self: Runs, windows: []const RowRange) Ranges(Runs) {
                return Ranges(Runs).init(self, windows);
            }
        };

        /// Whether the column is empty, or every one of its values is
        /// `value` (`Column::is_only`, `column.rs:1429-1443`).
        ///
        /// One run per slab settles it, which is what makes the export
        /// check cheap: the column is read run-at-a-time, and a literal
        /// run of more than one row is by definition not one value.
        pub fn isOnly(self: *const Self, value: T) ParseError!bool {
            for (self.slabs.items, 0..) |s, si| {
                if (s.len == 0) continue;
                const ra = (try E.runAtOrAfter(s.data, 0)) orelse continue;
                const n = if (ra.seg.kind == .literal) 1 else ra.seg.itemCount();
                if (n != s.len) return false;
                // The run carries a *wire* entry, and a delta column's is a
                // difference measured from that slab's own base, so it is
                // realized before it is compared. For every other codec the
                // realization is the identity, and a nullable one hands back
                // its own null rather than being unwrapped away.
                var base = self.baseOf(si);
                const held = try E.valueOfWire(ra.seg.first_value.?, &base);
                if (compareValue(T, held, value) != .eq) return false;
            }
            return true;
        }

        /// `encode`, unless every value is `value` — in which case
        /// nothing is written and `null` comes back
        /// (`Column::save_to_unless`, `column.rs:1447-1453`).
        ///
        /// This is what makes a save write the columns the reference
        /// writes: a nullable column that is all null and a boolean column
        /// that is all false are omitted, while `id_actor`, `insert`,
        /// `action`, `succ_count`, `value_meta` and `value` are saved
        /// whatever they hold (`op_set2/columns.rs:135-169`).
        pub fn encodeUnless(self: *const Self, gpa: std.mem.Allocator, value: T) ParseError!?[]u8 {
            if (try self.isOnly(value)) return null;
            return try self.encode(gpa);
        }

        /// The rows of `range` that carry `value`, as the contiguous run
        /// they form (`Column::scope_to_value`, `column.rs:1495-1506`).
        ///
        /// This is the one that carries the row-order invariant: the op
        /// set's correctness rests on an object's rows being a contiguous
        /// range, and that is exactly what a run of equal `obj_actor`
        /// values *is*. The values in `range` are assumed sorted; if they
        /// are not the answer may be wrong or empty, but nothing panics
        /// and nothing is corrupted (`column.rs:1487-1494`).
        pub fn scopeToValue(self: *const Self, value: T, range: RowRange) ParseError!RowRange {
            var it = try self.iterRange(range);
            return it.sortedScanToValue(value);
        }

        /// The slabs whose realized values can hold `target`
        /// (`Column::find_by_value`, `column.rs:1812-1817`).
        ///
        /// The cursor allocates a stack one frame per tree level, so it
        /// needs `deinit`; the column it walks is untouched. Only a
        /// column whose index weight carries a value range has one — a
        /// delta column, whose weight is `SlabAgg`
        /// (`column.rs:1806-1811`).
        pub fn findByValue(self: *const Self, target: i64) btree.TreeError!btree.FindByValue {
            if (comptime Weight == btree.SlabAgg) {
                return btree.FindByValue.init(&self.tree, target);
            } else {
                @compileError("a value search needs the index weight that carries a value range: a delta column");
            }
        }

        /// The slabs whose realized values overlap `[lo, hi]`
        /// (`Column::find_by_value_range`, `column.rs:1819-1823`).
        ///
        /// `findByValue` with a one-point range, except that a slab
        /// overlapping only at one end is still reported
        /// (`btree.rs:1622-1626`). This is the walk the counter walker
        /// makes over `id_ctr` and `succ_ctr`
        /// (`op_set.rs:830-834`).
        pub fn findByRange(self: *const Self, lo: i64, hi: i64) btree.TreeError!btree.FindByValueRange {
            if (comptime Weight == btree.SlabAgg) {
                return btree.FindByValueRange.init(&self.tree, lo, hi);
            } else {
                @compileError("a value search needs the index weight that carries a value range: a delta column");
            }
        }

        // ── The prefix arithmetic ───────────────────────────────────────

        /// The sum of the row lengths before row `index`
        /// (`PrefixColumn::get_prefix`, `prefix.rs:543-548`).
        ///
        /// `index` may be `len()`, which is the grand total: that is how
        /// the op-set loader sizes the successor columns, whose length is
        /// the prefix sum of `succ_count` (`op_set2/columns.rs:294-300`).
        pub fn getPrefix(self: *const Self, index: usize) ParseError!i64 {
            if (!comptime E.is_prefix_column) return error.Unsupported;
            return self.runningAt(index);
        }

        /// The first row whose *exclusive* prefix — what `getPrefix` is at
        /// that row — reaches `target`
        /// (`PrefixColumn::get_index_for_prefix`, `prefix.rs:600-623`).
        ///
        /// `0` for a non-positive `target` and `len() + 1` for one past
        /// the grand total, which are the two out-of-range answers
        /// upstream gives (`prefix.rs:603-604`).
        pub fn getIndexForPrefix(self: *const Self, target: i64) ParseError!usize {
            if (!comptime E.is_prefix_column) return error.Unsupported;
            if (target <= 0) return 0;
            if (self.isEmpty()) return self.total_len + 1;
            // The index descends by running sum, so the slab the target
            // lands in is one lookup, not a walk.
            const hit = self.tree.findByPrefixSum(E.weightIncrement, target);
            if (hit.slab >= self.slabs.items.len) return self.total_len + 1;
            const remaining = std.math.sub(i64, target, hit.prefix_before) catch return error.Overflow;
            return hit.items_before + try findPrefixInSlab(E, &self.slabs.items[hit.slab], remaining);
        }

        /// The row whose *inclusive* prefix first reaches `target` — the
        /// inverse of `getPrefix` (`PrefixColumn::get_index_for_total`,
        /// `prefix.rs:592-598`).
        pub fn getIndexForTotal(self: *const Self, target: i64) ParseError!usize {
            return try self.getIndexForPrefix(target) -| 1;
        }

        /// The sum of the row lengths in `range`
        /// (`PrefixColumn::sum_range`, `prefix.rs:573-583`).
        pub fn sumRange(self: *const Self, range: RowRange) ParseError!i64 {
            if (!comptime E.is_prefix_column) return error.Unsupported;
            if (range.start >= range.end or self.isEmpty()) return 0;
            const lo = self.getPrefix(range.start) catch return error.Overflow;
            const hi = self.getPrefix(range.end) catch return error.Overflow;
            return std.math.sub(i64, hi, lo) catch return error.Overflow;
        }

        /// A value paired with the running sum through it
        /// (`PrefixedValue`, `prefix.rs:699-720`).
        ///
        /// The two views of the accumulator are named so the
        /// inclusive/exclusive distinction cannot be missed: `prefix()` is
        /// the sum *before* this row, `total()` the sum *through* it. With
        /// unit widths `[1, 1, 1]` the row at 1 has `prefix() == 1` and
        /// `total() == 2`, and a byte-offset column reads naturally as
        /// `pv.prefix()..pv.total()` (`prefix.rs:686-694`).
        pub const PrefixedValue = struct {
            /// The row's own value: its length, for a prefix column.
            value: T,
            /// The running sum through this row, inclusive. The field is
            /// named for what it holds; `total()` is the accessor, so a
            /// call site reads the way upstream's does.
            sum: i64,

            /// The running sum through this row, inclusive
            /// (`prefix.rs:708-710`).
            pub fn total(self: PrefixedValue) i64 {
                return self.sum;
            }

            /// The running sum of the rows before this one, exclusive —
            /// `total()` less this row's own contribution
            /// (`prefix.rs:715-719`).
            pub fn prefix(self: PrefixedValue) i64 {
                return self.sum - prefixUnit(T, self.value);
            }
        };

        /// The result of a seek on a [`PrefixIter`]
        /// (`PrefixSeek`, `prefix.rs:361-376`). After the call the cursor
        /// stands at `pos + 1`, ready to yield the rows behind it.
        pub const PrefixSeek = struct {
            /// The row landed on.
            pos: usize,
            /// The prefix consumed over `[from, to)`, exclusive of the
            /// row landed on.
            delta: i64,
            /// The row itself, with its absolute running sums.
            pv: PrefixedValue,
        };

        /// A forward cursor over a prefix column, carrying the running
        /// sum (`PrefixIter`, `prefix.rs:751-1020`).
        ///
        /// This is the load-bearing piece of a prefix column: a row's
        /// length is the prefix sum of the row before it, so the offset of
        /// any row is one lookup and a walk of a single slab's runs — which
        /// is what makes a single-column sequence walk O(1) per row
        /// instead of O(rows). A value is a value, but here it is a
        /// *length*, and everything the op set asks about a sequence is a
        /// question about lengths.
        pub const PrefixIter = struct {
            col: *const Self,
            inner: Iterator,
            /// The running sum of everything consumed so far, which is
            /// the exclusive prefix of the row `next` would yield.
            sum: i64,
            /// Subtracted from the column's absolute prefixes, and **zero
            /// until [`resetPrefix`](column.zig) says otherwise**
            /// (`prefix.rs:751-757`, `:882-887`). The invariant is
            /// `sum == absolute prefix at pos - base`.
            ///
            /// **It is not the window's offset.** Upstream's `iter_range`
            /// is `iter()` plus `advance_by(start)` (`prefix.rs:668-676`),
            /// and `advance_by` accumulates into `total`, never into
            /// `base` — so a window opened at `s` reports *absolute*
            /// sums, and `base` is still zero (`prefix.rs:903-907`).
            base: i64,

            /// The next value with its running sums, or null at the end of
            /// the window. O(1).
            pub fn next(self: *PrefixIter) ParseError!?PrefixedValue {
                const v = (try self.inner.next()) orelse return null;
                self.sum = try addChecked(self.sum, prefixUnit(T, v));
                return .{ .value = v, .sum = self.sum };
            }

            /// The value `n` rows ahead, with its running sums, or null
            /// past the end of the window. O(log S): a jump that leaves
            /// the current slab reads the absolute prefix back from the
            /// column, which is the only place it lives; a jump inside
            /// one walks its runs and adds each (`prefix.rs:810-836`).
            pub fn nth(self: *PrefixIter, n: usize) ParseError!?PrefixedValue {
                if (n >= self.inner.items_left) {
                    if (self.inner.items_left > 0) _ = try self.nth(self.inner.items_left - 1);
                    return null;
                }
                // A jump inside the current slab is walked run at a time,
                // and every run it crosses is added to the sum: the rows
                // in front of the target are consumed, so their widths
                // are part of the sum the target is reported with
                // (`same_slab_nth`, `prefix.rs:818-821` and
                // `prefix.rs:847-859`).
                if (n < self.inner.slab_remaining) return self.sameSlabNth(n);
                // A jump that leaves the slab reads the absolute prefix
                // back from the column, which is the only place it lives
                // (`prefix.rs:831-833`).
                const absolute = try self.col.runningAt(self.inner.at + n);
                self.sum = std.math.sub(i64, absolute, self.base) catch return error.Overflow;
                const v = (try self.inner.nth(n)) orelse return null;
                self.sum = try addChecked(self.sum, prefixUnit(T, v));
                return .{ .value = v, .sum = self.sum };
            }

            /// The value `n` rows ahead inside the current slab, with the
            /// sum carried over every run the jump crosses
            /// (`same_slab_nth`, `prefix.rs:847-859`). One step per run,
            /// which is what makes an in-slab `nth` cheaper than a row
            /// walk; `null` when the slab has no run left, which the
            /// caller's `n < slab_remaining` does not allow.
            fn sameSlabNth(self: *PrefixIter, n: usize) ParseError!?PrefixedValue {
                var left = n;
                while (try self.inner.nextRunMax(left + 1)) |run| {
                    const each = prefixUnit(T, run.value);
                    const span = std.math.mul(i64, each, @as(i64, @intCast(run.count))) catch return error.Overflow;
                    self.sum = try addChecked(self.sum, span);
                    if (run.count > left) return .{ .value = run.value, .sum = self.sum };
                    left -= run.count;
                }
                return null;
            }

            /// The next run of equal values, described by its *final* row:
            /// `pv.total()` is the sum through the end of the run
            /// (`prefix.rs:935-947`).
            pub fn nextRun(self: *PrefixIter) ParseError!?RunOf(PrefixedValue) {
                const run = (try self.inner.nextRun()) orelse return null;
                const each = prefixUnit(T, run.value);
                const span = std.math.mul(i64, each, @as(i64, @intCast(run.count))) catch return error.Overflow;
                self.sum = try addChecked(self.sum, span);
                return .{ .count = run.count, .value = .{ .value = run.value, .sum = self.sum } };
            }

            /// This cursor as a run iterator over plain values, the prefix
            /// sums dropped (`prefix.rs:929-933`).
            pub fn runs(self: PrefixIter) Runs {
                return .{ .inner = self.inner };
            }

            /// Yields the rows of `windows` in turn, keeping the absolute
            /// prefix totals across the window jumps
            /// (`Shiftable::ranges`, `shift.rs:142-154`).
            ///
            /// The running sum belongs to the column, not to the window,
            /// so a jump forward keeps accumulating from where the previous
            /// window stopped rather than restarting.
            pub fn ranges(self: PrefixIter, windows: []const RowRange) Ranges(PrefixIter) {
                return Ranges(PrefixIter).init(self, windows);
            }

            /// The row the next `next` stands on.
            pub fn pos(self: *const PrefixIter) usize {
                return self.inner.pos();
            }

            /// The running sum of everything consumed so far — the
            /// exclusive prefix of the row `next` would yield. Right
            /// after `prefixIterRange` it is already the prefix at the
            /// range's start, paid for by the construction's descent
            /// (`prefix.rs:866-873`).
            pub fn prefix(self: *const PrefixIter) i64 {
                return self.sum;
            }

            /// `prefix`, under the name upstream's `total()` gives it:
            /// the sum through the last row consumed.
            pub fn total(self: *const PrefixIter) i64 {
                return self.sum;
            }

            /// Zeros the running sum where the cursor stands, without
            /// moving it, so the sums it reports from here on are relative
            /// to this row (`prefix.rs:875-887`).
            pub fn resetPrefix(self: *PrefixIter) void {
                self.base = std.math.add(i64, self.base, self.sum) catch self.base;
                self.sum = 0;
            }

            /// How many rows are left in the window.
            pub fn itemsLeft(self: *const PrefixIter) usize {
                return self.inner.items_left;
            }

            /// One past the last row this cursor can yield.
            pub fn maxPos(self: *const PrefixIter) usize {
                return self.inner.maxPos();
            }

            /// Truncates the window at `pos`. It can shorten the window
            /// and extend it again; a `pos` past the end of the data
            /// simply stops the cursor there
            /// (`Iter::set_max`, `column.rs:505-512`).
            pub fn setMax(self: *PrefixIter, at: usize) void {
                self.inner.setMax(at);
            }

            /// Advances so the next `next` is the row at `target`. A
            /// target at or behind the cursor is a no-op, which is what
            /// makes `shift` usable on a cursor that is already in the
            /// range (`PrefixIter::advance_to`, `prefix.rs:951-956`).
            ///
            /// **It goes through `nth`, not through the inner cursor's
            /// `advanceTo`.** Upstream's `PrefixIter` has an `advance_to`
            /// of its own and it accumulates, because every row it skips
            /// over is part of the sum the next `total()` reports; the
            /// inner `Iter::advance_to` (`column.rs:531-535`) moves the
            /// window and nothing else, and a `PrefixIter` that delegated
            /// to it left its accumulator behind at zero.
            pub fn advanceTo(self: *PrefixIter, target: usize) ParseError!void {
                const here = self.pos();
                if (target > here) _ = try self.nth(target - here - 1);
            }

            /// Advances past `amount` rows, **adding every width it skips
            /// to the running sum** (`PrefixIter::advance_by`,
            /// `prefix.rs:903-907`).
            ///
            /// This is `nth(amount - 1)` and not the inner
            /// `Iter::advance_by` (`column.rs:547-549`): upstream spells
            /// both, and only this one accumulates. `amount` of zero is a
            /// no-op rather than an `nth(-1)`.
            pub fn advanceBy(self: *PrefixIter, amount: usize) ParseError!void {
                if (amount > 0) _ = try self.nth(amount - 1);
            }

            /// Repositions the window to `range`: the cursor yields the
            /// rows in it and then stops (`PrefixIter::shift`,
            /// `prefix.rs:962-965`; the same two halves
            /// `shift.rs:50-55`).
            pub fn shift(self: *PrefixIter, range: RowRange) ParseError!void {
                self.setMax(range.end);
                try self.advanceTo(range.start);
            }

            /// Repositions the window to `range` and returns the row at
            /// its start, in one step rather than a reposition and a
            /// `next` (`shift.rs:59-63`).
            pub fn shiftNext(self: *PrefixIter, range: RowRange) ParseError!?PrefixedValue {
                if (range.start < self.inner.at) return error.InvalidValue;
                self.setMax(range.end);
                return self.nth(range.start - self.inner.at);
            }

            /// Consumes through `at`, returning the row there. `null`
            /// when `at` is behind the cursor, which cannot happen to a
            /// well-formed window (`shift.rs:68-74`).
            pub fn seekTo(self: *PrefixIter, at: usize) ParseError!?PrefixedValue {
                if (at < self.inner.at) return null;
                return self.nth(at - self.inner.at);
            }

            /// The row `n` rows ahead, with the prefix consumed over
            /// `[pos, pos + n)` as `delta` (`PrefixIter::delta_nth`,
            /// `prefix.rs:973-982`).
            pub fn deltaNth(self: *PrefixIter, n: usize) ParseError!?PrefixSeek {
                const from = self.sum;
                const pv = (try self.nth(n)) orelse return null;
                return .{
                    .pos = self.inner.at - 1,
                    .delta = std.math.sub(i64, pv.prefix(), from) catch return error.Overflow,
                    .pv = pv,
                };
            }

            /// The row at `from` together with the prefix consumed over
            /// `[from, to)` (`PrefixColumn::delta`, `prefix.rs:558-569`).
            /// `null` when `to` is behind `from`.
            pub fn delta(self: *PrefixIter, from: usize, to: usize) ParseError!?PrefixSeek {
                if (to < from) return null;
                try self.advanceTo(from);
                return self.deltaNth(to - from);
            }

            /// Advances *past* `n` prefix units and returns the row landed
            /// on — the row that holds unit `n + 1`
            /// (`PrefixIter::advance_prefix`, `prefix.rs:985-1019`).
            ///
            /// The boundary is load-bearing and automerge's text indexing
            /// depends on it: with unit widths `[1, 1, 1]`,
            /// `advancePrefix(0)` lands on row 0 and `advancePrefix(1)`
            /// lands on row **1**, because passing row 0's single unit
            /// lands past it. A row whose cumulative sum is exactly `n` is
            /// skipped, not returned (`prefix.rs:990-996`).
            pub fn advancePrefix(self: *PrefixIter, n: i64) ParseError!?PrefixSeek {
                if (!comptime E.is_prefix_column) return error.Unsupported;
                // The index works in absolute prefixes, so a reset
                // offset is undone before the seek (`prefix.rs:1004-1006`).
                const here = std.math.add(i64, self.sum, self.base) catch return error.Overflow;
                const want = std.math.add(i64, here, n) catch return error.Overflow;
                const seek = std.math.add(i64, want, 1) catch return error.Overflow;
                const row = try self.col.getIndexForTotal(seek);
                if (row < self.inner.at or row >= self.inner.maxPos()) {
                    if (self.inner.items_left > 0) _ = try self.nth(self.inner.items_left - 1);
                    return null;
                }
                return self.deltaNth(row - self.inner.at);
            }
        };

        /// A cursor over every row with its running prefix sum
        /// (`PrefixColumn::iter`, `prefix.rs:658-666`).
        pub fn prefixIter(self: *const Self) ParseError!PrefixIter {
            if (!comptime E.is_prefix_column) return error.Unsupported;
            const whole = try self.iterator();
            return .{
                .col = self,
                .inner = whole,
                .sum = 0,
                .base = try self.getPrefix(0),
            };
        }

        /// A cursor over the rows of `range` with their running prefix
        /// sums, **starting already paid for**: `total()` is the prefix at
        /// `range.start` before the first `next`
        /// (`PrefixColumn::iter_range`, `prefix.rs:668-676`).
        ///
        /// **`iter()` then `setMax(end)` then `advanceBy(start)`, and the
        /// order is the behaviour.** Upstream builds the whole-column
        /// cursor and *accumulates* the skipped widths into `total`
        /// (`advance_by`, `prefix.rs:903-907`), so every sum this hands
        /// back is **absolute** — the prefix at `range.start`, and the
        /// running total through each row after it. A consumer therefore
        /// subtracts `base` from a sum rather than reading an offset out of
        /// it, which is upstream's own `op_set2/op_set.rs:976` and `:995`.
        /// Parking that same number in `base` instead and leaving `sum` at
        /// zero answers the same questions in a *window-relative* space,
        /// which is a different answer and one no upstream caller is
        /// written against.
        ///
        /// **A window-relative variant was patched here once and removed on
        /// 2026-10-01; bringing it back takes two edits and this note.**
        /// Here: `it.base = try self.getPrefix(start)` and `it.sum = 0`
        /// after the `advanceBy`, which is the whole of it — the cursor's
        /// position and its window were always upstream's, so only the sums
        /// moved. In `src/opset/op_set.zig`: `OpSet.calculateMarks`'s
        /// compensation, which took `seq_base` from `getPrefix` and read
        /// the cursor's sums as object-relative. The symptom it had is worth
        /// stating, because it was not a wrong number but a refusal: with
        /// the sums relative, `pv.prefix()` is 0 at the start of every
        /// window, so `cast(usize, 0 - base)` is `error.Overflow` for every
        /// object that does not begin at column row 0 — 23 tests across
        /// `op_set`, `read`, `sync`, `doc`, `transaction` and `cursor`.
        /// Pinned in both directions: `test "prefix_iter_proptest"`
        /// ([`column.zig`](column.zig)) holds the absolute sums, and
        /// `src/opset/op_set.zig`'s mark tests hold the subtraction.
        pub fn prefixIterRange(self: *const Self, range: RowRange) ParseError!PrefixIter {
            if (!comptime E.is_prefix_column) return error.Unsupported;
            const start = @min(range.start, self.total_len);
            const end = @min(range.end, self.total_len);
            var it = try self.prefixIter();
            it.setMax(end);
            try it.advanceBy(start);
            return it;
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

        /// Builds a second column in which every value has been through `f`,
        /// and leaves this one exactly as it was. This is the borrowed half of
        /// [`remap`](Column.remap), and the one implementation both of them
        /// are made of: `remap` publishes the result over the receiver, and
        /// `Columns::remapActors` has to stage four columns before it can
        /// publish any of them (`op_set2/columns.rs:332-348`).
        ///
        /// **One `f` call per run, and the values are laid out per row.** The
        /// walk is run-at-a-time, so a repeat run is mapped by a single call
        /// rather than one per copy (`encoding.rs:66-86`,
        /// `column.rs:1263-1273`), and a run that maps to one value stays one
        /// run. The *copying* behind that is per row: the mapped value is
        /// filled into a fixed 256-element stack buffer once per row and the
        /// buffer is handed to `extend` once per 256 rows, so the rebuild is
        /// O(rows) writes and O(rows / 256) extensions whatever the run
        /// lengths are.
        ///
        /// **`f` is handed one borrowed value per run, and a row is never
        /// what it is handed.** `ctx` comes through unchanged; the value is
        /// the run's, read out of the source's slab. For a `T` that carries a
        /// payload — `[]const u8` over `RleUtf8` or `Rle([]const u8)` — that
        /// value *is* a window on the slab's own bytes rather than a copy of
        /// them (`rle.zig:117-120`: a payload read is a window on the encoded
        /// bytes), so `f` must not retain it past the walk and must not hand
        /// back a window into memory it does not own.
        ///
        /// **What `f` returns is read again later.** The result of a call may
        /// sit in the stack buffer across further calls and is only copied
        /// into the result column when that buffer is flushed, so a returned
        /// slice or pointer must stay readable until then — long enough to
        /// cover the rest of the walk, not just the call. `f` must not write
        /// to the source column or re-enter this method while the walk is
        /// running: the iterator and the slab the run's value names are both
        /// live across the loop.
        ///
        /// **The result is the caller's column.** It is built in `gpa`, it is
        /// released by `deinit` with `gpa`, and it is held on **this column's
        /// own run budget** — `maxSegmentsOf` of the source and of the result
        /// answer the same number — so a staged column is byte for byte the
        /// one `remap` would have installed.
        ///
        /// **The source is untouched on both paths.** Nothing here writes it,
        /// and a refusal — `error.OutOfMemory` from the new column or from a
        /// flush, or an encoding refusal from a value `f` produced — frees the
        /// partial result before the error leaves, so neither side keeps
        /// residue: the caller holds the same whole column it handed in, and
        /// can read it, remap it again or `deinit` it exactly as it would have
        /// without this call.
        ///
        /// **What it costs.** One pass over the rows, one `f` call per run,
        /// a fixed 256-element stack buffer, and the result's own storage —
        /// which is a **whole second column**, materialised in `gpa` before
        /// this returns, so the peak is the source and the finished result
        /// both live. That is what `remap` costs too, because the result is
        /// the column that gets installed. What it does *not* cost is a copy
        /// of the source: it is read, never cloned, so the source's own bytes
        /// are not duplicated to keep the input intact — which is what lets a
        /// caller stage four columns at once and pay that peak four times over
        /// instead of paying for four source copies as well.
        ///
        /// **The result's counter is the result's own**: `initWithBudget`
        /// starts it at zero and every flush of the 256-element buffer bumps
        /// it once, so it counts this build's writes and says nothing about
        /// the column the result replaces. Installing it in place of a live
        /// column is the caller's step, and so is invalidating the cursors
        /// over the rows it replaces:
        /// `remap` keeps the receiver's counter and adds one, and
        /// `Columns::remapActors` publishes through
        /// [`swapContents`](Column.swapContents), which moves both counters
        /// past either column's. A caller that installs a result any other way
        /// has to do that itself, or an [`IterState`](Column.IterState) taken
        /// over the old rows may resume against the new ones.
        pub fn remapped(
            self: *const Self,
            gpa: std.mem.Allocator,
            ctx: anytype,
            comptime f: fn (@TypeOf(ctx), T) T,
        ) ParseError!Self {
            var src = try self.iterator();
            var out = try Self.initWithBudget(gpa, self.budget);
            errdefer out.deinit();
            // Big enough that a run of ordinary rows is one splice, small
            // enough that the staging buffer is a stack frame.
            var buf: [256]T = undefined;
            var held: usize = 0;
            // **The flushes go through the private mutating core, not
            // [`extend`](Column.extend).** `out` is a local this function
            // owns whole — nothing else names it and the `errdefer` gives it
            // back — so the atomicity [`splice`](Column.splice) buys by
            // staging the column beside itself buys nothing here, and costs a
            // copy of `out`'s slab list and a copy of its index on every
            // flush. The core is the same splice either way: same rows, same
            // encoding, same run budget, one counter bump per flush. A
            // refusal leaves `out` holding part of the result and the error
            // leaves through the `errdefer` that frees it; the borrowed source
            // is not touched on any path.
            while (try src.nextRun()) |run| {
                const mapped = f(ctx, run.value);
                // A run that maps to one value stays one run: the whole
                // point of walking runs rather than rows
                // (`encoding.rs:80-85`).
                var left = run.count;
                while (left != 0) {
                    const room = @min(left, buf.len - held);
                    for (buf[held..][0..room]) |*slot| slot.* = mapped;
                    held += room;
                    left -= room;
                    if (held == buf.len) {
                        try out.spliceInPlace(gpa, out.total_len, 0, &buf);
                        held = 0;
                    }
                }
            }
            if (held != 0) try out.spliceInPlace(gpa, out.total_len, 0, buf[0..held]);
            return out;
        }

        /// Replaces the column with a re-encoded copy in which every value
        /// has been through `f` (`Column::remap`, `column.rs:1263-1273`).
        ///
        /// The rewrite itself is [`remapped`](Column.remapped) — the same
        /// borrowed build the op set's four-column stage is made of — and this
        /// is the publishing half of it: **every byte the receiver holds
        /// survives until the new column has been built in full**, so a
        /// refusal returns with the column exactly as it was.
        ///
        /// `ctx` is passed to `f` unchanged, so a closure over the shift or
        /// the table is a plain pointer, and `f` sees one borrowed value per
        /// run.
        ///
        /// **The column adopts `gpa`.** The re-encoded copy is built in it
        /// and takes the receiver's place, so afterwards the column's slabs,
        /// its index and its bases all live in `gpa` and `deinit` gives them
        /// back with it. `gpa` need not be the allocator the column was
        /// built with — building a column into an arena is the reason the
        /// parameter exists — but a value of
        /// [`allocator`](Column.allocator) taken before this call names a
        /// different allocator afterwards, so ask again rather than reusing
        /// it on a slab taken from the column.
        ///
        /// The run budget and the suspension counter are the receiver's own
        /// and do not travel with the contents: the budget is the number the
        /// result was built with, and the counter is the receiver's plus one.
        /// A remap rewrites the rows and keeps every guarantee the column
        /// already made, while a cursor suspended over the old rows has been
        /// invalidated by it and cannot resume against the new ones.
        pub fn remap(
            self: *Self,
            gpa: std.mem.Allocator,
            ctx: anytype,
            comptime f: fn (@TypeOf(ctx), T) T,
        ) ParseError!void {
            const out = try self.remapped(gpa, ctx, f);
            // The mapping is total — every value comes back through `f`, in
            // the source's order — so the new column has the same rows in the
            // same order and the same length, with every value *mapped*: only
            // the encoding and the values differ, never the shape. The swap
            // is what upstream's `*self = remap(..)` does (`column.rs:1272`).
            // The budget is the result's own — it was built with the
            // receiver's — so the counter is the only thing carried across by
            // hand, and `+% 1` past the receiver's is what stops a cursor
            // suspended over the rows this replaces.
            const counter = self.counter +% 1;
            self.deinit();
            self.* = out;
            self.counter = counter;
        }

        /// Replaces the values `[index, index + del)` with `values`. This is
        /// what a remote change does when it inserts rows, so every boundary
        /// is a real case: an empty column, a splice at either end, a
        /// splice that removes everything, and a splice that spans slabs.
        ///
        /// **Every return leaves the column exactly as it was.** Not merely a
        /// column that still describes itself: the same values, the same
        /// `len`, the same slab list, the same index, the same per-slab
        /// bases, the same allocator and the same suspension counter. The
        /// write is [`stageSplice`](Column.stageSplice) followed by
        /// [`publish`](Column.StagedSplice.publish) — the same splice runs
        /// against a provisional column whose slab list shares this one's
        /// buffers, and the publish is the one step that cannot be refused.
        ///
        /// **Why the seam and not a reservation.** The rebuild publishes the
        /// cut's bytes before the last step that allocates. `settle` splits
        /// the rebuilt slab at the run budget and coalesces the neighbours of
        /// the rebuilt range, and both take their room from `reserveSlabs`
        /// before the first byte moves, so neither can fail after the list has
        /// moved. The index rebuild behind them cannot: `reindexFrom` hands
        /// the new list to `Tree.splice`, which grows nodes and leaf buffers
        /// out of the tree's own arena (`btree.zig:402-416`, `:422-439`), and
        /// that arena is not the column's to reserve. A column that reserved
        /// everything it could reach would still be refused there, holding
        /// new slabs against an index that describes the old ones — which is
        /// what a caller reads afterwards. Staging puts that step on a column
        /// whose refusal costs nothing.
        ///
        /// **What it costs.** One shallow copy of the slab list and one copy
        /// of the index — both proportional to the slab count, the same order
        /// as the per-splice cache rebuilds this write already ran — plus one
        /// copy of each slab the cut re-encodes, and that one is bounded by
        /// the run budget. It is a fixed price per call, not per value:
        /// [`extend`](Column.extend) and [`remapped`](Column.remapped) hand a
        /// whole run to one splice.
        ///
        /// **`gpa` must be this column's own** —
        /// [`allocator`](Column.allocator), the value `deinit` releases it
        /// with. The write is made there whatever `gpa` says, because the
        /// slabs, the index and the bases of a published stage move with the
        /// contents; passing a second allocator would already have mixed two
        /// inside one splice, so it is refused by assertion rather than
        /// honoured — on the allocator's vtable, which is the whole of the
        /// identity an allocator can be compared on; the body says exactly
        /// what that does and does not separate. This is the same rule as
        /// [`remap`](Column.remap), and for the same reason: the allocator
        /// moves with the storage, so it is named once at the boundary rather
        /// than chosen per write.
        ///
        /// `index + del` past the end is `error.InvalidValue`, matching
        /// upstream's out-of-bounds assertion (`column.rs:1773`).
        ///
        /// A length that does not fit `usize` is `error.Overflow`, from the
        /// stage's own count of what publishing would produce.
        pub fn splice(
            self: *Self,
            gpa: std.mem.Allocator,
            index: usize,
            del: usize,
            values: []const T,
        ) ParseError!void {
            // **The write is made in the column's own allocator.** The stage,
            // and everything it builds, come out of — and go back into — the
            // allocator [`deinit`](Column.deinit) releases the column with,
            // which is the one `reserveSlabs` and the two cache rebuilds
            // already spend and the one `deinit` already frees. `gpa` names
            // that allocator and must be this column's own: a caller that
            // passed a different one was already mixing allocators inside a
            // single splice, so this is a statement of the precondition rather
            // than a relaxation of it. It is an assertion because a mismatch is
            // a programmer error and not a condition to answer, and it is
            // compiled out of `ReleaseFast` — the duty is the caller's there.
            //
            // **The vtable, and only the vtable.** That is the identity a
            // `std.mem.Allocator` can be compared on: `ptr` is `undefined` for
            // every stateless allocator std ships — `page_allocator`,
            // `c_allocator`, `smp_allocator`, `brk_allocator` — so reading it
            // to compare two of them is undefined behaviour and can fold to
            // `false` under optimisation. The vtable is a static pointer in
            // every allocator, so it names the implementation exactly. What it
            // does not separate is two *instances* of one implementation,
            // which was already a hazard before this write existed and is not
            // what this seam introduces.
            std.debug.assert(gpa.vtable == self.gpa.vtable);
            var stage = try self.stageSplice(index, del, values);
            // A no-op in either direction: `publish` spends the stage, and a
            // `deinit` after a publish is documented as a no-op rather than
            // a second free.
            defer stage.deinit();
            stage.publish(self);
        }

        /// The splice itself: rebuild the cut range in this column and bring
        /// the two caches back into step.
        ///
        /// **A refusal is only survivable on a provisional column.** The
        /// rebuilt range goes into the slab list before `settle` runs, and
        /// `settle`'s coalescing and index rebuild are the steps that
        /// allocate after that — so a refusal in either leaves a column
        /// holding new slabs against an index that describes the old ones.
        /// [`splice`](Column.splice) is therefore this plus a publish, and
        /// this runs only on the provisional column a
        /// [`StagedSplice`](Column.StagedSplice) builds, which a refusal
        /// discards whole.
        fn spliceInPlace(
            self: *Self,
            gpa: std.mem.Allocator,
            index: usize,
            del: usize,
            values: []const T,
        ) ParseError!void {
            if (index > self.total_len or del > self.total_len - index) return error.InvalidValue;
            if (del == 0 and values.len == 0) return;
            // A suspended cursor names the column it was reading, and a
            // write can move the row it stands on under it. The counter is
            // what `tryResume` compares, so it is bumped here — at the one
            // place every row-level write passes through, rather than in
            // the slab machinery a caller never sees. On the provisional
            // column this bump is carried out by the stage's own counter,
            // which `publish` installs.
            self.counter +%= 1;
            if (self.slabs.items.len == 0) {
                try self.slabs.append(gpa, .empty);
                self.stagedGrew(self.slabs.items.len - 1, 0, 1);
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
        }

        // ── The staged splice ───────────────────────────────────────────

        /// What a staged splice owns on a provisional column: one flag per
        /// slab of that column's list, and the slabs the rebuild took out of
        /// the list without owning their buffers.
        ///
        /// The provisional column is a real `Column(T, E)` — that is what
        /// makes a staged splice the *same* splice, merge policy, split and
        /// re-anchor included, rather than a second implementation of it.
        /// What it is not is a copy: its slab list starts as struct copies of
        /// the real one's, sharing every buffer. A stage only ever re-encodes
        /// the range the cut covers, plus whichever neighbour the merge
        /// policy reaches for — so the work is O(the cut and the slabs in
        /// the index), never O(the values).
        const Staging = struct {
            /// One flag per slab, the same length as the provisional list:
            /// true when this stage owns that slab's buffer, false when the
            /// buffer is still the original column's. A slab the provisional
            /// column made for itself has no flag and counts as owned.
            owned: std.ArrayList(bool),
            /// Slabs the original column named and the provisional list no
            /// longer does — either dropped outright, or overwritten in place
            /// by a copy the stage made. **Both spellings of "no longer
            /// named" matter**, and both end here: after the provisional list
            /// stops naming a slab, only the original column's own list still
            /// does, and a publish is exactly the moment that list goes away.
            /// So an abort must leave these alone — the column still holds
            /// them, and this list releases only its own buffer — and a
            /// publish must free them, once each, because the column's own
            /// list is about to stop naming anything.
            detached: std.ArrayList(Slab),
        };

        /// Whether the provisional column owns slab `i`, as opposed to
        /// sharing the original column's buffer.
        fn ownedByStage(self: *Self, i: usize) bool {
            const st = self.staging orelse return true;
            if (i >= st.owned.items.len) return true;
            return st.owned.items[i];
        }

        /// Hands slab `i` over from the original column to this stage,
        /// copying its bytes the first time. Every step that rewrites a slab
        /// in place calls this first, because those steps free the slab's old
        /// buffer and that buffer is still the original column's until here.
        ///
        /// **The original is recorded before it is overwritten.** The
        /// provisional list is about to stop naming the slab the column
        /// named at this index, and after this assignment nothing else names
        /// it: not the provisional list, which holds the copy, and not the
        /// column, whose own list a publish replaces wholesale. So an abort
        /// must hand it back to the column (it only releases this list's
        /// buffer) and a publish must free it (it releases each entry once).
        /// Leaving it unrecorded leaks the column's buffer for the rest of
        /// the process — which is what an integrated run reported.
        ///
        /// Both fallible steps are done before anything is overwritten: the
        /// record is appended first and rolled back if the copy is refused,
        /// so a refusal leaves the provisional slab exactly as it was —
        /// still shared, still the column's, and named by both lists, which
        /// is the one state in which an abort and a publish agree on who
        /// owns it. The flag makes the pair exactly-once: it is the guard
        /// above, so a second call for the same slab finds it already owned.
        fn takeOwnership(self: *Self, i: usize) ParseError!void {
            if (self.ownedByStage(i)) return;
            const st = self.staging.?;
            try st.detached.append(self.gpa, self.slabs.items[i]);
            errdefer _ = st.detached.orderedRemove(st.detached.items.len - 1);
            self.slabs.items[i] = try self.slabs.items[i].clone(self.gpa);
            st.owned.items[i] = true;
        }

        /// Releases slab `i` as the provisional list drops it. An owned slab
        /// is freed; a shared one is recorded for the publish, which is the
        /// only path after which the original column no longer names it.
        fn dropSlab(self: *Self, i: usize) ParseError!void {
            if (self.ownedByStage(i)) {
                self.slabs.items[i].deinit(self.gpa);
                return;
            }
            try self.staging.?.detached.append(self.gpa, self.slabs.items[i]);
        }

        /// Keeps the ownership flags the same length as the slab list after
        /// `added` slabs took the place of `dropped` at `at`. The added ones
        /// are the stage's: the provisional rebuild built them.
        ///
        /// **Not fallible, deliberately.** A flag list that fell behind the
        /// slab list would have the stage free a buffer the original column
        /// still names, and the two would free it twice. Every caller has
        /// already reserved through `reserveSlabs`, which reserves this list
        /// for the same count it reserves the slab list for, so the appends
        /// and inserts below fit.
        fn stagedGrew(self: *Self, at: usize, dropped: usize, added: usize) void {
            const st = self.staging orelse return;
            while (st.owned.items.len < at + dropped) st.owned.appendAssumeCapacity(false);
            var i = dropped;
            while (i != 0) {
                i -= 1;
                _ = st.owned.orderedRemove(at + i);
            }
            var k: usize = 0;
            while (k < added) : (k += 1) st.owned.insertAssumeCapacity(at, true);
        }

        /// A splice built beside the column instead of inside it. This is
        /// how [`splice`](Column.splice) makes itself atomic, and it is the
        /// seam `Columns.splice` and `Columns.removeOps` need so that a
        /// refusal in one of twenty columns leaves all twenty as they were:
        /// twenty stages, then twenty infallible publishes.
        ///
        /// # What it owns, and what it does not
        ///
        /// * **The staged column is the stage's**, together with the buffers
        ///   of the slabs it re-encoded — exactly the slabs the cut covered
        ///   plus whichever neighbour the merge policy reached for. Every
        ///   other slab is *borrowed*: the provisional list holds a struct
        ///   copy and both lists name one buffer.
        /// * **[`deinit`](StagedSplice.deinit) is the abort** and is the
        ///   caller's to make: it frees the staged slabs and nothing else,
        ///   leaving the original column byte-for-byte as it was. The slabs
        ///   the rebuild detached are *not* freed, because the original
        ///   column still names them.
        /// * **[`publish`](StagedSplice.publish) consumes the stage** and
        ///   hands the column the whole staged list — borrowed buffers
        ///   included, since the column's own list is being replaced — plus
        ///   the staged index, the staged bases and the staged length, and
        ///   frees the detached slabs that are then in neither list. It
        ///   cannot fail.
        /// * **One stage per splice point.** A caller with several points
        ///   stages each of them against columns that have not changed
        ///   since, and only then publishes; it never publishes before every
        ///   stage is in hand.
        /// * A returned stage has no pointer into the constructor's stack.
        ///   It can move while no caller borrows its address. A shallow copy
        ///   is not a second owner.
        /// * The stage borrows the original column and its untouched buffers.
        ///   Keep that column live, at the same address, and unchanged until
        ///   the stage is published or aborted.
        ///
        /// The allocator is the original column's own, taken from
        /// [`allocator`](Column.allocator) rather than as a parameter, so
        /// every byte the stage holds comes out of — and goes back into —
        /// exactly the allocator [`deinit`](Column.deinit) will release the
        /// column with. It is the same rule as [`remap`](Column.remap): the
        /// allocator moves with the contents, and a stage does not move it.
        ///
        /// A stage is bound to the column it was built from. Publishing it
        /// into another column, or into one written since, is a programmer
        /// error that the publish asserts rather than a recoverable case.
        pub const StagedSplice = struct {
            /// The column this stage was built against. `publish` checks it.
            col: *Self,
            /// The provisional column the splice ran against: the same type,
            /// the same run budget and the same allocator, over a slab list
            /// that starts as copies of the original's.
            /// Undefined for a no-op stage; use `newLen`, `publish`, or `deinit`.
            staged: Self,
            /// What the stage owns, and what it detached.
            stage: Staging,
            /// How many values the column holds once this is published.
            new_len: usize,
            /// The suspension counter the column carries afterwards, so a
            /// cursor suspended over it cannot resume across the splice.
            counter: usize,
            /// Whether the splice asked for nothing at all, in which case
            /// both `deinit` and `publish` leave the column alone.
            noop: bool,
            /// Whether the stage has been published or aborted. A `deinit`
            /// after a publish is a no-op, so `defer s.deinit()` beside
            /// `col.publish(s)` is safe rather than a double free.
            spent: bool,

            /// **The abort.** Frees the slabs this stage re-encoded and its
            /// own bookkeeping, and leaves the original column exactly as it
            /// was: no value, no length, no index and no base moved, and not
            /// one of its buffers freed. After this the stage is spent and
            /// `publish` is no longer valid.
            ///
            /// Reads ownership flags from this stage. The provisional
            /// column's construction-only stack link is cleared before return.
            /// A slab beyond the flags was created by the provisional column.
            pub fn deinit(self: *StagedSplice) void {
                if (self.spent) return;
                if (self.noop) {
                    self.spent = true;
                    return;
                }
                const flags = self.stage.owned.items;
                for (self.staged.slabs.items, 0..) |*s, i| {
                    if (i >= flags.len or flags[i]) s.deinit(self.staged.gpa);
                }
                // Only the list buffer: those slabs' buffers are still the
                // original column's, which is the whole reason they are
                // recorded rather than freed.
                self.stage.detached.deinit(self.staged.gpa);
                self.stage.owned.deinit(self.staged.gpa);
                self.staged.slabs.deinit(self.staged.gpa);
                self.staged.agg_before.deinit(self.staged.gpa);
                self.staged.tree.deinit();
                self.spent = true;
            }

            /// **Publishes the splice.** Hands `col` the staged slab list —
            /// borrowed buffers included, because `col`'s own list stops
            /// naming them the moment it is replaced — the staged index, the
            /// staged bases and the staged length, and frees the slabs the
            /// staged rebuild had detached, which are then in neither list.
            /// Consumes the stage.
            ///
            /// **Cannot fail.** Every allocation the hand-over needs was
            /// taken by [`stageSplice`](Column.stageSplice), which is what
            /// lets a caller stage twenty columns and know that publishing
            /// them cannot leave the set half-applied.
            ///
            /// A stage for a splice that asked for nothing leaves `col`
            /// untouched, counter included, and allocates nothing to say so —
            /// which is what keeps [`splice`](Column.splice) free for a splice
            /// that removes nothing and inserts nothing.
            pub fn publish(self: *StagedSplice, col: *Self) void {
                std.debug.assert(!self.spent);
                std.debug.assert(col == self.col);
                // The column must not have been written since the stage was
                // built, or the staged layout describes a column that no
                // longer exists.
                std.debug.assert(col.counter +% 1 == self.counter);
                if (self.noop) {
                    self.deinit();
                    return;
                }
                // `ArrayList.deinit` releases the buffer, not the slabs, and
                // the staged list names every slab this column had.
                col.slabs.deinit(col.gpa);
                col.slabs = self.staged.slabs;
                col.tree.deinit();
                col.tree = self.staged.tree;
                col.agg_before.deinit(col.gpa);
                col.agg_before = self.staged.agg_before;
                col.total_len = self.new_len;
                col.counter = self.counter;
                // In neither list now: the staged one dropped them and the
                // column's own is gone.
                for (self.stage.detached.items) |*s| s.deinit(col.gpa);
                self.stage.detached.deinit(col.gpa);
                self.stage.owned.deinit(col.gpa);
                self.staged.slabs = .empty;
                self.staged.agg_before = .empty;
                self.spent = true;
            }

            /// How many values the column holds once this stage is published.
            /// A caller that has to size something from the staged column — a
            /// successor buffer, a companion prefix column — asks here rather
            /// than adding up the values itself.
            pub fn newLen(self: *const StagedSplice) usize {
                return self.new_len;
            }
        };

        /// Builds the splice that replaces `[index, index + del)` with
        /// `values` beside the column instead of inside it, and returns it
        /// staged (`StagedSplice`).
        ///
        /// **The column is not touched on any path**, including every error
        /// path: same values, same `len`, same slabs, same index, same bases,
        /// same allocator. Every allocation the eventual publish needs is
        /// taken here, which is what makes the publish infallible — so a
        /// caller with twenty columns to write can stage all twenty and only
        /// then publish, and a refusal anywhere leaves the set whole.
        ///
        /// This is the splice run against a provisional column whose slab list
        /// shares the original's buffers, so the staged result is the same
        /// merge policy, the same split, the same delta re-anchor and the same
        /// canonical bytes a direct splice produces — not a second
        /// implementation of them. The slabs the cut did not cover are never
        /// re-encoded; only their struct copies are made.
        ///
        /// Bounds past the end return `error.InvalidValue`; a resulting length
        /// that does not fit `usize` returns `error.Overflow`.
        /// A splice that asks for nothing stages an allocation-free no-op.
        /// Both `deinit` and `publish` leave the column alone.
        ///
        /// The returned stage is the caller's to release — `defer
        /// stage.deinit()` — or to publish, which consumes it.
        pub fn stageSplice(
            self: *Self,
            index: usize,
            del: usize,
            values: []const T,
        ) ParseError!StagedSplice {
            if (index > self.total_len or del > self.total_len - index) return error.InvalidValue;

            var st = StagedSplice{
                .col = self,
                .staged = undefined,
                .stage = Staging{ .owned = .empty, .detached = .empty },
                .new_len = std.math.add(usize, self.total_len - del, values.len) catch return error.Overflow,
                .counter = self.counter +% 1,
                .noop = del == 0 and values.len == 0,
                .spent = false,
            };
            if (st.noop) return st;
            st.staged = .{
                .gpa = self.gpa,
                .slabs = .empty,
                .tree = try self.tree.clone(self.gpa),
                .total_len = self.total_len,
                .agg_before = .empty,
                .budget = self.budget,
                .counter = self.counter,
            };
            errdefer st.deinit();

            // Room for the flags and for the one empty slab an empty column
            // is seeded with, so `stagedGrew` never has to allocate on a path
            // where the slab list is already moving.
            // `resize` grows to `slabs.len + 1` and leaves the new slot
            // uninitialized, so every flag is written before it is read; the
            // spare slot is the one an empty column's seeded empty slab will
            // take. The length then drops back to the slab count, and the
            // spare capacity stays for `stagedGrew`.
            try st.stage.owned.resize(self.gpa, self.slabs.items.len + 1);
            @memset(st.stage.owned.items, false);
            try st.stage.detached.ensureTotalCapacity(self.gpa, self.slabs.items.len + 1);
            try st.staged.agg_before.appendSlice(self.gpa, self.agg_before.items);
            // The provisional layout: the same slab structs, sharing their
            // buffers, and a flag per slab saying the buffer is not ours.
            try st.staged.slabs.appendSlice(self.gpa, self.slabs.items);
            st.stage.owned.items.len = self.slabs.items.len;
            st.staged.staging = &st.stage;

            // **The mutating core, not [`splice`](Column.splice).** `splice`
            // is this stage plus a publish, so routing it back through the
            // public entry would stage the provisional column a second time
            // and never finish.
            if (!st.noop) try st.staged.spliceInPlace(self.gpa, index, del, values);
            // **The provisional column gives the pointer back before the
            // stage moves.** `st` lives in this frame and is returned by
            // value, so `&st.stage` is the address of a local — clearing it
            // here is what keeps the returned stage from carrying a pointer
            // into a frame that ends with this call. Only the staged splice
            // needs it, and it has run. `deinit` and `publish` read the
            // flags out of `self.stage` directly and never through this.
            st.staged.staging = null;
            return st;
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
            // it, and `runs`: **the number of runs the wire form holds so
            // far**, which is the index a boolean run's value is read from
            // (`bool.rs:855-857`, upstream's `a_segments`). Every slab has
            // to be counted into it, or the parity below is the wrong one.
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
                // The slab's own last run, taken while the run sequence is
                // known to be non-empty. The `continue` above is the only
                // thing that proves it, and this is the one place the
                // sequence is indexed from its end, so the subtraction
                // sits next to the proof instead of ten lines below it.
                const last_seg = segs[segs.len - 1];
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
                // The seam's own bytes, for the path that hands its items
                // to the codec. The literal-header path never fills them:
                // it rewrites the header where the run already is.
                var merged: []u8 = &.{};
                defer gpa.free(merged);
                var merged_segs: []slabmod.Segment(E.Wire) = &.{};
                defer gpa.free(merged_segs);
                // What the seam left at the end of the wire form, for the
                // tail bookkeeping below. All zero on the paths that copy
                // a run through, which the `after != 0 or !merge` branch
                // never reads.
                var seam_runs: usize = 0;
                var seam_bytes: usize = 0;
                // Where the run the wire form ends on starts inside
                // `seam_bytes`. Zero on the paths where the merged region
                // is that one run and it starts the region.
                var seam_byte_start: usize = 0;
                var seam_items: usize = 0;
                var seam_lit_tail: u32 = 0;
                var seam_value: ?E.Wire = null;
                var seam_kind: slabmod.RunKind = .literal;
                if (merge) {
                    // Two literal runs that meet on *different* values are
                    // one run: a canonical run sequence has no two adjacent
                    // literal runs (`rle/decoder.rs:444-451`), and a
                    // literal value equal to the previous one is not
                    // canonical either (`:452-455`). So the run already
                    // written keeps its bytes and its payload, the other
                    // run's values go behind it, and one count header is
                    // rewritten — upstream's `do_merge` seam, which is
                    // `Codec::rewrite_lit_header` and not a decode
                    // (`encoder.rs:288-302`, `codec.rs:207-219`,
                    // `rle/splice.rs:1093-1110`). It is O(bytes in the two
                    // runs) where the item path below is O(rows in them).
                    const lit_seam = (comptime E.has_lit_header) and
                        last_kind == .literal and b_first.kind == .literal and
                        !E.sameValue(last_value, b_first.first_value);
                    if (lit_seam) {
                        const head = out.items.len - last_bytes;
                        const hdr = try leb128.readSigned(s.data[b_first.byte_start..]);
                        if (hdr.len > b_first.byte_end - b_first.byte_start) return error.InvalidValue;
                        try out.appendSlice(gpa, s.data[b_first.byte_start + hdr.len .. b_first.byte_end]);
                        seam_items = last_items + b_first.itemCount();
                        _ = try slabmod.rewrite_lit_header(gpa, &out, head, seam_items);
                        seam_runs = 1;
                        seam_value = try E.lastValueOfRun(s.data, b_first);
                        seam_lit_tail = try E.litTail(s.data, b_first);
                        seam_kind = .literal;
                        seam_bytes = out.items.len - head;
                        // The slab's remaining runs, copied through behind
                        // the seam exactly as the item path copies them.
                        try out.appendSlice(gpa, s.data[b_first.byte_end..]);
                    } else {
                        // Every other pair of runs, and the deviation the
                        // slab module names: the two runs' items go through
                        // the codec, which regroups them.
                        var mid: std.ArrayList(E.Wire) = .empty;
                        defer mid.deinit(gpa);
                        {
                            // The head run's items, read out of the fragment
                            // it occupies in `out` — **with the value that run
                            // carries**, because a boolean run's value is its
                            // position in the run sequence and a fragment cut
                            // out of one opens on the `false` run a slab's own
                            // bytes do. Read on its own, the `true` run in
                            // front of the seam came back as `false`, so the
                            // merged region was written as a run of the wrong
                            // value and every row behind it decoded as the
                            // other boolean than it is (`bool.zig:13-25`).
                            const head_items = try E.wireRunItems(
                                gpa,
                                out.items[out.items.len - last_bytes ..],
                                0,
                                last_items,
                                last_value.?,
                            );
                            defer gpa.free(head_items);
                            try mid.appendSlice(gpa, head_items);
                        }
                        {
                            const tail_items = try E.wireRange(gpa, s.data, b_first.item_start, b_first.item_end);
                            defer gpa.free(tail_items);
                            try mid.appendSlice(gpa, tail_items);
                        }
                        // The merged region takes the place of the run
                        // already written, which is the run at `runs - 1`,
                        // so its own value is that one's parity.
                        merged = try E.wireEncode(gpa, mid.items, ((runs - 1) % 2) == 1);
                        merged_segs = try E.segmentsOf(gpa, merged);
                        out.shrinkRetainingCapacity(out.items.len - last_bytes);
                        try out.appendSlice(gpa, merged);
                        try out.appendSlice(gpa, s.data[b_first.byte_end..]);
                        // `merge` is only reached with `b_first` a run that
                        // carries items — `slabmod.firstItemRun` steps over
                        // the boolean pad — so `mid` holds at least one wire
                        // value, `merged` is at least one run long, and
                        // `merged_segs` is not empty. Stated at the
                        // subtraction: a codec that encoded nothing for a
                        // non-empty input is refused, not underflowed.
                        if (merged_segs.len == 0) return error.InvalidValue;
                        const mid_last = merged_segs[merged_segs.len - 1];
                        seam_runs = merged_segs.len;
                        seam_value = try E.lastValueOfRun(merged, mid_last);
                        seam_lit_tail = try E.litTail(merged, mid_last);
                        seam_kind = mid_last.kind;
                        seam_items = mid_last.itemCount();
                        seam_byte_start = mid_last.byte_start;
                        seam_bytes = merged.len;
                    }
                } else {
                    // Past the pad, if this slab has one, and on.
                    try out.appendSlice(gpa, s.data[b_first.byte_start..]);
                }
                // What this slab adds to the wire form: the runs behind
                // the seam, plus either the merged region's own runs or
                // the slab's first run, which is copied out whole when
                // the seam did not merge. A merged seam takes the place
                // of the run already written, so it gives that one back.
                //
                // The unmerged first run is what this counts and the
                // arithmetic around it left out: `runs` came out one
                // short of the wire form's own run count, and the parity
                // below is read off it, so a boolean column whose seam
                // merged two runs of `true` wrote that merged run at the
                // wrong parity — a pad run in the middle of its own
                // sequence, which is not canonical
                // (`bool.rs:784-824`).
                runs += after + (if (merge) seam_runs - 1 else 1);

                if (after != 0 or !merge) {
                    // The slab's own last run is the one the wire form ends
                    // on: it was copied through, tail and all.
                    last_value = try E.lastValueOfRun(s.data, last_seg);
                    last_bytes = s.tail.bytes;
                    last_items = last_seg.itemCount();
                    last_kind = last_seg.kind;
                } else {
                    // Nothing of the slab stood behind the seam, so the run
                    // the wire form ends on is the one just written — and its
                    // bytes are the **last run of** the merged region, not the
                    // whole of it: the region can hold more than one run, and
                    // it is the tail that says which bytes that run is. The
                    // arm above reads the same thing off the slab's own tail
                    // (`rle/load.rs:47-53`).
                    last_value = seam_value;
                    last_bytes = (try slabmod.tailAt(E, seam_bytes, .{
                        .byte_start = seam_byte_start,
                        .byte_end = seam_bytes,
                        .item_start = 0,
                        .item_end = seam_items,
                        .first_value = null,
                        .opens_with_true = false,
                        .kind = seam_kind,
                    }, seam_lit_tail)).bytes;
                    last_items = seam_items;
                    last_kind = seam_kind;
                }
            }
            // The wire form is what a load validates, so it is checked here
            // rather than left to fail later: `load(encode())` has to be
            // total, and this is the one place that can prove it.
            try E.canonicalSlab(out.items);
            return out.toOwnedSlice(gpa);
        }

        /// A column over the wire form, on the default run budget. The
        /// bytes are validated as a whole — a run sequence with the
        /// canonical rules — and then cut into slabs at half the run
        /// budget, so a later insert has room (`rle/load.rs:185-196`).
        pub fn load(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Self {
            return loadWithBudget(gpa, bytes, max_segments);
        }

        /// A column over the wire form, on a given run budget
        /// (`LoadOpts::with_max_segments`, `column.rs:1151-1161`).
        pub fn loadWithBudget(gpa: std.mem.Allocator, bytes: []const u8, budget: usize) ParseError!Self {
            try E.canonicalSlab(bytes);
            var self = try Self.initWithBudget(gpa, budget);
            errdefer self.deinit();

            const segs = try E.segmentsOf(gpa, bytes);
            defer gpa.free(segs);
            const target = @max(self.budget / 2, 1);
            var from: usize = 0;
            while (from < segs.len) {
                const to = @min(from + target, segs.len);
                // The cut is never empty: `target` is at least one run and
                // the loop only runs with a run left, so `from < to` and
                // `to - 1` names the last run in the cut. Spelled at the
                // subtraction, with the zero case named, so the bound is
                // read where it is needed rather than inferred.
                if (to == 0 or from >= to) return error.InvalidValue;
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

        /// The options a load takes (`LoadOpts`, `load_opts.rs:18-96`).
        ///
        /// The op set's loader needs all three knobs, and the second one
        /// is why a load can disagree with the column that names its
        /// length: a column the document omitted has no bytes at all, and
        /// without a fill value that would read as *empty* rather than as
        /// *everywhere null* (`op_set2/columns.rs:259-307`).
        pub const LoadOpts = struct {
            /// Require the loaded column to hold exactly this many values.
            /// Non-empty bytes that decode to another count are
            /// `error.InvalidValue`, which is this port's stand-in for
            /// upstream's `PackError::InvalidLength`
            /// (`load_opts.rs:81-91`, `column.rs:1163-1170`).
            length: ?usize = null,
            /// Read as `length` copies of this value when the bytes are
            /// empty. Distinct from "no fill", because a nullable
            /// column's fill value *is* null (`load_opts.rs:26-48`).
            fill: ?T = null,
            /// Whether `with_fill` was called. `fill` alone cannot say,
            /// because `null` is a legitimate fill value.
            has_fill: bool = false,
            /// The run budget the loaded column's slabs are cut to
            /// (`with_max_segments`, `column.rs:1155`). Null is the
            /// default budget; a value below two is refused by the load,
            /// which is where the check upstream asserts belongs.
            max_segments: ?usize = null,

            /// The options a load starts from (`load_opts.rs:52-58`).
            pub fn new() LoadOpts {
                return .{};
            }

            /// Require exactly `len` values (`with_length`, `load_opts.rs:88-92`).
            pub fn withLength(self: LoadOpts, n: usize) LoadOpts {
                var next = self;
                next.length = n;
                return next;
            }

            /// Read empty bytes as `len` copies of `value`
            /// (`with_fill`, `load_opts.rs:65-72`). Has no effect unless
            /// `withLength` is set too.
            pub fn withFill(self: LoadOpts, value: T) LoadOpts {
                var next = self;
                next.fill = value;
                next.has_fill = true;
                return next;
            }

            /// Cut the loaded slabs at `budget` runs each
            /// (`with_max_segments`, `load_opts.rs:75-79`). A budget below
            /// two is refused by the load rather than asserted here, so an
            /// untrusted value gets an error.
            pub fn withMaxSegments(self: LoadOpts, n: usize) LoadOpts {
                var next = self;
                next.max_segments = n;
                return next;
            }
        };

        /// A column of `len` copies of `value`, in one run and so in O(1)
        /// (`Column::fill`, `column.rs:1227-1245`).
        pub fn fill(gpa: std.mem.Allocator, n: usize, value: T) ParseError!Self {
            var self = try Self.init(gpa);
            errdefer self.deinit();
            if (n == 0) return self;
            // The bytes have one owner on every path out: this column
            // until the slab is in its list, and its `deinit` from there
            // on. A guard left armed past the append would free bytes the
            // column still names if the index build failed.
            const bytes = try E.fillBytes(gpa, n, value);
            const m = slabmod.measure(gpa, E, bytes) catch |e| {
                gpa.free(bytes);
                return e;
            };
            self.slabs.append(gpa, .{ .data = bytes, .len = n, .segments = m.segments, .tail = m.tail }) catch |e| {
                gpa.free(bytes);
                return e;
            };
            self.total_len = n;
            try self.reindex();
            try self.rebuildAggs();
            return self;
        }

        /// A column over the wire form, with options
        /// (`Column::load_with`, `column.rs:1156-1170`).
        ///
        /// Empty bytes plus a fill value read as `length` copies of it,
        /// which is how a column the document omitted becomes a column of
        /// the right length holding the right default. Empty bytes with no
        /// fill read as an empty column. Non-empty bytes are validated as
        /// a whole, cut into slabs at half the run budget and then held
        /// to `opts.length` if one was given.
        pub fn loadWith(gpa: std.mem.Allocator, bytes: []const u8, opts: LoadOpts) ParseError!Self {
            if (bytes.len == 0 and opts.has_fill) {
                return fillWithBudget(gpa, opts.length orelse 0, opts.fill.?, opts.max_segments orelse max_segments);
            }
            var self = try Self.loadWithBudget(gpa, bytes, opts.max_segments orelse max_segments);
            errdefer self.deinit();
            if (opts.length) |want| {
                if (self.total_len != want) return error.InvalidValue;
            }
            return self;
        }

        /// A column of `len` copies of `value` on the given run budget
        /// (`Column::with_max_segments`, `column.rs:1118-1126`).
        pub fn fillWithBudget(
            gpa: std.mem.Allocator,
            n: usize,
            value: T,
            budget: usize,
        ) ParseError!Self {
            var self = try Self.initWithBudget(gpa, budget);
            errdefer self.deinit();
            if (n == 0) return self;
            // One owner on every path out: this column until the slab is in
            // its list, its `deinit` from there on.
            const bytes = try E.fillBytes(gpa, n, value);
            const m = slabmod.measure(gpa, E, bytes) catch |e| {
                gpa.free(bytes);
                return e;
            };
            self.slabs.append(gpa, .{ .data = bytes, .len = n, .segments = m.segments, .tail = m.tail }) catch |e| {
                gpa.free(bytes);
                return e;
            };
            self.total_len = n;
            try self.reindex();
            try self.rebuildAggs();
            return self;
        }

        /// A column built from slabs whose metadata the caller already has
        /// and whose weights it has already computed, so nothing here
        /// decodes a value (`Column::from_slabs`,
        /// `column.rs:1202-1223`).
        ///
        /// The weights are the ones the streaming load measured while its
        /// slabs were being cut, which is the whole reason it measures
        /// them there rather than at the end: `finalize` hands them straight
        /// to the index instead of walking every slab again.
        fn fromWeights(
            gpa: std.mem.Allocator,
            slabs: *std.ArrayList(Slab),
            weights: *std.ArrayList(Weight),
            budget: usize,
        ) ParseError!Self {
            if (slabs.items.len != weights.items.len) return error.InvalidValue;
            var self = try Self.initWithBudget(gpa, budget);
            errdefer self.deinit();
            self.slabs = slabs.*;
            slabs.* = .empty;
            for (self.slabs.items) |s| {
                self.total_len = std.math.add(usize, self.total_len, s.len) catch return error.Overflow;
            }
            const fresh = Tree.fromSlice(gpa, weights.items) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidIndex => return error.InvalidValue,
            };
            self.tree.deinit();
            self.tree = fresh;
            if (comptime E.tracks_prefix) {
                var acc = identity;
                try self.agg_before.append(gpa, acc);
                for (weights.items) |w| {
                    acc = Weight.Aggregate.merge(acc, w);
                    try self.agg_before.append(gpa, acc);
                }
            }
            return self;
        }

        /// Streaming load (`Column::load_iter`, `column.rs:1173-1193`;
        /// `ColumnLoadIter`, `column.rs:1835-1971`).
        ///
        /// It yields the input's canonical runs while the slabs build
        /// underneath, so a caller that needs the values anyway — an index
        /// builder, a consumer that wants to see the rows as they are
        /// decoded — walks them during the same pass instead of after it.
        /// Pulling runs is optional: `loadIter(…).finalize()` is a plain
        /// load, and `finalize` validates whatever the caller did not pull.
        ///
        /// The input must be canonical and is validated run by run as it is
        /// pulled, so a caller that pulls a few runs and then meets a
        /// malformed one is refused there — it never sees the rest of bytes
        /// it was not going to believe.
        ///
        /// The stream owns every slab it has cut and their buffers, plus the
        /// weight list; the input bytes are the caller's and are only read.
        /// A stream abandoned part-way is released with [`deinit`](LoadIter.deinit)
        /// and the column is untouched, which is the other half of what
        /// [`finalize`](LoadIter.finalize) promises.
        pub const LoadIter = struct {
            gpa: std.mem.Allocator,
            bytes: []const u8,
            cursor: E.LoadCursor,
            /// The slabs finished so far.
            slabs: std.ArrayList(Slab),
            /// Their weights, measured as each slab was cut.
            weights: std.ArrayList(Weight),
            /// The byte offset the slab being cut starts at.
            cut_start: usize,
            /// The run count at which a slab is cut: half the budget, so a
            /// later insert has room (`rle/load.rs:193`).
            target: usize,
            /// The runs and rows the slab being cut holds so far.
            cut_segments: usize,
            cut_items: usize,
            /// The running value in front of the slab being cut, and the one
            /// in front of the row being served. Only a delta column reads
            /// them; the rest ignore both.
            base: i64,
            running: i64,
            /// The load options' fill, engaged when the data was empty.
            fill: ?RunOf(T),
            fill_emitted: bool,
            length: ?usize,
            budget: usize,

            /// Frees every slab cut so far and the weight list, so a stream
            /// the caller abandons before [`finalize`](LoadIter.finalize)
            /// gives its bytes back. The input is the caller's and is not
            /// released.
            ///
            /// **Not callable after `finalize`.** That takes the stream by
            /// value and moves the slabs into the column it returns, so the
            /// caller's own copy then names storage the column owns;
            /// calling this on it frees every slab out from under that
            /// column.
            pub fn deinit(self: *LoadIter) void {
                for (self.slabs.items) |*s| s.deinit(self.gpa);
                self.slabs.deinit(self.gpa);
                self.weights.deinit(self.gpa);
                self.* = undefined;
            }

            /// The next canonical run, or null at the end of the input. A
            /// fill emits its entire contents as one run and writes one
            /// slab (`column.rs:1872-1888`).
            pub fn tryNextRun(self: *LoadIter) ParseError!?RunOf(T) {
                if (self.fill) |f| {
                    if (self.fill_emitted or f.count == 0) return null;
                    self.fill_emitted = true;
                    return f;
                }
                while (true) {
                    const cursor_step = try self.cursor.next() orelse return null;
                    self.cut_items = std.math.add(usize, self.cut_items, cursor_step.count) catch return error.Overflow;
                    self.cut_segments += 1;
                    if (cursor_step.last_of_run and self.cut_segments == self.target) {
                        try self.cutSlab(cursor_step.run_end, cursor_step.after_opens_with_true);
                    }
                    // The boolean codec's opening pad holds no items and
                    // yields no run (`rle/load.rs:148-160`).
                    if (cursor_step.count == 0) continue;
                    if (cursor_step.value) |v| {
                        return .{ .count = cursor_step.count, .value = try E.valueOfWire(v, &self.running) };
                    }
                    return .{ .count = cursor_step.count, .value = try absentValueOf(E, &self.running) };
                }
            }

            /// Slabs already cut and finished behind the stream
            /// (`LoadIterApi::slabs_completed`, `encoding.rs:161`).
            pub fn slabsCompleted(self: *const LoadIter) usize {
                return self.slabs.items.len;
            }

            /// The row count of completed slab `i`, so a caller can
            /// attribute the runs it pulled to individual slabs. `i` at or
            /// past `slabsCompleted` is `error.InvalidValue`, which is how a
            /// caller that has pulled further than the stream has finished
            /// slabs finds out.
            pub fn completedSlabLen(self: *const LoadIter, i: usize) ParseError!usize {
                if (i >= self.slabs.items.len) return error.InvalidValue;
                return self.slabs.items[i].len;
            }

            /// Drains and validates whatever was not pulled, applies the
            /// length check, and returns the finished column.
            ///
            /// **This consumes the stream.** The slabs it has cut become the
            /// returned column's — `fromWeights` takes the list by pointer
            /// and empties it — so the receiver must not be read, freed or
            /// finalized again. `slabsCompleted` and `completedSlabLen`
            /// would answer through storage the column now owns, a second
            /// `finalize` would consume nothing, and `deinit` would free
            /// every slab out from under the column. The returned column's
            /// own `deinit` is what releases them; a stream the caller wants
            /// to drop instead is released with [`deinit`](LoadIter.deinit)
            /// *before* this call.
            pub fn finalize(self: LoadIter) ParseError!Self {
                var it = self;
                defer it.deinit();
                if (it.fill) |f| {
                    return fillWithBudget(it.gpa, f.count, f.value, it.budget);
                }
                while (try it.tryNextRun()) |_| {}
                if (it.cut_segments != 0) try it.cutSlab(it.cursor.bytePos(), false);
                var total: usize = 0;
                for (it.slabs.items) |s| total = std.math.add(usize, total, s.len) catch return error.Overflow;
                if (it.length) |want| {
                    if (total != want) return error.InvalidValue;
                }
                return fromWeights(it.gpa, &it.slabs, &it.weights, it.budget);
            }

            /// Closes the slab being cut at `at` and measures it.
            ///
            /// The bytes have exactly one owner on every path out: this
            /// function until the slab is in the list, and the list from
            /// there on. Both are spelled out rather than left to an
            /// `errdefer`, because a guard still armed after the append
            /// would free bytes the list still names.
            fn cutSlab(self: *LoadIter, at: usize, opens_with_true: bool) ParseError!void {
                if (self.cut_segments == 0) return;
                const piece = try E.wireSlice(self.gpa, self.bytes, self.cut_start, at, opens_with_true);
                const m = slabmod.measure(self.gpa, E, piece) catch |e| {
                    self.gpa.free(piece);
                    return e;
                };
                var slab: Slab = .{ .data = piece, .len = m.len, .segments = m.segments, .tail = m.tail };
                const w = E.weightOf(self.gpa, &slab) catch |e| {
                    self.gpa.free(piece);
                    return e;
                };
                self.slabs.append(self.gpa, slab) catch |e| {
                    self.gpa.free(piece);
                    return e;
                };
                errdefer {
                    _ = self.slabs.pop();
                    slab.deinit(self.gpa);
                }
                try self.weights.append(self.gpa, w);
                self.cut_start = at;
                self.cut_segments = 0;
                self.cut_items = 0;
                self.base = self.running;
            }
        };

        /// A streaming load over `bytes` with `opts`
        /// (`Column::load_iter`, `column.rs:1173-1193`).
        pub fn loadIter(gpa: std.mem.Allocator, bytes: []const u8, opts: LoadOpts) ParseError!LoadIter {
            const budget = opts.max_segments orelse max_segments;
            if (budget < 2) return error.InvalidValue;
            const initial: ?RunOf(T) = if (bytes.len == 0) blk: {
                if (opts.length) |fill_length| {
                    if (opts.has_fill) break :blk .{ .count = fill_length, .value = opts.fill.? };
                }
                break :blk null;
            } else null;
            return .{
                .gpa = gpa,
                .bytes = bytes,
                .cursor = E.LoadCursor.init(bytes),
                .slabs = .empty,
                .weights = .empty,
                .cut_start = 0,
                .target = @max(budget / 2, 1),
                .cut_segments = 0,
                .cut_items = 0,
                .base = 0,
                .running = 0,
                .fill = initial,
                .fill_emitted = false,
                .length = opts.length,
                .budget = budget,
            };
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

        /// Where a column position lands: the slab holding it, and the
        /// item's offset inside that slab.
        pub const SlabPos = struct {
            /// The slab the item is in, or the last one when the item is
            /// at the end of the column.
            slab: usize,
            /// The item's offset inside `slab`.
            in_slab: usize,
        };

        /// A column over `values`, on the given run budget
        /// (`Column::from_values_with_max_segments`,
        /// `column.rs:1141-1145`). Upstream goes through the same splice
        /// path a caller would; this goes through the streaming encoder,
        /// which produces the same values in the same order and the same
        /// canonical bytes — only the runs are grouped as they are written
        /// rather than re-read afterwards.
        pub fn fromValues(gpa: std.mem.Allocator, values: []const T, budget: usize) ParseError!Self {
            var enc = Encoder.init(gpa);
            defer enc.deinit();
            try enc.maxSegments(budget);
            try enc.extend(values);
            return enc.intoColumn();
        }

        /// The streaming encoder over this column's values (`EncoderApi`,
        /// `encoding.rs:187-240`).
        ///
        /// A value is encoded as it is appended: nothing is staged in full
        /// and then encoded, and a value is never copied more than once
        /// into the slab it ends up in. With a run budget set, the encoder
        /// rolls finished runs into slabs as it goes, so `intoColumn` hands
        /// them straight to a column with no decode pass at all
        /// (`RleEncoder::maybe_cut`, `encoder.rs:186-213`).
        pub const Encoder = struct {
            gpa: std.mem.Allocator,
            inner: E.StreamEncoder,
            /// The slabs rolled so far, empty until a budget is set.
            slabs: std.ArrayList(Slab),
            /// Their weights, measured as each was rolled — which is what
            /// lets `intoColumn` skip a second walk of the data.
            weights: std.ArrayList(Weight),
            /// The run budget, or null for one contiguous buffer.
            budget: ?usize,
            /// Values already rolled into `slabs`.
            len_flushed: usize,
            /// The running value in front of the values appended so far,
            /// which is what a delta column's differences are measured
            /// from.
            running: i64,
            /// Whether every value has been handed over: `intoColumn`
            /// always, `save` when no run budget was set. A spent encoder
            /// holds nothing — its buffer is gone and its rolled slabs are
            /// the returned column's — so `len` answers zero, `isEmpty`
            /// answers true, and a second `save` yields an empty buffer
            /// rather than the bytes that were already given away.
            spent: bool,

            /// An encoder holding nothing, on one contiguous buffer. The
            /// allocator is the caller's and is not released; `deinit` is.
            pub fn init(gpa: std.mem.Allocator) Encoder {
                return .{
                    .gpa = gpa,
                    .inner = E.StreamEncoder.init(gpa),
                    .slabs = .empty,
                    .weights = .empty,
                    .budget = null,
                    .len_flushed = 0,
                    .running = 0,
                    .spent = false,
                };
            }

            /// Frees the encoder's buffer, its rolled slabs and its weight
            /// list. The allocator itself is the caller's.
            pub fn deinit(self: *Encoder) void {
                for (self.slabs.items) |*s| s.deinit(self.gpa);
                self.slabs.deinit(self.gpa);
                self.weights.deinit(self.gpa);
                self.inner.deinit();
                self.* = undefined;
            }

            /// Values appended so far and still held by the encoder. Zero
            /// once it has been spent by `save` or `intoColumn`.
            pub fn len(self: *const Encoder) usize {
                if (self.spent) return 0;
                return self.inner.len();
            }

            /// Whether the encoder holds no values — which is also true of
            /// a spent one, whatever it appended before the handover.
            pub fn isEmpty(self: *const Encoder) bool {
                if (self.spent) return true;
                return self.inner.isEmpty();
            }

            /// Roll finished runs into slabs at half of `n`, so a later
            /// insert has room (`EncoderApi::max_segments`,
            /// `encoder.rs:183-196`). Must be set before appending: the
            /// encoder cuts on the way past, and a budget given afterwards
            /// would only bound slabs already written whole.
            ///
            /// A budget below two is `error.InvalidValue`, where upstream
            /// asserts (`column.rs:1126`): it would halve to a cut target
            /// of zero.
            pub fn maxSegments(self: *Encoder, n: usize) ParseError!void {
                if (n < 2) return error.InvalidValue;
                self.budget = n;
            }

            /// Appends one value.
            ///
            /// A spent encoder is outside this contract: its buffer is gone
            /// with the `save` or `intoColumn` that spent it, so what is
            /// appended here would never reach the values the caller was
            /// handed.
            pub fn append(self: *Encoder, v: T) ParseError!void {
                try self.maybeCut();
                const one = try E.wireOfOne(self.running, v);
                self.running = one.running;
                try self.inner.append(one.wire);
            }

            /// Appends `n` copies of `v` as one run
            /// (`EncoderApi::append_n`, `encoder.rs:246-249`).
            ///
            /// For a run-length column the `n` copies *are* one run, and
            /// that is what the codec writes. A delta column stores a
            /// difference, so the rows behind the first are measured from
            /// `v` and not from the value in front of the column: they are
            /// differences of zero, and repeating the first difference
            /// would walk the column away from `v` entirely. The writer
            /// regroups the tail itself — one literal run of two at
            /// `n == 2`, a repeat run of zero behind the first row above
            /// that, and one run of `n` zeros when the first difference is
            /// itself zero — so the bytes are canonical on every path.
            pub fn appendN(self: *Encoder, v: T, n: usize) ParseError!void {
                if (n == 0) return;
                try self.maybeCut();
                const one = try E.wireOfOne(self.running, v);
                self.running = one.running;
                if (comptime E.is_delta) {
                    const rest = try E.wireOfOne(self.running, v);
                    try self.inner.append(one.wire);
                    try self.inner.appendN(rest.wire, n - 1);
                    return;
                }
                try self.inner.appendN(one.wire, n);
            }

            /// Appends every value of `values`, in order.
            pub fn extend(self: *Encoder, values: []const T) ParseError!void {
                for (values) |v| try self.append(v);
            }

            /// The column's wire form, and the bytes a caller saves. Rolls
            /// first when a budget was set, then folds the slabs back into
            /// one canonical run sequence, which is what a column's `save`
            /// does (`RleEncoder::save_to`, `encoder.rs:281-304`).
            ///
            /// **A save spends the encoder.** Both paths hand over what they
            /// hold: the one-buffer path takes the contiguous buffer, and
            /// the budgeted path builds a column out of the rolled slabs,
            /// which `fromWeights` consumes from this encoder rather than
            /// borrowing. So afterwards `len` answers zero, `isEmpty`
            /// answers true, and a second `save` yields an empty buffer
            /// rather than the bytes that were already given away. A caller
            /// that wants the values again has them — they are the returned
            /// `[]u8`, and they are the caller's to free.
            pub fn save(self: *Encoder) ParseError![]u8 {
                if (self.spent) {
                    // Already handed over. `finish` over an empty writer
                    // writes nothing and `take` hands over nothing, which is
                    // exactly the empty buffer the contract above promises.
                    try self.inner.finish();
                    return self.inner.take();
                }
                if (self.slabs.items.len == 0) {
                    try self.inner.finish();
                    const bytes = try self.inner.take();
                    self.spent = true;
                    return bytes;
                }
                try self.rollSlab();
                // Set before the hand-over rather than after it: the slab
                // list leaves this encoder inside `fromWeights`, so from
                // here on it holds nothing whatever the encode does.
                self.spent = true;
                var col = try fromWeights(self.gpa, &self.slabs, &self.weights, self.budget.?);
                defer col.deinit();
                return col.encode(self.gpa);
            }

            /// The finished column, with no decode pass: the slabs are
            /// already measured and their weights already known
            /// (`Column::from_slabs`, `column.rs:1202-1223`).
            ///
            /// **This spends the encoder.** The rolled slabs become the
            /// returned column's and the contiguous buffer is handed over to
            /// it, so on every path out of here the encoder holds nothing:
            /// `len` answers zero, `isEmpty` answers true, and a later
            /// `save` or `intoColumn` produces an empty column rather than
            /// the values that were already given away. `deinit` still
            /// releases what is left — the weight list, which is the
            /// encoder's own.
            pub fn intoColumn(self: *Encoder) ParseError!Self {
                const budget = self.budget orelse max_segments;
                if (self.slabs.items.len != 0) {
                    try self.rollSlab();
                    // Before the hand-over rather than after it: the slab
                    // list leaves this encoder inside `fromWeights`, so
                    // from here on it holds nothing whatever that returns.
                    self.spent = true;
                    return fromWeights(self.gpa, &self.slabs, &self.weights, budget);
                }

                try self.inner.finish();
                const bytes = try self.inner.take();
                // The buffer is the column's from here; every path below
                // either hands it over or gives it back, and neither leaves
                // the encoder holding it.
                self.spent = true;
                // One owner on every path out: this function while the
                // buffer is still a local, and `slabs` from the append on.
                // The buffer is freed by hand until then rather than by a
                // function-scoped `errdefer`, which would still be armed
                // once `slabs` — and the column it becomes — owns it.
                var slabs: std.ArrayList(Slab) = .empty;
                errdefer {
                    for (slabs.items) |*s| s.deinit(self.gpa);
                    slabs.deinit(self.gpa);
                }
                var weights: std.ArrayList(Weight) = .empty;
                // A plain `defer` and not an `errdefer`: `fromWeights`
                // copies the weights into the tree and the aggregate prefix
                // and consumes only the slabs, so this list is still this
                // function's own on the way out — success included. An
                // `errdefer` would leave the success path's buffer behind,
                // and the borrowed lists the other two callers pass
                // (`self.weights` here, the iterator's own) are freed by
                // their owners, so exactly one free happens on every path.
                defer weights.deinit(self.gpa);
                const m = slabmod.measure(self.gpa, E, bytes) catch |e| {
                    self.gpa.free(bytes);
                    return e;
                };
                var slab: Slab = .{ .data = bytes, .len = m.len, .segments = m.segments, .tail = m.tail };
                const w = E.weightOf(self.gpa, &slab) catch |e| {
                    self.gpa.free(bytes);
                    return e;
                };
                // The append is the one step the list's `errdefer` cannot
                // cover: the slab is not in the list yet, so nothing above
                // owns the buffer. `deinit` rather than a bare `free`,
                // because an encoder with no values in it takes a zero-length
                // buffer that must not be freed (`slab.zig:186-189`).
                slabs.append(self.gpa, slab) catch |e| {
                    slab.deinit(self.gpa);
                    return e;
                };
                try weights.append(self.gpa, w);
                return fromWeights(self.gpa, &slabs, &weights, budget);
            }

            /// Rolls the pending buffer into a slab once the run budget is
            /// reached. A no-op unless a budget was set.
            fn maybeCut(self: *Encoder) ParseError!void {
                const n = self.budget orelse return;
                const target = @max(n / 2, 1);
                if (self.inner.segmentCount() < target) return;
                try self.rollSlab();
            }

            /// Closes the pending runs and takes the buffer as a slab.
            fn rollSlab(self: *Encoder) ParseError!void {
                if (self.inner.len() == self.len_flushed) return;
                try self.inner.finish();
                const bytes = try self.inner.take();
                // The buffer has exactly one owner on every path out: this
                // function until the slab is in the list, and the list from
                // there on. Each path is spelled rather than left to a
                // function-scoped `errdefer`, because that one is still
                // armed once the list owns the bytes — and would then free
                // what the list's own `deinit` frees.
                const m = slabmod.measure(self.gpa, E, bytes) catch |e| {
                    self.gpa.free(bytes);
                    return e;
                };
                var slab: Slab = .{ .data = bytes, .len = m.len, .segments = m.segments, .tail = m.tail };
                const w = E.weightOf(self.gpa, &slab) catch |e| {
                    self.gpa.free(bytes);
                    return e;
                };
                self.slabs.append(self.gpa, slab) catch |e| {
                    slab.deinit(self.gpa);
                    return e;
                };
                try self.weights.append(self.gpa, w);
                self.len_flushed = self.inner.len();
            }
        };

        // ── Copying between columns ─────────────────────────────────────

        /// One point of a multi-point [`Column.copyRanges`]: at destination
        /// row `pos` delete `delete` rows and insert `src`'s rows in
        /// `range` (`Splice`, `column.rs:701-724`).
        pub const Splice = struct {
            /// The destination row, in the destination's own coordinates
            /// before any of this copy's points are applied.
            pos: usize,
            /// How many destination rows the point deletes.
            delete: usize,
            /// The source rows the point inserts.
            range: RowRange,
        };

        /// How a copy is carried out (`CopyStrategy`, `column.rs:662-672`).
        ///
        /// The choice is unobservable: both paths yield the same values in
        /// the same order and the same `encode` bytes. It is a cost
        /// decision, and pinning it is what lets a test hold the two to
        /// each other.
        pub const CopyStrategy = enum {
            /// Read the source's kept rows and splice them in, one range at
            /// a time.
            direct,
            /// Keep the *source's* slabs: swap the columns, drop the gaps
            /// without decoding them, and splice the old destination's kept
            /// rows back around what survived.
            invert,
        };

        /// Safety factor favouring `direct` in [`Column.copyStrategy`]. The
        /// seam term is already a gross upper bound, so one is not
        /// aggressive (`COPY_INVERT_FACTOR`, `column.rs:669-672`).
        pub const copy_invert_factor: usize = 1;

        /// `ranges` clamped to `total`, empties dropped, touching neighbours
        /// merged, and any pair that goes backwards refused
        /// (`normalize_ranges`, `column.rs:676-699`).
        ///
        /// Upstream asserts `r.start >= pos` with the message "ranges must
        /// be ascending and non-overlapping". This port refuses instead: an
        /// overlapping list would silently drop rows, and an untrusted
        /// caller gets an error rather than a crash.
        pub fn normalizeRanges(gpa: std.mem.Allocator, ranges: []const RowRange, total: usize) ParseError![]RowRange {
            var out: std.ArrayList(RowRange) = .empty;
            errdefer out.deinit(gpa);
            var pos: usize = 0;
            for (ranges) |r| {
                if (r.start < pos) return error.InvalidValue;
                pos = @max(pos, r.end);
                const start = @min(r.start, total);
                const end = @min(r.end, total);
                if (end <= start) continue;
                if (out.items.len != 0) {
                    const last = &out.items[out.items.len - 1];
                    if (last.end == start) {
                        last.end = end;
                        continue;
                    }
                }
                try out.append(gpa, .{ .start = start, .end = end });
            }
            return out.toOwnedSlice(gpa);
        }

        /// A multi-point list clamped to the source and the destination,
        /// no-ops dropped, contiguous neighbours merged, and any pair that
        /// goes backwards refused (`normalize_splices`,
        /// `column.rs:726-769`).
        pub fn normalizeSplices(
            gpa: std.mem.Allocator,
            splices: []const Splice,
            src_len: usize,
            dst_len: usize,
        ) ParseError![]Splice {
            var out: std.ArrayList(Splice) = .empty;
            errdefer out.deinit(gpa);
            var src_pos: usize = 0;
            var dst_pos: usize = 0;
            for (splices) |sp| {
                if (sp.pos < dst_pos) return error.InvalidValue;
                if (sp.pos > dst_len or sp.delete > dst_len - sp.pos) return error.InvalidValue;
                if (sp.range.start < src_pos) return error.InvalidValue;
                dst_pos = sp.pos + sp.delete;
                src_pos = @max(src_pos, sp.range.end);
                const start = @min(sp.range.start, src_len);
                const end = @min(sp.range.end, src_len);
                if (end == start and sp.delete == 0) continue;
                if (out.items.len != 0) {
                    const last = &out.items[out.items.len - 1];
                    if (last.pos + last.delete == sp.pos and last.range.end == start) {
                        last.delete += sp.delete;
                        last.range.end = end;
                        continue;
                    }
                }
                try out.append(gpa, .{ .pos = sp.pos, .delete = sp.delete, .range = .{ .start = start, .end = end } });
            }
            return out.toOwnedSlice(gpa);
        }

        /// Replaces the values `[index, index + del)` with `runs`
        /// (`Column::splice_runs`, `column.rs:1563-1569`).
        ///
        /// A run-aware splice is a splice whose values are already grouped,
        /// which is what a caller copying rows out of another column has:
        /// its run walk hands over `count` copies of one value rather than
        /// the same value `count` times.
        ///
        /// The values are expanded once, into a buffer the splice encodes
        /// into the slab's own bytes. Upstream keeps them in runs all the
        /// way into the slab's writer, which saves the expansion; that
        /// writer is `slab.zig`'s and takes a flat value list here, so
        /// this port pays the one expansion and gets the same column.
        pub fn spliceRuns(
            self: *Self,
            gpa: std.mem.Allocator,
            index: usize,
            del: usize,
            runs: []const RunOf(T),
        ) ParseError!void {
            if (index > self.total_len or del > self.total_len - index) return error.InvalidValue;
            var flat: usize = 0;
            for (runs) |r| flat = std.math.add(usize, flat, r.count) catch return error.Overflow;
            const values = try gpa.alloc(T, flat);
            defer gpa.free(values);
            var at: usize = 0;
            for (runs) |r| {
                for (0..r.count) |_| {
                    values[at] = r.value;
                    at += 1;
                }
            }
            try self.splice(gpa, index, del, values);
        }

        /// The runs `src` holds in `range`, as one buffer. The caller owns
        /// it; a byte payload's runs borrow the source's slabs, which the
        /// splice encodes into its own bytes before it returns.
        fn runsInRange(self: *const Self, gpa: std.mem.Allocator, range: RowRange) ParseError![]RunOf(T) {
            var out: std.ArrayList(RunOf(T)) = .empty;
            errdefer out.deinit(gpa);
            var it = try self.iterRange(range);
            while (try it.nextRun()) |r| try out.append(gpa, r);
            return out.toOwnedSlice(gpa);
        }

        /// Copies `src`'s rows into this column at `index`, deleting `del`
        /// rows first, with the strategy pinned
        /// (`Column::copy_ranges_with`, `column.rs:1698-1735`).
        ///
        /// `ranges` must already be normalized. The result is
        /// `self[0..index] ++ src[ranges...] ++ self[index + del..]`,
        /// which is what both strategies produce.
        ///
        /// **The source is handed over, not borrowed** (`column.rs:1698`):
        /// `src` is moved in and freed here on every path out, the invert
        /// arm included, where it is the column's *old* contents that end
        /// up in it. A caller that still wants its source keeps a copy.
        pub fn copyRangesWith(
            self: *Self,
            gpa: std.mem.Allocator,
            index: usize,
            del: usize,
            src: Self,
            ranges: []const RowRange,
            strategy: CopyStrategy,
        ) ParseError!void {
            // The refusal still consumes the source: it was handed over,
            // and nothing else is going to free it. The parameter itself is
            // a `const` by-value binding, so freeing it means taking
            // ownership into a mutable local first — `deinit` hands the
            // column back as `undefined`.
            if (index > self.total_len or del > self.total_len - index) {
                var refused = src;
                refused.deinit();
                return error.InvalidValue;
            }
            var other = src;
            defer other.deinit();
            switch (strategy) {
                .direct => {
                    var flat: std.ArrayList(T) = .empty;
                    defer flat.deinit(gpa);
                    for (ranges) |r| {
                        if (r.end <= r.start) continue;
                        var it = try other.iterRange(r);
                        while (try it.next()) |v| try flat.append(gpa, v);
                    }
                    try self.splice(gpa, index, del, flat.items);
                },
                .invert => {
                    const old_len = self.total_len;
                    self.swapContents(&other);
                    try self.retainRanges(gpa, ranges);
                    const kept = self.total_len;
                    var shifted: usize = 0;
                    if (index > 0) {
                        const head = try other.sliceRange(gpa, .{ .start = 0, .end = index });
                        defer gpa.free(head);
                        try self.splice(gpa, shifted, 0, head);
                        shifted += head.len;
                    }
                    if (index + del < old_len) {
                        const tail = try other.sliceRange(gpa, .{ .start = index + del, .end = old_len });
                        defer gpa.free(tail);
                        try self.splice(gpa, shifted + kept, 0, tail);
                    }
                },
            }
        }

        /// Copies `src` into this column at the points `splices` name
        /// (`Column::copy_ranges`, `column.rs:1571-1594`).
        ///
        /// `splices` must be normalized. Each `pos` is a row of the
        /// destination *before* any of these points are applied, so the
        /// result interleaves the destination's surviving rows with the
        /// source's chosen ranges exactly as the points describe.
        ///
        /// **The source is handed over, not borrowed**: it is moved into
        /// [`Column.copySplicesWith`], which frees it on every path out.
        /// The one path that stops short of that is the strategy decision,
        /// so the refusal there frees it here.
        pub fn copySplices(self: *Self, gpa: std.mem.Allocator, src: Self, splices: []const Splice) ParseError!void {
            const strategy = self.copyStrategyForSplices(&src, splices) catch |e| {
                // A by-value parameter is a `const` binding; ownership moves
                // into a mutable local so the source can be given back.
                var refused = src;
                refused.deinit();
                return e;
            };
            return self.copySplicesWith(gpa, src, splices, strategy);
        }

        /// [`Column.copySplices`] with the strategy pinned
        /// (`Column::copy_splices_with`, `column.rs:1596-1640`).
        ///
        /// **`src` is consumed**: freed on every path out, the invert arm
        /// included, where it is this column's old contents that end up in
        /// it.
        pub fn copySplicesWith(
            self: *Self,
            gpa: std.mem.Allocator,
            src: Self,
            splices: []const Splice,
            strategy: CopyStrategy,
        ) ParseError!void {
            var other = src;
            defer other.deinit();
            switch (strategy) {
                .direct => {
                    var delta: i64 = 0;
                    for (splices) |sp| {
                        const at = std.math.add(i64, @as(i64, @intCast(sp.pos)), delta) catch return error.Overflow;
                        if (at < 0) return error.InvalidValue;
                        const pos: usize = @intCast(at);
                        if (pos > self.total_len or sp.delete > self.total_len - pos) return error.InvalidValue;
                        if (sp.range.end > sp.range.start) {
                            const runs = try other.runsInRange(gpa, sp.range);
                            defer gpa.free(runs);
                            try self.spliceRuns(gpa, pos, sp.delete, runs);
                        } else {
                            try self.splice(gpa, pos, sp.delete, &.{});
                        }
                        delta += @as(i64, @intCast(sp.range.end - sp.range.start)) - @as(i64, @intCast(sp.delete));
                    }
                },
                .invert => {
                    const old_len = self.total_len;
                    self.swapContents(&other);
                    var ranges: std.ArrayList(RowRange) = .empty;
                    defer ranges.deinit(gpa);
                    for (splices) |sp| try ranges.append(gpa, sp.range);
                    try self.retainRanges(gpa, ranges.items);
                    // Upstream's `for_each_gap` (`column.rs:1091-1108`): the
                    // gaps walk the *old destination* from left to right,
                    // and each one's landing place is counted in the rows
                    // of the retained source that stand in front of it —
                    // not in the rows already spliced back. Both counters
                    // are needed because this port splices into the column
                    // as it stands, where upstream's edit cursor seeks by
                    // the original position (`edit.rs:230-234`), so the
                    // landing place is `kept + inserted`.
                    var kept: usize = 0;
                    var inserted: usize = 0;
                    var end: usize = 0;
                    for (splices) |sp| {
                        if (sp.pos > end) try self.copyGapInto(gpa, &other, end, sp.pos, kept + inserted, &inserted);
                        end = sp.pos + sp.delete;
                        kept += sp.range.end - sp.range.start;
                    }
                    if (old_len > end) try self.copyGapInto(gpa, &other, end, old_len, kept + inserted, &inserted);
                },
            }
        }

        /// Splices `other`'s rows `[lo, hi)` in at `at`.
        ///
        /// `at` is the gap's place in the column as it stands: the retained
        /// source rows in front of it plus the old-destination rows already
        /// spliced back in front of it. The gaps are put in left to right,
        /// so `inserted` only ever grows and every one of them is a splice
        /// at a position the column already has.
        fn copyGapInto(
            self: *Self,
            gpa: std.mem.Allocator,
            other: *const Self,
            lo: usize,
            hi: usize,
            at: usize,
            inserted: *usize,
        ) ParseError!void {
            if (at > self.total_len) return error.InvalidValue;
            const vals = try other.sliceRange(gpa, .{ .start = lo, .end = hi });
            defer gpa.free(vals);
            try self.splice(gpa, at, 0, vals);
            inserted.* += vals.len;
        }

        /// Decides `direct` against `invert` for a multi-point copy, from
        /// the stored per-slab counts and nothing else — no data decoded
        /// (`Column::copy_strategy`, `column.rs:1645-1696`).
        pub fn copyStrategyForSplices(self: *const Self, src: *const Self, splices: []const Splice) ParseError!CopyStrategy {
            var ranges: std.ArrayList(RowRange) = .empty;
            defer ranges.deinit(self.gpa);
            for (splices) |sp| try ranges.append(self.gpa, sp.range);
            return self.copyStrategy(src, ranges.items, splices.len);
        }

        /// Decides `direct` against `invert` for `ranges`, from the stored
        /// per-slab item and run counts (`Column::copy_strategy`,
        /// `column.rs:1645-1696`).
        ///
        /// Inverting keeps the *source's* slabs, built under the source's
        /// own run budget — sound only when the two budgets agree — and only
        /// pays when the source is spread over enough slabs that the gap
        /// bookkeeping beats decoding the kept runs.
        pub fn copyStrategy(self: *const Self, src: *const Self, ranges: []const RowRange, points: usize) ParseError!CopyStrategy {
            if (self.budget != src.budget or src.slabs.items.len < 8) return .direct;

            var item_prefix: std.ArrayList(usize) = .empty;
            defer item_prefix.deinit(self.gpa);
            var seg_prefix: std.ArrayList(usize) = .empty;
            defer seg_prefix.deinit(self.gpa);
            try item_prefix.append(self.gpa, 0);
            try seg_prefix.append(self.gpa, 0);
            for (src.slabs.items) |s| {
                try item_prefix.append(self.gpa, item_prefix.items[item_prefix.items.len - 1] + s.len);
                try seg_prefix.append(self.gpa, seg_prefix.items[seg_prefix.items.len - 1] + s.segments);
            }

            var retained_segs: usize = 0;
            for (ranges) |r| {
                if (r.end <= r.start) continue;
                const sa = slabOfRow(item_prefix.items, r.start);
                const sb = slabOfRow(item_prefix.items, r.end - 1);
                if (sa == sb) {
                    retained_segs += src.slabs.items[sa].segments;
                } else {
                    retained_segs += src.slabs.items[sa].segments + src.slabs.items[sb].segments +
                        (seg_prefix.items[sb] - seg_prefix.items[sa + 1]);
                }
            }

            // The direct path also cuts a seam per insertion point.
            const direct_cost = retained_segs + points * 2 * self.budget;
            var dest_segs: usize = 0;
            for (self.slabs.items) |s| dest_segs += s.segments;
            const seam_segs = (ranges.len + points) * 2 * self.budget;
            const invert_cost = dest_segs + seam_segs + src.slabs.items.len;

            if (direct_cost > copy_invert_factor * invert_cost) return .invert;
            return .direct;
        }

        /// The index of the slab holding row `row`, from the slab-start
        /// prefixes — the same `partition_point(|&p| p <= row) - 1`
        /// upstream writes (`column.rs:1665`).
        fn slabOfRow(prefix: []const usize, row: usize) usize {
            var lo: usize = 0;
            var hi: usize = prefix.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (prefix[mid] <= row) lo = mid + 1 else hi = mid;
            }
            return lo - 1;
        }

        /// Keeps only the rows in `ranges`, deleting the gaps back to front
        /// so no index shifts a range still to come
        /// (`Column::retain_ranges`, `column.rs:1737-1750`).
        pub fn retainRanges(self: *Self, gpa: std.mem.Allocator, ranges: []const RowRange) ParseError!void {
            var end = self.total_len;
            var i = ranges.len;
            while (i > 0) {
                i -= 1;
                const r = ranges[i];
                if (r.end < end) try self.removeN(gpa, r.end, end - r.end);
                end = r.start;
            }
            if (end > 0) try self.removeN(gpa, 0, end);
        }

        /// Swaps this column's contents with `other`'s, keeping this
        /// column's run budget and bumping the counter past both, so a
        /// cursor suspended over either column cannot resume against the
        /// data it swapped into (`Column::swap_contents`,
        /// `column.rs:1752-1760`).
        ///
        /// **The allocator moves with the contents.** The two columns trade
        /// everything they hold, `gpa` included, so each keeps its slabs,
        /// its index and its bases in the allocator it can release them
        /// with — which is the point: the swap is sound, and only a caller
        /// that cached [`allocator`](Column.allocator) beforehand is not.
        /// Ask each column again after this, and do not free a slab taken
        /// from one with the other's cached allocator. The budget is the one
        /// exception: it is deliberately *not* traded, so both columns come
        /// out of this with the budget they went in with.
        pub fn swapContents(self: *Self, other: *Self) void {
            const counter = @max(self.counter, other.counter) +% 1;
            const mine = self.*;
            const theirs = other.*;
            self.* = theirs;
            other.* = mine;
            const budget = other.budget;
            other.budget = self.budget;
            self.budget = budget;
            self.counter = counter;
            other.counter = counter;
        }

        /// The slab holding item `item`, and the item's offset inside it.
        ///
        /// The pair upstream's `ColumnRef::find_slab` returns
        /// (`column.rs:328`, `:340-342`) and the pair the edit cursor
        /// opens with (`edit.rs:172-175`): a position at or past the end
        /// of the column lands in the last slab, at its end, so a write
        /// there appends to that slab rather than starting one of its own.
        pub fn locate(self: *const Self, item: usize) SlabPos {
            if (self.slabs.items.len == 0) return .{ .slab = 0, .in_slab = 0 };
            const last = self.slabs.items.len - 1;
            if (item >= self.total_len) {
                return .{ .slab = last, .in_slab = self.slabs.items[last].len };
            }
            const hit = self.tree.findByPrefix(item) orelse {
                return .{ .slab = last, .in_slab = item - self.tree.itemsBeforeSlab(last) };
            };
            return .{ .slab = hit.slab, .in_slab = item - hit.items_before };
        }

        /// Gives the column a slab for a write to land in, seeding an
        /// empty one when it has none.
        ///
        /// Upstream's `Edit::new` does the same before it looks anything
        /// up (`edit.rs:167-171`): a column with no slabs cannot answer a
        /// locate, and a splice into an empty column still has to have
        /// somewhere to put its first slab.
        ///
        /// **Both caches are seeded with it, not left for the first write.**
        /// A column with one slab and no base for it answers every read of
        /// that slab's base as the identity, which is right and says nothing
        /// about the omission — `checkInvariants` is what notices, and the
        /// array it checks is this step's to fill.
        ///
        /// **A refusal leaves the column exactly as it was: still no slabs.**
        /// The seeded slab goes into a list whose room was taken first, and
        /// the two rebuilds are the only steps after that which allocate —
        /// so the order is what makes the undo possible. `rebuildAggs` runs
        /// first and measures into room past the end of the array it
        /// replaces, shrinking back on a refusal; `reindex` runs second and
        /// builds the fresh tree before it tears the old one down. Whichever
        /// of the two refuses, the other has not run and the tree is still
        /// the one the column came in with. What is left to undo is a
        /// length and a flag, because an empty slab owns nothing.
        pub fn ensureSlab(self: *Self) ParseError!void {
            if (self.slabs.items.len != 0) return;
            // Room for the seeded slab, its ownership flag and the bases it
            // will need, taken while the column is still the empty one.
            try self.reserveSlabs(1);
            const seeded_len = self.agg_before.items.len;
            self.slabs.appendAssumeCapacity(.empty);
            self.stagedGrew(self.slabs.items.len - 1, 0, 1);
            errdefer {
                self.agg_before.shrinkRetainingCapacity(seeded_len);
                self.slabs.items.len = 0;
                self.stagedGrew(0, 1, 0);
            }
            try self.rebuildAggs();
            try self.reindex();
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
            try self.takeOwnership(si);
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

            // Room for everything the rewrite invalidates, taken while the
            // column is still exactly as the caller left it: the slabs the
            // split in `settle` below can spill into, and the bases
            // `rebuildAggs` refills afterwards. Every run is at least one
            // byte, so the spliced slab holds no more runs than the ones it
            // had plus one per inserted value.
            const spills = (s.segments + values.len) / self.budget;
            try self.reserveSlabs(self.slabs.items.len + spills + 1);

            try self.takeOwnership(si);
            try slabmod.splice(gpa, E, &self.slabs.items[si], in_slab, del_now, insert, postfix);
            // **The length is published with the bytes that back it.**
            // `settle` below can be refused, and a column still counting the
            // rows from before the splice would bounds-check every later read
            // against a count its slabs no longer have. `del_now` and
            // `insert` carry the absent rows a re-anchor took and put back,
            // so this is the same total the caller asked for.
            self.total_len = self.total_len - del_now + insert.len;
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
            // **The pieces are slabs, not wire runs.** Between the first one
            // being built and the list taking them over, a refusal leaves
            // them owned by nobody: `pieces.deinit` gives back the array that
            // names them and not the buffers behind it, which is what an
            // integrated run reported — one slab's bytes per refused
            // allocation, for the length of the whole sweep. The swap below
            // empties the list, and from there the column owns them, so this
            // guard has nothing left to do on the paths that follow it.
            errdefer for (pieces.items) |*p| p.deinit(gpa);

            // The head of the first slab, the inserted values, the tail of
            // the last, in that order: the column order.
            const head = try E.wireRange(gpa, self.slabs.items[s0].data, 0, index - self.tree.itemsBeforeSlab(s0));
            defer gpa.free(head);
            if (head.len != 0) {
                try appendPiece(gpa, &pieces, try slabOf(gpa, E, head));
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
                        try appendPiece(gpa, &pieces, try slabOf(gpa, E, anchored));
                        anchored_in_tail = true;
                    }
                }
                if (!anchored_in_tail) try appendPiece(gpa, &pieces, try slabOf(gpa, E, tail));
            }

            // **Room first, then the swap.** The old slabs are freed on the
            // next line and cannot be rebuilt, and the pieces are the column's
            // only copy of the range until they are in its list — so the list
            // has to be able to hold them before either happens. An
            // `insertSlice` that had to grow would come back with the range
            // gone from the column and the pieces still owned by `pieces`,
            // which is the one owner that gives them back. The bound covers
            // the split `settle` below makes at the run budget: a run is at
            // least one byte, so a piece's own run count bounds what it can
            // spill into.
            const placed = pieces.items.len;
            const dropped = s1 + 1 - s0;
            const head_spill = if (placed == 0) 0 else pieces.items[placed - 1].segments / self.budget;
            try self.reserveSlabs(self.slabs.items.len - dropped + placed + head_spill + 1);
            // Drop the slabs the cut spanned and put the pieces in their
            // place, in one non-fallible step. The old slabs are freed by hand
            // because the list is holding them, not copies of them.
            var i = s0;
            while (i <= s1) : (i += 1) try self.dropSlab(i);
            self.slabs.replaceRangeAssumeCapacity(s0, dropped, pieces.items);
            self.stagedGrew(s0, dropped, placed);
            pieces.items.len = 0;
            // **The length is published with the bytes that back it.** The
            // range in the list is the spliced range now, and `settle` below
            // can be refused; a column still counting the rows from before
            // the splice would bounds-check every later read against a count
            // its slabs no longer have.
            self.total_len = self.total_len - del + values.len;
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

        /// Appends `piece` to `pieces`, freeing it if the list cannot grow.
        ///
        /// **A piece is a slab, and a slab owns its buffer.** `try
        /// pieces.append(gpa, try slabOf(..))` reads as one step and is two:
        /// the piece is built first, and an `append` that had to grow would
        /// drop the finished value on the floor, owned by nobody and freed by
        /// nobody. This is the one place the rebuilt range's pieces go into a
        /// list, so it is the one place that has to carry the buffer across a
        /// refusal.
        fn appendPiece(
            gpa: std.mem.Allocator,
            pieces: *std.ArrayList(Slab),
            piece: Slab,
        ) ParseError!void {
            var owned_piece = piece;
            errdefer owned_piece.deinit(gpa);
            try pieces.append(gpa, piece);
        }

        /// Split `wires` into slabs at the run budget and append them.
        fn appendBudgeted(
            self: *Self,
            gpa: std.mem.Allocator,
            pieces: *std.ArrayList(Slab),
            wires: []const E.Wire,
        ) ParseError!void {
            if (wires.len == 0) return;
            const bytes = try E.wireEncode(gpa, wires, false);
            defer gpa.free(bytes);
            const segs = try E.segmentsOf(gpa, bytes);
            defer gpa.free(segs);
            var from: usize = 0;
            while (from < segs.len) {
                const to = @min(from + self.budget, segs.len);
                try appendPiece(gpa, pieces, try cutPiece(gpa, E, bytes, segs, from, to));
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
        ///
        /// The edit cursor's write-back is the same three steps in the
        /// same order over a range of one slab plus its spills, which is
        /// why it is this method rather than a second copy
        /// (`edit.rs:566-593`).
        ///
        /// **The split is the last step that can lose a value, so the room
        /// it needs is taken before it runs.** `splitToBudget` replaces the
        /// slab in place, and the pieces that spill out live in memory the
        /// column does not name until they are in its list — so a list that
        /// had to grow at that point could only be answered by freeing them,
        /// which drops the tail of the column rather than refusing the
        /// write. The bound is the slab's own run count over the budget, and
        /// the bases are reserved with it because `rebuildAggs` refills them
        /// from the list this step leaves behind.
        ///
        /// **A refusal past the split is only survivable on a provisional
        /// column.** Everything up to and including the spill insert is
        /// non-fallible, but the coalescing that follows and the index
        /// rebuild behind it allocate against a list that has already moved:
        /// a refusal in either leaves this column holding the new slabs
        /// against an index that still describes the old ones. That is why
        /// [`splice`](Column.splice) runs this on the provisional column a
        /// [`StagedSplice`](Column.StagedSplice) builds, which a refusal
        /// discards whole. The whole of this method's refusal contract is
        /// that: it is not atomic on a column the caller means to keep, and
        /// the row-level steps that call it are reached only that way.
        ///
        /// Private for the same reason. The edit cursor was the one caller
        /// that ran it on a live column, and it does so no more — its
        /// write-back goes through the same stage and publish as
        /// [`splice`](Column.splice) — so nothing outside this file is left
        /// that could reach a non-atomic step.
        fn settle(self: *Self, lo: usize, count: usize) ParseError!void {
            if (self.slabs.items.len == 0) {
                // A cut that spanned every slab and put nothing in its
                // place. An empty column still keeps one empty slab, the
                // one the next splice lands in (`column.rs:1298-1306`).
                try self.slabs.append(self.gpa, .empty);
                self.stagedGrew(self.slabs.items.len - 1, 0, 1);
                try self.reindex();
                return;
            }
            // Room for the split and for the bases that follow it, taken
            // while the column still holds every value it had. `Slab.segments`
            // is the run count `splitToBudget` cuts on, so this is the exact
            // number of pieces that can come out of it, not an estimate.
            try self.reserveSlabs(self.slabs.items.len + self.slabs.items[lo].segments / self.budget);
            // `spilled` has exactly one owner at every point and no guard
            // outlives it. The previous shape armed an `errdefer` that closed
            // over `spilled`, called `spilled.deinit` on the success path, and
            // then let `tryMergeRange`/`reindexFrom` below fail: the guard
            // then read `spilled.items` out of the `undefined` an
            // `ArrayList.deinit` leaves behind, so it walked a garbage length
            // over garbage item pointers and freed garbage — the general
            // protection fault the apply-route allocation sweep hit. The
            // items transfer to `self.slabs` on success; the list buffer is
            // released once, here, and the two fallible calls after it hold no
            // reference to `spilled` at all.
            try self.takeOwnership(lo);
            var spilled = try slabmod.splitToBudget(self.gpa, E, &self.slabs.items[lo], self.budget);
            const spill = spilled.items.len;
            if (spill != 0) {
                // Non-fallible: the room was taken above, so the pieces are
                // put in their place rather than freed on a refusal that
                // would drop the tail of the column.
                self.slabs.insertSliceAssumeCapacity(lo + 1, spilled.items);
                self.stagedGrew(lo + 1, 0, spill);
                spilled.items.len = 0;
            }
            spilled.deinit(self.gpa);

            const range = try self.tryMergeRange(lo, lo + count + spill);
            try self.reindexFrom(@min(lo, range.start));
        }

        /// Merge slab `b` into slab `a` when one of them is undersized and
        /// the pair fits the budget (`Column::try_merge`,
        /// `column.rs:1782-1797`). `null` when the pair was not merged, and
        /// otherwise how many slabs the merge spilled.
        ///
        /// The pre-check is `sa + sb <= max_segments`, which is upstream's
        /// rule and is not enough here. Upstream's `Slab.segments` counts a
        /// literal run as its number of *values*
        /// (`rle/load.rs:131-138`, `rle/state.rs:394-424`), so the metric
        /// is additive across the seam. This port counts one literal run as
        /// one run, and two literal runs meeting cannot become one — a
        /// literal value equal to the previous one is not canonical
        /// (`rle/decoder.rs:452-455`) and two adjacent literal runs are not
        /// canonical either (`:444-451`) — so the seam that replaces two
        /// runs is three and the merged slab is one run over the budget the
        /// pre-check admitted it at. So the merged slab is cut back to the
        /// budget, exactly as `settle` cuts the slab a splice rebuilt
        /// (`column.rs:1866-1870`): the pair `63 + 1` is inside the
        /// pre-check and its seam is three runs.
        fn tryMerge(self: *Self, a: usize, b: usize) ParseError!?usize {
            if (a >= self.slabs.items.len or b >= self.slabs.items.len) return null;
            const min_seg = @max(self.budget / 4, 1);
            const sa = self.slabs.items[a].segments;
            const sb = self.slabs.items[b].segments;
            if (!((sa < min_seg or sb < min_seg) and sa + sb <= self.budget)) return null;
            // Room for the split below, taken before the merge has put its
            // values into `a`: after `splitToBudget` the spills are the only
            // copy of the tail of the pair, and a list that had to grow at
            // that point could only be answered by freeing them. The merge
            // pre-check admits a pair of at most `budget` runs, and its seam
            // costs at most three, so this is a bound and not an estimate.
            try self.reserveSlabs(self.slabs.items.len + (sa + sb) / self.budget + 1);
            try self.takeOwnership(a);
            try slabmod.merge(self.gpa, E, &self.slabs.items[a], &self.slabs.items[b]);
            var spilled = try slabmod.splitToBudget(self.gpa, E, &self.slabs.items[a], self.budget);
            errdefer {
                for (spilled.items) |*p| p.deinit(self.gpa);
                spilled.deinit(self.gpa);
            }
            const spill = spilled.items.len;
            try self.dropSlab(b);
            _ = self.slabs.orderedRemove(b);
            if (spill != 0) {
                // Where `b` stood: the merge put its values into `a`, and
                // the spill is the tail of the pair that did not fit.
                self.slabs.insertSliceAssumeCapacity(b, spilled.items);
                self.stagedGrew(b, 1, spill);
                spilled.items.len = 0;
            }
            spilled.deinit(self.gpa);
            return spill;
        }

        /// Walk the four slab boundaries around a rebuilt range and merge
        /// undersized neighbours. Only the edges of a rebuilt range can be
        /// short — the spills in the middle were cut at the budget — so the
        /// walk stays short however many slabs the splice touched
        /// (`try_merge_range_skeleton`, `column.rs:185-229`).
        ///
        /// A merge can leave slabs behind (`tryMerge`), so a step that
        /// merged one inside the range moves `end` by the spill minus the
        /// slab removed rather than by minus one alone. The two steps that
        /// merge a pair *straddling* a boundary do not: the slab they
        /// remove is outside the range, so `end` still names the first
        /// slab after it — which is upstream's own accounting, and the
        /// reason the outward-right loop there is written as a bare
        /// `while` (`column.rs:215-216`).
        ///
        /// `end` saturates at zero rather than wrapping: only `start` is
        /// load-bearing (it is what the caller reindexes from), and a walk
        /// cursor that has run off the left of the column has nothing left
        /// to point at.
        fn tryMergeRange(self: *Self, lo: usize, hi: usize) ParseError!struct { start: usize, end: usize } {
            var start = lo;
            var end = hi;
            // The end a merge inside the range moved to: one slab out,
            // `spill` in.
            const shrink = struct {
                fn f(at: usize, spill: usize) usize {
                    return if (spill == 0) at -| 1 else at +| (spill - 1);
                }
            }.f;
            if (end > start) {
                if (end >= start + 3) {
                    if (try self.tryMerge(end - 3, end - 2)) |spill| end = shrink(end, spill);
                }
                if (end >= start + 2) {
                    if (try self.tryMerge(end - 2, end - 1)) |spill| end = shrink(end, spill);
                }
                // The last slab of the range against the first slab after
                // it. The pair straddles the boundary, so the merge removes
                // a slab *outside* the range and `end` stays put: this is
                // the outward walk to the right, and it has to go on after
                // the range has collapsed onto its first slab, or the
                // merged slab is left beside a short one that upstream folds
                // in as well. Every pass either takes a slab out of the
                // column or lands one on the budget, where no further merge
                // can fit, so the walk ends (`try_merge_range_skeleton`,
                // `column.rs:215-216`).
                while (end > 0) {
                    if (try self.tryMerge(end - 1, end) == null) break;
                }
                if (end >= start + 2) {
                    if (try self.tryMerge(start, start + 1)) |spill| end = shrink(end, spill);
                }
                while (start > 0) {
                    const spill = (try self.tryMerge(start - 1, start)) orelse break;
                    start -= 1;
                    end = shrink(end, spill);
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
        ///
        /// The index owns its weights: `Tree.fromSlice` copies every leaf
        /// and every internal level it builds (`copyOf`,
        /// `btree.zig:146-153`, reached at `btree.zig:283` and `:486`), so
        /// the `defer` frees the buffer the weights were counted in and
        /// not the tree.
        ///
        /// The fresh tree is built *before* the old one is torn down, which
        /// is what makes that ownership true on the failure path as well
        /// as the good one. An allocation failure inside `fromSlice` comes
        /// back with `self.tree` still the tree the column already had, so
        /// the caller's `errdefer self.deinit()` frees a real tree. Tearing
        /// the old one down first left `self.tree` undefined — `Tree.deinit`
        /// poisons its receiver — for every
        /// caller that has a teardown, including `splice`, `loadWithBudget`,
        /// `fill`, `fillWithBudget`, `ensureSlab` and `settle`.
        fn reindex(self: *Self) ParseError!void {
            var weights: std.ArrayList(Weight) = .empty;
            defer weights.deinit(self.gpa);
            for (self.slabs.items) |*s| try weights.append(self.gpa, try E.weightOf(self.gpa, s));
            const fresh = Tree.fromSlice(self.gpa, weights.items) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidIndex => return error.InvalidValue,
            };
            self.tree.deinit();
            self.tree = fresh;
        }

        /// Rebuild the per-slab weight prefixes. Only a codec whose weight
        /// carries a prefix keeps them.
        ///
        /// **A refusal leaves the column's previous bases in place, whole.**
        /// The array is read as a slab's base — a delta or prefix column's
        /// running value in front of that slab — and `aggWeight` answers the
        /// identity for a slab past its end, so an array shortened by a
        /// failed rebuild would not fail loudly: every slab past the
        /// truncation would read its base as zero and decode against it.
        /// The new bases are therefore measured into the room past the end
        /// of the array the column is still reading and only take its place
        /// once every weight is in, so neither the allocation nor a weight
        /// that will not measure can leave a short array behind.
        fn rebuildAggs(self: *Self) ParseError!void {
            if (!comptime E.tracks_prefix) {
                self.agg_before.clearRetainingCapacity();
                return;
            }
            const n = self.slabs.items.len;
            const old = self.agg_before.items.len;
            // Room for the bases and for the weights they are summed from,
            // both past the end of the entries the column is still reading.
            try self.agg_before.ensureTotalCapacity(self.gpa, old + n + 1);
            const weights = self.agg_before.addManyAsSliceAssumeCapacity(n + 1)[0..n];
            errdefer self.agg_before.shrinkRetainingCapacity(old);
            for (self.slabs.items, weights) |*s, *w| w.* = try E.weightOf(self.gpa, s);
            var acc = identity;
            for (weights, 0..) |w, i| {
                self.agg_before.items[i] = acc;
                acc = Weight.Aggregate.merge(acc, w);
            }
            self.agg_before.items[n] = acc;
            self.agg_before.shrinkRetainingCapacity(n + 1);
        }

        /// Room in the slab list for `n` slabs, and in the base array for
        /// the rebuild `rebuildAggs` makes from whatever the list holds
        /// afterwards.
        ///
        /// Both are taken by the steps that invalidate them — a rewrite of
        /// the bytes, or the split that cuts an over-budget slab — and
        /// neither can be undone: a slab `splitToBudget` has already
        /// replaced is gone even though the pieces that spilled out of it
        /// are not yet in the list. Reserving at the point the change starts
        /// is what turns those steps from ones that can fail half-way into
        /// ones that cannot fail at all.
        ///
        /// Both lists live in the column's own allocator, which is the one
        /// `settle` and `tryMerge` already grow them with — so this takes no
        /// allocator of its own and cannot be pointed at a second one.
        fn reserveSlabs(self: *Self, n: usize) ParseError!void {
            try self.slabs.ensureTotalCapacity(self.gpa, n);
            // The ownership flags move with the list: `stagedGrew` cannot
            // allocate, so the room for every flag a staged splice inserts
            // is taken here, alongside the room for the slab it belongs to.
            if (self.staging) |st| try st.owned.ensureTotalCapacity(self.gpa, n);
            // A codec whose weight carries no prefix keeps no bases, so it
            // has nothing to reserve: `rebuildAggs` clears the array and
            // never fills it, and an allocation here would be memory every
            // splice of such a column pays for and never uses.
            if (!comptime E.tracks_prefix) return;
            // Room for the bases `rebuildAggs` writes and for the weights it
            // sums them from, which it measures past the end of the array it
            // is replacing. That array is as long as the slab list is now,
            // so the bound is the larger of the two counts twice over: a
            // splice that collapses many slabs into one leaves `n` below the
            // count the array already has.
            const count = @max(n, self.slabs.items.len);
            try self.agg_before.ensureTotalCapacity(self.gpa, count + n + 2);
        }

        // ── The invariants ──────────────────────────────────────────────

        /// What a failed invariant check found. Mirrors the assertions of
        /// `Column::check_invariants` (`column.rs:1292-1345`), which a test
        /// turns into a report rather than a panic.
        pub const Violation = struct {
            what: []const u8,
            at: usize,
            /// The sub-check's own rendering, when `what` names a layer
            /// rather than a failure. `detail_len == 0` for the checks that
            /// are one sentence already. It is a **fixed array copied by
            /// value**, not a slice: a `Violation` is returned by value, and
            /// a slice into a field of the value being returned points into
            /// the *returning* frame, which is dead by the time the caller
            /// prints it. That is not a hypothetical — it is what the first
            /// version of this field did, and it printed garbage.
            detail_len: usize = 0,
            detail_storage: [128]u8 = undefined,

            /// The rendered detail, or `""` when there is none.
            pub fn detail(self: *const Violation) []const u8 {
                return self.detail_storage[0..self.detail_len];
            }
        };

        /// Whether two adjacent slabs are one the merge policy would have
        /// coalesced: one of them undersized and the pair inside the budget
        /// (`column.rs:1782-1797`).
        ///
        /// The policy is the splice path's, so a column that came from
        /// `load` may hold such a pair — a load cuts at half the budget and
        /// its last slab can be a run long.
        pub fn mergeableNeighbours(self: *const Self) ?Violation {
            const min_seg = @max(self.budget / 4, 1);
            for (self.slabs.items, 0..) |s, i| {
                if (i == 0) continue;
                const prev = self.slabs.items[i - 1].segments;
                if ((prev < min_seg or s.segments < min_seg) and prev + s.segments <= self.budget) {
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
                if (!(s.segments <= self.budget or s.segments == 1)) {
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
                // **The kind is carried, not flattened into the sentence.**
                // "the slab index is not sound" names the layer and nothing
                // else, and a violation that reports only its layer is a
                // violation the next reader has to reproduce to learn
                // anything: this check reports eleven kinds and said one.
                var out: Violation = .{ .what = "the slab index is not sound", .at = v.node orelse 0 };
                out.detail_len = v.describe(&out.detail_storage).len;
                return out;
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

        /// A forward cursor over a positional window of the column's rows
        /// (`Iter`, `column.rs:355-658`).
        ///
        /// A value, not a heap object: it holds a pointer, three numbers
        /// and one decoder, so constructing one allocates nothing and a
        /// window can be repositioned as often as a caller likes without
        /// touching the allocator. It answers the three questions every
        /// repositionable iterator is asked — where am I, how far may I go,
        /// cut the window here — and the four defaults built on them, which
        /// together are upstream's `Shiftable` (`shift.rs:19-74`).
        /// A snapshot of a cursor's position, restorable later
        /// (`IterState`, `column.rs:787-853`).
        ///
        /// A cursor names the column it is reading and where in it it
        /// stands. A write can move the row it stands on somewhere else,
        /// so a snapshot is only meaningful against the column it was taken
        /// from — which is what the counter and the slab count are for.
        pub const IterState = struct {
            /// The column's mutation counter when the cursor was suspended.
            counter: usize,
            /// How many slabs the column had then.
            num_slabs: usize,
            /// The slab the cursor was in.
            slab_idx: usize,
            /// The row the cursor stood on.
            pos: usize,
            /// How many rows its window still held.
            items_left: usize,
            /// How many rows of the current slab it had consumed.
            slab_consumed: usize,

            /// Restores the cursor in `column`, or refuses
            /// (`IterState::try_resume`, `column.rs:807-852`).
            ///
            /// A column written since the snapshot, or one whose slab count
            /// has changed, is not the column the snapshot was taken from:
            /// the row a cursor stood on may now be a different row. Both
            /// are `error.InvalidValue`, upstream's
            /// `PackError::InvalidResume`, because "you cannot resume
            /// here" is a statement about the caller's sequence and not
            /// about the bytes.
            pub fn tryResume(self: IterState, column: *const Self) ParseError!Iterator {
                if (self.counter != column.counter) return error.InvalidValue;
                if (self.num_slabs != column.slabs.items.len) return error.InvalidValue;
                if (self.slab_idx >= column.slabs.items.len) {
                    return .{
                        .col = column,
                        .slab_idx = column.slabs.items.len,
                        .dec = try E.WireDecoder.init(&.{}),
                        .items_left = 0,
                        .running = 0,
                        .at = self.pos,
                        .slab_remaining = 0,
                    };
                }
                const slab = &column.slabs.items[self.slab_idx];
                if (self.slab_consumed > slab.len) return error.InvalidValue;
                var it = Iterator{
                    .col = column,
                    .slab_idx = self.slab_idx,
                    .dec = try E.WireDecoder.init(slab.data),
                    .items_left = self.items_left,
                    .running = column.baseOf(self.slab_idx),
                    .at = self.pos,
                    .slab_remaining = slab.len - self.slab_consumed,
                };
                // The decoder starts at the slab's own first row, so it
                // is walked onto the row the cursor stood on — the same
                // `decoder.nth(slab_consumed - 1)` upstream reaches for
                // (`column.rs:838-840`).
                try it.skipRows(self.slab_consumed);
                return it;
            }
        };

        /// A forward-only cursor over a window of a column's rows, and the
        /// window into the slab it currently stands in.
        ///
        /// Built by [`iterator`](Column.iterator) and
        /// [`iterRange`](Column.iterRange), held by value inside a
        /// [`Runs`](Column.Runs) cursor, by [`BoolColumnSkipper`](Column)
        /// and behind [`Ranges`](Column) and [`Unshift`](Column), and
        /// rebuilt from a saved [`IterState`](Column) by
        /// [`tryResume`](Column.IterState.tryResume). It allocates nothing
        /// to construct and nothing to read, and it has no teardown: it owns
        /// no memory, and the decoder it holds is a view over a slab's
        /// bytes.
        ///
        /// **What invalidates it is the column.** `col` is a borrow of a
        /// column that must outlive the cursor, and the column must not be
        /// written while the cursor is open: any of `splice`, `set`,
        /// `removeN`, `remap`, `swapContents`, `settle` or `edit` may
        /// rewrite, split, free or replace the slab the cursor is standing
        /// in, and the decoder would then read bytes that are gone or a
        /// different row entirely. A cursor that has to outlive a write is
        /// recorded as an [`IterState`](Column) instead, which
        /// [`tryResume`](Column.IterState.tryResume) checks against the
        /// column's suspension counter. Fields are reachable without a
        /// method, so treat every one of them as cursor state: only `next`,
        /// `peek`, the run cursor and `tryResume` maintain them.
        pub const Iterator = struct {
            /// The column being walked, borrowed for the cursor's life.
            col: *const Self,
            /// The slab the cursor is standing in.
            slab_idx: usize,
            /// The decoder over that slab's bytes, positioned at the row
            /// after the one the cursor last returned.
            dec: E.WireDecoder,
            /// Rows left in the cursor's window.
            items_left: usize,
            /// The realized value in front of the current row. Only a delta
            /// column reads it, and it starts at the current slab's base.
            running: i64,
            /// The index of the row the next `next` returns
            /// (`Iter::pos`, `column.rs:521-524`).
            at: usize,
            /// The rows of the current slab that have not been consumed
            /// (`Iter::slab_remaining`, `column.rs:365`). It is what tells
            /// a `nth` that can stay on this slab from one that has to ask
            /// the index, and where a run cursor starts inside it.
            slab_remaining: usize,

            /// The run the cursor is in, kept from the last lookup so a run
            /// walk that stays inside one run does not ask for that run once
            /// per row of it.
            ///
            /// `runAtOrAfter` reads the slab's run sequence from its own
            /// start, and a literal run's packed payload is walked whole to
            /// find where the run ends — so a lookup costs the bytes of the
            /// slab up to the run, and a run walk that re-looked it up for
            /// every row of a long literal run was quadratic in that run's
            /// length. A column of mostly distinct values is one long
            /// literal run (`encoder_into_column_direct_matches_load` says
            /// the same about its own), so this is a shape a real column
            /// has and not an artefact of a fixture.
            ///
            /// It can only answer while the cursor is in the run it was
            /// taken from, and the slab is part of it because a run's item
            /// bounds are relative to its own slab.
            run_cache: ?RunCache = null,
            /// The run the last lookup found, and the slab it belongs to.
            const RunCache = struct {
                slab: usize,
                seg: slabmod.Segment(E.Wire),
            };

            /// The next value, or null at the end of the window.
            pub fn next(self: *Iterator) ParseError!?T {
                while (self.items_left != 0) {
                    if (try self.dec.next()) |w| {
                        self.items_left -= 1;
                        self.slab_remaining -= 1;
                        self.at += 1;
                        return try E.valueOfWire(w, &self.running);
                    }
                    self.slab_idx += 1;
                    if (self.slab_idx >= self.col.slabs.items.len) {
                        self.items_left = 0;
                        return null;
                    }
                    self.dec = try E.WireDecoder.init(self.col.slabs.items[self.slab_idx].data);
                    self.slab_remaining = self.col.slabs.items[self.slab_idx].len;
                    self.running = self.col.baseOf(self.slab_idx);
                }
                return null;
            }

            /// The index of the row the next `next` returns
            /// (`column.rs:521-524`).
            pub fn pos(self: *const Iterator) usize {
                return self.at;
            }

            /// One past the last row this cursor can yield
            /// (`Iter::end_pos`, `column.rs:526-529`).
            pub fn maxPos(self: *const Iterator) usize {
                return self.at + self.items_left;
            }

            /// How many rows are left in the window.
            pub fn itemsLeft(self: *const Iterator) usize {
                return self.items_left;
            }

            /// Truncates the window so iteration stops at `pos`
            /// (`Iter::set_max`, `column.rs:505-512`).
            ///
            /// It can shorten the window and extend it again, and a `pos`
            /// past the end of the data simply stops the cursor there.
            pub fn setMax(self: *Iterator, at: usize) void {
                self.items_left = if (at > self.at) at - self.at else 0;
            }

            /// Consumes `n` rows off the current slab's decoder and moves
            /// the cursor with them, keeping the running value in step.
            /// This is the walk inside a slab that the port cannot skip:
            /// the decoders here have no `nth`, so a seek pays for the
            /// rows before its target inside its own slab, exactly as
            /// `get` does (`column.rs:1500-1516`).
            fn skip(self: *Iterator, n: usize) ParseError!void {
                try self.skipRows(n);
                self.at += n;
                self.items_left -= n;
                self.slab_remaining -= n;
            }

            /// Advances the decoder `n` rows *without* moving the cursor:
            /// the rows walked are the ones in front of the position, not
            /// the ones the window holds. `iter_range` is exactly this —
            /// its decoder is advanced by the offset into the slab while
            /// `pos` stays at the range's start (`column.rs:1406-1419`),
            /// and a cursor that moved with the decoder would stand past
            /// the start of its own window, and would underflow the count
            /// of rows left whenever the offset was longer than the
            /// window.
            ///
            /// The invariant this establishes, and the reason the two
            /// halves are separate: **the decoder stands on the row the
            /// cursor is at**. Every move that lands on a row — `next`,
            /// `skip`, a run walk, a rewind — keeps the two together, and
            /// a caller that wants to position the cursor walks the
            /// decoder alone and leaves the position where it wants it.
            fn skipRows(self: *Iterator, n: usize) ParseError!void {
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const w = (try self.dec.next()) orelse return error.InvalidValue;
                    _ = try E.valueOfWire(w, &self.running);
                }
            }

            /// Moves the cursor onto slab `si` and onto the row `row` —
            /// an absolute index, as upstream's `advance_to_slab` takes
            /// it — with the decoder walked onto the same row. `false`
            /// when `si` is at or past the last slab, which drains the
            /// window and leaves the decoder empty so a later `setMax`
            /// cannot decode rows already passed
            /// (`advance_to_slab`, `column.rs:638-657`).
            ///
            /// `row` is absolute because that is the distance the window
            /// gives up: `items_left` loses the whole of `row - at`, not
            /// the offset of the row inside its own slab
            /// (`column.rs:649-654`, `let skipped = pos - self.pos`).
            /// The invariant this establishes, and the reason the
            /// argument is not the offset: after this, `at == row` and
            /// the decoder stands on `row`. Upstream gets the decoder
            /// there with one `decoder.nth` (`column.rs:438`); these
            /// decoders have no `nth`, so the rows in front of the target
            /// inside the slab are read, the walk `skip` already pays.
            fn advanceToSlab(self: *Iterator, si: usize, row: usize) ParseError!bool {
                if (si >= self.col.slabs.items.len) {
                    self.slab_idx = si;
                    self.at = row;
                    self.items_left = 0;
                    self.slab_remaining = 0;
                    self.dec = try E.WireDecoder.init(&.{});
                    return false;
                }
                const slab = &self.col.slabs.items[si];
                const offset = row - self.col.tree.itemsBeforeSlab(si);
                // The window gives up every row between here and the
                // target, which is the whole distance and not the offset
                // inside the slab (`column.rs:649`).
                self.items_left -= row - self.at;
                self.at = row;
                self.slab_idx = si;
                self.dec = try E.WireDecoder.init(slab.data);
                // A delta column's values are measured from the value in
                // front of their slab, so a jump has to re-anchor on the
                // new slab's base or the rows behind it realize wrongly.
                self.running = self.col.baseOf(si);
                try self.skipRows(offset);
                // What is left of *this* slab is its length less the
                // offset just walked. Upstream subtracts the same rows
                // after its `decoder.nth` (`column.rs:434`), because
                // there the position and the decoder move in two steps
                // and here they move in one.
                self.slab_remaining = slab.len - offset;
                return true;
            }

            /// The value `n` rows ahead, or null past the end of the
            /// window (`Iter::nth`, `column.rs:411-439`).
            ///
            /// A `n` that stays inside the current slab walks; one that
            /// leaves it asks the index, which is O(log S). Either way the
            /// rows between here and there are read, because the decoders
            /// have no `nth` of their own.
            pub fn nth(self: *Iterator, n: usize) ParseError!?T {
                if (n >= self.items_left) {
                    if (self.items_left > 0) _ = try self.nth(self.items_left - 1);
                    return null;
                }
                if (n < self.slab_remaining) {
                    try self.skip(n);
                } else {
                    const target = self.at + n;
                    const hit = self.col.tree.findByPrefix(target) orelse return null;
                    if (!try self.advanceToSlab(hit.slab, target)) return null;
                }
                const w = (try self.dec.next()) orelse return error.InvalidValue;
                self.at += 1;
                self.items_left -= 1;
                self.slab_remaining -= 1;
                return try E.valueOfWire(w, &self.running);
            }

            /// Advances so the next `next` is the row at `target`. A target
            /// at or behind the cursor is a no-op, which is what makes
            /// `shift` usable on a cursor already inside the range
            /// (`column.rs:531-535`).
            pub fn advanceTo(self: *Iterator, target: usize) ParseError!void {
                if (target > self.at) _ = try self.nth(target - self.at - 1);
            }

            /// Advances past `amount` rows (`column.rs:547-549`).
            pub fn advanceBy(self: *Iterator, amount: usize) ParseError!void {
                return self.advanceTo(self.at +| amount);
            }

            /// Repositions the window to `range`: the cursor yields the rows
            /// in it and then stops (`Iter::shift`, `column.rs:538-545`;
            /// the `Shiftable` default it implements, `shift.rs:50-55`).
            ///
            /// **`setMax` to the end *and* `advanceTo` the start.** Both
            /// halves are load-bearing: upstream's own doc says the window
            /// "yields the items in `range` and then returns `None`"
            /// (`column.rs:536-537`), and a `setMax` alone leaves the cursor
            /// yielding rows from wherever it stood, which is the window
            /// without the range. Repositioning only moves forward, so a
            /// `range` that starts behind the cursor truncates the window
            /// and leaves the position where it was (`shift.rs:14-16`).
            pub fn shift(self: *Iterator, range: RowRange) ParseError!void {
                self.setMax(range.end);
                try self.advanceTo(range.start);
            }

            /// Repositions the window to `range` and returns the row at its
            /// start, in one step rather than a reposition and a `next`
            /// (`shift.rs:59-63`).
            ///
            /// A `range` that starts behind the cursor cannot be served —
            /// repositioning only moves forward — so it is
            /// `error.InvalidValue` where upstream's assertion fires
            /// (`column.rs:626-632`).
            pub fn shiftNext(self: *Iterator, range: RowRange) ParseError!?T {
                if (range.start < self.at) return error.InvalidValue;
                self.setMax(range.end);
                return self.nth(range.start - self.at);
            }

            /// Consumes through `pos`, returning the row there; `null` when
            /// `pos` is behind the cursor (`shift.rs:68-74`).
            pub fn seekTo(self: *Iterator, at: usize) ParseError!?T {
                if (at < self.at) return null;
                return self.nth(at - self.at);
            }

            /// The next run of equal values, merged across the slab
            /// boundaries it crosses, or null at the end of the window
            /// (`Iter::next_run`, `column.rs:551-622`).
            pub fn nextRun(self: *Iterator) ParseError!?Run {
                return self.nextRunMax(self.items_left);
            }

            /// The next run of equal values, at most `max` rows of it.
            ///
            /// A delta column is the one case that cannot be read run at a
            /// time: its repeat run is a run of equal *differences*, not
            /// of equal values, so the values have to be realized one by
            /// one to find where the run of equal values ends — which is
            /// exactly what upstream's `DeltaRuns` does as well
            /// (`delta/mod.rs:19-26`).
            pub fn nextRunMax(self: *Iterator, max: usize) ParseError!?Run {
                if (comptime E.is_delta) return self.nextRunByValue(max);
                if (max == 0 or self.items_left == 0) return null;
                var budget = max;
                const head = (try self.takeRunInSlab(budget)) orelse return null;
                const value = head.value;
                var count = head.count;
                budget -= count;
                // The layout is only canonical inside a slab, so two runs
                // of one value can sit either side of a boundary and have
                // to come back as one (`column.rs:591-616`). A boundary
                // whose next slab starts with another value is left
                // unstepped, so the run behind it is read again on the
                // next call (`column.rs:609-613`).
                while (budget != 0 and self.items_left != 0 and self.slab_remaining == 0) {
                    const ni = self.slab_idx + 1;
                    if (ni >= self.col.slabs.items.len) break;
                    const nslab = &self.col.slabs.items[ni];
                    const head_run = (try E.runAtOrAfter(nslab.data, 0)) orelse break;
                    if (compareValue(T, head_run.seg.first_value.?, value) != .eq) break;
                    _ = try self.stepToNextSlab();
                    const taken = (try self.takeRunInSlab(budget)) orelse break;
                    count += taken.count;
                    budget -= taken.count;
                }
                return .{ .count = count, .value = value };
            }

            /// Takes the run the cursor stands in, or the first one behind
            /// it, clipped to `budget` rows and to what the window holds.
            ///
            /// A spent slab is not the end of the walk. The run sequence
            /// is only canonical inside a slab, so the cursor steps to
            /// the next slab and looks again — the step `next` takes when
            /// its decoder runs dry, and the one `next_run_max`'s
            /// acquisition loop takes around its decoder call
            /// (`column.rs:569-581`). Past the last slab the window is
            /// drained, so `maxPos` cannot promise rows the data does not
            /// hold (`column.rs:576-577`). Each turn either answers or
            /// steps one slab on, so the walk is bounded by the slab
            /// count even when a slab's bytes run out before its length
            /// says so: such a slab is stepped over, never read again.
            fn takeRunInSlab(self: *Iterator, budget: usize) ParseError!?Run {
                if (budget == 0 or self.items_left == 0) return null;
                while (true) {
                    if (self.slab_remaining != 0) {
                        const slab = &self.col.slabs.items[self.slab_idx];
                        const at = slab.len - self.slab_remaining;
                        if (try self.runSegAt(slab.data, at)) |seg| {
                            return try self.takeRun(seg, at, budget);
                        }
                    }
                    if (!try self.stepToNextSlab()) {
                        self.items_left = 0;
                        return null;
                    }
                }
            }

            /// The run holding item `at` of `data`, answered from the run the
            /// last lookup found while the cursor is still inside it, and
            /// from the codec otherwise. The two answers are the same one:
            /// `runAtOrAfter` returns the run holding `at`, which is one run
            /// for every `at` inside it (`slab.zig`'s `RunAt`).
            fn runSegAt(self: *Iterator, data: []const u8, at: usize) ParseError!?slabmod.Segment(E.Wire) {
                if (self.run_cache) |c| {
                    if (c.slab == self.slab_idx and at >= c.seg.item_start and at < c.seg.item_end) {
                        return c.seg;
                    }
                }
                const ra = (try E.runAtOrAfter(data, at)) orelse {
                    self.run_cache = null;
                    return null;
                };
                self.run_cache = .{ .slab = self.slab_idx, .seg = ra.seg };
                return ra.seg;
            }

            /// Steps onto the next slab, re-reading its decoder and
            /// re-anchoring the running value. `false` when the last slab
            /// is already behind the cursor (`column.rs:574-580`).
            fn stepToNextSlab(self: *Iterator) ParseError!bool {
                const ni = self.slab_idx + 1;
                if (ni >= self.col.slabs.items.len) return false;
                self.slab_idx = ni;
                self.dec = try E.WireDecoder.init(self.col.slabs.items[ni].data);
                self.slab_remaining = self.col.slabs.items[ni].len;
                // A delta column's values are measured from the value in
                // front of their slab, so a jump has to re-anchor on the
                // new slab's base or the rows behind it realize wrongly.
                self.running = self.col.baseOf(ni);
                return true;
            }

            /// Reports the run `seg` holds at `at`, the row the cursor
            /// stands on, and takes as much of it as `budget` and the
            /// window allow.
            ///
            /// The count is the rows of the run *behind the cursor*, not
            /// the whole of the run: a cursor positioned by `iterRange`,
            /// `advanceTo`, `advanceBy`, `seekTo`, `nth` or `shiftNext`
            /// stands in the middle of one, and a run that claimed the
            /// rows in front of the cursor would overrun the window and
            /// corrupt every prefix sum built on it. The decoder counts
            /// the rest of its run the same way, as what is left of it
            /// rather than as its length (`decoder.rs:508-517`:
            /// `self.remaining.min(max)`, where `remaining` is what the
            /// cursor's own `nth` left of the run it landed in,
            /// `decoder.rs:352-359`).
            ///
            /// The decoder moves with the run, so the cursor's two halves
            /// stand on one row and a row read after a run walk starts
            /// where the walk stopped — upstream's decoder is what
            /// consumes the run (`column.rs:586-588`).
            fn takeRun(
                self: *Iterator,
                seg: slabmod.Segment(E.Wire),
                at: usize,
                budget: usize,
            ) ParseError!Run {
                // A run with no value of its own is an absent run, and a run
                // of absent rows is a run of equal values like any other
                // (`rle/decoder.rs:438-497` rule 9) — so it is answered, not
                // refused: the value it carries is the one the column holds
                // for those rows, which for a nullable codec is none. Only a
                // codec with absent runs can name one, and one without is
                // refused here rather than handed a value it has no encoding
                // for (`rle/decoder.rs:428-437`).
                var value: T = undefined;
                if (seg.first_value) |v| {
                    value = v;
                } else {
                    value = try absentValueOf(E, &self.running);
                }
                var count: usize = undefined;
                if (seg.kind == .literal) {
                    // A literal run's values are all distinct, so it is
                    // yielded one row at a time — which is what the
                    // upstream decoder's `next_run` does
                    // (`rle/decoder.rs:266-320`).
                    count = 1;
                } else {
                    count = seg.item_end - at;
                }
                const taken = @min(count, @min(budget, self.items_left));
                if (taken != 0 and seg.kind == .literal) {
                    // **Off the decoder, not off the run's bytes.** A literal
                    // run stores its values as one packed sequence with no
                    // index into it, so reading its `k`-th value reads the
                    // `k` in front of it — and a run walk over a long
                    // literal run asked one row at a time is quadratic in
                    // the run's length. The decoder stands on the row the
                    // cursor is at, by this file's own invariant, so it is
                    // what reads the row being taken.
                    const w = (try self.dec.next()) orelse return error.InvalidValue;
                    value = try E.valueOfWire(w, &self.running);
                    self.at += 1;
                    self.items_left -= 1;
                    self.slab_remaining -= 1;
                    return .{ .count = 1, .value = value };
                }
                try self.skipRows(taken);
                self.at += taken;
                self.items_left -= taken;
                self.slab_remaining -= taken;
                return .{ .count = taken, .value = value };
            }

            /// The next run of equal *values*, for a codec whose runs are
            /// runs of something else: a delta column's repeat run is a run
            /// of equal differences, so the run of equal values has to be
            /// found by realizing them (`delta/mod.rs:19-26`).
            ///
            /// **A run ends where the value changes, and the row that changed
            /// it is left unconsumed.** That row is the first row of the
            /// *next* run, so the next call starts on it and the walk makes
            /// progress: every run answered here is at least one row long and
            /// the cursor stands `count` rows on. A run that ends at the
            /// window's edge is left by the forward walk with nothing to put
            /// back.
            ///
            /// **The row is put back by restoring the cursor rather than by
            /// walking the run again.** The decoder only moves forward, so the
            /// walk takes the cursor as it stands *before* the row that may
            /// end the run and restores that on a change. Two things make the
            /// restore whole rather than partial: the row can be the first of
            /// **next slab**, so the snapshot has to carry which slab the
            /// cursor is on and how much of it is spent, not just the
            /// decoder's place inside one; and a delta column's rows are
            /// measured from the value in front of their slab, so it has to
            /// carry the running value as well — `next` re-anchors that on
            /// the slab it steps onto, which is why restoring the old slab is
            /// enough and the row is read again as the *first* read of the
            /// next slab rather than as a walk.
            ///
            /// **The cost is one cursor copy per row looked at, and nothing
            /// else.** The rows this call accepted stay consumed, so nothing
            /// before the run is decoded a second time. The one row that had
            /// to be read to know the run had ended is read again from where
            /// it was put back — out of the decoder's own run when the run
            /// ended inside a slab, and as the first read of the next slab
            /// when it ended at the last row of one — and that is the whole
            /// of it. The copy itself is plain data: a byte offset, a count,
            /// the run a decoder is serving, a running value and three
            /// counters, over bytes borrowed from a slab that is immutable for
            /// as long as the cursor is. No allocation, no replay, no
            /// decoder rebuild.
            fn nextRunByValue(self: *Iterator, max: usize) ParseError!?Run {
                if (max == 0 or self.items_left == 0) return null;
                // `max` and `items_left` are both non-zero, so the window is
                // at least one row and the run starts on a real value:
                // `held` is that value from the first row on, not a value
                // the loop below is trusted to have written before the
                // return reads it.
                const want = @min(max, self.items_left);
                const held = (try self.next()) orelse return null;
                var count: usize = 1;
                while (count < want) {
                    const before = self.*;
                    const v = (try self.next()) orelse break;
                    if (compareValue(T, v, held) != .eq) {
                        self.* = before;
                        break;
                    }
                    count += 1;
                }
                return .{ .count = count, .value = held };
            }

            /// This cursor as a run iterator (`Iter::runs`, `column.rs:561-563`).
            pub fn runs(self: Iterator) Runs {
                return .{ .inner = self };
            }

            /// Yields the values of `windows` in turn
            /// (`Shiftable::ranges`, `shift.rs:87-99`).
            pub fn ranges(self: Iterator, windows: []const RowRange) Ranges(Iterator) {
                return Ranges(Iterator).init(self, windows);
            }

            /// Captures where this cursor stands, so the same place can be
            /// restored later against an *unwritten* column
            /// (`Iter::suspend`, `column.rs:855-872`).
            pub fn @"suspend"(self: *const Iterator) IterState {
                const slab_len = if (self.slab_idx < self.col.slabs.items.len)
                    self.col.slabs.items[self.slab_idx].len
                else
                    0;
                return .{
                    .counter = self.col.counter,
                    .num_slabs = self.col.slabs.items.len,
                    .slab_idx = self.slab_idx,
                    .pos = self.at,
                    .items_left = self.items_left,
                    .slab_consumed = slab_len - self.slab_remaining,
                };
            }

            /// Scans forward for the next row carrying `target`, without
            /// the values needing to be sorted (`Iter::scan_to_value`,
            /// `column.rs:884-911`).
            ///
            /// On a hit the row is consumed, so repeated calls walk
            /// successive occurrences — including consecutive rows inside
            /// one run, with no run state for the caller to keep. On a
            /// miss the window is drained and `null` comes back.
            pub fn scanToValue(self: *Iterator, target: T) ParseError!?usize {
                const end = self.maxPos();
                var probe = self.*;
                var at = probe.at;
                while (at < end) {
                    const run = (try probe.nextRun()) orelse break;
                    if (compareValue(T, run.value, target) == .eq) {
                        // Consume the real cursor through the hit, with
                        // one indexed jump rather than a row at a time.
                        _ = try self.nth(at - self.at);
                        return at;
                    }
                    at += run.count;
                }
                try self.advanceTo(end);
                return null;
            }

            /// The contiguous run of `target` inside `range`, which must
            /// hold sorted values, with the window left on it
            /// (`Iter::seek_to_value`, `column.rs:913-934`).
            ///
            /// A value that is not present answers an empty range at the
            /// point it would have been inserted.
            ///
            /// The scan runs on a copy narrowed to the range and the real
            /// cursor is moved onto what it found: scanning on the cursor
            /// itself would walk it past the run, leaving `advanceTo` a
            /// no-op and the cursor at the row *behind* the answer
            /// (`column.rs:927-932`).
            pub fn seekToValue(self: *Iterator, target: T, range: RowRange) ParseError!RowRange {
                const window = clampRange(range, self.maxPos());
                if (window.start > self.at) try self.advanceTo(window.start);
                var checkpoint = self.*;
                checkpoint.setMax(window.end);
                const found = try checkpoint.sortedScanToValue(target);
                try self.advanceTo(found.start);
                return found;
            }

            /// The contiguous run of `target` inside this window, moving
            /// the cursor onto it (`Iter::sorted_scan_to_value`,
            /// `column.rs:936-1003`).
            ///
            /// The first run settles the easy three cases — equal, already
            /// past, or before us. Otherwise the slabs behind this one are
            /// binary-searched by their first value and the walk continues
            /// forward from the last slab that starts below `target`
            /// (`column.rs:958-1000`).
            pub fn sortedScanToValue(self: *Iterator, target: T) ParseError!RowRange {
                const start = self.at;
                const end = self.maxPos();
                const first = (try self.nextRun()) orelse return .{ .start = start, .end = start };
                const si_start = self.slab_idx;
                switch (compareValue(T, first.value, target)) {
                    .eq => return .{ .start = start, .end = start + first.count },
                    .gt => return .{ .start = start, .end = start },
                    .lt => {},
                }
                const si_end = self.col.locate(if (end == 0) 0 else end - 1).slab;
                var lo = si_start + 1;
                var hi = si_end + 1;
                var candidate: ?usize = null;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    // The first *wire* entry of a slab, realized against
                    // that slab's own base: a delta column stores a
                    // difference there, so the raw entry is measured from a
                    // different origin in every slab and cannot be
                    // compared with `target` as it stands. Every other
                    // codec's realization is the identity.
                    const wire = (try E.firstRunValue(self.col.slabs.items[mid].data)) orelse
                        return .{ .start = start, .end = start };
                    var base = self.col.baseOf(mid);
                    switch (compareValue(T, try E.valueOfWire(wire, &base), target)) {
                        .lt => {
                            candidate = mid;
                            lo = mid + 1;
                        },
                        else => hi = mid,
                    }
                }
                // The target, if it is there, ends the last slab whose
                // first value is below it.
                if (candidate) |i| try self.advanceTo(self.col.tree.itemsBeforeSlab(i));
                var at = self.at;
                while (try self.nextRun()) |run| {
                    switch (compareValue(T, run.value, target)) {
                        .lt => at += run.count,
                        .gt => return .{ .start = at, .end = at },
                        .eq => return .{ .start = at, .end = at + run.count },
                    }
                }
                return .{ .start = at, .end = at };
            }
        };

        /// The `Shiftable` conformance mark for a value cursor. Its
        /// instantiation *is* the check: a cursor missing any of the eight
        /// methods does not compile (`shift.rs:19-74`).
        pub const shiftable = Shiftable(Iterator);

        /// The same mark for the prefix cursor, which answers the same
        /// three questions about the same window (`shift.rs:142-154`).
        pub const prefix_shiftable = Shiftable(PrefixIter);

        /// The same mark for the run adapter, which positions by row and
        /// not by run (`shift.rs:170-204`).
        pub const runs_shiftable = Shiftable(Runs);
    };
}

/// A standalone slab over the runs `[from, to)` of `bytes`.
///
/// `from < to`: the only caller cuts a non-empty run range, from a
/// `from < segs.len` loop with a budget of at least one run, so the last
/// run in the cut is `segs[to - 1]`. A range that came out empty is
/// refused rather than underflowed.
fn cutPiece(
    gpa: std.mem.Allocator,
    comptime E: type,
    bytes: []const u8,
    segs: []const slabmod.Segment(E.Wire),
    from: usize,
    to: usize,
) ParseError!Slab {
    // `from < to` — the only caller cuts a non-empty run range, from a
    // `from < segs.len` loop with a budget of at least one run — so the
    // last run in the cut is `segs[to - 1]`, and `to` is not zero. Named
    // the way the subtraction reads it.
    if (to == 0 or from >= to) return error.InvalidValue;
    const piece = try E.wireSlice(gpa, bytes, segs[from].byte_start, segs[to - 1].byte_end, segs[from].opens_with_true);
    errdefer gpa.free(piece);
    const m = try slabmod.measure(gpa, E, piece);
    return .{ .data = piece, .len = m.len, .segments = m.segments, .tail = m.tail };
}

/// The item an adapter over `I` names: what `I.next` yields with the error
/// union and the end-of-window marker taken off, and nothing else.
///
/// A cursor's `next` is `ParseError!?T`, so the error union comes off first
/// and then **exactly one** optional: the one that means *the window is
/// spent*. A nullable column's value is an optional too, and it is part of
/// the item — an absent row is a value the column holds, not the end of
/// anything. Peeling every optional made [`Unshift`] and [`Ranges`] name
/// `[]const u8` for a column of `?[]const u8`, which both loses the absent
/// rows on the way out and collapses "an absent row" into "the window ended".
fn IterItem(comptime I: type) type {
    const ret = @typeInfo(@TypeOf(I.next)).@"fn".return_type.?;
    const yielded = switch (@typeInfo(ret)) {
        .error_union => |e| e.payload,
        else => ret,
    };
    return switch (@typeInfo(yielded)) {
        .optional => |o| o.child,
        else => yielded,
    };
}

/// The `Shiftable` trait, as Zig spells a trait: a set of method names
/// (`shift.rs:19-31`) that every positional iterator provides, and the
/// defaults built on them (`shift.rs:36-74`).
///
/// Zig has no traits to inject defaults through, so the defaults live on
/// the cursors themselves — [`Column.Iterator`], [`Column.PrefixIter`]
/// and [`Column.Runs`] each carry all eight — and this is the compile-time
/// check that a cursor of the caller's own has the same kernel, plus the
/// generic form of the two adapters upstream builds on one
/// (`shift.rs:174-236`).
///
/// Repositioning only moves forward: a new range must start at or after
/// the current position. A cursor with a faster way to move than
/// `nth` — a multi-column wrapper, a skipper — overrides `advanceTo` and
/// `advanceBy`, which is what upstream's trait lets it do
/// (`shift.rs:14-18`).
pub fn Shiftable(comptime I: type) type {
    return struct {
        comptime {
            const missing = "a Shiftable cursor needs this method: the Shiftable kernel or one of its defaults";
            if (!@hasDecl(I, "pos")) @compileError(missing);
            if (!@hasDecl(I, "maxPos")) @compileError(missing);
            if (!@hasDecl(I, "setMax")) @compileError(missing);
            if (!@hasDecl(I, "advanceTo")) @compileError(missing);
            if (!@hasDecl(I, "advanceBy")) @compileError(missing);
            if (!@hasDecl(I, "shift")) @compileError(missing);
            if (!@hasDecl(I, "shiftNext")) @compileError(missing);
            if (!@hasDecl(I, "seekTo")) @compileError(missing);
        }

        /// Whether `I` is a `Shiftable` cursor. Always true: the
        /// instantiation is the check.
        pub fn isShiftable() bool {
            return true;
        }
    };
}

/// An iterator with its lookahead already pulled (`Unshift`,
/// `shift.rs:238-294`).
///
/// `init` draws the first item immediately, so `peek` is free and needs no
/// mutable self; `shift` repositions the inner cursor and refills the
/// lookahead from the start of the new range. The top-op scan needs it
/// because the row that terminates one group is the first row of the
/// next (`top_op.rs:169-171`).
pub fn Unshift(comptime I: type) type {
    return struct {
        const Self = @This();

        /// What the inner cursor yields.
        pub const Item = IterItem(I);

        inner: I,
        /// The item `next` will hand back, already drawn. Null once the
        /// inner cursor is spent, and after a `shift` that found nothing.
        held: ?Item,

        /// A wrapper over `inner` with its first item already pulled.
        ///
        /// The item is drawn *before* the struct is built, so the cursor
        /// stored beside it is the one that drew it. Building the struct
        /// from the un-advanced cursor and advancing the local
        /// afterwards stores a cursor one item behind the lookahead, and
        /// `next` hands the first item back a second time; upstream draws
        /// into a local and then builds (`shift.rs:264-267`).
        pub fn init(inner: I) ParseError!Self {
            var cursor = inner;
            const held = try cursor.next();
            return .{ .inner = cursor, .held = held };
        }

        /// The item `next` will return, without consuming it.
        pub fn peek(self: *const Self) ?Item {
            return self.held;
        }

        /// Repositions the inner cursor to `range` and refills the
        /// lookahead from the range's start.
        pub fn shift(self: *Self, range: RowRange) ParseError!void {
            self.held = try self.inner.shiftNext(range);
        }

        /// The next item, pulling one more behind it.
        pub fn next(self: *Self) ParseError!?Item {
            const out = self.held;
            self.held = try self.inner.next();
            return out;
        }
    };
}

/// A cursor that yields the items of several windows in turn
/// (`Shiftable::ranges`, `shift.rs:102-126`).
///
/// Whatever is left of the cursor's own window is discarded when the first
/// range is taken, so the adapter starts at the first range's start and not
/// at wherever the cursor happened to be. Ranges must be ascending and
/// non-overlapping; touching is fine, because a window that ends where the
/// next begins costs nothing to move across.
///
/// Upstream asserts `r.start >= self.iter.get_pos()` with the message
/// "ranges must be ascending and non-overlapping" (`shift.rs:119-122`).
/// This port refuses instead: a descending window would silently re-read
/// rows, and an untrusted caller gets an error rather than a crash. An
/// empty window contributes nothing and does not stop the walk.
pub fn Ranges(comptime I: type) type {
    return struct {
        const Self = @This();

        comptime {
            // The same check `Shiftable` makes: the adapter drives the
            // cursor's window kernel and nothing else.
            if (!@hasDecl(I, "pos")) @compileError("Ranges needs a cursor with pos, setMax and shift");
            if (!@hasDecl(I, "setMax")) @compileError("Ranges needs a cursor with pos, setMax and shift");
            if (!@hasDecl(I, "shift")) @compileError("Ranges needs a cursor with pos, setMax and shift");
        }

        /// What the inner cursor yields.
        pub const Item = IterItem(I);

        inner: I,
        ranges: []const RowRange,
        /// The next range to take.
        at: usize,

        /// The adapter over `cursor`, positioned to yield `ranges` in turn.
        ///
        /// **The cursor's own window is discarded.** `init` empties it with
        /// `setMax(pos)` before anything is pulled, so the first `next`
        /// takes the first range rather than whatever the cursor had left
        /// (`shift.rs:92-95`). A caller that wants the cursor's current
        /// window walked as well has to name it as the first range; there is
        /// no way to keep it and start the ranges from here.
        ///
        /// `ranges` is borrowed, not copied, and must outlive the adapter.
        /// The cursor is taken by value and owned from here.
        pub fn init(cursor: I, ranges: []const RowRange) Self {
            // The window is emptied so the first `next` pulls the first
            // range rather than whatever was left of the old one
            // (`shift.rs:92-95`).
            var c = cursor;
            c.setMax(c.pos());
            return .{ .inner = c, .ranges = ranges, .at = 0 };
        }

        /// The next item, or null once every range is spent.
        pub fn next(self: *Self) ParseError!?Item {
            while (true) {
                if (try self.inner.next()) |v| return v;
                if (self.at >= self.ranges.len) return null;
                const r = self.ranges[self.at];
                self.at += 1;
                if (r.start < self.inner.pos()) return error.InvalidValue;
                try self.inner.shift(r);
            }
        }

        /// Every item of every range, in order. The caller owns the slice.
        pub fn collect(self: *Self, gpa: std.mem.Allocator) ParseError![]Item {
            var out: std.ArrayList(Item) = .empty;
            errdefer out.deinit(gpa);
            while (try self.next()) |v| try out.append(gpa, v);
            return out.toOwnedSlice(gpa);
        }
    };
}

/// A cursor over a boolean column that reports the distance to the next
/// `true` (`BoolColumnSkipper`, `iter/tools.rs:306-383`).
///
/// The op set's visibility and top-op iterators are both built on it:
/// each has a boolean column and a set of rows to step over, and walking
/// the column run-at-a-time turns "skip to the next visible row" into one
/// step per run rather than one per row (`visible.rs:82-101`,
/// `top_op.rs:193-196`).
///
/// A step is a count, not a position: `next` answers how many rows to
/// skip from where the cursor stands to reach the next `true`, and `0`
/// means the very next row is one. A window with no `true` left answers
/// the rest of the window once and then `null`.
pub fn BoolColumnSkipper(comptime E: type) type {
    const Col = Column(bool, E);
    return struct {
        const Self = @This();

        iter: Col.Iterator,
        /// One past the last row the window covers.
        range_end: usize,
        /// The row the next `next` is measured from.
        cursor: usize,
        /// How many further rows are `true` behind the one already found.
        pending: usize,
        /// Whether the window has been walked out.
        exhausted: bool,

        /// A skipper over `iter`, whose window ends at `range_end`.
        pub fn init(iter: Col.Iterator, range_end: usize) Self {
            return .{
                .iter = iter,
                .range_end = range_end,
                .cursor = iter.pos(),
                .pending = 0,
                .exhausted = false,
            };
        }

        /// The distance to the next `true`, or null once the window is
        /// spent.
        pub fn next(self: *Self) ParseError!?usize {
            if (self.exhausted) return null;
            if (self.pending > 0) {
                self.pending -= 1;
                self.cursor += 1;
                return 0;
            }
            var skipped: usize = 0;
            while (try self.iter.nextRun()) |run| {
                if (run.value and run.count > 0) {
                    // The rest of the run is `true` too, and each of those
                    // rows is its own step of zero.
                    self.pending = run.count - 1;
                    const at = self.cursor + skipped;
                    self.cursor = at + 1;
                    return skipped;
                }
                skipped += run.count;
            }
            self.exhausted = true;
            const skip = self.range_end -| self.cursor;
            self.cursor = self.range_end +| 1;
            return skip;
        }

        /// Repositions the skipper to `range` and yields the distance to
        /// the first `true` in it (`iter/tools.rs:334-353`).
        pub fn shiftNext(self: *Self, range: RowRange) ParseError!?usize {
            self.range_end = range.end;
            self.cursor = range.start;
            self.pending = 0;
            self.exhausted = false;
            const value = (try self.iter.shiftNext(range)) orelse {
                self.exhausted = true;
                return range.end -| range.start;
            };
            self.cursor = range.start + 1;
            if (value) return 0;
            const more = (try self.next()) orelse 0;
            return 1 + more;
        }
    };
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

/// The `block`-th value of a column that holds every value three times, so
/// the values form runs of three while the differences a delta column
/// stores form runs of one or two. A nullable column is absent nowhere,
/// which keeps a run of nulls out of the run shapes being read.
fn blockValue(comptime T: type, block: usize) T {
    const v: payloadOf(T) = @intCast(block);
    return v;
}

/// The column's structural invariants, with a report rather than a panic.
fn expectSound(comptime T: type, comptime E: type, col: *const Column(T, E)) !void {
    if (try col.checkInvariants()) |v| {
        if (v.detail_len != 0) {
            std.debug.print("invariant broken: {s} {s} ({s}, node {d} of {d} slabs)\n", .{
                @typeName(E), v.what, v.detail(), v.at, col.slabCount(),
            });
        } else {
            std.debug.print("invariant broken: {s} {s} (slab {d} of {d})\n", .{
                @typeName(E), v.what, v.at, col.slabCount(),
            });
        }
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
    // (`RunWriter`, `rle/decoder.rs:438-497` rule 4), so only a repeated
    // value makes a run of its own.
    for (0..5000) |i| try many.append(gpa, i / 2);
    try col.extend(gpa, many.items);
    try expectSound(u64, Rle(u64), &col);
    try testing.expect(col.slabCount() > 1);

    const segs = try col.slabSegments(gpa);
    defer gpa.free(segs);
    for (segs) |n| try testing.expect(n <= default_max_segments or n == 1);
}

// ── The read surface ────────────────────────────────────────────────────────

/// The rows a range iterator over `range` must yield, in order: the window
/// is clamped, the cursor starts where the window does, and the value slice
/// over the same range is the same answer.
fn expectRange(
    comptime T: type,
    comptime E: type,
    col: *const Column(T, E),
    model: []const T,
    range: RowRange,
) !void {
    const window = clampRange(range, model.len);
    var it = try col.iterRange(range);
    try testing.expectEqual(window.start, it.pos());
    try testing.expectEqual(window.end, it.maxPos());
    try testing.expectEqual(window.end - window.start, it.itemsLeft());
    var i = window.start;
    while (try it.next()) |v| {
        if (i >= window.end) return error.TestUnexpectedResult;
        try testing.expectEqual(model[i], v);
        i += 1;
    }
    try testing.expectEqual(window.end, i);
    const slice = try col.sliceRange(testing.allocator, range);
    defer testing.allocator.free(slice);
    try testing.expectEqualSlices(T, model[window.start..window.end], slice);
}

/// The column's values as an owned slice, for a test that wants to compare
/// them against a model and free them.
fn owned(comptime T: type, comptime E: type, col: *const Column(T, E)) ![]T {
    return col.toSlice(testing.allocator);
}

//  An empty column answers a range, a seek, a run walk and a scope without
//  complaining, and an empty column is "only" every default — which is what
//  makes `encodeUnless` write nothing for it.
test "an empty column answers every range and every seek" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try expectRange(u64, Rle(u64), &col, &.{}, .{ .start = 0, .end = 0 });
    try expectRange(u64, Rle(u64), &col, &.{}, .{ .start = 5, .end = 9 });
    try expectRange(u64, Rle(u64), &col, &.{}, .{ .start = 9, .end = 5 });
    var it = try col.iterator();
    try testing.expect((try it.next()) == null);
    try testing.expectEqual(@as(usize, 0), it.pos());
    try testing.expect((try it.nth(0)) == null);
    try testing.expect((try it.nextRun()) == null);
    try testing.expect(try col.isOnly(0));
    try testing.expect((try col.encodeUnless(gpa, 0)) == null);
    try testing.expectEqual(
        RowRange{ .start = 0, .end = 0 },
        try col.scopeToValue(0, .{ .start = 0, .end = 0 }),
    );
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectEqualSlices(u8, &.{}, bytes);
}

//  A prefix cursor's runs carry lengths, and the run of lengths is what a text
//  scan walks: one step per run, not per row. The value describes the run's
//  *final* row, so `total()` is the sum through the end of the run and a row
//  with no length holds the sum where it was.
test "a prefix cursor's runs carry the running sum through the run" {
    const gpa = testing.allocator;
    var col = try Column(u32, Prefix(u32)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 2, 2, 2, 5, 0, 5 });
    var it = try col.prefixIter();
    const first = (try it.nextRun()).?;
    try testing.expectEqual(@as(usize, 3), first.count);
    try testing.expectEqual(@as(u32, 2), first.value.value);
    try testing.expectEqual(@as(i64, 6), first.value.total());
    try testing.expectEqual(@as(i64, 4), first.value.prefix());
    const second = (try it.nextRun()).?;
    try testing.expectEqual(@as(usize, 1), second.count);
    try testing.expectEqual(@as(i64, 11), second.value.total());
    const third = (try it.nextRun()).?;
    try testing.expectEqual(@as(i64, 11), third.value.total());
    const fourth = (try it.nextRun()).?;
    try testing.expectEqual(@as(i64, 16), fourth.value.total());
    try testing.expect((try it.nextRun()) == null);
}

//  The successor columns are loaded at a *different* length from the rest of
//  the op set: the grand total of `succ_count` is how many successors there
//  are, and it is a prefix sum (`op_set2/columns.rs:294-300`). So a prefix
//  column sizes a plain one, the plain one is held to that length, and one the
//  document omitted comes back as that many copies of the default.
test "a prefix column's grand total sizes a companion column" {
    const gpa = testing.allocator;
    const counts = [_]u32{ 2, 0, 3, 1, 0, 4, 0, 0, 2 };
    var succ_count = try Column(u32, Prefix(u32)).init(gpa);
    defer succ_count.deinit();
    try succ_count.extend(gpa, &counts);
    const succ_len: usize = @intCast(try succ_count.getPrefix(counts.len));
    try testing.expectEqual(@as(usize, 12), succ_len);

    const actors = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const bytes = try Rle(u32).wireEncode(gpa, &actors, false);
    defer gpa.free(bytes);
    {
        var succ_actor = try Column(u32, Rle(u32)).loadWith(
            gpa,
            bytes,
            Column(u32, Rle(u32)).LoadOpts.new().withLength(succ_len),
        );
        defer succ_actor.deinit();
        const loaded = try owned(u32, Rle(u32), &succ_actor);
        defer gpa.free(loaded);
        try testing.expectEqualSlices(u32, &actors, loaded);
    }
    {
        var succ_actor = try Column(u32, Rle(u32)).loadWith(
            gpa,
            &.{},
            Column(u32, Rle(u32)).LoadOpts.new().withLength(succ_len).withFill(0),
        );
        defer succ_actor.deinit();
        try testing.expectEqual(@as(usize, succ_len), succ_actor.len());
        try testing.expect(try succ_actor.isOnly(0));
    }
}

//  A nullable prefix column: a row with no length contributes nothing, and
//  the inverse steps over it rather than dividing by it.
test "a nullable prefix column's null rows contribute nothing" {
    const gpa = testing.allocator;
    const widths = [_]?u32{ 2, null, 3, null, null, 4 };
    var col = try Column(?u32, Prefix(?u32)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &widths);
    // The exclusive prefixes are 0, 2, 2, 5, 5, 5, 9.
    try testing.expectEqual(@as(i64, 0), try col.getPrefix(0));
    try testing.expectEqual(@as(i64, 2), try col.getPrefix(1));
    try testing.expectEqual(@as(i64, 2), try col.getPrefix(2));
    try testing.expectEqual(@as(i64, 5), try col.getPrefix(3));
    try testing.expectEqual(@as(i64, 5), try col.getPrefix(5));
    try testing.expectEqual(@as(i64, 9), try col.getPrefix(widths.len));
    try testing.expectEqual(@as(usize, 1), try col.getIndexForPrefix(2));
    try testing.expectEqual(@as(usize, 3), try col.getIndexForPrefix(5));
    try testing.expectEqual(@as(usize, 6), try col.getIndexForPrefix(9));
    try testing.expectEqual(@as(usize, 5), try col.getIndexForTotal(9));
    var it = try col.prefixIter();
    for (widths, 0..) |_, i| {
        const pv = (try it.next()).?;
        try testing.expectEqual(widths[i], pv.value);
    }
    try testing.expectEqual(@as(i64, 9), it.total());
}

//  A prefix column is the only column that answers the prefix questions: a
//  delta column's running value is a *value*, not a sum of lengths, and a
//  boolean column is a third thing again.
test "only a prefix column answers the prefix questions" {
    const gpa = testing.allocator;
    {
        var col = try Column(u32, Delta(u32)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ 5, 6, 7 });
        try testing.expectError(error.Unsupported, col.getPrefix(1));
        try testing.expectError(error.Unsupported, col.getIndexForPrefix(1));
        try testing.expectError(error.Unsupported, col.getIndexForTotal(1));
        try testing.expectError(error.Unsupported, col.sumRange(.{ .start = 0, .end = 1 }));
        try testing.expectError(error.Unsupported, col.prefixIter());
        try testing.expectError(error.Unsupported, col.prefixIterRange(.{ .start = 0, .end = 1 }));
    }
    {
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ 5, 6, 7 });
        try testing.expectError(error.Unsupported, col.getPrefix(1));
        try testing.expectError(error.Unsupported, col.prefixIter());
    }
    {
        var col = try Column(bool, Bool).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ true, false });
        try testing.expectError(error.Unsupported, col.getPrefix(1));
    }
}

//  The wire form is one canonical run sequence over every value, whatever the
//  slab layout was. This is the codec's own answer for the whole value
//  sequence at once, so a seam that joined two runs wrongly — or dropped a
//  slab behind it — would make the two differ. It is what the literal-header
//  rewrite in `encode` has to preserve.
test "the wire form is the one canonical sequence over every value" {
    try expectWholeWireForm(u32, Rle(u32));
    try expectWholeWireForm(?u32, RleOption(u32));
    try expectWholeWireForm(bool, Bool);
}

fn expectWholeWireForm(comptime T: type, comptime E: type) !void {
    const gpa = testing.allocator;
    const built = try buildRuns(T, E, 400);
    var col = built.col;
    defer col.deinit();
    var owned_model = built.model;
    defer owned_model.deinit(gpa);
    const model = owned_model.items;
    try testing.expect(col.slabCount() > 3);

    const got = try col.encode(gpa);
    defer gpa.free(got);
    const want = try E.wireEncode(gpa, model, false);
    defer gpa.free(want);
    try testing.expectEqualSlices(u8, want, got);
    var back = try Column(T, E).load(gpa, got);
    defer back.deinit();
    const reloaded = try owned(T, E, &back);
    defer gpa.free(reloaded);
    try testing.expectEqualSlices(T, model, reloaded);
}

// ── The run cursor over a delta column ─────────────────────────────────────

/// A delta column's runs are runs of *values*, found by realizing the runs
/// of differences the wire actually stores (`delta/mod.rs:1610-1622`). A
/// column that holds every value three times is the shape that shows the
/// difference: 192 rows of `0,0,0,1,1,1,…` are 127 runs of one or two
/// differences each, and 64 runs of three values, and the two answers are
/// not the same.
///
/// The window is one value-run long, so a run ends on the window's edge
/// rather than on a value change, and the cursor is left on the row behind
/// the run it just handed over. The column spans several slabs, so the
/// windows cross slab boundaries too.
fn exerciseDeltaValueRuns(comptime T: type, comptime E: type) !void {
    const gpa = testing.allocator;
    const rows: usize = 192;
    var col = try Column(T, E).init(gpa);
    defer col.deinit();
    const model = try gpa.alloc(T, rows);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = blockValue(T, i / 3);
    for (model) |v| try col.append(gpa, v);
    try expectSound(T, E, &col);
    // The point of the shape: the values are not the wire's runs, so a
    // cursor that read the wire's runs would answer something else.
    try testing.expect(col.slabCount() > 1);
    try expectModel(T, E, &col, model);

    // A window of one value-run: the whole run, and the cursor on the row
    // behind it. The value never changes inside the window, so the count
    // is the window and the value is the one the run started on.
    var it = try col.iterator();
    var at: usize = 0;
    while (at < model.len) {
        const run = (try it.nextRunMax(3)).?;
        try testing.expectEqual(@as(usize, 3), run.count);
        try testing.expectEqual(model[at], run.value);
        at += run.count;
        try testing.expectEqual(at, it.pos());
    }
    try testing.expectEqual(model.len, at);
    try testing.expect((try it.nextRunMax(3)) == null);

    // A window of one row: the run of three is cut rather than reported
    // whole, and exactly the row asked for is taken, in order, to the end.
    var one = try col.iterator();
    for (model, 0..) |v, i| {
        const run = (try one.nextRunMax(1)).?;
        try testing.expectEqual(@as(usize, 1), run.count);
        try testing.expectEqual(v, run.value);
        try testing.expectEqual(i + 1, one.pos());
    }
    try testing.expect((try one.nextRunMax(1)) == null);

    // A window of no rows is not a run, and takes nothing.
    var none = try col.iterator();
    try testing.expect((try none.nextRunMax(0)) == null);
    try testing.expectEqual(@as(usize, 0), none.pos());
}

test "a delta column's runs are runs of values, not of differences" {
    try exerciseDeltaValueRuns(i64, Delta(i64));
    try exerciseDeltaValueRuns(?u32, DeltaOption);
}

// ── A column whose index could not be rebuilt ──────────────────────────────

/// Loads a column, reads every value back through the index the load
/// built, and gives the column back — for the allocation-failure test
/// below.
///
/// The read and the `defer` are both the point. A `reindex` that tore the
/// old index down before it built the new one came back from an
/// out-of-memory with `self.tree` undefined, because `Tree.deinit` ends in
/// `self.* = undefined` (`btree.zig:248`). Both the walk and the free then
/// ran on a tree whose arena pointer was never written, which is what
/// this test is here to make loud.
fn loadRleThenRead(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var col = try Column(u64, Rle(u64)).load(gpa, bytes);
    defer col.deinit();
    const all = try col.toSlice(gpa);
    defer gpa.free(all);
    try testing.expect(all.len > 0);
    var it = try col.iterator();
    var seen: usize = 0;
    while (try it.next()) |v| {
        try testing.expectEqual(all[seen], v);
        seen += 1;
    }
    try testing.expectEqual(all.len, seen);
}

test "a column survives every allocation failure while its index is built" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    // 300 distinct values: 300 runs, so a load cuts several slabs and the
    // index the load builds is more than one leaf.
    for (0..300) |i| try col.append(gpa, @intCast(i));
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    try testing.checkAllAllocationFailures(gpa, loadRleThenRead, .{bytes});
}

/// A column built by the public streaming encoder and handed over by
/// `intoColumn`, with no run budget — the one-contiguous-buffer path, where
/// the encoder's buffer is a **local** until it is in the column's slab list.
/// A refusal anywhere on the way has to give that buffer back exactly once:
/// an errdefer for the list is not enough, because it is not armed on the
/// path where the buffer becomes the list's.
fn streamOneBufferThenRead(gpa: std.mem.Allocator, values: []const u64) !void {
    const Col = Column(u64, Rle(u64));
    var enc = Col.Encoder.init(gpa);
    defer enc.deinit();
    try enc.extend(values);
    var col = try enc.intoColumn();
    defer col.deinit();
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, values, got);
}

/// The same through the budgeted path, where `intoColumn` rolls the pending
/// buffer into a slab and moves the rolled list into the column.
fn streamBudgetedThenRead(gpa: std.mem.Allocator, values: []const u64) !void {
    const Col = Column(u64, Rle(u64));
    var enc = Col.Encoder.init(gpa);
    defer enc.deinit();
    try enc.maxSegments(4);
    try enc.extend(values);
    var col = try enc.intoColumn();
    defer col.deinit();
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, values, got);
}

test "a streaming encoder gives its bytes back on every allocation failure" {
    // The sweep runs a successful build, then refuses each allocation.
    // Its testing.allocator backing catches bytes leaked on either path.
    const gpa = testing.allocator;
    // Runs of one, two, four and one, so the column is cut into several
    // slabs on the budgeted path and left as one buffer on the other.
    const values = [_]u64{ 3, 3, 3, 1, 2, 2, 9, 9, 0, 4, 4, 4, 4, 7 };
    try testing.checkAllAllocationFailures(gpa, streamOneBufferThenRead, .{values[0..]});
    try testing.checkAllAllocationFailures(gpa, streamBudgetedThenRead, .{values[0..]});
}

/// One refused splice over a column of `model`, built and spliced with
/// `gpa`. Whatever the outcome, the column has to come out readable: its
/// own invariant check passing, `len` counting the rows it decodes, and its
/// values being either the ones it started with or the ones the splice
/// asked for — never a mixture, and never a set of rows the count does not
/// cover.
///
/// The read is deliberately taken with `testing.allocator` rather than
/// `gpa`, so that a refusal inside the splice is the only refusal this
/// helper can see and the assertions always run.
fn oomSpliceThenRead(
    comptime T: type,
    comptime E: type,
    gpa: std.mem.Allocator,
    model: []const T,
    index: usize,
    del: usize,
    ins: []const T,
) !void {
    var col = try Column(T, E).initWithBudget(gpa, 4);
    defer col.deinit();
    try col.extend(gpa, model);

    var want: std.ArrayList(T) = .empty;
    defer want.deinit(testing.allocator);
    try want.appendSlice(testing.allocator, model[0..index]);
    try want.appendSlice(testing.allocator, ins);
    try want.appendSlice(testing.allocator, model[index + del ..]);

    var committed = true;
    if (col.splice(gpa, index, del, ins)) |_| {} else |e| {
        // The bounds are checked before anything moves, so the only error a
        // valid request can come back with is the allocator.
        if (e != error.OutOfMemory) return e;
        committed = false;
    }

    try testing.expect((try col.checkInvariants()) == null);
    const got = try col.toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(got.len, col.len());
    if (committed) {
        try testing.expectEqualSlices(T, want.items, got);
    } else {
        // **A refusal leaves the column exactly as it was.** A half-applied
        // splice — rows written but not counted, a range dropped but not
        // rebuilt, bases measured from the wrong slab, an index describing
        // the layout before the cut — is what the stage seam exists to
        // prevent, and each of them would show here as a value sequence that
        // is neither list.
        try testing.expectEqualSlices(T, model, got);
    }
    // Teardown is `testing.allocator`'s to check: a column whose splice was
    // refused has to give back every byte it was holding.
}

/// Sweeps every allocation the one splice of `oomSpliceThenRead` makes.
fn sweepSplice(
    comptime T: type,
    comptime E: type,
    model: []const T,
    ins: []const T,
    index: usize,
    del: usize,
) !void {
    const gpa = testing.allocator;
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        try oomSpliceThenRead(T, E, failing.allocator(), model, index, del, ins);
        break :blk failing.alloc_index;
    };
    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        // A refusal in the *setup* says nothing about the splice, so it is
        // skipped rather than counted as a pass: `fail_index` counts from the
        // first allocation of the run, and the run's first allocations are
        // the column's own.
        oomSpliceThenRead(T, E, failing.allocator(), model, index, del, ins) catch |e| switch (e) {
            error.OutOfMemory => continue,
            else => return e,
        };
    }
}

test "a refused splice leaves the length, the values and the caches in step" {
    // **A splice rewrites the slab bytes before the last step that can be
    // refused.** The splice path takes that step's room while the column is
    // still intact, and the length is published with the bytes rather than
    // after them, so the only thing a refusal can leave behind is the column
    // as it was. Three shapes, because the three rewrite steps differ: a
    // cut across slabs (which frees the old slabs before installing the
    // pieces), a cut inside one slab (which splits it), and a plain column
    // (which keeps no per-slab bases at all).
    const model = [_]i64{ 100, 250, 400, 550, 700, 850, 1000, 1150 };
    const ins = [_]i64{ -50, -50, 2000, 0, 0, -900 };

    // Across slabs: eight distinct rows over a budget of four, so the cut
    // drops two of one slab's runs and rebuilds several budgeted slabs in
    // their place.
    try sweepSplice(i64, Delta(i64), &model, &ins, 3, 2);
    // Inside one slab, through `settle`'s split.
    try sweepSplice(i64, Delta(i64), &model, &ins, 1, 1);
    // A plain column: `len` is the only cache in play, and the split is the
    // only step that can be refused after the bytes move.
    try sweepSplice(i64, Rle(i64), &model, &ins, 3, 2);
}

/// The column reads exactly as `want`, and its length counts what it decodes.
fn expectColumn(comptime T: type, comptime E: type, col: *const Column(T, E), want: []const T) !void {
    try testing.expect((try col.checkInvariants()) == null);
    const got = try col.toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(got.len, col.len());
    try testing.expectEqualSlices(T, want, got);
}

/// One refused pair of staged splices, on two columns of `model`.
///
/// **Both stages are built before either is published** — the order the seam
/// exists for — so after a refusal in either one there is a stage in hand and
/// nothing has moved, and both columns have to read exactly as they did. The
/// reads are taken with `testing.allocator` rather than `gpa`, so a refusal
/// inside a stage is the only refusal this helper can see.
fn oomTwoStagesThenPublish(
    comptime T: type,
    comptime E: type,
    gpa: std.mem.Allocator,
    model: []const T,
    ins: []const T,
    left_at: usize,
    left_del: usize,
    right_at: usize,
    right_del: usize,
) !void {
    var left = try Column(T, E).initWithBudget(gpa, 4);
    defer left.deinit();
    var right = try Column(T, E).initWithBudget(gpa, 4);
    defer right.deinit();
    try left.extend(gpa, model);
    try right.extend(gpa, model);

    var want_left: std.ArrayList(T) = .empty;
    defer want_left.deinit(testing.allocator);
    try want_left.appendSlice(testing.allocator, model[0..left_at]);
    try want_left.appendSlice(testing.allocator, ins);
    try want_left.appendSlice(testing.allocator, model[left_at + left_del ..]);
    var want_right: std.ArrayList(T) = .empty;
    defer want_right.deinit(testing.allocator);
    try want_right.appendSlice(testing.allocator, model[0..right_at]);
    try want_right.appendSlice(testing.allocator, ins);
    try want_right.appendSlice(testing.allocator, model[right_at + right_del ..]);

    var a = left.stageSplice(left_at, left_del, ins) catch |e| switch (e) {
        error.OutOfMemory => {
            // The first stage refused. There is nothing in hand and nothing
            // published; the second column was never even asked.
            try expectColumn(T, E, &left, model);
            try expectColumn(T, E, &right, model);
            return;
        },
        // Anything else is an answer about the request rather than about the
        // allocator, and this is a fixed in-range point, so it is propagated
        // rather than turned into a pass.
        else => return e,
    };
    defer a.deinit();

    var b = right.stageSplice(right_at, right_del, ins) catch |e| switch (e) {
        error.OutOfMemory => {
            // **A stage is in hand and is still discarded.** Nothing has been
            // published, so both columns still read as they did — which is
            // the whole point of staging both before publishing either, and
            // the case that is a half-applied write if the publish comes
            // first.
            try expectColumn(T, E, &left, model);
            try expectColumn(T, E, &right, model);
            return;
        },
        else => return e,
    };
    defer b.deinit();

    // Both in hand, and both publishes infallible: the set is whole or it is
    // untouched, never half.
    a.publish(&left);
    b.publish(&right);
    try expectColumn(T, E, &left, want_left.items);
    try expectColumn(T, E, &right, want_right.items);
}

/// Sweeps every allocation the two stages of `oomTwoStagesThenPublish` make.
fn sweepTwoStages(
    comptime T: type,
    comptime E: type,
    model: []const T,
    ins: []const T,
    left_at: usize,
    left_del: usize,
    right_at: usize,
    right_del: usize,
) !void {
    const gpa = testing.allocator;
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        try oomTwoStagesThenPublish(T, E, failing.allocator(), model, ins, left_at, left_del, right_at, right_del);
        break :blk failing.alloc_index;
    };
    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        // A refusal in the *setup* says nothing about a stage, so it is
        // skipped rather than counted as a pass: `fail_index` counts from the
        // first allocation of the run, and the run's first allocations are
        // the two columns' own.
        oomTwoStagesThenPublish(T, E, failing.allocator(), model, ins, left_at, left_del, right_at, right_del) catch |e| switch (e) {
            error.OutOfMemory => continue,
            else => return e,
        };
    }
}

test "a staged splice publishes whole, and a refused one moves nothing" {
    // **The seam `Columns.splice` and `Columns.removeOps` are waiting on.**
    // Twenty columns written one after another is all-or-nothing only if the
    // twenty can each be prepared first and committed afterwards: a refusal
    // after the seventh commit leaves seven columns longer than the other
    // thirteen. Here it is two columns and every allocation of both stages
    // is swept, and the assertion is that a refusal leaves **both** reading
    // as they did — including the case where the first stage is already in
    // hand and the second is the one that refuses.
    //
    // One codec of each shape, because the staging machinery has to hold for
    // all of them: the plain one keeps no per-slab bases, the delta one
    // re-anchors a row behind the cut and keeps those bases, and the
    // nullable prefix one makes the cut land past absent rows. A removal is
    // the same call with `del > 0`, which is why the four shapes below run
    // both an insert and a delete.
    const model = [_]i64{ 100, 250, 400, 550, 700, 850, 1000, 1150 };
    const ins = [_]i64{ -50, -50, 2000, 0, 0, -900 };
    const none = [_]i64{};

    try sweepTwoStages(i64, Rle(i64), &model, &ins, 2, 1, 5, 2);
    try sweepTwoStages(i64, Rle(i64), &model, &none, 2, 3, 5, 2);
    try sweepTwoStages(i64, Delta(i64), &model, &ins, 2, 1, 5, 2);
    try sweepTwoStages(i64, Delta(i64), &model, &none, 2, 3, 5, 2);

    // A nullable prefix column, where a cut can land past absent rows and
    // the row behind it still has to be re-anchored — the case the delta and
    // prefix base caches exist for.
    const opt_model = [_]?i64{ 100, null, 250, null, 400, 550, null, 700 };
    const opt_ins = [_]?i64{ null, -50, 2000, null, -900 };
    const opt_none = [_]?i64{};
    try sweepTwoStages(?i64, Prefix(?i64), &opt_model, &opt_ins, 2, 1, 4, 2);
    try sweepTwoStages(?i64, Prefix(?i64), &opt_model, &opt_none, 2, 3, 4, 2);
}

/// Stages a splice in a frame of its own and hands the stage back **by
/// value**, so by the time the caller has it the address it was built at no
/// longer exists. This is the ordinary way a caller will use it — a helper
/// that stages on the caller's behalf — and it is the shape that caught the
/// provisional column's ownership flags outliving their frame.
fn stageOutOfHelper(
    comptime T: type,
    comptime E: type,
    col: *Column(T, E),
    index: usize,
    del: usize,
    ins: []const T,
) ParseError!Column(T, E).StagedSplice {
    return col.stageSplice(index, del, ins);
}

/// Writes over more stack than a call frame holds, so whatever a returned
/// helper left at that address is gone before the caller reads the stage.
fn clobberStack() void {
    var junk: [4096]u64 = undefined;
    for (&junk, 0..) |*w, i| w.* = @intCast(i);
    std.mem.doNotOptimizeAway(&junk);
}

/// One refused abort of a stage that has been moved out of the frame it was
/// built in. The column has to come out exactly as it went in: same values,
/// same length, same slab count, and the same bytes — which is the whole of
/// what a stage promises, and the thing a dangling read of the ownership
/// flags would take away.
fn oomMovedStageThenAbort(gpa: std.mem.Allocator, model: []const i64, ins: []const i64) !void {
    const T = i64;
    const E = Rle(i64);
    var col = try Column(T, E).initWithBudget(gpa, 4);
    defer col.deinit();
    try col.extend(gpa, model);

    // What the abort must not disturb, taken with `testing.allocator` so a
    // refusal inside the stage is the only refusal this helper can see.
    const before = try col.encode(testing.allocator);
    defer testing.allocator.free(before);
    const before_len = col.len();
    const before_slabs = col.slabCount();

    var s = stageOutOfHelper(T, E, &col, 2, 1, ins) catch |e| switch (e) {
        error.OutOfMemory => {
            // The stage never existed. The column is untouched and the
            // provisional column's own scaffolding has already given its
            // bytes back.
            try expectColumn(T, E, &col, model);
            try testing.expectEqual(before_len, col.len());
            try testing.expectEqual(before_slabs, col.slabCount());
            return;
        },
        else => return e,
    };
    // The stage is on the caller's stack now; the frame it was built in is
    // gone. Overwrite that ground before touching it.
    clobberStack();

    s.deinit();
    // The abort after an abort, on a moved stage: a no-op rather than a
    // second free of the same staged slabs.
    s.deinit();

    try expectColumn(T, E, &col, model);
    try testing.expectEqual(before_len, col.len());
    try testing.expectEqual(before_slabs, col.slabCount());
    const after = try col.encode(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
    // `testing.allocator` sees the teardown: the stage's staged slabs, its
    // weight list, its index arena and its bookkeeping all go back, and not
    // one of the column's own buffers is freed.
}

/// Sweeps every allocation the moved stage of `oomMovedStageThenAbort` makes.
fn sweepMovedStage(gpa: std.mem.Allocator, model: []const i64, ins: []const i64) !void {
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        try oomMovedStageThenAbort(failing.allocator(), model, ins);
        break :blk failing.alloc_index;
    };
    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        // A refusal in the *setup* — the column the stage runs against never
        // got built — says nothing about the stage, so it is skipped rather
        // than counted as a pass.
        oomMovedStageThenAbort(failing.allocator(), model, ins) catch |e| switch (e) {
            error.OutOfMemory => continue,
            else => return e,
        };
    }
}

test "a stage moved out of the frame it was built in aborts to nothing" {
    // **The stage is a value, so a caller may move it.** It was not: the
    // provisional column inside it held a pointer to the ownership flags on
    // the stack frame `stageSplice` was building in, and returning the stage
    // by value left that pointer naming a frame that had ended. The abort
    // read through it. This is the consumer-visible shape of that: stage
    // through a helper, move the result, overwrite the ground it came from,
    // abort — and the column must be exactly what it was.
    //
    // No assertion here looks at an address or a layout. What is checked is
    // the promise a caller can see: the values, the length, the slab count,
    // the invariants, and the bytes the column encodes to.
    const model = [_]i64{ 100, 250, 400, 550, 700, 850, 1000, 1150 };
    const ins = [_]i64{ -50, -50, 2000, 0, 0, -900 };
    try sweepMovedStage(testing.allocator, &model, &ins);
}

/// One refused seed of the first slab, over a fresh column.
///
/// **`ensureSlab` puts the slab in the list before the caches are rebuilt**,
/// and both rebuilds allocate. Whatever the seed comes back with, the column
/// has to be the one it started with — and, either way, a column a write
/// lands in, because that is the whole reason the seed exists.
fn oomEnsureSlabThenWrite(
    comptime T: type,
    comptime E: type,
    gpa: std.mem.Allocator,
) !void {
    var col = try Column(T, E).initWithBudget(gpa, 4);
    defer col.deinit();
    // What the column is on entry, so the refusal arm asserts "as it was"
    // rather than a number this test would otherwise have to keep true.
    const before_slabs = col.slabCount();

    var committed = true;
    if (col.ensureSlab()) |_| {} else |e| {
        // The column is empty and the request is a constant one, so the only
        // error a seed can come back with is the allocator.
        if (e != error.OutOfMemory) return e;
        committed = false;
    }

    try testing.expect((try col.checkInvariants()) == null);
    try testing.expectEqual(@as(usize, 0), col.len());
    if (committed) {
        try testing.expectEqual(@as(usize, 1), col.slabCount());
    } else {
        // **A refusal puts the slab back out.** One slab against an index that
        // still describes none is a column that does not describe itself, and
        // the check above is what names it.
        try testing.expectEqual(before_slabs, col.slabCount());
    }
    // Either way the column is still a column a write lands in.
    const row = [_]T{genValue(T, 1)};
    try col.splice(gpa, 0, 0, &row);
    try expectColumn(T, E, &col, &row);
    // Teardown is `testing.allocator`'s to check: a column whose seed was
    // refused has to give back every byte it was holding.
}

/// Sweeps every allocation the one seed of `oomEnsureSlabThenWrite` makes.
fn sweepEnsureSlab(comptime T: type, comptime E: type) !void {
    const gpa = testing.allocator;
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        try oomEnsureSlabThenWrite(T, E, failing.allocator());
        break :blk failing.alloc_index;
    };
    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        // A refusal in the *setup* — the column the seed runs against never
        // got built — says nothing about the seed, so it is skipped rather
        // than counted as a pass.
        oomEnsureSlabThenWrite(T, E, failing.allocator()) catch |e| switch (e) {
            error.OutOfMemory => continue,
            else => return e,
        };
    }
}

test "a refused slab seed leaves a column with no slabs and no caches" {
    // **The edit cursor opens on a fresh column and asks for a slab to land
    // in.** A seed that refuses has to leave that column exactly as it was:
    // the slab it may already have put in the list comes back out, and the
    // index and the bases agree with a column that has none.
    //
    // Three codecs, because the seed's two halves are shaped by the codec: one
    // that keeps no bases, one nullable that keeps none either, and one that
    // carries a prefix sum and so has an array to seed alongside the slab.
    try sweepEnsureSlab(i64, Rle(i64));
    try sweepEnsureSlab(?i64, RleOption(i64));
    try sweepEnsureSlab(?i64, Prefix(?i64));
}

// ── The row cursor across slab boundaries ──────────────────────────────────

/// A value for the cursor tests: every value five rows long, with every
/// seventh block absent. The runs are longer than one row and an absent
/// run is as long as a present one, so a window that starts part way
/// through a slab starts part way through a run — the case a run cursor
/// standing in a run has to answer.
fn blockRunValue(i: usize) ?i64 {
    const block = i / 5;
    if (block % 7 == 3) return null;
    return @intCast(block);
}

/// A nullable `i64` column of `rows` such values in one splice, with the
/// model beside it. One wide splice is what spreads them over many slabs:
/// a slab holds 64 runs (`slab.zig:111-114`), so 4000 rows of five-row runs is
/// a dozen slabs and every cursor over it has to cross a boundary.
fn cursorColumn(rows: usize) !struct { col: Column(?i64, RleOption(i64)), model: []?i64 } {
    const gpa = testing.allocator;
    const model = try gpa.alloc(?i64, rows);
    errdefer gpa.free(model);
    for (model, 0..) |*v, i| v.* = blockRunValue(i);
    var col = try Column(?i64, RleOption(i64)).init(gpa);
    errdefer col.deinit();
    try col.splice(gpa, 0, 0, model);
    // The shape is the point: with one slab every boundary below is
    // crossed by accident and none of the tests can fail.
    if (col.slabCount() < 3) return error.TestUnexpectedResult;
    return .{ .col = col, .model = model };
}

/// The rows of `model` a cursor yields from where it stands to `end`, each
/// on the position the cursor reports, and then nothing: the window's
/// edge is where the walk stops.
fn expectRows(
    model: []const ?i64,
    it: *Column(?i64, RleOption(i64)).Iterator,
    end: usize,
) !void {
    var at = it.pos();
    while (at < end) {
        const v = (try it.next()) orelse {
            std.debug.print("no value at {d}\n", .{at});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(model[at], v);
        at += 1;
        try testing.expectEqual(at, it.pos());
    }
    try testing.expect((try it.next()) == null);
    try testing.expectEqual(end, it.pos());
}

/// The runs of `it` as the model says they are: each run is rows of one
/// value, the runs tile the window from where the cursor stands with no
/// gap and no overlap, and the cursor stands one past the last row it
/// handed over. A run that claims a row the cursor has already passed
/// trips the `pos` check; one that claims a row past the window trips
/// the bound check.
fn expectRunWalk(
    model: []const ?i64,
    it: *Column(?i64, RleOption(i64)).Iterator,
    end: usize,
) !void {
    const bound = it.maxPos();
    var at = it.pos();
    while (try it.nextRun()) |run| {
        try testing.expect(run.count > 0);
        try testing.expect(at + run.count <= bound);
        for (0..run.count) |k| try testing.expectEqual(model[at + k], run.value);
        at += run.count;
        try testing.expectEqual(at, it.pos());
    }
    try testing.expectEqual(end, at);
    try testing.expectEqual(end, it.maxPos());
}

//  A run walk that stops at the first slab boundary reports the first
//  slab's runs and then null however long the column is. The acquisition
//  step has to cross the boundary the way `next` does
//  (`column.rs:569-581`).
test "a run walk crosses every slab of a many-slab column" {
    const gpa = testing.allocator;
    var built = try cursorColumn(4000);
    defer gpa.free(built.model);
    defer built.col.deinit();
    var it = try built.col.iterator();
    try expectRunWalk(built.model, &it, built.model.len);

    // The same walk with a budget of three rows a step: a run is clipped
    // to the budget and the next call picks the walk up on the row behind
    // it, across the boundary as well as inside a slab.
    var budgeted = try built.col.iterator();
    var at: usize = 0;
    while (at < built.model.len) {
        const run = (try budgeted.nextRunMax(3)).?;
        try testing.expect(run.count > 0 and run.count <= 3);
        for (0..run.count) |k| try testing.expectEqual(built.model[at + k], run.value);
        at += run.count;
        try testing.expectEqual(at, budgeted.pos());
    }
    try testing.expectEqual(built.model.len, at);
    try testing.expect((try budgeted.nextRunMax(3)) == null);
}

//  A cursor standing inside a run reports the rows behind it, not the
//  whole run: the run's own length is the length of the run the cursor is
//  in, and a run that claims the rows in front of it overruns the window
//  and corrupts every prefix sum built on it. The count is the run's end
//  less the cursor, as the decoder counts it (`decoder.rs:508-517`:
//  `self.remaining.min(max)`, where `remaining` is what is left of the
//  run behind the cursor).
test "a run cursor inside a run reports the rows behind it" {
    const gpa = testing.allocator;
    var built = try cursorColumn(4000);
    defer gpa.free(built.model);
    defer built.col.deinit();
    const window = RowRange{ .start = 1001, .end = 1400 };
    // The window starts on the second row of a five-row run, so the run
    // it stands in has four rows left of it.
    const left_of_run = 5 - (window.start % 5);
    var it = try built.col.iterRange(window);
    const head = (try it.nextRun()).?;
    try testing.expectEqual(left_of_run, head.count);
    try testing.expectEqual(built.model[window.start], head.value);
    try testing.expectEqual(window.start + left_of_run, it.pos());
    try expectRunWalk(built.model, &it, window.end);

    // `advanceTo` and `seekTo` land mid-run the same way, and the runs
    // they hand over are the rest of the run they land in.
    for ([_]struct { range: RowRange, to: usize }{
        .{ .range = .{ .start = 0, .end = 3000 }, .to = 2033 },
        .{ .range = .{ .start = 0, .end = 3000 }, .to = 2007 },
    }) |case| {
        var advanced = try built.col.iterRange(case.range);
        try advanced.advanceTo(case.to);
        try testing.expectEqual(case.to, advanced.pos());
        const run = (try advanced.nextRun()).?;
        try testing.expectEqual(5 - (case.to % 5), run.count);
        try testing.expectEqual(built.model[case.to], run.value);
        try expectRunWalk(built.model, &advanced, case.range.end);
    }
}

//  A window that starts near the end of its slab: the cursor belongs on
//  the window's start, and the decoder on the same row. Positioning it
//  advanced both by the offset into the slab, which put the cursor past
//  the window and, when the offset was longer than the window, underflowed
//  the count of rows left.
test "a window that starts inside a slab positions on the window's start" {
    const gpa = testing.allocator;
    var built = try cursorColumn(4000);
    defer gpa.free(built.model);
    defer built.col.deinit();
    // Twelve rows, starting deep inside slab zero: the offset into the
    // slab is longer than the window.
    const window = RowRange{ .start = 260, .end = 272 };
    var it = try built.col.iterRange(window);
    try testing.expectEqual(window.start, it.pos());
    try testing.expectEqual(window.end, it.maxPos());
    try testing.expectEqual(window.end - window.start, it.itemsLeft());
    try expectRows(built.model, &it, window.end);
    // The decoder stands where the cursor does, so extending the window
    // again picks the walk up on the row behind the one it stopped on.
    it.setMax(built.model.len);
    try expectRows(built.model, &it, built.model.len);
    // A run cursor over the same window reports the same rows.
    var runs = try built.col.iterRange(window);
    try expectRunWalk(built.model, &runs, window.end);
}

//  A run cursor and a row cursor are one cursor. The run walk advances
//  the decoder as well as the position, so the row behind a run is the
//  row it stopped on and `nth` reads from where the walk left it. A run
//  walk that moved only the position left the decoder behind, and the two
//  halves of the cursor disagreed about which row they stood on.
test "a run walk and a row walk are the same cursor" {
    const gpa = testing.allocator;
    var built = try cursorColumn(4000);
    defer gpa.free(built.model);
    defer built.col.deinit();
    var it = try built.col.iterator();
    var at: usize = 0;
    while (at < built.model.len) {
        const run = (try it.nextRun()) orelse {
            std.debug.print("no run at {d}\n", .{at});
            return error.TestUnexpectedResult;
        };
        for (0..run.count) |k| try testing.expectEqual(built.model[at + k], run.value);
        at += run.count;
        if (at == built.model.len) break;
        // The row behind the run, read by the row cursor, is the next row
        // of the model and not the first row of the run.
        const v = (try it.next()) orelse {
            std.debug.print("no row at {d}\n", .{at});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(built.model[at], v);
        at += 1;
        try testing.expectEqual(at, it.pos());
    }
    try testing.expectEqual(built.model.len, at);

    // A run walk followed by an indexed `nth`, and by `advanceTo`, both
    // read from where the walk left the cursor.
    var it2 = try built.col.iterator();
    _ = (try it2.nextRunMax(2)).?;
    // `nth` is `n` rows ahead of where the run walk stopped, and the
    // cursor lands on the row it read.
    try testing.expectEqual(@as(usize, 2), it2.pos());
    try testing.expectEqual(built.model[5], (try it2.nth(3)).?);
    try testing.expectEqual(@as(usize, 6), it2.pos());
    try it2.advanceTo(2000);
    try testing.expectEqual(built.model[2000], (try it2.next()).?);

    // The run adapter is the same cursor, and its `seekTo` reads the run
    // standing at the row it moves to.
    var runs = (try built.col.iterRange(.{ .start = 0, .end = 3000 })).runs();
    const run = (try runs.seekTo(1001)).?;
    try testing.expectEqual(4, run.count);
    try testing.expectEqual(built.model[1001], run.value);
}

//  A window with no rows is still a position: a window is routinely
//  re-extended, and an unpositioned cursor would have nothing to extend
//  from. An inverted range is the empty range at its start, and a range
//  past the data is the empty range at the end of it
//  (`column.rs:1385-1394`).
test "an empty, an inverted and a past-the-end range are all a position" {
    const gpa = testing.allocator;
    var built = try cursorColumn(4000);
    defer gpa.free(built.model);
    defer built.col.deinit();
    const model = built.model;

    var empty = try built.col.iterRange(.{ .start = 1000, .end = 1000 });
    try testing.expectEqual(@as(usize, 1000), empty.pos());
    try testing.expectEqual(@as(usize, 1000), empty.maxPos());
    try testing.expectEqual(@as(usize, 0), empty.itemsLeft());
    try testing.expect((try empty.next()) == null);
    try testing.expect((try empty.nextRun()) == null);
    // and it is positioned: extending it yields the rows behind it.
    empty.setMax(model.len);
    try expectRows(model, &empty, model.len);

    // **A window re-extended by `shift` rather than `setMax`**, which is what
    // automerge's batch apply does: a scope narrows a cursor to `p..p` and the
    // next object's switch shifts the same cursor forward
    // (`tests.rs:3299-3311`). `shift` is `setMax` to the end **then**
    // `advanceTo` the start (`column.rs:542-545`, `shift.rs:50-55`), so an
    // empty-born cursor that is shifted rather than extended has to move its
    // position and not only its window.
    {
        var shifted = try built.col.iterRange(.{ .start = 1000, .end = 1000 });
        try testing.expectEqual(@as(usize, 1000), shifted.pos());
        try testing.expectEqual(@as(usize, 0), shifted.itemsLeft());
        try shifted.shift(.{ .start = 1000, .end = 1000 });
        try testing.expectEqual(@as(usize, 1000), shifted.pos());
        // Extending after the shift yields from where it stands.
        shifted.setMax(1008);
        try testing.expectEqual(model[1000], (try shifted.next()).?);
        try testing.expectEqual(model[1001], (try shifted.next()).?);
        try testing.expectEqual(@as(usize, 1002), shifted.pos());
    }

    // **A far `nth` from an empty-born cursor on a many-slab column.** The
    // skip leaves the slab the cursor is in, so it answers through the index
    // (`findByPrefix`, `column.rs:365-372`) and re-anchors there — and a
    // cursor born at the end of the data stays a clean end cursor however far
    // past it the window is opened (`tests.rs:3314-3326`).
    {
        var jumped = try built.col.iterRange(.{ .start = 1000, .end = 1000 });
        jumped.setMax(model.len);
        try testing.expectEqual(model[1500], (try jumped.nth(500)).?);
        try testing.expectEqual(@as(usize, 1501), jumped.pos());
        // and it reads on from there, one row at a time.
        try expectRows(model, &jumped, model.len);
    }
    {
        var end_it = try built.col.iterRange(.{ .start = model.len, .end = model.len });
        end_it.setMax(model.len + 1000);
        try testing.expect((try end_it.next()) == null);
        try testing.expect((try end_it.nth(0)) == null);
        try testing.expect((try end_it.nextRun()) == null);
        try testing.expectEqual(model.len, end_it.pos());
    }

    for ([_]RowRange{
        .{ .start = 1400, .end = 1000 },
        .{ .start = 0, .end = 0 },
    }) |range| {
        const window = clampRange(range, model.len);
        var it = try built.col.iterRange(range);
        try testing.expectEqual(window.start, it.pos());
        try testing.expectEqual(window.end, it.maxPos());
        try testing.expect((try it.next()) == null);
        try testing.expect((try it.nextRun()) == null);
    }

    // A range past the end of the data is clamped to it, not refused.
    var past = try built.col.iterRange(.{ .start = 5000, .end = 6000 });
    try testing.expectEqual(model.len, past.pos());
    try testing.expect((try past.next()) == null);
    try testing.expect((try past.nextRun()) == null);
    try testing.expectEqual(@as(usize, 0), past.itemsLeft());

    // A column with no rows at all: every cursor over it is empty, and
    // the run adapter answers an empty walk too.
    var none = try Column(?i64, RleOption(i64)).init(gpa);
    defer none.deinit();
    for ([_]RowRange{
        .{ .start = 0, .end = 0 },
        .{ .start = 3, .end = 9 },
        .{ .start = 9, .end = 3 },
    }) |range| {
        var it = try none.iterRange(range);
        try testing.expect(clampRange(range, 0).start == it.pos());
        try testing.expect((try it.next()) == null);
        try testing.expect((try it.nth(0)) == null);
        try testing.expect((try it.nextRun()) == null);
        var runs = it.runs();
        try testing.expect((try runs.next()) == null);
    }
    var all = try none.iterator();
    try testing.expectEqual(@as(usize, 0), all.itemsLeft());
    try testing.expect((try all.next()) == null);
    try testing.expect((try all.nextRun()) == null);
}

//  Every way a window is moved is the same cursor: the three questions it
//  answers and the four defaults built on them (`shift.rs:19-74`), on a
//  column of several slabs where each of them has to cross a boundary to
//  answer.
test "a row cursor positions through every way a window is moved" {
    const gpa = testing.allocator;
    var built = try cursorColumn(4000);
    defer gpa.free(built.model);
    defer built.col.deinit();
    const model = built.model;

    // `iterator` starts on row zero with the whole column in the window.
    var it = try built.col.iterator();
    try testing.expectEqual(@as(usize, 0), it.pos());
    try testing.expectEqual(model.len, it.maxPos());
    try testing.expectEqual(model.len, it.itemsLeft());

    // `nth` answers the row it is asked for and leaves the cursor on it.
    try testing.expectEqual(model[10], (try it.nth(10)).?);
    try testing.expectEqual(@as(usize, 11), it.pos());
    try testing.expectEqual(model.len, it.maxPos());

    // `advanceTo` leaves the cursor on the row before its target, so the
    // next row is the target; a target behind the cursor is a no-op.
    try it.advanceTo(1000);
    try testing.expectEqual(@as(usize, 1000), it.pos());
    try testing.expectEqual(model[1000], (try it.next()).?);
    try testing.expectEqual(@as(usize, 1001), it.pos());
    try it.advanceBy(500);
    try testing.expectEqual(@as(usize, 1501), it.pos());
    try it.advanceTo(10);
    try testing.expectEqual(@as(usize, 1501), it.pos());

    // `seekTo` consumes through its row and answers it; a row behind the
    // cursor is not served.
    try testing.expectEqual(model[2000], (try it.seekTo(2000)).?);
    try testing.expectEqual(@as(usize, 2001), it.pos());
    try testing.expect((try it.seekTo(10)) == null);
    try testing.expectEqual(@as(usize, 2001), it.pos());

    // `shiftNext` moves the window and answers its first row in one step,
    // and a range that starts behind the cursor is a refusal.
    try testing.expectEqual(model[2500], (try it.shiftNext(.{ .start = 2500, .end = 3000 })).?);
    try testing.expectEqual(@as(usize, 2501), it.pos());
    try testing.expectEqual(@as(usize, 3000), it.maxPos());
    try testing.expectError(error.InvalidValue, it.shiftNext(.{ .start = 10, .end = 20 }));
    try expectRows(model, &it, 3000);

    // `shift` is `setMax` to the end **then `advanceTo` the start**
    // (`column.rs:542-545`, `shift.rs:50-55`), so the window follows the
    // range *and* the cursor stands on the range's first row. It is not a
    // window-only truncation: upstream's own doc says the window "yields
    // the items in `range` and then returns `None`" (`column.rs:536-537`),
    // and a cursor left at row 3000 behind a window ending at 3600 yields
    // rows 3000 to 3599.
    try it.shift(.{ .start = 3500, .end = 3600 });
    try testing.expectEqual(@as(usize, 3500), it.pos());
    try testing.expectEqual(@as(usize, 3600), it.maxPos());
    try expectRows(model, &it, 3600);

    // `setMax` shortens the window and extends it again, and a position
    // past the end of the data stops the cursor at the end of it.
    it.setMax(3600);
    it.setMax(model.len);
    try testing.expectEqual(model.len, it.maxPos());
    try expectRows(model, &it, model.len);
    var past = try built.col.iterRange(.{ .start = 3990, .end = 9000 });
    try testing.expectEqual(model.len, past.maxPos());
    try expectRows(model, &past, model.len);
    try testing.expect((try past.nth(0)) == null);
    try testing.expectEqual(model.len, past.pos());
}

//  An iterator is a value, not a heap object (`docs/plan.md` §3): a column
//  built through a counting allocator allocates nothing more once every
//  cursor over it — the whole-column one, a range one, a run walk, a run
//  adapter — has been built and walked.
test "building and walking a cursor allocates nothing" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    const model = try gpa.alloc(?i64, 4000);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = blockRunValue(i);
    var col = try Column(?i64, RleOption(i64)).init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, model);
    const built_at = failing.allocations;

    var all = try col.iterator();
    var at: usize = 0;
    while (try all.next()) |v| {
        try testing.expectEqual(model[at], v);
        at += 1;
    }
    try testing.expectEqual(model.len, at);

    var window = try col.iterRange(.{ .start = 1001, .end = 1400 });
    var runs = window.runs();
    var covered: usize = 0;
    while (try runs.next()) |run| {
        try testing.expect(run.count > 0);
        covered += run.count;
    }
    try testing.expectEqual(@as(usize, 399), covered);
    try testing.expectEqual(@as(usize, 1400), window.maxPos());

    try testing.expectEqual(built_at, failing.allocations);
}

//  A prefix cursor is the row cursor with a running sum, and the sum is
//  what makes a mispositioned cursor visible: `nth` across a slab reads
//  the absolute prefix back from the column, so a cursor that landed on
//  the wrong row would report another row's sum. Every entry point is
//  held to the model's own running total, on a column of many slabs.
test "a prefix cursor over many slabs keeps its sums" {
    const gpa = testing.allocator;
    const rows: usize = 4000;
    var col = try Column(u32, Prefix(u32)).init(gpa);
    defer col.deinit();
    const model = try gpa.alloc(u32, rows);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = @intCast(i / 5);
    try col.extend(gpa, model);
    try testing.expect(col.slabCount() >= 3);
    // The model's own prefix sums, so every answer below has one.
    const sums = try gpa.alloc(i64, rows + 1);
    defer gpa.free(sums);
    sums[0] = 0;
    for (model, 0..) |v, i| sums[i + 1] = sums[i] + @as(i64, v);

    // A row walk: the sum behind each row is the model's own.
    var walk = try col.prefixIter();
    for (model, 0..) |v, i| {
        const pv = (try walk.next()).?;
        try testing.expectEqual(v, pv.value);
        try testing.expectEqual(sums[i + 1], pv.sum);
        try testing.expectEqual(sums[i + 1], pv.total());
    }
    try testing.expectEqual(rows, walk.pos());

    // `nth` and `seekTo` inside a slab and across a boundary: the same
    // row and the same sum as the walk, from a cursor that has moved.
    var seek = try col.prefixIter();
    for ([_]usize{ 0, 1, 319, 320, 321, 1500, 3999 }) |row| {
        const pv = (try seek.nth(row - seek.pos())).?;
        try testing.expectEqual(model[row], pv.value);
        try testing.expectEqual(sums[row + 1], pv.sum);
    }
    var jumped = try col.prefixIter();
    const at2000 = (try jumped.seekTo(2000)).?;
    try testing.expectEqual(model[2000], at2000.value);
    try testing.expectEqual(sums[2001], at2000.sum);
    try jumped.advanceBy(3);
    try testing.expectEqual(@as(usize, 2004), jumped.pos());
    const shifted = (try jumped.shiftNext(.{ .start = 3000, .end = 3100 })).?;
    try testing.expectEqual(model[3000], shifted.value);
    try testing.expectEqual(sums[3001], shifted.sum);
    try testing.expectEqual(@as(usize, 3100), jumped.maxPos());

    // A run reports the sum through its *final* row, so a run of five
    // widths is one step, not five.
    var runs = try col.prefixIter();
    var at: usize = 0;
    while (try runs.nextRun()) |run| {
        try testing.expectEqual(@as(usize, 5), run.count);
        try testing.expectEqual(model[at], run.value.value);
        try testing.expectEqual(sums[at + run.count], run.value.total());
        at += run.count;
    }
    try testing.expectEqual(rows, at);
}

//  A value's rows are a contiguous range, and finding one is a run walk
//  (`scope_to_value`, `column.rs:1495-1506`). Over many slabs the walk
//  has to cross every boundary, and a cursor that stops at the first
//  would answer a range that stops where the first slab stops.
test "a value's rows are found across every slab" {
    const gpa = testing.allocator;
    const rows: usize = 4000;
    var col = try Column(u32, Rle(u32)).init(gpa);
    defer col.deinit();
    const model = try gpa.alloc(u32, rows);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = @intCast(i / 5);
    try col.extend(gpa, model);
    try testing.expect(col.slabCount() >= 3);

    // Every value is five rows, so each one is a run of its own and the
    // whole column is the range it stands for.
    const whole = RowRange{ .start = 0, .end = rows };
    try testing.expectEqual(RowRange{ .start = 2000, .end = 2005 }, try col.scopeToValue(400, whole));
    // and it is found from a window that starts in the middle of the run
    try testing.expectEqual(
        RowRange{ .start = 2002, .end = 2005 },
        try col.scopeToValue(400, .{ .start = 2002, .end = 2005 }),
    );
    // a value outside the window answers an empty range at the point it
    // would have been inserted (`column.rs:913-934`).
    try testing.expectEqual(
        RowRange{ .start = 2000, .end = 2000 },
        try col.scopeToValue(400, .{ .start = 0, .end = 2000 }),
    );

    // `seekToValue` leaves the cursor on the run it found, whichever
    // slabs the search crossed to get there.
    var it = try col.iterRange(whole);
    try testing.expectEqual(RowRange{ .start = 1000, .end = 1005 }, try it.seekToValue(200, whole));
    try testing.expectEqual(model[1000], (try it.next()).?);
}

/// The row function the remap below is called with: every value up by
/// one, which is what an inserted actor index does to the columns that
/// hold one (`op_set2/columns.rs:332-348`).
fn shiftValueByOne(_: void, v: u32) u32 {
    return v + 1;
}

//  `remap` rebuilds the column out of a run walk
//  (`Column::remap`, `column.rs:1263-1273`), so a run walk that stopped
//  at the first slab boundary left the column holding slab zero's rows
//  and dropped every row behind it. This is the one place the cursor
//  reaches the bytes: the op set's actor renumbering is this call, so a
//  truncated remap is a document that lost its rows.
test "a remap of a many-slab column keeps every row" {
    const gpa = testing.allocator;
    const rows: usize = 4000;
    var col = try Column(u32, Rle(u32)).init(gpa);
    defer col.deinit();
    const model = try gpa.alloc(u32, rows);
    defer gpa.free(model);
    const mapped = try gpa.alloc(u32, rows);
    defer gpa.free(mapped);
    for (model, 0..) |*v, i| v.* = @intCast(i / 5);
    for (model, 0..) |v, i| mapped[i] = v + 1;
    try col.extend(gpa, model);
    try testing.expect(col.slabCount() >= 3);

    try col.remap(gpa, {}, shiftValueByOne);
    try expectSound(u32, Rle(u32), &col);
    try testing.expectEqual(rows, col.len());
    try expectModel(u32, Rle(u32), &col, mapped);
    try expectRoundTrip(u32, Rle(u32), &col, mapped);
}

//  A lookahead cursor holds the item it has drawn and the cursor that
//  drew it. A struct built from the cursor from *before* the draw kept
//  the two one item apart, so `next` handed the first item back twice
//  and every item behind it one row late — and for a cursor that owns
//  its stack, the two copies of it shared one. Upstream draws into a
//  local and then builds (`shift.rs:264-267`).
test "a lookahead cursor hands every item back once, in order" {
    const gpa = testing.allocator;
    const Cursor = Column(i64, Rle(i64)).Iterator;
    const model = [_]i64{ 5, 5, 5, 7, 7, 1, 1, 1, 1, 9 };
    var col = try Column(i64, Rle(i64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &model);

    // The first item is already in hand before the first `next`.
    var whole = try Unshift(Cursor).init(try col.iterator());
    try testing.expectEqual(model[0], whole.peek().?);
    for (model) |v| try testing.expectEqual(v, (try whole.next()).?);
    try testing.expect((try whole.next()) == null);
    try testing.expect(whole.peek() == null);

    // `shift` refills the lookahead from the range's start and the
    // window it leaves is the range, not one row more.
    var windowed = try Unshift(Cursor).init(try col.iterRange(.{ .start = 3, .end = model.len }));
    try windowed.shift(.{ .start = 6, .end = 9 });
    try testing.expectEqual(model[6], windowed.peek().?);
    for (model[6..9]) |v| try testing.expectEqual(v, (try windowed.next()).?);
    try testing.expect((try windowed.next()) == null);
}

//  The row a prefix descent lands on and the prefix consumed in front of it:
//  the two halves of a seek's answer (`PrefixSeek`, `prefix.rs:361-376`).
const Landing = struct { pos: usize, delta: i64 };

/// `advancePrefix(n)` from a fresh cursor — over the whole column, or over
/// `range` of it. A [`PrefixIter`] is a value, so building the cursor is not
/// what a seek costs; the descent is.
fn landingAt(
    comptime T: type,
    comptime E: type,
    col: *const Column(T, E),
    range: ?RowRange,
    n: i64,
) ParseError!?Landing {
    var it = if (range) |r| try col.prefixIterRange(r) else try col.prefixIter();
    const seek = (try it.advancePrefix(n)) orelse return null;
    return .{ .pos = seek.pos, .delta = seek.delta };
}

/// The landing of `advancePrefix(n)`, as a row and the prefix consumed in
/// front of it. The two halves are asserted together because they are one
/// answer: a descent that names the right row with the wrong delta is the
/// failure this file had.
fn expectLanding(
    comptime T: type,
    comptime E: type,
    col: *const Column(T, E),
    range: ?RowRange,
    n: i64,
    pos: usize,
    delta: i64,
) !void {
    const got = (try landingAt(T, E, col, range, n)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(pos, got.pos);
    try testing.expectEqual(delta, got.delta);
}

//  A multi-unit element is ordinary, not a corner: a text row's value is a
//  whole string and its width is that string's width under the document's
//  encoding ([op.zig:1844-1849](opset/op.zig)), so a text reading `"ab"`
//  followed by `"c"` is a two-unit element followed by a one-unit one.
//  `index.text` over that document is `[1, 2, 1]` — the row that created the
//  object carries a width of its own, and the object's own rows are `1..3` —
//  and the op set descends that range, not the whole column.
//
//  `advancePrefix(n)` lands on the row holding unit `n` and reports the
//  prefix consumed in front of it (`prefix.rs:989-996`), so over these widths
//  unit 0 is row 0, units 1 and 2 are row 1, and unit 3 is row 2.
test "a prefix descent lands inside a two-unit element" {
    const gpa = testing.allocator;
    var col = try Column(?u32, Prefix(?u32)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &[_]?u32{ 1, 2, 1 });

    // Over the whole column, the prefix in front of a row is the sum of the
    // rows before it: 0, 1 and 3.
    try expectLanding(?u32, Prefix(?u32), &col, null, 0, 0, 0);
    // Unit 1 is **inside** the two-unit element, and the delta is the prefix
    // in front of that element, not the sum through it.
    try expectLanding(?u32, Prefix(?u32), &col, null, 1, 1, 1);
    // Unit 2 is that element's last unit, and it is the same row with the
    // same delta: the two are one landing.
    try expectLanding(?u32, Prefix(?u32), &col, null, 2, 1, 1);
    // Unit 3 is the element behind it, which is a run boundary.
    try expectLanding(?u32, Prefix(?u32), &col, null, 3, 2, 3);
    // Unit 4 is past the end of a four-unit column.
    try testing.expect((try landingAt(?u32, Prefix(?u32), &col, null, 4)) == null);

    // The object's own range, which is what the op set descends: the sums a
    // range cursor reports are in front of *its* start, so the same four
    // landings come back with row 1 first and a delta one unit lower.
    const range = RowRange{ .start = 1, .end = 3 };
    try expectLanding(?u32, Prefix(?u32), &col, range, 0, 1, 0);
    try expectLanding(?u32, Prefix(?u32), &col, range, 1, 1, 0);
    try expectLanding(?u32, Prefix(?u32), &col, range, 2, 2, 2);
    try testing.expect((try landingAt(?u32, Prefix(?u32), &col, range, 3)) == null);
}

//  Inside an element and on its last unit are different units and have to be
//  pinned separately, because a descent reads a run's *first* value and only a
//  landing inside the run tells the two apart from a run boundary. The widths
//  here are `2, 2, 2, 1, 2, 3, 4, 4, 0, 1, 5, 5, 5, 7, 7, 3`, so rows 3 to 5
//  are a literal run of one, two and three units and row 5 is three units wide.
test "a landing inside a wide element and a landing on its last unit are both answered" {
    const gpa = testing.allocator;
    var col = try Column(u32, Prefix(u32)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &[_]u32{ 2, 2, 2, 1, 2, 3, 4, 4, 0, 1, 5, 5, 5, 7, 7, 3 });

    // Row 4 is two units wide — units 7 and 8 — and it is the second item of
    // the literal run, so the landing has to come out of that run and not out
    // of the run behind it.
    try expectLanding(u32, Prefix(u32), &col, null, 7, 4, 7);
    try expectLanding(u32, Prefix(u32), &col, null, 8, 4, 7);
    // Row 5 is three units wide — units 9, 10 and 11 — and it is the literal
    // run's last item. Its first unit, one strictly inside it and its last are
    // three assertions, because a descent that answers one of them out of the
    // run behind has answered all three wrongly.
    try expectLanding(u32, Prefix(u32), &col, null, 9, 5, 9);
    try expectLanding(u32, Prefix(u32), &col, null, 10, 5, 9);
    try expectLanding(u32, Prefix(u32), &col, null, 11, 5, 9);
    // Unit 12 is row 6's, the first row of the repeat run behind the literal,
    // and 15 is that row's last unit.
    try expectLanding(u32, Prefix(u32), &col, null, 12, 6, 12);
    try expectLanding(u32, Prefix(u32), &col, null, 15, 6, 12);
    // Row 7 is four units wide, units 16 to 19, and unit 17 is inside it.
    try expectLanding(u32, Prefix(u32), &col, null, 16, 7, 16);
    try expectLanding(u32, Prefix(u32), &col, null, 17, 7, 16);
    // Row 8 is a zero-length row in the second literal run, so unit 20 is
    // row 9's, one row further on, and unit 21 is the repeat run behind it.
    try expectLanding(u32, Prefix(u32), &col, null, 20, 9, 20);
    try expectLanding(u32, Prefix(u32), &col, null, 21, 10, 21);
}

//  The prefix sum over several runs, against totals written out here rather
//  than computed by the code under test: the widths are
//  `2, 2, 2, 1, 2, 3, 4, 4, 0, 1, 5, 5, 5, 7, 7, 3` and their running total is
//  `0, 2, 4, 6, 7, 9, 12, 16, 20, 20, 21, 26, 31, 36, 43, 50, 53`. A descent
//  reads the same numbers, so a row walk, `getPrefix` and the two inverse
//  lookups are all held to this one list.
test "the prefix sum over several runs of differing widths is the running total" {
    const gpa = testing.allocator;
    const widths = [_]u32{ 2, 2, 2, 1, 2, 3, 4, 4, 0, 1, 5, 5, 5, 7, 7, 3 };
    const totals = [_]i64{ 0, 2, 4, 6, 7, 9, 12, 16, 20, 20, 21, 26, 31, 36, 43, 50, 53 };
    var col = try Column(u32, Prefix(u32)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &widths);

    var walk = try col.prefixIter();
    for (widths, 0..) |width, i| {
        try testing.expectEqual(totals[i], try col.getPrefix(i));
        const pv = (try walk.seekTo(i)).?;
        try testing.expectEqual(width, pv.value);
        try testing.expectEqual(totals[i], pv.prefix());
        try testing.expectEqual(totals[i + 1], pv.total());
    }
    try testing.expectEqual(totals[widths.len], try col.getPrefix(widths.len));
    // The inverse, on the same numbers: the row whose inclusive total first
    // reaches `t`, and the row whose exclusive one does. Total 9 is row 4's
    // inclusive total, so the inclusive lookup names row 4 and the exclusive
    // one for 9 names the row behind it, row 5. Total 51 is inside row 15's
    // three units, and 54 is past the grand total, which is one row past the
    // end — the two out-of-range answers upstream gives (`prefix.rs:603-604`).
    try testing.expectEqual(@as(usize, 0), try col.getIndexForTotal(1));
    try testing.expectEqual(@as(usize, 4), try col.getIndexForTotal(9));
    try testing.expectEqual(@as(usize, 9), try col.getIndexForTotal(21));
    try testing.expectEqual(@as(usize, 15), try col.getIndexForTotal(51));
    try testing.expectEqual(@as(usize, 5), try col.getIndexForPrefix(9));
    try testing.expectEqual(@as(usize, 10), try col.getIndexForPrefix(21));
    try testing.expectEqual(@as(usize, widths.len + 1), try col.getIndexForPrefix(54));
    try testing.expectEqual(@as(usize, 0), try col.getIndexForPrefix(0));
}

//  A descent crosses a slab boundary in the tree and then walks the runs of
//  the slab it lands in, so the two halves have to agree at the seam. The
//  widths here are five equal rows per block, block `b` being `b mod 4 + 1`
//  units wide, except for block 63 — the last block of the first slab —
//  whose five rows are `1, 2, 3, 1, 2` and so are one literal run. A slab
//  holds 64 runs (`slab.zig:111-114`), so the seam is after row 319 and its 780
//  units plus that literal's nine are 789.
test "a prefix descent crosses a slab boundary and lands in the slab holding the unit" {
    const gpa = testing.allocator;
    const rows: usize = 1000;
    const literal = [_]u32{ 1, 2, 3, 1, 2 };
    var col = try Column(u32, Prefix(u32)).init(gpa);
    defer col.deinit();
    for (0..rows) |i| {
        const block = i / 5;
        try col.append(gpa, if (block == 63) literal[i % 5] else @intCast(block % 4 + 1));
    }
    try testing.expectEqual(@as(usize, 4), col.slabCount());
    const first = col.tree.itemsBeforeSlab(1);
    try testing.expectEqual(@as(usize, 320), first);
    try testing.expectEqual(@as(i64, 789), try col.getPrefix(first));

    // The literal run at the end of the first slab, one unit at a time. Rows
    // 315 to 319 are one, two, three, one and two units wide, so unit 780 is
    // row 315's, 781 and 782 are row 316's, 783 to 785 are row 317's, 786 is
    // row 318's and 787 and 788 are row 319's.
    try expectLanding(u32, Prefix(u32), &col, null, 780, 315, 780);
    try expectLanding(u32, Prefix(u32), &col, null, 781, 316, 781);
    try expectLanding(u32, Prefix(u32), &col, null, 782, 316, 781);
    // Inside the three-unit row 317, and then on each of its ends.
    try expectLanding(u32, Prefix(u32), &col, null, 783, 317, 783);
    try expectLanding(u32, Prefix(u32), &col, null, 784, 317, 783);
    try expectLanding(u32, Prefix(u32), &col, null, 785, 317, 783);
    try expectLanding(u32, Prefix(u32), &col, null, 786, 318, 786);
    // Unit 788 is the last unit of the first slab and unit 789 is the first
    // unit of the next, so this pair is the seam itself.
    try expectLanding(u32, Prefix(u32), &col, null, 787, 319, 787);
    try expectLanding(u32, Prefix(u32), &col, null, 788, 319, 787);
    try expectLanding(u32, Prefix(u32), &col, null, 789, 320, 789);
    // Past the seam, rows 320 to 324 are one unit each and rows 325 to 329
    // are two, so unit 794 is row 325's and 795 is inside it.
    try expectLanding(u32, Prefix(u32), &col, null, 794, 325, 794);
    try expectLanding(u32, Prefix(u32), &col, null, 795, 325, 794);

    // A range cursor over the second slab alone agrees, with its sums in
    // front of its own start: that range's units are 789 onwards, so its
    // unit 5 is row 325's and its unit 6 is inside it.
    const seam = RowRange{ .start = first, .end = first + 10 };
    try expectLanding(u32, Prefix(u32), &col, seam, 0, 320, 0);
    try expectLanding(u32, Prefix(u32), &col, seam, 1, 321, 1);
    try expectLanding(u32, Prefix(u32), &col, seam, 5, 325, 5);
    try expectLanding(u32, Prefix(u32), &col, seam, 6, 325, 5);
}

//  Every element one unit wide: the descent is the identity, `advancePrefix(n)`
//  is row `n` with delta `n`, and a column of them is a single repeat run —
//  the case the ceiling division was written for (`prefix.rs:138-143`).
test "a single-unit prefix column's descent is the identity" {
    const gpa = testing.allocator;
    const rows: usize = 5;
    var col = try Column(u32, Prefix(u32)).init(gpa);
    defer col.deinit();
    for (0..rows) |_| try col.append(gpa, 1);
    for (0..rows) |n| {
        try expectLanding(u32, Prefix(u32), &col, null, @intCast(n), n, @intCast(n));
    }
    try testing.expect((try landingAt(u32, Prefix(u32), &col, null, @intCast(rows))) == null);
    // A range cursor over the same rows shifts both numbers by its start.
    const range = RowRange{ .start = 2, .end = rows };
    try expectLanding(u32, Prefix(u32), &col, range, 0, 2, 0);
    try expectLanding(u32, Prefix(u32), &col, range, 1, 3, 1);
    try expectLanding(u32, Prefix(u32), &col, range, 2, 4, 2);
    try testing.expect((try landingAt(u32, Prefix(u32), &col, range, 3)) == null);
}

//  A zero-length row is a row, and the format carries one: a repeat run of
//  zeros and a zero inside a literal group are both encodable, and a mark
//  row's width is zero ([op.zig:1847](opset/op.zig)). It contributes nothing to
//  the sum, so a descent steps over it — there is nothing to divide by
//  (`prefix.rs:113-115`) and it can never be the row a target is in.
test "a zero-length row is stepped over, in a repeat run and in a literal" {
    const gpa = testing.allocator;
    {
        // `0, 0, 0` is a repeat run of the value zero and `2` follows it.
        var col = try Column(u32, Prefix(u32)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &[_]u32{ 0, 0, 0, 2, 2, 0, 3 });
        // Units 0 and 1 are row 3's — the first row with any width at all —
        // and 2 and 3 are row 4's, the second row of the repeat run.
        try expectLanding(u32, Prefix(u32), &col, null, 0, 3, 0);
        try expectLanding(u32, Prefix(u32), &col, null, 1, 3, 0);
        try expectLanding(u32, Prefix(u32), &col, null, 2, 4, 2);
        try expectLanding(u32, Prefix(u32), &col, null, 3, 4, 2);
        // Row 5 is the zero-length row, so units 4, 5 and 6 are all row 6's,
        // and unit 7 is past the seven-unit total.
        try expectLanding(u32, Prefix(u32), &col, null, 4, 6, 4);
        try expectLanding(u32, Prefix(u32), &col, null, 5, 6, 4);
        try expectLanding(u32, Prefix(u32), &col, null, 6, 6, 4);
        try testing.expect((try landingAt(u32, Prefix(u32), &col, null, 7)) == null);
    }
    {
        // The same row inside a literal group, where its neighbours are what
        // make it one: `0, 2, 0, 3`.
        var col = try Column(?u32, Prefix(?u32)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &[_]?u32{ 0, 2, 0, 3, null, 1 });
        // Row 0 is a zero-length row and row 1 is two units wide, so units 0
        // and 1 are both row 1's.
        try expectLanding(?u32, Prefix(?u32), &col, null, 0, 1, 0);
        try expectLanding(?u32, Prefix(?u32), &col, null, 1, 1, 0);
        // Row 2 is a zero-length row again, so units 2, 3 and 4 are row 3's.
        try expectLanding(?u32, Prefix(?u32), &col, null, 2, 3, 2);
        try expectLanding(?u32, Prefix(?u32), &col, null, 3, 3, 2);
        try expectLanding(?u32, Prefix(?u32), &col, null, 4, 3, 2);
        // Row 4 is null and row 5 is one unit wide, so unit 5 is row 5's and
        // unit 6 is past the six-unit total.
        try expectLanding(?u32, Prefix(?u32), &col, null, 5, 5, 5);
        try testing.expect((try landingAt(?u32, Prefix(?u32), &col, null, 6)) == null);
    }
}

//  The bytes are the format: this is the run sequence a prefix column of
//  three distinct widths is written as — a signed LEB128 literal header `-3`
//  and the three values — and the descent above reads exactly these bytes.
//  Pinned so that a fix to the descent cannot be made by changing what a run
//  is written as.
test "a prefix column's bytes are the canonical run sequence, literal run and all" {
    const gpa = testing.allocator;
    {
        // `1, 2, 1`: `7d` is `-3`, a literal run of three items.
        var col = try Column(?u32, Prefix(?u32)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &[_]?u32{ 1, 2, 1 });
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        try testing.expectEqualSlices(u8, &[_]u8{ 0x7d, 0x01, 0x02, 0x01 }, bytes);
    }
    {
        // `2, 2, 2` then `1, 2, 3` then `4, 4` then `0, 1` then `5, 5, 5` then
        // `7, 7` then `3`: two repeat runs, two literal runs and three
        // single-item literals, in one slab. `7d` is `-3` and `7e` is `-2`, so
        // the two literal headers are the multi-item ones.
        var col = try Column(u32, Prefix(u32)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &[_]u32{ 2, 2, 2, 1, 2, 3, 4, 4, 0, 1, 5, 5, 5, 7, 7, 3 });
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        try testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x02, 0x7d, 0x01, 0x02, 0x03, 0x02, 0x04, 0x7e, 0x00, 0x01, 0x03, 0x05, 0x02, 0x07, 0x7f, 0x03 }, bytes);
        const segs = try col.slabSegments(gpa);
        defer gpa.free(segs);
        try testing.expectEqualSlices(usize, &[_]usize{7}, segs);
    }
    {
        // One unit per element is one repeat run, and no literal at all.
        var col = try Column(u32, Prefix(u32)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &[_]u32{ 1, 1, 1, 1, 1 });
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        try testing.expectEqualSlices(u8, &[_]u8{ 0x05, 0x01 }, bytes);
    }
}

//  A prefix cursor is a value like any other: a column built through a
//  counting allocator hands out no more memory once a cursor over it — the
//  whole-column one, a range one — has been built and descended. The
//  instrument is the one the plain cursor uses above, and for the same
//  reason: a constructor that allocated and one that did not both return a
//  perfectly usable cursor.
test "a prefix cursor is a value, and its descent allocates nothing" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    const widths = [_]u32{ 2, 2, 2, 1, 3, 3, 4, 0, 0, 5, 5, 5, 7 };
    var col = try Column(u32, Prefix(u32)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &widths);
    const built_at = failing.allocations;

    var whole = try col.prefixIter();
    const seek = (try whole.advancePrefix(8)).?;
    try testing.expectEqual(@as(usize, 4), seek.pos);
    try testing.expectEqual(@as(i64, 7), seek.delta);
    try testing.expectEqual(@as(i64, 10), seek.pv.total());
    // The cursor moved: the next row behind it is the one the seek consumed.
    const behind = (try whole.next()).?;
    try testing.expectEqual(@as(u32, 3), behind.value);

    var window = try col.prefixIterRange(.{ .start = 6, .end = widths.len });
    const in_window = (try window.advancePrefix(4)).?;
    try testing.expectEqual(@as(usize, 9), in_window.pos);
    try testing.expectEqual(@as(i64, 4), in_window.delta);

    try testing.expectEqual(built_at, failing.allocations);
}

// ── Upstream `hexane/src/tests.rs`, ported case for case ────────────────────
//
// Every test below is named after the upstream `#[test]` it transcribes, so
// the two suites can be diffed by name. The upstream file is
// `rust/hexane/src/tests.rs` (286 tests); the mapping rules for the port:
//
// * `Column<T>` is `Column(T, E)` with `E` naming upstream's
//   `T::Encoding<C>` (`encoding.rs:15-140`): `Rle`/`RleOption`/`Prefix`/
//   `Delta`/`Bool` here, all Leb128. Upstream's `save` is `encode`,
//   `load_with` is `loadWith`, `insert`/`remove` are one `splice`, `iter` is
//   `iterator`, `iter_range` is `iterRange`, `to_vec` is `toSlice`.
// * Upstream's `proptest!` cases are ported as **seeded deterministic sweeps**
//   over the same generator domain. A property test draws at random; a
//   regression test over a fixed seed list is reproducible, which is what
//   `docs/plan.md` §4 asks for (`proptest-regressions/tests.txt`).
// * Upstream's `from_values_with_max_segments(n)`, `with_max_segments(n)` and
//   `LoadOpts::with_max_segments(n)` are the port's `fromValues`,
//   `initWithBudget` and `LoadOpts.withMaxSegments`, so a case that tunes the
//   budget can. Most cases below still build the **shape** that produces
//   several slabs under the default budget instead — enough *runs*, which is
//   what the budget counts (`slab.zig:111-114`) — and say which.
// * `assert_col` also asserts `validate_encoding` upstream
//   (`tests.rs:88-100`); here that is [`expectRoundTrip`], whose load accepts
//   only canonical bytes (`column.zig`, `Column.load` → `canonicalSlab`).
//
// **Not ported, and why** — every case is accounted for in the report; the
// three reasons are a type the port does not have, an API the port does not
// have, or a Rust type property rather than behaviour.

/// Builds a column of `values` by appending them one at a time — upstream's
/// `v1_build` (`tests.rs:11-17`).
fn v1Build(gpa: std.mem.Allocator, values: []const u64) !Column(u64, Rle(u64)) {
    var col = try Column(u64, Rle(u64)).init(gpa);
    errdefer col.deinit();
    for (values) |v| try col.append(gpa, v);
    return col;
}

/// `v1_build` over a nullable payload.
fn v1BuildOpt(gpa: std.mem.Allocator, values: []const ?u64) !Column(?u64, RleOption(u64)) {
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    errdefer col.deinit();
    for (values) |v| try col.append(gpa, v);
    return col;
}

/// `v1_build` over a boolean payload.
fn v1BuildBool(gpa: std.mem.Allocator, values: []const bool) !Column(bool, Bool) {
    var col = try Column(bool, Bool).init(gpa);
    errdefer col.deinit();
    for (values) |v| try col.append(gpa, v);
    return col;
}

/// Upstream's truncation rule, walked over every strict prefix of `bytes`: a
/// prefix either refuses or loads as a **strictly shorter** column, and the
/// prefixes that end a run whole are the boundary the two answers meet on
/// (`tests.rs:1894-1897`, `rle/decoder.rs:227-234`).
///
/// The run boundaries come from the codec's own segment walk rather than from
/// a written-down byte count, so this is a statement about the wire form and
/// not about offsets an encoder change could move out from under it.
fn expectTruncationRule(
    comptime C: type,
    comptime E: type,
    gpa: std.mem.Allocator,
    col: *const C,
    bytes: []const u8,
) !void {
    const segs = try E.segmentsOf(gpa, bytes);
    defer gpa.free(segs);
    var cut: usize = 0;
    while (cut < bytes.len) : (cut += 1) {
        // The empty prefix is the one prefix that is a boundary without
        // ending a run, and it is a valid empty column.
        var on_boundary = cut == 0;
        for (segs) |s| {
            if (s.byte_end == cut) on_boundary = true;
        }
        if (C.load(gpa, bytes[0..cut])) |loaded| {
            var got = loaded;
            defer got.deinit();
            if (!on_boundary) {
                std.debug.print(
                    "prefix {d} of {d} bytes cuts a run in half and loaded {d} rows\n",
                    .{ cut, bytes.len, got.len() },
                );
                return error.TestUnexpectedResult;
            }
            // Upstream's assertion (`tests.rs:1896`), and the half of it
            // that keeps a truncation from being mistaken for the whole
            // column: a strict prefix is never all of it. Never empty
            // either — an empty column is what a *refusal* must not read
            // as, and a truncation is not the same thing as an absent
            // column.
            try testing.expect(got.len() < col.len());
            if (cut > 0) try testing.expect(got.len() > 0);
        } else |_| {
            if (on_boundary) {
                std.debug.print(
                    "prefix {d} of {d} bytes ends a run and was refused\n",
                    .{ cut, bytes.len },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
    // The one prefix that is not a truncation is the whole column, and the
    // reverse direction this rule could get wrong the other way: a load
    // that refuses it, or truncates it, is a load that cannot read what
    // this port wrote.
    var whole = try C.load(gpa, bytes);
    defer whole.deinit();
    try testing.expectEqual(col.len(), whole.len());
}

/// Upstream's `insert` (`column.rs:1148-1153`), which is a splice of one value
/// at an index.
fn insertAt(comptime Col: type, gpa: std.mem.Allocator, col: *Col, index: usize, v: Col.Value) !void {
    try col.splice(gpa, index, 0, &.{v});
}

/// Upstream's `remove` (`column.rs:1136-1147`): one row out at an index.
fn removeAt(comptime Col: type, gpa: std.mem.Allocator, col: *Col, index: usize) !void {
    try col.removeN(gpa, index, 1);
}

/// Upstream's `assert_col` (`tests.rs:88-100`): the values by index and in
/// order, the length, and a canonical encoding.
fn assertCol(comptime T: type, comptime E: type, col: *const Column(T, E), expected: []const T) !void {
    try expectModel(T, E, col, expected);
    try expectRoundTrip(T, E, col, expected);
}

/// Upstream's `build_and_check` (`tests.rs:100-110`): apply
/// `(value, index)` steps to a nullable column and a mirror, and hold the
/// column to the mirror at the end.
fn buildAndCheck(steps: []const struct { v: ?u64, at: usize }) !void {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);
    for (steps) |one| {
        try col.splice(gpa, one.at, 0, &.{one.v});
        try mirror.insert(gpa, one.at, one.v);
    }
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
}

/// The xorshift `tests.rs` uses to build its random columns
/// (`tests.rs:5169-5174`).
fn xorshift(seed: *u64) u64 {
    var x = seed.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    seed.* = x;
    return x;
}

/// A u64 column of `runs` runs of `per` copies each — the run structure
/// upstream builds with `from_values_with_max_segments`, which the port has
/// to reach the same way, because its budget counts **runs** (`slab.zig:111-114`).
fn manySlabColumn(gpa: std.mem.Allocator, runs: usize, per: usize) !Column(u64, Rle(u64)) {
    var col = try Column(u64, Rle(u64)).init(gpa);
    errdefer col.deinit();
    for (0..runs) |r| {
        const v: u64 = @intCast(r);
        for (0..per) |_| try col.append(gpa, v);
    }
    return col;
}

// ── `load_*` ────────────────────────────────────────────────────────────────

//  Alternating booleans past the run budget: the slab cut inside a boolean
//  column must not lose or reorder a run (`tests.rs:1663`).
test "load_bool_alternating_slab_boundary" {
    const gpa = testing.allocator;
    const values = [_]bool{
        false, true, false, true, false, true, false, true,  false, true,
        false, true, false, true, false, true, false, false,
    };
    var original = try v1BuildBool(gpa, &values);
    defer original.deinit();
    const bytes = try original.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(bool, Bool).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(values.len, loaded.len());
    for (values, 0..) |want, i| {
        try testing.expectEqual(want, try loaded.get(i));
        try testing.expectEqual(want, try original.get(i));
    }
}

//  Empty bytes are an empty column, not a refusal (`tests.rs:1685`).
test "load_empty" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).load(gpa, &.{});
    defer col.deinit();
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expect(col.isEmpty());
}

//  The whole `load_roundtrip_*` family is one shape: save, load, and read
//  every row back. Seven cases, seven value shapes (`tests.rs:1692-1795`).
test "load_roundtrip_u64" {
    const gpa = testing.allocator;
    var original = try v1Build(gpa, &.{ 10, 20, 20, 30, 40, 40, 40 });
    defer original.deinit();
    const bytes = try original.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(u64, Rle(u64)).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(original.len(), loaded.len());
    for (0..original.len()) |i| try testing.expectEqual(try original.get(i), try loaded.get(i));
}

test "load_roundtrip_i64" {
    const gpa = testing.allocator;
    var original = try Column(i64, Rle(i64)).init(gpa);
    defer original.deinit();
    try original.extend(gpa, &.{ -5, 0, 100, -1, -1 });
    const bytes = try original.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(i64, Rle(i64)).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(original.len(), loaded.len());
    for (0..original.len()) |i| try testing.expectEqual(try original.get(i), try loaded.get(i));
}

test "load_roundtrip_nullable" {
    const gpa = testing.allocator;
    var original = try v1BuildOpt(gpa, &.{ 1, null, null, 3, 3 });
    defer original.deinit();
    const bytes = try original.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(?u64, RleOption(u64)).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(original.len(), loaded.len());
    for (0..original.len()) |i| try testing.expectEqual(try original.get(i), try loaded.get(i));
}

test "load_roundtrip_bool" {
    const gpa = testing.allocator;
    var original = try v1BuildBool(gpa, &.{ true, true, false, false, true, false });
    defer original.deinit();
    const bytes = try original.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(bool, Bool).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(original.len(), loaded.len());
    for (0..original.len()) |i| try testing.expectEqual(try original.get(i), try loaded.get(i));
}

//  A hundred copies of one boolean is one run, and the two runs of a hundred
//  differ only in whether the count is padded (`tests.rs:1774`, `:1785`).
test "load_roundtrip_bool_all_true" {
    const gpa = testing.allocator;
    var original = try Column(bool, Bool).init(gpa);
    defer original.deinit();
    try original.extend(gpa, &([_]bool{true} ** 100));
    const bytes = try original.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(bool, Bool).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 100), loaded.len());
    for (0..100) |i| try testing.expectEqual(true, try loaded.get(i));
}

test "load_roundtrip_bool_all_false" {
    const gpa = testing.allocator;
    var original = try Column(bool, Bool).init(gpa);
    defer original.deinit();
    try original.extend(gpa, &([_]bool{false} ** 100));
    const bytes = try original.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(bool, Bool).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 100), loaded.len());
    for (0..100) |i| try testing.expectEqual(false, try loaded.get(i));
}

//  An absent run is not part of a non-nullable column's format, so bytes
//  carrying one are refused rather than read as zero
//  (`tests.rs:1835`, `:1846`; `rle/decoder.rs:438-497`).
test "load_null_in_non_nullable_u64_is_error" {
    const gpa = testing.allocator;
    var nullable = try v1BuildOpt(gpa, &.{ 1, null, 3 });
    defer nullable.deinit();
    const bytes = try nullable.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnexpectedNull, Column(u64, Rle(u64)).load(gpa, bytes));
}

test "load_null_in_non_nullable_i64_is_error" {
    const gpa = testing.allocator;
    var nullable = try Column(?i64, RleOption(i64)).init(gpa);
    defer nullable.deinit();
    try nullable.extend(gpa, &.{ 1, null, 3 });
    const bytes = try nullable.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnexpectedNull, Column(i64, Rle(i64)).load(gpa, bytes));
}

//  The same bytes into the nullable column they came from (`tests.rs:1879`).
test "load_null_in_nullable_is_ok" {
    const gpa = testing.allocator;
    var nullable = try v1BuildOpt(gpa, &.{ 1, null, 3 });
    defer nullable.deinit();
    const bytes = try nullable.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(?u64, RleOption(u64)).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 3), loaded.len());
    try testing.expectEqual(@as(?u64, 1), try loaded.get(0));
    try testing.expectEqual(@as(?u64, null), try loaded.get(1));
    try testing.expectEqual(@as(?u64, 3), try loaded.get(2));
}

//  Truncation is either a refusal or a shorter column — never a trap
//  (`tests.rs:1890`). The port refuses: the load validates the whole run
//  sequence before it cuts any slab (`Column.load` → `canonicalSlab`).
test "load_truncated_data_is_error" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2, 3, 4, 5 });
    defer col.deinit();
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    // The port refuses, with the codec's own refusal: a run header whose
    // count is wider than the bytes that follow it (`rle.zig`,
    // `readRunHeader`).
    try testing.expectError(error.LengthExceedsInput, Column(u64, Rle(u64)).load(gpa, bytes[0..1]));
    // Every non-empty strict prefix is refused, which is the totality property
    // the codec is held to; the empty prefix is a valid empty column.
    var cut: usize = 1;
    while (cut < bytes.len) : (cut += 1) {
        try testing.expectError(error.LengthExceedsInput, Column(u64, Rle(u64)).load(gpa, bytes[0..cut]));
    }
}

//  Upstream's rule for a truncated column load, and it is the half of the
//  rule the test above cannot reach: a truncated load either refuses or
//  yields a **strictly shorter** column — never a full-length one, and never
//  an empty one standing in for a truncated one (`tests.rs:1894-1897`,
//  `if let Ok(loaded) = &result { assert!(loaded.len() < col.len()) }`).
//
//  The column above has exactly one run, so every one of its strict prefixes
//  cuts that run in half and the reference refuses them all by handing an
//  empty slice to the value reader (`rle/decoder.rs:228-232`). The "shorter
//  column" arm needs a column with more than one run, where a prefix that
//  ends a run whole is a canonical run sequence on its own and both the
//  reference and this port load it (`rle/decoder.rs:233-234`).
//
//  This is what catches the other reading of "truncation is a shorter
//  column". A load that keeps the longest acceptable prefix without holding
//  it to *strictly* shorter hands back an empty column for the prefix above,
//  and an empty column reads as "this column is empty" rather than "this
//  column was cut".
test "load_truncated_at_a_run_boundary_is_a_shorter_column" {
    const gpa = testing.allocator;
    {
        var col = try v1Build(gpa, &.{ 1, 1, 2, 2, 3 });
        defer col.deinit();
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        try expectTruncationRule(Column(u64, Rle(u64)), Rle(u64), gpa, &col, bytes);
    }
    {
        // The nullable form's truncation the plain one does not have: a cut
        // between a null run's zero marker and the unsigned count that
        // follows it (`rle/decoder.rs:258-262`).
        var col = try v1BuildOpt(gpa, &.{ null, null, 5, 5, 5 });
        defer col.deinit();
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        try expectTruncationRule(Column(?u64, RleOption(u64)), RleOption(u64), gpa, &col, bytes);
    }
}

//  Eleven 0xff bytes are an overlong LEB128 and then some (`tests.rs:1902`).
test "load_garbage_data_is_error" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidLeb128, Column(u64, Rle(u64)).load(gpa, &([_]u8{0xff} ** 11)));
}

//  A load after a splice, a remove and another splice (`tests.rs:1911`).
test "load_roundtrip_after_mutations" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 10, 20, 30, 40, 50 });
    defer col.deinit();
    try insertAt(Column(u64, Rle(u64)), gpa, &col, 2, 25);
    try removeAt(Column(u64, Rle(u64)), gpa, &col, 4);
    try col.splice(gpa, 0, 1, &.{ 99, 100 });
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(u64, Rle(u64)).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(col.len(), loaded.len());
    for (0..col.len()) |i| try testing.expectEqual(try col.get(i), try loaded.get(i));
}

//  Ten thousand distinct values: many slabs on both sides (`tests.rs:1925`).
test "load_roundtrip_large" {
    const gpa = testing.allocator;
    const values = try gpa.alloc(u64, 10_000);
    defer gpa.free(values);
    for (values, 0..) |*v, i| v.* = @intCast(i);
    var original = try Column(u64, Rle(u64)).init(gpa);
    defer original.deinit();
    try original.extend(gpa, values);
    const bytes = try original.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(u64, Rle(u64)).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(original.len(), loaded.len());
    var i: usize = 0;
    while (i < 10_000) : (i += 100) {
        try testing.expectEqual(try original.get(i), try loaded.get(i));
    }
}

//  The three `load_roundtrip_proptest_*` cases (`tests.rs:1938`, `:1949`,
//  `:1960`), each over forty seeded value lists in upstream's generator
//  domain (`prop::collection::vec(0u64..1000, 0..500)` and its boolean and
//  optional forms).
fn roundTripSeeds() struct {
    u64_seed: u64,
    bool_seed: u64,
    opt_seed: u64,
} {
    return .{ .u64_seed = 0x1D0C_5EED, .bool_seed = 0xB001_5EED, .opt_seed = 0x0FF0_5EED };
}

test "load_roundtrip_proptest_u64" {
    const gpa = testing.allocator;
    var seed = roundTripSeeds().u64_seed;
    var case: usize = 0;
    while (case < 40) : (case += 1) {
        const n = xorshift(&seed) % 500;
        const values = try gpa.alloc(u64, n);
        defer gpa.free(values);
        for (values) |*v| v.* = xorshift(&seed) % 1000;
        var original = try Column(u64, Rle(u64)).init(gpa);
        defer original.deinit();
        try original.extend(gpa, values);
        const bytes = try original.encode(gpa);
        defer gpa.free(bytes);
        var loaded = try Column(u64, Rle(u64)).load(gpa, bytes);
        defer loaded.deinit();
        try testing.expectEqual(n, loaded.len());
        for (values, 0..) |v, i| try testing.expectEqual(v, try loaded.get(i));
    }
}

test "load_roundtrip_proptest_bool" {
    const gpa = testing.allocator;
    var seed = roundTripSeeds().bool_seed;
    var case: usize = 0;
    while (case < 40) : (case += 1) {
        const n = xorshift(&seed) % 500;
        const values = try gpa.alloc(bool, n);
        defer gpa.free(values);
        for (values) |*v| v.* = xorshift(&seed) % 2 == 0;
        var original = try Column(bool, Bool).init(gpa);
        defer original.deinit();
        try original.extend(gpa, values);
        const bytes = try original.encode(gpa);
        defer gpa.free(bytes);
        var loaded = try Column(bool, Bool).load(gpa, bytes);
        defer loaded.deinit();
        try testing.expectEqual(n, loaded.len());
        for (values, 0..) |v, i| try testing.expectEqual(v, try loaded.get(i));
    }
}

test "load_roundtrip_proptest_nullable" {
    const gpa = testing.allocator;
    var seed = roundTripSeeds().opt_seed;
    var case: usize = 0;
    while (case < 40) : (case += 1) {
        const n = xorshift(&seed) % 500;
        const values = try gpa.alloc(?u64, n);
        defer gpa.free(values);
        for (values) |*v| {
            const r = xorshift(&seed);
            v.* = if (r % 7 == 0) null else r % 1000;
        }
        var original = try Column(?u64, RleOption(u64)).init(gpa);
        defer original.deinit();
        try original.extend(gpa, values);
        const bytes = try original.encode(gpa);
        defer gpa.free(bytes);
        var loaded = try Column(?u64, RleOption(u64)).load(gpa, bytes);
        defer loaded.deinit();
        try testing.expectEqual(n, loaded.len());
        for (values, 0..) |v, i| try testing.expectEqual(v, try loaded.get(i));
    }
}

//  Empty bytes plus a fill and a length are that many copies of the fill
//  (`load_opts.rs:26-48`, `column.rs:1156-1170`; `tests.rs:2539`, `:2547`).
test "load_with_empty_data_and_fill_gives_filled_bool" {
    const gpa = testing.allocator;
    var col = try Column(bool, Bool).loadWith(
        gpa,
        &.{},
        Column(bool, Bool).LoadOpts.new().withLength(5).withFill(false),
    );
    defer col.deinit();
    try testing.expectEqual(@as(usize, 5), col.len());
    try testing.expect(try col.isOnly(false));
}

test "load_with_empty_data_and_fill_gives_filled_nullable" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).loadWith(
        gpa,
        &.{},
        Column(?u64, RleOption(u64)).LoadOpts.new().withLength(3).withFill(null),
    );
    defer col.deinit();
    try testing.expectEqual(@as(usize, 3), col.len());
    try testing.expect(try col.isOnly(null));
}

//  A length with no fill against empty bytes is `PackError::InvalidLength(0, 5)`
//  upstream (`tests.rs:2555`); here `error.InvalidValue`
//  (`Column.LoadOpts.length`).
test "load_with_empty_data_length_without_fill_errors" {
    const gpa = testing.allocator;
    try testing.expectError(
        error.InvalidValue,
        Column(bool, Bool).loadWith(gpa, &.{}, Column(bool, Bool).LoadOpts.new().withLength(5)),
    );
}

test "load_with_empty_data_and_zero_length" {
    const gpa = testing.allocator;
    var col = try Column(bool, Bool).loadWith(gpa, &.{}, Column(bool, Bool).LoadOpts.new().withLength(0));
    defer col.deinit();
    try testing.expectEqual(@as(usize, 0), col.len());
}

//  Bytes that decode to another count than the one named
//  (`tests.rs:2567`, `:2575`, `:2594`).
test "load_with_length_mismatch_errors" {
    const gpa = testing.allocator;
    var col = try v1BuildOpt(gpa, &.{ 1, 2 });
    defer col.deinit();
    const data = try col.encode(gpa);
    defer gpa.free(data);
    try testing.expectError(
        error.InvalidValue,
        Column(?u64, RleOption(u64)).loadWith(
            gpa,
            data,
            Column(?u64, RleOption(u64)).LoadOpts.new().withLength(5),
        ),
    );
}

test "load_with_length_match_succeeds" {
    const gpa = testing.allocator;
    var col = try v1BuildOpt(gpa, &.{ 1, null, 3 });
    defer col.deinit();
    const data = try col.encode(gpa);
    defer gpa.free(data);
    var loaded = try Column(?u64, RleOption(u64)).loadWith(
        gpa,
        data,
        Column(?u64, RleOption(u64)).LoadOpts.new().withLength(3),
    );
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 3), loaded.len());
    try testing.expectEqual(@as(?u64, 1), try loaded.get(0));
    try testing.expectEqual(@as(?u64, null), try loaded.get(1));
    try testing.expectEqual(@as(?u64, 3), try loaded.get(2));
}

//  `load` with no options at all takes whatever the bytes say
//  (`tests.rs:2586`).
test "load_with_no_validation_accepts_all" {
    const gpa = testing.allocator;
    var col = try v1BuildOpt(gpa, &.{ 1, 2, null });
    defer col.deinit();
    const data = try col.encode(gpa);
    defer gpa.free(data);
    var loaded = try Column(?u64, RleOption(u64)).load(gpa, data);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 3), loaded.len());
}

test "load_with_length" {
    const gpa = testing.allocator;
    var col = try v1BuildOpt(gpa, &.{ 1, 2, 3 });
    defer col.deinit();
    const data = try col.encode(gpa);
    defer gpa.free(data);
    var loaded = try Column(?u64, RleOption(u64)).loadWith(
        gpa,
        data,
        Column(?u64, RleOption(u64)).LoadOpts.new().withLength(3),
    );
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 3), loaded.len());
}

//  Every value shape the wire form can carry, saved and loaded back through
//  the port's single slab cut (`tests.rs:5010`).
//
//  Upstream sweeps `with_max_segments` over 2, 8 and 64; this sweep keeps the
//  shape axis under the default budget, and a load is still required to
//  reproduce its own bytes.
test "load_roundtrips_across_shapes" {
    const gpa = testing.allocator;
    // A long literal run (forces literal splitting), repeats, and a mix.
    {
        const values = try gpa.alloc(u64, 300);
        defer gpa.free(values);
        for (values, 0..) |*v, i| v.* = @intCast(i);
        try expectShapeRoundTrip(u64, Rle(u64), values);
    }
    {
        const values = try gpa.alloc(u64, 300);
        defer gpa.free(values);
        for (values, 0..) |*v, i| v.* = @intCast(i / 50);
        try expectShapeRoundTrip(u64, Rle(u64), values);
    }
    {
        const values = try gpa.alloc(u64, 300);
        defer gpa.free(values);
        for (values, 0..) |*v, i| v.* = if (i % 7 == 0) @intCast(i) else 9;
        try expectShapeRoundTrip(u64, Rle(u64), values);
    }
    {
        const values = try gpa.alloc(?u64, 200);
        defer gpa.free(values);
        for (values, 0..) |*v, i| v.* = if (i % 5 == 0) null else @as(?u64, @intCast(i / 3));
        try expectShapeRoundTrip(?u64, RleOption(u64), values);
    }
    {
        const values = try gpa.alloc(bool, 500);
        defer gpa.free(values);
        for (values, 0..) |*v, i| v.* = (i / 13) % 2 == 0;
        try expectShapeRoundTrip(bool, Bool, values);
    }
    {
        // A prefix column's weights must come out right for the prefix
        // queries, which is the point of the shape (`tests.rs:5056-5063`).
        const counts = try gpa.alloc(u32, 400);
        defer gpa.free(counts);
        for (counts, 0..) |*v, i| v.* = @intCast(i % 5);
        var col = try Column(u32, Prefix(u32)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, counts);
        const saved = try col.encode(gpa);
        defer gpa.free(saved);
        var loaded = try Column(u32, Prefix(u32)).load(gpa, saved);
        defer loaded.deinit();
        var total: i64 = 0;
        for (counts, 0..) |c, pos| {
            try testing.expectEqual(total, try loaded.getPrefix(pos));
            total += @intCast(c);
        }
        try testing.expectEqual(total, try loaded.getPrefix(counts.len));
    }
}

/// Saves `values`, loads them back, and holds both the values and the bytes.
fn expectShapeRoundTrip(comptime T: type, comptime E: type, values: []const T) !void {
    const gpa = testing.allocator;
    var col = try Column(T, E).init(gpa);
    defer col.deinit();
    try col.extend(gpa, values);
    const saved = try col.encode(gpa);
    defer gpa.free(saved);
    var loaded = try Column(T, E).load(gpa, saved);
    defer loaded.deinit();
    const got = try loaded.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(T, values, got);
    const again = try loaded.encode(gpa);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, saved, again);
}

//  Empty bytes, a fill and a length; then a length that disagrees with the
//  bytes (`tests.rs:5072`).
test "load_empty_and_fill_and_length" {
    const gpa = testing.allocator;
    const C = Column(u64, Rle(u64));
    var col = try C.loadWith(gpa, &.{}, C.LoadOpts.new().withLength(5).withFill(7));
    defer col.deinit();
    const filled = try col.toSlice(gpa);
    defer gpa.free(filled);
    try testing.expectEqualSlices(u64, &([_]u64{7} ** 5), filled);
    try testing.expectError(error.InvalidValue, C.loadWith(gpa, &.{}, C.LoadOpts.new().withLength(5)));

    var full = try v1Build(gpa, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    defer full.deinit();
    const saved = try full.encode(gpa);
    defer gpa.free(saved);
    try testing.expectError(error.InvalidValue, C.loadWith(gpa, saved, C.LoadOpts.new().withLength(11)));
}

//  Every non-canonical run structure is a load error (`tests.rs:5084`).
test "load_rejects_non_canonical_input" {
    const gpa = testing.allocator;
    const C = Column(u64, Rle(u64));
    const O = Column(?u64, RleOption(u64));
    const cases = [_][]const u8{
        // repeat with count 1
        &.{ 0x01, 0x05 },
        // adjacent equal repeats
        &.{ 0x02, 0x05, 0x02, 0x05 },
        // repeat then equal literal
        &.{ 0x02, 0x05, 0x7f, 0x05 },
        // adjacent literal runs
        &.{ 0x7f, 0x05, 0x7f, 0x05 },
        // literal with consecutive equal values
        &.{ 0x7e, 0x05, 0x05 },
        // literal then equal repeat
        &.{ 0x7f, 0x05, 0x02, 0x05 },
    };
    for (cases) |bytes| {
        try testing.expectError(error.InvalidValue, C.load(gpa, bytes));
        // The run stream refuses the same bytes: the check is at the wire
        // level, beneath the slab machinery.
        try testing.expectError(error.InvalidValue, rle.Rle(u64).canonical(bytes));
    }
    // adjacent null runs
    try testing.expectError(error.InvalidValue, O.load(gpa, &.{ 0x00, 0x01, 0x00, 0x01 }));
    // count-0 null run
    try testing.expectError(error.InvalidValue, O.load(gpa, &.{ 0x00, 0x00 }));
}

//  A null run in a non-nullable column and a truncated payload are both
//  refused (`tests.rs:5125`). Upstream's third case is a string column
//  holding invalid UTF-8; the port has no byte-string codec.
test "load_rejects_bad_contents" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnexpectedNull, Column(u64, Rle(u64)).load(gpa, &.{ 0x00, 0x01 }));
    try testing.expectError(error.UnexpectedEnd, Column(u64, Rle(u64)).load(gpa, &.{0x02}));
}

//  A prefix column's weights are accumulated as the runs stream past the
//  loader, so every query below descends the index through them
//  (`tests.rs:5178`).
//
//  Upstream asks for `max_segments = 4` to force many slabs; here the shape is
//  five thousand rows of values in `[0, 7)` — 5,000 runs over the 64-run
//  budget, which is many slabs whatever the cut.
test "load_accumulates_prefix_weights" {
    const gpa = testing.allocator;
    var seed: u64 = 0x5EED;
    const vals = try gpa.alloc(u64, 5_000);
    defer gpa.free(vals);
    for (vals) |*v| v.* = xorshift(&seed) % 7;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, vals);
    const saved = try col.encode(gpa);
    defer gpa.free(saved);
    var loaded = try Column(u64, Prefix(u64)).load(gpa, saved);
    defer loaded.deinit();
    try testing.expect(loaded.slabCount() > 1);

    // Upstream reads every row as a `PrefixValue`; the port's `Column.get`
    // answers the row's own length and the cursor answers the sums
    // (`column.zig`, `PrefixIter.next` → `PrefixedValue`).
    var it = try loaded.prefixIter();
    var running: i64 = 0;
    for (vals, 0..) |v, i| {
        const pv = (try it.next()).?;
        try testing.expectEqual(v, pv.value);
        try testing.expectEqual(running, pv.prefix());
        running += @intCast(v);
        try testing.expectEqual(running, pv.total());
        try testing.expectEqual(running, try loaded.getPrefix(i + 1));
    }
}

//  A delta column's index carries a value range per slab, and
//  `find_by_value` prunes on it (`tests.rs:5227`). The port's answer is a
//  walk over the *slabs* that can hold the target, so the row list is built
//  from those slabs' ranges — which is what `op_set.zig:getOpIdPos` does.
fn deltaValueRows(gpa: std.mem.Allocator, col: *const Column(u64, Delta(u64)), target: i64, out: *std.ArrayList(usize)) !void {
    var find = try col.findByValue(target);
    defer find.deinit();
    while (find.next()) |hit| {
        const slab = col.slabAt(hit.slab) orelse return error.InvalidValue;
        const rows: RowRange = .{ .start = hit.items_before, .end = hit.items_before + slab.len };
        var it = try col.iterRange(rows);
        var i: usize = 0;
        while (try it.next()) |v| {
            if (v == target) try out.append(gpa, hit.items_before + i);
            i += 1;
        }
    }
}

test "load_accumulates_delta_agg_weights" {
    const gpa = testing.allocator;
    var seed: u64 = 0xDE17A;
    const vals = try gpa.alloc(u64, 3_000);
    defer gpa.free(vals);
    for (vals) |*v| v.* = xorshift(&seed) % 100;
    var col = try Column(u64, Delta(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, vals);
    const saved = try col.encode(gpa);
    defer gpa.free(saved);
    var loaded = try Column(u64, Delta(u64)).load(gpa, saved);
    defer loaded.deinit();
    try testing.expect(loaded.slabCount() > 1);
    const got_all = try loaded.toSlice(gpa);
    defer gpa.free(got_all);
    try testing.expectEqualSlices(u64, vals, got_all);

    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(gpa);
    var want: std.ArrayList(usize) = .empty;
    defer want.deinit(gpa);
    var target: u64 = 0;
    while (target < 100) : (target += 1) {
        got.clearRetainingCapacity();
        want.clearRetainingCapacity();
        try deltaValueRows(gpa, &loaded, @intCast(target), &got);
        for (vals, 0..) |v, i| {
            if (v == target) try want.append(gpa, i);
        }
        try testing.expectEqualSlices(usize, want.items, got.items);
    }
}

test "load_accumulates_delta_agg_weights_nullable" {
    const gpa = testing.allocator;
    var seed: u64 = 0x0511;
    const vals = try gpa.alloc(?i64, 3_000);
    defer gpa.free(vals);
    for (vals) |*v| {
        const r = xorshift(&seed);
        v.* = if (r % 10 == 0) null else @as(?i64, @as(i64, @intCast(r % 200)) - 100);
    }
    var col = try Column(?i64, Delta(?i64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, vals);
    const saved = try col.encode(gpa);
    defer gpa.free(saved);
    var loaded = try Column(?i64, Delta(?i64)).load(gpa, saved);
    defer loaded.deinit();
    const got_all = try loaded.toSlice(gpa);
    defer gpa.free(got_all);
    try testing.expectEqualSlices(?i64, vals, got_all);

    var target: i64 = -100;
    while (target < 100) : (target += 1) {
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(gpa);
        var find = try loaded.findByValue(target);
        defer find.deinit();
        while (find.next()) |hit| {
            const slab = loaded.slabAt(hit.slab) orelse return error.InvalidValue;
            const rows: RowRange = .{ .start = hit.items_before, .end = hit.items_before + slab.len };
            var it = try loaded.iterRange(rows);
            var i: usize = 0;
            while (try it.next()) |v| {
                if (v == target) try got.append(gpa, hit.items_before + i);
                i += 1;
            }
        }
        var want: std.ArrayList(usize) = .empty;
        defer want.deinit(gpa);
        for (vals, 0..) |v, i| {
            if (v == target) try want.append(gpa, i);
        }
        try testing.expectEqualSlices(usize, want.items, got.items);
    }
}

// ── `iter_*` ────────────────────────────────────────────────────────────────

//  `pos` is the row the next `next` stands on, and a `nth` moves it by the
//  skip plus the row it lands on (`Iter::pos`, `column.rs:521-524`).
test "iter_pos_tracks_position" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 10, 20, 30, 40, 50 });
    defer col.deinit();
    var it = try col.iterator();
    try testing.expectEqual(@as(usize, 0), it.pos());
    _ = try it.next();
    try testing.expectEqual(@as(usize, 1), it.pos());
    _ = try it.next();
    try testing.expectEqual(@as(usize, 2), it.pos());
    _ = try it.nth(1); // skip 30, land on 40
    try testing.expectEqual(@as(usize, 4), it.pos());
    _ = try it.next(); // 50
    try testing.expectEqual(@as(usize, 5), it.pos());
    try testing.expect((try it.next()) == null);
    try testing.expectEqual(@as(usize, 5), it.pos());
}

//  A range cursor starts on the range's first row, not on the column's
//  (`tests.rs:468-477`).
test "iter_range_pos_starts_at_range_start" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 10, 20, 30, 40, 50 });
    defer col.deinit();
    var it = try col.iterRange(.{ .start = 2, .end = 4 });
    try testing.expectEqual(@as(usize, 2), it.pos());
    try testing.expectEqual(@as(?u64, 30), try it.next());
    try testing.expectEqual(@as(usize, 3), it.pos());
    try testing.expectEqual(@as(?u64, 40), try it.next());
    try testing.expectEqual(@as(usize, 4), it.pos());
    try testing.expect((try it.next()) == null);
    try testing.expectEqual(@as(usize, 4), it.pos());
}

//  An empty column answers every range with nothing (`tests.rs:479-484`).
test "iter_empty" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    {
        var it = try col.iterator();
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 0), n);
    }
    for ([_]RowRange{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 10 } }) |r| {
        var it = try col.iterRange(r);
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 0), n);
    }
}

//  The three value shapes a cursor walks in order (`tests.rs:486`, `:495`,
//  `:503`).
test "iter_u64" {
    const gpa = testing.allocator;
    const vals = [_]u64{ 10, 20, 20, 30, 40, 40, 40, 50 };
    var col = try v1Build(gpa, &vals);
    defer col.deinit();
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, &vals, got);
    var it = try col.iterator();
    var i: usize = 0;
    while (try it.next()) |v| : (i += 1) try testing.expectEqual(vals[i], v);
    try testing.expectEqual(vals.len, i);
}

test "iter_bool" {
    const gpa = testing.allocator;
    const vals = [_]bool{ true, true, false, true, false, false, true };
    var col = try v1BuildBool(gpa, &vals);
    defer col.deinit();
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(bool, &vals, got);
    var it = try col.iterator();
    var i: usize = 0;
    while (try it.next()) |v| : (i += 1) try testing.expectEqual(vals[i], v);
    try testing.expectEqual(vals.len, i);
}

test "iter_nullable" {
    const gpa = testing.allocator;
    const vals = [_]?u64{ 1, null, null, 2, 2, null };
    var col = try v1BuildOpt(gpa, &vals);
    defer col.deinit();
    var it = try col.iterator();
    var i: usize = 0;
    while (try it.next()) |v| : (i += 1) try testing.expectEqual(vals[i], v);
    try testing.expectEqual(vals.len, i);
}

//  Six range cases: the ends of the window, a clamp at the column's end, an
//  empty window, a reversed window, and a boolean column (`tests.rs:511-542`).
test "iter_range_basic" {
    const gpa = testing.allocator;
    const vals = try gpa.alloc(u64, 100);
    defer gpa.free(vals);
    for (vals, 0..) |*v, i| v.* = @intCast(i);
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, vals);
    const got = try col.sliceRange(gpa, .{ .start = 10, .end = 20 });
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, vals[10..20], got);
}

test "iter_range_full" {
    const gpa = testing.allocator;
    const vals = try gpa.alloc(u64, 50);
    defer gpa.free(vals);
    for (vals, 0..) |*v, i| v.* = @intCast(i);
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, vals);
    const got = try col.sliceRange(gpa, .{ .start = 0, .end = 50 });
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, vals, got);
}

//  A range that runs off the end is clamped, not refused
//  (`column.rs:1385-1386`; `tests.rs:526`).
test "iter_range_clamped" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    defer col.deinit();
    const got = try col.sliceRange(gpa, .{ .start = 5, .end = 100 });
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, &.{ 5, 6, 7, 8, 9 }, got);
}

//  An empty window and a reversed one are both empty (`tests.rs:535-541`).
test "iter_range_empty" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    defer col.deinit();
    for ([_]RowRange{ .{ .start = 5, .end = 5 }, .{ .start = 7, .end = 3 } }) |r| {
        var it = try col.iterRange(r);
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 0), n);
        try testing.expectEqual(r.start, it.pos());
    }
}

test "iter_range_bool" {
    const gpa = testing.allocator;
    const vals = try gpa.alloc(bool, 100);
    defer gpa.free(vals);
    for (vals, 0..) |*v, i| v.* = i % 3 == 0;
    var col = try Column(bool, Bool).init(gpa);
    defer col.deinit();
    try col.extend(gpa, vals);
    const got = try col.sliceRange(gpa, .{ .start = 20, .end = 40 });
    defer gpa.free(got);
    try testing.expectEqualSlices(bool, vals[20..40], got);
}

//  `ExactSizeIterator::len` is the window's length, whole or clipped
//  (`tests.rs:544-548`); the port spells it `itemsLeft` (`column.rs`).
test "iter_exact_size" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    const vals = try gpa.alloc(u64, 50);
    defer gpa.free(vals);
    for (vals, 0..) |*v, i| v.* = @intCast(i);
    try col.extend(gpa, vals);
    {
        const it = try col.iterator();
        try testing.expectEqual(@as(usize, 50), it.itemsLeft());
    }
    {
        const it = try col.iterRange(.{ .start = 10, .end = 30 });
        try testing.expectEqual(@as(usize, 20), it.itemsLeft());
    }
}

//  A cursor that crosses slab boundaries (`tests.rs:550`, `:559`).
//
//  Upstream forces several slabs with `from_values_with_max_segments(vals, 4)`
//  over `(0..200).map(|i| i * 7 % 100)`; the port builds the same *run*
//  structure under the default budget instead — pairs of equal values over
//  200 runs — which is what the budget counts.
test "iter_multi_slab" {
    const gpa = testing.allocator;
    var col = try manySlabColumn(gpa, 200, 2);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);
    var it = try col.iterator();
    var i: usize = 0;
    while (try it.next()) |v| : (i += 1) {
        try testing.expectEqual(@as(u64, @intCast(i / 2)), v);
    }
    try testing.expectEqual(@as(usize, 400), i);
}

test "iter_range_multi_slab" {
    const gpa = testing.allocator;
    var col = try manySlabColumn(gpa, 200, 2);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);
    const got = try col.sliceRange(gpa, .{ .start = 50, .end = 150 });
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 100), got.len);
    for (got, 0..) |v, k| try testing.expectEqual(@as(u64, @intCast((50 + k) / 2)), v);
}

//  `iter_proptest_u64` and `iter_range_proptest_u64` (`tests.rs:568`, `:574`),
//  as seeded sweeps over upstream's generator domain.
test "iter_proptest_u64" {
    const gpa = testing.allocator;
    var seed: u64 = 0x17E4_0E70;
    var case: usize = 0;
    while (case < 40) : (case += 1) {
        const n = xorshift(&seed) % 500;
        const values = try gpa.alloc(u64, n);
        defer gpa.free(values);
        for (values) |*v| v.* = xorshift(&seed) % 1000;
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, values);
        var it = try col.iterator();
        var i: usize = 0;
        while (try it.next()) |v| : (i += 1) try testing.expectEqual(values[i], v);
        try testing.expectEqual(n, i);
    }
}

test "iter_range_proptest_u64" {
    const gpa = testing.allocator;
    var seed: u64 = 0x2A11_0E70;
    var case: usize = 0;
    while (case < 40) : (case += 1) {
        const n = 10 + xorshift(&seed) % 490;
        const values = try gpa.alloc(u64, n);
        defer gpa.free(values);
        for (values) |*v| v.* = xorshift(&seed) % 1000;
        const start = xorshift(&seed) % 10;
        const len = xorshift(&seed) % 10;
        const s = @min(start, n);
        const e = @min(s + len, n);
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, values);
        const got = try col.sliceRange(gpa, .{ .start = s, .end = e });
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, values[s..e], got);
    }
}

// ── `splice_*` ──────────────────────────────────────────────────────────────

/// Upstream's `validate_rle_column` (`tests.rs:2296-2305`): the column's
/// encoding is canonical and its layout is sound. The port's two halves are
/// the wire check `Column.load` performs (`canonicalSlab`) and
/// `checkInvariants`.
fn validateRleColumn(comptime C: type, col: *const Column(C.Value, C)) !void {
    try expectSound(C.Value, C, col);
    if (try col.checkInvariants()) |v| {
        std.debug.print("invariant broken: {s} {s} (slab {d})\n", .{ @typeName(C), v.what, v.at });
        return error.TestUnexpectedResult;
    }
    const gpa = testing.allocator;
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    try C.canonicalSlab(bytes);
}

/// Two row ranges, with a report rather than a panic.
fn expectScope(want: RowRange, got: RowRange) !void {
    if (want.start == got.start and want.end == got.end) return;
    std.debug.print("scope got {d}..{d}, want {d}..{d}\n", .{ got.start, got.end, want.start, want.end });
    return error.TestUnexpectedResult;
}

//  The four plain splice shapes, and a nullable column's (`tests.rs:366`, `:372`,
//  `:379`, `:385`, `:392`, `:399`).
test "splice_insert_only" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, &.{ 1, 2, 3 });
    try assertCol(u64, Rle(u64), &col, &.{ 1, 2, 3 });
}

test "splice_delete_only" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 10, 20, 30, 40 });
    defer col.deinit();
    try col.splice(gpa, 1, 2, &.{});
    try assertCol(u64, Rle(u64), &col, &.{ 10, 40 });
}

test "splice_replace" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2, 3, 4, 5 });
    defer col.deinit();
    try col.splice(gpa, 1, 2, &.{ 10, 20, 30 });
    try assertCol(u64, Rle(u64), &col, &.{ 1, 10, 20, 30, 4, 5 });
}

test "splice_at_end" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2, 3 });
    defer col.deinit();
    try col.splice(gpa, col.len(), 0, &.{ 4, 5 });
    try assertCol(u64, Rle(u64), &col, &.{ 1, 2, 3, 4, 5 });
}

test "splice_nullable" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, &.{ 1, null, 2 });
    try assertCol(?u64, RleOption(u64), &col, &.{ 1, null, 2 });
    try col.splice(gpa, 1, 1, &.{ 10, 20 });
    try assertCol(?u64, RleOption(u64), &col, &.{ 1, 10, 20, 2 });
}

//  Every position of a literal-then-repeat column, with an insert, a delete
//  and a replace, and a canonical encoding after each (`tests.rs:516-546`).
test "splice_at_literal_repeat_boundary" {
    const gpa = testing.allocator;
    const initial = [_]u64{ 1, 2, 3, 3, 3 };
    var base = try Column(u64, Rle(u64)).init(gpa);
    defer base.deinit();
    try base.extend(gpa, &initial);
    try validateRleColumn(Rle(u64), &base);

    for (0..initial.len + 1) |pos| {
        var c = try cloneU64(gpa, &base);
        defer c.deinit();
        try insertAt(Column(u64, Rle(u64)), gpa, &c, pos, 99);
        try validateRleColumn(Rle(u64), &c);
        try testing.expectEqual(initial.len + 1, c.len());

        if (pos < initial.len) {
            var d = try cloneU64(gpa, &base);
            defer d.deinit();
            try insertAt(Column(u64, Rle(u64)), gpa, &d, pos, initial[pos]);
            try validateRleColumn(Rle(u64), &d);
        }
    }

    for (0..initial.len) |pos| {
        {
            var c = try cloneU64(gpa, &base);
            defer c.deinit();
            try removeAt(Column(u64, Rle(u64)), gpa, &c, pos);
            try validateRleColumn(Rle(u64), &c);
            try testing.expectEqual(initial.len - 1, c.len());
        }
        {
            // Replace with the same value: the column is unchanged.
            var c = try cloneU64(gpa, &base);
            defer c.deinit();
            try c.splice(gpa, pos, 1, &.{initial[pos]});
            try validateRleColumn(Rle(u64), &c);
            const got = try c.toSlice(gpa);
            defer gpa.free(got);
            try testing.expectEqualSlices(u64, &initial, got);
        }
        {
            var c = try cloneU64(gpa, &base);
            defer c.deinit();
            try c.splice(gpa, pos, 1, &.{99});
            try validateRleColumn(Rle(u64), &c);
        }
    }
}

/// A second u64 column holding the same values, which is upstream's
/// `col.clone()` (`tests.rs:527`).
fn cloneU64(gpa: std.mem.Allocator, src: *const Column(u64, Rle(u64))) !Column(u64, Rle(u64)) {
    const all = try src.toSlice(gpa);
    defer gpa.free(all);
    var out = try Column(u64, Rle(u64)).init(gpa);
    errdefer out.deinit();
    try out.extend(gpa, all);
    return out;
}

//  The mirror image: a repeat then a literal (`tests.rs:548-570`).
test "splice_at_repeat_then_literal_boundary" {
    const gpa = testing.allocator;
    const initial = [_]u64{ 5, 5, 5, 1, 2, 3 };
    var base = try Column(u64, Rle(u64)).init(gpa);
    defer base.deinit();
    try base.extend(gpa, &initial);
    try validateRleColumn(Rle(u64), &base);

    for (0..initial.len + 1) |pos| {
        var c = try cloneU64(gpa, &base);
        defer c.deinit();
        try insertAt(Column(u64, Rle(u64)), gpa, &c, pos, 99);
        try validateRleColumn(Rle(u64), &c);

        // Insert the repeat's own value at every position.
        var d = try cloneU64(gpa, &base);
        defer d.deinit();
        try insertAt(Column(u64, Rle(u64)), gpa, &d, pos, 5);
        try validateRleColumn(Rle(u64), &d);
    }
    for (0..initial.len) |pos| {
        var c = try cloneU64(gpa, &base);
        defer c.deinit();
        try removeAt(Column(u64, Rle(u64)), gpa, &c, pos);
        try validateRleColumn(Rle(u64), &c);
    }
}

//  Inserting the repeat's own value at the junction, which is the case the
//  merge rule exists for (`tests.rs:572-586`).
test "splice_insert_same_value_at_literal_repeat_junction" {
    const gpa = testing.allocator;
    {
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ 1, 2, 3, 3, 3 });
        try insertAt(Column(u64, Rle(u64)), gpa, &col, 2, 3);
        try validateRleColumn(Rle(u64), &col);
        const got = try col.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 3, 3, 3 }, got);
    }
    {
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ 1, 2, 3, 3, 3 });
        try insertAt(Column(u64, Rle(u64)), gpa, &col, 3, 2);
        try validateRleColumn(Rle(u64), &col);
        const got = try col.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 2, 3, 3 }, got);
    }
}

//  An insert that overflows the slab's run budget, at every position, so the
//  postfix has to land on the overflow slab (`tests.rs:588-606`).
//
//  Upstream builds the column with `max_segments = 4`; here the column is
//  built with 60 runs — one under the default budget — and the insert adds 20
//  more, which is what forces the split.
test "splice_overflow_at_postfix_boundary" {
    const gpa = testing.allocator;
    const initial = try gpa.alloc(u64, 120);
    defer gpa.free(initial);
    for (initial, 0..) |*v, i| v.* = @intCast(i / 2);
    const new_vals = try gpa.alloc(u64, 40);
    defer gpa.free(new_vals);
    for (new_vals, 0..) |*v, i| v.* = 100 + @as(u64, @intCast(i / 2));

    var base = try Column(u64, Rle(u64)).init(gpa);
    defer base.deinit();
    try base.extend(gpa, initial);
    try validateRleColumn(Rle(u64), &base);

    var model: std.ArrayList(u64) = .empty;
    defer model.deinit(gpa);
    for (0..initial.len + 1) |pos| {
        var c = try cloneU64(gpa, &base);
        defer c.deinit();
        try c.splice(gpa, pos, 0, new_vals);
        try validateRleColumn(Rle(u64), &c);
        try testing.expect(c.slabCount() > 1);

        model.clearRetainingCapacity();
        try model.appendSlice(gpa, initial[0..pos]);
        try model.appendSlice(gpa, new_vals);
        try model.appendSlice(gpa, initial[pos..]);
        const got = try c.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, model.items, got);
    }
}

//  The postfix falls inside a literal run while the slab overflows
//  (`tests.rs:608-620`).
test "splice_overflow_with_postfix_in_literal" {
    const gpa = testing.allocator;
    const initial = try gpa.alloc(u64, 120);
    defer gpa.free(initial);
    for (initial, 0..) |*v, i| v.* = @intCast(i / 2);
    const new_vals = try gpa.alloc(u64, 40);
    defer gpa.free(new_vals);
    for (new_vals, 0..) |*v, i| v.* = 100 + @as(u64, @intCast(i / 2));

    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, initial);
    try validateRleColumn(Rle(u64), &col);
    try col.splice(gpa, 30, 20, new_vals);
    try validateRleColumn(Rle(u64), &col);
    try testing.expect(col.slabCount() > 1);

    var model: std.ArrayList(u64) = .empty;
    defer model.deinit(gpa);
    try model.appendSlice(gpa, initial[0..30]);
    try model.appendSlice(gpa, new_vals);
    try model.appendSlice(gpa, initial[50..]);
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, model.items, got);
}

//  `LonePlusLit`: a delete inside a repeat that leaves one row behind, in
//  front of a literal run (`tests.rs:622-638`).
test "splice_lone_plus_lit_postfix" {
    const gpa = testing.allocator;
    {
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ 7, 7, 7, 1, 2, 3 });
        try validateRleColumn(Rle(u64), &col);
        try col.splice(gpa, 1, 1, &.{});
        try validateRleColumn(Rle(u64), &col);
        const got = try col.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, &.{ 7, 7, 1, 2, 3 }, got);
    }
    {
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &.{ 7, 7, 7, 1, 2, 3 });
        try col.splice(gpa, 0, 2, &.{});
        try validateRleColumn(Rle(u64), &col);
        const got = try col.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, &.{ 7, 1, 2, 3 }, got);
    }
}

test "splice_lone_plus_lit_with_insert" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 7, 7, 7, 1, 2, 3 });
    try col.splice(gpa, 1, 1, &.{99});
    try validateRleColumn(Rle(u64), &col);
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, &.{ 7, 99, 7, 1, 2, 3 }, got);
}

test "splice_lone_plus_lit_insert_same_as_lone" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 7, 7, 7, 1, 2, 3 });
    try col.splice(gpa, 0, 2, &.{});
    try validateRleColumn(Rle(u64), &col);
    try insertAt(Column(u64, Rle(u64)), gpa, &col, 0, 7);
    try validateRleColumn(Rle(u64), &col);
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, &.{ 7, 7, 1, 2, 3 }, got);
}

//  A nullable column whose payload is wider than a byte, spliced and then
//  saved and loaded (`tests.rs:314-324`).
//
//  Upstream writes the case four times, twice per codec: Leb128 (`BeLen`) and
//  `Bijou64`. Only the Leb128 case is ported — `Bijou64` is the second
//  unsigned codec that nothing selects (`docs/plan.md` §2).
test "splice_and_nullable" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, &.{ 1, null, null, 300, 300 });
    try col.splice(gpa, 2, 1, &.{70000});
    try assertCol(?u64, RleOption(u64), &col, &.{ 1, null, 70000, 300, 300 });
    const saved = try col.encode(gpa);
    defer gpa.free(saved);
    var loaded = try Column(?u64, RleOption(u64)).load(gpa, saved);
    defer loaded.deinit();
    const got = try loaded.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(?u64, &.{ 1, null, 70000, 300, 300 }, got);
}

// ── `save_*` ────────────────────────────────────────────────────────────────

//  An empty column saves to nothing (`tests.rs:270-273`).
test "save_empty" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

test "save_single_slab" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2, 3 });
    defer col.deinit();
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 0);
}

//  `save_to_unless` writes nothing when every value is the default and the
//  column's bytes when one is not (`column.rs:1447-1453`; `tests.rs:275`,
//  `:281`, `:287`). The port's `encodeUnless` answers `null` for the first
//  case instead of an empty range, which is the same decision.
test "save_to_unless_skips_all_null" {
    const gpa = testing.allocator;
    var col = try v1BuildOpt(gpa, &.{ null, null, null, null, null });
    defer col.deinit();
    try testing.expect((try col.encodeUnless(gpa, null)) == null);
}

test "save_to_unless_writes_non_null" {
    const gpa = testing.allocator;
    var col = try v1BuildOpt(gpa, &.{ 1, 2, null, 3 });
    defer col.deinit();
    const bytes = (try col.encodeUnless(gpa, null)) orelse return error.TestUnexpectedResult;
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 0);
}

//  A single present value is enough, and zero is a value like any other
//  (`tests.rs:287`).
test "save_to_unless_writes_mixed_null" {
    const gpa = testing.allocator;
    var col = try v1BuildOpt(gpa, &.{ null, null, 0, null });
    defer col.deinit();
    const bytes = (try col.encodeUnless(gpa, null)) orelse return error.TestUnexpectedResult;
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 0);
}

test "save_to_unless_after_insert" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).fill(gpa, 10, null);
    defer col.deinit();
    try testing.expect((try col.encodeUnless(gpa, null)) == null);
    try insertAt(Column(?u64, RleOption(u64)), gpa, &col, 5, 42);
    const bytes = (try col.encodeUnless(gpa, null)) orelse return error.TestUnexpectedResult;
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 0);
}

//  The same five cases for a boolean column (`tests.rs:301`, `:307`, `:313`,
//  `:319`).
test "save_to_unless_skips_all_false" {
    const gpa = testing.allocator;
    var col = try v1BuildBool(gpa, &.{ false, false, false, false });
    defer col.deinit();
    try testing.expect((try col.encodeUnless(gpa, false)) == null);
}

test "save_to_unless_writes_mixed_bool" {
    const gpa = testing.allocator;
    var col = try v1BuildBool(gpa, &.{ false, false, true, false });
    defer col.deinit();
    const bytes = (try col.encodeUnless(gpa, false)) orelse return error.TestUnexpectedResult;
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 0);
}

test "save_to_unless_skips_all_true" {
    const gpa = testing.allocator;
    var col = try v1BuildBool(gpa, &.{ true, true, true });
    defer col.deinit();
    try testing.expect((try col.encodeUnless(gpa, true)) == null);
    const bytes = (try col.encodeUnless(gpa, false)) orelse return error.TestUnexpectedResult;
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 0);
}

test "save_to_unless_bool_after_insert" {
    const gpa = testing.allocator;
    var col = try Column(bool, Bool).fill(gpa, 10, false);
    defer col.deinit();
    try testing.expect((try col.encodeUnless(gpa, false)) == null);
    try insertAt(Column(bool, Bool), gpa, &col, 5, true);
    const bytes = (try col.encodeUnless(gpa, false)) orelse return error.TestUnexpectedResult;
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 0);
}

//  Four columns saved into one buffer, each range equal to its own save and
//  the concatenation equal to the four saves laid end to end
//  (`tests.rs:325-379`).
//
//  The port has no `save_to(&mut buf) -> Range`: `encode` allocates and the
//  caller frees, so the buffer here is the concatenation the test builds, and
//  the ranges are the offsets it computed. Upstream's fourth column is a
//  `String`; the port has no byte-string codec.
test "save_to_multi_column_concatenation" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5A4E_0001);
    const rand = prng.random();
    const n = 1000;

    const u64_vals = try gpa.alloc(u64, n);
    defer gpa.free(u64_vals);
    for (u64_vals) |*v| v.* = rand.intRangeLessThan(u64, 0, 100);
    const opt_vals = try gpa.alloc(?u64, n);
    defer gpa.free(opt_vals);
    for (opt_vals) |*v| {
        v.* = if (rand.intRangeLessThan(u32, 0, 5) == 0) null else rand.intRangeLessThan(u64, 0, 5);
    }
    const bool_vals = try gpa.alloc(bool, n);
    defer gpa.free(bool_vals);
    for (bool_vals) |*v| v.* = rand.boolean();

    var c_u64 = try Column(u64, Rle(u64)).init(gpa);
    defer c_u64.deinit();
    try c_u64.extend(gpa, u64_vals);
    var c_opt = try Column(?u64, RleOption(u64)).init(gpa);
    defer c_opt.deinit();
    try c_opt.extend(gpa, opt_vals);
    var c_bool = try Column(bool, Bool).init(gpa);
    defer c_bool.deinit();
    try c_bool.extend(gpa, bool_vals);

    const s_u64 = try c_u64.encode(gpa);
    defer gpa.free(s_u64);
    const s_opt = try c_opt.encode(gpa);
    defer gpa.free(s_opt);
    const s_bool = try c_bool.encode(gpa);
    defer gpa.free(s_bool);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const r_u64: RowRange = .{ .start = 0, .end = s_u64.len };
    try buf.appendSlice(gpa, s_u64);
    const r_opt: RowRange = .{ .start = buf.items.len, .end = buf.items.len + s_opt.len };
    try buf.appendSlice(gpa, s_opt);
    const r_bool: RowRange = .{ .start = buf.items.len, .end = buf.items.len + s_bool.len };
    try buf.appendSlice(gpa, s_bool);

    try testing.expectEqualSlices(u8, s_u64, buf.items[r_u64.start..r_u64.end]);
    try testing.expectEqualSlices(u8, s_opt, buf.items[r_opt.start..r_opt.end]);
    try testing.expectEqualSlices(u8, s_bool, buf.items[r_bool.start..r_bool.end]);
    // Ranges are contiguous and cover the buffer.
    try testing.expectEqual(@as(usize, 0), r_u64.start);
    try testing.expectEqual(r_u64.end, r_opt.start);
    try testing.expectEqual(r_opt.end, r_bool.start);
    try testing.expectEqual(buf.items.len, r_bool.end);

    {
        var back = try Column(u64, Rle(u64)).load(gpa, buf.items[r_u64.start..r_u64.end]);
        defer back.deinit();
        const got = try back.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, u64_vals, got);
    }
    {
        var back = try Column(?u64, RleOption(u64)).load(gpa, buf.items[r_opt.start..r_opt.end]);
        defer back.deinit();
        const got = try back.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(?u64, opt_vals, got);
    }
    {
        var back = try Column(bool, Bool).load(gpa, buf.items[r_bool.start..r_bool.end]);
        defer back.deinit();
        const got = try back.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(bool, bool_vals, got);
    }
}

// ── `insert_*` ──────────────────────────────────────────────────────────────

//  The three positions an insert can take (`tests.rs:146`, `:152`, `:158`).
test "insert_at_beginning" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 2, 3 });
    defer col.deinit();
    try insertAt(Column(u64, Rle(u64)), gpa, &col, 0, 1);
    try assertCol(u64, Rle(u64), &col, &.{ 1, 2, 3 });
}

test "insert_at_end" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2 });
    defer col.deinit();
    try insertAt(Column(u64, Rle(u64)), gpa, &col, 2, 3);
    try assertCol(u64, Rle(u64), &col, &.{ 1, 2, 3 });
}

test "insert_in_middle" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 3 });
    defer col.deinit();
    try insertAt(Column(u64, Rle(u64)), gpa, &col, 1, 2);
    try assertCol(u64, Rle(u64), &col, &.{ 1, 2, 3 });
}

//  `build_and_check` with two copies of one value in a row, which is a
//  literal run taking a second item (`tests.rs:210`).
test "insert_duplicate_into_literal" {
    try buildAndCheck(&.{
        .{ .v = null, .at = 0 },
        .{ .v = 1, .at = 0 },
        .{ .v = 1, .at = 0 },
    });
}

//  A present value inserted into a run of nulls splits it, and the two
//  literals either side merge (`tests.rs:213-224`).
test "insert_into_null_run_merges_literals" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);
    for ([_]struct { v: ?u64, at: usize }{
        .{ .v = 2, .at = 0 },
        .{ .v = null, .at = 1 },
        .{ .v = null, .at = 2 },
        .{ .v = 3, .at = 3 },
    }) |one| {
        try col.splice(gpa, one.at, 0, &.{one.v});
        try mirror.insert(gpa, one.at, one.v);
    }
    try assertCol(?u64, RleOption(u64), &col, mirror.items);

    try col.splice(gpa, 1, 0, &.{5});
    try mirror.insert(gpa, 1, 5);
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(?u64, &.{ 2, 5, null, null, 3 }, got);
}

test "insert_value_into_null_adjacent_null" {
    try buildAndCheck(&.{
        .{ .v = null, .at = 0 },
        .{ .v = null, .at = 0 },
        .{ .v = 2, .at = 0 },
        .{ .v = 2, .at = 1 },
    });
}

// ── `scope_*` ───────────────────────────────────────────────────────────────

//  `scope_to_value` over the row range a value's contiguous run covers, with
//  the window truncated at both ends (`tests.rs:3438-3462`).
//
//  Upstream's `..` is `0..len`; the port takes an explicit `RowRange`
//  (`column.rs:1495-1506`).
test "scope_to_value_basic" {
    const gpa = testing.allocator;
    const data = [_]?u64{ 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 8, 9, 9 };
    var col = try v1BuildOpt(gpa, &data);
    defer col.deinit();
    const whole: RowRange = .{ .start = 0, .end = data.len };

    try testing.expectEqual(RowRange{ .start = 7, .end = 15 }, try col.scopeToValue(4, whole));
    try testing.expectEqual(RowRange{ .start = 7, .end = 11 }, try col.scopeToValue(4, .{ .start = 0, .end = 11 }));
    try testing.expectEqual(RowRange{ .start = 7, .end = 8 }, try col.scopeToValue(4, .{ .start = 0, .end = 8 }));
    try testing.expectEqual(RowRange{ .start = 1, .end = 1 }, try col.scopeToValue(4, .{ .start = 0, .end = 1 }));
    try testing.expectEqual(RowRange{ .start = 8, .end = 9 }, try col.scopeToValue(4, .{ .start = 8, .end = 9 }));
    try testing.expectEqual(RowRange{ .start = 9, .end = 15 }, try col.scopeToValue(4, .{ .start = 9, .end = 25 }));
    try testing.expectEqual(RowRange{ .start = 14, .end = 15 }, try col.scopeToValue(4, .{ .start = 14, .end = 16 }));

    try testing.expectEqual(RowRange{ .start = 0, .end = 3 }, try col.scopeToValue(2, whole));
    try testing.expectEqual(RowRange{ .start = 22, .end = 22 }, try col.scopeToValue(7, whole));
    try testing.expectEqual(RowRange{ .start = 22, .end = 23 }, try col.scopeToValue(8, whole));
    try testing.expectEqual(RowRange{ .start = 23, .end = 25 }, try col.scopeToValue(9, whole));
}

//  A value below every one, above every one, and in a gap the window cuts
//  (`tests.rs:3476-3486`).
test "scope_to_value_not_found" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2, 3, 4, 5 });
    defer col.deinit();
    try testing.expectEqual(RowRange{ .start = 0, .end = 0 }, try col.scopeToValue(0, .{ .start = 0, .end = 5 }));
    try testing.expectEqual(RowRange{ .start = 5, .end = 5 }, try col.scopeToValue(6, .{ .start = 0, .end = 5 }));
    try testing.expectEqual(RowRange{ .start = 2, .end = 2 }, try col.scopeToValue(3, .{ .start = 0, .end = 2 }));
}

test "scope_to_value_empty" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try testing.expectEqual(RowRange{ .start = 0, .end = 0 }, try col.scopeToValue(1, .{ .start = 0, .end = 0 }));
}

//  One row: the value, a value below it and a value above it (`tests.rs:3494-3499`).
test "scope_to_value_single_element" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{5});
    defer col.deinit();
    const whole: RowRange = .{ .start = 0, .end = 1 };
    try testing.expectEqual(RowRange{ .start = 0, .end = 1 }, try col.scopeToValue(5, whole));
    try testing.expectEqual(RowRange{ .start = 0, .end = 0 }, try col.scopeToValue(4, whole));
    try testing.expectEqual(RowRange{ .start = 1, .end = 1 }, try col.scopeToValue(6, whole));
}

//  A run that runs past the window is truncated at the window's end
//  (`tests.rs:3501-3511`).
test "scope_to_value_range_truncation" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 1, 1, 2, 2, 2, 2, 2, 3, 3 });
    defer col.deinit();
    try testing.expectEqual(RowRange{ .start = 4, .end = 6 }, try col.scopeToValue(2, .{ .start = 4, .end = 6 }));
    try testing.expectEqual(RowRange{ .start = 3, .end = 5 }, try col.scopeToValue(2, .{ .start = 3, .end = 5 }));
    try testing.expectEqual(RowRange{ .start = 3, .end = 8 }, try col.scopeToValue(2, .{ .start = 3, .end = 10 }));
    try testing.expectEqual(RowRange{ .start = 0, .end = 2 }, try col.scopeToValue(1, .{ .start = 0, .end = 2 }));
}

//  The same answers over a column of several slabs (`tests.rs:3513-3525`).
//
//  Upstream forces the slabs with `max_segments = 4`; here the shape is 100
//  runs of three rows each over the 64-run budget.
test "scope_to_value_multi_slab" {
    const gpa = testing.allocator;
    var col = try manySlabColumn(gpa, 100, 3);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);
    const whole: RowRange = .{ .start = 0, .end = col.len() };
    try testing.expectEqual(RowRange{ .start = 0, .end = 3 }, try col.scopeToValue(0, whole));
    try testing.expectEqual(RowRange{ .start = 150, .end = 153 }, try col.scopeToValue(50, whole));
    try testing.expectEqual(RowRange{ .start = 297, .end = 300 }, try col.scopeToValue(99, whole));
    try testing.expectEqual(RowRange{ .start = 300, .end = 300 }, try col.scopeToValue(100, whole));
    try testing.expectEqual(RowRange{ .start = 151, .end = 152 }, try col.scopeToValue(50, .{ .start = 151, .end = 152 }));
    try testing.expectEqual(RowRange{ .start = 145, .end = 145 }, try col.scopeToValue(50, .{ .start = 140, .end = 145 }));
}

//  A thousand random windows over a thousand sorted runs, against a linear
//  scan (`tests.rs:3527-3585`).
test "scope_to_value_fuzz_vs_linear" {
    const gpa = testing.allocator;
    const n: u32 = 1000;
    const step_len: usize = 3;
    var prng: std.Random.DefaultPrng = .init(0x5C0E_0002);
    const rand = prng.random();

    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    var data: std.ArrayList(u64) = .empty;
    defer data.deinit(gpa);
    for (0..n) |i| {
        const v: u64 = @as(u64, @intCast(i)) * 2 + 1;
        for (0..step_len) |_| {
            try col.append(gpa, v);
            try data.append(gpa, v);
        }
    }
    try testing.expect(col.slabCount() > 1);

    var case: usize = 0;
    while (case < 1000) : (case += 1) {
        const roll = rand.intRangeLessThan(u32, 0, n);
        const target_present: u64 = @as(u64, roll) * 2 + 1;
        const target_absent: u64 = @as(u64, roll) * 2;
        var a = rand.intRangeLessThan(usize, 0, n * step_len);
        var b = rand.intRangeLessThan(usize, 0, n * step_len);
        if (a > b) std.mem.swap(usize, &a, &b);

        // The reference answer, by a linear scan of the window.
        var want_present: RowRange = .{ .start = a, .end = a };
        var seen = false;
        var first: usize = 0;
        var last: usize = 0;
        for (data.items[a..b], 0..) |v, k| {
            if (v == target_present) {
                if (!seen) {
                    seen = true;
                    first = k;
                }
                last = k;
            }
        }
        if (seen) {
            want_present = .{ .start = a + first, .end = a + last + 1 };
        } else {
            var ip = b;
            for (data.items[a..b], 0..) |v, k| {
                if (v >= target_present) {
                    ip = a + k;
                    break;
                }
            }
            want_present = .{ .start = ip, .end = ip };
        }
        var ip_absent = b;
        for (data.items[a..b], 0..) |v, k| {
            if (v >= target_absent) {
                ip_absent = a + k;
                break;
            }
        }
        try expectScope(want_present, try col.scopeToValue(target_present, .{ .start = a, .end = b }));
        const want_absent: RowRange = .{ .start = ip_absent, .end = ip_absent };
        try expectScope(want_absent, try col.scopeToValue(target_absent, .{ .start = a, .end = b }));
    }
}

//  A middle group spread over three or more slabs, built by inserting at
//  scattered positions (`tests.rs:3587-3620`).
test "scope_to_value_multi_slab_span" {
    const gpa = testing.allocator;
    var col = try Column(?u32, RleOption(u32)).init(gpa);
    defer col.deinit();
    try insertAt(Column(?u32, RleOption(u32)), gpa, &col, 0, null);

    var seed: u64 = 42;
    const group1_start: usize = 1;
    for (0..200) |i| {
        const pos = group1_start + (@as(usize, @intCast(xorshift(&seed))) % (i + 1));
        try insertAt(Column(?u32, RleOption(u32)), gpa, &col, pos, 1);
    }
    const group1_end: usize = 201;
    for (0..10) |i| try insertAt(Column(?u32, RleOption(u32)), gpa, &col, group1_end + i, 2);

    try testing.expectEqual(@as(usize, 211), col.len());
    const whole: RowRange = .{ .start = 0, .end = col.len() };
    try testing.expectEqual(RowRange{ .start = 1, .end = 201 }, try col.scopeToValue(1, whole));
    try testing.expectEqual(RowRange{ .start = 0, .end = 1 }, try col.scopeToValue(null, whole));
    try testing.expectEqual(RowRange{ .start = 201, .end = 211 }, try col.scopeToValue(2, whole));
}

//  The middle run located across every prefix / run / suffix shape
//  (`tests.rs:3622-3641`).
//
//  Upstream's outer axis is `max_segments`; this sweep keeps the run lengths
//  — the shapes that decide where a run starts and ends — and reaches several
//  slabs under the default budget instead of by tuning one.
test "scope_to_value_fuzz_multi_slab" {
    const gpa = testing.allocator;
    for ([_]usize{ 0, 1, 2, 5 }) |prefix_len| {
        for ([_]usize{ 10, 50, 100, 200 }) |run_len| {
            for ([_]usize{ 0, 1, 5, 10 }) |suffix_len| {
                const data = try gpa.alloc(u64, prefix_len + run_len + suffix_len);
                defer gpa.free(data);
                @memset(data[0..prefix_len], 0);
                @memset(data[prefix_len .. prefix_len + run_len], 1);
                @memset(data[prefix_len + run_len ..], 2);
                var col = try Column(u64, Rle(u64)).init(gpa);
                defer col.deinit();
                try col.extend(gpa, data);
                const got = try col.scopeToValue(1, .{ .start = 0, .end = col.len() });
                const want: RowRange = .{ .start = prefix_len, .end = prefix_len + run_len };
                if (got.start != want.start or got.end != want.end) {
                    std.debug.print("prefix={d} run={d} suffix={d} slabs={d} got={d}..{d} want={d}..{d}\n", .{ prefix_len, run_len, suffix_len, col.slabCount(), got.start, got.end, want.start, want.end });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

// ── `prefix_*` ──────────────────────────────────────────────────────────────
//
// Upstream splits these across `PrefixColumn` (`prefix.rs`) and the
// `prefix_*` test module; both land on `Column(T, Prefix(T))` here, so they
// live beside the other column tests rather than in `prefix.zig`, which
// carries the in-place offset transform instead (`prefix.zig`, `Prefix`).

/// A prefix column of `runs` runs of `per` lengths each, values `1..=runs`.
/// Upstream's `prefix_ground_truth(&vals, max_seg)` builds the same shape
/// with a two-run budget; the port reaches several slabs through its own.
fn manySlabPrefix(gpa: std.mem.Allocator, runs: usize, per: usize) !Column(u64, Prefix(u64)) {
    var col = try Column(u64, Prefix(u64)).init(gpa);
    errdefer col.deinit();
    for (0..runs) |r| {
        for (0..per) |_| try col.append(gpa, @intCast(r + 1));
    }
    return col;
}

//  A prefix column's values, and the running sum in front of the third row
//  (`tests.rs:444-449`).
test "prefix_column_from_iterator" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 3, 1, 4, 1, 5 });
    try testing.expectEqual(@as(usize, 5), col.len());
    try testing.expectEqual(@as(i64, 8), try col.getPrefix(3));
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, &.{ 3, 1, 4, 1, 5 }, got);
}

//  A prefix cursor carries the absolute running sum, so a window opened
//  anywhere in the column reports absolute totals (`prefix.rs:708-719`;
//  `tests.rs:451-472`).
test "prefix_iter_pos_and_shift_next" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });

    var it = try col.prefixIterRange(.{ .start = 0, .end = 4 });
    try testing.expectEqual(@as(usize, 0), it.pos());

    const first = (try it.next()).?;
    try testing.expectEqual(@as(u64, 1), first.value);
    try testing.expectEqual(@as(i64, 1), first.total()); // inclusive: through item 0
    try testing.expectEqual(@as(i64, 0), first.prefix()); // exclusive: before item 0
    try testing.expectEqual(@as(usize, 1), it.pos());

    const jumped = (try it.shiftNext(.{ .start = 5, .end = 8 })).?;
    try testing.expectEqual(@as(u64, 6), jumped.value);
    try testing.expectEqual(@as(i64, 21), jumped.total());
    try testing.expectEqual(@as(i64, 15), jumped.prefix());
    try testing.expectEqual(@as(usize, 6), it.pos());

    const seventh = (try it.next()).?;
    try testing.expectEqual(@as(u64, 7), seventh.value);
    try testing.expectEqual(@as(i64, 28), seventh.total());
    const eighth = (try it.next()).?;
    try testing.expectEqual(@as(u64, 8), eighth.value);
    try testing.expectEqual(@as(i64, 36), eighth.total());

    try testing.expect((try it.next()) == null);
}

//  `nth` past the end drains the cursor, and `nth(0)` over an empty window is
//  nothing (`tests.rs:488-496`).
test "prefix_nth_past_end" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3 });
    var it = try col.prefixIter();
    try testing.expect((try it.nth(3)) == null);
    try testing.expectEqual(@as(usize, 0), it.itemsLeft());
    try testing.expect((try it.next()) == null);

    var empty = try col.prefixIterRange(.{ .start = 5, .end = 5 });
    try testing.expect((try empty.nth(0)) == null);
}

//  `nth` inside one slab: the zero case, a skip, and a jump to the last row
//  (`tests.rs:498-513`).
test "prefix_nth_fast_path_within_slab" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3, 4, 5 });
    const all = try col.toSlice(gpa);
    defer gpa.free(all);

    {
        var it = try col.prefixIter();
        try testing.expectEqual(all[0], (try it.nth(0)).?.value);
        try testing.expectEqual(all[1], (try it.next()).?.value);
    }
    {
        var it = try col.prefixIter();
        try testing.expectEqual(all[2], (try it.nth(2)).?.value);
        try testing.expectEqual(all[3], (try it.next()).?.value);
    }
    {
        var it = try col.prefixIter();
        try testing.expectEqual(all[4], (try it.nth(4)).?.value);
        try testing.expect((try it.next()) == null);
    }
}

//  `nth` after a `next` has already moved the cursor (`tests.rs:515-523`).
test "prefix_nth_fast_path_after_next" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 10, 20, 30, 40, 50 });
    const all = try col.toSlice(gpa);
    defer gpa.free(all);
    var it = try col.prefixIter();
    try testing.expectEqual(all[0], (try it.next()).?.value);
    try testing.expectEqual(all[2], (try it.nth(1)).?.value);
    try testing.expectEqual(all[3], (try it.next()).?.value);
}

//  A jump that leaves the slab reads the absolute prefix back from the
//  column's index (`prefix.rs:847-859`; `tests.rs:525-537`).
test "prefix_nth_bit_traversal" {
    const gpa = testing.allocator;
    var col = try manySlabPrefix(gpa, 150, 2);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);

    var it = try col.prefixIter();
    const mid = col.len() / 2;
    // Row `r` carries value `r / 2 + 1`: the run of two.
    try testing.expectEqual(@as(u64, @intCast(mid / 2 + 1)), (try it.nth(mid)).?.value);
    try testing.expectEqual(@as(u64, @intCast((mid + 1) / 2 + 1)), (try it.next()).?.value);

    var last_run = try col.prefixIter();
    const last = col.len() - 1;
    try testing.expectEqual(@as(u64, @intCast(last / 2 + 1)), (try last_run.nth(last)).?.value);
    try testing.expect((try last_run.next()) == null);
}

//  The same jump inside a clipped window, past its end (`tests.rs:539-546`).
test "prefix_nth_bit_out_of_bounds" {
    const gpa = testing.allocator;
    var col = try manySlabPrefix(gpa, 150, 2);
    defer col.deinit();
    var it = try col.prefixIterRange(.{ .start = 0, .end = 10 });
    try testing.expect((try it.nth(10)) == null);
    try testing.expectEqual(@as(usize, 0), it.itemsLeft());
}

//  Every row, reached by `nth` from a fresh cursor, against a plain array
//  (`tests.rs:548-556`).
test "prefix_nth_exhaustive_vs_next" {
    const gpa = testing.allocator;
    const vals = [_]u64{ 3, 0, 1, 0, 2, 0, 1, 5, 0, 0, 4, 0, 1, 2, 3 };
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &vals);
    for (vals, 0..) |want, i| {
        var it = try col.prefixIter();
        try testing.expectEqual(want, (try it.nth(i)).?.value);
    }
    var past = try col.prefixIter();
    try testing.expect((try past.nth(vals.len)) == null);
}

//  Six `shift_next` shapes (`tests.rs:558-608`).
test "prefix_shift_next_empty_range" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3 });
    var it = try col.prefixIter();
    try testing.expect((try it.shiftNext(.{ .start = 2, .end = 2 })) == null);
    try testing.expect((try it.next()) == null);
}

test "prefix_shift_next_from_start" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3, 4, 5 });
    const all = try col.toSlice(gpa);
    defer gpa.free(all);
    var it = try col.prefixIter();
    const first = (try it.shiftNext(.{ .start = 0, .end = 5 })).?;
    try testing.expectEqual(all[0], first.value);
    try testing.expectEqual(@as(usize, 4), it.itemsLeft());
}

test "prefix_shift_next_skip_forward" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3, 4, 5 });
    const all = try col.toSlice(gpa);
    defer gpa.free(all);
    var it = try col.prefixIter();
    _ = try it.next(); // pos = 1
    const shifted = (try it.shiftNext(.{ .start = 3, .end = 5 })).?;
    try testing.expectEqual(all[3], shifted.value);
    try testing.expectEqual(@as(usize, 1), it.itemsLeft());
    try testing.expectEqual(all[4], (try it.next()).?.value);
    try testing.expect((try it.next()) == null);
}

test "prefix_shift_next_consecutive" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const all = try col.toSlice(gpa);
    defer gpa.free(all);
    var it = try col.prefixIter();
    try testing.expectEqual(all[0], (try it.shiftNext(.{ .start = 0, .end = 8 })).?.value);
    try testing.expectEqual(all[3], (try it.shiftNext(.{ .start = 3, .end = 8 })).?.value);
    try testing.expectEqual(all[6], (try it.shiftNext(.{ .start = 6, .end = 8 })).?.value);
    try testing.expectEqual(all[7], (try it.next()).?.value);
    try testing.expect((try it.next()) == null);
}

test "prefix_shift_next_beyond_data" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3 });
    var it = try col.prefixIter();
    try testing.expect((try it.shiftNext(.{ .start = 3, .end = 5 })) == null);
}

//  `shift_next` and then `nth` (`tests.rs:590-607`).
//
//  Upstream's column is `PrefixColumn<bool>`, whose unit is the row's own
//  truth value (`prefix.rs:319-320`). The port's `Prefix` codec takes an
//  integer payload (`column.zig`, `Prefix` → `WireRle`), and the boolean
//  prefix column lives in `opset/columns.zig` as `BoolPrefixColumn`, which
//  is not this module's to reach — so the sequence is ported over the
//  integer form and the boolean form is left to that module.
test "prefix_shift_next_then_nth" {
    const gpa = testing.allocator;
    const vals = [_]u64{ 1, 0, 1, 0, 1, 0 };
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &vals);
    {
        var it = try col.prefixIter();
        try testing.expectEqual(vals[0], (try it.shiftNext(.{ .start = 0, .end = 6 })).?.value);
        try testing.expectEqual(vals[1], (try it.nth(0)).?.value);
    }
    {
        var it = try col.prefixIter();
        _ = try it.next();
        try testing.expectEqual(vals[2], (try it.shiftNext(.{ .start = 2, .end = 6 })).?.value);
        try testing.expectEqual(vals[3], (try it.nth(0)).?.value);
    }
    {
        var it = try col.prefixIter();
        try testing.expectEqual(vals[0], (try it.shiftNext(.{ .start = 0, .end = 6 })).?.value);
        try testing.expectEqual(vals[2], (try it.nth(1)).?.value);
    }
}

//  A `shift_next` into the middle of a later slab, then the rest of the walk
//  (`tests.rs:609-621`).
test "prefix_shift_next_multi_slab" {
    const gpa = testing.allocator;
    var col = try manySlabPrefix(gpa, 150, 2);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);
    const mid = 100;
    var it = try col.prefixIter();
    const shifted = (try it.shiftNext(.{ .start = mid, .end = col.len() })).?;
    try testing.expectEqual(@as(u64, @intCast(mid / 2 + 1)), shifted.value);
    var i: usize = mid + 1;
    while (try it.next()) |pv| : (i += 1) {
        try testing.expectEqual(@as(u64, @intCast(i / 2 + 1)), pv.value);
    }
    try testing.expectEqual(col.len(), i);
}

//  `prefix_iter_proptest` (`tests.rs:623-651`) as a seeded sweep: the values
//  match the source, the totals are a running sum, **a window carries the
//  absolute prefix**, and `nth` matches direct indexing.
//
//  **Part three failed here until 2026-10-01, and the comment saying so was
//  itself the last defect.** Upstream's `iter_range` is `iter()` plus
//  `advance_by(start)`, which accumulates the skipped widths into `total`
//  (`prefix.rs:669-676`, `:903-907`), so a window opened at `s` reports
//  absolute totals. This port's `prefixIterRange` used to set `base` to the
//  absolute prefix at `s` and leave `sum` at zero, so it reported sums
//  **relative to the window**, and the op set compensated at its two call
//  sites — it took `seq_base` from `getPrefix` and read the cursor's sums as
//  object-relative. `prefixIterRange` is upstream's shape now
//  ([`column.zig`](column.zig)) and the compensation is upstream's own
//  subtraction (`op_set2/op_set.rs:976`, `:995`).
//
//  **The record of that was where it did the most damage.** It lived in this
//  comment, three layers below the function and one file away from the op
//  set that depended on it, so `prefixIterRange`'s name said nothing about
//  relativity and the deviation read as current behaviour: a reader sent to
//  fix a mark regression "compensated" the op set *again* and broke 23
//  further tests. A deviation that is going to be relied on is recorded at
//  the code that carries it, and this one now says so in both places.
test "prefix_iter_proptest" {
    const gpa = testing.allocator;
    var seed: u64 = 0x9E1F_0C10;
    var case: usize = 0;
    while (case < 40) : (case += 1) {
        const n = 1 + xorshift(&seed) % 200;
        const values = try gpa.alloc(u64, n);
        defer gpa.free(values);
        for (values) |*v| v.* = xorshift(&seed) % 100;
        var col = try Column(u64, Prefix(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, values);

        const inner = try col.toSlice(gpa);
        defer gpa.free(inner);
        try testing.expectEqualSlices(u64, values, inner);

        {
            var it = try col.prefixIter();
            var running: i64 = 0;
            for (values) |v| {
                const pv = (try it.next()).?;
                try testing.expectEqual(running, pv.prefix());
                running += @intCast(v);
                try testing.expectEqual(running, pv.total());
            }
        }
        for ([_]usize{ 0, n / 4, n / 2, 3 * n / 4 }) |s| {
            const e = @min(s + n / 4, n);
            var base: i64 = 0;
            for (values[0..s]) |v| base += @intCast(v);
            var it = try col.prefixIterRange(.{ .start = s, .end = e });
            var running = base;
            for (values[s..e]) |v| {
                running += @intCast(v);
                const pv = (try it.next()).?;
                if (pv.total() != running) {
                    std.debug.print(
                        "prefix window {d}..{d}: upstream total {d}, this port {d} (base {d})\n",
                        .{ s, e, running, pv.total(), base },
                    );
                    return error.TestUnexpectedResult;
                }
            }
            try testing.expect((try it.next()) == null);
        }
        for ([_]usize{ 0, 1, n / 2, n - 1 }) |skip| {
            if (skip >= n) continue;
            var it = try col.prefixIter();
            const pv = (try it.nth(skip)).?;
            try testing.expectEqual(values[skip], pv.value);
            var want: i64 = 0;
            for (values[0 .. skip + 1]) |v| want += @intCast(v);
            try testing.expectEqual(want, pv.total());
        }
    }
}

//  Empty bytes plus a length and a fill (`tests.rs:5474-5479`).
//
//  As above, the port's `Prefix` codec is the integer form; upstream's case is
//  `PrefixColumn<bool>`.
test "prefix_column_load_with_empty_and_fill" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).loadWith(
        gpa,
        &.{},
        Column(u64, Prefix(u64)).LoadOpts.new().withLength(4).withFill(0),
    );
    defer col.deinit();
    try testing.expectEqual(@as(usize, 4), col.len());
    try testing.expect(try col.isOnly(0));
}

//  Save, load with the length it names, and save again (`tests.rs:5481-5486`).
test "prefix_column_load_with_roundtrip" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 0, 1 });
    const data = try col.encode(gpa);
    defer gpa.free(data);
    var loaded = try Column(u64, Prefix(u64)).loadWith(
        gpa,
        data,
        Column(u64, Prefix(u64)).LoadOpts.new().withLength(3),
    );
    defer loaded.deinit();
    const again = try loaded.encode(gpa);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, data, again);
}

test "prefix_column_load_with_length_mismatch" {
    const gpa = testing.allocator;
    var col = try Column(u64, Prefix(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 0 });
    const data = try col.encode(gpa);
    defer gpa.free(data);
    try testing.expectError(
        error.InvalidValue,
        Column(u64, Prefix(u64)).loadWith(
            gpa,
            data,
            Column(u64, Prefix(u64)).LoadOpts.new().withLength(10),
        ),
    );
}

//  The canonicality check is at the wire level, so an accumulating column
//  refuses the same bytes a plain one does (`tests.rs:5490-5495`).
test "prefix_load_rejects_non_canonical_input" {
    const gpa = testing.allocator;
    const bytes: []const u8 = &([_]u8{ 0x02, 0x05 } ** 200);
    try testing.expectError(error.InvalidValue, Column(u64, Prefix(u64)).load(gpa, bytes));
    try testing.expectError(error.InvalidValue, Rle(u64).canonicalSlab(bytes));
}

// ── The cases `tests.rs` files outside its own name-prefixes ────────────────

//  Three builds and two reads (`tests.rs:109`, `:115`, `:121`, `:134`, `:141`).
test "build_sequential_values" {
    const gpa = testing.allocator;
    const vals = [_]u64{ 1, 2, 3, 4, 5 };
    var col = try v1Build(gpa, &vals);
    defer col.deinit();
    try assertCol(u64, Rle(u64), &col, &vals);
}

test "build_with_repeats" {
    const gpa = testing.allocator;
    const vals = [_]u64{ 1, 2, 3, 3, 3, 4, 5 };
    var col = try v1Build(gpa, &vals);
    defer col.deinit();
    try assertCol(u64, Rle(u64), &col, &vals);
}

test "build_all_same" {
    const gpa = testing.allocator;
    const vals = [_]u64{7} ** 10;
    var col = try v1Build(gpa, &vals);
    defer col.deinit();
    try assertCol(u64, Rle(u64), &col, &vals);
}

test "get_in_bounds" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 10, 20, 30 });
    defer col.deinit();
    try testing.expectEqual(@as(?u64, 10), try col.get(0));
    try testing.expectEqual(@as(?u64, 20), try col.get(1));
    try testing.expectEqual(@as(?u64, 30), try col.get(2));
}

test "get_out_of_bounds" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 10, 20 });
    defer col.deinit();
    try testing.expect((try col.get(2)) == null);
    try testing.expect((try col.get(100)) == null);
}

//  A remove at each of the three positions (`tests.rs:148`, `:154`, `:160`).
test "remove_first" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2, 3 });
    defer col.deinit();
    try removeAt(Column(u64, Rle(u64)), gpa, &col, 0);
    try assertCol(u64, Rle(u64), &col, &.{ 2, 3 });
}

test "remove_last" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2, 3 });
    defer col.deinit();
    try removeAt(Column(u64, Rle(u64)), gpa, &col, 2);
    try assertCol(u64, Rle(u64), &col, &.{ 1, 2 });
}

test "remove_middle" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2, 3 });
    defer col.deinit();
    try removeAt(Column(u64, Rle(u64)), gpa, &col, 1);
    try assertCol(u64, Rle(u64), &col, &.{ 1, 3 });
}

//  A nullable and a boolean column, each inserted one row at a time
//  (`tests.rs:166`, `:173`, `:180`, `:187`). Upstream's fourth case is a
//  string column; the port has no byte-string codec.
test "nullable_basic" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    try insertAt(Column(?u64, RleOption(u64)), gpa, &col, 0, 1);
    try insertAt(Column(?u64, RleOption(u64)), gpa, &col, 1, null);
    try insertAt(Column(?u64, RleOption(u64)), gpa, &col, 2, 2);
    try assertCol(?u64, RleOption(u64), &col, &.{ 1, null, 2 });
}

test "nullable_all_null" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    for (0..5) |i| try insertAt(Column(?u64, RleOption(u64)), gpa, &col, i, null);
    try assertCol(?u64, RleOption(u64), &col, &([_]?u64{null} ** 5));
}

test "bool_basic" {
    const gpa = testing.allocator;
    var col = try Column(bool, Bool).init(gpa);
    defer col.deinit();
    try insertAt(Column(bool, Bool), gpa, &col, 0, true);
    try insertAt(Column(bool, Bool), gpa, &col, 1, false);
    try insertAt(Column(bool, Bool), gpa, &col, 2, true);
    try assertCol(bool, Bool, &col, &.{ true, false, true });
}

test "bool_all_same" {
    const gpa = testing.allocator;
    var col = try Column(bool, Bool).init(gpa);
    defer col.deinit();
    for (0..10) |i| try insertAt(Column(bool, Bool), gpa, &col, i, true);
    try assertCol(bool, Bool, &col, &([_]bool{true} ** 10));
}

//  A column long enough to split into several slabs (`tests.rs:194`;
//  `Column::with_max_segments(4)` with twenty distinct rows). Twenty
//  *distinct* rows are one literal run here — the port counts a literal run
//  as one segment (`slab.zig:111-114`, `pinned_run_count`) — so the same shape is
//  reached with seventy runs of two, which is over the 64-run budget.
test "slab_splitting" {
    const gpa = testing.allocator;
    var col = try manySlabColumn(gpa, 70, 2);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);
    const vals = try gpa.alloc(u64, 140);
    defer gpa.free(vals);
    for (vals, 0..) |*v, i| v.* = @intCast(i / 2);
    try assertCol(u64, Rle(u64), &col, vals);
}

//  Twenty rows in, fifteen removed from the front (`tests.rs:202`). The
//  removes are what the merge policy runs on, so the layout is checked after
//  every one of them.
test "slab_merging_after_removes" {
    const gpa = testing.allocator;
    var col = try manySlabColumn(gpa, 5, 4);
    defer col.deinit();
    var model: std.ArrayList(u64) = .empty;
    defer model.deinit(gpa);
    for (0..5) |r| for (0..4) |_| try model.append(gpa, @intCast(r));
    var k: usize = 0;
    while (k < 15) : (k += 1) {
        try removeAt(Column(u64, Rle(u64)), gpa, &col, 0);
        _ = model.orderedRemove(0);
        try expectModel(u64, Rle(u64), &col, model.items);
    }
    try assertCol(u64, Rle(u64), &col, model.items);
}

//  Five columns built from an iterator (`tests.rs:213`-`:233`).
test "column_from_iterator" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 10, 20, 30, 40, 50 });
    defer col.deinit();
    try testing.expectEqual(@as(usize, 5), col.len());
    for ([_]u64{ 10, 20, 30, 40, 50 }, 0..) |v, i| try testing.expectEqual(v, try col.get(i));
}

test "column_bool_from_iterator" {
    const gpa = testing.allocator;
    var col = try v1BuildBool(gpa, &.{ true, false, true, true });
    defer col.deinit();
    try testing.expectEqual(@as(usize, 4), col.len());
    try testing.expectEqual(true, try col.get(0));
    try testing.expectEqual(false, try col.get(1));
}

test "column_nullable_from_iterator" {
    const gpa = testing.allocator;
    var col = try v1BuildOpt(gpa, &.{ 1, null, 3 });
    defer col.deinit();
    try testing.expectEqual(@as(usize, 3), col.len());
    try testing.expectEqual(@as(?u64, 1), try col.get(0));
    try testing.expectEqual(@as(?u64, null), try col.get(1));
    try testing.expectEqual(@as(?u64, 3), try col.get(2));
}

test "delta_column_from_iterator" {
    const gpa = testing.allocator;
    var col = try Column(u64, Delta(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 10, 20, 30, 40 });
    try testing.expectEqual(@as(usize, 4), col.len());
    try testing.expectEqual(@as(?u64, 10), try col.get(0));
    try testing.expectEqual(@as(?u64, 40), try col.get(3));
}

test "column_from_empty_iterator" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expect(col.isEmpty());
}

//  `scan_to_value` is "scan to the next row carrying the value", and each
//  call takes the next one (`column.rs:625-640`; `tests.rs:2461-2481`).
//  Upstream's third block is a `Column<Option<String>>`; the port has no
//  byte-string codec.
test "scan_to_value_on_rle_columns" {
    const gpa = testing.allocator;
    const vals = [_]bool{ false, false, false, false, true, true, true, false, false, true };
    var col = try v1BuildBool(gpa, &vals);
    defer col.deinit();

    var it = try col.iterator();
    try testing.expectEqual(@as(?usize, 4), try it.scanToValue(true));
    try testing.expectEqual(@as(?usize, 5), try it.scanToValue(true));
    try testing.expectEqual(@as(?usize, 6), try it.scanToValue(true));
    try testing.expectEqual(@as(?usize, 9), try it.scanToValue(true));
    try testing.expect((try it.scanToValue(true)) == null);
    try testing.expect((try it.next()) == null);

    // `shift` positions the cursor: upstream is `set_max(range.end)` then
    // `advance_to(range.start)` (`column.rs:542-545`, `shift.rs:51-54`), so a
    // scan from a fresh cursor over `5..9` starts at row 5 and finds the
    // first `false` at row 7. The window moves *and* the position does:
    // this is upstream's `Iter::shift` and not a truncation that leaves
    // the cursor where it stood.
    var windowed = try col.iterator();
    try windowed.shift(.{ .start = 5, .end = 9 });
    try testing.expectEqual(@as(usize, 5), windowed.pos());
    try testing.expectEqual(@as(usize, 9), windowed.maxPos());
    try testing.expectEqual(@as(?usize, 7), try windowed.scanToValue(false));

    // A nullable column: the absent value is a value like any other.
    var opt = try v1BuildOpt(gpa, &.{ 1, 1, null, 2 });
    defer opt.deinit();
    var oi = try opt.iterator();
    try testing.expectEqual(@as(?usize, 2), try oi.scanToValue(null));
    var oj = try opt.iterator();
    try testing.expectEqual(@as(?usize, 3), try oj.scanToValue(2));
}

//  `seek_to` over the three column kinds (`tests.rs:2482-2494`).
test "scan_to_consumes_through" {
    const gpa = testing.allocator;
    {
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, &([_]u64{0} ** 100));
        for (0..100) |i| try col.set(gpa, i, @intCast(i));
        var it = try col.iterator();
        try testing.expectEqual(@as(?u64, 10), try it.seekTo(10));
        try testing.expectEqual(@as(?u64, 11), try it.next());
        try testing.expectEqual(@as(?u64, 50), try it.seekTo(50));
    }
    {
        var col = try Column(u64, Delta(u64)).init(gpa);
        defer col.deinit();
        for (0..100) |i| try col.append(gpa, @intCast(i));
        var it = try col.iterator();
        try testing.expectEqual(@as(?u64, 7), try it.seekTo(7));
        try testing.expectEqual(@as(?u64, 8), try it.next());
    }
    {
        var col = try Column(u64, Prefix(u64)).init(gpa);
        defer col.deinit();
        for (0..100) |i| try col.append(gpa, @intCast(i));
        var it = try col.prefixIter();
        try testing.expectEqual(@as(u64, 5), (try it.seekTo(5)).?.value);
    }
}

//  Five `shift_next` cases (`tests.rs:2468`-`:2468`, `:2536`, `:2551`).
test "shift_next_matches_v0" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 0, 0, 0, 1, 1, 1, 6, 6, 6, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10 });
    defer col.deinit();
    var it = try col.iterRange(.{ .start = 1, .end = 4 });
    try testing.expectEqual(@as(?u64, 0), try it.next());
    try testing.expectEqual(@as(?u64, 0), try it.next());
    try testing.expectEqual(@as(?u64, 1), try it.next());
    try testing.expect((try it.next()) == null);

    try testing.expectEqual(@as(?u64, 1), try it.shiftNext(.{ .start = 5, .end = 7 }));
    try testing.expectEqual(@as(?u64, 6), try it.next());
    try testing.expect((try it.next()) == null);

    try testing.expectEqual(@as(?u64, 6), try it.shiftNext(.{ .start = 8, .end = 10 }));
    try testing.expectEqual(@as(?u64, 7), try it.next());
    try testing.expect((try it.next()) == null);
}

test "shift_next_bool_column" {
    const gpa = testing.allocator;
    var col = try v1BuildBool(gpa, &.{ true, false, true, true, false, false, true, false, true, true });
    defer col.deinit();
    var it = try col.iterRange(.{ .start = 0, .end = 3 });
    try testing.expectEqual(true, try it.next());
    try testing.expectEqual(@as(usize, 1), it.pos());
    try testing.expectEqual(false, try it.shiftNext(.{ .start = 4, .end = 7 }));
    try testing.expectEqual(@as(usize, 5), it.pos());
    try testing.expectEqual(false, try it.next());
    try testing.expectEqual(true, try it.next());
    try testing.expect((try it.next()) == null);
}

test "shift_next_nullable_column" {
    const gpa = testing.allocator;
    var col = try v1BuildOpt(gpa, &.{ 1, null, 3, null, 5, null, 7 });
    defer col.deinit();
    var it = try col.iterRange(.{ .start = 0, .end = 2 });
    try testing.expectEqual(@as(?u64, 1), try it.next());
    try testing.expectEqual(@as(?u64, null), try it.next());
    try testing.expect((try it.next()) == null);
    try testing.expectEqual(@as(?u64, null), try it.shiftNext(.{ .start = 3, .end = 5 }));
    try testing.expectEqual(@as(?u64, 5), try it.next());
    try testing.expect((try it.next()) == null);
}

test "shift_next_at_current_pos" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 10, 20, 30, 40, 50 });
    defer col.deinit();
    var it = try col.iterRange(.{ .start = 0, .end = 2 });
    try testing.expectEqual(@as(?u64, 10), try it.next());
    try testing.expectEqual(@as(?u64, 20), try it.next());
    try testing.expect((try it.next()) == null);
    try testing.expectEqual(@as(?u64, 30), try it.shiftNext(.{ .start = 2, .end = 5 }));
    try testing.expectEqual(@as(usize, 3), it.pos());
}

test "shift_next_reference_model" {
    const gpa = testing.allocator;
    const data = try gpa.alloc(u64, 50);
    defer gpa.free(data);
    for (data, 0..) |*v, i| v.* = @intCast(i / 3);
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, data);

    var it = try col.iterRange(.{ .start = 0, .end = 10 });
    for (data[0..5]) |want| try testing.expectEqual(want, try it.next());
    try testing.expectEqual(@as(usize, 5), it.pos());
    try testing.expectEqual(data[15], try it.shiftNext(.{ .start = 15, .end = 20 }));
    try testing.expectEqual(@as(usize, 16), it.pos());
    const rest = try col.sliceRange(gpa, .{ .start = it.pos(), .end = 20 });
    defer gpa.free(rest);
    try testing.expectEqualSlices(u64, data[16..20], rest);
}

//  `Column::fill` (`column.rs:1227-1245`), for the three types the port has:
//  a nullable column and a boolean one, at a length and at zero
//  (`tests.rs:2509`-`:2530`).
test "fill_creates_all_null_column" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).fill(gpa, 100, null);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 100), col.len());
    for (0..100) |i| try testing.expectEqual(@as(?u64, null), try col.get(i));
}

test "fill_zero_length" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).fill(gpa, 0, null);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expect(col.isEmpty());
}

test "fill_creates_all_false_column" {
    const gpa = testing.allocator;
    var col = try Column(bool, Bool).fill(gpa, 100, false);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 100), col.len());
    for (0..100) |i| try testing.expectEqual(false, try col.get(i));
}

test "fill_bool_zero_length" {
    const gpa = testing.allocator;
    var col = try Column(bool, Bool).fill(gpa, 0, false);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expect(col.isEmpty());
}

test "fill_null_roundtrips_through_save_load" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).fill(gpa, 1000, null);
    defer col.deinit();
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(?u64, RleOption(u64)).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1000), loaded.len());
}

test "fill_bool_roundtrips_through_save_load" {
    const gpa = testing.allocator;
    var col = try Column(bool, Bool).fill(gpa, 1000, false);
    defer col.deinit();
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    var loaded = try Column(bool, Bool).load(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1000), loaded.len());
}

//  The nine merge-rule cases: a delete that leaves two literals meeting, a
//  repeat of two shrinking into a literal, a null run split by an insert, and
//  the adjacencies that must coalesce (`tests.rs:4097`-`:4261`).
test "delete_null_merges_adjacent_literals" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);
    for ([_]struct { v: ?u64, at: usize }{
        .{ .v = 2, .at = 0 },
        .{ .v = null, .at = 1 },
        .{ .v = 1, .at = 2 },
        .{ .v = 3, .at = 3 },
    }) |one| {
        try col.splice(gpa, one.at, 0, &.{one.v});
        try mirror.insert(gpa, one.at, one.v);
    }
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
    try removeAt(Column(?u64, RleOption(u64)), gpa, &col, 1);
    _ = mirror.orderedRemove(1);
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(?u64, &.{ 2, 1, 3 }, got);
}

test "delete_repeat2_merges_into_literal" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);
    for ([_]struct { v: ?u64, at: usize }{
        .{ .v = 2, .at = 0 },
        .{ .v = 5, .at = 1 },
        .{ .v = 1, .at = 2 },
        .{ .v = 3, .at = 3 },
    }) |one| {
        try col.splice(gpa, one.at, 0, &.{one.v});
        try mirror.insert(gpa, one.at, one.v);
    }
    try col.splice(gpa, 2, 0, &.{5});
    try mirror.insert(gpa, 2, 5);
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
    try removeAt(Column(?u64, RleOption(u64)), gpa, &col, 2);
    _ = mirror.orderedRemove(2);
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
}

test "null_split_no_merge" {
    try buildAndCheck(&.{
        .{ .v = 1, .at = 0 },
        .{ .v = 1, .at = 0 },
        .{ .v = 2, .at = 0 },
        .{ .v = null, .at = 2 },
        .{ .v = null, .at = 0 },
    });
}

test "adjacent_null_various" {
    const gpa = testing.allocator;
    try buildAndCheck(&.{
        .{ .v = 3, .at = 0 },
        .{ .v = 2, .at = 1 },
        .{ .v = null, .at = 2 },
        .{ .v = null, .at = 3 },
    });
    try buildAndCheck(&.{
        .{ .v = null, .at = 0 },
        .{ .v = 1, .at = 0 },
        .{ .v = null, .at = 0 },
    });
    {
        var col = try Column(?u64, RleOption(u64)).init(gpa);
        defer col.deinit();
        var mirror: std.ArrayList(?u64) = .empty;
        defer mirror.deinit(gpa);
        for ([_]struct { v: ?u64, at: usize }{
            .{ .v = null, .at = 0 },
            .{ .v = 1, .at = 1 },
            .{ .v = null, .at = 2 },
        }) |one| {
            try col.splice(gpa, one.at, 0, &.{one.v});
            try mirror.insert(gpa, one.at, one.v);
        }
        try removeAt(Column(?u64, RleOption(u64)), gpa, &col, 1);
        _ = mirror.orderedRemove(1);
        try assertCol(?u64, RleOption(u64), &col, mirror.items);
        const got = try col.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(?u64, &.{ null, null }, got);
    }
}

//  Sixteen inserts and two deletes at scattered positions, checked against a
//  mirror after every step (`tests.rs:4151-4168`; `apply_ops`, `:171-186`).
test "adjacent_repeats" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);

    const ops = [_]struct { del: bool, v: ?u64, at: usize }{
        .{ .del = false, .v = null, .at = 0 },
        .{ .del = false, .v = null, .at = 0 },
        .{ .del = false, .v = 1, .at = 669 },
        .{ .del = false, .v = 1, .at = 144 },
        .{ .del = false, .v = null, .at = 931 },
        .{ .del = false, .v = null, .at = 129 },
        .{ .del = true, .v = null, .at = 577 },
        .{ .del = false, .v = null, .at = 498 },
        .{ .del = false, .v = null, .at = 171 },
        .{ .del = false, .v = 1, .at = 337 },
        .{ .del = false, .v = null, .at = 369 },
        .{ .del = false, .v = null, .at = 204 },
        .{ .del = false, .v = null, .at = 270 },
        .{ .del = false, .v = null, .at = 276 },
        .{ .del = false, .v = null, .at = 72 },
        .{ .del = true, .v = null, .at = 265 },
    };
    // `apply_ops` folds each position into the mirror's length
    // (`tests.rs:295-315`), which is what lets the upstream case scatter
    // positions far past the end of a two-row column.
    const positions = [_]usize{ 0, 0, 669, 144, 931, 129, 577, 498, 171, 337, 369, 204, 270, 276, 72, 265 };
    for (ops, 0..) |one, k| {
        const raw = positions[k];
        if (one.del) {
            if (mirror.items.len == 0) continue;
            const idx = raw % mirror.items.len;
            try removeAt(Column(?u64, RleOption(u64)), gpa, &col, idx);
            _ = mirror.orderedRemove(idx);
        } else {
            const idx = if (mirror.items.len == 0) 0 else raw % (mirror.items.len + 1);
            try col.splice(gpa, idx, 0, &.{one.v});
            try mirror.insert(gpa, idx, one.v);
        }
        try expectModel(?u64, RleOption(u64), &col, mirror.items);
    }
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
}

test "lit_with_triple_dup" {
    try buildAndCheck(&.{
        .{ .v = 2, .at = 0 },
        .{ .v = 1, .at = 1 },
        .{ .v = 1, .at = 2 },
        .{ .v = 1, .at = 3 },
        .{ .v = null, .at = 4 },
        .{ .v = 2, .at = 5 },
    });
}

test "lit1_adjacent_repeat_same_value" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);
    for (0..3) |_| {
        try col.splice(gpa, 0, 0, &.{null});
        try mirror.insert(gpa, 0, null);
    }
    try removeAt(Column(?u64, RleOption(u64)), gpa, &col, 0);
    _ = mirror.orderedRemove(0);
    for ([_]?u64{ null, null, null, null, 2, null, null }) |v| {
        try col.splice(gpa, 0, 0, &.{v});
        try mirror.insert(gpa, 0, v);
    }
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
}

test "null_coalesce" {
    try buildAndCheck(&.{
        .{ .v = null, .at = 0 },
        .{ .v = 1, .at = 0 },
        .{ .v = null, .at = 2 },
    });
}

test "null_split" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);
    for (0..3) |i| {
        try col.splice(gpa, i, 0, &.{null});
        try mirror.insert(gpa, i, null);
    }
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
    try col.splice(gpa, 1, 0, &.{1});
    try mirror.insert(gpa, 1, 1);
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(?u64, &.{ null, 1, null, null }, got);
}

test "adjacent_null_from_value_insert" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);
    for ([_]struct { v: ?u64, at: usize }{
        .{ .v = null, .at = 0 },
        .{ .v = null, .at = 0 },
        .{ .v = 1, .at = 0 },
        .{ .v = null, .at = 3 },
    }) |one| {
        try col.splice(gpa, one.at, 0, &.{one.v});
        try mirror.insert(gpa, one.at, one.v);
    }
    try assertCol(?u64, RleOption(u64), &col, mirror.items);
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(?u64, &.{ 1, null, null, null }, got);
}

//  Nine interleaved inserts and deletes, checked after every step
//  (`tests.rs:4221-4240`).
test "adjacent_lits_after_null_delete" {
    const gpa = testing.allocator;
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);
    const ops = [_]struct { del: bool, v: ?u64, at: usize }{
        .{ .del = false, .v = 3, .at = 0 },
        .{ .del = false, .v = 3, .at = 0 },
        .{ .del = false, .v = 2, .at = 1 },
        .{ .del = true, .v = null, .at = 2 },
        .{ .del = false, .v = 2, .at = 1 },
        .{ .del = false, .v = 2, .at = 2 },
        .{ .del = false, .v = null, .at = 2 },
        .{ .del = false, .v = 1, .at = 1 },
        .{ .del = true, .v = null, .at = 3 },
    };
    for (ops) |one| {
        if (one.del) {
            try removeAt(Column(?u64, RleOption(u64)), gpa, &col, one.at);
            _ = mirror.orderedRemove(one.at);
        } else {
            try col.splice(gpa, one.at, 0, &.{one.v});
            try mirror.insert(gpa, one.at, one.v);
        }
        try expectModel(?u64, RleOption(u64), &col, mirror.items);
    }
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(?u64, &.{ 3, 1, 2, 2, 2 }, got);
}

// ── Cross-slab merge cases (`tests.rs:3136-3189`) ───────────────────────────
//
// Upstream's section header is "Edge case: `try_merge_range` with multiple
// small slabs", and all three cases reach the same code the port's own
// multi-slab tests do — `Column::try_merge_range` over a rebuilt range that
// spans more than one slab (`column.rs:185-229`). What makes them distinct
// from `a column of many slabs keeps its index, its budget and its values`
// is the **direction**: that test splices one or two rows at a time, so
// almost every rebuild stays inside one slab and the merge walk has two
// short neighbours to consider. These three cut *across* slab boundaries, so
// the rebuilt range covers several slabs at once and every boundary inside
// it is walked (`column.rs:200-227`).
//
// Upstream tunes `max_segments` to 2 or 4 to make that happen cheaply, and
// the port has the same knob: `Column.initWithBudget` is upstream's
// `with_max_segments` (`column.rs:1121-1135`), with `fromValues` and
// `LoadOpts.withMaxSegments` beside it. The fixture therefore asks for a
// budget of **8 runs a slab** over 200 runs of two, which is dozens of small
// slabs, and a range of forty rows covers several of them.
//
// **The run budget counts segments, and a literal run is one segment
// whatever values it holds** (`slab.zig:111-114`, `pinned_run_count`). So a
// fixture of two hundred *distinct* values is one segment and one slab: it
// would splice across no boundary at all and prove nothing. A repeated value
// is what makes a run, and runs are what the budget counts — hence runs of
// two, which is the smallest shape that reaches several slabs.
//
// **Whether the rebuilt range really crossed a boundary is asked of the rows,
// not of the column's slab count.** `spansMoreThanOneSlab` locates the first
// and last row of the range and compares the slabs they land in, which is
// what a cross-slab case has to reach to be one. Nothing here asserts how many
// slabs the splice *left* behind: that number is a property of the merge
// policy's freedom, not a promise, and pinning it would make the case fail on
// a layout change that broke nothing. The layout the column must keep is
// checked by `validateRleColumn` — no slab over its budget, the index and the
// weights in step, and no two adjacent slabs the policy would have merged.

/// The values the cross-slab merge cases start from: `runs` runs of two, the
/// tags running 0, 1, 2, ….
fn manyRunValues(gpa: std.mem.Allocator, runs: usize) ![]u64 {
    const values = try gpa.alloc(u64, runs * 2);
    errdefer gpa.free(values);
    for (values, 0..) |*v, i| v.* = @intCast(i / 2);
    return values;
}

/// Those values as a column on a run budget of eight, which is what makes it
/// "many small slabs" — see the section header.
///
/// Built through the splice path, not the streaming encoder's, because the
/// merge policy belongs to the splice path (`column.rs:1782-1797`) and an
/// encoder-built column is under no obligation to satisfy it: its last slab
/// is whatever was left over. A column built here is held to the policy by
/// `validateRleColumn`, before the splice as well as after, so a failure in
/// either is a failure of this fixture's premise rather than of the case.
fn manyRunColumn(gpa: std.mem.Allocator, values: []const u64) !Column(u64, Rle(u64)) {
    var col = try Column(u64, Rle(u64)).initWithBudget(gpa, 8);
    errdefer col.deinit();
    try col.extend(gpa, values);
    return col;
}

/// Whether a rebuild that ran from row `start` for `del` rows really covered
/// more than one slab. `locate` is the same lookup the edit cursor opens with
/// (`column.rs:328`, `:340-342`), so this asks the question about the rows
/// themselves rather than about the layout afterwards.
fn spansMoreThanOneSlab(
    comptime T: type,
    comptime E: type,
    col: *const Column(T, E),
    start: usize,
    del: usize,
) bool {
    if (del == 0) return false;
    return col.locate(start).slab != col.locate(start + del - 1).slab;
}

//  A twenty-row insert into the middle of a 200-run column. The insert
//  overflows the run budget of the slab it lands in, so the rebuild spills
//  and the merge walk has to settle the spilled range from both ends
//  (`tests.rs:3138-3155`, `column.rs:1866-1870`).
//
//  **The inserted rows are ten runs of two, not twenty distinct values**,
//  for the reason the section header gives: twenty distinct values are one
//  literal segment in this codec, so they could not cross a boundary however
//  the column was cut.
test "try_merge_range_multiple_merges" {
    const gpa = testing.allocator;
    const values = try manyRunValues(gpa, 200);
    defer gpa.free(values);
    var col = try manyRunColumn(gpa, values);
    defer col.deinit();
    try validateRleColumn(Rle(u64), &col);

    const inserted = try gpa.alloc(u64, 20);
    defer gpa.free(inserted);
    for (inserted, 0..) |*v, i| v.* = 1000 + @as(u64, @intCast(i / 2));

    var model: std.ArrayList(u64) = .empty;
    defer model.deinit(gpa);
    try model.appendSlice(gpa, values);

    // What an insert rebuilds is the postfix from the insert on, so that is
    // the range the merge walk has to cover more than one slab of.
    if (!spansMoreThanOneSlab(u64, Rle(u64), &col, 100, values.len - 100)) {
        std.debug.print("rows 100..{d} sit in one of {d} slabs\n", .{ values.len, col.slabCount() });
        return error.TestUnexpectedResult;
    }
    try col.splice(gpa, 100, 0, inserted);
    try model.insertSlice(gpa, 100, inserted);

    try validateRleColumn(Rle(u64), &col);
    try expectModel(u64, Rle(u64), &col, model.items);
    try expectRoundTrip(u64, Rle(u64), &col, model.items);
    // Ten runs cannot fit inside one slab's budget of eight, so the rows the
    // insert added are spread over slabs — and the column still holds every
    // one of them, in order, which is what a rebuild that dropped the spill
    // would have lost.
    try testing.expect(spansMoreThanOneSlab(u64, Rle(u64), &col, 100, inserted.len));
}

//  A delete of forty rows across boundaries, which is upstream's "delete
//  across multiple slab boundaries, triggering cross-slab delete + merge"
//  (`tests.rs:3158-3171`).
test "try_merge_range_delete_across_slabs" {
    const gpa = testing.allocator;
    const values = try manyRunValues(gpa, 200);
    defer gpa.free(values);
    var col = try manyRunColumn(gpa, values);
    defer col.deinit();
    try validateRleColumn(Rle(u64), &col);

    var model: std.ArrayList(u64) = .empty;
    defer model.deinit(gpa);
    try model.appendSlice(gpa, values);
    if (!spansMoreThanOneSlab(u64, Rle(u64), &col, 30, 40)) {
        std.debug.print("rows 30..70 sit in one of {d} slabs\n", .{col.slabCount()});
        return error.TestUnexpectedResult;
    }

    try col.splice(gpa, 30, 40, &.{});
    try model.replaceRange(gpa, 30, 40, &.{});

    try validateRleColumn(Rle(u64), &col);
    try expectModel(u64, Rle(u64), &col, model.items);
    try expectRoundTrip(u64, Rle(u64), &col, model.items);
    // The seam the delete left behind: the run in front of the cut and the
    // one behind it are both still whole, so a rebuild that settled the
    // rebuilt range across the boundaries it covered cannot have dropped,
    // duplicated or reordered a row of either.
    try testing.expectEqual(@as(u64, 14), model.items[29]);
    try testing.expectEqual(@as(u64, 35), model.items[30]);
    try testing.expectEqual(@as(usize, 360), model.items.len);
}

//  Twenty-five rows out and fifteen in, across a boundary: the rebuilt range
//  spans slabs *and* the values on either side of each internal boundary
//  change, so the walk cannot assume the seam it is closing (`tests.rs:3174-
//  3188`).
test "try_merge_range_replace_across_slabs" {
    const gpa = testing.allocator;
    const values = try manyRunValues(gpa, 200);
    defer gpa.free(values);
    var col = try manyRunColumn(gpa, values);
    defer col.deinit();
    try validateRleColumn(Rle(u64), &col);

    var model: std.ArrayList(u64) = .empty;
    defer model.deinit(gpa);
    try model.appendSlice(gpa, values);
    if (!spansMoreThanOneSlab(u64, Rle(u64), &col, 40, 25)) {
        std.debug.print("rows 40..65 sit in one of {d} slabs\n", .{col.slabCount()});
        return error.TestUnexpectedResult;
    }

    const inserted = try gpa.alloc(u64, 15);
    defer gpa.free(inserted);
    for (inserted, 0..) |*v, i| v.* = 500 + @as(u64, @intCast(i / 2));
    try col.splice(gpa, 40, 25, inserted);
    try model.replaceRange(gpa, 40, 25, inserted);

    try validateRleColumn(Rle(u64), &col);
    try expectModel(u64, Rle(u64), &col, model.items);
    try expectRoundTrip(u64, Rle(u64), &col, model.items);
    // The run before the cut and the run after it are both distinct from the
    // inserted values, so the seam either side of the rebuilt range is a real
    // adjacency and the walk has to look at it.
    try testing.expectEqual(@as(u64, 19), model.items[39]);
    try testing.expectEqual(@as(u64, 500), model.items[40]);
    try testing.expectEqual(@as(u64, 507), model.items[54]);
    try testing.expectEqual(@as(u64, 32), model.items[55]);
    try testing.expectEqual(@as(usize, 390), model.items.len);
}

// ── `seek_to_value` (`tests.rs:3647-3746`) ──────────────────────────────────
//
// `Column.scope_to_value` and `Iterator.seek_to_value` are the same answer by
// two routes: the first opens a fresh cursor on a window
// (`column.rs:1487-1494`), the second answers on a cursor that is already
// standing somewhere and **moves it onto what it found**
// (`column.rs:927-932`, `seekToValue`). Upstream's eight cases are all about
// the second: what it answers for a value that is absent, for a window that
// does not hold the value, and when it is called repeatedly on one cursor.
// The port had `scopeToValue` covered against a linear scan
// (`scope_to_value_fuzz_vs_linear`) and `seekToValue` called exactly once.
//
// **These cases do not assume a slab layout.** Every answer here is compared
// with a model built by a linear scan of a plain array, so what is under test
// is the answer a cursor gives and where it is left — not how many slabs the
// constructor happened to cut. `distinct` is the knob that decides the layout
// (it is the number of runs the column holds), so `seek_to_value_basic` picks
// a wide one to reach the slab search and the rest keep upstream's handful.

/// The rows `target` occupies in a **sorted** model, by linear scan. The
/// answer for a value the column does not hold is the empty range at the row
/// it would have been inserted at — the rule `column.rs:913-934` implements,
/// and the one `partition_point` gives upstream.
fn scopeInModel(model: []const u64, target: u64, range: RowRange) RowRange {
    const window = clampRange(range, model.len);
    var start = window.start;
    var end = window.start;
    while (start < window.end and model[start] < target) : (start += 1) {}
    while (end < window.end and model[end] <= target) : (end += 1) {}
    return .{ .start = start, .end = end };
}

/// The answer `Iterator::seek_to_value` gives for `target` when the cursor
/// already stands at `at`. **The scan starts at the cursor, not at the
/// window's start** (`column.rs:927-932`): the cursor is first advanced to
/// `range.start` if it is behind the cursor, a copy of the cursor is scanned
/// up to `range.end`, and the real cursor is then moved onto the answer. A
/// model that scanned the whole window would be modelling a different
/// method — `Column::scope_to_value`, which opens a fresh cursor.
fn seekModel(model: []const u64, target: u64, at: usize, range: RowRange) RowRange {
    const end = @min(range.end, model.len);
    const from = @min(@max(at, @min(range.start, model.len)), end);
    const rel = scopeInModel(model[from..end], target, .{ .start = 0, .end = end - from });
    return .{ .start = from + rel.start, .end = from + rel.end };
}

/// A sorted column of `n` rows drawn from `distinct + 1` values, and the
/// same rows as a model. Upstream builds these by inserting every value at
/// its sorted position (`tests.rs:3663-3681`), which is what leaves
/// equal-valued rows adjacent; a single `extend` of a sorted list produces the
/// same layout through the splice path and is what the port has.
///
/// `distinct` decides the run count, and the run count is what decides the
/// slab count: a few values make one slab whatever the budget is, and an
/// alphabet wider than the budget makes a column that spans several.
fn sortedColumn(
    gpa: std.mem.Allocator,
    n: usize,
    distinct: u64,
    seed: u64,
) !struct { col: Column(u64, Rle(u64)), model: []u64 } {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    const model = try gpa.alloc(u64, n);
    errdefer gpa.free(model);
    for (model) |*v| v.* = rand.intRangeAtMost(u64, 0, distinct);
    std.mem.sort(u64, model, {}, std.sort.asc(u64));
    var col = try Column(u64, Rle(u64)).init(gpa);
    errdefer col.deinit();
    try col.extend(gpa, model);
    return .{ .col = col, .model = model };
}

//  A value that is there, and a value that is not: the second answers the
//  empty range at the row it would have been inserted at, which is where a
//  sequential scan lands when it first passes the target
//  (`tests.rs:3655-3670`, `column.rs:913-934`). Both routes are asked, because
//  they are different code — one opens a fresh cursor, the other does not.
//
//  **The alphabet is wide enough that the column really spans slabs**, because
//  the answer has to be found the way it is found in production: `sortedScanToValue`
//  reads one run, binary-searches the slabs behind it by their first value and
//  walks forward from the last slab that starts below the target. Upstream's
//  case reaches that arm on a handful of values because its `Slab.segments`
//  counts a literal run by its values; this port counts it as one
//  (`slab.zig:111-114`), so the same *rows* need a wider alphabet to be the
//  same *shape*.
test "seek_to_value_basic" {
    const gpa = testing.allocator;
    var built = try sortedColumn(gpa, 400, 200, 0x5EED);
    defer gpa.free(built.model);
    defer built.col.deinit();
    const whole = RowRange{ .start = 0, .end = built.col.len() };

    for ([_]u64{ 0, 3, 7, 8, 99 }) |target| {
        const want = scopeInModel(built.model, target, whole);
        try expectScope(want, try built.col.scopeToValue(target, whole));
        var it = try built.col.iterator();
        try expectScope(want, try it.seekToValue(target, whole));
        // The cursor is moved onto the answer, so a target that was found
        // leaves the cursor on its first row and one that was not leaves it
        // on the row it would have been inserted at.
        try testing.expectEqual(want.start, it.pos());
        try testing.expectEqual(@as(?u64, if (want.start < built.model.len) built.model[want.start] else null), try it.next());
    }
}

//  The same answers asked for one value after another on **one** cursor,
//  which is what the op set does walking a map's rows in order
//  (`tests.rs:3695-3712`). Each answer is the model's **from where the cursor
//  stands**, so a value whose rows are all behind it answers the empty range at
//  the cursor rather than its own range — the arm a fresh cursor per call
//  cannot reach.
test "seek_to_value_sequential" {
    const gpa = testing.allocator;
    var built = try sortedColumn(gpa, 600, 6, 0xC0DE);
    defer gpa.free(built.model);
    defer built.col.deinit();
    const whole = RowRange{ .start = 0, .end = built.col.len() };

    var it = try built.col.iterator();
    var target: u64 = 0;
    while (target <= 6) : (target += 1) {
        try expectScope(seekModel(built.model, target, it.pos(), whole), try it.seekToValue(target, whole));
    }
    // Every other value: a seek that skips a run, and one that has to
    // re-descend for a value behind the cursor.
    var skipped = try built.col.iterator();
    target = 0;
    while (target <= 6) : (target += 2) {
        try expectScope(seekModel(built.model, target, skipped.pos(), whole), try skipped.seekToValue(target, whole));
    }
    // The cursor never walked past the end, whichever order the targets came
    // in.
    try testing.expect(it.pos() <= built.col.len());
    try testing.expect(skipped.pos() <= built.col.len());
}

//  A window that is not the whole column: the answer is found **inside** the
//  window, so a value whose rows are all outside it answers empty even though
//  the column holds it (`tests.rs:3714-3722`). Each target gets a fresh
//  cursor, because the cursor-relative answer is what the other case is for.
test "seek_to_value_with_range" {
    const gpa = testing.allocator;
    var built = try sortedColumn(gpa, 600, 6, 0xF00D);
    defer gpa.free(built.model);
    defer built.col.deinit();
    const whole = RowRange{ .start = 0, .end = built.col.len() };
    const window = RowRange{ .start = 100, .end = 500 };

    for ([_]u64{ 0, 1, 3, 5 }) |target| {
        const in_window = scopeInModel(built.model, target, window);
        const in_whole = scopeInModel(built.model, target, whole);
        var scoped = try built.col.iterator();
        try expectScope(in_window, try scoped.seekToValue(target, window));
        var full = try built.col.iterator();
        try expectScope(in_whole, try full.seekToValue(target, whole));
        // The answer never leaves the window it was asked about, and it
        // starts no earlier than the column's own answer does. **It is
        // not a sub-range of the column's answer, and does not have to
        // be**: a value whose rows are all in front of the window
        // answers the empty range at the window's own start, which is a
        // row *past* the column-level answer's end — the insertion-point
        // rule `scopeInModel` implements and `partition_point` gives
        // upstream.
        try testing.expect(in_window.start >= window.start);
        try testing.expect(in_window.end <= window.end);
        try testing.expect(in_whole.start <= in_window.start);
    }
    // An empty window answers an empty range and moves the cursor nowhere
    // past its own end.
    var narrow = try built.col.iterator();
    try expectScope(.{ .start = 300, .end = 300 }, try narrow.seekToValue(3, .{ .start = 300, .end = 300 }));
    try testing.expectEqual(@as(usize, 300), narrow.pos());
}

//  A cursor that has already read rows: the scan starts from where it stands,
//  so every answer is the model's from **that** row on, and a target whose
//  rows are all behind it answers the empty range at the cursor
//  (`tests.rs:3674-3694`).
test "seek_to_value_after_reads" {
    const gpa = testing.allocator;
    var built = try sortedColumn(gpa, 600, 6, 0xBEEF);
    defer gpa.free(built.model);
    defer built.col.deinit();
    const whole = RowRange{ .start = 0, .end = built.col.len() };

    var it = try built.col.iterator();
    var at: usize = 0;
    while (at < 120) : (at += 1) {
        const v = (try it.next()) orelse return error.TestUnexpectedResult;
        if (v != built.model[at]) return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 120), it.pos());
    // The same answers a fresh cursor would give are *not* what this one
    // gives for a value that only lives in the rows already read: the scan
    // begins at row 120, so it reports the insertion point there.
    const at_start = built.model[120];
    try testing.expect(at_start != built.model[0]);

    var target: u64 = 0;
    while (target <= 6) : (target += 1) {
        try expectScope(seekModel(built.model, target, it.pos(), whole), try it.seekToValue(target, whole));
    }
    try testing.expect(it.pos() >= 120);
}

//  A nullable column's absent rows sort **first**, so `scope_to_value` and
//  `seek_to_value` both answer a range for `null` that is at the front of the
//  column and not in the middle (`tests.rs:3673-3693` upstream's
//  `delta_scope_to_value_nullable` shape, which the codec's own comparison
//  rule states at `column.zig:239-243`).
test "seek_to_value_nullable" {
    const gpa = testing.allocator;
    const model = try gpa.alloc(?u64, 400);
    defer gpa.free(model);
    var prng: std.Random.DefaultPrng = .init(0x0A11);
    const rand = prng.random();
    for (model) |*v| {
        const r = rand.intRangeAtMost(u64, 0, 9);
        v.* = if (r % 4 == 0) null else r;
    }
    // Absent rows first: null sorts before every value.
    std.mem.sort(?u64, model, {}, lessNullable);
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, model);
    const whole = RowRange{ .start = 0, .end = col.len() };

    for ([_]?u64{ null, 0, 1, 5, 9, 100 }) |target| {
        try expectScope(scopeInNullableModel(model, target, whole), try col.scopeToValue(target, whole));
        var it = try col.iterator();
        try expectScope(scopeInNullableModel(model, target, whole), try it.seekToValue(target, whole));
    }
}

/// `?u64` in the order the column's own comparison rule puts them
/// (`column.zig:239-243`): absent before every value, values unsigned.
fn lessNullable(_: void, a: ?u64, b: ?u64) bool {
    if (a == null) return b != null;
    if (b == null) return false;
    return a.? < b.?;
}

fn scopeInNullableModel(model: []const ?u64, target: ?u64, range: RowRange) RowRange {
    const window = clampRange(range, model.len);
    var start = window.start;
    var end = window.start;
    while (start < window.end and lessNullable({}, model[start], target)) : (start += 1) {}
    while (end < window.end and !lessNullable({}, target, model[end])) : (end += 1) {}
    return .{ .start = start, .end = end };
}

//  A delta column's answer is a plain column's answer. The delta column's
//  run walk realizes values (`nextRunByValue`, `delta/mod.rs:19-26`) where the
//  RLE column's is the wire's, so the two routes to the answer are different
//  code for the same claim (`tests.rs:3739-3806`).
test "delta_scope_to_value_matches_plain_column" {
    const gpa = testing.allocator;
    const n: usize = 3000;
    const model = try gpa.alloc(u64, n);
    defer gpa.free(model);
    var prng: std.Random.DefaultPrng = .init(0x3141_5);
    const rand = prng.random();
    for (model) |*v| v.* = rand.intRangeAtMost(u64, 0, 60);
    std.mem.sort(u64, model, {}, std.sort.asc(u64));

    var plain = try Column(u64, Rle(u64)).init(gpa);
    defer plain.deinit();
    try plain.extend(gpa, model);
    var delta = try Column(u64, Delta(u64)).init(gpa);
    defer delta.deinit();
    try delta.extend(gpa, model);
    if (delta.slabCount() < 2) return error.TestUnexpectedResult;

    var target: u64 = 0;
    while (target <= 62) : (target += 1) {
        var a = rand.intRangeAtMost(usize, 0, n);
        var b = rand.intRangeAtMost(usize, 0, n);
        if (a > b) std.mem.swap(usize, &a, &b);
        const window = RowRange{ .start = a, .end = b };
        const want = try plain.scopeToValue(target, window);
        if (want.start != want.end) {
            const got = try delta.scopeToValue(target, window);
            if (got.start != want.start or got.end != want.end) {
                std.debug.print(
                    "target {d} window {d}..{d}: delta {d}..{d}, plain {d}..{d}\n",
                    .{ target, a, b, got.start, got.end, want.start, want.end },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}

//  The nullable delta form, where a null row leaves the running value alone
//  (`delta/mod.rs:19-26`) and so an absent row is not a difference at all
//  (`tests.rs:3707-3738`).
test "delta_scope_to_value_nullable" {
    const gpa = testing.allocator;
    const n: usize = 1500;
    const model = try gpa.alloc(?u64, n);
    defer gpa.free(model);
    var prng: std.Random.DefaultPrng = .init(0x9A9_9);
    const rand = prng.random();
    for (model) |*v| {
        const r = rand.intRangeAtMost(u64, 0, 7);
        v.* = if (r % 5 == 0) null else r;
    }
    std.mem.sort(?u64, model, {}, lessNullable);

    var plain = try Column(?u64, RleOption(u64)).init(gpa);
    defer plain.deinit();
    try plain.extend(gpa, model);
    var delta = try Column(?u64, Delta(?u64)).init(gpa);
    defer delta.deinit();
    try delta.extend(gpa, model);
    const whole = RowRange{ .start = 0, .end = n };

    for ([_]?u64{ null, 0, 1, 4, 7, 50 }) |target| {
        try expectScope(scopeInNullableModel(model, target, whole), try plain.scopeToValue(target, whole));
        try expectScope(scopeInNullableModel(model, target, whole), try delta.scopeToValue(target, whole));
        var it = try delta.iterator();
        try expectScope(scopeInNullableModel(model, target, whole), try it.seekToValue(target, whole));
    }
}

/// A delta column over `rows` values in runs of `per`, and the same rows as
/// a model. The default run budget, so the column spans several slabs: the
/// walk below has to leave the row behind a run unconsumed both when the run
/// ends inside a slab and when it ends at the slab's last row, and only a
/// column that really spans slabs can be asked to do the second.
fn deltaRunColumn(rows: usize, per: usize) !struct { col: Column(u64, Delta(u64)), model: []u64 } {
    const gpa = testing.allocator;
    const model = try gpa.alloc(u64, rows);
    errdefer gpa.free(model);
    for (model, 0..) |*v, i| v.* = @intCast(i / per);
    var col = try Column(u64, Delta(u64)).init(gpa);
    errdefer col.deinit();
    try col.extend(gpa, model);
    return .{ .col = col, .model = model };
}

//  A delta column's runs are runs of equal *differences*, so a run of equal
//  values is found by realizing rows one at a time (`delta/mod.rs:19-26`) —
//  and the row that turned out to differ is the first row of the **next**
//  run. Handing that row back is what makes the walk make progress: a walk
//  that rewinds to where the run began answers the same run for ever, and a
//  walk that kept the row skips a value. This is the case `sortedScanToValue`
//  loops on, and it is a case no model comparison reaches on its own.
test "a delta run walk leaves the row behind every run for the next one" {
    const gpa = testing.allocator;
    var built = try deltaRunColumn(3000, 5);
    defer gpa.free(built.model);
    defer built.col.deinit();
    if (built.col.slabCount() < 3) return error.TestUnexpectedResult;

    var it = try built.col.iterator();
    const bound = it.maxPos();
    var at: usize = 0;
    while (try it.nextRun()) |run| {
        if (run.count == 0 or at + run.count > bound) return error.TestUnexpectedResult;
        for (0..run.count) |k| try testing.expectEqual(built.model[at + k], run.value);
        at += run.count;
        try testing.expectEqual(at, it.pos());
        // The row behind the run is still there. Reading it off a *copy* of
        // the cursor leaves the walk where it is and says what the cursor is
        // standing on: a walk that consumed the row would report the row
        // after this one, and a walk that rewound would report the first row
        // of the run it has already handed over.
        if (at < bound) {
            var peeked = it;
            const row = (try peeked.next()) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(built.model[at], row);
        }
    }
    try testing.expectEqual(built.model.len, at);
    try testing.expectEqual(built.model.len, it.pos());
    try testing.expect((try it.nextRun()) == null);

    // The same walk clipped to two rows a step, which is what asks for the
    // row behind a run to be put back inside one call as often as between
    // two: every call that is cut short mid-run has to leave the rest of that
    // run, and the row that ends it, exactly where they were.
    var clipped = try built.col.iterator();
    var cat: usize = 0;
    while (cat < built.model.len) {
        const run = (try clipped.nextRunMax(2)).?;
        try testing.expect(run.count > 0 and run.count <= 2);
        for (0..run.count) |k| try testing.expectEqual(built.model[cat + k], run.value);
        cat += run.count;
        try testing.expectEqual(cat, clipped.pos());
    }
    try testing.expectEqual(built.model.len, cat);
    try testing.expect((try clipped.nextRunMax(2)) == null);

    // A window that starts in the middle of a run: the first run is the rows
    // behind the cursor, and the walk carries on from there.
    const window = RowRange{ .start = 1002, .end = 2500 };
    var wit = try built.col.iterRange(window);
    const head = (try wit.nextRun()).?;
    try testing.expectEqual(built.model[window.start], head.value);
    try testing.expectEqual(@as(usize, 3), head.count);
    try testing.expectEqual(window.start + 3, wit.pos());
    var wat: usize = window.start + 3;
    while (try wit.nextRun()) |run| {
        for (0..run.count) |k| try testing.expectEqual(built.model[wat + k], run.value);
        wat += run.count;
        try testing.expectEqual(wat, wit.pos());
    }
    try testing.expectEqual(window.end, wat);
}

// ── `nth` on the row cursor (`tests.rs:2094-2236`) ──────────────────────────
//
// `Iterator::nth` has two arms and upstream's eight cases are a partition of
// them (`column.rs:365-372`, `:3690-3706`): a target inside the slab the
// cursor already stands in is reached by consuming the decoder's rows, and a
// target past it asks the index for the slab (`findByPrefix`) and re-anchors
// there. **Both arms have to be right and they disagree quietly** — the
// in-slab arm forgets to re-anchor a delta column's running value, and the
// index arm lands on a slab whose base is the value in front of *that* slab.
//
// `nth_sequential_calls` is the composition (`nth` after `nth`), and
// `nth_from_iter_range` is the window-relative form: both count from where the
// cursor stands, not from zero.

/// The `nth` answer of `col` for each offset in `offsets`, against `model`:
/// once from a fresh cursor over the whole column, and once from a window
/// born in the middle of it. **Each offset gets its own cursor**, so an
/// answer is not inherited from the one before — the composition of two
/// `nth` calls is `nth_sequential_calls`'s subject, not this one's.
fn expectNth(
    comptime T: type,
    comptime E: type,
    col: *const Column(T, E),
    model: []const T,
    offsets: []const usize,
) !void {
    for (offsets) |n| {
        var fresh = try col.iterator();
        const got = try fresh.nth(n);
        if (n >= model.len) {
            try testing.expect(got == null);
            continue;
        }
        if (got == null or got.? != model[n]) {
            std.debug.print(
                "nth({d}) of {d} rows: got {any}, the model says {any}\n",
                .{ n, model.len, got, model[n] },
            );
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(n + 1, fresh.pos());
    }
    // The same offsets from a window that starts in the middle of the
    // column, which is the shape a caller walking one object's rows has.
    // **A window of its own per offset, like the cursor above**: a window
    // `nth` counts from where the cursor stands and leaves it on the row it
    // landed on, so one window carried round the loop would answer the
    // second offset from the first one's landing row and every answer
    // behind it would be a row further on — `nth_sequential_calls` is the
    // case that composes two calls on one cursor, and this is not it.
    if (model.len < 4) return;
    const start = model.len / 3;
    for (offsets) |n| {
        const at = start + n;
        var window = try col.iterRange(.{ .start = start, .end = model.len });
        const got = try window.nth(n);
        if (at >= model.len) {
            try testing.expect(got == null);
            continue;
        }
        if (got == null or got.? != model[at]) {
            std.debug.print(
                "window at {d}, nth({d}): got {any}, the model says {any}\n",
                .{ start, n, got, model[at] },
            );
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(at + 1, window.pos());
    }
}

//  A thousand alternating runs of a hundred rows: a target that lands on the
//  last row of one run, the first row of the next, and the middle of a third,
//  which is the in-slab arm's whole domain (`tests.rs:2100-2114`).
test "nth_across_runs" {
    const gpa = testing.allocator;
    const model = try gpa.alloc(u64, 1000);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = @intCast(i / 100);
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, model);
    try expectNth(u64, Rle(u64), &col, model, &.{ 0, 99, 100, 199, 200, 555, 999, 1000 });
}

//  The same shape at the port's own budget rather than upstream's four runs,
//  so the offsets past the first slab take the index arm (`tests.rs:2117-
//  2125`).
test "nth_across_slabs" {
    const gpa = testing.allocator;
    const rows: usize = 4000;
    const model = try gpa.alloc(u64, rows);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = @intCast(i / 5);
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, model);
    if (col.slabCount() < 3) return error.TestUnexpectedResult;
    // Offsets in the first slab, either side of its end, in a middle slab, in
    // the last row, and past the end.
    try expectNth(u64, Rle(u64), &col, model, &.{ 0, 63, 64, 319, 320, 321, 1500, 3998, 3999, 4000, 9000 });
}

//  A target inside one long repeat run. Ten thousand copies of one value are
//  **one run**, so a target in the middle of it cannot be found by an index
//  descent at all: the column is a single slab holding a single wire header,
//  and the answer is whatever the decoder's remaining count says
//  (`tests.rs:2226-2235`).
//
//  Upstream's comment on this case reads "nth should skip in O(1)". **That is
//  a cost claim, and this port makes the opposite trade** — its decoders have
//  no `nth`, so the rows in front of the target inside its own slab are read
//  one at a time (`column.zig:3648-3650`, `skipRows`), which the code says in
//  as many words. What is asserted here is the **answer**, not how long the
//  walk took, and the offsets that matter are the ones deep inside the run.
test "nth_within_repeat_run" {
    const gpa = testing.allocator;
    const rows: usize = 10_000;
    const model = try gpa.alloc(u64, rows);
    defer gpa.free(model);
    @memset(model, 42);
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, model);
    const segs = try col.slabSegments(gpa);
    defer gpa.free(segs);
    try testing.expectEqual(@as(usize, 1), segs.len);
    try expectNth(u64, Rle(u64), &col, model, &.{ 0, 1, 5000, 9999, 10_000 });
}

//  `nth` twice on one cursor answers the two rows the two skips name, so a
//  caller walking with `nth` sees every row exactly once (`tests.rs:2213-2223`).
test "nth_sequential_calls" {
    const gpa = testing.allocator;
    const model = try gpa.alloc(u64, 100);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = @intCast(i);
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, model);

    var it = try col.iterator();
    try testing.expectEqual(@as(?u64, 5), try it.nth(5));
    try testing.expectEqual(@as(usize, 6), it.pos());
    // From row 6, five more is row 11.
    try testing.expectEqual(@as(?u64, 11), try it.nth(5));
    try testing.expectEqual(@as(usize, 12), it.pos());
    // And a window born in the middle composes the same way.
    var window = try col.iterRange(.{ .start = 50, .end = 100 });
    try testing.expectEqual(@as(?u64, 55), try window.nth(5));
    try testing.expectEqual(@as(usize, 56), window.pos());
    try testing.expectEqual(@as(?u64, 56), try window.nth(0));
    try testing.expectEqual(@as(usize, 57), window.pos());
}

//  The two codecs whose wire form is not a value at all. A boolean column's
//  runs are counts and a nullable one's absent rows are null runs, so a
//  target landing in either comes back out of a run header rather than off a
//  payload (`tests.rs:2128-2136`, `:2186-2195`).
test "nth_bool" {
    const gpa = testing.allocator;
    const rows: usize = 1000;
    const model = try gpa.alloc(bool, rows);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = i % 100 < 50;
    var col = try Column(bool, Bool).init(gpa);
    defer col.deinit();
    try col.extend(gpa, model);
    try expectNth(bool, Bool, &col, model, &.{ 0, 49, 50, 51, 500, 999, 1000 });
}

test "nth_nullable" {
    const gpa = testing.allocator;
    const rows: usize = 100;
    const model = try gpa.alloc(?u64, rows);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = if (i % 3 == 0) null else @intCast(i);
    var col = try Column(?u64, RleOption(u64)).init(gpa);
    defer col.deinit();
    try col.extend(gpa, model);
    try expectNth(?u64, RleOption(u64), &col, model, &.{ 0, 1, 2, 3, 50, 99, 100 });
}

//  The randomised form (`tests.rs:2197-2206`): a hundred and one column
//  shapes, each with a skip drawn from its own length, answered by the cursor.
//  **The seed is a constant**, because a randomised case whose inputs are not
//  recorded cannot be re-run from the line that failed.
test "nth_proptest" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x8EED);
    const rand = prng.random();
    for (0..101) |trial| {
        const rows = rand.intRangeAtMost(usize, 1, 500);
        const model = try gpa.alloc(u64, rows);
        defer gpa.free(model);
        for (model) |*v| v.* = rand.intRangeAtMost(u64, 0, 99);
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        try col.extend(gpa, model);
        const skip = rand.intRangeAtMost(usize, 0, 500);
        var it = try col.iterator();
        const got = try it.nth(skip);
        if (skip < rows) {
            if (got == null or got.? != model[skip]) {
                std.debug.print("trial {d}: nth({d}) of {d} rows\n", .{ trial, skip, rows });
                return error.TestUnexpectedResult;
            }
        } else if (got != null) {
            std.debug.print("trial {d}: nth({d}) of {d} rows answered a row\n", .{ trial, skip, rows });
            return error.TestUnexpectedResult;
        }
    }
}

// ── `remap` and `remove_n` (`tests.rs:3604-3646`, `:4728-4761`) ──────────────

/// Every value up by one, which is what an inserted actor index does to the
/// columns that hold one (`op_set2/columns.rs:332-348`). **The `u32` form of
/// this mapping is `shiftValueByOne` above** and is not folded into this one,
/// because a row function is typed by its column.
fn bumpByOne(_: void, v: u64) u64 {
    return v + 1;
}

/// Upstream's `fuzz_column_remap` mapping (`tests.rs:3626`).
fn timesThreePlusSeven(_: void, v: u64) u64 {
    return v * 3 + 7;
}

/// The runs of `col`, as `(count, value)` pairs.
fn runsOf(gpa: std.mem.Allocator, col: *const Column(u64, Rle(u64))) ![]RunOf(u64) {
    var out: std.ArrayList(RunOf(u64)) = .empty;
    errdefer out.deinit(gpa);
    var it = try col.iterator();
    while (try it.nextRun()) |run| try out.append(gpa, run);
    return out.toOwnedSlice(gpa);
}

//  `remap` over a column with no rows: it has no slabs to walk, so the
//  rebuild has to produce an empty column and not seed one (`tests.rs:3608-
//  3615`).
test "remap_empty" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    try col.remap(gpa, {}, bumpByOne);
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expect(col.isEmpty());
    try expectSound(u64, Rle(u64), &col);
    try expectRoundTrip(u64, Rle(u64), &col, &.{});

    // A column emptied by a delete remaps the same way, and the empty slab it
    // keeps is still a slab a later splice can land in.
    var filled = try v1Build(gpa, &.{ 1, 2, 3, 4, 5 });
    defer filled.deinit();
    try filled.removeN(gpa, 0, 5);
    try filled.remap(gpa, {}, bumpByOne);
    try testing.expectEqual(@as(usize, 0), filled.len());
    try expectSound(u64, Rle(u64), &filled);
    try filled.extend(gpa, &.{7});
    try testing.expectEqual(@as(?u64, 7), try filled.get(0));
}

//  A long repeat stays a repeat, which is the claim `remap_runs_preserved`
//  makes by counting rows (`tests.rs:3638-3646`). **Counting rows cannot see
//  it**, so this one counts runs: a `remap` that rebuilt by walking rows would
//  turn a hundred copies of one value into a hundred single-row runs and
//  still answer the same values. The claim behind it is that the rebuild
//  walks run-at-a-time (`column.rs:1263-1273`, `encoding.rs:66-86`), so one
//  `f` call covers a whole repeat run.
test "remap_runs_preserved" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    const model = try gpa.alloc(u64, 100);
    defer gpa.free(model);
    @memset(model, 7);
    try col.extend(gpa, model);

    const before = try runsOf(gpa, &col);
    defer gpa.free(before);
    try testing.expectEqual(@as(usize, 1), before.len);
    try testing.expectEqual(@as(usize, 100), before[0].count);

    try col.remap(gpa, {}, bumpByOne);
    const after = try runsOf(gpa, &col);
    defer gpa.free(after);
    try testing.expectEqual(before.len, after.len);
    try testing.expectEqual(@as(usize, 100), after[0].count);
    try testing.expectEqual(@as(u64, 8), after[0].value);

    const mapped = try gpa.alloc(u64, 100);
    defer gpa.free(mapped);
    @memset(mapped, 8);
    try expectModel(u64, Rle(u64), &col, mapped);
    try expectRoundTrip(u64, Rle(u64), &col, mapped);
}

//  `remapped` builds *beside* the column rather than through it. That is what
//  `Columns.remapActors` stands on: it has four columns to renumber and may
//  publish none of them until all four are staged, so a stage cannot release
//  or borrow the source's storage — which is exactly what remapping a shallow
//  copy of a column did.
test "remapped_leaves_the_source_column_whole" {
    const gpa = testing.allocator;
    var col = try v1Build(gpa, &.{ 1, 2, 3, 4, 5 });
    defer col.deinit();

    var staged = try col.remapped(gpa, {}, bumpByOne);
    defer staged.deinit();

    // The source still answers for its own rows, at its own run budget, and
    // is still a column that can be written to and freed.
    try testing.expectEqual(col.maxSegmentsOf(), staged.maxSegmentsOf());
    try expectSound(u64, Rle(u64), &col);
    try expectSound(u64, Rle(u64), &staged);
    try testing.expectEqual(@as(?u64, 1), try col.get(0));
    try testing.expectEqual(@as(?u64, 5), try col.get(4));

    const mapped = try gpa.alloc(u64, 5);
    defer gpa.free(mapped);
    for (mapped, 0..) |*v, i| v.* = @intCast(i + 2);
    try expectModel(u64, Rle(u64), &staged, mapped);
    try expectRoundTrip(u64, Rle(u64), &staged, mapped);

    // The two are independent: a write to the source leaves the staged copy
    // exactly as it was built.
    try col.extend(gpa, &.{6});
    try testing.expectEqual(@as(usize, 5), staged.len());
    try expectSound(u64, Rle(u64), &col);
}

//  `remap` after arbitrary mutation, against the same mapping applied to a
//  plain array (`tests.rs:3617-3636`). A remap over a column built in one
//  splice never sees the layout an edited column has, and the walk is the
//  part that reads it.
test "fuzz_column_remap" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x2E2E);
    const rand = prng.random();
    for (0..20) |trial| {
        var col = try Column(u64, Rle(u64)).init(gpa);
        defer col.deinit();
        var model: std.ArrayList(u64) = .empty;
        defer model.deinit(gpa);
        for (0..100) |_| {
            const len = model.items.len;
            const at = if (len == 0) 0 else rand.intRangeAtMost(usize, 0, len);
            const v = rand.intRangeAtMost(u64, 0, 50);
            try col.splice(gpa, at, 0, &.{v});
            try model.insert(gpa, at, v);
        }
        try expectSound(u64, Rle(u64), &col);

        var want: std.ArrayList(u64) = .empty;
        defer want.deinit(gpa);
        for (model.items) |v| try want.append(gpa, v * 3 + 7);

        try col.remap(gpa, {}, timesThreePlusSeven);
        try expectSound(u64, Rle(u64), &col);
        if (col.len() != want.items.len) {
            std.debug.print("trial {d}: remap left {d} rows of {d}\n", .{ trial, col.len(), want.items.len });
            return error.TestUnexpectedResult;
        }
        try expectModel(u64, Rle(u64), &col, want.items);
        try expectRoundTrip(u64, Rle(u64), &col, want.items);
    }
}

//  `remove_n` is a bounds-checked delete: it drains like `Vec::drain`, a
//  zero-length drain changes nothing, and a drain past the end is refused
//  rather than taken (`tests.rs:4728-4761`). The refusal half is upstream's
//  `#[should_panic(expected = "splice range out of bounds")]`, and a refusal
//  is stronger than the panic it replaces: the column is still whole
//  afterwards, which a panic that never returns cannot check.
test "remove_n_matches_vec_drain" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    const model = try gpa.alloc(u64, 100);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = @intCast(i);
    try col.extend(gpa, model);

    try col.removeN(gpa, 10, 25);
    var mirror: std.ArrayList(u64) = .empty;
    defer mirror.deinit(gpa);
    try mirror.appendSlice(gpa, model[0..10]);
    try mirror.appendSlice(gpa, model[35..]);
    try expectModel(u64, Rle(u64), &col, mirror.items);

    // A zero-length drain is a no-op, and a drain of the whole column leaves
    // one empty slab behind rather than none.
    try col.removeN(gpa, 0, 0);
    try expectModel(u64, Rle(u64), &col, mirror.items);
    try col.removeN(gpa, 0, mirror.items.len);
    try testing.expectEqual(@as(usize, 0), col.len());
    try expectSound(u64, Rle(u64), &col);

    // Past the end is refused and the column is untouched.
    try col.extend(gpa, model);
    try testing.expectError(error.InvalidValue, col.removeN(gpa, 5, model.len));
    try expectModel(u64, Rle(u64), &col, model);
}

//  Empty bytes plus a length and a fill, on the **delta** codec. Upstream's
//  case is `DeltaColumn::<Option<u64>>::load_with(&[], with_length(5).
//  with_fill(None))` (`tests.rs:2656-2665`); the RLE and boolean forms are
//  already covered (`load_with_empty_data_and_fill_gives_filled_nullable`),
//  and a delta column fills by a **different** rule: a run of equal values is
//  one literal run followed by one repeat run of zero differences
//  (`column.zig:1319-1342`), so a nullable delta fill takes a third shape
//  again — the null run `Delta.fillBytes` returns before it looks at any
//  value.
test "delta_column_load_with_nullable_empty_fill" {
    const gpa = testing.allocator;
    const C = Column(?u32, DeltaOption);
    var col = try C.loadWith(gpa, &.{}, C.LoadOpts.new().withLength(5).withFill(null));
    defer col.deinit();
    try testing.expectEqual(@as(usize, 5), col.len());
    for (0..5) |i| try testing.expectEqual(@as(?u32, null), try col.get(i));
    try expectSound(?u32, DeltaOption, &col);

    // And the non-null fill on the same codec, which is the literal-plus-zero
    // difference shape.
    const D = Column(u32, Delta(u32));
    var filled = try D.loadWith(gpa, &.{}, D.LoadOpts.new().withLength(7).withFill(3));
    defer filled.deinit();
    for (0..7) |i| try testing.expectEqual(@as(u32, 3), try filled.get(i));
    const want = try gpa.alloc(u32, 7);
    defer gpa.free(want);
    @memset(want, 3);
    try expectRoundTrip(u32, Delta(u32), &filled, want);
}

// ── `next_run` across a slab boundary (`tests.rs:4134-4146`, `:4901-4990`)
// ────────────────────────────────────────────────────────────────────────────
//
// A slab cut lands on a run boundary, so the only way two adjacent slabs hold
// the same value is an **edit that makes them agree** — which is exactly what
// upstream builds in all three of these cases. `next_run` coalesces runs
// regardless of the slab layout (`column.rs:591-616`), so a caller walking
// runs never sees a slab boundary, and two consecutive runs never carry equal
// values.
//
// **This is the one property the port's own run walks could not reach.** Their
// fixtures (`cursorColumn` and the cross-slab merge fixtures) put a distinct
// value in every run and cut at the run budget, so a slab boundary always fell
// between two runs of different values and the coalescing arm of `nextRunMax`
// (`column.zig:3789-3799`) was never taken. An edit is the only way two
// neighbouring slabs can come to hold the same value, which is what this
// fixture makes.

/// A run-length column of `runs` runs of `per` rows, values `1..=runs`, cut
/// so that several slabs meet, and then an edit that makes the last row
/// before the first boundary carry the same value as the first row after it.
/// Returns the column and the boundary row.
fn equalAtSlabBoundary(gpa: std.mem.Allocator) !struct {
    col: Column(u64, Rle(u64)),
    model: std.ArrayList(u64),
    boundary: usize,
} {
    var col = try Column(u64, Rle(u64)).init(gpa);
    errdefer col.deinit();
    var model: std.ArrayList(u64) = .empty;
    errdefer model.deinit(gpa);
    // 400 runs of two rows is 400 runs and so seven slabs of 64.
    for (0..400) |run| {
        for (0..2) |_| {
            const v: u64 = @intCast(run + 1);
            try col.append(gpa, v);
            try model.append(gpa, v);
        }
    }
    if (col.slabCount() < 2) return error.TestUnexpectedResult;
    const boundary = col.slabAt(0).?.len;
    const across = model.items[boundary];
    try col.splice(gpa, boundary - 1, 1, &.{across});
    try model.replaceRange(gpa, boundary - 1, 1, &.{across});
    // The two slabs stay two slabs: each is at the run budget, so the merge
    // policy has nothing to do and the boundary survives the edit.
    if (col.slabCount() < 2) return error.TestUnexpectedResult;
    try expectSound(u64, Rle(u64), &col);
    return .{ .col = col, .model = model, .boundary = boundary };
}

//  The two equal-valued runs either side of a slab boundary come back as one
//  run, the total is the column's length, and no two consecutive runs carry
//  equal values (`tests.rs:4901-4990`).
test "next_run_merges_across_slabs" {
    const gpa = testing.allocator;
    var built = try equalAtSlabBoundary(gpa);
    defer built.model.deinit(gpa);
    defer built.col.deinit();
    try expectModel(u64, Rle(u64), &built.col, built.model.items);

    var it = try built.col.iterator();
    var at: usize = 0;
    var previous: ?u64 = null;
    var spanned: ?usize = null;
    while (try it.nextRun()) |run| {
        if (previous) |p| {
            if (p == run.value) {
                std.debug.print("two adjacent runs of {d} at row {d}\n", .{ p, at });
                return error.TestUnexpectedResult;
            }
        }
        if (run.count == 0) return error.TestUnexpectedResult;
        // The rows behind the run are the model's, which is what says a
        // coalesced run neither swallowed a row it should not have nor left
        // one behind.
        for (0..run.count) |k| {
            if (built.model.items[at + k] != run.value) {
                std.debug.print("run at {d} of {d}x{d}, the model says {d}\n", .{
                    at, run.count, run.value, built.model.items[at + k],
                });
                return error.TestUnexpectedResult;
            }
        }
        // The run that reaches across the first slab boundary is the one the
        // edit made: the row it left behind in the first slab and the rows the
        // second slab opens with are one run, not two.
        if (at <= built.boundary - 1 and built.boundary - 1 < at + run.count) {
            spanned = run.count;
        }
        at += run.count;
        previous = run.value;
    }
    try testing.expectEqual(built.model.items.len, at);
    try testing.expectEqual(built.model.items.len, it.pos());
    // The run that reaches across the boundary is three rows: the one the
    // edit wrote on the far side of it plus the two the second slab held.
    if (spanned) |n| {
        // **Had the two runs stayed apart, this would be one and three.**
        try testing.expectEqual(@as(usize, 3), n);
    } else {
        std.debug.print("no run reaches across the boundary at row {d}\n", .{built.boundary});
        return error.TestUnexpectedResult;
    }
}

//  The other direction of the same seam: after rows have been read past the
//  boundary, `next_run` hands back the rest of the run it stands in and does
//  **not** reach into the next slab (`tests.rs:4134-4146`).
test "next_run_cross_slab_mismatch_resets_decoder" {
    const gpa = testing.allocator;
    var col = try Column(u64, Rle(u64)).init(gpa);
    defer col.deinit();
    const model = try gpa.alloc(u64, 4000);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = @intCast(i / 5 + 1);
    try col.extend(gpa, model);
    if (col.slabCount() < 2) return error.TestUnexpectedResult;

    // Read the whole of the first slab one row at a time, so the cursor stands
    // on the first row of the second with its decoder already advanced.
    var it = try col.iterator();
    const boundary = col.slabAt(0).?.len;
    var i: usize = 0;
    while (i < boundary) : (i += 1) {
        try testing.expectEqual(model[i], (try it.next()).?);
    }
    try testing.expectEqual(boundary, it.pos());
    // The run there is the second slab's **own** first run: not the tail of
    // the run the cursor just finished, which ended a row earlier, and not
    // extended past its own length.
    const run = (try it.nextRun()).?;
    try testing.expectEqual(model[boundary], run.value);
    try testing.expectEqual(@as(usize, 5), run.count);
    try testing.expectEqual(boundary + 5, it.pos());
    // And the walk continues from there with the model's values.
    var at = it.pos();
    while (try it.nextRun()) |r| {
        for (0..r.count) |k| {
            if (model[at + k] != r.value) return error.TestUnexpectedResult;
        }
        at += r.count;
    }
    try testing.expectEqual(model.len, at);
}

//  A prefix column's run walk is the same cursor with a running sum, so the
//  same seam has to coalesce and the sum has to come back through the merged
//  run's **final** row (`prefix.rs:929-933`).
test "prefix_next_run_merges_across_slabs" {
    const gpa = testing.allocator;
    var col = try Column(u32, Prefix(u32)).init(gpa);
    defer col.deinit();
    var model: std.ArrayList(u32) = .empty;
    defer model.deinit(gpa);
    for (0..400) |run| {
        for (0..2) |_| {
            const v: u32 = @intCast(run + 1);
            try col.append(gpa, v);
            try model.append(gpa, v);
        }
    }
    if (col.slabCount() < 2) return error.TestUnexpectedResult;
    const boundary = col.slabAt(0).?.len;
    const across = model.items[boundary];
    try col.splice(gpa, boundary - 1, 1, &.{across});
    try model.replaceRange(gpa, boundary - 1, 1, &.{across});
    if (col.slabCount() < 2) return error.TestUnexpectedResult;
    try expectSound(u32, Prefix(u32), &col);

    // The model's own running totals, so the sum a run reports has one.
    const sums = try gpa.alloc(i64, model.items.len + 1);
    defer gpa.free(sums);
    sums[0] = 0;
    for (model.items, 0..) |v, k| sums[k + 1] = sums[k] + @as(i64, v);

    var it = try col.prefixIter();
    var at: usize = 0;
    var previous: ?u32 = null;
    while (try it.nextRun()) |run| {
        if (previous) |p| {
            if (p == run.value.value) return error.TestUnexpectedResult;
        }
        // The run's reported total is the prefix through its **final** row,
        // which is what makes a coalesced run one step rather than two, and
        // the run's own value is the width of every row it covers.
        try testing.expectEqual(model.items[at], run.value.value);
        try testing.expectEqual(sums[at + run.count], run.value.total());
        at += run.count;
        previous = run.value.value;
    }
    try testing.expectEqual(model.items.len, at);
}

// ── The delta column's value search (`tests.rs:4407-4455`) ──────────────────
//
// A delta column's index carries a per-slab realized-value range, and
// `find_by_value` / `find_by_range` prune on it (`delta/indexed.rs:15-20`,
// `column.rs:1812-1823`). The op set walks `id_ctr` and `succ_ctr` with
// `findByRange` (`op_set.zig`, `op_iter.zig:1201`), so a pruning walk that
// drops a slab holding the value is an op that cannot be found.

/// Every row whose value is in `[lo, hi]`, found through the index.
fn deltaRangeRows(
    gpa: std.mem.Allocator,
    col: *const Column(u64, Delta(u64)),
    lo: i64,
    hi: i64,
    out: *std.ArrayList(usize),
) !void {
    var find = try col.findByRange(lo, hi);
    defer find.deinit();
    while (find.next()) |hit| {
        const slab = col.slabAt(hit.slab) orelse return error.InvalidValue;
        var it = try col.iterRange(.{
            .start = hit.items_before,
            .end = hit.items_before + slab.len,
        });
        var i: usize = 0;
        while (try it.next()) |v| {
            const at = hit.items_before + i;
            if (@as(i64, @intCast(v)) >= lo and @as(i64, @intCast(v)) < hi) {
                try out.append(gpa, at);
            }
            i += 1;
        }
    }
}

//  A delta column edited at random, then searched for every value and every
//  value range, against the same search done by hand (`tests.rs:4407-4455`).
//  `find_first` is upstream's third query and this port has no counterpart;
//  the first row a `find_by_value` walk reports **is** that answer, so it is
//  the same walk rather than a second one.
test "fuzz_indexed_delta_column" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x0DE1A);
    const rand = prng.random();
    for (0..8) |trial| {
        var col = try Column(u64, Delta(u64)).init(gpa);
        defer col.deinit();
        var model: std.ArrayList(u64) = .empty;
        defer model.deinit(gpa);
        // **Every fourth insert is three copies of one value**, because a
        // delta column's runs are runs of equal *differences*: a run of
        // three equal values is two differences of zero behind each other,
        // which is a repeat run, and a column of values drawn from five
        // hundred alternatives has almost no two rows equal beside each
        // other — so it canonically groups into **one literal run**,
        // however long it is, and never reaches a second slab whatever the
        // run budget is. Three copies are the shortest sequence that puts a
        // repeat run behind the insert, and the value itself still comes
        // from the wide alphabet the searches below walk.
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
        if (col.slabCount() < 2) {
            std.debug.print("trial {d}: {d} rows of delta hold {d} slab(s)\n", .{
                trial, model.items.len, col.slabCount(),
            });
            return error.TestUnexpectedResult;
        }
        try expectSound(u64, Delta(u64), &col);

        var target: u64 = 0;
        while (target < 500) : (target += 97) {
            var got: std.ArrayList(usize) = .empty;
            defer got.deinit(gpa);
            var find = try col.findByValue(@intCast(target));
            defer find.deinit();
            while (find.next()) |hit| {
                const slab = col.slabAt(hit.slab) orelse return error.InvalidValue;
                var it = try col.iterRange(.{
                    .start = hit.items_before,
                    .end = hit.items_before + slab.len,
                });
                var i: usize = 0;
                while (try it.next()) |v| {
                    if (v == target) try got.append(gpa, hit.items_before + i);
                    i += 1;
                }
            }
            var want: std.ArrayList(usize) = .empty;
            defer want.deinit(gpa);
            for (model.items, 0..) |v, k| {
                if (v == target) try want.append(gpa, k);
            }
            if (!std.mem.eql(usize, want.items, got.items)) {
                std.debug.print("trial {d}: find_by_value({d}) found {d} rows of {d}\n", .{
                    trial, target, got.items.len, want.items.len,
                });
                return error.TestUnexpectedResult;
            }
        }

        var lo: u64 = 0;
        while (lo < 500) : (lo += 111) {
            const hi = lo + 130;
            var got: std.ArrayList(usize) = .empty;
            defer got.deinit(gpa);
            try deltaRangeRows(gpa, &col, @intCast(lo), @intCast(hi), &got);
            var want: std.ArrayList(usize) = .empty;
            defer want.deinit(gpa);
            for (model.items, 0..) |v, k| {
                if (v >= lo and v < hi) try want.append(gpa, k);
            }
            if (!std.mem.eql(usize, want.items, got.items)) {
                std.debug.print("trial {d}: find_by_range({d}..{d}) found {d} rows of {d}\n", .{
                    trial, lo, hi, got.items.len, want.items.len,
                });
                return error.TestUnexpectedResult;
            }
        }

        // And the bytes it re-encodes to are the bytes it loaded.
        const bytes = try col.encode(gpa);
        defer gpa.free(bytes);
        var back = try Column(u64, Delta(u64)).load(gpa, bytes);
        defer back.deinit();
        const again = try back.encode(gpa);
        defer gpa.free(again);
        try testing.expectEqualSlices(u8, bytes, again);
    }
}

// ── Variable-width run payloads (`tests.rs:3277-3351`) ───────────────────────
//
// Upstream's two string cases exist to stress **byte-offset arithmetic over a
// literal run whose values are not the same width**: a splice at position `k`
// has to find where the `k`-th value ends, and with fixed-width payloads that
// is `k * width` and with variable ones it is a walk
// (`tests.rs:3277-3290`, `:3324-3351`).
//
// The port's RLE payload is LEB128, whose width is one byte below 128, two
// below 16384 and so on — **so the run payloads are already variable width on
// the port's real representation**, and that is what this case exercises.
//
// The **length-prefixed byte payload** upstream packs for `String` and
// `Vec<u8>` (`lib.rs:696-770`) is a second, independent source of width
// variation, and it is exercised too: `Rle([]const u8)` and
// `RleUtf8(Nullable)` are real payload types and the two string cases are
// declared under their upstream names above this section —
// `string_splice_at_literal_repeat_boundary` and
// `string_splice_variable_length_values` — over
// `Column([]const u8, RleUtf8(false))`. This block is **kept** rather than
// folded into them because it pins the *integer* column's arithmetic, which
// the string cases do not reach.

//  A literal run of five distinct values whose LEB128 payloads are one, two,
//  three, two and four bytes, followed by a repeat run. Every splice position,
//  an insert, a delete and both directions of the literal/repeat seam.
test "splice_over_mixed_width_payloads" {
    const gpa = testing.allocator;
    // 2_500_000 and not 2_000_000 for the fourth width: a ULEB128 count
    // is one byte below 2^7, two below 2^14 and three below 2^21, so
    // 2_000_000 packs into **three** and the run would have held no
    // four-byte payload at all (`leb128.zig:55`).
    const initial = [_]u64{ 1, 200, 70000, 5000, 2_500_000, 9, 9, 9 };
    var base = try Column(u64, Rle(u64)).init(gpa);
    defer base.deinit();
    try base.extend(gpa, &initial);
    try validateRleColumn(Rle(u64), &base);

    // The payloads really are of different widths, which is what makes the
    // offsets non-trivial: 1 packs into one byte, 2_500_000 into four
    // (`leb128.zig:55`).
    for ([_]usize{ 1, 2, 3, 2, 4 }, initial[0..5]) |w, v| {
        if (leb128.unsignedSize(v) != w) {
            std.debug.print("value {d} packs into {d} byte(s), the case says {d}\n", .{
                v, leb128.unsignedSize(v), w,
            });
            return error.TestUnexpectedResult;
        }
    }

    for (0..initial.len + 1) |pos| {
        var c = try cloneU64(gpa, &base);
        defer c.deinit();
        // A wide value inserted into a narrow run, and a narrow one into a
        // wide run.
        try c.splice(gpa, pos, 0, &.{400_000});
        try validateRleColumn(Rle(u64), &c);
        try testing.expectEqual(initial.len + 1, c.len());

        var d = try cloneU64(gpa, &base);
        defer d.deinit();
        try d.splice(gpa, pos, 0, &.{3});
        try validateRleColumn(Rle(u64), &d);
    }

    for (0..initial.len) |pos| {
        var c = try cloneU64(gpa, &base);
        defer c.deinit();
        try c.removeN(gpa, pos, 1);
        try validateRleColumn(Rle(u64), &c);
        try testing.expectEqual(initial.len - 1, c.len());
    }

    // Replacing the repeat's value with one of the literal's joins two runs
    // of different widths, and replacing a literal with the repeat's value
    // moves the seam the other way. Both have to leave a canonical encoding.
    {
        var c = try cloneU64(gpa, &base);
        defer c.deinit();
        try c.splice(gpa, 5, 1, &.{70000});
        try validateRleColumn(Rle(u64), &c);
        const got = try c.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, &.{ 1, 200, 70000, 5000, 2_500_000, 70000, 9, 9 }, got);
    }
    {
        var c = try cloneU64(gpa, &base);
        defer c.deinit();
        try c.splice(gpa, 4, 1, &.{9});
        try validateRleColumn(Rle(u64), &c);
        const got = try c.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, &.{ 1, 200, 70000, 5000, 9, 9, 9, 9 }, got);
    }
    // A delete across the seam, which is upstream's "delete across the
    // literal/repeat boundary" (`tests.rs:3345-3351`).
    {
        var c = try cloneU64(gpa, &base);
        defer c.deinit();
        try c.splice(gpa, 2, 3, &.{});
        try validateRleColumn(Rle(u64), &c);
        const got = try c.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, &.{ 1, 200, 9, 9, 9 }, got);
    }
}

// ── A run sequence that is canonical and is not a column ────────────────────
//
// **A cross-codec load used to be held here and is not.** The claim was that
// one codec's bytes read under another either refuse or answer different
// values, and it needed this port's runtime codec parameter to say at all:
// upstream's `Column<T>` has none — this file says so three times, where it
// excludes upstream's own codec comparison for exactly that reason
// (`string_and_bool_columns`, `string_bool_delta_prefix_columns`,
// `prefix_column`: the other codec is upstream's test-local `BeLen`,
// `tests.rs:5420-5431`, and this port "has exactly one integer packing and
// no codec parameter"). The header's own citation does not rescue it: the
// lines it named, `tests.rs:5478-5495`, are the union of the three
// **prefix-column load** cases directly above it
// (`prefix_column_load_with_empty_and_fill`, `:5474-5479`;
// `prefix_column_load_with_roundtrip`, `:5481-5486`;
// `prefix_load_rejects_non_canonical_input`, `:5490-5495`). So the case was
// port-only, and its distinguishing assertion was the incidental
// codec-parameter overlap rather than a consumer invariant. The part of it
// that did not need the port's codec parameter is below.
//
// **The boundary is the sum, and the load is where it is met.** The bytes are
// one repeat run — a signed count and one signed payload — which is the
// canonical form and validates as one, so the *run sequence* is not what
// refuses. A delta column's index carries the running value, so building it
// realizes the rows (`weightOf` → `accumulate` → `addChecked`, which is
// `error.Overflow` rather than a wrap), and the load answers before the
// column exists. That is upstream's own arrangement: `DeltaColumn::<u32>::load`
// over bytes whose realized value leaves the element's own domain is an
// error, not a column a later read trips over (`delta/mod.rs:2169-2180`).
// The two cases below differ **only in the run count**, so what decides is the
// row that leaves the domain and not the shape of the bytes. A delta column
// is `Rle<Option<i64>>` on the wire (`lib.rs:406-437`), so this is the
// boundary reached without reading a foreign codec's bytes at all.
test "a delta column refuses bytes whose running sum leaves i64" {
    const gpa = testing.allocator;
    const DCol = Column(u64, Delta(u64));
    // The same canonical repeat run twice, over the same payload. The payload
    // is the canonical signed LEB128 for 4_000_000_000_000_000_001
    // (`0x3782DACE9D900001`), and it was written out rather than produced by
    // this tree's own LEB128 writer on purpose: a fixture generated by the code
    // under test cannot catch that code. Row 0 is therefore
    // 4_000_000_000_000_000_001 and row 1 is 8_000_000_000_000_000_002 — both
    // inside i64 — and the third is 12_000_000_000_000_000_003, which no i64
    // holds. `expectModel` below names the decoded value, so a mistyped payload
    // is caught by the assertion rather than by the reader's charity.
    const two = &[_]u8{ 2, 0x81, 0x80, 0xc0, 0xec, 0xe9, 0xd9, 0xb6, 0xc1, 0x37 };
    const three = &[_]u8{ 3, 0x81, 0x80, 0xc0, 0xec, 0xe9, 0xd9, 0xb6, 0xc1, 0x37 };
    // Canonical first: the refusal below is about the sum, so both have to be
    // run sequences the canonicality check accepts.
    try RleOption(i64).canonicalSlab(two);
    try RleOption(i64).canonicalSlab(three);

    // Two rows realize: the column exists, holds both of them, and reads back
    // the running values the run describes.
    var col = try DCol.load(gpa, two);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 2), col.len());
    try expectModel(u64, Delta(u64), &col, &.{ 4_000_000_000_000_000_001, 8_000_000_000_000_000_002 });

    // One row further and the running value leaves i64, and the refusal is
    // the load's. There is no column to hand back whose first rows are
    // readable and whose later ones are not: a caller cannot tell a column
    // that stops short of its declared length from one that was cut, and
    // both would look like a shorter column rather than a refusal.
    try testing.expectError(error.Overflow, DCol.load(gpa, three));
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **A truncated column load is refused or shortened, and the port's test
//   says which, where upstream's names neither.** Upstream's
//   `load_truncated_data_is_error` asserts the *shape* of the answer and not
//   its identity: it takes `&bytes[..1]`, and if the load happens to succeed
//   it only requires that the column is shorter
//   (`tests.rs:1891-1899`, `if let Ok(loaded) = &result { assert!(loaded.len() < col.len()) }`).
//   The port's case for the same column names `error.LengthExceedsInput` at
//   every strict prefix, which is a stronger assertion than upstream's and is
//   true here: the column is one run, so every strict prefix cuts that run
//   in half and the reference refuses by handing an empty slice to the value
//   reader (`rle/decoder.rs:228-232`). The error *name* is a port choice —
//   upstream reports a `PackError` and the name is not part of the wire
//   contract — so the strengthening is about the property, not about the
//   spelling.
//
// * **A prefix that ends a run whole is a shorter column, in both trees, and
//   the port now pins it.** With `remaining == 0` the reference's decoder
//   takes the empty-slice arm and stops (`rle/decoder.rs:233-234`), so a
//   run-boundary prefix decodes as the runs it ends and nothing more. This
//   is why the single-run column above cannot reach the "shorter column"
//   arm, and why `load_truncated_at_a_run_boundary_is_a_shorter_column` uses
//   a column with three runs. It pins two things upstream's shape assertion
//   does not: that a strict prefix is *strictly* shorter, and that a
//   non-empty prefix is never an empty column. The second is the load-bearing
//   one — an empty column is indistinguishable from an absent one, and a
//   caller that is handed one cannot tell "this column was cut" from "this
//   column is empty".
//
// * **What refuses a truncated column in a document is the row count, not the
//   column load, and that is upstream's arrangement too.** `Column.load` is
//   reached with a byte span the document already bounds
//   (`opset/columns.zig:1486`, `:1499`, every `loadLen` / `loadFilled` call
//   goes through `LoadOpts::with_length`, `column.rs:1156-1170`), and the
//   length check is what turns a run-boundary prefix into a refusal
//   (`loadWith` → `error.InvalidValue`). A declared length the buffer cannot
//   hold is refused earlier still, before it is used to size anything
//   (`storage/parse.zig:234`, `:247`). So the format layer and the column
//   layer are not in disagreement: the lower one bounds the bytes, the
//   higher one decodes them, and the *count* is the invariant that spans
//   both. A truncation that no caller holds to a count is a shorter column,
//   which is what the reference does too.

// ── Byte payloads: the columns that hold a variable-width value ─────────────
//
// A byte value's wire form is an unsigned LEB128 length followed by that
// many raw bytes (`lib.rs:696-770`), so one column's values are not all
// the same width and the byte-offset arithmetic every splice does has to
// find where each value ends rather than multiply. Everything below is a
// real `Column` over that payload.
//
// `RleUtf8` is the byte codec plus the UTF-8 check upstream's
// `RleValue for String` makes on every read (`lib.rs:700-709`), so a text
// column refuses bytes that are not text and a byte column keeps them.
// `Rle`/`RleOption` are the same wire with no such rule.

/// A text column: `Column<String>`, whose values must be UTF-8.
const StrCol = Column([]const u8, RleUtf8(false));
/// A nullable text column: `Column<Option<String>>`.
const OptStrCol = Column(?[]const u8, RleUtf8(true));
/// A byte column: `Column<Vec<u8>>`, which keeps any bytes at all.
const BytesCol = Column([]const u8, Rle([]const u8));
/// A nullable byte column: `Column<Option<Vec<u8>>>`.
const OptBytesCol = Column(?[]const u8, RleOption([]const u8));

fn textEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn optTextEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Holds a byte-valued column to `model`, by content.
///
/// The generic `expectModel` compares elements with `expectEqual`, which
/// for a slice is a comparison of slice headers. A value read out of a slab
/// borrows that slab's bytes, so two equal values never share a header —
/// the comparison has to be by content, and an absent value has to stay
/// distinct from an empty one.
fn expectBytesValues(
    comptime C: type,
    col: *const C,
    model: []const C.Value,
    comptime eql: fn (a: C.Value, b: C.Value) bool,
) !void {
    try testing.expectEqual(model.len, col.len());
    try testing.expectEqual(model.len == 0, col.isEmpty());
    for (model, 0..) |want, i| {
        const got = (try col.get(i)) orelse {
            std.debug.print("no value at {d}\n", .{i});
            return error.TestUnexpectedResult;
        };
        if (!eql(want, got)) {
            // **Both sides are printed, not just the row.** "row 62 is not
            // the value the model has" names the position and nothing about
            // the disagreement, and the position is the one thing the model
            // already agrees about — the whole question is *what* the two
            // differ by. The bytes are borrowed from the column and from the
            // model, both of which outlive this print.
            // The value is a byte slice for this helper, optionally nullable:
            // a string column's value is `[]const u8`, a nullable string
            // column's is `?[]const u8`. The null arm is only reachable for
            // the latter, so it is named at comptime rather than with an
            // `orelse` that does not type-check on the non-nullable
            // instantiation.
            const render = if (@typeInfo(C.Value) == .optional)
                struct {
                    fn f(v: C.Value) []const u8 {
                        return v orelse "<null>";
                    }
                }.f
            else
                struct {
                    fn f(v: C.Value) []const u8 {
                        return v;
                    }
                }.f;
            std.debug.print(
                "row {d}: column has '{s}', the model has '{s}'\n",
                .{ i, render(got), render(want) },
            );
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect((try col.get(model.len)) == null);

    var it = try col.iterator();
    var k: usize = 0;
    while (try it.next()) |v| {
        if (k >= model.len) return error.TestUnexpectedResult;
        if (!eql(model[k], v)) {
            std.debug.print("row {d} is not the value the model has on the walk\n", .{k});
            return error.TestUnexpectedResult;
        }
        k += 1;
    }
    try testing.expectEqual(model.len, k);
}

/// The same, and the column's bytes loaded back: a byte column's save and
/// load is the round trip a document makes, and the values have to come
/// back out of the *packed* bytes rather than out of the slab they came
/// from.
fn expectBytesRoundTrip(
    comptime C: type,
    col: *const C,
    model: []const C.Value,
    comptime eql: fn (a: C.Value, b: C.Value) bool,
) !void {
    try expectBytesValues(C, col, model, eql);
    const gpa = testing.allocator;
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    var back = try C.load(gpa, bytes);
    defer back.deinit();
    try expectBytesValues(C, &back, model, eql);
    const again = try back.encode(gpa);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

test "string_basic" {
    // `tests.rs`. Two distinct values, so they land in one literal run and
    // the column has one run of two payloads whose widths differ.
    const gpa = testing.allocator;
    var col = try StrCol.init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, &[_][]const u8{ "hello", "world" });
    try expectBytesRoundTrip(StrCol, &col, &.{ "hello", "world" }, textEql);
}

test "insert_str_into_string_column" {
    // `tests.rs`. Rows land one at a time, so each append is a splice at
    // the end — the case that puts a value in front of nothing and then
    // one in front of it.
    const gpa = testing.allocator;
    var col = try StrCol.init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, &[_][]const u8{"hello"});
    try col.splice(gpa, 1, 0, &[_][]const u8{"world"});
    // Owned still works: a byte payload is borrowed, so the column has to
    // have copied it into its own slab before this line returns.
    try col.splice(gpa, 2, 0, &[_][]const u8{"owned"});
    try expectBytesRoundTrip(StrCol, &col, &.{ "hello", "world", "owned" }, textEql);
}

test "insert_option_str_into_nullable_string_column" {
    // `tests.rs`. An absent value rides in the run header, so a nullable
    // text column is one wire with two kinds of run.
    const gpa = testing.allocator;
    var col = try OptStrCol.init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, &[_]?[]const u8{"hello"});
    try col.splice(gpa, 1, 0, &[_]?[]const u8{null});
    try col.splice(gpa, 2, 0, &[_]?[]const u8{"world"});
    try expectBytesRoundTrip(OptStrCol, &col, &[_]?[]const u8{ "hello", null, "world" }, optTextEql);
}

test "insert_slice_into_bytes_column" {
    // `tests.rs`. A byte column keeps bytes that are not text at all, which
    // is the whole difference between `Rle` and `RleUtf8`.
    const gpa = testing.allocator;
    var col = try BytesCol.init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, &[_][]const u8{ "hello", &[_]u8{ 1, 2, 3 } });
    try expectBytesRoundTrip(BytesCol, &col, &.{ "hello", &[_]u8{ 1, 2, 3 } }, textEql);
}

test "insert_option_slice_into_nullable_bytes_column" {
    // `tests.rs`. Present, absent, present — the three shapes a nullable
    // byte column has to tell apart, with an absent value distinct from an
    // empty one.
    const gpa = testing.allocator;
    var col = try OptBytesCol.init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, &[_]?[]const u8{ "hello", null, "bare" });
    try expectBytesRoundTrip(OptBytesCol, &col, &[_]?[]const u8{ "hello", null, "bare" }, optTextEql);
    // An empty payload is a value, not an absence, and the two are told
    // apart by the run header rather than by the payload.
    try col.splice(gpa, 3, 0, &[_]?[]const u8{""});
    try expectBytesRoundTrip(OptBytesCol, &col, &[_]?[]const u8{ "hello", null, "bare", "" }, optTextEql);
}

test "insert_string_ref_via_deref" {
    // `tests.rs`. Upstream's `&String` derefs to `&str`; here the payload
    // *is* a slice, so the call is the same borrowing. What the case is
    // really for is that the column owns its bytes afterwards.
    const gpa = testing.allocator;
    var text = "hello".*;
    var col = try StrCol.init(gpa);
    defer col.deinit();
    try col.splice(gpa, 0, 0, &[_][]const u8{text[0..]});
    text[0] = 'j';
    // The column kept its own copy: the caller's buffer is gone from it.
    try expectBytesValues(StrCol, &col, &.{"hello"}, textEql);
}

test "column_string_from_iterator" {
    // `tests.rs`. Built straight from values rather than by splicing, which
    // here is the streaming encoder's job.
    const gpa = testing.allocator;
    var col = try StrCol.fromValues(gpa, &.{ "hello", "world" }, default_max_segments);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 2), col.len());
    try expectBytesRoundTrip(StrCol, &col, &.{ "hello", "world" }, textEql);
}

test "iter_string" {
    // `tests.rs`. The cursor yields borrowed windows on the slab; what the
    // case holds is that they are the right bytes.
    const gpa = testing.allocator;
    var col = try StrCol.fromValues(gpa, &.{ "hello", "world", "hello" }, default_max_segments);
    defer col.deinit();
    const want = [_][]const u8{ "hello", "world", "hello" };
    var it = try col.iterator();
    for (want) |w| {
        const got = (try it.next()) orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, w, got)) return error.TestUnexpectedResult;
    }
    try testing.expect((try it.next()) == null);
}

test "load_roundtrip_string" {
    // `tests.rs`. Save packs the payloads behind length prefixes and load
    // unpacks them, so a value read back is a window on the *loaded* slab.
    const gpa = testing.allocator;
    var col = try StrCol.fromValues(gpa, &.{ "hello", "world", "foo" }, default_max_segments);
    defer col.deinit();
    try expectBytesRoundTrip(StrCol, &col, &.{ "hello", "world", "foo" }, textEql);
}

test "load_roundtrip_nullable_string" {
    // `tests.rs`. The absent row has no payload, so it is the header that
    // carries it and the round trip has to keep the two apart.
    const gpa = testing.allocator;
    var col = try OptStrCol.fromValues(
        gpa,
        &[_]?[]const u8{ "hello", null, "world" },
        default_max_segments,
    );
    defer col.deinit();
    try expectBytesRoundTrip(OptStrCol, &col, &[_]?[]const u8{ "hello", null, "world" }, optTextEql);
}

test "load_roundtrip_bytes" {
    // `tests.rs`. The byte column's round trip, with payloads that are not
    // text.
    const gpa = testing.allocator;
    var col = try BytesCol.fromValues(
        gpa,
        &[_][]const u8{ &[_]u8{ 1, 2, 3 }, &[_]u8{ 4, 5 }, &[_]u8{6} },
        default_max_segments,
    );
    defer col.deinit();
    try expectBytesRoundTrip(
        BytesCol,
        &col,
        &[_][]const u8{ &[_]u8{ 1, 2, 3 }, &[_]u8{ 4, 5 }, &[_]u8{6} },
        textEql,
    );
}

test "splice_str_items" {
    // `tests.rs`. A splice inside a literal run whose payloads are three,
    // one and one bytes wide: the offsets the case exists for are the ones
    // that have to be found rather than multiplied.
    const gpa = testing.allocator;
    var col = try StrCol.fromValues(
        gpa,
        &[_][]const u8{ "a", "b", "c", "d", "e" },
        default_max_segments,
    );
    defer col.deinit();
    try col.splice(gpa, 1, 2, &[_][]const u8{ "x", "y", "z" });
    try testing.expectEqual(@as(usize, 6), col.len());
    try expectBytesRoundTrip(StrCol, &col, &.{ "a", "x", "y", "z", "d", "e" }, textEql);
}

test "splice_option_str_items" {
    // `tests.rs`. The same splice over a nullable column, where one of the
    // inserted values is absent and so has no payload at all.
    const gpa = testing.allocator;
    var col = try OptStrCol.init(gpa);
    defer col.deinit();
    var five = [_]?[]const u8{"x"};
    try col.splice(gpa, 0, 0, five[0..]);
    try col.extend(gpa, five[0..]);
    try col.extend(gpa, five[0..]);
    try col.extend(gpa, five[0..]);
    try col.extend(gpa, five[0..]);
    try col.splice(gpa, 1, 2, &[_]?[]const u8{ "new", null });
    try expectBytesRoundTrip(
        OptStrCol,
        &col,
        &[_]?[]const u8{ "x", "new", null, "x", "x" },
        optTextEql,
    );
}

test "scope_to_value_strings" {
    // `tests.rs`. The sorted scan over a nullable text column. The runs are
    // found by *content*, and the target that is one byte short of a run's
    // first character sorts before it and so lands in the gap.
    const gpa = testing.allocator;
    var col = try OptStrCol.fromValues(
        gpa,
        &[_]?[]const u8{ "aaa", "aaa", "bbb", "bbb", "bbb", "ccc" },
        default_max_segments,
    );
    defer col.deinit();
    const whole = RowRange{ .start = 0, .end = col.len() };
    // The targets are named as nullable values because the column's value
    // type is: an absent row has to be searchable for too, and that is the
    // same scan.
    const aaa: ?[]const u8 = "aaa";
    const bbb: ?[]const u8 = "bbb";
    const ccc: ?[]const u8 = "ccc";
    const ddd: ?[]const u8 = "ddd";
    const aab: ?[]const u8 = "aab";
    try expectScope(.{ .start = 0, .end = 2 }, try col.scopeToValue(aaa, whole));
    try expectScope(.{ .start = 2, .end = 5 }, try col.scopeToValue(bbb, whole));
    try expectScope(.{ .start = 5, .end = 6 }, try col.scopeToValue(ccc, whole));
    try expectScope(.{ .start = 6, .end = 6 }, try col.scopeToValue(ddd, whole));
    try expectScope(.{ .start = 2, .end = 2 }, try col.scopeToValue(aab, whole));
}

test "a_text_column_refuses_bytes_that_are_not_text" {
    // The byte codec and the text codec are the same wire, so the bytes a
    // byte column writes are exactly the bytes a text column refuses: the
    // one difference between them is observable, and it is a refusal
    // rather than a value that comes back wrong (`lib.rs:705-707`).
    const gpa = testing.allocator;
    var bytes_col = try BytesCol.init(gpa);
    defer bytes_col.deinit();
    // A lone continuation byte: not UTF-8 under any reading.
    try bytes_col.splice(gpa, 0, 0, &[_][]const u8{&[_]u8{0x80}});
    const bytes = try bytes_col.encode(gpa);
    defer gpa.free(bytes);
    // The byte column loads its own bytes.
    var same = try BytesCol.load(gpa, bytes);
    defer same.deinit();
    try testing.expectEqual(@as(usize, 1), same.len());
    // The text column does not.
    try testing.expectError(error.InvalidUtf8, StrCol.load(gpa, bytes));
    // And a nullable text column refuses them the same way.
    try testing.expectError(error.InvalidUtf8, OptStrCol.load(gpa, bytes));
}

// ── Streaming encode and incremental load ───────────────────────────────────

/// `n` values from `f`, for the cases that want a column big enough to cut.
fn manyU64(gpa: std.mem.Allocator, n: usize, f: fn (usize) u64) ![]u64 {
    const out = try gpa.alloc(u64, n);
    for (out, 0..) |*v, i| v.* = f(i);
    return out;
}

/// A run of thirteen, repeating: every run is a repeat run.
fn modThirteen(i: usize) u64 {
    return @as(u64, @intCast(i % 13));
}

/// `i * 3`, strictly increasing: every value its own literal run's item.
fn triple(i: usize) u64 {
    return @as(u64, @intCast(i * 3));
}

/// `i + 1`, for the prefix column whose totals are known.
fn oneMore(i: usize) u64 {
    return @as(u64, @intCast(i + 1));
}

/// `(i / 5) % 5`: five copies of each value, a column of short repeat runs
/// and **many of them**, for one cut over and over.
///
/// `i % 5` was here and is not what the case wanted: every row of it
/// differs from the row in front of it, so it canonically groups into one
/// literal run — a single slab however small the run budget is — and a
/// column that is one slab has no cut for a partial load to cut at. The
/// run budget bounds runs, not rows, so a generator has to make runs
/// (`encoder_into_column_direct_matches_load` says the same about its own).
fn modFive(i: usize) u64 {
    return @as(u64, @intCast((i / 5) % 5));
}

/// Runs of eight, for the range-chain case's 60 rows.
fn sevens(i: usize) u64 {
    return @as(u64, @intCast(i / 7));
}

/// Runs of four, for the touching-ranges case's 30 rows.
fn fours(i: usize) u64 {
    return @as(u64, @intCast(i / 4));
}

/// Runs of forty.
fn forties(i: usize) u64 {
    return @as(u64, @intCast(i / 40));
}

/// `(i * 7) / 40`, so the runs do not line up with the source's forty-run
/// boundaries and a cut lands where neither side agrees.
fn sevenTimesOverForties(i: usize) u64 {
    return @as(u64, @intCast((i * 7) / 40));
}

/// Runs of three around 9000, for a destination.
fn nineThousands(i: usize) u64 {
    return @as(u64, @intCast(9000 + i / 3));
}

/// Runs of three.
fn thirds(i: usize) u64 {
    return @as(u64, @intCast(i / 3));
}

/// Runs of nine.
fn nines(i: usize) u64 {
    return @as(u64, @intCast(i / 9));
}

/// Lengths one, two, three, one… for a prefix column whose slabs are cut
/// across runs of equal lengths.
fn oneTwoThree(i: usize) u64 {
    return @as(u64, @intCast(1 + i % 3));
}

test "encoder_into_column_direct_matches_load" {
    // `tests.rs`. Values appended one at a time at a budget of four runs
    // per slab, so the encoder rolls several slabs and `intoColumn` hands
    // them over without decoding anything.
    //
    // **Runs of three, because a cut is measured in runs.** A budget
    // bounds the runs a slab holds, and a sequence whose values are all
    // different is *one* literal run whatever the budget is: it fills one
    // slab however small the budget is, and a column built that way never
    // rolls at all. Three equal values in a row make a hundred runs out of
    // three hundred values, and every cut lands inside one.
    const gpa = testing.allocator;
    const vals = try manyU64(gpa, 300, thirds);
    defer gpa.free(vals);

    const Col = Column(u64, Rle(u64));
    var plain = try Col.fromValues(gpa, vals, default_max_segments);
    defer plain.deinit();
    const want = try plain.encode(gpa);
    defer gpa.free(want);

    var enc = Col.Encoder.init(gpa);
    defer enc.deinit();
    try enc.maxSegments(4);
    try enc.extend(vals);
    var col = try enc.intoColumn();
    defer col.deinit();

    // The rollover is the case under test, so it is checked rather than
    // assumed: one slab means the budget never cut, and the rest of the
    // case would be asserting against a column that never rolled.
    if (col.slabCount() <= 1) {
        std.debug.print("the encoder rolled {d} slab(s) for {d} values at a budget of four\n", .{ col.slabCount(), vals.len });
        return error.TestUnexpectedResult;
    }
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, vals, got);
    // The cut boundaries are invisible in the wire form: a column's save
    // coalesces them back into one canonical run sequence.
    const saved = try col.encode(gpa);
    defer gpa.free(saved);
    try testing.expectEqualSlices(u8, want, saved);
    // And the column it produced is structurally sound for later mutation.
    try col.splice(gpa, 150, 0, &.{999});
    try col.removeN(gpa, 10, 1);
    try testing.expectEqual(vals.len, col.len());
    try validateRleColumn(Rle(u64), &col);
}

test "encoder_save_after_rollover_matches_plain" {
    // `tests.rs`. `save` after the encoder has rolled slabs folds them
    // back into one canonical run sequence, so the bytes are the ones a
    // single-buffer encode would have produced.
    const gpa = testing.allocator;
    const vals = try manyU64(gpa, 200, modThirteen);
    defer gpa.free(vals);

    const Col = Column(u64, Rle(u64));
    var plain = try Col.fromValues(gpa, vals, default_max_segments);
    defer plain.deinit();
    const want = try plain.encode(gpa);
    defer gpa.free(want);

    var enc = Col.Encoder.init(gpa);
    defer enc.deinit();
    try enc.maxSegments(4);
    try enc.extend(vals);
    const got = try enc.save();
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, want, got);
}

test "string_encoder_into_column_direct" {
    // `tests.rs`. Byte payloads across slab cuts: every slab's tail
    // records the width of the last value of its last run, and with
    // variable widths those differ from slab to slab.
    const gpa = testing.allocator;
    // A pool of payloads of different widths, three rows each, so the
    // column holds repeat runs rather than one long literal: a cut is
    // measured in runs, and a sequence of values that are all different
    // is a single literal run that no budget cuts. Every cut then lands
    // inside a run of three, one or two rows in, and the slab it closes
    // ends on a literal run whose last value's width is the payload's
    // own — so the tails differ from slab to slab, which is the shape
    // this case is about.
    const pool = [_][]const u8{ "s", "se", "see", "seei", "seein", "seeing", "seeing!" };
    var vals: [80][]const u8 = undefined;
    for (&vals, 0..) |*v, i| v.* = pool[(i / 3) % pool.len];

    var enc = StrCol.Encoder.init(gpa);
    defer enc.deinit();
    try enc.maxSegments(4);
    for (vals) |v| try enc.append(v);
    var col = try enc.intoColumn();
    defer col.deinit();

    // Checked rather than assumed, for the same reason the integer case
    // checks it: one slab means no cut was ever made, and the tails this
    // case is about would all be one slab's.
    if (col.slabCount() <= 1) {
        std.debug.print("the encoder rolled {d} slab(s) for {d} payloads at a budget of four\n", .{ col.slabCount(), vals.len });
        return error.TestUnexpectedResult;
    }
    try expectBytesValues(StrCol, &col, &vals, textEql);
    try expectBytesRoundTrip(StrCol, &col, &vals, textEql);
}

test "bool_encoder_into_column_direct_matches_load" {
    // `tests.rs`. A boolean run stores no payload at all — only a count —
    // so a boolean encoder is the case where "direct" is most visible: the
    // slabs it hands over need no decode pass whatsoever, because there is
    // nothing to decode.
    //
    // **A budget of four over four hundred rows cuts this column a
    // hundred times**, and a boolean run's value is its *position* in the
    // run sequence, so a save has to write each run where its position
    // says it belongs: two runs of one value meeting across a cut are one
    // run again, written at the position the merged run takes, and the
    // bytes are the ones the plain column's save wrote (`bool.rs:784-824`
    // for the rule, `bool.rs:845-925` for the seam). A run count that
    // lost track of a boundary puts that run at the other parity, which is
    // a pad run in the middle of the sequence — and the values behind it
    // are then read as the other boolean than they are.
    const gpa = testing.allocator;
    const Col = Column(bool, Bool);
    const pattern = [_]bool{ true, true, false, true, false, false, false, true, true, true };
    const vals = try gpa.alloc(bool, 400);
    defer gpa.free(vals);
    for (vals, 0..) |*v, i| v.* = pattern[i % pattern.len];

    var plain = try Col.fromValues(gpa, vals, default_max_segments);
    defer plain.deinit();
    const want = try plain.encode(gpa);
    defer gpa.free(want);

    var enc = Col.Encoder.init(gpa);
    defer enc.deinit();
    try enc.maxSegments(4);
    try enc.extend(vals);
    var col = try enc.intoColumn();
    defer col.deinit();
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(bool, vals, got);
    const saved = try col.encode(gpa);
    defer gpa.free(saved);
    try testing.expectEqualSlices(u8, want, saved);
}

test "a nullable column's absent runs do not break its repeat runs" {
    // An absent run rides in the run header and carries no value, so it
    // separates two runs without either of them merging into the other:
    // rule 8 compares a run against the last *value-bearing* run, and an
    // absent run is not one (`rle/decoder.rs:438-497`). The grouping
    // therefore carries on across it, which is the shape an encoder that
    // flushed everything at an absent value gets wrong — it writes every
    // value behind the absent run as a literal run of its own, and a run
    // sequence of those is not canonical (rules 4 and 6).
    //
    // The bytes are written out here rather than compared against the
    // encoder's own answer, because the encoder is what is under test.
    const gpa = testing.allocator;
    const Codec = RleOption(u64);
    const Col = Column(?u64, Codec);
    const Case = struct { vals: []const ?u64, bytes: []const u8 };
    const cases = [_]Case{
        // repeat(3, 5) absent(1) repeat(2, 5) repeat(2, 6)
        .{ .vals = &.{ 5, 5, 5, null, 5, 5, 6, 6 }, .bytes = &.{ 3, 5, 0, 1, 2, 5, 2, 6 } },
        // absent(2) repeat(2, 1) absent(1) literal(2, [2, 300])
        .{ .vals = &.{ null, null, 1, 1, null, 2, 300 }, .bytes = &.{ 0, 2, 2, 1, 0, 1, 126, 2, 172, 2 } },
        // absent(1) repeat(2, 1) absent(2) literal(1, 2)
        .{ .vals = &.{ null, 1, 1, null, null, 2 }, .bytes = &.{ 0, 1, 2, 1, 0, 2, 127, 2 } },
    };
    for (cases) |c| {
        const got = try Codec.wireEncode(gpa, c.vals, false);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, c.bytes, got);
        // Two independent readers agree: the canonicality check takes
        // them, and the values they decode to are the ones they were
        // written from.
        try Codec.canonicalSlab(got);
        const back = try rle.RleOption(u64).decodeAll(got, gpa);
        defer gpa.free(back);
        try testing.expectEqualSlices(?u64, c.vals, back);

        // And the streaming encoder agrees, one value at a time and with
        // the values spread over several slabs. What it rolls is coalesced
        // back into one run sequence on the way out, and the loader is the
        // independent check on that: it refuses a column whose slabs were
        // written as literal runs of one.
        var enc = Col.Encoder.init(gpa);
        defer enc.deinit();
        try enc.maxSegments(4);
        try enc.extend(c.vals);
        var col = try enc.intoColumn();
        defer col.deinit();
        const values = try col.toSlice(gpa);
        defer gpa.free(values);
        try testing.expectEqualSlices(?u64, c.vals, values);
        const saved = try col.encode(gpa);
        defer gpa.free(saved);
        var reloaded = try Col.load(gpa, saved);
        defer reloaded.deinit();
        const again = try reloaded.toSlice(gpa);
        defer gpa.free(again);
        try testing.expectEqualSlices(?u64, c.vals, again);
    }
}

test "save_load_save_is_identity" {
    // `tests.rs`. Save, load, save: the second save is the first save's
    // bytes. A load cuts its slabs at half the budget, so this also holds
    // that the cut is invisible in the wire form.
    const gpa = testing.allocator;
    const shapes = [_][]const u64{
        &.{},
        &.{7},
        &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
        &.{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 },
        &.{ 1, 1, 2, 3, 3, 3, 4, 5, 5, 6, 7, 7, 7, 8 },
    };
    for (shapes) |vals| {
        const Col = Column(u64, Rle(u64));
        var col = try Col.fromValues(gpa, vals, default_max_segments);
        defer col.deinit();
        const once = try col.encode(gpa);
        defer gpa.free(once);
        var back = try Col.load(gpa, once);
        defer back.deinit();
        const twice = try back.encode(gpa);
        defer gpa.free(twice);
        try testing.expectEqualSlices(u8, once, twice);
    }
}

test "string_and_bool_columns" {
    // `tests.rs`. Upstream's second half is `assert_ne!` between two
    // *codecs* over the same values — `Column<String, BeLen>` against the
    // default — and `BeLen` is upstream's own test-local varint
    // (`tests.rs:5420-5431`); `bijou64`, the other one, is dead feature
    // code (`AGENTS.md:50-52`). This port has exactly one integer packing
    // and no codec parameter, so that half has no counterpart to compare.
    // What is left — the string and boolean columns round-tripping through
    // their own bytes — is real and is what is held here, on the byte
    // payload and on the boolean codec.
    const gpa = testing.allocator;
    const strings = [_][]const u8{ "alpha", "alpha", "beta", "gamma" };
    var scol = try StrCol.fromValues(gpa, &strings, default_max_segments);
    defer scol.deinit();
    try expectBytesRoundTrip(StrCol, &scol, &strings, textEql);

    const bools = [_]bool{ true, true, false, true, false, false, false, true };
    const BCol = Column(bool, Bool);
    var bcol = try BCol.fromValues(gpa, &bools, default_max_segments);
    defer bcol.deinit();
    try assertCol(bool, Bool, &bcol, &bools);
}

test "string_bool_delta_prefix_columns" {
    // `tests.rs`. The same four shapes with the other codec parameter, so
    // the same exclusion as `string_and_bool_columns`: the `assert_ne!`
    // between two codecs needs `BeLen`. The four columns themselves are
    // real, and this is where a byte column, a boolean column, a delta
    // column and a prefix column are each built, saved and loaded in one
    // place — which is also the only place the byte payload meets the
    // integer codecs they share a spine with.
    const gpa = testing.allocator;
    const strings = [_][]const u8{ "alpha", "alpha", "beta", "gamma" };
    var scol = try StrCol.fromValues(gpa, &strings, default_max_segments);
    defer scol.deinit();
    try expectBytesRoundTrip(StrCol, &scol, &strings, textEql);

    const bools = [_]bool{ true, true, false, true, false, false, false, true };
    const BCol = Column(bool, Bool);
    var bcol = try BCol.fromValues(gpa, &bools, default_max_segments);
    defer bcol.deinit();
    try assertCol(bool, Bool, &bcol, &bools);

    const values = try manyU64(gpa, 200, triple);
    defer gpa.free(values);

    const DCol = Column(u64, Delta(u64));
    var dcol = try DCol.fromValues(gpa, values, default_max_segments);
    defer dcol.deinit();
    try assertCol(u64, Delta(u64), &dcol, values);

    const PCol = Column(u64, Prefix(u64));
    var pcol = try PCol.fromValues(gpa, values, default_max_segments);
    defer pcol.deinit();
    try assertCol(u64, Prefix(u64), &pcol, values);
}

test "prefix_column" {
    // `tests.rs`. The values, and the prefix sums they answer with. The
    // `assert_ne!` against the other codec's bytes is excluded for the
    // reason `string_and_bool_columns` gives: the other codec is
    // upstream's test-local `BeLen`.
    const gpa = testing.allocator;
    const values = try manyU64(gpa, 99, oneMore);
    defer gpa.free(values);
    const PCol = Column(u64, Prefix(u64));
    var col = try PCol.fromValues(gpa, values, default_max_segments);
    defer col.deinit();
    try assertCol(u64, Prefix(u64), &col, values);
    // The prefix sums: the row whose running total crosses a target.
    var total: i64 = 0;
    for (values, 0..) |v, i| {
        try testing.expectEqual(total, try col.getPrefix(i));
        total += @intCast(v);
    }
    try testing.expectEqual(total, try col.getPrefix(values.len));
    try testing.expectEqual(@as(usize, 4950), @as(usize, @intCast(total)));
}

test "delta_column" {
    // `tests.rs`. The values and the save/load round trip. The
    // `assert_ne!` between two codecs' bytes is excluded for the reason
    // `string_and_bool_columns` gives.
    const gpa = testing.allocator;
    const values = try manyU64(gpa, 200, triple);
    defer gpa.free(values);
    const DCol = Column(u64, Delta(u64));
    var col = try DCol.fromValues(gpa, values, default_max_segments);
    defer col.deinit();
    try assertCol(u64, Delta(u64), &col, values);
    // A delta column's values are differences on the wire, so its bytes
    // are not its values: a run of equal values is a run of equal
    // *differences*, which is the whole reason the column exists.
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    // The wire is the *nullable* signed run-length format — a difference,
    // or an absent row in the run header — which is `RleOption`, not `Rle`.
    try RleOption(i64).canonicalSlab(bytes);
}

test "load_iter_partial_consume_then_error" {
    // `tests.rs`. One valid run followed by a malformed tail. The error
    // surfaces when the iterator *reaches* the malformed run, not before:
    // a caller that pulls the first run and never looks again is not told
    // about the bytes behind it, exactly as upstream's `LoadIter` behaves
    // (`column.rs:1872-1888`).
    const gpa = testing.allocator;
    const Col = Column(u64, Rle(u64));
    var col = try Col.fromValues(gpa, &.{ 5, 5, 5 }, default_max_segments);
    defer col.deinit();
    const good = try col.encode(gpa);
    defer gpa.free(good);

    // Every strict prefix of a well-formed encoding is a decode error, so
    // one byte of a good run header is the malformed case: a repeat header
    // with no value behind it.
    const bad = try gpa.alloc(u8, good.len + 1);
    defer gpa.free(bad);
    @memcpy(bad[0..good.len], good);
    bad[good.len] = 0x03;

    var iter = try Col.loadIter(gpa, bad, Col.LoadOpts.new());
    const first = try iter.tryNextRun();
    try testing.expect(first != null);
    if (first) |r| try testing.expectEqual(@as(usize, 3), r.count);
    // The tail is refused when it is reached, and the refusal is the
    // decoder's own rather than a named one: what matters is that the run
    // behind a header with no value behind it is an error, not a run.
    if (iter.tryNextRun()) |maybe| {
        _ = maybe;
        return error.TestUnexpectedResult;
    } else |_| {}

    // The same input with nothing malformed runs to the end and no
    // further.
    var ok = try Col.loadIter(gpa, good, Col.LoadOpts.new());
    const r = (try ok.tryNextRun()).?;
    try testing.expectEqual(@as(usize, 3), r.count);
    try testing.expectEqual(@as(u64, 5), r.value);
    try testing.expect((try ok.tryNextRun()) == null);
}

test "load_accumulates_prefix_weights_partial_consume" {
    // `tests.rs`. A consumer pulls some runs before `finalize`, and the
    // weights the index is built from are the ones measured as the slabs
    // were cut — not a second walk of the data. The proof is the prefix
    // sums, which come out of those weights.
    const gpa = testing.allocator;
    const vals = try manyU64(gpa, 2000, modFive);
    defer gpa.free(vals);
    const PCol = Column(u64, Prefix(u64));
    var original = try PCol.fromValues(gpa, vals, default_max_segments);
    defer original.deinit();
    const saved = try original.encode(gpa);
    defer gpa.free(saved);

    var iter = try PCol.loadIter(gpa, saved, PCol.LoadOpts.new().withMaxSegments(4));
    for (0..25) |_| _ = try iter.tryNextRun();
    var col = try iter.finalize();
    defer col.deinit();

    var running: i64 = 0;
    for (vals, 0..) |v, i| {
        var it = try col.prefixIter();
        it.setMax(i + 1);
        const pv = (try it.nth(i)).?;
        // The row's own value is the column's value type; the running total
        // is the index's `i64` prefix, and the two are different numbers
        // that must not be compared as one.
        try testing.expectEqual(v, pv.value);
        try testing.expectEqual(running + @as(i64, @intCast(v)), pv.total());
        running += @intCast(v);
    }
    // And the same column a plain load of the same bytes produces. **The
    // rows, not the slab count**: the two loads were given different run
    // budgets — four here, the default there — so they cut their slabs at
    // different places, and how many slabs either of them ends up with is
    // a decision of the budget rather than a thing about the column.
    var plain = try PCol.load(gpa, saved);
    defer plain.deinit();
    const theirs = try plain.toSlice(gpa);
    defer gpa.free(theirs);
    try testing.expectEqualSlices(u64, vals, theirs);
}

test "load_roundtrip_proptest_streaming" {
    // `tests.rs`, over a fixed sweep of the two axes rather than a
    // generator: a small slab budget and a column long enough to cut many
    // times, over optional values so null runs are in the stream.
    const gpa = testing.allocator;
    const Col = Column(?u64, RleOption(u64));
    const budgets = [_]usize{ 2, 3, 8, 32, 64 };
    for (budgets) |budget| {
        const vals = try gpa.alloc(?u64, 600);
        defer gpa.free(vals);
        for (vals, 0..) |*v, i| {
            v.* = if (i % 5 == 0) null else @as(?u64, @as(u64, @intCast(i % 50)));
        }
        var col = try Col.fromValues(gpa, vals, budget);
        defer col.deinit();
        const saved = try col.encode(gpa);
        defer gpa.free(saved);
        var back = try Col.loadWith(gpa, saved, Col.LoadOpts.new().withMaxSegments(budget));
        defer back.deinit();
        const got = try back.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(?u64, vals, got);
        // The bytes survive the round trip whatever the budget was.
        const again = try back.encode(gpa);
        defer gpa.free(again);
        try testing.expectEqualSlices(u8, saved, again);
    }
}

// ── The slab budget as a runtime value ──────────────────────────────────────

test "max_segments_one_rejected" {
    // `tests.rs`. Upstream asserts `max_segments >= 2` in
    // `Column::with_max_segments` (`column.rs:1126`) — and asserts, so the
    // case is `#[should_panic]`. This port refuses instead, because
    // `ParseError` is what every other boundary here reports and an
    // untrusted caller gets an error rather than a crash. The value it
    // refuses is the same: one, which halves to a cut target of zero.
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidValue, Column(u64, Rle(u64)).initWithBudget(gpa, 1));
    // Two is the minimum that works, and it is accepted.
    var ok = try Column(u64, Rle(u64)).initWithBudget(gpa, 2);
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 2), ok.maxSegmentsOf());
}

test "max_segments_one_rejected_at_load" {
    // `tests.rs`. The same floor on the load path
    // (`LoadOpts::with_max_segments`, `column.rs:1177`), refused before
    // any of the bytes are looked at.
    const gpa = testing.allocator;
    const Col = Column(u64, Rle(u64));
    const vals = try manyU64(gpa, 50, oneMore);
    defer gpa.free(vals);
    var col = try Col.fromValues(gpa, vals, default_max_segments);
    defer col.deinit();
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(
        error.InvalidValue,
        Col.loadWith(gpa, bytes, Col.LoadOpts.new().withMaxSegments(1)),
    );
    try testing.expectError(
        error.InvalidValue,
        Col.loadIter(gpa, bytes, Col.LoadOpts.new().withMaxSegments(1)),
    );
    // And a budget of two loads, and cuts the slabs at one run each.
    var tight = try Col.loadWith(gpa, bytes, Col.LoadOpts.new().withMaxSegments(2));
    defer tight.deinit();
    try testing.expectEqual(vals.len, tight.len());
    const segs = try tight.slabSegments(gpa);
    defer gpa.free(segs);
    for (segs) |n| try testing.expect(n <= 2 or n == 1);
}

// ── Ranges, runs and suspended cursors ──────────────────────────────────────

test "ranges_chains_windows" {
    // `tests.rs`. Several windows off one cursor, with an *empty* one in
    // the middle: an empty window contributes nothing and does not stop
    // the walk. And the same windows off a cursor that was born inside a
    // range.
    const gpa = testing.allocator;
    const Col = Column(u64, Rle(u64));
    const values = try manyU64(gpa, 60, sevens);
    defer gpa.free(values);
    var col = try Col.fromValues(gpa, values, default_max_segments);
    defer col.deinit();

    var want: std.ArrayList(u64) = .empty;
    defer want.deinit(gpa);
    for ([_]RowRange{ .{ .start = 2, .end = 5 }, .{ .start = 10, .end = 15 }, .{ .start = 31, .end = 50 } }) |r| {
        try want.appendSlice(gpa, values[r.start..r.end]);
    }

    const with_empty = [_]RowRange{
        .{ .start = 2, .end = 5 },
        .{ .start = 7, .end = 7 },
        .{ .start = 10, .end = 15 },
        .{ .start = 31, .end = 50 },
    };
    const without_empty = [_]RowRange{
        .{ .start = 2, .end = 5 },
        .{ .start = 10, .end = 15 },
        .{ .start = 31, .end = 50 },
    };

    var whole = try col.iterator();
    var chain = whole.ranges(&with_empty);
    const got = try chain.collect(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, want.items, got);

    // The same windows off a cursor born inside a range.
    var inside = try col.iterRange(.{ .start = 1, .end = 60 });
    var chain2 = inside.ranges(&without_empty);
    const got2 = try chain2.collect(gpa);
    defer gpa.free(got2);
    try testing.expectEqualSlices(u64, want.items, got2);

    // A window that goes backwards is refused rather than walked.
    var back = try col.iterator();
    var bad = back.ranges(&[_]RowRange{
        .{ .start = 10, .end = 15 },
        .{ .start = 2, .end = 5 },
    });
    _ = try bad.next();
    var refused = false;
    while (bad.next()) |_| {} else |_| refused = true;
    try testing.expect(refused);
}

//  A nullable column's item is still nullable. An absent **row** is a value
//  the column holds; only the end of a window is the absence of an item, and
//  the two are different answers that an adapter has to keep apart — naming
//  the payload alone cannot hold an absent row at all, and the op set's actor
//  and counter windows walk absent rows every time an actor is gone
//  (`columns.zig`, `shiftable`).
test "a nullable cursor keeps an absent row apart from the end of its windows" {
    const gpa = testing.allocator;
    const Col = Column(?u64, RleOption(u64));
    const model = [_]?u64{ null, 1, 1, null, null, 2, 3, null, null };
    var col = try Col.init(gpa);
    defer col.deinit();
    try col.extend(gpa, &model);

    // Two windows off one cursor, with the row between them outside both.
    const windows = [_]RowRange{ .{ .start = 0, .end = 5 }, .{ .start = 6, .end = 9 } };
    var ranged = (try col.iterator()).ranges(&windows);
    const got = try ranged.collect(gpa);
    defer gpa.free(got);
    // An absent row is a `null` **element** of the answer, not a short slice:
    // the eight rows inside the two windows all came back, four of them
    // absent, and only the ninth row — outside both windows — is missing.
    try testing.expectEqual(@as(usize, 8), got.len);
    try testing.expect(got[0] == null);
    try testing.expectEqual(@as(?u64, 1), got[1]);
    try testing.expectEqual(@as(?u64, 1), got[2]);
    try testing.expect(got[3] == null);
    try testing.expect(got[4] == null);
    try testing.expectEqual(@as(?u64, 3), got[5]);
    try testing.expect(got[6] == null);
    try testing.expect(got[7] == null);

    // The same column through the lookahead adapter, where the distinction
    // is the adapter's own: `peek` is null only once the inner cursor is
    // spent, and an absent row is a `null` *inside* that optional.
    var un = try Unshift(Col.Iterator).init(try col.iterator());
    try testing.expect(un.peek() != null);
    try testing.expect(un.peek().? == null);
    try testing.expectEqual(@as(?u64, null), (try un.next()).?);
    var i: usize = 1;
    while (i < model.len) : (i += 1) {
        try testing.expectEqual(model[i], (try un.next()).?);
    }
    // The walk ends on an absent value, which came back as one — the loop
    // above checked it against the model — and the call after it is the one
    // that says the window is spent.
    try testing.expect((try un.next()) == null);
    try testing.expect(un.peek() == null);
}

test "ranges_touching_equals_union" {
    // `tests.rs`. Two windows that touch are one window, whether the
    // adapter is over values or over runs — a run clipped at the boundary
    // re-merges in the splice encoder, so the two splices are the same
    // column.
    const gpa = testing.allocator;
    const Col = Column(u64, Rle(u64));
    const values = try manyU64(gpa, 30, fours);
    defer gpa.free(values);
    var col = try Col.fromValues(gpa, values, default_max_segments);
    defer col.deinit();

    const two_windows = [_]RowRange{
        .{ .start = 10, .end = 15 },
        .{ .start = 15, .end = 20 },
    };
    const one_window = [_]RowRange{.{ .start = 10, .end = 20 }};

    var it = try col.iterator();
    var split_win = it.ranges(&two_windows);
    const split = try split_win.collect(gpa);
    defer gpa.free(split);
    var it2 = try col.iterator();
    var union_win = it2.ranges(&one_window);
    const @"union" = try union_win.collect(gpa);
    defer gpa.free(@"union");
    try testing.expectEqualSlices(u64, @"union", split);

    const base = [_]u64{ 100, 200 };
    var a = try Col.fromValues(gpa, &base, default_max_segments);
    defer a.deinit();
    var b = try Col.fromValues(gpa, &base, default_max_segments);
    defer b.deinit();
    {
        var r1 = try col.iterator();
        var run_curs = r1.runs();
        var win1 = run_curs.ranges(&two_windows);
        const runs1 = try win1.collect(gpa);
        defer gpa.free(runs1);
        try a.spliceRuns(gpa, 1, 0, runs1);
    }
    {
        var r2 = try col.iterator();
        var run_curs2 = r2.runs();
        var win2 = run_curs2.ranges(&one_window);
        const runs2 = try win2.collect(gpa);
        defer gpa.free(runs2);
        try b.spliceRuns(gpa, 1, 0, runs2);
    }
    // Both splices hold the same rows between the two marker values, and
    // both produce the same bytes.
    var want: std.ArrayList(u64) = .empty;
    defer want.deinit(gpa);
    try want.append(gpa, 100);
    try want.appendSlice(gpa, values[10..20]);
    try want.append(gpa, 200);
    try assertCol(u64, Rle(u64), &a, want.items);
    try assertCol(u64, Rle(u64), &b, want.items);
    const ab = try a.encode(gpa);
    defer gpa.free(ab);
    const bb = try b.encode(gpa);
    defer gpa.free(bb);
    try testing.expectEqualSlices(u8, ab, bb);
}

test "prefix_iter_runs_splices" {
    // `tests.rs`. The prefix cursor over several windows, and the rows it
    // yields spliced into another prefix column. Two things are held: the
    // running totals stay absolute across the jumps (they belong to the
    // column, not to the window), and the spliced column answers with the
    // same totals.
    const gpa = testing.allocator;
    const PCol = Column(u64, Prefix(u64));
    const values = try manyU64(gpa, 20, oneMore);
    defer gpa.free(values);
    var src = try PCol.fromValues(gpa, values, default_max_segments);
    defer src.deinit();

    var it = try src.prefixIter();
    // The adapter is a value and `collect` walks it, so it is named: a
    // temporary cannot be handed a mutable pointer.
    var windowed_it = it.ranges(&[_]RowRange{
        .{ .start = 2, .end = 4 },
        .{ .start = 10, .end = 12 },
    });
    const windowed = try windowed_it.collect(gpa);
    defer gpa.free(windowed);

    // The totals are the source's, not a restart at each window: the
    // cursor carries the running sum across the jumps.
    var running: i64 = 0;
    for (values, 0..) |v, i| {
        const which: ?usize = if (i >= 2 and i < 4)
            i - 2
        else if (i >= 10 and i < 12)
            i - 10 + 2
        else
            null;
        if (which) |k| {
            const pv = windowed[k];
            try testing.expectEqual(v, pv.value);
            try testing.expectEqual(running + @as(i64, @intCast(v)), pv.total());
        }
        running += @intCast(v);
    }

    // And the same rows splice into a fresh prefix column with the same
    // totals, because a splice re-measures the slabs it rebuilds. Row `k` of
    // the result stands behind `k + 1` values, so the total asked for is the
    // one *at* that row — the prefix cursor's own rule, and the one the
    // window above reads its absolute totals through. Upstream asks the same
    // question once, at the last spliced row
    // (`dst.get_prefix(4)` over `[1, 3, 3, 10, 1]`, `tests.rs:1212`).
    const picked = [_]u64{ values[2], values[3], values[10], values[11] };
    var dest = try PCol.init(gpa);
    defer dest.deinit();
    try dest.splice(gpa, 0, 0, &picked);
    // `getPrefix(n)` is `runningAt(n)`: the sum of the first `n` rows, so it is
    // the total *at* row `n`, exclusive of it. That is why the value is added
    // before the question is asked and not after — asking it first compares the
    // total through row `k-1` against the total through row `k`.
    var total: i64 = 0;
    for (picked, 0..) |v, k| {
        total += @intCast(v);
        try testing.expectEqual(total, try dest.getPrefix(k + 1));
    }
    // The last of them is the whole column, and the spliced rows are the
    // source's own rows.
    try testing.expectEqual(total, try dest.getPrefix(dest.len()));
    // And the fixture is what the comment above says it is: four rows of the
    // source, summing to thirty.
    try testing.expectEqual(@as(i64, 30), total);
    try expectModel(u64, Prefix(u64), &dest, &picked);
}

test "splice_invalidates_a_suspended_iter" {
    // `tests.rs`. A cursor is suspended, the column is written, and the
    // snapshot refuses to resume: the row the cursor stood on may now be a
    // different row, and resuming would silently read the wrong one.
    const gpa = testing.allocator;
    const Col = Column(u64, Rle(u64));
    const vals = try manyU64(gpa, 100, oneMore);
    defer gpa.free(vals);
    var col = try Col.fromValues(gpa, vals, default_max_segments);
    defer col.deinit();

    var it = try col.iterator();
    _ = try it.next();
    const state = it.@"suspend"();
    // An unwritten column resumes, and from where it was left.
    var resumed = try state.tryResume(&col);
    try testing.expectEqual(@as(usize, 1), resumed.pos());
    try testing.expectEqual(@as(u64, 2), (try resumed.next()).?);

    const slabs_before = col.slabCount();
    try col.splice(gpa, 50, 1, &.{999});
    try testing.expectEqual(slabs_before, col.slabCount());

    try testing.expectError(error.InvalidValue, state.tryResume(&col));
    // And a fresh snapshot of the written column does resume.
    var again = try col.iterator();
    _ = try again.next();
    const state2 = again.@"suspend"();
    var resumed2 = try state2.tryResume(&col);
    try testing.expectEqual(@as(u64, 2), (try resumed2.next()).?);
}

// ── Copying between columns ─────────────────────────────────────────────────
//
// A copy has two strategies and one answer. `direct` reads the source's
// kept rows and splices them in; `invert` keeps the *source's* slabs,
// drops the gaps without decoding them, and splices the destination's
// surviving rows back around what is left. Which one runs is a cost
// decision and is unobservable — every case below holds both against the
// same model and against each other's bytes.

/// The values a copy of `splices` leaves in a destination of `dest_vals`,
/// given the source's values: for each point, the destination's rows up to
/// it, then the source's rows the point takes.
fn interleave(
    gpa: std.mem.Allocator,
    dest: []const u64,
    src: []const u64,
    splices: []const Column(u64, Rle(u64)).Splice,
) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    var prev: usize = 0;
    for (splices) |sp| {
        try out.appendSlice(gpa, dest[prev..sp.pos]);
        try out.appendSlice(gpa, src[sp.range.start..sp.range.end]);
        prev = sp.pos + sp.delete;
    }
    try out.appendSlice(gpa, dest[prev..]);
    return out.toOwnedSlice(gpa);
}

test "copy_ranges_strategies_agree" {
    // `tests.rs`. Positions, deletions and range shapes: touching,
    // clamped, and empty. Both strategies are held to the same values and
    // to the same bytes.
    const gpa = testing.allocator;
    const Col = Column(u64, Rle(u64));
    const src_vals = try manyU64(gpa, 3000, forties);
    defer gpa.free(src_vals);
    const dest_vals = [_]u64{ 500, 501, 502, 503 };

    const Case = struct { index: usize, del: usize, ranges: []const RowRange };
    const cases = [_]Case{
        .{ .index = 0, .del = 0, .ranges = &.{.{ .start = 0, .end = 3000 }} },
        // touching
        .{ .index = 2, .del = 0, .ranges = &.{ .{ .start = 0, .end = 1500 }, .{ .start = 1500, .end = 3000 } } },
        .{ .index = 4, .del = 0, .ranges = &.{ .{ .start = 10, .end = 900 }, .{ .start = 950, .end = 2900 } } },
        .{ .index = 1, .del = 2, .ranges = &.{ .{ .start = 0, .end = 40 }, .{ .start = 100, .end = 2000 }, .{ .start = 2500, .end = 3000 } } },
        // nothing to copy
        .{ .index = 2, .del = 2, .ranges = &.{} },
        .{ .index = 0, .del = 4, .ranges = &.{.{ .start = 5, .end = 6 }} },
        // clamped past the end
        .{ .index = 3, .del = 0, .ranges = &.{.{ .start = 2990, .end = 3100 }} },
    };

    for (cases) |c| {
        const norm = try Col.normalizeRanges(gpa, c.ranges, src_vals.len);
        defer gpa.free(norm);

        var direct = try Col.fromValues(gpa, &dest_vals, default_max_segments);
        defer direct.deinit();
        var invert = try Col.fromValues(gpa, &dest_vals, default_max_segments);
        defer invert.deinit();
        // The source is handed over, not borrowed: each strategy takes its
        // own copy and frees it.
        try direct.copyRangesWith(
            gpa,
            c.index,
            c.del,
            try Col.fromValues(gpa, src_vals, default_max_segments),
            norm,
            .direct,
        );
        try invert.copyRangesWith(
            gpa,
            c.index,
            c.del,
            try Col.fromValues(gpa, src_vals, default_max_segments),
            norm,
            .invert,
        );

        var want: std.ArrayList(u64) = .empty;
        defer want.deinit(gpa);
        try want.appendSlice(gpa, dest_vals[0..c.index]);
        for (norm) |r| try want.appendSlice(gpa, src_vals[r.start..r.end]);
        try want.appendSlice(gpa, dest_vals[c.index + c.del ..]);

        const dg = try direct.toSlice(gpa);
        defer gpa.free(dg);
        const ig = try invert.toSlice(gpa);
        defer gpa.free(ig);
        try testing.expectEqualSlices(u64, want.items, dg);
        try testing.expectEqualSlices(u64, want.items, ig);
        const db = try direct.encode(gpa);
        defer gpa.free(db);
        const ib = try invert.encode(gpa);
        defer gpa.free(ib);
        try testing.expectEqualSlices(u8, db, ib);
    }
}

test "copy_ranges_multi_point_strategies_agree" {
    // `tests.rs`. Inserts, replaces, pure deletes, and points that
    // normalize into one. Every `pos` is a row of the destination *before*
    // any of them are applied, so the answer is the interleave, not a
    // sequence of shifts.
    const gpa = testing.allocator;
    const Col = Column(u64, Rle(u64));
    const src_vals = try manyU64(gpa, 3000, sevenTimesOverForties);
    defer gpa.free(src_vals);
    const dest_vals = try manyU64(gpa, 200, nineThousands);
    defer gpa.free(dest_vals);

    const cases = [_][]const Col.Splice{
        &.{
            .{ .pos = 0, .delete = 0, .range = .{ .start = 0, .end = 100 } },
            .{ .pos = 50, .delete = 0, .range = .{ .start = 200, .end = 300 } },
            .{ .pos = 199, .delete = 0, .range = .{ .start = 400, .end = 500 } },
        },
        &.{
            .{ .pos = 10, .delete = 0, .range = .{ .start = 0, .end = 40 } },
            .{ .pos = 10, .delete = 0, .range = .{ .start = 100, .end = 140 } },
            .{ .pos = 90, .delete = 0, .range = .{ .start = 200, .end = 2900 } },
        },
        &.{
            .{ .pos = 200, .delete = 0, .range = .{ .start = 0, .end = 1500 } },
            .{ .pos = 200, .delete = 0, .range = .{ .start = 1500, .end = 3000 } },
        },
        &.{.{ .pos = 1, .delete = 0, .range = .{ .start = 5, .end = 2995 } }},
        &.{
            .{ .pos = 0, .delete = 3, .range = .{ .start = 0, .end = 3 } },
            .{ .pos = 10, .delete = 5, .range = .{ .start = 100, .end = 102 } },
            .{ .pos = 60, .delete = 20, .range = .{ .start = 300, .end = 300 } },
        },
        &.{
            .{ .pos = 5, .delete = 1, .range = .{ .start = 0, .end = 1 } },
            .{ .pos = 6, .delete = 1, .range = .{ .start = 1, .end = 2 } },
            .{ .pos = 7, .delete = 1, .range = .{ .start = 2, .end = 3 } },
            .{ .pos = 30, .delete = 2, .range = .{ .start = 50, .end = 60 } },
        },
        &.{
            .{ .pos = 0, .delete = 0, .range = .{ .start = 3, .end = 3 } },
            .{ .pos = 7, .delete = 0, .range = .{ .start = 2990, .end = 3100 } },
        },
    };

    for (cases) |raw| {
        const norm = try Col.normalizeSplices(gpa, raw, src_vals.len, dest_vals.len);
        defer gpa.free(norm);

        var direct = try Col.fromValues(gpa, dest_vals, default_max_segments);
        defer direct.deinit();
        var invert = try Col.fromValues(gpa, dest_vals, default_max_segments);
        defer invert.deinit();
        try direct.copySplicesWith(
            gpa,
            try Col.fromValues(gpa, src_vals, default_max_segments),
            norm,
            .direct,
        );
        try invert.copySplicesWith(
            gpa,
            try Col.fromValues(gpa, src_vals, default_max_segments),
            norm,
            .invert,
        );

        const want = try interleave(gpa, dest_vals, src_vals, norm);
        defer gpa.free(want);
        const dg = try direct.toSlice(gpa);
        defer gpa.free(dg);
        const ig = try invert.toSlice(gpa);
        defer gpa.free(ig);
        try testing.expectEqualSlices(u64, want, dg);
        try testing.expectEqualSlices(u64, want, ig);
        const db = try direct.encode(gpa);
        defer gpa.free(db);
        const ib = try invert.encode(gpa);
        defer gpa.free(ib);
        try testing.expectEqualSlices(u8, db, ib);

        // The public entry point picks a strategy and has to land on the
        // same answer.
        var auto = try Col.fromValues(gpa, dest_vals, default_max_segments);
        defer auto.deinit();
        try auto.copySplices(
            gpa,
            try Col.fromValues(gpa, src_vals, default_max_segments),
            norm,
        );
        const ag = try auto.toSlice(gpa);
        defer gpa.free(ag);
        try testing.expectEqualSlices(u64, want, ag);
    }
}

test "copy_ranges_strategies_agree_nullable" {
    // `tests.rs`. The same agreement with null runs in the source: an
    // absent value rides in the run header, so keeping a source slab means
    // keeping a header the destination's own encoding may group
    // differently — and both strategies still have to answer the same.
    const gpa = testing.allocator;
    const Col = Column(?u64, RleOption(u64));
    var vals: [2000]?u64 = undefined;
    for (&vals, 0..) |*v, i| v.* = if (i % 7 == 0) null else @as(?u64, @as(u64, @intCast(i / 30)));
    const dest_vals = [_]?u64{ 9, null, 11 };

    const ranges = [_]RowRange{
        .{ .start = 3, .end = 1200 },
        .{ .start = 1300, .end = 1999 },
    };
    const norm = try Col.normalizeRanges(gpa, &ranges, vals.len);
    defer gpa.free(norm);

    var direct = try Col.fromValues(gpa, &dest_vals, default_max_segments);
    defer direct.deinit();
    var invert = try Col.fromValues(gpa, &dest_vals, default_max_segments);
    defer invert.deinit();
    try direct.copyRangesWith(
        gpa,
        1,
        1,
        try Col.fromValues(gpa, &vals, default_max_segments),
        norm,
        .direct,
    );
    try invert.copyRangesWith(
        gpa,
        1,
        1,
        try Col.fromValues(gpa, &vals, default_max_segments),
        norm,
        .invert,
    );

    var want: std.ArrayList(?u64) = .empty;
    defer want.deinit(gpa);
    try want.append(gpa, dest_vals[0]);
    for (norm) |r| try want.appendSlice(gpa, vals[r.start..r.end]);
    try want.appendSlice(gpa, dest_vals[2..]);

    const dg = try direct.toSlice(gpa);
    defer gpa.free(dg);
    const ig = try invert.toSlice(gpa);
    defer gpa.free(ig);
    try testing.expectEqualSlices(?u64, want.items, dg);
    try testing.expectEqualSlices(?u64, want.items, ig);
    const db = try direct.encode(gpa);
    defer gpa.free(db);
    const ib = try invert.encode(gpa);
    defer gpa.free(ib);
    try testing.expectEqualSlices(u8, db, ib);
}

test "copy_ranges_heuristic" {
    // `tests.rs`. The three shapes the strategy decision is asked about,
    // each run end to end through the public entry point: a tiny
    // destination taking nearly all of a big source, the same destination
    // taking two scattered ranges, and the same bulk copy into a
    // destination built on another run budget — inverting keeps the
    // *source's* slabs, which were built under the source's budget, so that
    // last one cannot take them.
    //
    // **Which of the two paths answers is a cost decision and is not
    // observable** ([`Column.CopyStrategy`] says so, and so does upstream's
    // own `copy_ranges`: "the choice is unobservable — both paths yield
    // identical values and `save()` bytes"). So the decision is not pinned
    // here; the *rows* are, and they are held against a model built from
    // the destination's and the source's own arrays rather than from
    // anything the copy produced. The three boundary reads upstream makes
    // on the motivating case are subsumed: this model is every row, of
    // which those three are the ends and the first copied row.
    const gpa = testing.allocator;
    const Col = Column(u64, Rle(u64));
    const src_vals = try manyU64(gpa, 100_000, thirds);
    defer gpa.free(src_vals);
    const dest_vals = [_]u64{ 1, 2 };
    const pos: usize = 1;

    const Case = struct {
        what: []const u8,
        budget: usize,
        ranges: []const RowRange,
    };
    const cases = [_]Case{
        .{
            .what = "nearly all of a big source into a tiny destination",
            .budget = default_max_segments,
            .ranges = &[_]RowRange{.{ .start = 0, .end = 100_000 }},
        },
        .{
            .what = "two scattered ranges out of the same source",
            .budget = default_max_segments,
            .ranges = &[_]RowRange{ .{ .start = 50, .end = 60 }, .{ .start = 1000, .end = 1010 } },
        },
        .{
            .what = "the same bulk copy into a destination on another run budget",
            .budget = 8,
            .ranges = &[_]RowRange{.{ .start = 0, .end = 100_000 }},
        },
    };

    for (cases) |c| {
        // The rows the copy owes, from the two arrays and nothing else.
        const norm = try Col.normalizeRanges(gpa, c.ranges, src_vals.len);
        defer gpa.free(norm);
        var want: std.ArrayList(u64) = .empty;
        defer want.deinit(gpa);
        try want.appendSlice(gpa, dest_vals[0..pos]);
        for (norm) |r| try want.appendSlice(gpa, src_vals[r.start..r.end]);
        try want.appendSlice(gpa, dest_vals[pos..]);

        // Every range is copied at the same point, which is what makes the
        // scattered case two points rather than one.
        const splices = try gpa.alloc(Col.Splice, norm.len);
        defer gpa.free(splices);
        for (norm, 0..) |r, i| splices[i] = .{ .pos = pos, .delete = 0, .range = r };

        var dest = try Col.fromValues(gpa, &dest_vals, c.budget);
        defer dest.deinit();
        try dest.copySplices(gpa, try Col.fromValues(gpa, src_vals, default_max_segments), splices);

        const got = try dest.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqual(want.items.len, got.len);
        for (want.items, got, 0..) |w, g, i| {
            if (w != g) {
                std.debug.print("copy of {s}: row {d} is {d}, the model has {d}\n", .{ c.what, i, g, w });
                return error.TestUnexpectedResult;
            }
        }
        try validateRleColumn(Rle(u64), &dest);
    }
}

test "copy_ranges_into_empty_column" {
    // `tests.rs`. Both strategies against a destination that holds
    // nothing, where the invert path has no destination rows at all to
    // put back.
    const gpa = testing.allocator;
    const Col = Column(u64, Rle(u64));
    const src_vals = try manyU64(gpa, 500, nines);
    defer gpa.free(src_vals);
    const ranges = [_]RowRange{
        .{ .start = 5, .end = 100 },
        .{ .start = 200, .end = 450 },
    };
    const norm = try Col.normalizeRanges(gpa, &ranges, src_vals.len);
    defer gpa.free(norm);

    var want: std.ArrayList(u64) = .empty;
    defer want.deinit(gpa);
    for (norm) |r| try want.appendSlice(gpa, src_vals[r.start..r.end]);

    for ([_]Col.CopyStrategy{ .direct, .invert }) |strategy| {
        var dest = try Col.init(gpa);
        defer dest.deinit();
        try dest.copyRangesWith(
            gpa,
            0,
            0,
            try Col.fromValues(gpa, src_vals, default_max_segments),
            norm,
            strategy,
        );
        const got = try dest.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u64, want.items, got);
        try validateRleColumn(Rle(u64), &dest);
    }
}

test "copy_ranges_prefix_column" {
    // `tests.rs`. A prefix column copied through the inverting path: the
    // kept slabs are the source's, and the prefix sums the destination
    // answers with have to add up to the same total. This is the case that
    // would fail if the inverting path kept the slabs but not the weights
    // behind them.
    const gpa = testing.allocator;
    const PCol = Column(u64, Prefix(u64));
    const src_vals = try manyU64(gpa, 50_000, oneTwoThree);
    defer gpa.free(src_vals);
    var expected: i64 = 0;
    for (src_vals) |v| expected += @intCast(v);

    const splices = [_]PCol.Splice{.{ .pos = 1, .delete = 0, .range = .{ .start = 0, .end = 50_000 } }};
    const norm = try PCol.normalizeSplices(gpa, &splices, src_vals.len, 2);
    defer gpa.free(norm);

    var dest = try PCol.fromValues(gpa, &[_]u64{ 7, 7 }, default_max_segments);
    defer dest.deinit();
    try dest.copySplices(gpa, try PCol.fromValues(gpa, src_vals, default_max_segments), norm);
    try testing.expectEqual(@as(usize, 50_002), dest.len());
    try testing.expectEqual(@as(i64, 14) + expected, try dest.getPrefix(dest.len()));
    // And the column is still sound, and the values are the source's.
    try expectSound(u64, Prefix(u64), &dest);
    try testing.expectEqual(@as(u64, 7), (try dest.get(0)).?);
    try testing.expectEqual(@as(u64, 1), (try dest.get(1)).?);
    try testing.expectEqual(@as(u64, 7), (try dest.get(dest.len() - 1)).?);
}

// ── Merging and splicing runs over byte payloads ────────────────────────────

/// A slab over `values` built through the whole-column encoder, for the
/// merge case: it is the same bytes an encoder hands out.
fn encodedSlab(
    gpa: std.mem.Allocator,
    comptime C: type,
    values: []const C.Value,
) !Slab {
    const bytes = try C.wireEncode(gpa, values, false);
    errdefer gpa.free(bytes);
    const m = try slabmod.measure(gpa, C, bytes);
    return .{ .data = bytes, .len = m.len, .segments = m.segments, .tail = m.tail };
}

test "merge_slab_string_literal_boundary" {
    // `tests.rs`. Two byte-payload slabs whose seam runs meet on the same
    // value: `["x","y","hello"]` and `["hello","hello","world"]`. The seam
    // is literal against literal — the arm the integer codec's
    // `merge_slab_literal_to_literal_same_value` covers — and the merged
    // run has to hold all three `hello`s, because the wire is a *sequence*
    // and two literal runs may not stand next to each other.
    const gpa = testing.allocator;
    const C = RleUtf8(false);
    var a = try encodedSlab(gpa, C, &.{ "x", "y", "hello" });
    defer a.deinit(gpa);
    var b = try encodedSlab(gpa, C, &.{ "hello", "hello", "world" });
    defer b.deinit(gpa);
    // `b` is only read: the merge rewrites `a` and leaves its source alone.
    try slabmod.merge(gpa, C, &a, &b);

    var back = try C.WireDecoder.init(a.data);
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(gpa);
    while (try back.next()) |v| try got.append(gpa, v);
    // **By content, and not by slice header.** Upstream's assertion is
    // `assert_eq!(merged, vec!["x", "y", ...])` over a `Vec<&str>`
    // (`tests.rs:3416`), which compares the strings; `expectEqualSlices`
    // over `[]const u8` compares the *headers*, and a value read out of a
    // slab is a window on that slab's bytes, so two equal values never
    // share one. `textEql` is the same rule the codec's own run boundaries
    // use (`rle.zig:152-162`).
    const want = [_][]const u8{ "x", "y", "hello", "hello", "hello", "world" };
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items, 0..) |w, g, i| {
        if (!textEql(w, g)) {
            std.debug.print("merged row {d} is \"{s}\", the model has \"{s}\"\n", .{ i, g, w });
            return error.TestUnexpectedResult;
        }
    }
    // The merged slab is canonical and its metadata still describes it.
    try C.canonicalSlab(a.data);
    const m = try slabmod.measure(gpa, C, a.data);
    try testing.expectEqual(got.items.len, m.len);
}

test "splice_runs_str_and_bool" {
    // `tests.rs`. `splice_runs` over a byte payload and over a boolean
    // column — the two value kinds the run-aware splice has to carry, both
    // with runs that come straight off another column's run walk.
    const gpa = testing.allocator;

    const src_text = [_][]const u8{ "a", "a", "b", "b", "b" };
    var s = try StrCol.fromValues(gpa, &src_text, default_max_segments);
    defer s.deinit();
    var dst_text = try StrCol.fromValues(gpa, &[_][]const u8{ "x", "y" }, default_max_segments);
    defer dst_text.deinit();
    {
        var it = try s.iterRange(.{ .start = 1, .end = 4 });
        var runs = it.runs();
        var got: std.ArrayList(StrCol.Run) = .empty;
        defer got.deinit(gpa);
        while (try runs.next()) |r| try got.append(gpa, r);
        try dst_text.spliceRuns(gpa, 1, 0, got.items);
    }
    try expectBytesRoundTrip(
        StrCol,
        &dst_text,
        &[_][]const u8{ "x", "a", "b", "b", "y" },
        textEql,
    );

    const BCol = Column(bool, Bool);
    const src_bools = [_]bool{ true, true, false, true };
    var sb = try BCol.fromValues(gpa, &src_bools, default_max_segments);
    defer sb.deinit();
    var dst_bools = try BCol.fromValues(gpa, &[_]bool{ false, false }, default_max_segments);
    defer dst_bools.deinit();
    {
        var it = try sb.iterRange(.{ .start = 0, .end = 3 });
        var runs = it.runs();
        var got: std.ArrayList(BCol.Run) = .empty;
        defer got.deinit(gpa);
        while (try runs.next()) |r| try got.append(gpa, r);
        try dst_bools.spliceRuns(gpa, 2, 0, got.items);
    }
    try assertCol(bool, Bool, &dst_bools, &[_]bool{ false, false, true, true, false });
}

test "fill_nullable_types" {
    // `tests.rs`. A column of `n` absent values, in one run and so in O(1),
    // over each of the three nullable value kinds the port has: a signed
    // integer, text and bytes. **The text and byte arms are why this case
    // was unreachable before** — a nullable column's payload had to be an
    // integer, so there was no `Option<String>` column to fill.
    const gpa = testing.allocator;
    {
        var col = try Column(?i64, RleOption(i64)).fill(gpa, 50, null);
        defer col.deinit();
        try testing.expectEqual(@as(usize, 50), col.len());
        try testing.expect((try col.get(0)).? == null);
        try testing.expect((try col.get(49)).? == null);
    }
    {
        var col = try OptStrCol.fill(gpa, 10, null);
        defer col.deinit();
        try testing.expectEqual(@as(usize, 10), col.len());
        try testing.expect((try col.get(0)).? == null);
        try expectBytesRoundTrip(OptStrCol, &col, &([_]?[]const u8{null} ** 10), optTextEql);
    }
    {
        var col = try OptBytesCol.fill(gpa, 10, null);
        defer col.deinit();
        try testing.expectEqual(@as(usize, 10), col.len());
        try testing.expect((try col.get(0)).? == null);
        try expectBytesRoundTrip(OptBytesCol, &col, &([_]?[]const u8{null} ** 10), optTextEql);
    }
}

test "next_run_merges_across_slabs_strings_and_prefix" {
    // `tests.rs`. The cross-slab coalescing arm over the two codecs whose
    // runs are not plain integers: a byte payload and a prefix column. A
    // slab cut lands on a run boundary and each slab here is at the run
    // budget, so the edit is the only thing that can make the values either
    // side of the first boundary equal — which is exactly the case the arm
    // exists for.
    const gpa = testing.allocator;

    {
        var col = try StrCol.init(gpa);
        defer col.deinit();
        var model: std.ArrayList([]const u8) = .empty;
        defer model.deinit(gpa);
        // 400 runs of two rows is 400 runs and so several slabs.
        const tags = try runTags(gpa, 400);
        defer freeTags(gpa, tags);
        for (tags) |tag| {
            for (0..2) |_| {
                try col.append(gpa, tag);
                try model.append(gpa, tag);
            }
        }
        if (col.slabCount() < 2) return error.TestUnexpectedResult;
        const boundary = col.slabAt(0).?.len;
        const across = model.items[boundary];
        try col.splice(gpa, boundary - 1, 1, &[_][]const u8{across});
        try model.replaceRange(gpa, boundary - 1, 1, &[_][]const u8{across});
        if (col.slabCount() < 2) return error.TestUnexpectedResult;
        try expectBytesValues(StrCol, &col, model.items, textEql);

        var it = try col.iterator();
        var runs = it.runs();
        var at: usize = 0;
        var previous: ?[]const u8 = null;
        var spanned: ?usize = null;
        while (try runs.next()) |run| {
            if (previous) |p| try testing.expect(!std.mem.eql(u8, p, run.value));
            if (at <= boundary - 1 and boundary - 1 < at + run.count) spanned = run.count;
            at += run.count;
            previous = run.value;
        }
        try testing.expectEqual(model.items.len, at);
        // Had the two runs stayed apart this would be one and two.
        try testing.expectEqual(@as(usize, 3), spanned.?);
    }

    {
        const PCol = Column(u64, Prefix(u64));
        var col = try PCol.init(gpa);
        defer col.deinit();
        var model: std.ArrayList(u64) = .empty;
        defer model.deinit(gpa);
        for (0..400) |run| {
            for (0..2) |_| {
                const v: u64 = @intCast(run + 1);
                try col.append(gpa, v);
                try model.append(gpa, v);
            }
        }
        if (col.slabCount() < 2) return error.TestUnexpectedResult;
        const boundary = col.slabAt(0).?.len;
        const across = model.items[boundary];
        try col.splice(gpa, boundary - 1, 1, &.{across});
        try model.replaceRange(gpa, boundary - 1, 1, &.{across});
        if (col.slabCount() < 2) return error.TestUnexpectedResult;
        try expectModel(u64, Prefix(u64), &col, model.items);

        var it = try col.iterator();
        var runs = it.runs();
        var at: usize = 0;
        var previous: ?u64 = null;
        var spanned: ?usize = null;
        while (try runs.next()) |run| {
            if (previous) |p| try testing.expect(p != run.value);
            if (at <= boundary - 1 and boundary - 1 < at + run.count) spanned = run.count;
            at += run.count;
            previous = run.value;
        }
        try testing.expectEqual(model.items.len, at);
        try testing.expectEqual(@as(usize, 3), spanned.?);
        // The prefix sums survived the edit and the coalescing walk.
        var total: i64 = 0;
        for (model.items) |v| total += @intCast(v);
        try testing.expectEqual(total, try col.getPrefix(col.len()));
    }
}

/// `count` distinct payloads, four to six bytes wide, **handed over with
/// their bytes still live** and given back by `freeTags` below.
///
/// The cross-slab cases need the runs to be *distinct* — or the column would
/// not have the run count they are counting — and they want the widths to
/// differ, or the payload arithmetic would not be exercised.
///
/// **A tag is borrowed, and it is borrowed for as long as the array is.**
/// That is the byte payload's own rule (`rle.zig:117-120`: a payload read is
/// a window on the encoded bytes, not a copy) and this is the fixture's copy
/// of it. Copying the *headers* out of the list and then freeing the bytes
/// they name hands the caller `count` dangling windows, and the first append
/// that reads one reads freed memory — which is exactly what it did: the
/// cross-slab string case appended 800 rows out of tags freed before the
/// first one, and the encoder's `memcpy` of a payload is where it died. So
/// the payloads travel with the list, and `freeTags` gives every one back.
fn runTags(gpa: std.mem.Allocator, count: usize) ![]const []const u8 {
    var payloads: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (payloads.items) |t| gpa.free(t);
        payloads.deinit(gpa);
    }
    for (0..count) |n| {
        var buf: [16]u8 = undefined;
        try payloads.append(gpa, try gpa.dupe(u8, try std.fmt.bufPrint(&buf, "run{d}", .{n})));
    }
    return payloads.toOwnedSlice(gpa);
}

/// Gives back what [`runTags`] handed over: every payload, and then the list
/// of them. One owner for both halves, so a caller cannot free one and keep
/// the other.
fn freeTags(gpa: std.mem.Allocator, tags: []const []const u8) void {
    for (tags) |t| gpa.free(t);
    gpa.free(tags);
}

test "next_run_never_yields_adjacent_equal_runs_at_default_config" {
    // `tests.rs`. Runs of pairs at the default budget, so the column splits
    // on its own, and then an edit makes the values either side of the
    // first boundary equal. The contract is that the run walk coalesces
    // across a slab boundary, so two consecutive runs never carry equal
    // values — whatever the layout is.
    const gpa = testing.allocator;
    // Runs of two, cycling through eight distinct tags: 300 rows make 150
    // runs, which is more than the 64-run budget, so the column splits on its
    // own into three slabs and there is a real slab boundary to coalesce
    // across. A flat `i/2` with an `else` arm collapses every row past the
    // eighth tag into one long final run — eight runs, one slab, and a test
    // that reports its own premise missing instead of the defect it is for.
    const tags = [_][]const u8{ "k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7" };
    var vals: [300]?[]const u8 = undefined;
    for (&vals, 0..) |*v, i| v.* = tags[(i / 2) % tags.len];
    var col = try OptStrCol.fromValues(gpa, &vals, default_max_segments);
    defer col.deinit();
    if (col.slabCount() <= 1) return error.TestUnexpectedResult;
    const boundary = col.slabAt(0).?.len;
    // **`after` is copied before the edit, because `get` borrows the
    // column's own slab bytes and the splice rewrites them.** Holding the
    // borrow across the mutation is the use-after-free AGENTS.md calls out:
    // a slice into a document's storage is valid until the next mutation.
    const after_src = (try col.get(boundary)).?.?;
    const after = try gpa.dupe(u8, after_src);
    defer gpa.free(after);
    try col.splice(gpa, boundary - 1, 1, &[_]?[]const u8{after});
    // The edit must not have folded the column back into one slab: with a
    // single slab there is no boundary to coalesce across and the walk
    // below would pass for the wrong reason. Upstream makes the same check
    // (`tests.rs:4952-4955`), and takes the empty slab it also forbids with
    // it through the layout check.
    if (col.slabCount() <= 1) return error.TestUnexpectedResult;
    // The edit landed where it was aimed: row `boundary - 1` now carries the
    // value `boundary` stood on, and nothing else moved.
    var model = vals;
    model[boundary - 1] = after;
    try expectBytesValues(OptStrCol, &col, &model, optTextEql);
    try expectSound(?[]const u8, RleUtf8(true), &col);
    var it = try col.iterator();
    var runs = it.runs();
    var prev: ?[]const u8 = null;
    var total: usize = 0;
    while (try runs.next()) |r| {
        if (r.value) |v| {
            if (prev) |p| try testing.expect(!std.mem.eql(u8, p, v));
            prev = v;
        }
        total += r.count;
    }
    try testing.expectEqual(col.len(), total);
}

test "string_splice_at_literal_repeat_boundary" {
    // `tests.rs`. A splice whose cut lands exactly on the boundary between
    // a literal run and the repeat run behind it. With a byte payload the
    // seam's byte offsets are the length-prefixed ones, so the count header
    // rewrite and the payload search either side of it are both exercised.
    const gpa = testing.allocator;
    var col = try StrCol.fromValues(
        gpa,
        &[_][]const u8{ "aa", "bb", "cc", "dd", "dd", "dd", "dd" },
        default_max_segments,
    );
    defer col.deinit();
    try col.splice(gpa, 3, 4, &[_][]const u8{"zz"});
    try expectBytesRoundTrip(
        StrCol,
        &col,
        &[_][]const u8{ "aa", "bb", "cc", "zz" },
        textEql,
    );
    try col.splice(gpa, 1, 1, &[_][]const u8{"e"});
    try expectBytesRoundTrip(
        StrCol,
        &col,
        &[_][]const u8{ "aa", "e", "cc", "zz" },
        textEql,
    );
}

test "string_splice_variable_length_values" {
    // `tests.rs`. Every splice position in a literal run whose payloads
    // are one, two, three and four bytes wide, with an insert, a delete
    // and both directions of the literal/repeat seam. **This is the case
    // the port's integer codec could only approach**: a LEB128 payload is
    // variable width too, but a byte payload makes every width in the run
    // explicit, and the offsets have to be *found* rather than multiplied.
    const gpa = testing.allocator;
    const base = [_][]const u8{ "a", "bbbb", "ccccc", "dd", "dddd", "dddd", "eeee", "ffffffff" };
    for (0..base.len) |at| {
        var col = try StrCol.fromValues(gpa, &base, default_max_segments);
        defer col.deinit();
        try col.splice(gpa, at, 0, &[_][]const u8{"zzzzzzzz"});
        var want: std.ArrayList([]const u8) = .empty;
        defer want.deinit(gpa);
        try want.appendSlice(gpa, base[0..at]);
        try want.append(gpa, "zzzzzzzz");
        try want.appendSlice(gpa, base[at..]);
        try expectBytesValues(StrCol, &col, want.items, textEql);

        // And a delete at the same position.
        try col.splice(gpa, at, 1, &[_][]const u8{});
        want.items.len = 0;
        try want.appendSlice(gpa, &base);
        try expectBytesRoundTrip(StrCol, &col, want.items, textEql);
    }
}
