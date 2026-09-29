//! Prefix columns: the length of every row, so that walking a column
//! can skip to any row's payload in O(1).
//!
//! The stored value of a row is its own *length* — the byte length of a
//! value in `value_meta`, the number of successors in `succ_count` — and
//! the offset a row's payload starts at is the sum of the lengths before
//! it. Upstream keeps that sum in the column's B-tree index rather than
//! in the bytes, and exposes it two ways (`prefix.rs:541-566`):
//!
//! * `get_prefix(index)` — the sum of the lengths of rows `0..index`,
//!   which is the offset of row `index`. The op-set loader calls it
//!   with `index == len` to size a companion column
//!   (`op_set2/columns.rs:294-300`), so the grand total has to be
//!   reachable.
//! * `get_total(index)` — the same sum through row `index`.
//!
//! This module makes that sum an array, so a caller can hold it, index
//! it, and re-derive it from the column bytes.
//!
//! # The prefix array
//!
//! The array is `n + 1` slots for `n` rows. Slot `i` holds the running
//! sum *through* row `i`, and the last slot holds the grand total, which
//! no row shadows because no row sits at it. `toPrefix` writes the array,
//! `fromPrefix` reads a row list back out of it, and `offsetAt` answers
//! the offset question from one slot:
//!
//! * `offsetAt(0)` is 0 — the first row starts at the front.
//! * `offsetAt(i)` for `0 < i < n` is slot `i - 1`: the total through
//!   the row before it.
//! * `offsetAt(n)` is the last slot, the grand total.
//!
//! For a nullable column a null row contributes nothing to the sum
//! (`None` is the prefix identity, `prefix.rs:287-312`), so its slot
//! stays null: the null marks the row it came from, which is what keeps
//! the transform reversible. `offsetAt` then reads the last non-null
//! slot before the row, a walk bounded by the null run behind it.
//!
//! # Wire format
//!
//! A prefix column is an ordinary RLE column of the lengths, so the wire
//! format is `rle.zig`'s and the five wire functions here are that
//! codec: `encodedSize`, `write` and `append` are its own, and
//! `decodeAll` and `Decoder` drive its value cursor.
//!
//! What this module adds is the check the RLE codec knows nothing
//! about: the running sum of the lengths has to fit `Element`, or the
//! offsets the column hands out are not representable and the slab is
//! rejected rather than wrapped. Upstream accumulates into a wider type
//! instead — `u32` rows sum into a `u64` (`prefix.rs:259-267`) — so this
//! port narrows that check to the array's own width, and
//! `prefixArray` reports the same overflow `error.Overflow` the
//! transform's own callers get.

const std = @import("std");
const rle = @import("rle.zig");
const err = @import("../error.zig");

const ParseError = err.ParseError;

/// The value type behind a nullable column type.
fn payloadOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Whether `T` is a nullable column type.
fn isNullable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => true,
        else => false,
    };
}

