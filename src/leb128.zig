//! LEB128 encoding, as used by the columnar format and the change encoder.
//!
//! Zig's standard library has no LEB128: the only copy in `std` is an internal
//! one in the DWARF parser. This is the port's own.
//!
//! Three properties matter for compatibility and are enforced by tests:
//!
//! * A value is encoded in at most ten bytes; the tenth byte contributes one
//!   bit unsigned and a whole byte of sign extension signed.
//! * An overlong encoding — one that spends a byte the value did not need — is
//!   a parse error, not a silently accepted value. Upstream draws the same
//!   line in its in-tree reader: a zero terminator anywhere but the first
//!   byte for an unsigned value, and a terminator that continues the sign of
//!   the byte before it for a signed one, are `Leb128Overlong`
//!   (`rust/automerge/src/storage/parse/leb128.rs:32-33`, `:63-65`).
//! * Reading consumes only the bytes the encoding actually needs, so a
//!   decoder can keep reading from the same cursor afterwards.
//!
//! ## At which widths is an overlong encoding refused?
//!
//! **At every one, on both signs.** That is worth stating separately, because
//! upstream's own error tables do not show it: `storage/parse/leb128.rs:132-149`
//! and `:235-262` carry five refusal rows between them and every one of them is
//! two or three bytes wide. The rules at `:29-38` and `:57-74` have no width in
//! them at all, so what they do at widths four through ten is a property of the
//! rule rather than of the table, and the table cannot be used to answer it.
//!
//! The two rules get there differently and the difference is the whole story.
//! The unsigned one reads the terminator's payload alone, and a non-minimal
//! unsigned encoding always ends in a `0x00` after at least one byte, so one
//! condition catches every width. The signed one also reads the **penultimate**
//! byte, because `0x00` and `0x7f` are both legitimate terminators and only the
//! byte before distinguishes them — and that extra term is not a gap. LEB128
//! groups are positional, so a longer encoding of one value differs from the
//! canonical one only by groups that carry no information, and those groups are
//! `0x00` above a non-negative value and `0x7f` above a negative one. The byte
//! in front of the terminator is therefore a canonical group every time, and it
//! is the arm of the rule that refuses it. The tests at the bottom of this file
//! build that construction for every width, both signs and every extension
//! length that fits, and the random sweep states the same thing without having
//! to know it: whatever the decoder accepts must re-encode to itself, byte for
//! byte, and the sweep checks that over twenty thousand random buffers.

const std = @import("std");
const err = @import("error.zig");

const ParseError = err.ParseError;

/// The maximum number of bytes a u64 occupies: nine whole bytes plus one
/// bit-carrying byte.
pub const max_unsigned_size = 10;
/// The maximum number of bytes an i64 occupies, which is the same ten: the
/// tenth byte carries the sign and a whole byte of sign extension where the
/// unsigned tenth byte carries a single bit (see the module doc).
///
/// It is the size of the stack buffer `appendSigned` and `writeSigned` use,
/// so a caller sizing one of its own needs no arithmetic.
pub const max_signed_size = 10;

/// The number of bytes `writeUnsigned` will emit for `value`, which must be a
/// non-negative integer no wider than `u64`. A signed argument is clamped at
/// zero here, so it answers for `0` where `writeUnsigned` refuses the same
/// value: clamp with `@max(value, 0)` before calling either.
pub fn unsignedSize(value: anytype) usize {
    const v: u64 = @intCast(@max(value, 0));
    var n: usize = 1;
    var rest = v >> 7;
    while (rest != 0) : (n += 1) rest >>= 7;
    return n;
}

/// The number of bytes `writeSigned` will emit for `value`, which must be an
/// integer no wider than `i64` — `@intCast` refuses anything wider at compile
/// time, so the domain is checked where it is written down rather than at
/// run time. It runs the same loop as the encoder, so the two cannot
/// disagree.
pub fn signedSize(value: anytype) usize {
    const v: i64 = @intCast(value);
    var n: usize = 1;
    var rest = v;
    while (true) {
        const byte: u8 = @truncate(@as(u64, @bitCast(rest)) & 0x7f);
        rest >>= 7;
        const sign_bit_set = (byte & 0x40) != 0;
        if ((rest == 0 and !sign_bit_set) or (rest == -1 and sign_bit_set)) return n;
        n += 1;
    }
}

/// Writes `value` as unsigned LEB128 into `out`, returning the bytes written.
/// The caller guarantees `out` has room; use `unsignedSize` to size it.
///
/// `value` must be a non-negative integer no wider than `u64`, and the
/// `@intCast` is what enforces it: a negative or a wider integer traps in
/// Debug and ReleaseSafe rather than encoding a wrapped one. This is the
/// domain `unsignedSize` assumes, and the two disagree on a negative
/// argument on purpose — there is one shape for the caller to hold to.
pub fn writeUnsigned(out: []u8, value: anytype) usize {
    var v: u64 = @intCast(value);
    var i: usize = 0;
    while (v >= 0x80) {
        out[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
        i += 1;
    }
    out[i] = @truncate(v);
    return i + 1;
}

/// Writes `value` as signed LEB128 into `out`, returning the bytes written.
/// The caller guarantees `out` has room; use `signedSize` to size it.
///
/// `value` must be an integer no wider than `i64`, the domain `signedSize`
/// shares and the `@intCast` here enforces at compile time.
pub fn writeSigned(out: []u8, value: anytype) usize {
    var v: i64 = @intCast(value);
    var i: usize = 0;
    while (true) {
        // Only the low seven bits of the value belong in the byte; the eighth
        // bit is the continuation flag.
        const byte: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7f);
        v >>= 7;
        const sign_bit_set = (byte & 0x40) != 0;
        if ((v == 0 and !sign_bit_set) or (v == -1 and sign_bit_set)) {
            out[i] = byte;
            return i + 1;
        }
        out[i] = byte | 0x80;
        i += 1;
    }
}

/// Reads an unsigned LEB128 from `in`, returning the value and the number of
/// bytes consumed. **Exactly the bytes the encoding needed are consumed**, so
/// a caller reads the next value from `in[n.len..]`.
///
/// * `error.UnexpectedEnd` — `in` ran out mid-value, a missing last byte
///   included.
/// * `error.InvalidLeb128` — the encoding is overlong: a zero group above a
///   non-zero one, or an eleventh byte (`storage/parse/leb128.rs:32-33`).
/// * `error.Overflow` — the tenth byte carries more than the one bit that is
///   left, or a group would sit above bit 64.
///
/// The three are distinct on purpose: a truncated stream is not an overlong
/// encoding, and neither is a value too wide for a `u64`.
pub fn readUnsigned(in: []const u8) ParseError!struct { value: u64, len: usize } {
    if (in.len == 0) return error.UnexpectedEnd;
    const first = in[0];
    if (first & 0x80 == 0) return .{ .value = first, .len = 1 };
    if (in.len < 2) return error.UnexpectedEnd;
    const second = in[1];
    const result = @as(u64, first & 0x7f) | (@as(u64, second & 0x7f) << 7);
    if (second & 0x80 == 0) {
        if (second == 0) return error.InvalidLeb128;
        return .{ .value = result, .len = 2 };
    }
    const longer = try readLong(false, in, result);
    return .{ .value = longer.value, .len = longer.len };
}

