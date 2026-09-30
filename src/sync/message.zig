//! The sync message: the one record the sync protocol sends, in both
//! directions, at both versions.
//!
//! There is no message-kind enum at this commit. No `Sync`, `Ack`, `Nack`,
//! `Auth` or handshake message exists: the same five-field record carries
//! every message, a peer acknowledges by advertising the `heads` that descend
//! from what it received (`sync.rs:430-431`), and the version negotiation is
//! a side effect of the optional trailing flags section
//! (`sync.rs:657-663`, `sync.rs:404-411`). A message that means "reset",
//! "here is a change", "here are all the changes" and "here is the whole
//! document" is the same record with a different payload.
//!
//! ```text
//! offset  size        field
//! 0       1           0x42 V1, or 0x43 V2                       sync.rs:136-137
//! 1       uleb128     nHeads
//!         32 * nHeads heads[i], raw, ascending
//!         uleb128     nNeed
//!         32 * nNeed  need[i], raw, ascending
//!         uleb128     nHave                                    sync.rs:681-685
//!           uleb128     nLastSync
//!           32 * n      last_sync[i], raw, ascending
//!           uleb128     nBloomBytes
//!           nBloomBytes  bloom filter bytes, see sync/bloom.zig
//!         uleb128     nChunks                                  sync.rs:687-690
//!           uleb128     nChunkBytes
//!           nChunkBytes  raw bytes: a change chunk or a document
//!         --- present only if at least one byte remained ---------- sync.rs:657-663
//!           uleb128     nFlagBytes
//!           nFlagBytes    0x02, then 0x80 | bits
//! ```
//!
//! V1 and V2 are byte-identical from offset 1 to the end of the chunks
//! (`sync.rs:652-656`). The only structural difference is the flags section,
//! which V1 never emits. Which version a message *is* is decided by the
//! sender (`sync/message_builder.rs:18-24`) and the receiver discards the
//! version byte entirely (`sync.rs:395-402`), so this parser does not check
//! the version against the payload: a `0x43` message with one chunk per
//! change parses, and so does a `0x42` message carrying a document chunk.
//!
//! Every reader below is total over the bytes it is given. Upstream reports
//! all of them as one class, `ReadMessageError::NotEnoughInput`, because
//! `ParseError::Incomplete` collapses into it (`sync.rs:503-510`); the port
//! keeps the two classes `storage/parse.zig:23-28` already distinguishes, so
//! a declared length that is provably past the end is
//! `error.LengthExceedsInput` and a reader that simply runs out of bytes is
//! `error.UnexpectedEnd`. A first byte that is neither `0x42` nor `0x43` is
//! upstream's `ReadMessageError::WrongType` (`sync.rs:151-154`), spelled
//! `error.InvalidMagic` here: both mean the record's identification byte is
//! not one of ours. Trailing bytes after the flags section are ignored, as
//! upstream ignores them (`sync.rs:641-646`); the JavaScript reference says
//! why at `sync.mjs:206-207`.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const leb128 = @import("../leb128.zig");
const Input = @import("../storage/parse.zig").Input;
const bloom = @import("bloom.zig");
const state = @import("state.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const ChangeHash = types.ChangeHash;
const BloomFilter = bloom.BloomFilter;
const hash_size = types.hash_size;

/// A summary of what the sender already has, and an implicit request for
/// everything after it (`Have`, `sync/state.rs:81-90`).
///
/// The struct lives in `state.zig` with the rest of the per-peer state; it
/// is re-exported here because a message is where one appears. `last_sync` is
/// the heads at the sender's last successful sync and `bloom` covers
/// everything it has added since.
pub const Have = state.Have;

/// The first byte of a V1 sync message, for identification (`sync.rs:136`).
pub const message_type_sync: u8 = 0x42;

/// The first byte of a V2 sync message, for identification (`sync.rs:137`).
///
/// This is the same value as `state.sync_state_type` (`sync/state.rs:9`).
/// The two constants are independent facts about two different records and
/// neither is derived from the other; the fact that they coincide is what
/// makes a V2 sync message and a sync *state* distinguishable by context
/// alone.
pub const message_type_sync_v2: u8 = 0x43;

/// Which message format to write (`MessageVersion`, `sync.rs:140-164`).
///
/// The variant is only the type byte: `V1` writes `0x42` and `V2` writes
/// `0x43` (`sync.rs:158-164`), and a receiver learns nothing else from it.
pub const MessageVersion = enum {
    /// The original format: one length-prefixed chunk per change.
    v1,
    /// The extension: one chunk, holding every change concatenated or a
    /// whole saved document (`sync/message_builder.rs:43-78`).
    v2,

    /// The type byte this version writes (`sync.rs:158-164`).
    pub fn encode(self: MessageVersion) u8 {
        return switch (self) {
            .v1 => message_type_sync,
            .v2 => message_type_sync_v2,
        };
    }
};

/// What a peer has said it supports, derived from the flags sections it has
/// sent (`Capability`, `sync.rs:800-806`).
///
/// This is not read off the wire: it is computed from the presence of a
/// flags section and one bit inside it (`sync.rs:404-411`). A peer that has
/// never sent a flags section has *no* capability list at all, which is what
/// makes it a v1-only peer (`sync/state.rs:208-212`).
pub const Capability = enum {
    /// The peer reads the original format. Nothing in this port constructs
    /// it: a peer that has not advertised v2 has no capabilities rather than
    /// a list containing this (`sync.rs:895,897,921,923` are the only
    /// upstream constructions and they are in commented-out proptests).
    message_v1,
    /// The peer reads a V2 message. Every peer that has sent a flags section
    /// at all has this (`sync.rs:407`).
    message_v2,
    /// The peer understands `MessageFlags.sync_reset` and will clear its
    /// `sent_hashes` when it sees one (`sync.rs:409-410`, read at
    /// `sync/state.rs:191-196`).
    sync_reset,
};

/// Per-message flags, as a bitfield byte inside the trailing section
/// (`MessageFlags`, `sync.rs:742-796`).
///
/// The section is encoded backwards-compatibly: a length prefix, then the
/// one byte the pre-bitfield format used to send, then a byte with the high
/// bit set carrying every flag (`sync.rs:776-781`). A reader that predates
/// the bitfield sees a length, `0x02`, and then unknown bytes it ignores;
/// this parser reads every byte whose high bit is set and ORs its low seven
/// bits into the set (`sync.rs:783-795`).
pub const MessageFlags = struct {
    /// The bitfield, without the marker bit.
    bits: u8,

    /// Tell the peer to clear its `sent_hashes` and start a fresh exchange
    /// (`sync.rs:752-754`). Set when this side has just left read-only mode.
    pub const sync_reset: u8 = 1 << 0;
    /// The sender is read-only and will not apply incoming changes
    /// (`sync.rs:755-757`).
    pub const read_only: u8 = 1 << 1;
    /// The sender understands `sync_reset` (`sync.rs:758-759`).
    pub const supports_sync_reset: u8 = 1 << 2;

    /// Set on the byte that carries the flags themselves, so that a reader
    /// which does not know about bitfields ignores the whole byte
    /// (`sync.rs:760`).
    const bitfield_marker: u8 = 0x80;
    /// The byte the pre-bitfield format used for "I read V2 messages", still
    /// emitted and still ignored on the way in (`sync.rs:762`).
    const legacy_v2_byte: u8 = 0x02;
    /// Two entries: the legacy byte and the bitfield byte (`sync.rs:778`).
    const encoded_len: u64 = 2;

    /// The empty set, which is what `MessageFlags::new()` returns
    /// (`sync.rs:764-766`).
    pub fn none() MessageFlags {
        return .{ .bits = 0 };
    }

    /// Whether every bit of `flag` is set (`sync.rs:768-770`).
    pub fn contains(self: MessageFlags, flag: u8) bool {
        return self.bits & flag != 0;
    }

    /// Sets every bit of `flag` (`sync.rs:772-774`).
    pub fn set(self: *MessageFlags, flag: u8) void {
        self.bits |= flag;
    }

    /// Appends the length prefix and both bytes (`sync.rs:776-781`).
    pub fn write(self: MessageFlags, out: *std.ArrayList(u8), gpa: Allocator) !void {
        try leb128.appendUnsigned(out, gpa, encoded_len);
        try out.append(gpa, legacy_v2_byte);
        try out.append(gpa, bitfield_marker | self.bits);
    }

    /// The flags a peer sent, from the section's bytes (`sync.rs:783-795`).
    ///
    /// Every byte with the marker bit set contributes its other seven bits.
    /// A byte without it is ignored, which is what the legacy bytes `0x01`
    /// and `0x02` are for; unknown bits are kept, so a flag this port does
    /// not know survives a decode/encode round trip.
    pub fn parseBytes(bytes: []const u8) MessageFlags {
        var flags = MessageFlags.none();
        for (bytes) |byte| {
            if (byte & bitfield_marker != 0) flags.bits |= byte & ~bitfield_marker;
        }
        return flags;
    }
};

/// The changes, or the document, a message carries
/// (`ChunkList`, `sync.rs:551-601`).
///
/// The elements are opaque bytes. A V1 message puts one change chunk in
/// each; a V2 message puts one element holding every change concatenated,
/// or a whole `save()` (`sync/message_builder.rs:43-78`). `join` reassembles
/// them into the single stream a document's `load_incremental` takes
/// (`sync.rs:590-599`), and nothing in this file interprets them.
pub const ChunkList = struct {
    /// The element payloads, owned.
    items: [][]u8,
    gpa: Allocator,

    /// A list with no elements (`ChunkList::empty`, `sync.rs:572-574`).
    pub fn empty(gpa: Allocator) ChunkList {
        return .{ .items = &.{}, .gpa = gpa };
    }

    /// Frees every element and the list itself (`sync.rs:551-553`).
    pub fn deinit(self: *ChunkList) void {
        for (self.items) |item| self.gpa.free(item);
        self.gpa.free(self.items);
        self.* = undefined;
    }

    /// Whether there is no payload at all (`sync.rs:576-578`).
    pub fn isEmpty(self: ChunkList) bool {
        return self.items.len == 0;
    }

    /// How many elements there are (`sync.rs:580-582`).
    pub fn len(self: ChunkList) usize {
        return self.items.len;
    }

    /// The payloads in order (`sync.rs:584-586`).
    pub fn iter(self: ChunkList) []const []const u8 {
        return self.items;
    }

    /// Every payload concatenated, in order (`sync.rs:590-599`).
    ///
    /// The caller owns the result. An empty list joins to zero bytes rather
    /// than to a null, because the whole point of the concatenation is that
    /// the result goes into one loader call.
    pub fn join(self: ChunkList, gpa: Allocator) ![]u8 {
        var total: usize = 0;
        for (self.items) |item| total += item.len;
        const out = try gpa.alloc(u8, total);
        errdefer gpa.free(out);
        var at: usize = 0;
        for (self.items) |item| {
            @memcpy(out[at..][0..item.len], item);
            at += item.len;
        }
        return out;
    }

    /// A count, then that many length-prefixed payloads (`sync.rs:565-570`).
    fn parse(gpa: Allocator, in: *Input) ParseError!ChunkList {
        var items: std.ArrayList([]u8) = .empty;
        errdefer {
            for (items.items) |item| gpa.free(item);
            items.deinit(gpa);
        }
        try in.readCountThen(ChunkSink{ .in = in, .gpa = gpa, .out = &items }, 1, ChunkSink.collect);
        return .{ .items = try items.toOwnedSlice(gpa), .gpa = gpa };
    }
};

/// A sync message (`Message`, `sync.rs:529-547`).
///
/// Every field is owned by the message and `deinit` frees all of it. The
/// receive path does not deinit the message it consumes: it *moves* `heads`,
/// `need` and `have` into the peer's `State` (`sync.rs:459-461`), so a
/// caller that hands a message to a `State` must clear those three fields
/// first or not free the message at all. `changes` is the exception: it is
/// read, joined, and then freed with the message.
pub const Message = struct {
    gpa: Allocator,
    /// The sender's heads, ascending. This is also the acknowledgement: a
    /// receiver prunes its `sent_hashes` by them (`sync.rs:430-431`).
    heads: []ChangeHash,
    /// Changes the sender is explicitly asking for (`sync.rs:533`).
    need: []ChangeHash,
    /// What the sender says it has (`sync.rs:535`).
    have: []Have,
    /// The payload for the recipient to apply (`sync.rs:542`).
    changes: ChunkList,
    /// The trailing flags section, absent when the peer sent none
    /// (`sync.rs:544`, `sync.rs:657-663`).
    flags: ?MessageFlags,
    /// The type byte to write (`sync.rs:546`).
    version: MessageVersion,

    /// The message with nothing in it, no flags, and a V1 type byte: the
    /// starting point every generated message is built from
    /// (`sync.rs:279-287`) and the shape `Message::reset` fills in
    /// (`sync.rs:625-638`).
    pub fn init(gpa: Allocator) Message {
        return .{
            .gpa = gpa,
            .heads = &.{},
            .need = &.{},
            .have = &.{},
            .changes = .empty(gpa),
            .flags = null,
            .version = .v1,
        };
    }

    /// Frees the three lists, every `have` in the list, and the chunk list
    /// (`sync.rs:529-547`). See the note on the type: a message consumed by
    /// the receive path has already given three of these away.
    pub fn deinit(self: *Message) void {
        self.gpa.free(self.heads);
        self.gpa.free(self.need);
        for (self.have) |*entry| entry.deinit();
        self.gpa.free(self.have);
        self.changes.deinit();
        self.* = undefined;
    }

    /// The message that tells a peer to start again: our heads, nothing we
    /// need, one empty `have`, no payload, and `SUPPORTS_SYNC_RESET`
    /// (`Message::reset`, `sync.rs:625-638`).
    ///
    /// It is always V1 (`sync.rs:636`): a reset asks the peer to forget what
    /// it thinks it has sent, and that is a request about *their* bookkeeping
    /// rather than a payload, so there is nothing for V2 to pack differently.
    pub fn reset(gpa: Allocator, our_heads: []const ChangeHash) !Message {
        var heads: std.ArrayList(ChangeHash) = .empty;
        errdefer heads.deinit(gpa);
        try appendHashes(gpa, &heads, our_heads);

        var have: std.ArrayList(Have) = .empty;
        errdefer {
            for (have.items) |*entry| entry.deinit();
            have.deinit(gpa);
        }
        try have.append(gpa, .empty(gpa));

        var flags = MessageFlags.none();
        flags.set(MessageFlags.supports_sync_reset);

        const owned_heads = try heads.toOwnedSlice(gpa);
        errdefer gpa.free(owned_heads);

        return .{
            .gpa = gpa,
            .heads = owned_heads,
            .need = &.{},
            .have = try have.toOwnedSlice(gpa),
            .changes = .empty(gpa),
            .flags = flags,
            .version = .v1,
        };
    }

    /// Reads a message from `bytes`, ignoring anything after the flags
    /// section (`Message::decode`, `sync.rs:640-647`).
    ///
    /// `bytes` is whatever arrived on the transport. Nothing about it is
    /// trusted beyond the four elements of `ParseError` this file uses:
    /// `error.InvalidMagic` for a type byte that is not ours,
    /// `error.LengthExceedsInput` for a declared count or length the rest of
    /// the input cannot hold, and `error.UnexpectedEnd` for a reader that
    /// runs out of bytes.
    pub fn decode(gpa: Allocator, bytes: []const u8) ParseError!Message {
        var in: Input = .init(bytes);
        return parse(gpa, &in);
    }

    /// Reads a message, advancing `in` past the flags section
    /// (`Message::parse`, `sync.rs:649-674`).
    ///
    /// Whatever follows the flags section is left on the cursor, which is how
    /// a caller that framed the message inside a larger stream can find the
    /// end of it. The flags section itself is read only when at least one
    /// byte remains (`sync.rs:657-663`).
    pub fn parse(gpa: Allocator, in: *Input) ParseError!Message {
        const version: MessageVersion = switch (try in.takeByte()) {
            message_type_sync => .v1,
            message_type_sync_v2 => .v2,
            // `sync.rs:151-154` reports the two bytes it expected along with
            // the one it found; the set is a constant, so only the value is
            // carried.
            else => return error.InvalidMagic,
        };

        var heads: std.ArrayList(ChangeHash) = .empty;
        errdefer heads.deinit(gpa);
        try readHashes(in, gpa, &heads);

        var need: std.ArrayList(ChangeHash) = .empty;
        errdefer need.deinit(gpa);
        try readHashes(in, gpa, &need);

        var have: std.ArrayList(Have) = .empty;
        errdefer {
            for (have.items) |*entry| entry.deinit();
            have.deinit(gpa);
        }
        try in.readCountThen(HaveSink{ .in = in, .gpa = gpa, .out = &have }, 1, HaveSink.collect);

        var changes = try ChunkList.parse(gpa, in);
        errdefer changes.deinit();

        const flags: ?MessageFlags = if (in.isEmpty())
            null
        else
            MessageFlags.parseBytes(try takeLengthPrefixedBytes(in));

        // The three lists are handed over one at a time, each with a guard
        // for the next, so a message that runs out of memory half way
        // through building frees what it already took.
        const owned_heads = try heads.toOwnedSlice(gpa);
        errdefer gpa.free(owned_heads);
        const owned_need = try need.toOwnedSlice(gpa);
        errdefer gpa.free(owned_need);
        const owned_have = try have.toOwnedSlice(gpa);
        errdefer {
            for (owned_have) |*entry| entry.deinit();
            gpa.free(owned_have);
        }

        return .{
            .gpa = gpa,
            .heads = owned_heads,
            .need = owned_need,
            .have = owned_have,
            .changes = changes,
            .flags = flags,
            .version = version,
        };
    }

    /// The message's bytes (`Message::encode`, `sync.rs:676-698`).
    ///
    /// `heads`, `need` and every `last_sync` must be ascending: upstream
    /// asserts it (`sync.rs:819-824`) because the receiver prunes by walking
    /// them as an ordered set. A caller that does not sort gets a panic in a
    /// safe build and a message no peer can use in a release build, which is
    /// the same trade upstream makes.
    pub fn encode(self: Message, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try out.append(gpa, self.version.encode());
        try encodeHashes(&out, gpa, self.heads);
        try encodeHashes(&out, gpa, self.need);
        try encodeMany(Encoder{ .out = &out, .gpa = gpa }, self.have, Encoder.writeHave);
        try encodeMany(Encoder{ .out = &out, .gpa = gpa }, self.changes.items, Encoder.writeChunk);
        if (self.flags) |flags| try flags.write(&out, gpa);

        return out.toOwnedSlice(gpa);
    }
};

/// The shared `uleb128`-counted hash list, used by a message's `heads`,
/// `need` and every `have`'s `last_sync`, and by a persisted sync state
/// (`encode_hashes`, `sync.rs:819-825`).
///
/// Ascending order is the invariant, not a detail: it is what the receiver's
/// `filter_changes` and `advance_heads` assume (`sync.rs:827-850`).
pub fn encodeHashes(out: *std.ArrayList(u8), gpa: Allocator, hashes: []const ChangeHash) !void {
    for (hashes, 0..) |hash, index| {
        if (index > 0) std.debug.assert(ChangeHash.order(hashes[index - 1], hash) != .gt);
    }
    try leb128.appendUnsigned(out, gpa, hashes.len);
    for (hashes) |hash| try out.appendSlice(gpa, &hash.bytes);
}

/// The new shared heads after applying changes: everything we gained, plus
/// the old shared heads we still have (`advance_heads`, `sync.rs:827-850`).
///
/// `my_old_heads` is our head set before the changes were applied,
/// `my_new_heads` after, and `our_old_shared_heads` is what both peers
/// agreed on last time. The caller owns the result.
pub fn advanceHeads(
    gpa: Allocator,
    my_old_heads: []const ChangeHash,
    my_new_heads: []const ChangeHash,
    our_old_shared_heads: []const ChangeHash,
) ![]ChangeHash {
    var advanced: std.ArrayList(ChangeHash) = .empty;
    errdefer advanced.deinit(gpa);
    for (my_new_heads) |head| {
        if (!containsHash(my_old_heads, head)) try advanced.append(gpa, head);
    }
    for (our_old_shared_heads) |head| {
        if (containsHash(my_new_heads, head) and !containsHash(advanced.items, head)) {
            try advanced.append(gpa, head);
        }
    }
    // Upstream collects into a `HashSet` and sorts it (`sync.rs:843-849`);
    // sorting and dropping the adjacent duplicates is the same set.
    std.mem.sort(ChangeHash, advanced.items, {}, ChangeHash.lessThan);
    var kept: usize = 0;
    for (advanced.items) |head| {
        if (kept == 0 or !ChangeHash.eql(advanced.items[kept - 1], head)) {
            advanced.items[kept] = head;
            kept += 1;
        }
    }
    advanced.shrinkRetainingCapacity(kept);
    return advanced.toOwnedSlice(gpa);
}

fn containsHash(hashes: []const ChangeHash, needle: ChangeHash) bool {
    for (hashes) |hash| {
        if (ChangeHash.eql(hash, needle)) return true;
    }
    return false;
}

// --- reading ---------------------------------------------------------------

/// One `have`: a `last_sync` list and a length-prefixed bloom
/// (`parse_have`, `sync.rs:617-622`).
///
/// The bloom is read from the bytes the field delimited, not from the
/// enclosing cursor, because upstream throws away the cursor it gets back
/// (`sync.rs:619`): the field length is the authority, and bytes after the
/// bit array inside it are the future's business.
fn readHave(in: *Input, gpa: Allocator) ParseError!Have {
    var last_sync: std.ArrayList(ChangeHash) = .empty;
    errdefer last_sync.deinit(gpa);
    try readHashes(in, gpa, &last_sync);

    const bloom_bytes = try takeLengthPrefixedBytes(in);
    // The filter is parsed before the hash list is handed over, and freed if
    // that hand-over cannot allocate, so neither step strands the other.
    var filter = try BloomFilter.parse(gpa, bloom_bytes);
    errdefer filter.deinit();
    return .{
        .gpa = gpa,
        .last_sync = try last_sync.toOwnedSlice(gpa),
        .bloom = filter,
    };
}

/// The cursor for a `readCountThen` over hashes: a count, then that
/// many fixed 32-byte hashes (`parse::length_prefixed(parse::change_hash)`,
/// `parse.rs:423-447` and `parse.rs:515-519`).
const HashSink = struct {
    in: *Input,
    gpa: Allocator,
    out: *std.ArrayList(ChangeHash),

    fn collect(self: HashSink, count: usize) ParseError!void {
        try self.out.ensureUnusedCapacity(self.gpa, count);
        for (0..count) |_| self.out.appendAssumeCapacity(.{ .bytes = try self.in.takeArray(ChangeHash) });
    }
};

const HaveSink = struct {
    in: *Input,
    gpa: Allocator,
    out: *std.ArrayList(Have),

    fn collect(self: HaveSink, count: usize) ParseError!void {
        try self.out.ensureUnusedCapacity(self.gpa, count);
        for (0..count) |_| self.out.appendAssumeCapacity(try readHave(self.in, self.gpa));
    }
};

const ChunkSink = struct {
    in: *Input,
    gpa: Allocator,
    out: *std.ArrayList([]u8),

    fn collect(self: ChunkSink, count: usize) ParseError!void {
        try self.out.ensureUnusedCapacity(self.gpa, count);
        for (0..count) |_| {
            const raw = try takeLengthPrefixedBytes(self.in);
            self.out.appendAssumeCapacity(try self.gpa.dupe(u8, raw));
        }
    }
};

fn readHashes(in: *Input, gpa: Allocator, out: *std.ArrayList(ChangeHash)) ParseError!void {
    // A hash is 32 raw bytes and is never length-prefixed
    // (`parse.rs:515-519`), so the count is bounded by the input before
    // anything is reserved for it.
    try in.readCountThen(HashSink{ .in = in, .gpa = gpa, .out = out }, hash_size, HashSink.collect);
}

/// A `uleb128` byte count and that many bytes
/// (`parse::length_prefixed_bytes`, `parse.rs:453-458`).
///
/// The declared length is proved against what is left before it is used, so
/// a length of four exabytes costs one comparison
/// (`storage/parse.zig:242-249`).
fn takeLengthPrefixedBytes(in: *Input) ParseError![]const u8 {
    const prefix = try leb128.readUnsigned(in.rest());
    // The payload starts after the prefix, so the bound is what remains once
    // the prefix is taken off.
    if (prefix.value > @as(u64, in.remaining() - prefix.len)) return error.LengthExceedsInput;
    in.pos += prefix.len;
    return in.take(@intCast(prefix.value));
}

// --- writing ---------------------------------------------------------------

/// The `uleb128` element count that opens every repeated field, followed by
/// one encoded element each (`encode_many`, `sync.rs:808-817`).
fn encodeMany(
    ctx: anytype,
    items: anytype,
    comptime f: fn (@TypeOf(ctx), @TypeOf(items[0])) Allocator.Error!void,
) Allocator.Error!void {
    try leb128.appendUnsigned(ctx.out, ctx.gpa, items.len);
    for (items) |item| try f(ctx, item);
}

/// The destination and allocator every encoder needs.
const Encoder = struct {
    out: *std.ArrayList(u8),
    gpa: Allocator,

    /// A `last_sync` list and a length-prefixed bloom (`sync.rs:681-685`).
    fn writeHave(self: Encoder, entry: Have) !void {
        try encodeHashes(self.out, self.gpa, entry.last_sync);
        try leb128.appendUnsigned(self.out, self.gpa, entry.bloom.byteLen());
        try entry.bloom.writeBytes(self.out, self.gpa);
    }

    /// A length prefix and the raw payload (`sync.rs:687-690`).
    fn writeChunk(self: Encoder, chunk: []const u8) !void {
        try leb128.appendUnsigned(self.out, self.gpa, chunk.len);
        try self.out.appendSlice(self.gpa, chunk);
    }
};

/// Appends `hashes` to a list, the allocation `encodeHashes` does not do.
fn appendHashes(gpa: Allocator, out: *std.ArrayList(ChangeHash), hashes: []const ChangeHash) !void {
    try out.ensureUnusedCapacity(gpa, hashes.len);
    for (hashes) |hash| out.appendAssumeCapacity(hash);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const io = testing.io;

/// The corpus the wire format is checked against, relative to the process
/// working directory. A unit test binary inherits the directory it was
/// started in, which is the package root under `zig build test` and this
/// file's own directory under a direct `zig test`, so the path is probed
/// rather than assumed.
const golden_paths = [_][]const u8{
    "test/golden/sync.jsonl",
    "../test/golden/sync.jsonl",
    "../../test/golden/sync.jsonl",
};

/// One line of `test/golden/sync.jsonl`, as written by
/// `tools/oracle/src/main.rs:227-290`. The two `sync-final` records are saved
/// documents, not sync messages, and carry `side` instead of the round and
/// direction.
const Record = struct {
    bytes: ?u64 = null,
    from: ?[]const u8 = null,
    hex: []const u8,
    kind: []const u8,
    round: ?u64 = null,
    sent: bool = false,
    side: ?[]const u8 = null,
    to: ?[]const u8 = null,
};

/// The two change hashes the oracle's exchange produces. Every hash in every
/// `sync` record is one of them.
const head_left = "2c91769152d8390db87c3db1b489b0d8d754aa81555edc60f41349595293e572";
const head_right = "ce5e79e9f00e45efc8c49afa7276b22193fa61d3c9018772353c659db5b220ac";

/// Reads the golden corpus, or returns `error.GoldenVectorsNotFound` naming
/// the paths that were tried.
fn readGolden(gpa: Allocator) ![]u8 {
    for (golden_paths) |path| {
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
    }
    std.debug.print("sync.jsonl not found; tried", .{});
    for (golden_paths) |path| std.debug.print(" {s}", .{path});
    std.debug.print("\n", .{});
    return error.GoldenVectorsNotFound;
}

fn hashHex(hash: ChangeHash) [64]u8 {
    var out: [64]u8 = undefined;
    err.hexInto(&hash.bytes, &out);
    return out;
}

test "the empty message is five bytes and round trips" {
    const gpa = testing.allocator;
    // `encode_decode_empty_message` (`sync.rs:944-958`): the smallest legal
    // message, a V2 record with no flags section.
    const bytes = [_]u8{ message_type_sync_v2, 0, 0, 0, 0 };

    var msg = try Message.decode(gpa, &bytes);
    defer msg.deinit();
    try testing.expectEqual(MessageVersion.v2, msg.version);
    try testing.expectEqual(@as(usize, 0), msg.heads.len);
    try testing.expectEqual(@as(usize, 0), msg.need.len);
    try testing.expectEqual(@as(usize, 0), msg.have.len);
    try testing.expect(msg.changes.isEmpty());
    try testing.expectEqual(@as(?MessageFlags, null), msg.flags);

    const again = try msg.encode(gpa);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, &bytes, again);
}

test "the reset message is V1 and advertises sync reset" {
    const gpa = testing.allocator;
    const heads = try gpa.dupe(ChangeHash, &.{try ChangeHash.parse(gpa, head_left)});
    defer gpa.free(heads);

    var msg = try Message.reset(gpa, heads);
    defer msg.deinit();

    try testing.expectEqual(MessageVersion.v1, msg.version);
    try testing.expectEqual(@as(usize, 1), msg.heads.len);
    try testing.expectEqual(@as(usize, 0), msg.need.len);
    try testing.expectEqual(@as(usize, 1), msg.have.len);
    try testing.expectEqual(@as(usize, 0), msg.have[0].last_sync.len);
    try testing.expectEqual(@as(u32, 0), msg.have[0].bloom.num_entries);
    try testing.expect(msg.changes.isEmpty());
    const flags = msg.flags.?;
    try testing.expect(flags.contains(MessageFlags.supports_sync_reset));
    try testing.expect(!flags.contains(MessageFlags.read_only));
    try testing.expect(!flags.contains(MessageFlags.sync_reset));

    // 0x42, one head, no need, one empty have, no chunks, then `02 02 84`.
    const bytes = try msg.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 1 + 1 + 32 + 1 + 3 + 1 + 3), bytes.len);
    try testing.expectEqualSlices(u8, &[_]u8{ message_type_sync, 0x01 }, bytes[0..2]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00 }, bytes[34..39]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x02, 0x84 }, bytes[39..42]);
}

