//! The change record: one change's metadata plus the bytes it was decoded from.
//!
//! A change is the unit of causality. It names the changes it depends on, the
//! actor that authored it, where its op counters start, and its ops. The ops
//! are columnar and belong to the columnar layer; this module owns the fixed
//! header in front of them and the identity that goes with it.
//!
//! A change chunk is `[4 magic][4 checksum][1 type][uleb len][body]`, and the
//! change hash is `SHA-256(type || uleb(len) || body)`
//! (`storage/chunk.zig`), and a chunk's checksum field is the first four
//! bytes of that hash. So the hash covers the body, the body covers the
//! header, and a change's identity cannot be known without its bytes — which
//! is why `Change` keeps the two together instead of storing the header twice.
//!
//! ## The change chunk body
//!
//! ```text
//! offset  size  field
//! 0       n     deps: uleb128 count, then count * 32 raw hash bytes
//! ...     n     actor: uleb128 byte count + raw bytes
//! ...     n     seq: uleb128
//! ...     n     start_op: nonzero uleb128
//! ...     n     time: sleb128, seconds since the epoch
//! ...     n     message: uleb128 byte count + UTF-8 bytes
//! ...     n     other_actors: uleb128 count, then per actor uleb128 length + bytes
//! ...     m     the op columns, and after them the author footer
//! ```
//!
//! Every one of those is FORMAT. Upstream's reader is
//! `storage/change.rs:100-156` and its writer is
//! `ChangeBuilder::build` (`storage/change.rs:453-522`); the two agree
//! field for field, and this port is checked against both.
//!
//! Three details are easy to get wrong and each is pinned by a test below:
//!
//! * A dependency is 32 raw bytes with **no** length prefix. Only the count is
//!   length-prefixed (`storage/change.rs:470-473`).
//! * `start_op` must not be zero. Upstream reads it as a `NonZeroU64`
//!   (`parse/leb128.rs:87-96`) and treats a zero as `UnexpectedZero`; this
//!   port has no `NonZeroU64`, so the check is explicit and reports
//!   `error.InvalidLeb128`.
//! * `time` is **signed**. A timestamp before 1970 is a negative sleb128, and
//!   writing it as uleb128 changes the change hash.
//!
//! ## What this module does not decode
//!
//! `parseChange` reads the header and leaves the op columns where they are.
//! The op count is not in the header — it is the row count of the columns —
//! so `max_op` is not knowable here and stays 0 until `withOpCount` is called
//! by whoever decodes the columns. Upstream reaches the same value by walking
//! the ops (`Change::max_op`, `change.rs:74-76`).
//!
//! For the same reason the author footer — everything after the op data,
//! `uleb(1) || uleb(len) || bytes` (`change.rs:365-403`) — is left inside
//! `bytes` rather than split out: where it starts needs the op data length.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");
const leb128 = @import("leb128.zig");
const parse = @import("storage/parse.zig");
const chunk = @import("storage/chunk.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const ActorId = types.ActorId;
const ChangeHash = types.ChangeHash;
const hash_size = types.hash_size;
const Input = parse.Input;

comptime {
    // A run of dependencies is borrowed straight out of the input as a slice
    // of `ChangeHash`, which is only a re-interpretation when the hash is
    // exactly 32 bytes at alignment one. If a future `ChangeHash` grows a tag
    // or a length, this stops the port instead of misreading the body.
    if (@sizeOf(ChangeHash) != hash_size) @compileError("ChangeHash must stay 32 bytes wide");
    if (@alignOf(ChangeHash) != 1) @compileError("ChangeHash must stay alignment 1 to be borrowed from the input");
}

/// One change: its metadata, and the bytes it was decoded from.
///
/// `bytes` is the whole chunk body — header included — and every other field
/// either borrows from it or is a copy of a value read out of it. A `Change`
/// is therefore only valid while its `bytes` are, and it owns exactly one
/// allocation: the `other_actors` array `parseChange` makes. `deinit` frees
/// that and nothing else.
///
/// Use `parseChange` to get one. Building one by hand is fine and is what the
/// future change encoder does, but then `other_actors` is whatever slice the
/// caller put there and `deinit` must not be called on it.
pub const Change = struct {
    /// The change chunk body: the header this change was parsed from,
    /// followed by its op columns and the author footer. The change hash
    /// covers exactly these bytes, framed as a `ChunkType.change` chunk.
    bytes: []const u8,
    /// The length of the header: the op columns start here, and
    /// `bytes[0..header_len]` is the header, byte for byte as it was read.
    header_len: usize,
    /// The actor that authored the change. It is not in `other_actors`: a
    /// change names its author once, and the op columns number every actor
    /// from it (`change_actors.rs:10-14`).
    actor: ActorId,
    /// The changes that must be applied before this one. On the wire this is
    /// a count followed by fixed-width hashes, so the slice borrows
    /// `bytes`; in a stored change it is sorted, because the writer sorts
    /// before encoding (`ChangeBuilder::with_dependencies`,
    /// `storage/change.rs:343-344`).
    deps: []const ChangeHash,
    /// `SHA-256(0x01 || uleb128(len(bytes)) || bytes)`, the identity the sync
    /// protocol and the change graph compare.
    hash: ChangeHash,
    /// Commit time in seconds since the epoch. Upstream calls it
    /// `timestamp`; it is a wall clock, not a logical clock, and the document
    /// never depends on it.
    time: i64,
    /// The commit message. An absent message and an empty one are the same
    /// thing here: upstream decodes an empty message to `None`, not to
    /// `Some("")` (`storage/change.rs:144-147`), and an empty byte string
    /// re-encodes to the same zero length.
    message: []const u8,
    /// The actor's sequence number: 1 for an actor's first change. Per-actor
    /// changes are strictly sequential, which is what `SeqClock` compares
    /// (`change_graph.rs:571-573`).
    seq: u64,
    /// The counter of this change's first op, never zero
    /// (`parse/leb128.rs:87-96`).
    start_op: u64,
    /// The counter of this change's last op, which is `start_op - 1` for a
    /// change with no ops. `parseChange` cannot know it, so this is 0 until
    /// `withOpCount` is called. Do not read it on a freshly parsed change.
    max_op: u64,
    /// The actors this change references but does not own, in the lexicographic
    /// order the writer emits them in (`change_actors.rs:10-14`). They are
    /// interned into the document's actor table in that order.
    other_actors: []const ActorId,

    /// The op columns and the author footer: `bytes` from the end of the
    /// header on. The columnar layer owns the decoding; this is its input.
    pub fn opsBytes(self: Change) []const u8 {
        return self.bytes[self.header_len..];
    }

    /// True when `other` is one of this change's dependencies.
    pub fn hasDependency(self: Change, other: ChangeHash) bool {
        for (self.deps) |dep| {
            if (dep.eql(other)) return true;
        }
        return false;
    }

    /// The same change with `max_op` filled in from the op count the columns
    /// yielded: the last op id it owns is `start_op + num_ops - 1`
    /// (`change.rs:74-76`). A change with no ops therefore has
    /// `max_op = start_op - 1`, which is a value the format permits — an
    /// empty transaction still commits a change.
    ///
    /// Rejects a `start_op` past `u32::MAX`. Op counters are `u32` in this
    /// port, and upstream refuses the same change when it walks the ops
    /// (`ReadChangeOpError::CounterTooLarge`, `storage/change.rs:182-184`).
    /// Here the check waits for the op count, because the columns that would
    /// supply it are not decoded in this module.
    pub fn withOpCount(self: Change, num_ops: u64) ParseError!Change {
        if (self.start_op > std.math.maxInt(u32)) return error.Overflow;
        var next = self;
        next.max_op = if (num_ops == 0)
            self.start_op - 1
        else
            self.start_op + (num_ops - 1);
        return next;
    }

    /// Writes the change header, in the order and widths the format fixes, to
    /// the end of `out`.
    ///
    /// This is the inverse of the header half of `parseChange`: a change
    /// parsed from a body and written back with it produces the original
    /// bytes. Dependencies keep the order the caller gave them, so a parsed
    /// change round trips; upstream sorts them in the *builder*
    /// (`storage/change.rs:343-344`), which is where a new change's order is
    /// decided, not here.
    pub fn encodeHeader(self: Change, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
        try leb128.appendUnsigned(out, gpa, self.deps.len);
        for (self.deps) |dep| try out.appendSlice(gpa, &dep.bytes);
        try appendLengthPrefixed(out, gpa, self.actor.bytes);
        try leb128.appendUnsigned(out, gpa, self.seq);
        try leb128.appendUnsigned(out, gpa, self.start_op);
        try leb128.appendSigned(out, gpa, self.time);
        try appendLengthPrefixed(out, gpa, self.message);
        try leb128.appendUnsigned(out, gpa, self.other_actors.len);
        for (self.other_actors) |actor| try appendLengthPrefixed(out, gpa, actor.bytes);
    }

    /// The whole change chunk, framed and ready to concatenate into a
    /// document. The body is `bytes` as it stands: it is already the exact
    /// body the hash was taken over, so nothing is re-serialised here.
    pub fn encode(self: Change, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try chunk.writeChunk(&out, gpa, .change, self.bytes);
        return out.toOwnedSlice(gpa);
    }

    /// A short form for an error message: the hash prefix, the author, the
    /// sequence number, the op range, and the message.
    pub fn debugString(self: Change, gpa: Allocator) Allocator.Error![]u8 {
        // Eight hex digits is enough to find the change in a hash set and
        // short enough to keep an error readable.
        var hash_prefix: [16]u8 = undefined;
        err.hexInto(self.hash.bytes[0..8], &hash_prefix);
        const actor_hex = try types.ActorId.toHex(gpa, self.actor);
        defer gpa.free(actor_hex);
        return std.fmt.allocPrint(gpa, "change {s} by {s} seq {d} ops {d}-{d} at {d}: {s}", .{
            hash_prefix[0..8], actor_hex, self.seq, self.start_op, self.max_op, self.time, self.message,
        });
    }

    /// Frees the actor array `parseChange` allocated. Everything else in the
    /// change borrows `bytes` and is left alone.
    ///
    /// Only call this on a `Change` that came from `parseChange`; a hand-built
    /// one has no allocation behind `other_actors`.
    pub fn deinit(self: *Change, gpa: Allocator) void {
        gpa.free(self.other_actors);
        self.other_actors = &.{};
    }
};

/// The change graph's view of a change: the same fields, without the bytes.
///
/// The graph keeps one of these per node for the life of the document, where
/// the encoded change is usually gone, so a metadata value outlives the chunk
/// it came from only if it was copied — see `intoOwned`. Upstream stores
/// `actor, author, seq, start_op, max_op, timestamp, message, deps, hash, extra`
/// (`op_set2/types.rs:748-760`); `author` and `extra` are the author footer,
/// which this module leaves inside `Change.bytes`.
pub const ChangeMetadata = struct {
    /// The actor that authored the change.
    actor: ActorId,
    /// The changes that must be applied before this one, sorted.
    deps: []const ChangeHash,
    /// The change's identity.
    hash: ChangeHash,
    /// Commit time in seconds since the epoch.
    time: i64,
    /// The commit message, empty when there was none.
    message: []const u8,
    /// The actor's sequence number, 1 for its first change.
    seq: u64,
    /// The counter of the change's first op.
    start_op: u64,
    /// The counter of the change's last op.
    max_op: u64,
    /// The actors this change references but does not own.
    other_actors: []const ActorId,

    /// The metadata for a change, borrowing everything from it. The result is
    /// only valid while `change.bytes` is.
    pub fn fromChange(change: Change) ChangeMetadata {
        return .{
            .actor = change.actor,
            .deps = change.deps,
            .hash = change.hash,
            .time = change.time,
            .message = change.message,
            .seq = change.seq,
            .start_op = change.start_op,
            .max_op = change.max_op,
            .other_actors = change.other_actors,
        };
    }

    /// A deep copy that owns its bytes, for a graph node that outlives the
    /// change it was read from. Upstream's `into_owned`
    /// (`op_set2/types.rs:762-777`) is the same move, for the same reason.
    pub fn intoOwned(self: ChangeMetadata, gpa: Allocator) Allocator.Error!ChangeMetadata {
        const actor = try gpa.dupe(u8, self.actor.bytes);
        errdefer gpa.free(actor);
        const deps = try gpa.dupe(ChangeHash, self.deps);
        errdefer gpa.free(deps);
        const message = try gpa.dupe(u8, self.message);
        errdefer gpa.free(message);

        const others = try gpa.alloc(ActorId, self.other_actors.len);
        var filled: usize = 0;
        errdefer {
            for (others[0..filled]) |a| gpa.free(a.bytes);
            gpa.free(others);
        }
        for (self.other_actors) |src| {
            others[filled] = .{ .bytes = try gpa.dupe(u8, src.bytes) };
            filled += 1;
        }

        return .{
            .actor = .{ .bytes = actor },
            .deps = deps,
            .hash = self.hash,
            .time = self.time,
            .message = message,
            .seq = self.seq,
            .start_op = self.start_op,
            .max_op = self.max_op,
            .other_actors = others,
        };
    }

    /// Frees everything `intoOwned` allocated, and nothing a borrowed value
    /// points at. Only valid on metadata that came from `intoOwned`.
    pub fn deinit(self: *ChangeMetadata, gpa: Allocator) void {
        gpa.free(self.actor.bytes);
        gpa.free(self.deps);
        gpa.free(self.message);
        for (self.other_actors) |a| gpa.free(a.bytes);
        gpa.free(self.other_actors);
        self.* = undefined;
    }

    /// True when `other` is one of this change's dependencies.
    pub fn hasDependency(self: ChangeMetadata, other: ChangeHash) bool {
        for (self.deps) |dep| {
            if (dep.eql(other)) return true;
        }
        return false;
    }

    /// The entry this change contributes to a sequence clock: its sequence
    /// number, because a clock entry counts an actor's changes
    /// (`clock.zig`) and `seq` is that count
    /// (`change_graph.rs:812-816`). Null when `seq` is past `u32::MAX`, which
    /// a clock entry cannot hold.
    pub fn clockEntry(self: ChangeMetadata) ?u32 {
        return std.math.cast(u32, self.seq);
    }
};

/// Reads the header of a change chunk body. `bytes` is the body only, with no
/// chunk framing, which is what `chunk.parseChunk` hands back and what
/// `decompressChunk` produces for a compressed change.
///
/// Everything borrowed out of the result points into `bytes`, so `bytes` must
/// outlive the change. The one allocation is the `other_actors` array; free it
/// with `Change.deinit`.
///
/// Refused, all of them `ParseError`:
///
/// * a header that runs off the end of the input, or a length inside it that
///   the remaining bytes could not hold;
/// * a dependency or other-actor count larger than the input could hold, which
///   is caught before anything is sized or indexed;
/// * a `start_op` of zero;
/// * a commit message that is not UTF-8.
pub fn parseChange(bytes: []const u8, gpa: Allocator) ParseError!Change {
    var in: Input = .init(bytes);

    var dep_sink: DepSink = .{ .in = &in };
    try in.readCountThen(&dep_sink, hash_size, DepSink.collect);

    const actor_bytes = try in.readStrBytes();
    const seq = try in.takeUleb();
    const start_op = try in.takeUleb();
    // Upstream's `NonZeroU64` (`parse/leb128.rs:87-96`); the port has no
    // non-optional integer, so the invariant is checked here.
    if (start_op == 0) return error.InvalidLeb128;
    const time = try in.takeLeb();
    const message = try in.readStr();

    var actor_sink: ActorSink = .{ .in = &in, .gpa = gpa };
    try in.readCountThen(&actor_sink, 1, ActorSink.collect);

    return .{
        .bytes = bytes,
        .header_len = in.pos,
        .actor = .{ .bytes = actor_bytes },
        .deps = dep_sink.deps,
        .hash = chunk.changeHashOf(.change, bytes),
        .time = time,
        .message = message,
        .seq = seq,
        .start_op = start_op,
        // The op count lives in the columns, not in the header. Whoever
        // decodes them calls `withOpCount`.
        .max_op = 0,
        .other_actors = actor_sink.list,
    };
}

/// The `readCountThen` destination for the dependency list. A dependency is
/// 32 raw bytes with no length prefix, so a run of them is already a
/// `[]const ChangeHash` over the input and nothing is copied.
const DepSink = struct {
    in: *Input,
    deps: []const ChangeHash = &.{},

    fn collect(self: *DepSink, count: usize) ParseError!void {
        if (count == 0) return;
        // `readCountThen` proved `count <= remaining / hash_size`, so the
        // multiplication cannot overflow and the take cannot run out.
        const raw = try self.in.take(count * hash_size);
        self.deps = @as([*]const ChangeHash, @ptrCast(raw.ptr))[0..count];
    }
};

/// The `readCountThen` destination for the other actors. An actor is
/// length-prefixed, so the actors are not contiguous and the array of them
/// does have to be built.
const ActorSink = struct {
    in: *Input,
    gpa: Allocator,
    list: []const ActorId = &.{},

    fn collect(self: *ActorSink, count: usize) ParseError!void {
        // The common case: a change that only ever refers to its own actor.
        if (count == 0) return;
        const actors = try self.gpa.alloc(ActorId, count);
        errdefer self.gpa.free(actors);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            actors[i] = .{ .bytes = try self.in.readStrBytes() };
        }
        self.list = actors;
    }
};