/// Reads a signed LEB128 from `in`, returning the value and bytes consumed.
/// **Exactly the bytes the encoding needed are consumed**, so a caller reads
/// the next value from `in[n.len..]`.
///
/// * `error.UnexpectedEnd` — `in` ran out mid-value, a missing last byte
///   included.
/// * `error.InvalidLeb128` — the encoding is overlong, which here is a
///   terminator that continues the sign of the byte before it, or an
///   eleventh byte (`storage/parse/leb128.rs:63-65`).
/// * `error.Overflow` — the tenth byte is neither all zeros nor all ones, or
///   a group above bit 64 is neither.
///
/// The three are the same three the unsigned reader reports, under the same
/// rule and with the same meaning.
pub fn readSigned(in: []const u8) ParseError!struct { value: i64, len: usize } {
    if (in.len == 0) return error.UnexpectedEnd;
    const first = in[0];
    if (first & 0x80 == 0) {
        const value: i8 = @bitCast(first << 1);
        return .{ .value = value >> 1, .len = 1 };
    }
    if (in.len < 2) return error.UnexpectedEnd;
    const second = in[1];
    var result = @as(u64, first & 0x7f) | (@as(u64, second & 0x7f) << 7);
    if (second & 0x80 == 0) {
        if ((second == 0 and first & 0x40 == 0) or
            (second == 0x7f and first & 0x40 != 0)) return error.InvalidLeb128;
        if (second & 0x40 != 0) result |= ~@as(u64, 0) << 14;
        return .{ .value = @bitCast(result), .len = 2 };
    }
    const longer = try readLong(true, in, result);
    return .{ .value = @bitCast(longer.value), .len = longer.len };
}

fn readLong(
    comptime signed: bool,
    in: []const u8,
    initial: u64,
) ParseError!struct { value: u64, len: usize } {
    // The caller has checked and consumed two continuation bytes. Fixed
    // shifts 14..56 never discard payload bits; each load is guarded before
    // it happens, and a terminator returns before inspecting later bytes.
    var result = initial;
    inline for (2..9) |index| {
        if (in.len <= index) return error.UnexpectedEnd;
        const byte = in[index];
        const payload: u64 = byte & 0x7f;
        result |= payload << (index * 7);
        if (byte & 0x80 == 0) {
            if (signed) {
                const previous = in[index - 1];
                if ((payload == 0 and previous & 0x40 == 0) or
                    (payload == 0x7f and previous & 0x40 != 0)) return error.InvalidLeb128;
                if (byte & 0x40 != 0) result |= ~@as(u64, 0) << ((index + 1) * 7);
            } else if (payload == 0) return error.InvalidLeb128;
            return .{ .value = result, .len = index + 1 };
        }
    }
    if (in.len < 10) return error.UnexpectedEnd;
    const byte = in[9];
    const payload: u64 = byte & 0x7f;
    // Overflow precedes both canonicality and continuation/EOF checks,
    // including an overflowing tenth byte with its continuation bit set.
    if (signed) {
        if (payload == 0x7f) {
            result |= @as(u64, 1) << 63;
        } else if (payload != 0) return error.Overflow;
    } else {
        if (payload > 1) return error.Overflow;
        result |= payload << 63;
    }
    if (byte & 0x80 == 0) {
        if (signed) {
            if ((payload == 0 and in[8] & 0x40 == 0) or
                (payload == 0x7f and in[8] & 0x40 != 0)) return error.InvalidLeb128;
        } else if (payload == 0) return error.InvalidLeb128;
        return .{ .value = result, .len = 10 };
    }
    // The original loop checked EOF before its ten-byte length limit.
    if (in.len == 10) return error.UnexpectedEnd;
    return error.InvalidLeb128;
}

/// Appends `value` as unsigned LEB128 to `list`. `value` is
/// `writeUnsigned`'s domain: a non-negative integer no wider than `u64`.
///
/// The only error reachable is `error.OutOfMemory`, and **nothing is
/// appended when it fires**: the encoding is copied in as one piece, so a
/// list that took a failure is byte for byte the list it was.
pub fn appendUnsigned(list: *std.ArrayList(u8), gpa: std.mem.Allocator, value: anytype) !void {
    var buf: [max_unsigned_size]u8 = undefined;
    const n = writeUnsigned(&buf, value);
    try list.appendSlice(gpa, buf[0..n]);
}

/// Appends `value` as signed LEB128 to `list`. `value` is `writeSigned`'s
/// domain: an integer no wider than `i64`.
///
/// The only error reachable is `error.OutOfMemory`, and **nothing is
/// appended when it fires**, as `appendUnsigned` says.
pub fn appendSigned(list: *std.ArrayList(u8), gpa: std.mem.Allocator, value: anytype) !void {
    var buf: [max_signed_size]u8 = undefined;
    const n = writeSigned(&buf, value);
    try list.appendSlice(gpa, buf[0..n]);
}

test "unsigned sizes and round trip" {
    const cases = [_]u64{ 0, 1, 127, 128, 255, 300, 16383, 16384, 1 << 32, std.math.maxInt(u64) };
    for (cases) |v| {
        var buf: [max_unsigned_size]u8 = undefined;
        const n = writeUnsigned(&buf, v);
        try std.testing.expectEqual(unsignedSize(v), n);
        const got = try readUnsigned(buf[0..n]);
        try std.testing.expectEqual(v, got.value);
        try std.testing.expectEqual(n, got.len);
    }
}

test "signed sizes and round trip" {
    const cases = [_]i64{ 0, 1, -1, 63, -64, 127, -128, 300, -300, 1 << 40, -(1 << 40) };
    for (cases) |v| {
        var buf: [max_signed_size]u8 = undefined;
        const n = writeSigned(&buf, v);
        try std.testing.expectEqual(signedSize(v), n);
        const got = try readSigned(buf[0..n]);
        try std.testing.expectEqual(v, got.value);
        try std.testing.expectEqual(n, got.len);
    }
    try std.testing.expectEqual(std.math.minInt(i64), (try readSigned(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f })).value);
    try std.testing.expectEqual(std.math.maxInt(i64), (try readSigned(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 })).value);
    // A tenth byte with a payload that is neither zeros nor ones is not a
    // sign extension of bit 63.
    try std.testing.expectError(
        error.Overflow,
        readSigned(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 }),
    );
}

test "encoding consumes only its own bytes" {
    const in = [_]u8{ 0x80, 0x01, 0xaa, 0xbb };
    const r = try readUnsigned(&in);
    try std.testing.expectEqual(@as(u64, 128), r.value);
    try std.testing.expectEqual(@as(usize, 2), r.len);
}

test "malformed input is rejected, never trapped" {
    // Truncated: every byte has the continuation bit.
    try std.testing.expectError(error.UnexpectedEnd, readUnsigned(&[_]u8{ 0x80, 0x80 }));
    // Overlong: eleven bytes.
    try std.testing.expectError(error.InvalidLeb128, readUnsigned(&@as([11]u8, @splat(0x80))));
    // Tenth byte carries more than the one bit left.
    try std.testing.expectError(
        error.Overflow,
        readUnsigned(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 }),
    );
    // Empty input.
    try std.testing.expectError(error.UnexpectedEnd, readUnsigned(&[_]u8{}));
    try std.testing.expectError(error.UnexpectedEnd, readSigned(&[_]u8{}));
}

