//! The chunk framing layer: all a saved automerge document is made of.
//!
//! A document is a bare concatenation of self-delimiting chunks. There is no
//! table, no index, no footer and no format-version field; compatibility rests
//! entirely on the magic bytes and the chunk-type byte. See the "Chunk header"
//! section of `docs/survey/03-storage-columnar.md`.
//!
//! ```text
//! offset  size  field
//! 0       4     magic, [0x85, 0x6f, 0x4a, 0x83]        storage.rs:26
//! 4       4     checksum, the first four bytes of the change hash
//! 5       1     chunk type: 0 document, 1 change, 2 compressed, 3 bundle
//! 6       n     uleb128 data_len
//! 6+n     m     data, m = data_len
//! ```
//!
//! The change hash is `SHA-256(chunk_type_byte || uleb128(data_len) || data)`
//! (`chunk.rs:300-312`); the header field is its first four bytes
//! (`chunk.rs:180-185`). Nothing else is hashed: not the magic, not the
//! checksum field itself, and not the length beyond its own LEB128 encoding.
//! Because the hash covers the body, a chunk that hashes to its recorded
//! checksum cannot have been altered anywhere inside it.
//!
//! The one exception is `ChunkType.compressed`, whose stored checksum is the
//! checksum of the **inflated** body hashed as a `ChunkType.change`, not of
//! the DEFLATE stream on the wire. Upstream writes the change's own checksum
//! (`change/compressed.rs:21`) and requires it to match the rebuilt inner
//! header (`chunk.rs:118-122`). `parseChunk` therefore cannot verify a
//! compressed chunk from the framing alone, and `decompressChunk` does it
//! instead — so nothing is ever handed to a body parser unverified.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const leb128 = @import("../leb128.zig");
const parse = @import("parse.zig");

const ParseError = err.ParseError;
const ChangeHash = types.ChangeHash;
const hash_size = types.hash_size;
const checksum_size = types.checksum_size;
const Input = parse.Input;

const Sha256 = std.crypto.hash.sha2.Sha256;
const flate = std.compress.flate;

/// The bytes that open every chunk (`storage.rs:26`).
pub const magic: [4]u8 = .{ 0x85, 0x6f, 0x4a, 0x83 };

/// What a chunk's body holds (`chunk.rs:126-131`). The tag is the byte on the
/// wire; anything else is `error.InvalidChunkType` (`chunk.rs:134-146`).
pub const ChunkType = enum(u8) {
    /// A full op-set and change-graph snapshot. The only chunk `save` emits on
    /// its own; a document is a change log written as one snapshot.
    document = 0,
    /// One change, in the columnar change encoding.
    change = 1,
    /// A `change` body wrapped in a raw DEFLATE stream.
    compressed = 2,
    /// A set of changes stored by `hexane`.
    bundle = 3,
};

/// One framed chunk. `data` borrows the input the chunk was parsed from; it is
/// the bytes as stored, so for `ChunkType.compressed` it is still deflated.
///
/// `checksum` is the value read from the header, not one recomputed here. It
/// equals `checksumOf(typ, data)` for every type except `compressed`, whose
/// checksum covers the inflated body.
pub const Chunk = struct {
    typ: ChunkType,
    checksum: [checksum_size]u8,
    data: []const u8,
};

/// The change hash of a chunk body: `SHA-256(typ || uleb128(len) || data)`
/// (`chunk.rs:300-312`). For a `change` chunk this is the change's identity
/// and is what the sync protocol compares.
pub fn changeHashOf(typ: ChunkType, data: []const u8) ChangeHash {
    // Upstream builds this same five-ish byte prefix into a `Vec` and hashes it
    // before the data; a fixed stack buffer is the same two updates without
    // the allocation.
    var prefix: [1 + leb128.max_unsigned_size]u8 = undefined;
    prefix[0] = @intFromEnum(typ);
    const n = leb128.writeUnsigned(prefix[1..], data.len);

    var hasher = Sha256.init(.{});
    hasher.update(prefix[0 .. 1 + n]);
    hasher.update(data);
    var out: [hash_size]u8 = undefined;
    hasher.final(&out);
    return .{ .bytes = out };
}