/// A uleb128 byte count followed by the bytes. Upstream
/// `length_prefixed_bytes` (`storage/change.rs:304-308`), which is how the
/// writer emits the actor, the commit message, and each other actor.
fn appendLengthPrefixed(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8) Allocator.Error!void {
    try leb128.appendUnsigned(out, gpa, bytes.len);
    try out.appendSlice(gpa, bytes);
}

const testing = std.testing;

// The body of the first chunk of `test/fixtures/two_change_chunks.automerge`:
// the 57 bytes after its 10-byte header. Copied in so this port's header
// reader is pinned to bytes automerge wrote, not to bytes this port wrote.
const two_change_chunks_body = [_]u8{
    0x00, 0x10, 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00,
    0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d, 0x01, 0x01, 0xc1, 0xbe, 0xc4, 0x83,
    0xe1, 0x30, 0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x31, 0x00,
    0x05, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x70, 0x02, 0x7f,
    0x01, 0x61, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x00,
};

// A body with one of every field shape, written out by hand: two
// dependencies, a three-byte actor, a two-byte sequence number, a three-byte
// start op, a negative timestamp, a message, and two other actors of
// different lengths. The tail stands in for the op columns and must survive
// untouched. Every byte is a literal, so a parser that reads the wrong field
// order fails here rather than agreeing with itself.