// One half of every overlong test: the short form must still read. A reader
// that refuses both is not strict, it is broken, and the refusal assertions
// would pass just as well. These are upstream's own success tables, every row
// of them, so the two halves cannot drift apart.
test "the canonical short form of a value is still accepted" {
    // `storage/parse/leb128.rs:161-170`, the u64 table.
    const u_cases = [_]struct { in: []const u8, want: u64 }{
        .{ .in = &[_]u8{0x00}, .want = 0 },
        .{ .in = &[_]u8{0x7f}, .want = 127 },
        .{ .in = &[_]u8{ 0x80, 0x01 }, .want = 128 },
        .{ .in = &[_]u8{ 0xff, 0x7f }, .want = 16383 },
        .{ .in = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, .want = std.math.maxInt(u64) },
    };
    for (u_cases) |c| {
        const got = try readUnsigned(c.in);
        try std.testing.expectEqual(c.want, got.value);
        try std.testing.expectEqual(c.in.len, got.len);
    }

    // `storage/parse/leb128.rs:274-290`, the i64 table, plus the payload
    // `counter_value_is_ok.automerge` carries: 2000 in two bytes.
    const i_cases = [_]struct { in: []const u8, want: i64 }{
        .{ .in = &[_]u8{0x00}, .want = 0 },
        .{ .in = &[_]u8{0x7f}, .want = -1 },
        .{ .in = &[_]u8{0x3f}, .want = 63 },
        .{ .in = &[_]u8{0x40}, .want = -64 },
        .{ .in = &[_]u8{ 0x80, 0x01 }, .want = 128 },
        .{ .in = &[_]u8{ 0xff, 0x3f }, .want = 8191 },
        .{ .in = &[_]u8{ 0x80, 0x40 }, .want = -8192 },
        .{ .in = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 }, .want = std.math.maxInt(i64) },
        .{ .in = &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f }, .want = std.math.minInt(i64) },
        .{ .in = &[_]u8{ 0xd0, 0x0f }, .want = 2000 },
    };
    for (i_cases) |c| {
        const got = try readSigned(c.in);
        try std.testing.expectEqual(c.want, got.value);
        try std.testing.expectEqual(c.in.len, got.len);
    }
}

// The other half: the same values, one byte more than they need, refused. The
// first case of every group is upstream's own error vector; the rest are the
// same rule at the neighbouring lengths. Upstream's error tables are
// `storage/parse/leb128.rs:144-146` (u64), `:197-199` (u32) and `:252-259`
// (i64), and the two readers that produce them are `:15-40` and `:42-76`.
test "an overlong encoding is refused, signed and unsigned alike" {
    // Unsigned: a zero terminator anywhere but the first byte
    // (`storage/parse/leb128.rs:32-33`). Upstream's vector is `[129, 0]`,
    // which is `1` in two bytes.
    try std.testing.expectError(error.InvalidLeb128, readUnsigned(&[_]u8{ 0x81, 0x00 }));
    // `0` in two bytes, and `127` in three.
    try std.testing.expectError(error.InvalidLeb128, readUnsigned(&[_]u8{ 0x80, 0x00 }));
    try std.testing.expectError(error.InvalidLeb128, readUnsigned(&[_]u8{ 0xff, 0x80, 0x00 }));
    // `0` in ten bytes: the same rule at the tenth byte, where the tenth
    // byte's own bounds check would otherwise let a zero payload through.
    try std.testing.expectError(error.InvalidLeb128, readUnsigned(&@as([9]u8, @splat(0x80)) ++ [_]u8{0x00}));

    // Signed, positive: a `0x00` terminator after a penultimate byte whose
    // sign bit is clear (`storage/parse/leb128.rs:63-65`). Upstream's vector is
    // `[0xbf, 0]` (`:252-254`), which is 63 in two bytes; `[0x85, 0x00]` is
    // the same rule at five, and `[0x80, 0x80, 0x00]` at three.
    try std.testing.expectError(error.InvalidLeb128, readSigned(&[_]u8{ 0xbf, 0x00 }));
    try std.testing.expectError(error.InvalidLeb128, readSigned(&[_]u8{ 0x85, 0x00 }));
    try std.testing.expectError(error.InvalidLeb128, readSigned(&[_]u8{ 0x80, 0x80, 0x00 }));
    // Signed, negative: a `0x7f` terminator after a penultimate byte whose
    // sign bit is set. Upstream's vector is `[0x81, 0xff, 0x7f]`, which is
    // -127 in three bytes; `[0xff, 0x7f]` is -1 in two.
    try std.testing.expectError(error.InvalidLeb128, readSigned(&[_]u8{ 0x81, 0xff, 0x7f }));
    try std.testing.expectError(error.InvalidLeb128, readSigned(&[_]u8{ 0xff, 0x7f }));
    // The exact payload of the `value` column in
    // `counter_value_is_overlong.automerge`: -48 in two bytes where the one
    // byte `0x40` would do. Upstream's reader refuses it at
    // `storage/parse/leb128.rs:63-65` and the load is an error
    // (`rust/automerge/tests/test.rs:2230-2231`).
    try std.testing.expectError(error.InvalidLeb128, readSigned(&[_]u8{ 0xd0, 0x7f }));
}

// The counterpart that keeps the refusal honest at the edges: a terminator
// that *changes* sign is canonical however many bytes precede it, and a
// terminator at the first byte is canonical whatever its payload. Upstream
// draws both lines in one `else if` chain (`storage/parse/leb128.rs:60-71`).
test "a terminator that changes sign is canonical however many bytes precede it" {
    // A `0x3f` terminator after a penultimate byte whose sign bit is *set*
    // (`storage/parse/leb128.rs:280`): the value is positive and complete, so
    // the terminator stops it rather than extending it.
    const a = try readSigned(&[_]u8{ 0xff, 0x3f });
    try std.testing.expectEqual(@as(i64, 8191), a.value);
    // A `0x40` terminator after a penultimate byte whose sign bit is *clear*
    // (`storage/parse/leb128.rs:281`): the mirror image, and negative.
    const b = try readSigned(&[_]u8{ 0x80, 0x40 });
    try std.testing.expectEqual(@as(i64, -8192), b.value);
    // `0x7f` after a penultimate byte whose sign bit is clear: -127, whose
    // canonical two-byte form this is.
    const c = try readSigned(&[_]u8{ 0x81, 0x7f });
    try std.testing.expectEqual(@as(i64, -127), c.value);
    // `0x00` after a penultimate byte whose sign bit is set, ten bytes deep:
    // maxInt(i64) (`storage/parse/leb128.rs:282-285`). The terminator is a
    // sign change, not an extension, at the very last byte.
    const d = try readSigned(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 });
    try std.testing.expectEqual(std.math.maxInt(i64), d.value);
}

/// Lowercase hex of `bytes`, into a caller-supplied buffer of `2 * len` bytes.
/// Only the failure reports use it, and they never nest.
fn hexOf(bytes: []const u8, buf: []u8) []const u8 {
    const digits = "0123456789abcdef";
    var n: usize = 0;
    for (bytes) |b| {
        buf[n * 2] = digits[b >> 4];
        buf[n * 2 + 1] = digits[b & 0xf];
        n += 1;
    }
    return buf[0 .. n * 2];
}