/// The four header bytes of `changeHashOf`.
pub fn checksumOf(typ: ChunkType, data: []const u8) [checksum_size]u8 {
    return changeHashOf(typ, data).checksum();
}

/// Appends a complete chunk to `out`: magic, checksum, type, uleb128 length,
/// data, in that order (`chunk.rs:232-236`). The header is
/// `4 + 4 + 1 + ulebsize(len)` bytes (`chunk.rs:203-207`).
///
/// The bytes appended are exactly what `parseChunk` accepts back, which is
/// what lets a re-saved document be byte-identical to the original.
///
/// Do not use this for `ChunkType.compressed`. It hashes `data` as it is
/// given, and for a compressed chunk the checksum must cover the *inflated*
/// body, so the result is a chunk no reader accepts. `compressChunk` is the
/// writer for that type.
pub fn writeChunk(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    typ: ChunkType,
    data: []const u8,
) std.mem.Allocator.Error!void {
    try out.appendSlice(gpa, &magic);
    const sum = checksumOf(typ, data);
    try out.appendSlice(gpa, &sum);
    try out.append(gpa, @intFromEnum(typ));
    try leb128.appendUnsigned(out, gpa, data.len);
    try out.appendSlice(gpa, data);
}

/// Appends a `ChunkType.compressed` chunk wrapping the change body `body`
/// (`change/compressed.rs:18-34`).
///
/// The stored checksum is `checksumOf(.change, body)` over the **uncompressed**
/// body, exactly as upstream copies the change's own checksum. Only the data
/// is deflated, and the length written is the deflated length.
pub fn compressChunk(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    body: []const u8,
) std.mem.Allocator.Error!void {
    const deflated = try compressRaw(gpa, body);
    defer gpa.free(deflated);

    try out.appendSlice(gpa, &magic);
    const sum = checksumOf(.change, body);
    try out.appendSlice(gpa, &sum);
    try out.append(gpa, @intFromEnum(ChunkType.compressed));
    try leb128.appendUnsigned(out, gpa, deflated.len);
    try out.appendSlice(gpa, deflated);
}

/// The inverse of `compressChunk`: inflates a compressed chunk's body and
/// checks it against the checksum in the chunk's own header, hashed as a
/// `ChunkType.change` (`chunk.rs:80-100`, `:213-225`).
///
/// Returns a buffer owned by the caller. A chunk of any other type is
/// `error.InvalidChunkType`; a body that inflates to something other than what
/// the header records is `error.InvalidChecksum`. Callers must run a compressed
/// body through this before parsing it, because `parseChunk` cannot check the
/// checksum without inflating.
pub fn decompressChunk(gpa: std.mem.Allocator, chunk: Chunk) ParseError![]u8 {
    if (chunk.typ != .compressed) return error.InvalidChunkType;
    const body = try decompressRaw(gpa, chunk.data);
    errdefer gpa.free(body);
    if (!std.mem.eql(u8, &chunk.checksum, &checksumOf(.change, body))) {
        return error.InvalidChecksum;
    }
    return body;
}

/// Deflates `data` into a raw DEFLATE stream: no zlib or gzip wrapper, which
/// is what a compressed chunk's body is (`change/compressed.rs:23-30`).
///
/// Returns a buffer owned by the caller. The level is zlib's default, the one
/// `flate2::Compression::default()` selects upstream.
pub fn compressRaw(gpa: std.mem.Allocator, data: []const u8) std.mem.Allocator.Error![]u8 {
    // `Compress.init` asserts the scratch window is at least `max_window_len`;
    // take it from `gpa` rather than the stack, because it is 64 KiB.
    const scratch = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(scratch);

    // `Compress` asserts the output buffer is longer than 8 bytes, and this
    // capacity also covers the usual case of a body that actually shrinks.
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, data.len + 64);
    defer aw.deinit();

    var compressor: flate.Compress = undefined;
    // `Compress.init` writes the container header, which is empty for a raw
    // stream, so this only fails if the output writer does.
    compressor = flate.Compress.init(&aw.writer, scratch, .raw, .default) catch
        return error.OutOfMemory;
    compressor.writer.writeAll(data) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Inflates a raw DEFLATE stream. Returns a buffer owned by the caller.