/// The dependency count and the two dependencies: 32 raw bytes each, with no
/// per-dependency length.
const built_deps = [_]u8{
    0x02, // 2 dependencies
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, // dep 0, bytes 0x00..0x1f
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, // dep 1, bytes 0xc0..0xdf
    0xc8, 0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf,
    0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7,
    0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf,
};

/// Every header field after the dependencies, as the writer emits it.
const built_header_tail = [_]u8{
    0x03, 0xaa, 0xbb, 0xcc, // actor
    0xac, 0x02, // seq = 300
    0x80, 0x80, 0x01, // start_op = 16384
    0x98, 0x78, // time = -1000
    0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x32, // message
    0x02, // 2 other actors
    0x01, 0x11, // first
    0x02, 0x22, 0x33, // second
};

/// The op columns, which this module must not touch.
const built_columns = [_]u8{ 0x05, 0x15, 0x03, 0x34 };

/// The header of `built_body`, as a literal, so the round trip is checked
/// against the bytes that were read and not against the writer.
const built_header = built_deps ++ built_header_tail;

const built_body = built_header ++ built_columns;

test "a hand-built header parses field by field" {
    const gpa = testing.allocator;
    // The literal header is the fixture: if this ever stops being true the
    // fixture and the expectations below have drifted apart.
    try testing.expectEqualSlices(u8, &built_header, built_body[0..built_header.len]);
    try testing.expectEqualSlices(u8, built_body[0..built_header.len], built_body[0..91]);

    var change = try parseChange(&built_body, gpa);
    defer change.deinit(gpa);

    try testing.expectEqual(built_header.len, change.header_len);
    try testing.expectEqual(@as(usize, 2), change.deps.len);
    // A dependency is 32 raw bytes: the first is 0x00..0x1f, the second
    // 0xc0..0xdf, and there is no per-dependency length.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 }, change.deps[0].bytes[0..8]);
    try testing.expectEqual(@as(u8, 0x1f), change.deps[0].bytes[31]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7 }, change.deps[1].bytes[0..8]);
    try testing.expectEqual(@as(u8, 0xdf), change.deps[1].bytes[31]);

    try testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb, 0xcc }, change.actor.bytes);
    try testing.expectEqual(@as(u64, 300), change.seq);
    try testing.expectEqual(@as(u64, 16384), change.start_op);
    try testing.expectEqual(@as(i64, -1000), change.time);
    try testing.expectEqualStrings("change 2", change.message);

    try testing.expectEqual(@as(usize, 2), change.other_actors.len);
    try testing.expectEqualSlices(u8, &[_]u8{0x11}, change.other_actors[0].bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0x33 }, change.other_actors[1].bytes);

    // The op columns are left exactly as they were.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x05, 0x15, 0x03, 0x34 }, change.opsBytes());
    // The op count is not in the header, so `max_op` stays 0 until the
    // columns are decoded.
    try testing.expectEqual(@as(u64, 0), change.max_op);
}

