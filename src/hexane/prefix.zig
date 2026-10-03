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
//!
//! # Import route and the shortest sequence that works
//!
//! `@import("hexane/prefix.zig")`, or `zautomerge.hexane.prefix` through the
//! root module. Zig 0.16.0. What a column imports from here is [`Prefix`] and
//! the [`Prefix.Decoder`] it drives.
//!
//! ```zig
//! var out: std.ArrayList(u8) = .empty;
//! try Prefix(u32).append(&out, gpa, &.{ 2, 3, 5 }); // canonical bytes
//! var it = try Prefix(u32).Decoder.init(out.items);   // borrows `out`
//! while (try it.next()) |len| { _ = len; }
//! ```
//!
//! # What it deliberately does not do
//!
//! It does not own the bytes whose offsets it accumulates, and it does not
//! widen the sum the way upstream does. The cursor's running sum is checked
//! against `Element` on every row, so a slab whose offsets do not fit the
//! column's own width is refused rather than carried.

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
            /// The value cursor underneath, over the same borrowed slab. It
            /// carries this decoder's borrow: the `bytes` given to [`init`]
            /// must outlive the cursor, the same way `rle.zig`'s own value
            /// decoder borrows the slab it walks.
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

            /// The next row length, null at the end of the slab. A null row
            /// contributes nothing to the running sum, which is what upstream's
            /// `None` does in `PrefixValue::accumulate`
            /// (`prefix.rs:287-312`). The sum is checked as it goes, so a
            /// slab whose offsets do not fit `Element` is
            /// `error.Overflow` rather than a wrap.
            ///
            /// **For a nullable `T` such as `Prefix(?u32)` the return is
            /// `??u32`, and the two nulls are different things.** The outer one
            /// is the end of the slab; the inner one is a row that is absent.
            /// An absent row stays distinct from the end of the slab, which is
            /// the same distinction [`rle.RleGeneric.Decoder.next`] draws for
            /// `RleOption`: a caller that stops at the first `null` reads a
            /// truncated column. `while (try it.next()) |len|` is the loop, and
            /// a nullable column wants the inner value tested against null.
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
                // (`rle.zig:410`).
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

test "prefix_iter_ranges_totals" {
    // **`tests.rs:1503-1517`.** Over the windows `2..4` and `10..12` of a
    // prefix column holding `1..=20`, each row reports
    // `(value, running total)` = `(3,6)`, `(4,10)`, `(11,66)`, `(12,78)`.
    //
    // **`Shiftable::ranges` has no counterpart in the port** — no file under
    // `src/hexane` defines a `ranges` combinator, and `column.zig` implements
    // only the four `Shiftable` defaults (`setMax`, `advanceTo`, `shift`,
    // `seekTo`). So the two windows are two stretches of **one** decoder,
    // stepped past in between, which is what the adapter yields. **What is
    // therefore not covered is the adapter's own chaining.**
    //
    // The arithmetic upstream states is `(i+1)(i+2)/2` at row `i`, which is
    // the sum of `1..=i+1`; it is written out here per row rather than
    // recomputed in the loop, so a decoder that drifted would be caught by
    // the numbers and not by an expression that drifted with it.
    const gpa = testing.allocator;
    const P = Prefix(u64);
    var values: [20]u64 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i + 1);

    const bytes = try gpa.alloc(u8, P.encodedSize(&values));
    defer gpa.free(bytes);
    P.write(bytes, &values);

    var dec = try P.Decoder.init(bytes);

    // The first two rows, to reach window `2..4`.
    _ = try dec.next();
    _ = try dec.next();
    {
        const row = (try dec.next()).?;
        try testing.expectEqual(@as(u64, 3), row);
        try testing.expectEqual(@as(u64, 6), dec.total());
    }
    {
        const row = (try dec.next()).?;
        try testing.expectEqual(@as(u64, 4), row);
        try testing.expectEqual(@as(u64, 10), dec.total());
    }
    // Six rows of gap, so the window `10..12` is reached by stepping, not by
    // seeking — the adapter advances, and nothing in the port can seek here.
    for (0..6) |_| _ = try dec.next();
    {
        const row = (try dec.next()).?;
        try testing.expectEqual(@as(u64, 11), row);
        try testing.expectEqual(@as(u64, 66), dec.total());
    }
    {
        const row = (try dec.next()).?;
        try testing.expectEqual(@as(u64, 12), row);
        try testing.expectEqual(@as(u64, 78), dec.total());
    }
}

// ── The differential corpus ──────────────────────────────────────────────────