///
/// A stream that ends early, carries an invalid code, or over-runs a match is
/// `error.InvalidDeflate`; upstream maps the same failure to
/// `error::Chunk::Deflate` (`chunk.rs:85-86`).
pub fn decompressRaw(gpa: std.mem.Allocator, data: []const u8) ParseError![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var decoder: flate.Decompress = .init(&in, .raw, &.{});
    // `streamRemaining` reports a clean end of frame as success, so only a
    // genuine failure reaches the catch. `WriteFailed` is the allocating
    // writer's out-of-memory signal, not a defect in the input.
    _ = decoder.reader.streamRemaining(&aw.writer) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        error.ReadFailed => error.InvalidDeflate,
    };
    return aw.toOwnedSlice();
}

/// Parses exactly one chunk that fills the whole of `bytes`.
///
/// Anything left over after the chunk is `error.TrailingBytes`. The checksum
/// is verified before the chunk is returned, as it is for every chunk upstream
/// reads (`load.rs:100-102`, `automerge.rs:907-911`) — except for
/// `ChunkType.compressed`, whose checksum covers the inflated body and is left
/// to `decompressChunk`.
pub fn parseChunk(bytes: []const u8) ParseError!Chunk {
    var in: Input = .init(bytes);
    const chunk = try readChunk(&in);
    if (!in.isEmpty()) return error.TrailingBytes;
    return chunk;
}

/// Parses a stream of chunks, which is what a saved document is: chunk after
/// chunk until the input runs out (`load.rs:75-99`). The returned slice belongs
/// to the caller; the chunks inside it borrow `bytes`.
///
/// An input that stops in the middle of a chunk is an error, not a short
/// result. Every chunk but a `compressed` one is checksum-verified here.
pub fn parseChunks(bytes: []const u8, gpa: std.mem.Allocator) ParseError![]Chunk {
    var out: std.ArrayList(Chunk) = .empty;
    errdefer out.deinit(gpa);
    var in: Input = .init(bytes);
    while (!in.isEmpty()) {
        try out.append(gpa, try readChunk(&in));
    }
    return out.toOwnedSlice(gpa);
}

/// Consumes one chunk from `in`, leaving the cursor on the first byte after
/// it. The body is bounded by the declared length, so a chunk can never read
/// into its successor.
fn readChunk(in: *Input) ParseError!Chunk {
    if (!std.mem.eql(u8, &try in.takeArray(u32), &magic)) return error.InvalidMagic;
    const checksum = try in.takeArray(u32);
    const typ: ChunkType = switch (try in.takeByte()) {
        0 => .document,
        1 => .change,
        2 => .compressed,
        3 => .bundle,
        else => return error.InvalidChunkType,
    };
    // The cast only fails where `usize` is narrower than 64 bits, which is the
    // whole point: a length that cannot be a byte count is not a length.
    const data_len = std.math.cast(usize, try in.takeUleb()) orelse return error.TooLarge;
    // Checked against what is left before any of the body is touched, so a
    // length of 2^40 costs a comparison and not a 2^40-byte read.
    if (data_len > in.remaining()) return error.LengthExceedsInput;
    const data = (try in.sub(data_len)).rest();

    // The compressed case is deferred: its checksum is over the inflated body
    // (`chunk.rs:118-122`), and inflating here would make a framing parse
    // allocate. `decompressChunk` checks it before the body is used.
    if (typ != .compressed and !std.mem.eql(u8, &checksum, &checksumOf(typ, data))) {
        return error.InvalidChecksum;
    }
    return .{ .typ = typ, .checksum = checksum, .data = data };
}

const testing = std.testing;