test "the flags section encodes two bytes and reads every marked one" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var none = MessageFlags.none();
    try none.write(&out, gpa);
    // The empty set still writes the legacy byte and a marked empty bitfield.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x02, 0x80 }, out.items);
    out.clearRetainingCapacity();

    var both: MessageFlags = .none();
    both.set(MessageFlags.read_only);
    both.set(MessageFlags.supports_sync_reset);
    try both.write(&out, gpa);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x02, 0x86 }, out.items);
    out.clearRetainingCapacity();

    var reset: MessageFlags = .none();
    reset.set(MessageFlags.sync_reset);
    reset.set(MessageFlags.supports_sync_reset);
    try reset.write(&out, gpa);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x02, 0x85 }, out.items);

    // The decoder takes the low seven bits of every byte with the high bit
    // set and ignores the rest (`sync.rs:783-795`).
    const read = MessageFlags.parseBytes(&[_]u8{ 0x01, 0x02, 0x80, 0x86 });
    try testing.expectEqual(@as(u8, 0x06), read.bits);
    try testing.expect(read.contains(MessageFlags.read_only));
    try testing.expect(read.contains(MessageFlags.supports_sync_reset));
    try testing.expect(!read.contains(MessageFlags.sync_reset));
    // A bit this port does not know survives, so a peer that sends a flag
    // added after this port was written still gets it back.
    try testing.expectEqual(@as(u8, 0x0a), MessageFlags.parseBytes(&[_]u8{0x8a}).bits);
    // A section of only legacy bytes carries no flags at all, which is what
    // makes an old peer's section a "no capabilities" section.
    try testing.expectEqual(@as(u8, 0), MessageFlags.parseBytes(&[_]u8{ 0x01, 0x02 }).bits);
}

