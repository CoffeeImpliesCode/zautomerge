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
//! **One hash, kept whole.** `readChunk` takes that SHA-256 once and publishes
//! all thirty-two bytes of it: [`Chunk.checksum`] is the first four and
//! [`Chunk.hash`] is all of it, so the change hash a body parser needs is
//! already in hand instead of a second pass over the same bytes. Upstream
//! keeps the same pair side by side in `Header` (`chunk.rs:187-194`), fills
//! both from one `hash()` call (`chunk.rs:198-201`, `:271`, `:279`), and
//! `Change::hash` reads the header back rather than recomputing
//! (`change.rs:268-270`).
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

/// The bytes that open every chunk (`storage.rs:26`). Read back with
/// [`parseChunk`], which refuses anything else with `error.InvalidMagic`, and
/// written by [`writeChunk`] and [`compressChunk`].
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

/// One framed chunk. `data` and `frame` both borrow the input the chunk was
/// parsed from; `data` is the bytes as stored, so for `ChunkType.compressed`
/// it is still deflated.
///
/// `checksum` is the value read from the header, not one recomputed here. It
/// equals `checksumOf(typ, data)` for every type except `compressed`, whose
/// checksum covers the inflated body.
///
/// **`hash` is the whole of what `checksum` is a prefix of.** The one SHA-256
/// taken to compare those four bytes against the header is kept, not
/// truncated, so the change hash a body parser downstream needs travels with
/// the chunk instead of being taken again over the same body. It is null
/// exactly when `typ == .compressed`, whose body was not hashed here at all.
///
/// **`frame` is the chunk and `data` is its tail.** The header cannot be
/// derived from `data`, because the LEB128 carrying the length is exactly as
/// wide as the length needs, so a reader that needs the whole chunk — the one
/// a receiver dispatches on — takes `frame` instead of rebuilding a header
/// from the three fields below. [`storage/bundle.zig`](bundle.zig)'s
/// `parseFramedChunk` is that reader: a bundle is a chunk, so a bundle read
/// out of a multi-chunk stream hands back the bytes the stream carried, byte
/// for byte, with nothing re-framed and nothing copied.
pub const Chunk = struct {
    /// What the body holds. A tag read off the wire is one of the four
    /// [`ChunkType`] values, or the parse was refused with
    /// `error.InvalidChunkType`.
    typ: ChunkType,
    /// The four header bytes as they were stored, never a recomputation. For
    /// every type but `compressed` this equals `checksumOf(typ, data)`; for
    /// `compressed` it covers the *inflated* body and is checked by
    /// [`decompressChunk`] instead.
    checksum: [checksum_size]u8,
    /// The hash `checksum` is the first four bytes of, whole:
    /// `SHA-256(typ || uleb128(data.len) || data)`, the thirty-two bytes
    /// [`changeHashOf`] returns for those arguments — a change's identity when
    /// `typ` is `change`, and that chunk type's own hash otherwise.
    ///
    /// This is the hash, not a checksum widened to fill it: the bytes past the
    /// fourth are hash output here and zeros in `ChangeHash.fromChecksum`.
    ///
    /// **Null means the body was never hashed, and only ever that.** A
    /// `compressed` chunk's stored checksum covers the inflated body rather
    /// than the deflated bytes in `data` (`chunk.rs:118-122`), so there is no
    /// body hash to publish and [`decompressChunk`] is what verifies it.
    hash: ?ChangeHash,
    /// The body as stored, borrowed from the buffer the chunk was parsed
    /// from — still deflated for `ChunkType.compressed`.
    data: []const u8,
    /// The whole chunk, header included, borrowed from the same buffer:
    /// `frame` is exactly `data`'s bytes with the header prepended, so
    /// `frame.ptr + frame.len == data.ptr + data.len`.
    frame: []const u8,
};

/// The change hash of a chunk body: `SHA-256(typ || uleb128(len) || data)`
/// (`chunk.rs:300-312`). For a `change` chunk this is the change's identity
/// and is what the sync protocol compares.
///
/// The type byte and the length prefix are hashed ahead of `data`, so two
/// chunks over the same body under different types hash differently. Nothing
/// is allocated: the prefix is built on the stack, because a length prefix
/// cannot be wider than `leb128.max_unsigned_size`. `data` is only read, and
/// the result is an owned value that borrows nothing.
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