const corpus = @import("codec_golden.zig");
const btree = @import("btree.zig");

/// The boundary cases the prefix corpus has to carry.
///
/// The `length_*` cases are where a row length's own LEB128 width changes,
/// `diverges_first` / `diverges_last` / `diverges_both` are the shapes where
/// a run of equal lengths is broken at one end or the other,
/// `zero_in_middle` is where a row of no length leaves the sum where it was,
/// and `null_runs` is where a run of absent rows has to keep its own slots.
const prefix_boundary_cases = [_][]const u8{
    "empty",
    "one",
    "zero_length",
    "zero_lengths_5",
    "all_equal_64",
    "length_2",
    "length_63",
    "length_64",
    "length_127",
    "length_128",
    "length_16383",
    "length_16384",
    "pair_0",
    "boundary_lengths",
    "diverges_first",
    "diverges_last",
    "diverges_both",
    "zero_in_middle",
    "null_alone",
    "null_then_length",
    "length_then_null",
    "nulls_between",
    "null_runs",
    "random_0",
    "random_12",
    "random_23",
};

/// A prefix slot as the number it holds, or `null` for an absent one.
///
/// A slot is never absent on the way out: `prefixArray` writes the running
/// total into every slot including a null row's, which is what keeps the
/// transform reversible (`prefix.zig:196-204`).
fn slotValue(comptime Payload: type, v: Payload) ?i128 {
    switch (@typeInfo(Payload)) {
        .optional => {
            if (v) |x| return @intCast(x);
            return null;
        },
        else => return @intCast(v),
    }
}

/// The row length of one column value, which is zero when the row is absent
/// (`prefix.rs:287-312`).
fn rowLength(comptime Payload: type, v: Payload) i64 {
    const at = slotValue(Payload, v) orelse return 0;
    return std.math.cast(i64, at) orelse std.math.maxInt(i64);
}

/// The running-sum increment of one slab aggregate, for `findByPrefixSum`.
fn prefixIncrement(a: btree.SlabAgg) i64 {
    return a.total;
}

/// Checks a prefix array against the reference's `get_prefix` for every
/// index.
fn expectPrefixSlots(
    comptime E: type,
    rec: corpus.Record,
    want: []const []const u8,
    got: []const E,
) !void {
    try testing.expectEqual(want.len, got.len);
    // The reference's sums are the payload's own numbers: an optional slot
    // holds a payload, and a running sum is never absent.
    const Payload = switch (@typeInfo(E)) {
        .optional => |o| o.child,
        else => E,
    };
    for (want, got, 0..) |_, g, k| {
        // **The two arrays are one slot apart, and the port's is the one that
        // is shifted.** A prefix array's slot `k` holds the sum *through* row
        // `k` (`prefix.zig:18-26`), while the reference's `get_prefix(i)` is
        // the *exclusive* sum before row `i` (`prefix.rs:544-547`). So slot
        // `k` is the reference's `get_prefix(k + 1)` — its `get_total(k)` —
        // and the last slot, which holds the grand total, is the reference's
        // `get_prefix(len)`: the one index both arrays agree on.
        const at = @min(k + 1, want.len - 1);
        const expected = std.fmt.parseInt(Payload, want[at], 10) catch |e| {
            std.debug.print("prefix corpus value `{s}` does not fit {s}\n", .{ want[at], @typeName(Payload) });
            return e;
        };
        const actual = slotValue(E, g) orelse {
            std.debug.print("prefix slot {d} is absent; a prefix slot never is\n", .{k});
            return error.PrefixSumAbsent;
        };
        if (actual == @as(i128, @intCast(expected))) continue;
        std.debug.print(
            \\
            \\--- prefix sum mismatch -----------------------------------------------
            \\  codec      {s}
            \\  case       {s}
            \\  seed       {s}
            \\  slot       {d} of {d}
            \\  reference  {s} (get_prefix({d}))
            \\  this port  {d}
            \\
        , .{ rec.codec, rec.case, rec.seed, k, want.len, want[at], at, actual });
        return error.PrefixSumMismatch;
    }
}

/// The index of `needle` in `hay`, for the message above. The corpus's sums
/// are strictly increasing, so the first match is the slot.
fn indexOfSlot(hay: []const []const u8, needle: []const u8) usize {
    for (hay, 0..) |h, i| {
        if (std.mem.eql(u8, h, needle)) return i;
    }
    return hay.len;
}