test "golden sync messages decode to the fields they carry and re-encode" {
    const gpa = testing.allocator;
    const text = try readGolden(gpa);
    defer gpa.free(text);

    var sync_records: usize = 0;
    var messages: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Record, gpa, line, .{});
        defer parsed.deinit();
        const record = parsed.value;
        if (!std.mem.eql(u8, record.kind, "sync")) continue;
        sync_records += 1;

        const bytes = try err.hexFrom(gpa, record.hex);
        defer gpa.free(bytes);
        try testing.expectEqual(record.bytes.?, bytes.len);

        if (!record.sent) {
            // The eleven records from round 3 rightwards carry no message:
            // the generator returned nothing. Decoding their empty payload
            // must fail rather than invent a message (`sync.rs:240-249`).
            try testing.expectEqual(@as(usize, 0), bytes.len);
            try testing.expectError(error.UnexpectedEnd, Message.decode(gpa, bytes));
            continue;
        }
        messages += 1;

        var msg = try Message.decode(gpa, bytes);
        defer msg.deinit();
        const again = try msg.encode(gpa);
        defer gpa.free(again);
        try testing.expectEqualSlices(u8, bytes, again);
    }

    try testing.expectEqual(@as(usize, 16), sync_records);
    try testing.expectEqual(@as(usize, 5), messages);
}