/// The four header bytes of `changeHashOf`, that is the first four bytes of
/// the hash. This is what a chunk header stores in its checksum field, and
/// what [`parseChunk`] compares against the body it just read. It is a value,
/// not a borrow: it copies four bytes off the hash and takes nothing of
/// `data`.
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
///
/// ## What is left in `out` when this fails
///
/// `out` belongs to the caller and this function only ever appends to it. Each
/// of the five appends is separately fallible and each is all-or-nothing —
/// `ArrayList` grows before it copies — so the only error here,
/// `error.OutOfMemory`, returns with the list holding one of the prefixes of
/// a whole chunk: nothing, the magic, the magic and the checksum, those plus
/// the type byte, those plus the length prefix, or — only on success — the
/// body as well. Nothing is rolled back and nothing truncates the list, so
/// the residue is a partial chunk that no reader accepts. The caller decides
/// whether `out` can still be used: a caller that appends another chunk
/// after a failure writes a stream whose first chunk is corrupt. Discard the
/// partial tail — `out.shrinkRetainingCapacity` back to the length the caller
/// recorded before the call, or `out.clearRetainingCapacity` if the list held
/// nothing before — or drop `out` and start again.
///
/// `gpa` is used for the list's growth only; `data` is copied into `out` and
/// stays owned by whoever supplied it.
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
///
/// ## What is left in `out` when this fails
///
/// The body is deflated first, into a buffer this function frees before it
/// returns, so a failure inside the deflate — the only error here,
/// `error.OutOfMemory` — leaves `out` exactly as the caller passed it. A
/// failure in one of the five appends that follow leaves the same residue
/// [`writeChunk`] describes: a prefix of a whole chunk, with no rollback and
/// no truncation. The caller owns `out` and must discard that partial tail
/// before it writes another chunk.
///
/// `body` is only read. The returned chunk borrows nothing: everything this
/// appends is copied into `out`.
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
/// Returns a buffer owned by the caller, freed with `gpa`. A chunk of any
/// other type is `error.InvalidChunkType`; a body that is not a raw DEFLATE
/// stream is `error.InvalidDeflate`; a growth the allocator cannot satisfy is
/// `error.OutOfMemory`; and a body that inflates to something other than what
/// the header records is `error.InvalidChecksum`. Nothing is returned on any
/// of them, and the inflated buffer is freed on the way out.
///
/// Callers must run a compressed body through this before parsing it, because
/// `parseChunk` cannot check the checksum without inflating. The expansion is
/// unbounded — see [`decompressRaw`] — so this is where a caller with a
/// resource ceiling imposes one.
///
/// **This is a spelling of [`decompressChunkWithHash`]**, which is where a
/// compressed chunk's change hash comes from. A caller that has nothing to do
/// with that hash — one that parses the inflated body by a route that hashes
/// it again — is served by this one and pays nothing extra for it.
pub fn decompressChunk(gpa: std.mem.Allocator, chunk: Chunk) ParseError![]u8 {
    return (try decompressChunkWithHash(gpa, chunk)).body;
}

/// What [`decompressChunkWithHash`] hands back: the inflated body, which the
/// caller owns, and the change hash the chunk's own header was checked
/// against.
///
/// **The two are one value because they are one computation.** Upstream keeps
/// the same pair side by side — `Header` carries the whole hash and the chunk's
/// `checksum_valid` compares its first four bytes out of that one `hash()`
/// call (`chunk.rs:187-201`, `:271`, `:279`) — and [`Chunk`] now carries it
/// too for a body that never had to be inflated. This is what puts the pair on
/// the compressed case, which is the one that had no place to keep it.
pub const Inflated = struct {
    /// The inflated body, owned by the caller and freed with `gpa`. Every
    /// slice a body parser derives from it points into this buffer, so it must
    /// outlive the parse and nothing may outlive it.
    body: []u8,
    /// `SHA-256(0x01 || uleb128(body.len) || body)` — the whole thirty-two
    /// bytes, of which this chunk's header records the first four. It is
    /// exactly what `changeHashOf` returns for those arguments, and exactly
    /// what `change.zig`'s `parseChange` would compute for itself over the
    /// same bytes: handing it to a body parser in place of letting that parser
    /// hash saves the second SHA-256 over the body and changes nothing else.
    hash: ChangeHash,
};

/// [`decompressChunk`], handing back the change hash this call had to compute
/// anyway to do its job.
///
/// **This is where a compressed chunk's change hash exists at all.** The stored
/// checksum of a `compressed` chunk is the checksum of the *inflated* body
/// hashed as a `change` chunk (`chunk.rs:118-122`), so this is the first and
/// only place those bytes are ever hashed: [`readChunk`] cannot produce a hash
/// for this type because it never inflates, and a body parser downstream would
/// otherwise take the same SHA-256 over the same bytes a second time. Upstream
/// reads the hash back out of the header it inflated and verified
/// (`change.rs:268-270`), which is what this hands over instead.
///
/// **The refusals are [`decompressChunk`]'s, tag for tag and at the same
/// points**: `error.InvalidChunkType` before a byte is read, `error.InvalidDeflate`
/// from the inflation, `error.OutOfMemory` from the growth, and
/// `error.InvalidChecksum` from the comparison — last, and before any caller
/// sees the inflated bytes. On any of them nothing is returned, the inflated
/// buffer is freed on the way out by the same `errdefer`, and no column has
/// been read, so a malformed compressed body reaches exactly as far as it
/// always did and no further.
pub fn decompressChunkWithHash(gpa: std.mem.Allocator, chunk: Chunk) ParseError!Inflated {
    if (chunk.typ != .compressed) return error.InvalidChunkType;
    const body = try decompressRaw(gpa, chunk.data);
    errdefer gpa.free(body);
    // **One SHA-256 over the inflated bytes, kept whole.** The comparison needs
    // the first four bytes of it; the change header a body parser builds needs
    // all thirty-two. Truncating here and hashing again there is the second
    // pass this exists to remove, so the hash is the one `checksumOf` was
    // folding the same way.
    const hash = changeHashOf(.change, body);
    if (!std.mem.eql(u8, &chunk.checksum, &hash.checksum())) {
        return error.InvalidChecksum;
    }
    return .{ .body = body, .hash = hash };
}