// `test/fixtures/two_change_chunks.automerge`: two `change` chunks, 57 and 100
// bytes of body. Copied in so the framing is pinned to bytes automerge wrote,
// not to bytes this port wrote.
const two_change_chunks = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x9a, 0xc3, 0xd7, 0x30, 0x01, 0x39, 0x00, 0x10,
    0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00, 0xa5, 0xeb,
    0xe1, 0xac, 0xd9, 0x4d, 0x01, 0x01, 0xc1, 0xbe, 0xc4, 0x83, 0xe1, 0x30,
    0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x31, 0x00, 0x05, 0x15,
    0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x70, 0x02, 0x7f, 0x01, 0x61,
    0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x00, 0x85, 0x6f, 0x4a, 0x83, 0xa7,
    0xe7, 0x27, 0xd5, 0x01, 0x64, 0x01, 0x9a, 0xc3, 0xd7, 0x30, 0xf2, 0x62,
    0xda, 0x35, 0xe7, 0x1d, 0xb5, 0x91, 0xb9, 0xe8, 0x15, 0x0d, 0xe9, 0xb0,
    0x28, 0x26, 0xda, 0xf7, 0x50, 0x06, 0xf2, 0x29, 0x89, 0x16, 0xad, 0xec,
    0x6e, 0x0b, 0x10, 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85,
    0x00, 0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d, 0x02, 0x02, 0xc1, 0xbe, 0xc4,
    0x83, 0xe1, 0x30, 0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x32,
    0x00, 0x08, 0x01, 0x02, 0x02, 0x02, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02,
    0x56, 0x02, 0x57, 0x01, 0x70, 0x02, 0x7f, 0x00, 0x7f, 0x01, 0x7f, 0x01,
    0x61, 0x01, 0x7f, 0x01, 0x7f, 0x16, 0x62, 0x7f, 0x00,
};

// The body of the first chunk of `two_change_chunks`: the 57 bytes after its
// 10-byte header.
const change_body = [_]u8{
    0x00, 0x10, 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00,
    0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d, 0x01, 0x01, 0xc1, 0xbe, 0xc4, 0x83,
    0xe1, 0x30, 0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x31, 0x00,
    0x05, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x70, 0x02, 0x7f,
    0x01, 0x61, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x00,
};

// `test/fixtures/two_change_chunks_compressed.automerge`: the same two changes,
// each wrapped in a raw DEFLATE stream. The checksums are the same two values
// as in the uncompressed file, which is the whole point: the checksum is of the
// change, not of the bytes around it.
const two_change_chunks_compressed = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x9a, 0xc3, 0xd7, 0x30, 0x02, 0x3e, 0x62, 0x10,
    0xb8, 0xc5, 0x15, 0x12, 0xe2, 0xe4, 0xec, 0xd9, 0xd2, 0xca, 0xb0, 0xf4,
    0xf5, 0xc3, 0x35, 0x37, 0x7d, 0x19, 0x19, 0x0f, 0xee, 0x3b, 0xd2, 0xfc,
    0xd0, 0x80, 0x23, 0x39, 0x23, 0x31, 0x2f, 0x3d, 0x55, 0xc1, 0x90, 0x81,
    0x55, 0x94, 0xd9, 0x84, 0xd1, 0x89, 0x29, 0x8c, 0xa9, 0x80, 0xa9, 0x9e,
    0x31, 0x91, 0xb1, 0x9e, 0x01, 0x04, 0x01, 0x01, 0x00, 0x00, 0xff, 0xff,
    0x85, 0x6f, 0x4a, 0x83, 0xa7, 0xe7, 0x27, 0xd5, 0x02, 0x6e, 0x00, 0x64,
    0x00, 0x9b, 0xff, 0x01, 0x9a, 0xc3, 0xd7, 0x30, 0xf2, 0x62, 0xda, 0x35,
    0xe7, 0x1d, 0xb5, 0x91, 0xb9, 0xe8, 0x15, 0x0d, 0xe9, 0xb0, 0x28, 0x26,
    0xda, 0xf7, 0x50, 0x06, 0xf2, 0x29, 0x89, 0x16, 0xad, 0xec, 0x6e, 0x0b,
    0x10, 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00, 0xa5,
    0xeb, 0xe1, 0xac, 0xd9, 0x4d, 0x02, 0x02, 0xc1, 0xbe, 0xc4, 0x83, 0xe1,
    0x30, 0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x32, 0x00, 0x08,
    0x01, 0x02, 0x02, 0x02, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02,
    0x57, 0x01, 0x70, 0x02, 0x7f, 0x00, 0x7f, 0x01, 0x7f, 0x01, 0x61, 0x01,
    0x7f, 0x01, 0x7f, 0x16, 0x62, 0x7f, 0x00, 0x01, 0x00, 0x00, 0xff, 0xff,
};