/// Report an encoding that is not the one the case calls for. Every case names
/// its value in the message, so the row can be found without re-running.
fn reportEncodingMismatch(
    comptime what: []const u8,
    value: anytype,
    got: []const u8,
    want: []const u8,
    seed: u64,
) error{CaseMismatch} {
    var gbuf: [2 * max_unsigned_size]u8 = undefined;
    var wbuf: [2 * max_unsigned_size]u8 = undefined;
    std.debug.print(
        \\
        \\--- leb128 {s} mismatch -----------------------------------------------
        \\  value    {d}
        \\  want     {s}
        \\  got      {s}
        \\  seed     0x{x:0>16}
        \\
        \\The bytes are the compatibility contract: every length, counter and actor
        \\index in the columnar format and the change encoder is one of these, so a
        \\difference here is a document the reference cannot read.
        \\
    , .{ what, value, hexOf(want, &wbuf), hexOf(got, &gbuf), seed });
    return error.CaseMismatch;
}

// ── the boundaries, one row per width ───────────────────────────────────────
//
// A round trip proves the two halves agree with each other. It does not prove
// either agrees with the format, and a decoder and an encoder that are both
// wrong the same way round trip perfectly. These tables therefore carry the
// bytes themselves. The rows marked with a citation are upstream's own success
// tables (`storage/parse/leb128.rs:161-170` unsigned, `:274-290` signed); the
// rest are the width boundaries the format fixes, so that every width from one
// to ten is pinned on both sides.
test "every unsigned width round trips at its own boundary, with the bytes" {
    const cases = [_]struct { value: u64, want: []const u8 }{
        // `:162` — 0, the one value whose payload is zero.
        .{ .value = 0, .want = &[_]u8{0x00} },
        // `:163` — the largest value one byte holds.
        .{ .value = 127, .want = &[_]u8{0x7f} },
        // `:164` — the first value that needs a second byte.
        .{ .value = 128, .want = &[_]u8{ 0x80, 0x01 } },
        // `:165` — the largest value two bytes hold.
        .{ .value = 16383, .want = &[_]u8{ 0xff, 0x7f } },
        // Width three. 127 and 128 are the pair either side of the boundary the
        // briefing names, and they are the pair where the two encodings of the
        // same value disagree about length.
        .{ .value = 129, .want = &[_]u8{ 0x81, 0x01 } },
        .{ .value = 16384, .want = &[_]u8{ 0x80, 0x80, 0x01 } },
        .{ .value = 2097151, .want = &[_]u8{ 0xff, 0xff, 0x7f } },
        // Widths four through eight, the largest value each holds.
        .{ .value = 268435455, .want = &[_]u8{ 0xff, 0xff, 0xff, 0x7f } },
        .{ .value = 34359738367, .want = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x7f } },
        .{ .value = 4398046511103, .want = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f } },
        .{ .value = 562949953421311, .want = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f } },
        .{ .value = 72057594037927935, .want = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f } },
        // Width nine ends at `i64::MAX`; width ten starts one above it. This is
        // the type boundary, and it is where an implementation that packs the
        // ninth byte loses the sign.
        .{ .value = 9223372036854775807, .want = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f } },
        .{ .value = 9223372036854775808, .want = &@as([9]u8, @splat(0x80)) ++ [_]u8{0x01} },
        // `:166-169` — `u64::MAX`, ten bytes, of which the tenth carries one bit.
        .{ .value = std.math.maxInt(u64), .want = &@as([9]u8, @splat(0xff)) ++ [_]u8{0x01} },
    };
    for (cases) |c| {
        var buf: [max_unsigned_size]u8 = undefined;
        const n = writeUnsigned(&buf, c.value);
        if (n != c.want.len or !std.mem.eql(u8, buf[0..n], c.want)) {
            return reportEncodingMismatch("unsigned", c.value, buf[0..n], c.want, 0);
        }
        // The size function and the encoder are the same function twice; if they
        // ever drift, the buffer above is already the wrong length.
        if (unsignedSize(c.value) != n) return error.CaseMismatch;
        const back = try readUnsigned(c.want);
        if (back.value != c.value or back.len != c.want.len) {
            return reportEncodingMismatch("unsigned decode", c.value, &[_]u8{}, c.want, 0);
        }
        // The bytes read as the value and nothing more: a cursor that follows
        // this one starts where the encoding stopped, not one byte later.
        var followed_buf: [max_unsigned_size + 2]u8 = undefined;
        @memcpy(followed_buf[0..c.want.len], c.want);
        followed_buf[c.want.len] = 0xa5;
        followed_buf[c.want.len + 1] = 0x5a;
        const followed = try readUnsigned(&followed_buf);
        if (followed.len != c.want.len) {
            return reportEncodingMismatch("unsigned length", c.value, &[_]u8{}, c.want, 0);
        }
    }
}

/// Read `prefix` out of a buffer that also holds two bytes the encoding does not
/// own, so the bytes a cursor leaves behind are the bytes that were there. The
/// value is not checked: this exists to show where the read stopped.
fn readUnsignedOrFail(prefix: []const u8) !struct { value: u64, len: usize } {
    var buf: [max_unsigned_size + 2]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = 0xa5;
    buf[prefix.len + 1] = 0x5a;
    return readUnsigned(&buf);
}

test "every signed width round trips at its own boundary, with the bytes" {
    const cases = [_]struct { value: i64, want: []const u8 }{
        // `:275` — 0.
        .{ .value = 0, .want = &[_]u8{0x00} },
        // `:276` — `-1` is one byte, and the whole of the negative half of the
        // one-byte range is the `0x40` row below.
        .{ .value = -1, .want = &[_]u8{0x7f} },
        // `:277` — the largest value one byte holds, and the value whose
        // unsigned encoding is a byte shorter than this one.
        .{ .value = 63, .want = &[_]u8{0x3f} },
        // `:278` — `-64`, the smallest negative value one byte holds.
        .{ .value = -64, .want = &[_]u8{0x40} },
        // The two values either side of `-64`, which is where the encoding stops
        // being one byte. `-65` is the first row upstream's overlong test is
        // built on (`:253`), so the short form of that value is pinned here.
        .{ .value = -65, .want = &[_]u8{ 0xbf, 0x7f } },
        .{ .value = 64, .want = &[_]u8{ 0xc0, 0x00 } },
        // `:279` — 128, which unsigned is one byte longer than this.
        .{ .value = 128, .want = &[_]u8{ 0x80, 0x01 } },
        // `-127`, the short form of upstream's three-byte overlong vector
        // (`:258`), and `-128`, one below it.
        .{ .value = -127, .want = &[_]u8{ 0x81, 0x7f } },
        .{ .value = -128, .want = &[_]u8{ 0x80, 0x7f } },
        // `:280-281` — the two ends of the two-byte range.
        .{ .value = 8191, .want = &[_]u8{ 0xff, 0x3f } },
        .{ .value = -8192, .want = &[_]u8{ 0x80, 0x40 } },
        // Width three, both signs, and the payload of the `counter` column of
        // `counter_value_is_ok.automerge`.
        .{ .value = 8192, .want = &[_]u8{ 0x80, 0xc0, 0x00 } },
        .{ .value = -8193, .want = &[_]u8{ 0xff, 0xbf, 0x7f } },
        .{ .value = 2000, .want = &[_]u8{ 0xd0, 0x0f } },
        .{ .value = -1000, .want = &[_]u8{ 0x98, 0x78 } },
        // Widths four through nine: the largest positive value each holds, and
        // the largest negative value each holds. `i64::MAX` is the end of width
        // nine and `i64::MIN` the end of width ten.
        .{ .value = 1048575, .want = &[_]u8{ 0xff, 0xff, 0x3f } },
        .{ .value = -1048576, .want = &[_]u8{ 0x80, 0x80, 0x40 } },
        .{ .value = 134217727, .want = &[_]u8{ 0xff, 0xff, 0xff, 0x3f } },
        .{ .value = -134217728, .want = &[_]u8{ 0x80, 0x80, 0x80, 0x40 } },
        .{ .value = std.math.maxInt(i64), .want = &@as([9]u8, @splat(0xff)) ++ [_]u8{0x00} },
        .{ .value = std.math.minInt(i64), .want = &@as([9]u8, @splat(0x80)) ++ [_]u8{0x7f} },
    };
    for (cases) |c| {
        var buf: [max_signed_size]u8 = undefined;
        const n = writeSigned(&buf, c.value);
        if (n != c.want.len or !std.mem.eql(u8, buf[0..n], c.want)) {
            return reportEncodingMismatch("signed", c.value, buf[0..n], c.want, 0);
        }
        if (signedSize(c.value) != n) return error.CaseMismatch;
        const back = try readSigned(c.want);
        if (back.value != c.value or back.len != c.want.len) {
            return reportEncodingMismatch("signed decode", c.value, &[_]u8{}, c.want, 0);
        }
        var followed_buf: [max_signed_size + 2]u8 = undefined;
        @memcpy(followed_buf[0..c.want.len], c.want);
        followed_buf[c.want.len] = 0xa5;
        followed_buf[c.want.len + 1] = 0x5a;
        const followed = try readSigned(&followed_buf);
        if (followed.len != c.want.len) {
            return reportEncodingMismatch("signed length", c.value, &[_]u8{}, c.want, 0);
        }
    }
}