/// The room `compressRaw` leaves in its output buffer for everything the input
/// length does not account for: the DEFLATE block headers, and the few bytes a
/// body that does not shrink needs to grow into. It is also the whole capacity
/// when the length term cannot be added to it.
const deflate_headroom: usize = 64;

/// The capacity `compressRaw` starts its output buffer at: the input length plus
/// [`deflate_headroom`], or the headroom alone when that sum does not fit in a
/// `usize`.
///
/// A plain `data.len + deflate_headroom` wraps once `data.len` is within the
/// headroom of `maxInt(usize)`, and the wrapped value is what `Compress.init`
/// is then handed: at `maxInt(usize)` it is 0, which trips the
/// `output.buffer.len > 8` assert (`std/compress/flate/Compress.zig:309`) and
/// turns a large body into a trap. The length term is a hint and not a bound —
/// `Allocating` grows with checked arithmetic
/// (`std/Io/Writer.zig:2615-2644`) — so dropping it costs reallocations and
/// nothing else, and it is what upstream pays for every body anyway: the
/// deflate output goes into a `Vec::new()` that `read_to_end` grows
/// (`storage/change/compressed.rs:27-28`).
fn outputCapacity(data_len: usize) usize {
    return std.math.add(usize, data_len, deflate_headroom) catch deflate_headroom;
}

/// Deflates `data` into a raw DEFLATE stream: no zlib or gzip wrapper, which
/// is what a compressed chunk's body is (`change/compressed.rs:23-30`).
///
/// Returns a buffer owned by the caller, freed with `gpa`. The only error is
/// `error.OutOfMemory`: from the 64 KiB scratch window, from the output
/// buffer's first allocation, or from growth while the body is written. No
/// input causes a refusal — the caller supplies the bytes and the format
/// accepts any length. The level is zlib's default, the one
/// `flate2::Compression::default()` selects upstream.
pub fn compressRaw(gpa: std.mem.Allocator, data: []const u8) std.mem.Allocator.Error![]u8 {
    // `Compress.init` asserts the scratch window is at least `max_window_len`;
    // take it from `gpa` rather than the stack, because it is 64 KiB.
    const scratch = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(scratch);

    // `Compress` asserts the output buffer is longer than 8 bytes, and this
    // capacity also covers the usual case of a body that actually shrinks.
    // `outputCapacity` is what keeps that sum from wrapping into a capacity
    // too small for either of those claims.
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, outputCapacity(data.len));
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

/// Inflates a raw DEFLATE stream. Returns a buffer owned by the caller,
/// freed with `gpa`.
///
/// ## The output is unbounded, and there is no way to bound it here
///
/// The result grows into a `std.Io.Writer.Allocating` seeded with no
/// capacity, and it grows until the stream ends: nothing in this function
/// compares the inflated length against a limit, because `flate.Decompress.init`
/// takes an input, a container and a scratch buffer and **no limit at all**
/// (`std/compress/flate/Decompress.zig:79`). A caller cannot impose a ceiling
/// through this signature, and this crate adds no arbitrary cap of its own,
/// because a cap that is wrong for one document is a compatibility change and
/// the bound a real caller wants is a resource bound, not a format one.
///
/// That leaves the ceiling where it belongs: with the caller. Both reachable
/// entry points, [`decompressChunk`] and
/// [`storage/change_chunk.zig`](change_chunk.zig)'s `parseFramedChunk`, hand
/// this a body parsed straight out of an input buffer, so a small hostile
/// chunk costs an allocation in proportion to its own expansion ratio — the
/// ratio a deflate stream is free to choose, and the one this file's own
/// round-trip test pins by inflating sixty-four kilobytes of zeroes back out
/// of a stream well under a kilobyte. A caller that accepts untrusted
/// documents bounds it with the allocator it passes, which is the only lever
/// the signature offers.
///
/// ## The refusals
///
/// * `error.InvalidDeflate` — a stream that ends early, carries an invalid
///   code, over-runs a match, or is not a raw DEFLATE stream at all.
///   Upstream maps the same failure to `error::Chunk::Deflate`
///   (`chunk.rs:85-86`).
/// * `error.OutOfMemory` — the output could not be grown to the size the
///   stream encodes. This is the allocating writer's own failure, not a
///   defect in the input, and it is the only way a bounded allocator answers
///   here.
///
/// Nothing is returned on either, and the partial output is freed on the way
/// out. `data` is only read and stays owned by the caller.
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
///
/// The signature returns the crate-wide `ParseError`, so a caller cannot
/// narrow the refusals from it. These are the tags this reaches, and they fall
/// into three groups a caller may want to tell apart:
///
/// * **Truncation.** `error.UnexpectedEnd` — the input stops inside a header
///   or inside the body the declared length delimits. An empty input is one.
/// * **Corruption.** `error.InvalidMagic` for four bytes that are not
///   [`magic`]; `error.InvalidChunkType` for a type byte outside 0 to 3;
///   `error.InvalidLeb128` for an overlong length prefix; `error.Overflow` for
///   a tenth prefix byte wider than the one bit that is left;
///   `error.TooLarge` for a declared length that does not fit `usize`, which
///   is unreachable where `usize` is 64 bits wide; `error.LengthExceedsInput`
///   for a declared length larger than the bytes behind it; and
///   `error.InvalidChecksum` for a body that does not hash to the recorded
///   checksum, on every type but `compressed`.
/// * **Framing.** `error.TrailingBytes` — the chunk parsed and bytes remain.
///
/// On any of them nothing is returned and nothing is allocated. The `Chunk`
/// returned on success borrows `bytes`: `data`, `frame` and every slice
/// derived from them are valid only while that buffer is.
pub fn parseChunk(bytes: []const u8) ParseError!Chunk {
    var in: Input = .init(bytes);
    const chunk = try readChunk(&in);
    if (!in.isEmpty()) return error.TrailingBytes;
    return chunk;
}