/// Checks that a prefix array this port refused is one the reference could
/// only have produced with a wider sum.
///
/// **The documented deviation, turned into an assertion.** Upstream
/// accumulates a `u32` column's lengths into a `u64` and a `u64` column's
/// into a `u128` (`prefix.rs:259-266`); this port accumulates into the
/// column's own element type, so a sum that leaves it is `error.Overflow`
/// rather than a number. That is allowed here **only** where the
/// reference's own answer no longer fits — anywhere else it is a narrowing
/// bug rather than the deviation, and the two are told apart by this
/// function.
fn expectNarrowing(
    comptime E: type,
    rec: corpus.Record,
    want: []const []const u8,
    e: anyerror,
) !void {
    if (e != error.Overflow) return e;
    var biggest: i128 = 0;
    for (want) |w| {
        const v = std.fmt.parseInt(i128, w, 10) catch return error.CorpusValueTooLarge;
        biggest = @max(biggest, v);
    }
    const cap: i128 = switch (@typeInfo(E)) {
        .optional => |o| std.math.maxInt(o.child),
        else => std.math.maxInt(E),
    };
    if (biggest > cap) return;
    std.debug.print(
        \\
        \\--- prefix narrowing ----------------------------------------------
        \\  codec     {s}
        \\  case      {s}
        \\  seed      {s}
        \\  the port refused a running sum the reference holds: its largest is
        \\  {d}, and {s} holds up to {d}
        \\
    , .{ rec.codec, rec.case, rec.seed, biggest, @typeName(E), cap });
    return error.PrefixSumNarrowing;
}

/// Holds a prefix column's slab search against the reference's
/// `get_index_for_prefix`.
///
/// The reference answers with an **item index**: it finds the slab the
/// prefix target lands in and then scans that slab (`prefix.rs:605-617`).
/// The port's tree stops at the slab, so what is compared is that the
/// reference's index lies in the slab the port's descent reached, and that
/// the running sum and item count the port reports for that slab are the
/// ones the partition puts in front of it. Both entry points into that
/// descent are checked, because they are two implementations of it.
fn expectPrefixSearch(
    gpa: std.mem.Allocator,
    comptime E: type,
    rec: corpus.Record,
    values: []const E,
    targets: []const []const u8,
    answers: []const []const u8,
) !void {
    // Three rows per slab, so a long case is a tree with a second level and
    // a short one is a single leaf.
    const chunk: usize = 3;
    var aggs: std.ArrayList(btree.SlabAgg) = .empty;
    defer aggs.deinit(gpa);
    var lens: std.ArrayList(usize) = .empty;
    defer lens.deinit(gpa);
    // The running sum at the first row of each slab, plus one at the end.
    var sums: std.ArrayList(i64) = .empty;
    defer sums.deinit(gpa);
    try sums.append(gpa, 0);
    var at: usize = 0;
    while (at < values.len) {
        const end = @min(at + chunk, values.len);
        var total: i64 = 0;
        for (values[at..end]) |v| {
            total = std.math.add(i64, total, rowLength(E, v)) catch return error.CorpusValueTooLarge;
        }
        const n = end - at;
        try aggs.append(gpa, .{
            .len = n,
            .total = total,
            // A length column's sum never decreases, so the slab's offsets
            // run from zero to its own total.
            .min_offset = @min(total, 0),
            .max_offset = @max(total, 0),
        });
        try lens.append(gpa, n);
        try sums.append(gpa, sums.items[sums.items.len - 1] + total);
        at = end;
    }

    var tree = try btree.SlabBTree.fromSlice(gpa, aggs.items);
    defer tree.deinit();

    for (targets, answers) |target, answer| {
        const t = std.math.cast(i64, std.fmt.parseInt(i128, target, 10) catch return error.CorpusValueTooLarge) orelse return error.CorpusValueTooLarge;
        const want_index = std.fmt.parseInt(usize, answer, 10) catch return error.CorpusValueTooLarge;
        const hit = tree.findByPrefixSum(prefixIncrement, t);
        const by_fn = btree.findSlabAtPrefix(&tree, t);
        try testing.expectEqual(hit.slab, by_fn.index);
        try testing.expectEqual(hit.items_before, by_fn.items_before);
        try testing.expectEqual(hit.prefix_before, by_fn.prefix);

        if (values.len == 0) {
            // An empty column answers before the index is consulted: zero
            // for a target at or below zero, `len + 1` for the rest
            // (`prefix.rs:605-609`).
            try testing.expectEqual(if (t <= 0) @as(usize, 0) else values.len + 1, want_index);
            try testing.expectEqual(tree.len(), hit.slab);
            continue;
        }
        if (hit.slab >= tree.len()) {
            // A target the column's prefix sums never reach is the
            // one-past-the-end answer, which the port reports as the slab
            // past the last one (`prefix.rs:611-617`).
            try testing.expectEqual(values.len + 1, want_index);
            continue;
        }
        // The reference's index lands in the slab the port's descent reached,
        // **or exactly at its end**: a target equal to the slab's own total is
        // first reached one row past the slab's last, and the reference
        // returns that index rather than the one-past-the-end answer
        // (`prefix.rs:605-617` scans the slab before it gives up).
        if (want_index < hit.items_before or
            want_index > hit.items_before + lens.items[hit.slab] or
            sums.items[hit.slab] != hit.prefix_before)
        {
            std.debug.print(
                \\
                \\--- prefix search mismatch --------------------------------------
                \\  codec     {s}
                \\  case      {s}
                \\  seed      {s}
                \\  target    {s}
                \\  reference index {d}
                \\  this port slab {d} of {d}, items before {d}, sum before {d}
                \\
            , .{ rec.codec, rec.case, rec.seed, target, want_index, hit.slab, tree.len(), hit.items_before, hit.prefix_before });
            return error.PrefixSearchMismatch;
        }
    }
}