// The one place the two encodings of the same number are not the same length,
// and the reason is arithmetic rather than a choice: a positive value of `b`
// bits needs `ceil(b / 7)` bytes unsigned and `ceil((b + 1) / 7)` signed, so
// the two disagree exactly when `b` is a multiple of seven. The columnar format
// stores some counters unsigned and some signed, and a length that came out one
// byte short shifts every byte after it.
test "the two encodings disagree about length exactly at multiples of seven bits" {
    const disagreeing = [_]struct { value: u64 }{
        .{ .value = 127 }, // 7 bits
        .{ .value = 16383 }, // 14
        .{ .value = 2097151 }, // 21
        .{ .value = 268435455 }, // 28
        .{ .value = 34359738367 }, // 35
        .{ .value = 4398046511103 }, // 42
        .{ .value = 562949953421311 }, // 49
        .{ .value = 72057594037927935 }, // 56
        .{ .value = 9223372036854775807 }, // 63
    };
    for (disagreeing) |c| {
        if (unsignedSize(c.value) + 1 != signedSize(c.value)) {
            std.debug.print("unsigned {d} is {d} bytes and signed {d}\n", .{
                c.value, unsignedSize(c.value), signedSize(c.value),
            });
            return error.CaseMismatch;
        }
    }
    // The values between them are the same length both ways, because neither
    // `ceil(b / 7)` nor `ceil((b + 1) / 7)` crosses a boundary: 63 is six bits,
    // 8191 is thirteen and 1048575 is twenty, and 128 is eight so it still
    // fits in a second unsigned byte and a second signed one.
    for ([_]u64{ 0, 1, 62, 63, 128, 8191, 1048575, 134217727 }) |v| {
        if (unsignedSize(v) != signedSize(v)) {
            std.debug.print("unsigned {d} is {d} bytes and signed {d}\n", .{
                v, unsignedSize(v), signedSize(v),
            });
            return error.CaseMismatch;
        }
    }
    // And the type boundary is where a signed encoding stops agreeing with the
    // unsigned one about the sign rather than about the length: `u64::MAX` and
    // `i64::MIN` are both ten bytes, and their tenth bytes differ in every bit.
    if (unsignedSize(std.math.maxInt(u64)) != 10) return error.CaseMismatch;
    if (signedSize(std.math.minInt(i64)) != 10) return error.CaseMismatch;
    if (signedSize(std.math.maxInt(i64)) != 10) return error.CaseMismatch;
    var u: [max_unsigned_size]u8 = undefined;
    var s: [max_signed_size]u8 = undefined;
    const un = writeUnsigned(&u, std.math.maxInt(u64));
    const sn = writeSigned(&s, std.math.minInt(i64));
    // `u64::MAX` ends in `0x01`, `i64::MIN` in `0x7f`: one bit versus a whole
    // byte of sign extension in the same position.
    if (u[un - 1] != 0x01 or s[sn - 1] != 0x7f) return error.CaseMismatch;
}

// ── the canonical form, at every width ──────────────────────────────────────
//
// The question is whether the reference refuses a non-minimal encoding at every
// width or only at the widths its own test table happens to name. It does not
// name most of them: `storage/parse/leb128.rs:132-149` and `:235-262` carry two
// unsigned and three signed error rows between them, all of them two or three
// bytes wide. The rules at `:29-38` and `:57-74` have no width test in them at
// all, so what they do at widths four through ten is a property of the rule and
// has to be established rather than assumed. These two tests establish it.
test "a non-minimal unsigned encoding is refused at every width from one to ten" {
    var value: u64 = 1;
    var width: usize = 1;
    while (width <= max_unsigned_size) : (width += 1) {
        var base: [max_unsigned_size]u8 = undefined;
        const n = writeUnsigned(&base, value);
        if (n != width) {
            std.debug.print("width {d}: {d} encoded in {d} bytes\n", .{ width, value, n });
            return error.CaseMismatch;
        }
        // A longer encoding of the same value: every canonical byte takes a
        // continuation bit and `extra` zero groups go on top. That is the only
        // shape there is — LEB128 groups are positional, so a longer encoding
        // of one value differs from the canonical one only by those zero
        // groups — and upstream refuses it at `:32-33`, which reads the
        // terminator's payload and so does not care how many bytes precede it.
        for (1..(max_unsigned_size - width) + 1) |extra| {
            var padded: [2 * max_unsigned_size]u8 = undefined;
            for (0..n) |i| padded[i] = base[i] | 0x80;
            @memset(padded[n .. n + extra], 0x00);
            const got = readUnsigned(padded[0 .. n + extra]);
            if (got) |ok| {
                std.debug.print("width {d}: {d} accepted in {d} bytes as {d}\n", .{
                    width + extra, value, n + extra, ok.value,
                });
                return error.CaseMismatch;
            } else |e| {
                if (e != error.InvalidLeb128) return e;
            }
        }
        // The next width's smallest value, which is this one's successor.
        if (width < max_unsigned_size) value <<= 7;
    }
}