/// Parses a stream of chunks, which is what a saved document is: chunk after
/// chunk until the input runs out (`load.rs:75-99`). The returned slice belongs
/// to the caller, who frees it with `gpa`; the chunks inside it borrow `bytes`.
///
/// An input that stops in the middle of a chunk is an error, not a short
/// result. Every chunk but a `compressed` one is checksum-verified here.
///
/// The refusals are those of [`parseChunk`] — `error.UnexpectedEnd`,
/// `error.InvalidMagic`, `error.InvalidChunkType`, `error.InvalidLeb128`,
/// `error.Overflow`, `error.TooLarge`, `error.LengthExceedsInput` and
/// `error.InvalidChecksum`, grouped there as truncation, corruption and
/// framing — plus `error.OutOfMemory` from the list this grows. Every chunk
/// that parsed before the refusal is discarded: `errdefer` frees the whole
/// list, so there is no partial result to recover. A caller that wants the
/// prefix that did parse uses [`parseChunksPartial`], which is the same walk
/// with the error captured rather than propagated.
///
/// The walk is bounded by the input: a chunk is at least
/// `magic + checksum + type + uleb128(0)` = 10 bytes, so the loop runs at most
/// `bytes.len / 10` times, and each declared length is checked against
/// `remaining()` before any of the body is taken.
pub fn parseChunks(bytes: []const u8, gpa: std.mem.Allocator) ParseError![]Chunk {
    var out: std.ArrayList(Chunk) = .empty;
    errdefer out.deinit(gpa);
    var in: Input = .init(bytes);
    while (!in.isEmpty()) {
        try out.append(gpa, try readChunk(&in));
    }
    return out.toOwnedSlice(gpa);
}

/// A chunk stream that stopped before the input ran out.
///
/// Upstream's `LoadedChanges`
/// ([`storage/load.rs`:51-64](../github-automerge-automerge/rust/automerge/src/storage/load.rs))
/// is the same shape: `Complete(Vec<Change>)` when the whole stream parsed,
/// and `Partial { loaded, remaining, error }` when a prefix did.
///
/// The caller owns the result and releases it with [`PartialChunks.deinit`],
/// exactly once. The value is a plain struct with one owned slice, so copying
/// it duplicates that slice's pointer: a copy is a second handle on the same
/// allocation, and deinitializing both frees the bytes twice. Copy a
/// `PartialChunks` only when exactly one of the copies is deinitialized, and
/// do not read `chunks` afterwards — the slices inside it borrow the input
/// buffer the walk read, which outlives this value but not a freed list.
pub const PartialChunks = struct {
    /// The chunks that parsed, in order. The caller owns the slice and frees
    /// it with [`PartialChunks.deinit`]; the chunks inside it borrow the
    /// input they were read from, which the caller also owns.
    chunks: []Chunk,
    /// What stopped the walk, or null when the input ran out cleanly. A null
    /// here means `chunks` covers the whole of `bytes`; a non-null one names
    /// the first refusal, of the vocabulary [`parseChunks`] lists.
    err: ?ParseError,

    /// Frees the slice and nothing else: the chunks borrow the input they
    /// were read from, so nothing inside `chunks` is owned here.
    ///
    /// Called once. The receiver is by value and `chunks` is a plain pointer,
    /// so a copied `PartialChunks` reaches the same allocation through
    /// [`PartialChunks.deinit`] twice and frees it twice. After it runs, this
    /// value and every copy of it are spent, and `chunks` must not be read.
    pub fn deinit(self: PartialChunks, gpa: std.mem.Allocator) void {
        gpa.free(self.chunks);
    }
};