/// The six column types the prefix corpus carries.
///
/// **`i32` is absent and cannot be added**: the reference has no
/// `PrefixValue for i32` (`prefix.rs:239-284`), so there is no
/// `get_index_for_prefix` to compare against. The port's `Prefix(i32)` wire
/// format is the RLE one and is covered by the `rle-i32` records.
///
/// A table of `(name, tag)` pairs rather than a `switch` on the name: Zig
/// will not switch on a `[]const u8`, and the codec type has to be known at
/// compile time. `corpus.dispatch` walks this with an `inline for`.
const PrefixKind = enum { u32, u64, i64, opt_u32, opt_u64, opt_i64 };

const prefix_kinds = [_]struct { name: []const u8, tag: PrefixKind }{
    .{ .name = "prefix-u32", .tag = .u32 },
    .{ .name = "prefix-u64", .tag = .u64 },
    .{ .name = "prefix-i64", .tag = .i64 },
    .{ .name = "prefix-opt-u32", .tag = .opt_u32 },
    .{ .name = "prefix-opt-u64", .tag = .opt_u64 },
    .{ .name = "prefix-opt-i64", .tag = .opt_i64 },
};

/// The whole prefix check for one column type: the bytes, the prefix array
/// from both directions, and the slab search.
fn checkPrefix(
    comptime C: type,
    comptime Wire: type,
    gpa: std.mem.Allocator,
    rec: corpus.Record,
) !void {
    const E = C.Element;
    const values = try corpus.expand(gpa, E, rec);
    defer gpa.free(values);
    const want = try corpus.referenceBytes(gpa, rec);
    defer gpa.free(want);

    // `Prefix`'s own writer first, and then the RLE codec the column stores
    // its rows in: a prefix column is an ordinary RLE column of lengths
    // (`prefix.rs:414-415`), so both have to produce the reference's bytes
    // and the second comparison is what says the two really are the same
    // format rather than coincidentally agreeing on this corpus.
    const out = try gpa.alloc(u8, C.encodedSize(values));
    defer gpa.free(out);
    C.write(out, values);
    try corpus.checkBytes(rec, want, out);
    const wire = try gpa.alloc(u8, Wire.encodedSize(values));
    defer gpa.free(wire);
    Wire.write(wire, values);
    try corpus.checkBytes(rec, want, wire);

    const sums = rec.prefixes orelse return error.CorpusRecordMissing;
    try testing.expectEqual(rec.len + 1, sums.len);

    // The prefix array decoded out of the port's own bytes. This is the
    // direction that matters: the reference's sums, read back out of bytes
    // this port wrote.
    if (C.decodePrefix(out, gpa)) |decoded| {
        defer gpa.free(decoded);
        try expectPrefixSlots(E, rec, sums, decoded);
    } else |e| try expectNarrowing(E, rec, sums, e);

    // And the same array built straight from the input, which never touches
    // the wire at all.
    if (C.prefixArray(gpa, values)) |built| {
        defer gpa.free(built);
        try expectPrefixSlots(E, rec, sums, built);
    } else |e| try expectNarrowing(E, rec, sums, e);

    // The slab search, where the reference has the method at all. A signed
    // prefix column accumulates into `i128`, which is not an
    // `UnsignedPrefix` (`prefix.rs:249-256`, `:588-621`), so the reference
    // reports no answer and there is nothing to compare.
    if (rec.indexes) |answers| {
        const targets = rec.index_targets orelse return error.CorpusRecordMissing;
        try testing.expectEqual(targets.len, answers.len);
        try expectPrefixSearch(gpa, E, rec, values, targets, answers);
    }
}