test "checksum and change hash are SHA-256 over type, length, and data" {
    // Vectors computed with an independent SHA-256, so a hash taken over the
    // wrong concatenation order fails here rather than passing against itself.
    const cases = [_]struct { typ: ChunkType, data: []const u8, cks: [4]u8, hash: []const u8 }{
        .{
            .typ = .document,
            .data = "",
            .cks = .{ 0x96, 0xa2, 0x96, 0xd2 },
            .hash = "96a296d224f285c67bee93c30f8a309157f0daa35dc5b87e410b78630a09cfc7",
        },
        .{
            .typ = .change,
            .data = "abc",
            .cks = .{ 0xa1, 0x8b, 0xb1, 0xcc },
            .hash = "a18bb1cc0780ac9b8a305ebfe12654668d0280f25f39b89e6362e89bf76e3204",
        },
        .{
            .typ = .change,
            .data = "hello automerge",
            .cks = .{ 0x45, 0xe6, 0x71, 0x4c },
            .hash = "45e6714c35f569c160586200b625f690b80905ec5f81384408c84f6219c4c403",
        },
        .{
            .typ = .compressed,
            .data = "abc",
            .cks = .{ 0xee, 0xdc, 0x37, 0xd7 },
            .hash = "eedc37d796ec5a9810ef2687d06009f18ccd58ecccd6980ec3df560545fb9000",
        },
        .{
            .typ = .bundle,
            .data = "abc",
            .cks = .{ 0xd3, 0x78, 0xa1, 0x97 },
            .hash = "d378a1975aca802a90315df55738d2cc41b30f9bce8ed0fbb6c99f17ef251a6c",
        },
    };
    for (cases) |c| {
        try testing.expectEqualSlices(u8, &c.cks, &checksumOf(c.typ, c.data));
        const got = changeHashOf(c.typ, c.data);
        var text: [64]u8 = undefined;
        err.hexInto(&got.bytes, &text);
        try testing.expectEqualStrings(c.hash, &text);
    }
    // The checksum is not simply the first bytes of some other hashing: the
    // type byte is part of the input, so two types over the same body differ.
    try testing.expect(!std.mem.eql(u8, &checksumOf(.document, "abc"), &checksumOf(.change, "abc")));
}

test "a chunk written is a chunk parsed, byte for byte" {
    const gpa = testing.allocator;
    const body = "the quick brown fox";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeChunk(&out, gpa, .change, body);

    // Header is 4 + 4 + 1 + 1 bytes here; the length is a one-byte LEB128.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x85, 0x6f, 0x4a, 0x83 }, out.items[0..4]);
    try testing.expectEqual(@as(u8, 0x01), out.items[8]);
    try testing.expectEqual(@as(u8, body.len), out.items[9]);

    const chunk = try parseChunk(out.items);
    try testing.expectEqual(ChunkType.change, chunk.typ);
    try testing.expectEqualStrings(body, chunk.data);
    try testing.expectEqualSlices(u8, &checksumOf(.change, body), &chunk.checksum);

    // Re-writing the parsed chunk reproduces the input exactly.
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(gpa);
    try writeChunk(&again, gpa, chunk.typ, chunk.data);
    try testing.expectEqualSlices(u8, out.items, again.items);
}

test "a length needing two LEB128 bytes is framed as two" {
    const gpa = testing.allocator;
    const body: [300]u8 = @splat(0x5a);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeChunk(&out, gpa, .document, &body);

    // 300 = 0b100101100, so uleb128 is 0xac 0x02.
    try testing.expectEqualSlices(u8, &[_]u8{ 0xac, 0x02 }, out.items[9..11]);
    try testing.expectEqual(@as(usize, 311), out.items.len);

    const chunk = try parseChunk(out.items);
    try testing.expectEqual(ChunkType.document, chunk.typ);
    try testing.expectEqualSlices(u8, &body, chunk.data);
}