test "each golden sync message carries the fields the oracle recorded" {
    const gpa = testing.allocator;
    const text = try readGolden(gpa);
    defer gpa.free(text);

    // What an independent walk of the hex says each of the five messages
    // holds. The two hashes, the two bloom payloads and the two chunk lengths
    // are all recorded, because a round trip alone would pass for a decoder
    // that reads the same wrong field twice.
    const Expected = struct {
        type_byte: u8,
        heads: []const []const u8,
        need: []const []const u8,
        last_sync: []const []const u8,
        bloom_hex: []const u8,
        chunk_lens: []const usize,
    };
    const expected = [_]Expected{
        // Round 1, left to right: a V1 message, because the peer has not
        // advertised anything yet, that already carries a flags section.
        .{
            .type_byte = message_type_sync,
            .heads = &.{head_left},
            .need = &.{},
            .last_sync = &.{},
            .bloom_hex = "020a07d70155",
            .chunk_lens = &.{},
        },
        // Round 1, right to left: the reply is V2, because the first message
        // carried a flags section.
        .{
            .type_byte = message_type_sync_v2,
            .heads = &.{head_right},
            .need = &.{head_left},
            .last_sync = &.{},
            .bloom_hex = "020a07c20045",
            .chunk_lens = &.{},
        },
        // Round 2, left to right: one 347-byte document chunk, the
        // "more than a third of the graph" path.
        .{
            .type_byte = message_type_sync_v2,
            .heads = &.{head_left},
            .need = &.{head_right},
            .last_sync = &.{},
            .bloom_hex = "020a07d70155",
            .chunk_lens = &.{347},
        },
        // Round 2, right to left: a non-empty `last_sync` and a one-entry
        // bloom, then a 104-byte document chunk.
        .{
            .type_byte = message_type_sync_v2,
            .heads = &.{ head_left, head_right },
            .need = &.{},
            .last_sync = &[_][]const u8{head_left},
            .bloom_hex = "010a074040",
            .chunk_lens = &.{104},
        },
        // Round 3, left to right: both heads in `last_sync`, and an *empty*
        // bloom, which is zero bytes on the wire.
        .{
            .type_byte = message_type_sync_v2,
            .heads = &.{ head_left, head_right },
            .need = &.{},
            .last_sync = &[_][]const u8{ head_left, head_right },
            .bloom_hex = "",
            .chunk_lens = &.{},
        },
    };

    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Record, gpa, line, .{});
        defer parsed.deinit();
        const record = parsed.value;
        if (!std.mem.eql(u8, record.kind, "sync") or !record.sent) continue;

        const want = expected[seen];
        seen += 1;

        const bytes = try err.hexFrom(gpa, record.hex);
        defer gpa.free(bytes);
        var msg = try Message.decode(gpa, bytes);
        defer msg.deinit();

        const type_byte: u8 = if (msg.version == .v1) message_type_sync else message_type_sync_v2;
        try testing.expectEqual(want.type_byte, type_byte);

        try expectHashes(want.heads, msg.heads);
        try expectHashes(want.need, msg.need);
        try testing.expectEqual(@as(usize, 1), msg.have.len);
        try expectHashes(want.last_sync, msg.have[0].last_sync);

        const bloom_bytes = try msg.have[0].bloom.toBytes(gpa);
        defer gpa.free(bloom_bytes);
        const want_bloom = try err.hexFrom(gpa, want.bloom_hex);
        defer gpa.free(want_bloom);
        try testing.expectEqualSlices(u8, want_bloom, bloom_bytes);

        try testing.expectEqual(want.chunk_lens.len, msg.changes.len());
        for (want.chunk_lens, msg.changes.iter()) |want_len, chunk| {
            try testing.expectEqual(want_len, chunk.len);
        }
        // The payload chunks are the document the oracle saved, which starts
        // with the automerge chunk magic (`storage.rs:26`).
        for (msg.changes.iter()) |chunk| {
            try testing.expectEqualSlices(u8, &[_]u8{ 0x85, 0x6f, 0x4a, 0x83 }, chunk[0..4]);
        }

        // Every generated message advertises sync-reset support and nothing
        // else (`sync.rs:255-259`).
        const flags = msg.flags.?;
        try testing.expect(flags.contains(MessageFlags.supports_sync_reset));
        try testing.expect(!flags.contains(MessageFlags.read_only));
        try testing.expect(!flags.contains(MessageFlags.sync_reset));
    }
    try testing.expectEqual(@as(usize, 5), seen);
}