fn prefixCaseFor(kind: PrefixKind, rec: corpus.Record, gpa: std.mem.Allocator) !void {
    switch (kind) {
        .u32 => try checkPrefix(Prefix(u32), rle.Rle(u32), gpa, rec),
        .u64 => try checkPrefix(Prefix(u64), rle.Rle(u64), gpa, rec),
        .i64 => try checkPrefix(Prefix(i64), rle.Rle(i64), gpa, rec),
        .opt_u32 => try checkPrefix(Prefix(?u32), rle.RleOption(u32), gpa, rec),
        .opt_u64 => try checkPrefix(Prefix(?u64), rle.RleOption(u64), gpa, rec),
        .opt_i64 => try checkPrefix(Prefix(?i64), rle.RleOption(i64), gpa, rec),
    }
}

fn prefixCase(rec: corpus.Record, gpa: std.mem.Allocator) !void {
    try corpus.dispatch(prefix_kinds, prefixCaseFor, gpa, rec);
}

test "the prefix codec matches the reference's bytes, sums and slab search" {
    const gpa = testing.allocator;
    var names = corpus.Names.init(gpa);
    defer names.deinit();

    const cases = try corpus.eachCase(gpa, "prefix", &names, prefixCase);
    try testing.expectEqual(@as(usize, 465), cases);
    try names.expectRequired(&prefix_boundary_cases);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`prefix_iter_ranges_totals` is spelled over `Prefix(u64).Decoder` and
//   names no column.** The case's content is `(value, running total)` for four
//   rows of a prefix column, and `Decoder.next` / `Decoder.total` are exactly
//   upstream's `PrefixedValue::value` / `total` (`prefix.rs:287-312`,
//   `prefix.rs:549-555`).
//
// * **`Shiftable::ranges` is `column.Ranges`, and it lives beside the cursors
//   it drives.** Upstream builds it as a free adapter over a `Shiftable`
//   iterator (`shift.rs:102-126`), and the port's cursors are column types:
//   `Column.Iterator`, `Column.Runs` and `Column.PrefixIter` each already
//   carry the kernel it needs — `pos`, `setMax`, `shift` (`column.zig:2271`,
//   `:2312`, `:1947`, `:1957`) — and `column.zig` already owns the trait and
//   the other two adapters built on it (`Shiftable`, `Unshift`). **A second
//   copy here would be the second-codec-convention problem**, so this file
//   names the adapter and the rule it implements and holds no code for it.
//
//   The rule, in one sentence: **each window is shifted onto in turn, and what
//   remains of the current window is discarded** (`shift.rs:92-95` empties the
//   window at construction so the first `next` pulls the first range; `:113-124`
//   is the loop). An empty window contributes nothing and the next one is
//   taken at once; a window that starts *behind* the cursor is
//   `error.InvalidValue`, which is where upstream's
//   `assert!(r.start >= self.iter.get_pos())` (`shift.rs:119-122`) refuses
//   rather than returning. What this file cannot show is the adapter over a
//   *prefix* cursor — `ranges_chains_windows` and
//   `ranges_touching_equals_union` need a `Column`, so they are pinned
//   against one in `column.zig`.
//
// * **`ranges_touching_equals_union` is not this file's
//   `normalizeSplices`.** Two touching windows `10..15, 15..20` are upstream's
//   `normalize_ranges` (`column.rs:695`); `raw.zig`'s `normalizeSplices`
//   (`raw.zig:788`) mirrors `normalize_splices` (`column.rs:731`), which
//   clamps *source byte ranges* and merges splices contiguous in both
//   destination and source. **Different operation, same-looking name** — using
//   one for the other would be testing the wrong rule.
//
// * **`prefix_iter_runs_splices` is a column-level case, and the half that was
//   reachable here is not the case.** It splices one column's
//   `iter_range(..).runs()` into another, which is
//   `PrefixColumn::splice_runs` (`prefix.rs:523`) over `PrefixIter.runs`
//   (`column.zig:2266`) into a `PrefixColumn` splice. Only the sum half has a
//   path below — `prefixArray` then `offsetAt` — and that half on its own is
//   not the case: what it asserts is that the spliced *values* are the
//   source's and that `get_prefix` agrees with them afterwards, which is a
//   statement about two columns and not about the running sum. It is pinned
//   in `column.zig`, where `PrefixIter.runs` and the splice live together.