test "a parsed change re-encodes to the bytes it came from" {
    const gpa = testing.allocator;
    for ([_][]const u8{ &built_body, &two_change_chunks_body }) |body| {
        var change = try parseChange(body, gpa);
        defer change.deinit(gpa);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try change.encodeHeader(&out, gpa);

        // The header, written back from the fields, is the header that was
        // read.
        try testing.expectEqualSlices(u8, body[0..change.header_len], out.items);
        // And the whole body, header plus the columns left untouched.
        var whole: std.ArrayList(u8) = .empty;
        defer whole.deinit(gpa);
        try whole.appendSlice(gpa, out.items);
        try whole.appendSlice(gpa, change.opsBytes());
        try testing.expectEqualSlices(u8, body, whole.items);
    }
}

test "a change automerge wrote parses to the fields and hash it has" {
    const gpa = testing.allocator;
    var change = try parseChange(&two_change_chunks_body, gpa);
    defer change.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), change.deps.len);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00, 0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d },
        change.actor.bytes,
    );
    try testing.expectEqual(@as(u64, 1), change.seq);
    try testing.expectEqual(@as(u64, 1), change.start_op);
    try testing.expectEqual(@as(i64, 1675313094465), change.time);
    try testing.expectEqualStrings("change 1", change.message);
    try testing.expectEqual(@as(usize, 0), change.other_actors.len);
    // 1 + 17 + 1 + 1 + 6 + 9 + 1 bytes of header; the rest is the columns.
    try testing.expectEqual(@as(usize, 36), change.header_len);

    // The hash of the body framed as a change chunk. The expected value was
    // computed with an independent SHA-256 over `0x01 0x39 || body`, and the
    // first four of its bytes are the checksum the fixture's own chunk header
    // carries.
    const expected = try types.ChangeHash.parse(gpa, "9ac3d730f262da35e71db591b9e8150de9b02826daf75006f2298916adec6e0b");
    try testing.expectEqual(expected.bytes, change.hash.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x9a, 0xc3, 0xd7, 0x30 }, &change.hash.checksum());
    try testing.expect(change.hash.eql(chunk.changeHashOf(.change, &two_change_chunks_body)));
}