/// [`parseChunks`], keeping whatever parsed before the first refusal
/// ([`load_changes`](../../github-automerge-automerge/rust/automerge/src/storage/load.rs):75-97).
///
/// **This is the same loop with the error captured instead of propagated.**
/// `load_changes` builds `changes` chunk by chunk and, on the first `Err`,
/// returns `LoadedChanges::Partial { loaded: changes, remaining: data, error }`
/// — the chunks before the bad one are kept, not discarded. A stream that is a
/// valid save with four bytes of rubbish appended parses every chunk and then
/// fails on the rubbish, and upstream keeps the document.
///
/// `parseChunks` stays the all-or-nothing spelling, because `Document.load`
/// *is* all-or-nothing: upstream's default is `OnPartialLoad::Error`
/// ([`automerge.rs`:107-110, :177](../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// The signature therefore returns only `error.OutOfMemory`, which the list
/// this grows can produce; a refusal to parse is not returned but stored in
/// [`PartialChunks.err`], which names one of the tags [`parseChunks`] lists.
/// An `error.OutOfMemory` still discards everything: `errdefer` frees the list
/// and nothing is returned, so this is the one case with no prefix to
/// recover. On the returned value, `err == null` means the input ran out
/// cleanly, and a caller that ignores `err` reads a prefix that may stop
/// mid-stream.
pub fn parseChunksPartial(
    bytes: []const u8,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!PartialChunks {
    var out: std.ArrayList(Chunk) = .empty;
    errdefer out.deinit(gpa);
    var in: Input = .init(bytes);
    while (!in.isEmpty()) {
        const chunk = readChunk(&in) catch |e| {
            return .{
                .chunks = try out.toOwnedSlice(gpa),
                .err = e,
            };
        };
        try out.append(gpa, chunk);
    }
    return .{ .chunks = try out.toOwnedSlice(gpa), .err = null };
}

/// Consumes one chunk from `in`, leaving the cursor on the first byte after
/// it. The body is bounded by the declared length, so a chunk can never read
/// into its successor.
///
/// **The frame is the window the chunk was read from**, taken from where the
/// cursor stood before the magic to where it stands after the body. That is
/// the whole of what preserving it costs: a slice of the caller's own buffer,
/// with no allocation, no copy, and no arithmetic about how wide the header
/// turned out to be — the one thing this layer knows exactly and a reader
/// downstream of it cannot work out.
///
/// The refusals are the ones [`parseChunk`] lists: the header reads give
/// `error.UnexpectedEnd`, `error.InvalidMagic`, `error.InvalidChunkType`,
/// `error.InvalidLeb128` and `error.Overflow`; the length gives
/// `error.TooLarge` and `error.LengthExceedsInput`; and the checksum gives
/// `error.InvalidChecksum` for every type but `compressed`. On any of them the
/// cursor stands where the refusal found it, and nothing is returned.
///
/// On success the hash the body was checked against is published on the
/// returned chunk as [`Chunk.hash`], all thirty-two bytes of it and not only
/// the four that were compared. There is no second hash here to save: this is
/// the one.
fn readChunk(in: *Input) ParseError!Chunk {
    const start = in.pos;
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
    //
    // **This is the one SHA-256 this layer takes, and every byte of it is
    // kept.** The four compared here are the four the header records, and the
    // other twenty-eight are the hash a change's identity is made of, so a
    // body parser downstream is handed it instead of hashing the same body
    // again. The comparison sits where it always did, so a body that does not
    // hash to what the header records is `error.InvalidChecksum` before
    // anything is returned; and the compressed case publishes nothing, because
    // its body was never hashed here.
    const hash: ?ChangeHash = switch (typ) {
        .compressed => null,
        else => blk: {
            const h = changeHashOf(typ, data);
            const sum = h.checksum();
            if (!std.mem.eql(u8, &checksum, &sum)) return error.InvalidChecksum;
            break :blk h;
        },
    };
    return .{
        .typ = typ,
        .checksum = checksum,
        .hash = hash,
        .data = data,
        .frame = in.bytes[start..in.pos],
    };
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

test "a parsed chunk publishes the whole hash its checksum is a prefix of" {
    const gpa = testing.allocator;
    // Every type but `compressed`. The published hash is that type's own chunk
    // hash, so the type byte is part of it and one body framed three ways
    // publishes three hashes.
    const bodies = [_][]const u8{ "", "one", "the quick brown fox" };
    const kinds = [_]ChunkType{ .document, .change, .bundle };
    for (bodies, kinds) |body, typ| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try writeChunk(&out, gpa, typ, body);

        const chunk = try parseChunk(out.items);
        const hash = chunk.hash orelse return error.TestUnexpectedResult;
        // The four header bytes are the first four of the thirty-two: one
        // value at two widths, which is the whole point of keeping it.
        try testing.expectEqualSlices(u8, &chunk.checksum, &hash.checksum());
        try testing.expectEqual(changeHashOf(typ, body), hash);
        // And the tail is hash output, not filler. A checksum zero-extended to
        // thirty-two bytes agrees on four and differs on the rest.
        const widened = ChangeHash.fromChecksum(chunk.checksum);
        try testing.expect(!std.mem.eql(u8, &widened.bytes, &hash.bytes));
    }

    // On the bytes automerge itself wrote, the published hash is the change
    // hash the sync protocol compares, all thirty-two of it. Ten header bytes
    // and the 57-byte body is the whole of that chunk.
    const first: []const u8 = two_change_chunks[0 .. 10 + change_body.len];
    const written = try parseChunk(first);
    try testing.expectEqualSlices(u8, &change_body, written.data);
    const written_hash = written.hash orelse return error.TestUnexpectedResult;
    var text: [64]u8 = undefined;
    err.hexInto(&written_hash.bytes, &text);
    try testing.expectEqualStrings(
        "9ac3d730f262da35e71db591b9e8150de9b02826daf75006f2298916adec6e0b",
        &text,
    );
    // ... and its first four are the four in that chunk's own header, read off
    // the frame rather than recomputed.
    try testing.expectEqualSlices(u8, written.frame[4..8], &written_hash.checksum());
}

test "a compressed chunk publishes no hash, because its body was never hashed" {
    const gpa = testing.allocator;
    const body = "a body that compresses well " ** 8;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try compressChunk(&out, gpa, body);

    const chunk = try parseChunk(out.items);
    // Its checksum covers the inflated body, which is not in `data`, so there
    // is nothing here a hash could have been taken over. Null says exactly
    // that, and nothing is claimed that was not checked.
    try testing.expectEqual(@as(?ChangeHash, null), chunk.hash);

    // The checksum is still exactly the change's own, checked where the body
    // can be seen whole.
    const inflated = try decompressChunk(gpa, chunk);
    defer gpa.free(inflated);
    try testing.expectEqualSlices(u8, &checksumOf(.change, inflated), &chunk.checksum);
}

test "a refused chunk publishes nothing" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeChunk(&out, gpa, .change, "body");

    // A body that no longer hashes to what the header records, both ways
    // round: the edit is in the body, and the edit is in the checksum field.
    var tampered = try gpa.dupe(u8, out.items);
    defer gpa.free(tampered);
    tampered[tampered.len - 1] ^= 0x01;
    try testing.expectError(error.InvalidChecksum, parseChunk(tampered));

    var wrong_sum = try gpa.dupe(u8, out.items);
    defer gpa.free(wrong_sum);
    wrong_sum[4] ^= 0x01;
    try testing.expectError(error.InvalidChecksum, parseChunk(wrong_sum));

    // The refusals that come before the body is reached are unchanged, and
    // none of them can publish a hash: there was no body to have hashed.
    try testing.expectError(error.UnexpectedEnd, parseChunk(out.items[0..6]));
    try testing.expectError(error.InvalidMagic, parseChunk("not a chunk at all"));

    var bad_type = try gpa.dupe(u8, out.items);
    defer gpa.free(bad_type);
    bad_type[8] = 0x09;
    try testing.expectError(error.InvalidChunkType, parseChunk(bad_type));

    var bad_len = try gpa.dupe(u8, out.items);
    defer gpa.free(bad_len);
    bad_len[9] = 0x7f; // 127 bytes claimed, 4 behind them
    try testing.expectError(error.LengthExceedsInput, parseChunk(bad_len));

    var bad_magic = try gpa.dupe(u8, out.items);
    defer gpa.free(bad_magic);
    bad_magic[2] ^= 0xff;
    try testing.expectError(error.InvalidMagic, parseChunk(bad_magic));

    var overlong = try gpa.dupe(u8, out.items);
    defer gpa.free(overlong);
    overlong[9] = 0x80; // a length prefix whose continuation byte is not there
    try testing.expectError(error.UnexpectedEnd, parseChunk(overlong[0..10]));
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
    // **The frame is the input byte for byte, and the body is its tail** —
    // not a window recomputed from a header length worked out here. The
    // LEB128 carrying the length is exactly the part a reader downstream
    // cannot derive from the body, which is why the whole chunk is what
    // travels here rather than the two ends of it.
    try testing.expectEqualSlices(u8, out.items, chunk.frame);
    try testing.expectEqual(
        chunk.frame.ptr + chunk.frame.len,
        chunk.data.ptr + chunk.data.len,
    );

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
    // **The frames tile the stream exactly.** Nothing is dropped between two
    // chunks and nothing is counted twice, so a chunk taken out of a stream
    // hands back the bytes the stream carried — which is what a receiver
    // re-sending one chunk of a document needs.
    var at: usize = 0;
    for (chunks) |chunk| {
        try testing.expectEqualSlices(u8, out.items[at..][0..chunk.frame.len], chunk.frame);
        at += chunk.frame.len;
    }
    try testing.expectEqual(out.items.len, at);

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

test "an overlong length prefix is a malformed length, not a short read" {
    const gpa = testing.allocator;
    // A complete header — magic, checksum, type 1 — and then eleven
    // continuation bytes, one more than the widest legal uleb128. The prefix
    // spends a byte the length did not need, so the strict reader refuses it
    // as `InvalidLeb128` rather than as `Overflow`, which is what a tenth
    // byte carrying more than the one bit that is left produces.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, &magic);
    try bytes.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 }); // never verified
    try bytes.append(gpa, @intFromEnum(ChunkType.change));
    try bytes.appendNTimes(gpa, 0x80, 11);

    try testing.expectError(error.InvalidLeb128, parseChunk(bytes.items));
    try testing.expectError(error.InvalidLeb128, parseChunks(bytes.items, gpa));

    // A truncated prefix is a different refusal: the input ran out rather
    // than the encoding being wrong.
    var cut: std.ArrayList(u8) = .empty;
    defer cut.deinit(gpa);
    try cut.appendSlice(gpa, bytes.items[0 .. bytes.items.len - 4]);
    try testing.expectError(error.UnexpectedEnd, parseChunk(cut.items));
}