// The signed rules are not the unsigned rule with a sign attached, and the
// difference is worth spelling out because the answer to "at which widths does
// the reference refuse a non-minimal encoding?" is not the same for the two.
//
// The unsigned rule (`:32-33`) looks only at the terminator's payload: a
// non-minimal unsigned encoding always ends in a `0x00` after at least one
// byte, so one condition catches every width and there is nothing else to see.
//
// The signed rule (`:61-65`) reads the **penultimate** byte as well, because a
// `0x00` and a `0x7f` are both legitimate terminators and only the byte before
// tells them apart. That extra term does not leave a gap, and the reason is
// arithmetic rather than luck. LEB128 groups are positional, so a longer
// encoding of the same value can only be built by appending, and the appended
// groups carry no information: a non-negative value is extended with `0x00` and
// a negative one with `0x7f`, because `2^(7m) - X` has every bit set from the
// top down to where `X` stops. The byte in front of the terminator is
// therefore always a canonical group — `0x40` set for a negative value, clear
// for a non-negative one — and it is the arm of the rule that refuses it.
//
// The helper below builds exactly that construction for every width, both
// signs and every extension length that fits, so "at every width" is a claim
// the suite makes rather than one this comment makes.
test "a non-minimal signed encoding is refused at every width, on both signs" {
    // `i64::MAX` is nine bytes wide and `i64::MIN` is ten, so the two walks
    // stop at different places.
    var positive: i64 = 1;
    var width: usize = 1;
    while (true) {
        try expectOverlongRefused(positive, width, false);
        if (width == 9) break;
        positive *= 128;
        width += 1;
    }
    var negative: i64 = -1;
    width = 1;
    while (true) {
        try expectOverlongRefused(negative, width, true);
        if (width == max_signed_size) break;
        negative *= 128;
        width += 1;
    }
}

/// Every non-minimal encoding of `value`, whose canonical form is `width`
/// bytes wide, at every length from `width + 1` to ten.
///
/// `1 << (7 * (width - 1))` has the narrowest span its width allows, so each
/// width is walked at the value that is hardest to extend and not only at its
/// smallest. Anything larger in the same width needs at least as many bytes to
/// reach its own top group, so the same construction refuses it too.
fn expectOverlongRefused(value: i64, width: usize, negative: bool) !void {
    var base: [max_signed_size]u8 = undefined;
    const n = writeSigned(&base, value);
    if (n != width) {
        std.debug.print("{d} is {d} bytes wide, not {d}\n", .{ value, n, width });
        return error.CaseMismatch;
    }
    const filler: u8 = if (negative) 0x7f else 0x00;
    var extra: usize = 1;
    while (extra <= max_signed_size - width) : (extra += 1) {
        // Every canonical byte takes a continuation bit and `extra` filler
        // groups go on top. Those groups have to be zero for a non-negative
        // value and `0x7f` for a negative one, because the sum has to come back
        // to the same number: `2^(7m) - X` is all ones above where `X` stops.
        // Any other filler changes the value, and a changed value is not a
        // non-minimal encoding of anything.
        var padded: [max_signed_size]u8 = undefined;
        for (0..n) |i| padded[i] = base[i] | 0x80;
        @memset(padded[n .. n + extra], filler);
        if (readSigned(padded[0 .. n + extra])) |ok| {
            std.debug.print(
                "{d} accepted in {d} bytes as {d}, which re-encodes in {d}\n",
                .{ value, n + extra, ok.value, signedSize(ok.value) },
            );
            return error.CaseMismatch;
        } else |e| {
            if (e != error.InvalidLeb128) return e;
        }
    }
}

// A truncated encoding is an error, not a short read. Every canonical encoding
// of two bytes or more has its continuation bit set on every byte but the last,
// so every strict prefix of one runs off the end of the input. Reading the
// first byte of a three-byte encoding must not hand back that byte's payload —
// that is a value the document never wrote, and a parser that returned it would
// read every remaining byte as the next field.
test "every strict prefix of a canonical encoding is an error, never a short read" {
    const unsigned = [_][]const u8{
        &[_]u8{ 0x80, 0x01 },
        &[_]u8{ 0xff, 0x7f },
        &[_]u8{ 0x80, 0x80, 0x01 },
        &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f },
        &(@as([9]u8, @splat(0xff)) ++ [_]u8{0x01}),
    };
    for (unsigned) |full| {
        var buf: [2 * max_unsigned_size]u8 = undefined;
        var cut: usize = 1;
        while (cut < full.len) : (cut += 1) {
            if (readUnsigned(full[0..cut])) |ok| {
                std.debug.print("unsigned: {d} of {d} bytes read as {d}\n", .{ cut, full.len, ok.value });
                return error.CaseMismatch;
            } else |e| {
                if (e != error.UnexpectedEnd) return e;
            }
        }
        // One byte more than it needs is not a short read either: the decoder
        // stops where the encoding stops and leaves the rest for the next
        // reader, which is the property every field after a length depends on.
        var longer: [max_unsigned_size + 2]u8 = undefined;
        @memcpy(longer[0..full.len], full);
        longer[full.len] = 0xa5;
        longer[full.len + 1] = 0x5a;
        const stopped = try readUnsigned(&longer);
        if (stopped.len != full.len) {
            std.debug.print("unsigned: {s} consumed {d} of {d} bytes\n", .{
                hexOf(full, &buf), stopped.len, full.len + 2,
            });
            return error.CaseMismatch;
        }
    }
    const signed = [_][]const u8{
        &[_]u8{ 0x98, 0x78 },
        &[_]u8{ 0xd0, 0x0f },
        &[_]u8{ 0x80, 0x80, 0x40 },
        &(@as([9]u8, @splat(0xff)) ++ [_]u8{0x00}),
        &(@as([9]u8, @splat(0x80)) ++ [_]u8{0x7f}),
    };
    for (signed) |full| {
        var buf: [2 * max_signed_size]u8 = undefined;
        var cut: usize = 1;
        while (cut < full.len) : (cut += 1) {
            if (readSigned(full[0..cut])) |ok| {
                std.debug.print("signed: {d} of {d} bytes read as {d}\n", .{ cut, full.len, ok.value });
                return error.CaseMismatch;
            } else |e| {
                if (e != error.UnexpectedEnd) return e;
            }
        }
        var longer: [max_signed_size + 2]u8 = undefined;
        @memcpy(longer[0..full.len], full);
        longer[full.len] = 0xa5;
        longer[full.len + 1] = 0x5a;
        const stopped = try readSigned(&longer);
        if (stopped.len != full.len) {
            std.debug.print("signed: {s} consumed {d} of {d} bytes\n", .{
                hexOf(full, &buf), stopped.len, full.len + 2,
            });
            return error.CaseMismatch;
        }
    }
}

// ── the bulk ────────────────────────────────────────────────────────────────
//
// The seed is fixed and printed in every failure message together with the
// input, because a random test whose failure cannot be re-run is a test whose
// failure cannot be fixed. Both sweeps below read the same seed, so the inputs
// that reach a tenth byte, that are nothing but continuation bytes, and that
// stop on exactly the right one are all the ones the generator walks into.
const random_seed: u64 = 0x5EED_1EB1_28;