test "V1 and V2 differ only in the type byte, and a bad body is refused under both" {
    const gpa = testing.allocator;
    const text = try readGolden(gpa);
    defer gpa.free(text);

    // The first message the oracle exchanged: a V1 record whose body is one
    // head, no need, one empty `have` and a flags section.
    const hex = "42012c91769152d8390db87c3db1b489b0d8d754aa81555edc60f41349595293e57200010006020a07d7015500020284";
    var v1_bytes = try err.hexFrom(gpa, hex);
    defer gpa.free(v1_bytes);
    try testing.expect(v1_bytes.len == 48);

    var v1 = try Message.decode(gpa, v1_bytes);
    defer v1.deinit();
    try testing.expectEqual(MessageVersion.v1, v1.version);

    // The same body with the type byte swapped parses to the same fields.
    var v2_bytes = try gpa.dupe(u8, v1_bytes);
    defer gpa.free(v2_bytes);
    v2_bytes[0] = message_type_sync_v2;
    var v2 = try Message.decode(gpa, v2_bytes);
    defer v2.deinit();

    try testing.expectEqual(MessageVersion.v2, v2.version);
    try testing.expectEqual(v1.heads.len, v2.heads.len);
    try testing.expect(ChangeHash.eql(v1.heads[0], v2.heads[0]));
    try testing.expectEqual(v1.need.len, v2.need.len);
    try testing.expectEqual(v1.have.len, v2.have.len);
    try testing.expectEqual(v1.have[0].last_sync.len, v2.have[0].last_sync.len);
    try testing.expectEqualSlices(u8, v1.have[0].bloom.bits, v2.have[0].bloom.bits);
    try testing.expectEqual(v1.changes.len(), v2.changes.len());
    try testing.expectEqual(v1.flags.?.bits, v2.flags.?.bits);

    // Re-encoding keeps each message's own version byte, and only that byte.
    const v1_again = try v1.encode(gpa);
    defer gpa.free(v1_again);
    const v2_again = try v2.encode(gpa);
    defer gpa.free(v2_again);
    try testing.expectEqualSlices(u8, v1_bytes, v1_again);
    try testing.expectEqualSlices(u8, v2_bytes, v2_again);
    try testing.expectEqualSlices(u8, v1_bytes[1..], v2_again[1..]);

    // A body whose declared lengths disagree with its bytes is refused under
    // both type bytes: the version changes no rule above offset 0.
    var truncated = try gpa.dupe(u8, v1_bytes);
    defer gpa.free(truncated);
    // The flags section claims five bytes and has two.
    truncated[truncated.len - 3] = 0x05;
    try testing.expectError(error.LengthExceedsInput, Message.decode(gpa, truncated));
    truncated[0] = message_type_sync_v2;
    try testing.expectError(error.LengthExceedsInput, Message.decode(gpa, truncated));
}