test "a stream of three chunks parses into three chunks" {
    const gpa = testing.allocator;
    const bodies = [_][]const u8{ "", "one", "two change bodies in a row" };
    const kinds = [_]ChunkType{ .document, .change, .bundle };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (bodies, kinds) |body, typ| try writeChunk(&out, gpa, typ, body);

    const chunks = try parseChunks(out.items, gpa);
    defer gpa.free(chunks);
    try testing.expectEqual(@as(usize, 3), chunks.len);
    for (chunks, bodies, kinds) |chunk, body, typ| {
        try testing.expectEqual(typ, chunk.typ);
        try testing.expectEqualStrings(body, chunk.data);
    }

    // Each chunk stops at its own length: the stream is the concatenation, and
    // re-serialising it is a no-op.
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(gpa);
    for (chunks) |chunk| try writeChunk(&again, gpa, chunk.typ, chunk.data);
    try testing.expectEqualSlices(u8, out.items, again.items);
}

test "an empty stream is an empty list" {
    const gpa = testing.allocator;
    const chunks = try parseChunks("", gpa);
    defer gpa.free(chunks);
    try testing.expectEqual(@as(usize, 0), chunks.len);
}

test "malformed chunks are rejected" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeChunk(&out, gpa, .change, "body");

    // Wrong magic.
    var bad_magic = try gpa.dupe(u8, out.items);
    defer gpa.free(bad_magic);
    bad_magic[2] ^= 0xff;
    try testing.expectError(error.InvalidMagic, parseChunk(bad_magic));

    // Wrong checksum: the body was changed, the recorded hash was not.
    var bad_sum = try gpa.dupe(u8, out.items);
    defer gpa.free(bad_sum);
    bad_sum[out.items.len - 1] ^= 0x01;
    try testing.expectError(error.InvalidChecksum, parseChunk(bad_sum));

    // A checksum field that is simply wrong, with an intact body.
    var bad_sum2 = try gpa.dupe(u8, out.items);
    defer gpa.free(bad_sum2);
    bad_sum2[4] ^= 0x01;
    try testing.expectError(error.InvalidChecksum, parseChunk(bad_sum2));

    // An undefined chunk type byte. The type is read before the length, so
    // neither of these reaches the length at all.
    var bad_type = try gpa.dupe(u8, out.items);
    defer gpa.free(bad_type);
    bad_type[8] = 4;
    try testing.expectError(error.InvalidChunkType, parseChunk(bad_type));
    bad_type[8] = 0xff;
    try testing.expectError(error.InvalidChunkType, parseChunk(bad_type));

    // A trailing byte after a complete chunk.
    var trailing: std.ArrayList(u8) = .empty;
    defer trailing.deinit(gpa);
    try trailing.appendSlice(gpa, out.items);
    try trailing.append(gpa, 0x00);
    try testing.expectError(error.TrailingBytes, parseChunk(trailing.items));

    // Every one of these must also stop a stream, not just a single chunk.
    try testing.expectError(error.InvalidMagic, parseChunks(bad_magic, gpa));
    try testing.expectError(error.InvalidChecksum, parseChunks(bad_sum, gpa));
    try testing.expectError(error.InvalidChunkType, parseChunks(bad_type, gpa));

    // A truncated stream: two good chunks and then half a third. The third
    // header is intact and its length runs off the end, so that is the error
    // rather than a short read.
    var two: std.ArrayList(u8) = .empty;
    defer two.deinit(gpa);
    try writeChunk(&two, gpa, .change, "first");
    try writeChunk(&two, gpa, .change, "second");
    try two.appendSlice(gpa, out.items[0 .. out.items.len - 2]);
    try testing.expectError(error.LengthExceedsInput, parseChunks(two.items, gpa));

    // A stream that stops inside a header never reaches a length at all.
    try testing.expectError(error.UnexpectedEnd, parseChunk(out.items[0..7]));
    try testing.expectError(error.UnexpectedEnd, parseChunk(""));
}