test "a failed write leaves the bytes it had already appended" {
    const gpa = testing.allocator;
    // A failing allocator is the only way these writers can fail, and each of
    // the five appends is separately fallible. The residue is whatever the
    // appends that did succeed left behind: there is no rollback and nothing
    // truncates the list, so a caller that keeps using it would write a
    // corrupt chunk.
    //
    // Each append is all-or-nothing — `ArrayList` grows before it copies — so
    // the residue is always one of the six prefix lengths a whole chunk
    // passes through, and never something inside the body. How many of those
    // appends fit in one allocation is `ArrayList`'s growth policy and not
    // this function's, so the test asserts the property over every
    // allocation index rather than one hard-coded residue.
    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(gpa);
    try writeChunk(&whole, gpa, .change, "body");

    for (0..8) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        var partial: std.ArrayList(u8) = .empty;
        defer partial.deinit(gpa);

        writeChunk(&partial, failing.allocator(), .change, "body") catch |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            // One of the prefix lengths a whole chunk passes through, and
            // strictly shorter than the whole chunk: nothing, the magic,
            // magic + checksum, + type byte, + length prefix. Nothing between
            // them is reachable, because no append is half done, and the
            // full length is not reachable either — a body that was appended
            // is a chunk that was written.
            const prefixes = [_]usize{ 0, 4, 8, 9, 10 };
            var a_prefix = false;
            for (prefixes) |len| {
                if (partial.items.len != len) continue;
                a_prefix = true;
                try testing.expectEqualSlices(u8, whole.items[0..len], partial.items);
            }
            try testing.expect(a_prefix);
            continue;
        };
        // No failure at this index means the whole write fitted, so there is
        // nothing to assert about a residue here.
        try testing.expectEqualSlices(u8, whole.items, partial.items);
    }

    // The first append onto an empty list has to allocate, so this is the
    // residue a caller sees when the very first byte cannot be written: the
    // list is untouched, because nothing had been appended to it before.
    var reused: std.ArrayList(u8) = .empty;
    defer reused.deinit(gpa);
    var at_start: testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        writeChunk(&reused, at_start.allocator(), .change, "body"),
    );
    try testing.expectEqual(@as(usize, 0), reused.items.len);

    // Discarding the partial tail is the caller's job, and on a list whose
    // only residue is what the failed call left, clearing it is enough: the
    // same list then writes a chunk a reader accepts.
    reused.clearRetainingCapacity();
    try writeChunk(&reused, gpa, .change, "body");
    const chunk = try parseChunk(reused.items);
    try testing.expectEqual(ChunkType.change, chunk.typ);
    try testing.expectEqualStrings("body", chunk.data);

    // `compressChunk` deflates before it appends anything, so a failure in
    // the deflate itself cannot leave a residue: the list is untouched.
    var deflate_fails: testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    var untouched: std.ArrayList(u8) = .empty;
    defer untouched.deinit(gpa);
    try untouched.append(gpa, 0x77);
    try testing.expectError(
        error.OutOfMemory,
        compressChunk(&untouched, deflate_fails.allocator(), "a body that compresses well " ** 8),
    );
    try testing.expectEqualSlices(u8, &[_]u8{0x77}, untouched.items);
}