test "every prefix of a golden message is refused until the last optional field" {
    const gpa = testing.allocator;
    const hex = "42012c91769152d8390db87c3db1b489b0d8d754aa81555edc60f41349595293e57200010006020a07d7015500020284";
    const full = try err.hexFrom(gpa, hex);
    defer gpa.free(full);

    // The body ends 3 bytes before the message does, and those 3 bytes are
    // the optional flags section. No proper prefix of the message is a valid
    // message, and the port says which of its two truncation classes applies
    // (`sync.rs:503-510` collapses both into one `NotEnoughInput`).
    const body_len = full.len - 3;
    for (0..body_len) |len| {
        if (Message.decode(gpa, full[0..len])) |*msg| {
            var owned = msg.*;
            defer owned.deinit();
            std.debug.print("a {d}-byte prefix of a {d}-byte message parsed\n", .{ len, full.len });
            return error.PrefixAccepted;
        } else |e| {
            try testing.expect(e == error.UnexpectedEnd or e == error.LengthExceedsInput);
        }
    }
    // The one prefix that *is* a complete message is the body without its
    // flags, which parses and reports no flags.
    var without_flags = try Message.decode(gpa, full[0..body_len]);
    defer without_flags.deinit();
    try testing.expectEqual(@as(?MessageFlags, null), without_flags.flags);
    try testing.expectEqual(@as(usize, 1), without_flags.heads.len);
}