test "an encoded change is a chunk that reads back as the same body" {
    const gpa = testing.allocator;
    var change = try parseChange(&two_change_chunks_body, gpa);
    defer change.deinit(gpa);

    const encoded = try change.encode(gpa);
    defer gpa.free(encoded);

    // The framing is the standard one, and the body is the change's bytes.
    try testing.expectEqualSlices(u8, &chunk.magic, encoded[0..4]);
    try testing.expectEqual(@as(u8, 0x01), encoded[8]);
    try testing.expectEqual(@as(u8, two_change_chunks_body.len), encoded[9]);
    try testing.expectEqualSlices(u8, &two_change_chunks_body, encoded[10..]);

    const read_back = try chunk.parseChunk(encoded);
    try testing.expectEqual(chunk.ChunkType.change, read_back.typ);
    try testing.expectEqualSlices(u8, &two_change_chunks_body, read_back.data);
}

test "a header that runs off the end is refused at every prefix" {
    const gpa = testing.allocator;
    // Every truncation of a valid header is a ParseError. The parser must
    // never believe a length the rest of the input cannot back.
    for (0..built_header.len) |cut| {
        if (parseChange(built_body[0..cut], gpa)) |change| {
            var owned = change;
            owned.deinit(gpa);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "a zero start op is refused" {
    const gpa = testing.allocator;
    // The fixture with its start op zeroed. The byte is found by walking the
    // header the same way the parser does, not by hard-coding an offset.
    var bytes: [built_body.len]u8 = built_body;
    var in: Input = .init(&bytes);
    var dep_sink: DepSink = .{ .in = &in };
    try in.readCountThen(&dep_sink, hash_size, DepSink.collect);
    _ = try in.readStrBytes(); // actor
    _ = try in.takeUleb(); // seq
    const at = in.pos;
    bytes[at] = 0x00;

    try testing.expectError(error.InvalidLeb128, parseChange(&bytes, gpa));

    // The same body unaltered is fine, so the failure above is the zero and
    // not the edit.
    var good = try parseChange(&built_body, gpa);
    defer good.deinit(gpa);
    try testing.expectEqual(@as(u64, 16384), good.start_op);
}

test "a dependency count past the end of the input is refused" {
    const gpa = testing.allocator;
    // A ten-byte LEB128 claiming 2^64-1 dependencies, with one byte of input.
    const bytes = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x00 };
    try testing.expectError(error.LengthExceedsInput, parseChange(&bytes, gpa));

    // A count that is small but still larger than the input can hold: two
    // dependencies need 64 bytes and there are 40.
    var many: [41]u8 = @splat(0xaa);
    many[0] = 0x02;
    try testing.expectError(error.LengthExceedsInput, parseChange(many[0..41], gpa));
}

test "an other-actor count past the end of the input is refused" {
    const gpa = testing.allocator;
    // A header that is complete except that it claims 4 other actors and
    // carries none. The actor count is the last header field before the
    // columns.
    const none = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // empty message
        0x04, // 4 other actors, and no bytes for them
    };
    try testing.expectError(error.LengthExceedsInput, parseChange(&none, gpa));

    // One actor's bytes is still not four.
    const one = [_]u8{ 0x00, 0x01, 0x41, 0x01, 0x01, 0x00, 0x00, 0x04, 0x01, 0x42 };
    try testing.expectError(error.LengthExceedsInput, parseChange(&one, gpa));
}

test "a commit message that is not UTF-8 is refused" {
    const gpa = testing.allocator;
    const bytes = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x02, 0xff, 0xfe, // message, not UTF-8
        0x00, // 0 other actors
    };
    try testing.expectError(error.InvalidUtf8, parseChange(&bytes, gpa));

    // A lone continuation byte is the smallest such message.
    const lone = [_]u8{ 0x00, 0x01, 0x41, 0x01, 0x01, 0x00, 0x01, 0x80, 0x00 };
    try testing.expectError(error.InvalidUtf8, parseChange(&lone, gpa));
}

