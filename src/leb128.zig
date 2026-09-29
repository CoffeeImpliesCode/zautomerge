//! LEB128 encoding, as used by the columnar format and the change encoder.
//!
//! Zig's standard library has no LEB128: the only copy in `std` is an internal
//! one in the DWARF parser. This is the port's own.
//!
//! Two properties matter for compatibility and are enforced by tests:
//!
//! * A value is encoded in at most ten bytes; the tenth byte contributes one
//!   bit. An overlong encoding is a parse error, not a silently accepted
//!   value.
//! * Reading consumes only the bytes the encoding actually needs, so a
//!   decoder can keep reading from the same cursor afterwards.

const std = @import("std");
const err = @import("error.zig");

const ParseError = err.ParseError;

/// The maximum number of bytes a u64 occupies: nine whole bytes plus one
/// bit-carrying byte.
pub const max_unsigned_size = 10;
pub const max_signed_size = 10;

/// The number of bytes `writeUnsigned` will emit for `value`.
pub fn unsignedSize(value: anytype) usize {
    const v: u64 = @intCast(@max(value, 0));
    var n: usize = 1;
    var rest = v >> 7;
    while (rest != 0) : (n += 1) rest >>= 7;
    return n;
}

/// The number of bytes `writeSigned` will emit for `value`. It runs the same
/// loop as the encoder, so the two cannot disagree.
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
/// bytes consumed. Errors on truncation, on an overlong encoding, and on a
/// value that does not fit in `u64`.
pub fn readUnsigned(in: []const u8) ParseError!struct { value: u64, len: usize } {
    var result: u64 = 0;
    var shift: usize = 0;
    var i: usize = 0;
    while (true) {
        if (i >= in.len) return error.UnexpectedEnd;
        if (i >= max_unsigned_size) return error.InvalidLeb128;
        const byte = in[i];
        const payload: u64 = byte & 0x7f;
        if (i == max_unsigned_size - 1) {
            // The tenth byte may only carry the single remaining bit.
            if (payload > 1) return error.Overflow;
        } else if (shift >= 64) {
            return error.Overflow;
        }
        result |= payload << @intCast(shift);
        i += 1;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return .{ .value = result, .len = i };
}

/// Reads a signed LEB128 from `in`, returning the value and bytes consumed.
pub fn readSigned(in: []const u8) ParseError!struct { value: i64, len: usize } {
    var result: u64 = 0;
    var shift: usize = 0;
    var i: usize = 0;
    var byte: u8 = 0;
    while (true) {
        if (i >= in.len) return error.UnexpectedEnd;
        if (i >= max_signed_size) return error.InvalidLeb128;
        byte = in[i];
        i += 1;
        const payload: u64 = byte & 0x7f;
        if (i == max_signed_size) {
            // The tenth byte carries only the sign and its extension: it must
            // be all zeros or all ones, and it sets bit 63.
            if (payload == 0x7f) {
                result |= @as(u64, 1) << 63;
            } else if (payload != 0x00) {
                return error.Overflow;
            }
        } else if (shift < 64) {
            result |= payload << @intCast(shift);
        } else if (payload != 0 and payload != 0x7f) {
            return error.Overflow;
        }
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    // Sign extension, when the sign bit is set and bits remain above it.
    if (shift + 7 < 64 and (byte & 0x40) != 0) {
        result |= ~@as(u64, 0) << @intCast(shift + 7);
    }
    return .{ .value = @bitCast(result), .len = i };
}

/// Appends `value` as unsigned LEB128 to `list`.
pub fn appendUnsigned(list: *std.ArrayList(u8), gpa: std.mem.Allocator, value: anytype) !void {
    var buf: [max_unsigned_size]u8 = undefined;
    const n = writeUnsigned(&buf, value);
    try list.appendSlice(gpa, buf[0..n]);
}

/// Appends `value` as signed LEB128 to `list`.
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
    try std.testing.expectError(error.InvalidLeb128, readUnsigned(&[_]u8{0x80} ** 11));
    // Tenth byte carries more than the one bit left.
    try std.testing.expectError(
        error.Overflow,
        readUnsigned(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 }),
    );
    // Empty input.
    try std.testing.expectError(error.UnexpectedEnd, readUnsigned(&[_]u8{}));
    try std.testing.expectError(error.UnexpectedEnd, readSigned(&[_]u8{}));
}