test "trailing bytes after the flags section are ignored" {
    const gpa = testing.allocator;
    const hex = "43012c91769152d8390db87c3db1b489b0d8d754aa81555edc60f41349595293e57200010006020a07d7015500020284";
    const full = try err.hexFrom(gpa, hex);
    defer gpa.free(full);
    try testing.expectEqual(@as(usize, 48), full.len);

    const padded = try gpa.alloc(u8, full.len + 3);
    defer gpa.free(padded);
    @memcpy(padded[0..full.len], full);
    padded[full.len] = 0xde;
    padded[full.len + 1] = 0xad;
    padded[full.len + 2] = 0xbe;

    var msg = try Message.decode(gpa, padded);
    defer msg.deinit();
    const again = try msg.encode(gpa);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, full, again);
}

test "malformed messages are refused, each with the class upstream reports" {
    const gpa = testing.allocator;

    // A type byte that is neither 0x42 nor 0x43: upstream's `WrongType`
    // (`sync.rs:151-154`).
    try testing.expectError(
        error.InvalidMagic,
        Message.decode(gpa, &[_]u8{ 0x41, 0x00, 0x00, 0x00, 0x00 }),
    );
    try testing.expectError(
        error.InvalidMagic,
        Message.decode(gpa, &[_]u8{ 0x44, 0x00, 0x00, 0x00, 0x00 }),
    );

    // No bytes at all: the smallest possible truncation.
    try testing.expectError(error.UnexpectedEnd, Message.decode(gpa, &[_]u8{}));
    // A header with nothing after the type byte.
    try testing.expectError(error.UnexpectedEnd, Message.decode(gpa, &[_]u8{message_type_sync}));

    // A uleb128 count whose continuation bit is set and which then runs out
    // of bytes.
    try testing.expectError(
        error.UnexpectedEnd,
        Message.decode(gpa, &[_]u8{ message_type_sync, 0x80 }),
    );

    // A head count of one with no hash behind it.
    try testing.expectError(
        error.LengthExceedsInput,
        Message.decode(gpa, &[_]u8{ message_type_sync, 0x01, 0x00 }),
    );

    // A head count of five with two hashes behind it: the count cannot be
    // right, and the port says so before it allocates (`parse.rs:423-447`
    // would notice on the third hash).
    var too_many_heads: std.ArrayList(u8) = .empty;
    defer too_many_heads.deinit(gpa);
    try too_many_heads.appendSlice(gpa, &[_]u8{ message_type_sync, 0x05 });
    try too_many_heads.appendSlice(gpa, &([_]u8{0x11} ** 64));
    try testing.expectError(error.LengthExceedsInput, Message.decode(gpa, too_many_heads.items));

    // A `have` whose bloom field claims ten bytes and has three: the
    // `last_sync` list in between is complete, so this is the bloom length
    // that fails.
    try testing.expectError(
        error.LengthExceedsInput,
        Message.decode(gpa, &[_]u8{ message_type_sync, 0x00, 0x00, 0x01, 0x00, 0x0a, 0x01, 0x02, 0x03 }),
    );
    // The same record with a bloom that is complete but whose parameters run
    // past the section.
    try testing.expectError(
        error.LengthExceedsInput,
        Message.decode(gpa, &[_]u8{ message_type_sync, 0x00, 0x00, 0x01, 0x00, 0x04, 0x02, 0x0a, 0x07 }),
    );

    // A chunk that claims twenty bytes and has three.
    try testing.expectError(
        error.LengthExceedsInput,
        Message.decode(gpa, &[_]u8{ message_type_sync, 0x00, 0x00, 0x00, 0x01, 0x14, 0x01, 0x02, 0x03 }),
    );

    // A complete body followed by a flags section whose length runs past the
    // end.
    try testing.expectError(
        error.LengthExceedsInput,
        Message.decode(gpa, &[_]u8{ message_type_sync, 0x00, 0x00, 0x00, 0x00, 0x05, 0x02, 0x84 }),
    );
    // A flags length byte with no section at all.
    try testing.expectError(
        error.LengthExceedsInput,
        Message.decode(gpa, &[_]u8{ message_type_sync, 0x00, 0x00, 0x00, 0x00, 0x02 }),
    );
}

test "a chunk list joins into one stream" {
    const gpa = testing.allocator;
    var msg = Message.init(gpa);
    msg.version = .v1;
    {
        var chunks: std.ArrayList([]u8) = .empty;
        errdefer {
            for (chunks.items) |chunk| gpa.free(chunk);
            chunks.deinit(gpa);
        }
        try chunks.append(gpa, try gpa.dupe(u8, "abc"));
        try chunks.append(gpa, try gpa.dupe(u8, "de"));
        msg.changes = .{ .items = try chunks.toOwnedSlice(gpa), .gpa = gpa };
    }
    defer msg.deinit();

    try testing.expectEqual(@as(usize, 2), msg.changes.len());
    try testing.expectEqualSlices(u8, "abc", msg.changes.iter()[0]);
    const joined = try msg.changes.join(gpa);
    defer gpa.free(joined);
    try testing.expectEqualSlices(u8, "abcde", joined);

    // Two length-prefixed chunks, and the same stream re-split by a reader.
    const bytes = try msg.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ message_type_sync, 0x00, 0x00, 0x00, 0x02, 0x03, 'a', 'b', 'c', 0x02, 'd', 'e' },
        bytes,
    );
    var back = try Message.decode(gpa, bytes);
    defer back.deinit();
    const rejoined = try back.changes.join(gpa);
    defer gpa.free(rejoined);
    try testing.expectEqualSlices(u8, "abcde", rejoined);
}