test "an empty message and an absent one are the same" {
    const gpa = testing.allocator;
    const bytes = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // empty message
        0x00, // 0 other actors
    };
    var change = try parseChange(&bytes, gpa);
    defer change.deinit(gpa);
    try testing.expectEqualStrings("", change.message);

    // Written back it is still a zero length, not a missing field.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try change.encodeHeader(&out, gpa);
    try testing.expectEqualSlices(u8, &bytes, out.items);
}

test "an other actor costs as little as one byte" {
    const gpa = testing.allocator;
    // The smallest an actor can be on the wire is a one-byte zero length, so
    // the bound the count is checked against is one byte per actor and not
    // two. A change carrying exactly one empty actor id is legal here and
    // must parse.
    const bytes = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // empty message
        0x01, // 1 other actor
        0x00, // of length zero
    };
    var change = try parseChange(&bytes, gpa);
    defer change.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), change.other_actors.len);
    try testing.expectEqualSlices(u8, "", change.other_actors[0].bytes);

    // A count of two with one byte left is refused, which is the same bound
    // seen from the other side.
    const short = [_]u8{
        0x00, 0x01, 0x41, 0x01, 0x01, 0x00, 0x00, 0x02, 0x00,
    };
    try testing.expectError(error.LengthExceedsInput, parseChange(&short, gpa));
}