test "an inflate grows to what the stream encodes, and a bounded allocator is what stops it" {
    const gpa = testing.allocator;
    // Nothing in the inflate bounds the output, and this is what that looks
    // like: a body of zeroes deflates to a small stream and comes back at
    // full size, so the cost of the inflate is a function of the expansion
    // ratio the stream chose, not of the bytes on the wire.
    const body = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(body);
    @memset(body, 0);

    const deflated = try compressRaw(gpa, body);
    defer gpa.free(deflated);
    // A run of zeroes deflates to a tiny stream, so the inflate below asks
    // the allocator for sixty-four times the bytes that reached it.
    try testing.expect(deflated.len * 64 < body.len);

    const inflated = try decompressRaw(gpa, deflated);
    defer gpa.free(inflated);
    try testing.expectEqualSlices(u8, body, inflated);

    // The signature offers no cap a caller could pass, so the ceiling is the
    // allocator: a writer that cannot grow answers `OutOfMemory` rather than
    // truncating the output into a document that looks whole.
    var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, decompressRaw(failing.allocator(), deflated));
    try testing.expectEqual(@as(usize, 0), failing.allocations);
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

test "a declared length that would wrap the deflate capacity hint is refused" {
    const gpa = testing.allocator;
    const max = std.math.maxInt(usize);
    // `compressRaw` reserves `data.len + deflate_headroom` for its output, so
    // the only body length that could make that sum wrap is one within the
    // headroom of `maxInt(usize)`. A chunk declaring one is refused by the
    // framing instead: `readChunk` bounds the declared length against what is
    // left of the input before the body is touched, so the value never reaches
    // an allocation.
    const declared = [_]usize{
        max - deflate_headroom,
        max - deflate_headroom + 1,
        max,
    };
    for (declared) |len| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, &magic);
        // The checksum is never reached: the length is bounded first, so four
        // zero bytes here are as good as the value the reference would write.
        try bytes.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
        try bytes.append(gpa, @intFromEnum(ChunkType.change));
        try leb128.appendUnsigned(&bytes, gpa, len);
        try bytes.appendSlice(gpa, "body");
        try testing.expectError(error.LengthExceedsInput, parseChunk(bytes.items));

        // And the streaming entry point refuses it with an allocator that fails
        // every allocation, so the error is the length and not the allocator.
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
        try testing.expectError(
            error.LengthExceedsInput,
            parseChunks(bytes.items, failing.allocator()),
        );
        try testing.expectEqual(@as(usize, 0), failing.allocations);
    }
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