/// A prefix column of `T`. `T` is `u32`, `u64`, `i32`, `i64`, or an
/// optional of one; anything else is a compile error.
pub fn Prefix(comptime T: type) type {
    return struct {
        /// The column's value type: the length of each row.
        pub const Element = T;
        /// Whether the column can hold nulls.
        pub const nullable = isNullable(T);

        const Payload = payloadOf(T);

        /// The RLE codec the lengths are stored in: the plain one, or the
        /// nullable one where a row can have no length. It is the codec's
        /// own per-type rule that packs an unsigned length unsigned and a
        /// signed one signed, as upstream does (`lib.rs:604-637`).
        fn codec() type {
            return if (comptime nullable) rle.RleOption(Payload) else rle.Rle(Payload);
        }

        /// That codec's value cursor.
        const WireDecoder = if (nullable)
            rle.RleOption(Payload).Decoder
        else
            rle.Rle(Payload).Decoder;

        /// The length of a row that has none, and the offset of the first
        /// row.
        fn zero() Payload {
            return 0;
        }

        /// `a + b`. A running sum that does not fit `Element` is a
        /// precondition violation: the caller asked for offsets the
        /// column type cannot hold. `append`, `decodeAll` and
        /// `prefixArray` report it as `error.Overflow` instead.
        fn addInPlace(a: Payload, b: Payload) Payload {
            const r = @addWithOverflow(a, b);
            if (r[1] != 0) @panic("Prefix: the running sum overflows the column's value type");
            return r[0];
        }

        /// `a - b`, for the same reason as `addInPlace`.
        fn subInPlace(a: Payload, b: Payload) Payload {
            const r = @subWithOverflow(a, b);
            if (r[1] != 0) @panic("Prefix: a prefix difference leaves the column's value type");
            return r[0];
        }

        /// `a + b` for a length on its way into a running sum.
        fn addChecked(a: Payload, b: Payload) ParseError!Payload {
            const r = @addWithOverflow(a, b);
            if (r[1] != 0) return error.Overflow;
            return r[0];
        }

        // ── the prefix array ──

        /// Converts the row lengths in `values[0 .. values.len - 1]`
        /// into running sums in place, leaving the grand total in the
        /// last slot. The array is one longer than the row list it
        /// describes, so the last row's own end offset has a home and
        /// no length is lost to a neighbour.
        ///
        /// A null row contributes nothing to the sum and keeps its null
        /// slot. Panics if the running sum leaves `Element`; use
        /// `prefixArray` to be told instead.
        pub fn toPrefix(values: []T) void {
            if (values.len == 0) return;
            const rows = values.len - 1;
            var acc = zero();
            for (values[0..rows]) |*v| {
                // A non-nullable element is its own single-valued
                // option, so both shapes run the same loop.
                const len: ?Payload = v.*;
                if (len) |l| {
                    acc = addInPlace(acc, l);
                    v.* = acc;
                }
            }
            values[rows] = acc;
        }

        /// Converts a prefix array back into the row lengths it
        /// describes, in place, dropping the grand total. The inverse of
        /// `toPrefix`. Panics if a difference leaves `Element`, which
        /// means the array was not one `toPrefix` produced.
        pub fn fromPrefix(values: []T) void {
            if (values.len == 0) return;
            const rows = values.len - 1;
            var prev = zero();
            for (values[0..rows]) |*v| {
                const total: ?Payload = v.*;
                if (total) |t| {
                    v.* = subInPlace(t, prev);
                    prev = t;
                }
            }
        }

        /// The absolute offset of row `index`: the sum of the lengths of
        /// the rows before it, which is upstream's `get_prefix(index)`
        /// (`prefix.rs:543-548`). `index` may be the last slot — the
        /// grand total, one past the end of the column — which is how a
        /// loader sizes the column this one indexes
        /// (`op_set2/columns.rs:294-300`).
        ///
        /// A nullable column answers `null` past the end of the array. A
        /// non-nullable one has no such value to answer with, so an
        /// index past the end is a precondition violation and panics.
        pub fn offsetAt(prefix: []const T, index: usize) T {
            if (index >= prefix.len) {
                if (comptime nullable) return null;
                @panic("Prefix.offsetAt: index past the end of the prefix array");
            }
            // The last slot is the grand total, the offset one past the
            // end: no row sits at it, so it is not shadowed by one.
            if (index + 1 == prefix.len) return prefix[index];
            var i = index;
            while (i > 0) {
                i -= 1;
                // Nulls contribute nothing, so the offset of a row is
                // the last non-null slot before it. A row with only
                // nulls before it starts at zero.
                const total: ?Payload = prefix[i];
                if (total) |t| return t;
            }
            return zero();
        }

        /// The prefix array for `values`: `values.len + 1` slots, the
        /// last of them the grand total. The caller owns the result.
        /// `error.Overflow` if the running sum leaves `Element`.
        pub fn prefixArray(gpa: std.mem.Allocator, values: []const T) ParseError![]T {
            const out = try gpa.alloc(T, values.len + 1);
            errdefer gpa.free(out);
            var acc = zero();
            for (values, 0..) |v, i| {
                const len: ?Payload = v;
                if (len) |l| acc = try addChecked(acc, l);
                out[i] = acc;
            }
            out[values.len] = acc;
            return out;
        }

        // ── wire format ──

        /// The number of bytes `write` emits for `values`.
        pub fn encodedSize(values: []const T) usize {
            return codec().encodedSize(values);
        }

        /// Writes `values` into `out`, which must hold `encodedSize`
        /// bytes.
        pub fn write(out: []u8, values: []const T) void {
            codec().write(out, values);
        }

        /// Appends the encoding of `values` to `list`.
        pub fn append(list: *std.ArrayList(u8), gpa: std.mem.Allocator, values: []const T) !void {
            return codec().append(list, gpa, values);
        }

        /// Every row length in a slab. The caller owns the result. The
        /// running sum is checked on the way out: a column whose offsets
        /// do not fit `Element` is `error.Overflow`, not a wrap.
        pub fn decodeAll(bytes: []const u8, gpa: std.mem.Allocator) ParseError![]T {
            const out = try codec().decodeAll(bytes, gpa);
            errdefer gpa.free(out);
            var acc = zero();
            for (out) |v| {
                const len: ?Payload = v;
                if (len) |l| acc = try addChecked(acc, l);
            }
            return out;
        }

        /// A slab decoded into its prefix array: `n + 1` slots for `n`
        /// rows, the last of them the grand total. The caller owns the
        /// result.
        pub fn decodePrefix(bytes: []const u8, gpa: std.mem.Allocator) ParseError![]T {
            const rows = try decodeAll(bytes, gpa);
            defer gpa.free(rows);
            return prefixArray(gpa, rows);
        }

        /// A cursor over a slab that yields row lengths one at a time,
        /// carrying the offsets alongside them the way upstream's
        /// `PrefixedValue` does (`prefix.rs:699-720`).
        pub const Decoder = struct {
            inner: WireDecoder,
            /// The running sum through the last row returned, which is
            /// the offset just past it.
            sum: Payload,
            /// The offset of the last row returned.
            before: Payload,

            /// A cursor at the start of `bytes`. The opening run header
            /// is read and checked here, so bytes that are not a slab at
            /// all are rejected at the boundary; anything malformed
            /// further in surfaces from `next`.
            pub fn init(bytes: []const u8) ParseError!Decoder {
                return .{
                    .inner = try WireDecoder.init(bytes),
                    .sum = zero(),
                    .before = zero(),
                };
            }

            /// The offset of the last row returned, which is upstream's
            /// exclusive `get_prefix` for that row (`prefix.rs:543-548`).
            pub fn prefix(self: *const Decoder) Payload {
                return self.before;
            }

            /// The running sum through the last row returned, which is
            /// upstream's inclusive `get_total` (`prefix.rs:549-555`).
            pub fn total(self: *const Decoder) Payload {
                return self.sum;
            }

            /// The next row length, null at the end of the slab. A null
            /// row contributes nothing to the running sum, which is what
            /// upstream's `None` does in `PrefixValue::accumulate`
            /// (`prefix.rs:287-312`). The sum is checked as it goes, so a
            /// slab whose offsets do not fit `Element` is
            /// `error.Overflow` rather than a wrap.
            pub fn next(self: *Decoder) ParseError!?T {
                const stored = (try self.inner.next()) orelse return null;
                const len: ?Payload = stored;
                if (len) |l| {
                    self.before = self.sum;
                    self.sum = try addChecked(self.sum, l);
                    return l;
                }
                // A null row holds no offset of its own and leaves the
                // running sum where it is. A non-nullable column never
                // gets here: its codec rejects the run
                // (`rle.zig:301`).
                if (comptime nullable) return @as(T, null);
                return error.UnexpectedNull;
            }
        };
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Encodes `values`, checks the bytes, and reads them back.
fn expectColumn(comptime P: type, values: []const P.Element, bytes: []const u8) !void {
    const gpa = testing.allocator;
    try testing.expectEqual(bytes.len, P.encodedSize(values));

    const buf = try gpa.alloc(u8, P.encodedSize(values));
    defer gpa.free(buf);
    P.write(buf, values);
    try testing.expectEqualSlices(u8, bytes, buf);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try P.append(&list, gpa, values);
    try testing.expectEqualSlices(u8, bytes, list.items);

    const back = try P.decodeAll(bytes, gpa);
    defer gpa.free(back);
    try testing.expectEqualSlices(P.Element, values, back);

    var dec = try P.Decoder.init(bytes);
    for (values) |v| try testing.expectEqual(v, (try dec.next()).?);
    try testing.expectEqual(@as(?P.Element, null), try dec.next());
}

/// Asserts that decoding `bytes` fails. Which error a malformed run
/// header is depends on the RLE codec, so only the refusal is pinned
/// here; the variants this module raises are pinned where they are
/// raised.
fn expectDecodeFails(comptime P: type, bytes: []const u8) !void {
    const gpa = testing.allocator;
    if (P.decodeAll(bytes, gpa)) |v| {
        gpa.free(v);
        return error.TestExpectedError;
    } else |_| {}
}

test "a column of row lengths" {
    // All three differ, so the column is one literal run.
    try expectColumn(Prefix(u32), &.{ 3, 0, 4 }, &.{ 0x7d, 0x03, 0x00, 0x04 });
    // A run of equal lengths is a repeat run.
    try expectColumn(Prefix(u32), &.{ 7, 7, 7, 7 }, &.{ 0x04, 0x07 });
    // An empty column is an empty slab.
    try expectColumn(Prefix(u32), &.{}, &.{});
    try expectColumn(Prefix(u64), &.{ 0, 1, 0, 1 }, &.{ 0x7c, 0x00, 0x01, 0x00, 0x01 });
}

test "a length that both follows and starts a run" {
    // The middle length cannot join the literal that opens the column:
    // the one after it repeats it.
    try expectColumn(Prefix(u32), &.{ 1, 2, 2 }, &.{ 0x7f, 0x01, 0x02, 0x02 });
    try expectColumn(Prefix(u32), &.{ 1, 1, 2 }, &.{ 0x02, 0x01, 0x7f, 0x02 });
    try expectColumn(Prefix(u32), &.{ 1, 2, 1 }, &.{ 0x7d, 0x01, 0x02, 0x01 });
}

test "a signed column packs signed values" {
    // The header and the values are signed varints here, as upstream's
    // `i32` and `i64` pack them.
    try expectColumn(Prefix(i32), &.{ -1, -1 }, &.{ 0x02, 0x7f });
    try expectColumn(Prefix(i64), &.{ 0, 300, 0 }, &.{ 0x7d, 0x00, 0xac, 0x02, 0x00 });
}

test "toPrefix and fromPrefix are inverses" {
    const P = Prefix(u32);
    var buf: [8]u32 = .{ 3, 1, 4, 1, 5, 9, 2, 0 };
    const lengths = buf[0..7];

    var rows = buf;
    P.toPrefix(&rows);
    // Slot i is the running sum through row i; the last slot is the
    // grand total.
    try testing.expectEqualSlices(u32, &.{ 3, 4, 8, 9, 14, 23, 25, 25 }, &rows);
    try testing.expectEqual(@as(u32, 0), P.offsetAt(&rows, 0));
    try testing.expectEqual(@as(u32, 3), P.offsetAt(&rows, 1));
    try testing.expectEqual(@as(u32, 23), P.offsetAt(&rows, 6));
    // The last slot is the offset one past the end, which is how a
    // loader sizes the column this one indexes.
    try testing.expectEqual(@as(u32, 25), P.offsetAt(&rows, 7));

    P.fromPrefix(&rows);
    try testing.expectEqualSlices(u32, lengths, rows[0..lengths.len]);
}

test "offsetAt agrees with the decoded prefix sums" {
    const gpa = testing.allocator;
    const P = Prefix(u32);
    const lengths = [_]u32{ 0, 5, 0, 0, 2, 7, 1, 0, 9 };
    const bytes = try gpa.alloc(u8, P.encodedSize(&lengths));
    defer gpa.free(bytes);
    P.write(bytes, &lengths);

    const prefix = try P.decodePrefix(bytes, gpa);
    defer gpa.free(prefix);
    try testing.expectEqual(lengths.len + 1, prefix.len);

    var sum: u32 = 0;
    for (lengths, 0..) |len, i| {
        try testing.expectEqual(sum, P.offsetAt(prefix, i));
        sum += len;
    }
    try testing.expectEqual(sum, P.offsetAt(prefix, lengths.len));

    // The same array the in-place transform produces.
    var built = try gpa.alloc(u32, lengths.len + 1);
    defer gpa.free(built);
    @memcpy(built[0..lengths.len], &lengths);
    P.toPrefix(built);
    try testing.expectEqualSlices(u32, prefix, built);
}

test "the streaming decoder carries the offsets" {
    const gpa = testing.allocator;
    const P = Prefix(u32);
    const lengths = [_]u32{ 2, 0, 3, 0, 0, 1 };
    const bytes = try gpa.alloc(u8, P.encodedSize(&lengths));
    defer gpa.free(bytes);
    P.write(bytes, &lengths);

    var dec = try P.Decoder.init(bytes);
    try testing.expectEqual(@as(u32, 0), dec.prefix());
    var sum: u32 = 0;
    for (lengths) |len| {
        try testing.expectEqual(len, (try dec.next()).?);
        // The row's own byte range, as `PrefixedValue` reads it
        // (`prefix.rs:689-694`).
        try testing.expectEqual(sum, dec.prefix());
        sum += len;
        try testing.expectEqual(sum, dec.total());
    }
    try testing.expectEqual(@as(?u32, null), try dec.next());
}

test "an optional column with nulls round-trips" {
    const P = Prefix(?u32);
    const lengths = [_]?u32{ 2, null, null, 3, 3, null, 1 };
    try expectColumn(P, &lengths, &.{ 0x7f, 0x02, 0x00, 0x02, 0x02, 0x03, 0x00, 0x01, 0x7f, 0x01 });

    var rows: [lengths.len + 1]?u32 = .{ lengths[0], lengths[1], lengths[2], lengths[3], lengths[4], lengths[5], lengths[6], 0 };
    P.toPrefix(&rows);
    // A null row contributes nothing and keeps its null slot.
    try testing.expectEqualSlices(?u32, &.{ 2, null, null, 5, 8, null, 9, 9 }, &rows);
    // The offsets of rows 0..6, then the grand total.
    try testing.expectEqualSlices(?u32, &.{ 0, 2, 2, 2, 5, 8, 8, 9 }, &.{
        P.offsetAt(&rows, 0), P.offsetAt(&rows, 1), P.offsetAt(&rows, 2), P.offsetAt(&rows, 3),
        P.offsetAt(&rows, 4), P.offsetAt(&rows, 5), P.offsetAt(&rows, 6), P.offsetAt(&rows, 7),
    });
    try testing.expectEqual(@as(?u32, null), P.offsetAt(&rows, lengths.len + 1));

    P.fromPrefix(&rows);
    try testing.expectEqualSlices(?u32, &lengths, rows[0..lengths.len]);
}

test "prefixArray matches the in-place transform" {
    const gpa = testing.allocator;
    const P = Prefix(u64);
    const lengths = [_]u64{ 1, 0, 0, 4, 4, 4, 2 };
    const built = try P.prefixArray(gpa, &lengths);
    defer gpa.free(built);
    try testing.expectEqualSlices(u64, &.{ 1, 1, 1, 5, 9, 13, 15, 15 }, built);

    // The same column, encoded as a slab: a literal run for the 1 and
    // the two zeros, a repeat run for the 4s, a literal for the 2.
    const bytes = [_]u8{ 0x7d, 0x01, 0x00, 0x00, 0x03, 0x04, 0x7f, 0x02 };
    const decoded = try P.decodePrefix(&bytes, gpa);
    defer gpa.free(decoded);
    try testing.expectEqualSlices(u64, built, decoded);
    const rows = try P.decodeAll(&bytes, gpa);
    defer gpa.free(rows);
    try testing.expectEqualSlices(u64, &lengths, rows);
}

test "a running sum that does not fit is rejected, not wrapped" {
    const gpa = testing.allocator;
    // Two rows of `maxInt - 1` overflow u32 once they are added up, and
    // the offsets the column hands out would be wrong rather than
    // absent.
    const lengths = [_]u32{ std.math.maxInt(u32) - 1, std.math.maxInt(u32) - 1 };
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try Prefix(u32).append(&list, gpa, &lengths);
    try testing.expectError(error.Overflow, Prefix(u32).decodeAll(list.items, gpa));
    try testing.expectError(error.Overflow, Prefix(u32).prefixArray(gpa, &lengths));

    // The same slab in a column wide enough to hold the total.
    const wide = try Prefix(u64).decodeAll(list.items, gpa);
    defer gpa.free(wide);
    const wide_lengths = [_]u64{ std.math.maxInt(u32) - 1, std.math.maxInt(u32) - 1 };
    try testing.expectEqualSlices(u64, &wide_lengths, wide);
    const wide_total = try Prefix(u64).decodePrefix(list.items, gpa);
    defer gpa.free(wide_total);
    try testing.expectEqual(@as(u64, 2 * @as(u64, std.math.maxInt(u32)) - 2), wide_total[wide_total.len - 1]);

    // A length that does not fit the column's own value type.
    try testing.expectError(
        error.Overflow,
        // A length of 2^32, which no u32 column can hold.
        Prefix(u32).decodeAll(&.{ 0x7f, 0x80, 0x80, 0x80, 0x80, 0x10 }, gpa),
    );
}

test "a malformed slab is rejected" {
    const gpa = testing.allocator;
    const P = Prefix(u32);
    // A null in a column that may not be null.
    try testing.expectError(error.UnexpectedNull, P.decodeAll(&.{ 0x00, 0x01 }, gpa));
    // A run header with no payload behind it, a null run with no count,
    // and a run claiming more values than the slab holds.
    try expectDecodeFails(P, &.{0x02});
    try expectDecodeFails(P, &.{0x00});
    try expectDecodeFails(P, &.{ 0x7e, 0x03 });
    try expectDecodeFails(P, &.{0x7f});

    // A non-canonical slab is not a malformed one: a one-element repeat
    // run and a zero-count null run both decode. Refusing them is the
    // loader's `canonical` pass (`rle/load.rs:19-63`), not this
    // codec's.
    const lone = try P.decodeAll(&.{ 0x01, 0x07 }, gpa);
    defer gpa.free(lone);
    try testing.expectEqualSlices(u32, &.{7}, lone);
    try testing.expectError(error.InvalidValue, rle.Rle(u32).canonical(&.{ 0x01, 0x07 }));
    try testing.expectError(error.InvalidValue, rle.RleOption(u32).canonical(&.{ 0x00, 0x00 }));
}

test "an empty slab is an empty prefix array" {
    const gpa = testing.allocator;
    const prefix = try Prefix(u32).decodePrefix(&.{}, gpa);
    defer gpa.free(prefix);
    try testing.expectEqualSlices(u32, &.{0}, prefix);
    try testing.expectEqual(@as(u32, 0), Prefix(u32).offsetAt(prefix, 0));

    const none = try Prefix(?u32).decodePrefix(&.{}, gpa);
    defer gpa.free(none);
    try testing.expectEqualSlices(?u32, &.{0}, none);
    try testing.expectEqual(@as(?u32, null), Prefix(?u32).offsetAt(none, 1));
}