test "hasDependency finds a dependency and misses anything else" {
    const gpa = testing.allocator;
    var change = try parseChange(&built_body, gpa);
    defer change.deinit(gpa);

    try testing.expect(change.hasDependency(change.deps[0]));
    try testing.expect(change.hasDependency(change.deps[1]));
    // A hash that differs from a dependency in its last byte, and one that
    // differs in its first, are both absent: a stride or length off by one
    // would turn one of them into a hit.
    var flipped_last: [hash_size]u8 = change.deps[0].bytes;
    flipped_last[hash_size - 1] = 0x00;
    try testing.expect(!change.hasDependency(.{ .bytes = flipped_last }));
    var flipped_first: [hash_size]u8 = change.deps[1].bytes;
    flipped_first[0] = 0x00;
    try testing.expect(!change.hasDependency(.{ .bytes = flipped_first }));
    try testing.expect(!change.hasDependency(ChangeHash.zero));
    // A change with no dependencies has none.
    var empty = try parseChange(&two_change_chunks_body, gpa);
    defer empty.deinit(gpa);
    try testing.expect(!empty.hasDependency(change.deps[0]));
}

test "withOpCount derives max_op and refuses a counter that does not fit" {
    const gpa = testing.allocator;
    var change = try parseChange(&built_body, gpa);
    defer change.deinit(gpa);

    const verified = try change.withOpCount(3);
    try testing.expectEqual(@as(u64, 16386), verified.max_op);
    try testing.expectEqual(@as(u64, 16384), verified.start_op);

    // A change with no ops ends just before it starts.
    const none = try change.withOpCount(0);
    try testing.expectEqual(@as(u64, 16383), none.max_op);

    // One op at `start_op` is the degenerate case.
    const one = try change.withOpCount(1);
    try testing.expectEqual(one.start_op, one.max_op);

    // Op counters are u32, so a start op past that is a change this port
    // cannot represent. Upstream refuses it when it verifies the ops.
    var huge = try parseChange(&[_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x80, 0x80, 0x80, 0x80, 0x10, // start_op = 2^32
        0x00, // time 0
        0x00, // empty message
        0x00, // 0 other actors
    }, gpa);
    defer huge.deinit(gpa);
    try testing.expectEqual(@as(u64, 1 << 32), huge.start_op);
    try testing.expectError(error.Overflow, huge.withOpCount(1));
}