test "a length past the end of the input is refused without allocating" {
    const gpa = testing.allocator;
    // Magic, checksum, type 1, then a length of 2^40 with a four-byte body
    // behind it. A parser that trusted the length would try to read, and one
    // that reserved it would try to allocate.
    const bytes = [_]u8{
        0x85, 0x6f, 0x4a, 0x83, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x80, 0x80, 0x80, 0x80, 0x10, 0x62, 0x6f, 0x64, 0x79,
    };
    try testing.expectError(error.LengthExceedsInput, parseChunk(&bytes));

    // The same, through the streaming entry point, with an allocator that
    // fails every allocation: the error must be the length, not out-of-memory.
    var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try testing.expectError(
        error.LengthExceedsInput,
        parseChunks(&bytes, failing.allocator()),
    );
    try testing.expectEqual(@as(usize, 0), failing.allocations);

    // The widest legal LEB128 length: nine whole bytes plus a tenth carrying
    // the last bit, so 2^64 - 1. Well formed, and no buffer can hold it.
    const widest = [_]u8{
        0x85, 0x6f, 0x4a, 0x83, 0x00, 0x00, 0x00, 0x00, 0x01,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x01,
    };
    try testing.expectError(error.LengthExceedsInput, parseChunk(&widest));

    // A tenth byte carrying more than the one bit left is a malformed LEB128,
    // rejected by the length reader before anything is reserved.
    const malformed = [_]u8{
        0x85, 0x6f, 0x4a, 0x83, 0x00, 0x00, 0x00, 0x00, 0x01,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x02,
    };
    try testing.expectError(error.Overflow, parseChunk(&malformed));
}

test "a raw DEFLATE stream round trips, and a truncated one does not" {
    const gpa = testing.allocator;
    const body = "abcabcabcabc" ** 64;
    const deflated = try compressRaw(gpa, body);
    defer gpa.free(deflated);
    try testing.expect(deflated.len < body.len);

    const inflated = try decompressRaw(gpa, deflated);
    defer gpa.free(inflated);
    try testing.expectEqualStrings(body, inflated);

    // A stream that stops mid-block is not a shorter document.
    try testing.expectError(error.InvalidDeflate, decompressRaw(gpa, deflated[0 .. deflated.len - 3]));
    try testing.expectError(error.InvalidDeflate, decompressRaw(gpa, deflated[0 .. deflated.len - 1]));
    // Neither is one that was never a deflate stream.
    try testing.expectError(error.InvalidDeflate, decompressRaw(gpa, "not deflate at all"));
    try testing.expectError(error.InvalidDeflate, decompressRaw(gpa, ""));

    // An empty input deflates to a valid, empty stream.
    const empty = try compressRaw(gpa, "");
    defer gpa.free(empty);
    const back = try decompressRaw(gpa, empty);
    defer gpa.free(back);
    try testing.expectEqual(@as(usize, 0), back.len);
}

test "compressChunk writes what decompressChunk reads back" {
    const gpa = testing.allocator;
    const body = "a change body that compresses well " ** 20;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try compressChunk(&out, gpa, body);

    // A compressed chunk is smaller than the same body stored plainly, and
    // carries the change's checksum, not one over the deflated bytes.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try writeChunk(&plain, gpa, .change, body);
    try testing.expect(out.items.len < plain.items.len);
    try testing.expectEqualSlices(u8, &checksumOf(.change, body), out.items[4..8]);
    try testing.expectEqual(@as(u8, 0x02), out.items[8]);

    const chunk = try parseChunk(out.items);
    try testing.expectEqual(ChunkType.compressed, chunk.typ);
    try testing.expect(!std.mem.eql(u8, &checksumOf(.compressed, chunk.data), &chunk.checksum));

    const back = try decompressChunk(gpa, chunk);
    defer gpa.free(back);
    try testing.expectEqualStrings(body, back);

    // A body that does not match the recorded checksum is refused, and a chunk
    // that is not compressed at all is not silently inflated.
    var tampered = chunk;
    tampered.checksum[0] ^= 0x01;
    try testing.expectError(error.InvalidChecksum, decompressChunk(gpa, tampered));
    try testing.expectError(
        error.InvalidChunkType,
        decompressChunk(gpa, .{ .typ = .change, .checksum = chunk.checksum, .data = chunk.data }),
    );

    // `writeChunk` cannot produce a compressed chunk: it hashes the deflated
    // bytes it is handed, so the reader rejects what it writes. That is why
    // `compressChunk` exists, and why the two are not interchangeable.
    var wrong: std.ArrayList(u8) = .empty;
    defer wrong.deinit(gpa);
    try writeChunk(&wrong, gpa, .compressed, chunk.data);
    const misframed = try parseChunk(wrong.items);
    try testing.expectEqual(ChunkType.compressed, misframed.typ);
    try testing.expectError(error.InvalidChecksum, decompressChunk(gpa, misframed));
}