test "random values round trip at every width, and the size functions agree" {
    var prng: std.Random.DefaultPrng = .init(random_seed);
    const rand = prng.random();

    var round: usize = 0;
    while (round < 20000) : (round += 1) {
        // A mixture of the widths the boundary tables pin and the widths only
        // the bulk reaches: a full word, a shifted one, and something small.
        const shift: u6 = rand.intRangeAtMost(u6, 0, 63);
        const u: u64 = switch (round % 4) {
            0 => rand.int(u64),
            1 => rand.int(u64) >> shift,
            2 => rand.intRangeAtMost(u64, 0, 16383),
            else => rand.int(u64),
        };
        const s: i64 = switch (round % 4) {
            0 => rand.int(i64),
            1 => rand.int(i64) >> shift,
            2 => rand.intRangeAtMost(i64, -8192, 8191),
            else => rand.int(i64),
        };

        var ubuf: [max_unsigned_size]u8 = undefined;
        const un = writeUnsigned(&ubuf, u);
        if (unsignedSize(u) != un or un > max_unsigned_size) {
            std.debug.print("seed 0x{x:0>16}: unsigned {d} claimed {d} bytes and wrote {d}\n", .{
                random_seed, u, unsignedSize(u), un,
            });
            return error.CaseMismatch;
        }
        const uback = readUnsigned(ubuf[0..un]) catch |e| {
            std.debug.print("seed 0x{x:0>16}: the encoder wrote bytes the decoder refuses ({s}) for {d}\n", .{
                random_seed, @errorName(e), u,
            });
            return e;
        };
        if (uback.value != u or uback.len != un) {
            std.debug.print("seed 0x{x:0>16}: unsigned {d} read back as {d} in {d} of {d} bytes\n", .{
                random_seed, u, uback.value, uback.len, un,
            });
            return error.CaseMismatch;
        }

        var sbuf: [max_signed_size]u8 = undefined;
        const sn = writeSigned(&sbuf, s);
        if (signedSize(s) != sn or sn > max_signed_size) {
            std.debug.print("seed 0x{x:0>16}: signed {d} claimed {d} bytes and wrote {d}\n", .{
                random_seed, s, signedSize(s), sn,
            });
            return error.CaseMismatch;
        }
        const sback = readSigned(sbuf[0..sn]) catch |e| {
            std.debug.print("seed 0x{x:0>16}: the encoder wrote bytes the decoder refuses ({s}) for {d}\n", .{
                random_seed, @errorName(e), s,
            });
            return e;
        };
        if (sback.value != s or sback.len != sn) {
            std.debug.print("seed 0x{x:0>16}: signed {d} read back as {d} in {d} of {d} bytes\n", .{
                random_seed, s, sback.value, sback.len, sn,
            });
            return error.CaseMismatch;
        }
    }
}

// Random bytes are the half a value sweep cannot reach. Almost every buffer is
// refused; the ones that are not must be encodings the encoder would have
// produced, byte for byte. That is the whole of the canonical-form contract in
// one assertion, and it is the assertion a hand-written list of overlong cases
// cannot make, because the list has to be right about which encodings *are*
// overlong and this one does not care: anything the decoder lets through has to
// re-encode to itself.
test "whatever the decoder accepts re-encodes to itself, on both signs" {
    var prng: std.Random.DefaultPrng = .init(random_seed ^ 0x1234_5678);
    const rand = prng.random();

    var accepted: usize = 0;
    var round: usize = 0;
    while (round < 20000) : (round += 1) {
        var bytes: [max_signed_size + 4]u8 = undefined;
        const len = 1 + rand.intRangeAtMost(usize, 0, bytes.len - 1);
        rand.bytes(bytes[0..len]);

        if (readUnsigned(bytes[0..len])) |ok| {
            var re: [max_unsigned_size]u8 = undefined;
            const rn = writeUnsigned(&re, ok.value);
            if (rn != ok.len or !std.mem.eql(u8, re[0..rn], bytes[0..ok.len])) {
                reportNonCanonical(random_seed, false, bytes[0..len], re[0..rn], ok.value);
                return error.CaseMismatch;
            }
            accepted += 1;
        } else |_| {}

        if (readSigned(bytes[0..len])) |ok| {
            var re: [max_signed_size]u8 = undefined;
            const rn = writeSigned(&re, ok.value);
            if (rn != ok.len or !std.mem.eql(u8, re[0..rn], bytes[0..ok.len])) {
                reportNonCanonical(random_seed, true, bytes[0..len], re[0..rn], ok.value);
                return error.CaseMismatch;
            }
            accepted += 1;
        } else |_| {}
    }
    // A sweep that accepted almost nothing would pass every check above and
    // prove none of them, so the count is asserted as well.
    if (accepted < 1000) {
        std.debug.print("seed 0x{x:0>16}: only {d} of 40000 random buffers were read at all\n", .{
            random_seed, accepted,
        });
        return error.CaseMismatch;
    }
}

/// Report an encoding the decoder accepted that this port's encoder would not
/// have produced. The seed, the input bytes and the value are all here, because
/// the seed alone only gets a reader to the start of the search.
fn reportNonCanonical(
    seed: u64,
    signed: bool,
    input: []const u8,
    canonical: []const u8,
    value: anytype,
) void {
    var inbuf: [2 * (max_signed_size + 4)]u8 = undefined;
    var outbuf: [2 * max_signed_size]u8 = undefined;
    std.debug.print(
        \\
        \\--- non-canonical leb128 accepted ----------------------------------------
        \\  seed     0x{x:0>16}
        \\  sign     {s}
        \\  input    {s}
        \\  value    {d}
        \\  encodes  {s}
        \\
        \\The decoder accepted bytes the encoder did not write. Either the decoder
        \\is reading more than the encoding says, or the encoder is not producing the
        \\canonical form; both change what the reference reads.
        \\
    , .{ seed, if (signed) "signed" else "unsigned", hexOf(input, &inbuf), value, hexOf(canonical, &outbuf) });
}

// ── Composition: many values, one cursor ────────────────────────────────────
//
// Every hot decode path reads varints out of one buffer with a cursor and
// advances by the `len` this module returns: `columnar/encoding.zig:273-276`
// and `:558`, `hexane/rle.zig`'s run headers, `hexane/slab.zig:1794-1826`,
// `storage/chunk.zig`'s chunk walk, `cursor.zig:563-568`, and the prefix fold
// in `opset/columns.zig`. **The width tables above pin that ONE value decodes
// to itself; they say nothing about a SEQUENCE of reads**, and what such a
// loop needs is the composition of the two:
//
// * the cursor lands on the byte after the value it just read, so nothing is
//   skipped and nothing is read twice, and
// * no read consumes nothing, so a loop that trusts a count terminates.
//   `opset/columns.zig:264-268` leans on the second by name.
//
// This is also the cheapest witness there is for the per-varint cost being
// constant: the loop below runs 1500 reads over one buffer, and the only thing
// that makes its total work a function of `count` rather than of
// `count * written` is that every read consumes the bytes it was owed.