test "advance heads keeps what we gained and what we still share" {
    const gpa = testing.allocator;
    const a = try ChangeHash.parse(gpa, "0a" ** 32);
    const b = try ChangeHash.parse(gpa, "0b" ** 32);
    const c = try ChangeHash.parse(gpa, "0c" ** 32);
    const d = try ChangeHash.parse(gpa, "0d" ** 32);

    // We were at `a`; we are now at `a`, `b` and `c`; the last shared heads
    // were `a` and `c`. `b` is new, and `a` and `c` come back through the
    // shared list, so the result is all three, ascending.
    const advanced = try advanceHeads(gpa, &.{a}, &.{ a, b, c }, &.{ a, c });
    defer gpa.free(advanced);
    try testing.expectEqual(@as(usize, 3), advanced.len);
    try testing.expect(ChangeHash.eql(advanced[0], a));
    try testing.expect(ChangeHash.eql(advanced[1], b));
    try testing.expect(ChangeHash.eql(advanced[2], c));

    // A head in both the new set and the shared set appears once.
    const deduped = try advanceHeads(gpa, &.{}, &.{ b, b, c }, &.{b});
    defer gpa.free(deduped);
    try testing.expectEqual(@as(usize, 2), deduped.len);
    try testing.expect(ChangeHash.eql(deduped[0], b));
    try testing.expect(ChangeHash.eql(deduped[1], c));

    // A shared head that is no longer one of our heads is dropped, however
    // much of it we still hold: `my_new_heads` is a head set, not a change
    // set (`sync.rs:832-845`).
    const stale = try advanceHeads(gpa, &.{}, &.{ b, c }, &.{a});
    defer gpa.free(stale);
    try testing.expectEqual(@as(usize, 2), stale.len);
    try testing.expect(ChangeHash.eql(stale[0], b));
    try testing.expect(ChangeHash.eql(stale[1], c));

    // Nothing gained and nothing shared: the other end lost everything.
    const empty = try advanceHeads(gpa, &.{}, &.{}, &.{});
    defer gpa.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    // `d` is only in the shared list and is not one of our heads, so it is
    // neither new nor shared.
    const only_shared = try advanceHeads(gpa, &.{}, &.{}, &.{d});
    defer gpa.free(only_shared);
    try testing.expectEqual(@as(usize, 0), only_shared.len);
}

/// Decodes a message and encodes it back, for the allocation-failure test
/// below. Every allocation either succeeds or unwinds through an `errdefer`
/// that frees what the step before it took, so the test fails on a leak
/// rather than on a count.
fn decodeThenEncode(gpa: Allocator, bytes: []const u8) !void {
    var msg = try Message.decode(gpa, bytes);
    defer msg.deinit();
    const again = try msg.encode(gpa);
    gpa.free(again);
}

test "a message survives every allocation failure" {
    const gpa = testing.allocator;
    // The richest message in the corpus, taken verbatim: two heads, one
    // `have` with a `last_sync` and a filter, a 104-byte chunk and a flags
    // section. Every field allocates at least once, so every allocation in
    // the decoder and the encoder is exercised.
    const text = try readGolden(gpa);
    defer gpa.free(text);
    var hex: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Record, gpa, line, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.kind, "sync") or !parsed.value.sent) continue;
        if (parsed.value.bytes.? == 216) hex = parsed.value.hex;
    }
    const bytes = try err.hexFrom(gpa, hex orelse return error.GoldenVectorMissing);
    defer gpa.free(bytes);
    try testing.checkAllAllocationFailures(gpa, decodeThenEncode, .{bytes});
}

// Every reader a network message reaches is either a value or a
// `ParseError`, and never a trap and never a loop. The eight corpora under
// `rust/automerge/tests/fuzz-crashers/` are upstream's regression suite for
// that property; this walks a deterministic sample of the same space,
// through all three record types a peer can send: a message, a persisted
// state, and the filter inside a `have`.
test "random bytes never trap a sync parser" {
    const gpa = testing.allocator;
    var prng = XorShift.init(0x5eed_1234_9abc_def0);
    var buf: [96]u8 = undefined;
    for (0..4000) |step| {
        const len = prng.below(buf.len + 1);
        for (buf[0..len]) |*byte| byte.* = @truncate(prng.next());
        // Two records start with a type byte; giving one most of the time
        // walks the counts and lengths behind it, which is where the risk is.
        if (len > 0 and step % 2 == 0) buf[0] = if (prng.below(2) == 0) message_type_sync else message_type_sync_v2;
        const bytes = buf[0..len];

        if (Message.decode(gpa, bytes)) |*msg| {
            var owned = msg.*;
            defer owned.deinit();
        } else |e| try expectParseError(e);

        if (step % 2 == 0) {
            if (state.State.decode(gpa, bytes)) |*peer| {
                var owned = peer.*;
                defer owned.deinit();
            } else |e| try expectParseError(e);
        }

        if (BloomFilter.parse(gpa, bytes)) |*filter| {
            var owned = filter.*;
            defer owned.deinit();
            // A filter that parsed must also answer every question asked of
            // it without dividing by zero.
            _ = owned.containsHash(ChangeHash.zero);
            owned.addHash(ChangeHash.zero);
        } else |e| try expectParseError(e);
    }
}

/// Asserts that `e` is one of the classes a sync reader may return. A reader
/// that reached anything else is a bug in the reader, not in the input.
fn expectParseError(e: anyerror) !void {
    try testing.expect(e == error.InvalidMagic or e == error.UnexpectedEnd or
        e == error.LengthExceedsInput or e == error.InvalidLeb128 or e == error.Overflow or
        e == error.TooLarge or e == error.OutOfMemory);
}

/// A `xorshift64*` step, so the corpus of test inputs is the same on every
/// run and on every target.
const XorShift = struct {
    state: u64,

    fn init(seed: u64) XorShift {
        return .{ .state = seed };
    }

    fn next(self: *XorShift) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545_f491_4f6c_dd1d;
    }

    fn below(self: *XorShift, limit: usize) usize {
        return @intCast(self.next() % @as(u64, @intCast(limit)));
    }
};

fn expectHashes(want: []const []const u8, got: []const ChangeHash) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |want_hex, hash| {
        try testing.expectEqualStrings(want_hex, &hashHex(hash));
    }
}