test "change metadata copies the change and can own its bytes" {
    const gpa = testing.allocator;
    var change = try parseChange(&built_body, gpa);
    defer change.deinit(gpa);
    const verified = try change.withOpCount(2);

    const borrowed = ChangeMetadata.fromChange(verified);
    try testing.expectEqual(change.hash.bytes, borrowed.hash.bytes);
    try testing.expectEqual(@as(u64, 300), borrowed.seq);
    try testing.expectEqual(@as(u64, 16384), borrowed.start_op);
    try testing.expectEqual(@as(u64, 16385), borrowed.max_op);
    try testing.expectEqual(@as(i64, -1000), borrowed.time);
    try testing.expectEqualStrings("change 2", borrowed.message);
    try testing.expectEqual(@as(u32, 300), borrowed.clockEntry().?);
    try testing.expect(borrowed.hasDependency(change.deps[1]));
    try testing.expect(!borrowed.hasDependency(ChangeHash.zero));

    // The owned copy does not point into the change's bytes.
    var owned = try borrowed.intoOwned(gpa);
    defer owned.deinit(gpa);
    try testing.expectEqual(borrowed.hash.bytes, owned.hash.bytes);
    try testing.expectEqualStrings(borrowed.message, owned.message);
    try testing.expectEqualSlices(u8, borrowed.actor.bytes, owned.actor.bytes);
    try testing.expectEqual(borrowed.deps.len, owned.deps.len);
    try testing.expectEqualSlices(u8, &borrowed.deps[1].bytes, &owned.deps[1].bytes);
    try testing.expectEqual(borrowed.other_actors.len, owned.other_actors.len);
    try testing.expectEqualSlices(u8, borrowed.other_actors[1].bytes, owned.other_actors[1].bytes);
    // Every owned slice is a distinct allocation.
    try testing.expect(owned.message.ptr != borrowed.message.ptr);
    try testing.expect(owned.deps.ptr != borrowed.deps.ptr);

    // Freeing the change leaves the metadata standing.
    change.deinit(gpa);
    try testing.expectEqualStrings("change 2", owned.message);
    try testing.expectEqual(@as(u64, 300), owned.seq);
}

test "debugString names the change" {
    const gpa = testing.allocator;
    var change = try parseChange(&two_change_chunks_body, gpa);
    defer change.deinit(gpa);

    const text = try change.debugString(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings(
        "change 9ac3d730 by da0a5454424349848500a5ebe1acd94d seq 1 ops 1-0 at 1675313094465: change 1",
        text,
    );
}