test "the deflate capacity hint is the old sum where it fits, and never wraps" {
    const max = std.math.maxInt(usize);
    // Small bodies: the hint is exactly what the old `data.len + 64` computed,
    // so a body any real document can carry starts from the same capacity it
    // always did and deflates to the same bytes.
    for (0..deflate_headroom + 1) |len| {
        try testing.expectEqual(@as(usize, len) + deflate_headroom, outputCapacity(len));
    }
    // The largest body whose sum still fits, and the two past it. The headroom
    // is 64 bytes, so `maxInt - 64` is the last length the old sum could carry
    // and `maxInt - 63` is the first it would have wrapped: 0 there, and 63 at
    // `maxInt` itself, both of which are buffers `Compress.init` refuses.
    try testing.expectEqual(max, outputCapacity(max - deflate_headroom));
    try testing.expectEqual(deflate_headroom, outputCapacity(max - deflate_headroom + 1));
    try testing.expectEqual(deflate_headroom, outputCapacity(max));

    // Whatever the body, the hint stays above the eight bytes `Compress.init`
    // asserts on (`std/compress/flate/Compress.zig:309`), so no length reaches
    // the compressor through a buffer too small to enter it.
    const lens = [_]usize{ 0, 1, 8, 9, 4096, max - deflate_headroom, max };
    for (lens) |len| try testing.expect(outputCapacity(len) > 8);
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
        decompressChunk(gpa, .{ .typ = .change, .checksum = chunk.checksum, .hash = chunk.hash, .data = chunk.data, .frame = chunk.frame }),
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

test "decompressChunkWithHash is decompressChunk with the change hash it already had" {
    const gpa = testing.allocator;
    const body = "a change body that compresses well " ** 20;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try compressChunk(&out, gpa, body);
    const c = try parseChunk(out.items);

    // The body is the one the plain spelling returns, byte for byte.
    const plain = try decompressChunk(gpa, c);
    defer gpa.free(plain);
    const both = try decompressChunkWithHash(gpa, c);
    defer gpa.free(both.body);
    try testing.expectEqualStrings(plain, both.body);

    // **The hash is over the inflated bytes, framed as a `change`** — not over
    // the deflated ones still in `c.data`, and not over the header. Its first
    // four bytes are the checksum this chunk's header records, which is what
    // ties the two together: the comparison `decompressChunk` made is the same
    // four bytes this hash begins with.
    try testing.expect(both.hash.eql(changeHashOf(.change, plain)));
    try testing.expectEqualSlices(u8, &c.checksum, &both.hash.checksum());
    try testing.expect(!std.mem.eql(
        u8,
        &changeHashOf(.compressed, c.data).checksum(),
        &both.hash.checksum(),
    ));

    // The same rule over the compressed fixture automerge wrote, where the
    // recorded checksums were carried over from the uncompressed file.
    const chunks = try parseChunks(&two_change_chunks_compressed, gpa);
    defer gpa.free(chunks);
    for (chunks) |compressed| {
        try testing.expectEqual(ChunkType.compressed, compressed.typ);
        const one = try decompressChunkWithHash(gpa, compressed);
        defer gpa.free(one.body);
        try testing.expect(one.hash.eql(changeHashOf(.change, one.body)));
        try testing.expectEqualSlices(u8, &compressed.checksum, &one.hash.checksum());
    }
}

test "both decompression spellings refuse the same bytes with the same tag" {
    const gpa = testing.allocator;
    const body = "a change body that compresses well " ** 20;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try compressChunk(&out, gpa, body);
    const c = try parseChunk(out.items);

    // A checksum that does not describe the inflated body, and a chunk that is
    // not compressed at all: one refusal after the inflation, one before it.
    var bad_checksum = c;
    bad_checksum.checksum[0] ^= 0x01;
    var wrong_type = c;
    wrong_type.typ = .change;
    // `writeChunk` hashes the bytes it is handed, so a `.compressed` chunk
    // written over deflated bytes carries a checksum no inflation can match.
    var wrong: std.ArrayList(u8) = .empty;
    defer wrong.deinit(gpa);
    try writeChunk(&wrong, gpa, .compressed, c.data);
    const misframed = try parseChunk(wrong.items);

    // **The sibling is a superset, not a variant.** Same input, same refusal,
    // and nothing returned either way — which is what keeps a malformed
    // compressed body from reaching a body parser through the new spelling
    // when it did not through the old one.
    for ([_]Chunk{ bad_checksum, wrong_type, misframed }) |input| {
        if (decompressChunk(gpa, input)) |leaked| {
            gpa.free(leaked);
            return error.TestUnexpectedResult;
        } else |plain_err| {
            if (decompressChunkWithHash(gpa, input)) |leaked| {
                gpa.free(leaked.body);
                return error.TestUnexpectedResult;
            } else |with_err| {
                try testing.expectEqual(plain_err, with_err);
            }
        }
    }
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

    // **Each chunk carries the exact window automerge wrote**, 67 bytes for
    // the first and the rest of the file for the second, so a reader that
    // needs a whole chunk re-emits automerge's own bytes rather than a header
    // this port rebuilt.
    try testing.expectEqualSlices(u8, two_change_chunks[0..67], chunks[0].frame);
    try testing.expectEqualSlices(u8, two_change_chunks[67..], chunks[1].frame);

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