test "two change chunks written by automerge parse and re-serialise exactly" {
    const gpa = testing.allocator;
    const chunks = try parseChunks(&two_change_chunks, gpa);
    defer gpa.free(chunks);
    try testing.expectEqual(@as(usize, 2), chunks.len);
    try testing.expectEqual(ChunkType.change, chunks[0].typ);
    try testing.expectEqual(ChunkType.change, chunks[1].typ);
    try testing.expectEqual(@as(usize, 57), chunks[0].data.len);
    try testing.expectEqual(@as(usize, 100), chunks[1].data.len);

    // The full change hashes are the ones automerge computed for these changes.
    var text: [64]u8 = undefined;
    err.hexInto(&changeHashOf(.change, chunks[0].data).bytes, &text);
    try testing.expectEqualStrings(
        "9ac3d730f262da35e71db591b9e8150de9b02826daf75006f2298916adec6e0b",
        &text,
    );
    err.hexInto(&changeHashOf(.change, chunks[1].data).bytes, &text);
    try testing.expectEqualStrings(
        "a7e727d50d6fdc1419e018cdce333683f48b609bf30f5b4b3a613ba35d6b1dc9",
        &text,
    );

    // The first chunk is 10 header bytes plus a 57-byte body, so the second
    // header starts at 67: magic there, type 1 at 75, length 100 at 76.
    try testing.expectEqualSlices(u8, &magic, two_change_chunks[67..71]);
    try testing.expectEqual(@as(u8, 0x01), two_change_chunks[75]);
    try testing.expectEqual(@as(u8, 100), two_change_chunks[76]);

    // Each chunk on its own parses with `parseChunk`, and re-serialising both
    // gives back the file byte for byte.
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(gpa);
    for (chunks) |chunk| try writeChunk(&again, gpa, chunk.typ, chunk.data);
    try testing.expectEqualSlices(u8, &two_change_chunks, again.items);

    const first = try parseChunk(two_change_chunks[0..67]);
    try testing.expectEqualSlices(u8, &change_body, first.data);
    const second = try parseChunk(two_change_chunks[67..]);
    try testing.expectEqualSlices(u8, chunks[1].data, second.data);
}

test "a compressed chunk carries the checksum of the change, not of the stream" {
    const gpa = testing.allocator;
    const chunks = try parseChunks(&two_change_chunks_compressed, gpa);
    defer gpa.free(chunks);
    try testing.expectEqual(@as(usize, 2), chunks.len);

    // Same two checksums as the uncompressed file, one byte at a time.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x9a, 0xc3, 0xd7, 0x30 }, &chunks[0].checksum);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xa7, 0xe7, 0x27, 0xd5 }, &chunks[1].checksum);

    // Neither is the checksum of the DEFLATE bytes automerge stored, which is
    // the property that makes the deferred check necessary.
    for (chunks) |chunk| {
        try testing.expectEqual(ChunkType.compressed, chunk.typ);
        try testing.expect(!std.mem.eql(u8, &checksumOf(.compressed, chunk.data), &chunk.checksum));
    }

    // Inflating gives back the change bodies verbatim, and the checksum check
    // is what proves the inflate is right: it is the same verification
    // automerge's own writer performed.
    const plain = try parseChunks(&two_change_chunks, gpa);
    defer gpa.free(plain);
    for (chunks, plain) |chunk, expected| {
        const body = try decompressChunk(gpa, chunk);
        defer gpa.free(body);
        try testing.expectEqualSlices(u8, expected.data, body);
        try testing.expectEqualSlices(u8, &checksumOf(.change, body), &chunk.checksum);
    }
    try testing.expectEqualSlices(u8, &change_body, plain[0].data);

    // The compressed file is longer than the plain one here, because these two
    // changes are too small for deflate to pay for itself. Upstream only tries
    // compression above 256 bytes (`change.rs:17`, `:302-306`); the framing
    // layer makes no such decision and stores what it is given.
    try testing.expect(two_change_chunks_compressed.len > two_change_chunks.len);
}