test "a stream of varints decodes value by value and lands exactly on its end" {
    var prng: std.Random.DefaultPrng = .init(random_seed ^ 0x5738_1E55);
    const rand = prng.random();

    // 1500 values, half unsigned and half signed, **alternating**, so that a
    // cursor which lost track of which sign the next value had would read a
    // u64's bytes as an i64 and be wrong rather than coincidentally right.
    const count = 1500;
    var stream: [count * max_signed_size]u8 = undefined;
    var want_unsigned: [count]u64 = undefined;
    var want_signed: [count]i64 = undefined;
    var written: usize = 0;

    for (0..count) |i| {
        const shift: u6 = rand.intRangeAtMost(u6, 0, 63);
        if (i % 2 == 0) {
            // The same four shapes the value sweep draws (`random values round
            // trip at every width`, :863), so the widths in this stream are
            // the widths that sweep already reaches.
            const u: u64 = switch (i % 4) {
                0 => rand.int(u64),
                1 => rand.int(u64) >> shift,
                2 => rand.intRangeAtMost(u64, 0, 16383),
                else => rand.int(u64),
            };
            want_unsigned[i] = u;
            written += writeUnsigned(stream[written..], u);
        } else {
            const s: i64 = switch (i % 4) {
                0 => rand.int(i64),
                1 => rand.int(i64) >> shift,
                2 => rand.intRangeAtMost(i64, -8192, 8191),
                else => rand.int(i64),
            };
            want_signed[i] = s;
            written += writeSigned(stream[written..], s);
        }
    }

    // **The stream is a mixture, or the assertions below prove nothing.** A
    // buffer of one-byte values would let a reader that consumed the wrong
    // count still land on the end; a buffer of ten-byte values would let a
    // reader that consumed a fixed ten still land on it. Both bounds say the
    // widths actually vary, and one of them is the width the wire mostly
    // carries.
    try std.testing.expect(written > count);
    try std.testing.expect(written < count * max_signed_size);

    var pos: usize = 0;
    var reads: usize = 0;
    while (pos < written) {
        if (reads % 2 == 0) {
            const got = try readUnsigned(stream[pos..]);
            // **The no-zero-length rule, at every position in the stream and
            // not only on a fresh buffer.** A `len` of zero would leave the
            // cursor where it was and this loop would never end.
            try std.testing.expect(got.len >= 1);
            try std.testing.expectEqual(want_unsigned[reads], got.value);
            pos += got.len;
        } else {
            const got = try readSigned(stream[pos..]);
            try std.testing.expect(got.len >= 1);
            try std.testing.expectEqual(want_signed[reads], got.value);
            pos += got.len;
        }
        reads += 1;
    }

    // **The composition, as an equation:** what the encoder spent and what the
    // decoder walked are the same bytes, and the number of reads is the number
    // of values — so no value was read twice and none was skipped. A read that
    // returned the right value with the wrong `len` fails one of the two.
    try std.testing.expectEqual(written, pos);
    try std.testing.expectEqual(count, reads);
}

test "checked readers preserve scalar errors and consumption on arbitrary bytes" {
    // Compare errors as well as values: ten continuations at EOF differ from
    // eleven, and an overflowing tenth payload wins over a missing terminator.
    var prng: std.Random.DefaultPrng = .init(random_seed ^ 0x6c65_6231_3238);
    const random = prng.random();
    var bytes: [40]u8 = undefined;
    for (0..6000) |sample| {
        random.bytes(&bytes);
        const len = sample % (bytes.len + 1);
        try expectScalarReaders(bytes[0..len]);
        for (0..@min(len, 11)) |terminator| {
            for (bytes[0..terminator]) |*byte| byte.* |= 0x80;
            bytes[terminator] &= 0x7f;
            try expectScalarReaders(bytes[0..len]);
            bytes[terminator] |= 0x80;
        }
    }
    for (0..256) |payload| {
        @memset(&bytes, 0x80);
        bytes[9] = @intCast(payload);
        for (0..12) |len| try expectScalarReaders(bytes[0..len]);
        bytes[8] = 0xff;
        for (0..12) |len| try expectScalarReaders(bytes[0..len]);
    }
}

fn expectScalarReaders(bytes: []const u8) !void {
    if (scalarReaderOracle(false, bytes)) |expected| {
        const actual = try readUnsigned(bytes);
        try std.testing.expectEqual(expected.value, actual.value);
        try std.testing.expectEqual(expected.len, actual.len);
    } else |expected| {
        try std.testing.expectError(expected, readUnsigned(bytes));
    }
    if (scalarReaderOracle(true, bytes)) |expected| {
        const actual = try readSigned(bytes);
        try std.testing.expectEqual(@as(i64, @bitCast(expected.value)), actual.value);
        try std.testing.expectEqual(expected.len, actual.len);
    } else |expected| {
        try std.testing.expectError(expected, readSigned(bytes));
    }
}

fn scalarReaderOracle(
    comptime signed: bool,
    bytes: []const u8,
) ParseError!struct { value: u64, len: usize } {
    // Independent variable-shift model of the original readers, test-only.
    var result: u64 = 0;
    var shift: usize = 0;
    var index: usize = 0;
    var previous: u8 = 0;
    while (true) {
        if (index >= bytes.len) return error.UnexpectedEnd;
        if (index >= 10) return error.InvalidLeb128;
        const byte = bytes[index];
        const payload: u64 = byte & 0x7f;
        if (index == 9) {
            if (signed) {
                if (payload == 0x7f) {
                    result |= @as(u64, 1) << 63;
                } else if (payload != 0) return error.Overflow;
            } else {
                if (payload > 1) return error.Overflow;
                result |= payload << 63;
            }
        } else {
            result |= payload << @intCast(shift);
        }
        index += 1;
        if (byte & 0x80 == 0) {
            if (signed) {
                if (shift >= 7 and ((payload == 0 and previous & 0x40 == 0) or
                    (payload == 0x7f and previous & 0x40 != 0))) return error.InvalidLeb128;
                if (shift + 7 < 64 and byte & 0x40 != 0) {
                    result |= ~@as(u64, 0) << @intCast(shift + 7);
                }
            } else if (shift > 0 and payload == 0) return error.InvalidLeb128;
            return .{ .value = result, .len = index };
        }
        previous = byte;
        shift += 7;
    }
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`Leb128TooLarge` is reported as `InvalidLeb128`, and that is a port
//   decision rather than a transcription.** Upstream's readers distinguish
//   three failures: `Leb128TooLarge` (`:30-31`, `:37`, `:58-60`, `:71-72`),
//   `Leb128Overlong` (`:32-33`, `:63-65`) and `UnexpectedZero` (`:94`). The
//   tenth byte carrying more than the one bit left is a *payload* question and
//   is reported here as `error.Overflow`, which matches `Leb128TooLarge`; the
//   eleventh byte is a *length* question, and it is reported as
//   `error.InvalidLeb128`, which `error.zig:103-104` documents as "truncated,
//   overlong, or otherwise malformed". Both are `ParseError`, both refuse the
//   document, and both are asserted the same way by the eight call sites that
//   pass `0x80 ** 11` to this decoder (`cursor.zig`, `hexane/bool.zig`,
//   `hexane/rle.zig`, `storage/parse.zig`, `opset/columns.zig`,
//   `storage/totality_test.zig`, `sync/protocol.zig`, `sync/message.zig`).
//   Changing it to `error.Overflow` would be a cross-cutting edit to eight
//   files this slice does not own, for a distinction no compatibility test can
//   observe — the fixture corpus only requires that the load fails. It is left
//   alone deliberately and recorded here so it is not mistaken for an oversight.
//
// * **Both readers perform at most ten guarded byte loads.** The longer path
//   uses fixed shifts through bit 56 and an explicit tenth-byte arm. Each
//   terminator returns a positive consumed length before inspecting later
//   bytes. After ten continuations EOF still precedes the length-limit error,
//   as it did in the original scalar loop. The eight fuzz crashers in
//   `tests/fuzz-crashers/` are the regression suite for totality, and
//   `storage/totality_test.zig` walks them.
//
// * **The random sweeps are the only tests here that can be flaky, and they
//   are not.** `random_seed` is a constant, `std.Random.DefaultPrng` is
//   deterministic for a given Zig version, and the same seed drives both sweeps.
//   Every failure message carries the seed and, for the byte sweep, the input
//   and the value it should have re-encoded to — so a failure names the input
//   rather than only the search that found it. The `accepted` floor is there
//   because a sweep that stopped accepting anything would pass every assertion
//   above it and prove none of them.
