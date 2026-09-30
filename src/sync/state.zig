//! The per-peer state of the sync protocol, and its persisted form.
//!
//! One `State` is what this document knows about one remote peer: what both
//! peers have, what we last sent, what the peer last said it has, and the
//! handful of bits that decide whether another message should be generated
//! at all. Upstream is `sync/state.rs` (214 lines); the wire format is
//! `sync.rs` and the `Have` record that sits inside a message is declared
//! here because it is part of this state as much as of that message.
//!
//! Only `shared_heads` is persisted (`State::encode`, `sync/state.rs:108-112`):
//!
//! ```text
//! offset 0, 1 byte:  0x43 == SYNC_STATE_TYPE      state.rs:9
//! offset 1, varint:  nSharedHeads
//!         32 * n    shared_heads[i], raw, ascending
//! ```
//!
//! The minimum encoding is `43 00`, two bytes. The other eleven fields are
//! deliberately dropped (`sync/state.rs:135-152`): a restored state starts
//! with `have_responded = false` so that it *does* send a message, which is
//! what the field's own comment requires (`sync/state.rs:56-59`). Trailing
//! bytes after the hash list are ignored (`sync/state.rs:115-121`).
//!
//! Three constants are in play and they are independent facts, not one
//! constant in three places: `SYNC_STATE_TYPE` is `0x43` (`state.rs:9`), the
//! V1 *message* type byte is `0x42` (`sync.rs:136`), and the V2 message type
//! byte is also `0x43` (`sync.rs:137`). A sync state and a V2 sync message
//! are told apart by what they are, not by their first byte.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const Input = @import("../storage/parse.zig").Input;
const bloom = @import("bloom.zig");
const msg = @import("message.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const ChangeHash = types.ChangeHash;
const BloomFilter = bloom.BloomFilter;
const Capability = msg.Capability;
const MessageFlags = msg.MessageFlags;
const hash_size = types.hash_size;

/// The first byte of an encoded sync state, for identification
/// (`state.rs:9`). Equal to `message.message_type_sync_v2`
/// (`sync.rs:137`) and to nothing else; see the module comment.
pub const sync_state_type: u8 = 0x43;

/// What the sender of a message says it already has, which is an implicit
/// request for everything it has not (`Have`, `state.rs:81-90`).
///
/// An empty `Have` is a legal thing to send and is what a reset message
/// carries (`sync.rs:632`): it claims nothing and asks for everything.
pub const Have = struct {
    gpa: Allocator,
    /// The heads at the sender's last successful sync with the recipient
    /// (`state.rs:86`).
    last_sync: []ChangeHash,
    /// Everything the sender has added since that sync (`state.rs:89`).
    bloom: BloomFilter,

    /// The `have` of a message that claims nothing.
    pub fn empty(gpa: Allocator) Have {
        return .{ .gpa = gpa, .last_sync = &.{}, .bloom = .empty(gpa) };
    }

    /// Frees the `last_sync` list and the filter (`state.rs:84-90`).
    pub fn deinit(self: *Have) void {
        self.gpa.free(self.last_sync);
        self.bloom.deinit();
        self.* = undefined;
    }
};

/// What `State.their` returns: the peer's `have` records and the changes it
/// asked for (`state.rs:202-206`).
pub const Their = struct {
    have: []const Have,
    need: []const ChangeHash,
};

/// The state of synchronisation with one peer (`State`, `state.rs:32-78`).
///
/// Persist with `encode` when the same peer is expected in a later session;
/// `encode` writes only what is worth reusing across connections.
pub const State = struct {
    gpa: Allocator,
    /// The hashes both peers have (`state.rs:35`). Advanced by
    /// `message.advanceHeads` when changes are applied (`sync.rs:424-427`),
    /// replaced with the peer's heads when we hold all of them
    /// (`sync.rs:442`), and cleared on the way out of read-only mode
    /// (`state.rs:170-174`).
    shared_heads: []ChangeHash,
    /// Our heads the last time we generated a message (`state.rs:37`).
    last_sent_heads: []ChangeHash,
    /// The heads the peer last advertised (`state.rs:39`). `Some` with an
    /// empty list is the "the peer has nothing" signal that arms `sendDoc`.
    their_heads: ?[]ChangeHash,
    /// Changes the peer last explicitly asked for (`state.rs:41`).
    their_need: ?[]ChangeHash,
    /// What the peer last said it has (`state.rs:43`). A decoded state starts
    /// with an *empty* list here rather than `null` (`state.rs:139`), so a
    /// restored state answers `their()` where a fresh one does not.
    their_have: ?[]Have,
    /// The hashes put on the wire this session (`state.rs:45`).
    ///
    /// Upstream holds a `BTreeSet`; this is the same set as an ascending,
    /// duplicate-free list, so it serialises and merges the same way.
    sent_hashes: std.ArrayList(ChangeHash),
    /// Whether the message we expect to send has been sent and not yet
    /// acknowledged (`state.rs:47-53`). A single bit, not a counter, and it
    /// is cleared at the top of every receive (`sync.rs:392`).
    in_flight: bool,
    /// Whether we have ever responded (`state.rs:56-59`). Guarantees that a
    /// peer learns our heads even when we have nothing to send.
    have_responded: bool,
    /// What the peer has advertised, derived from the flags sections it has
    /// sent (`state.rs:60-63`). `null` means it has never sent one, which is
    /// what makes it a v1-only peer (`state.rs:208-212`). A section replaces
    /// the list rather than adding to it (`sync.rs:407-411`).
    their_capabilities: ?[]Capability,
    /// Incoming changes are not applied; ours are still sent
    /// (`state.rs:65-68`).
    read_only: bool,
    /// The peer advertised `READ_ONLY` on its last message
    /// (`state.rs:69-72`), so there is no point sending it changes.
    peer_read_only: bool,
    /// The next message must carry `SYNC_RESET`, or empty heads if the peer
    /// is too old to understand it (`state.rs:73-78`, `sync.rs:267-278`).
    needs_reset: bool,

    /// A state for a peer we have never spoken to (`State::new`,
    /// `state.rs:93-99`): every field at its default.
    pub fn new(gpa: Allocator) State {
        return .{
            .gpa = gpa,
            .shared_heads = &.{},
            .last_sent_heads = &.{},
            .their_heads = null,
            .their_need = null,
            .their_have = null,
            .sent_hashes = .empty,
            .in_flight = false,
            .have_responded = false,
            .their_capabilities = null,
            .read_only = false,
            .peer_read_only = false,
            .needs_reset = false,
        };
    }

    /// A state for a publish-only peer (`State::new_read_only`,
    /// `state.rs:101-106`): the same, with `read_only` set.
    pub fn newReadOnly(gpa: Allocator) State {
        var state = State.new(gpa);
        state.read_only = true;
        return state;
    }

    /// Frees every owned field (`state.rs:33-78`). A state that has been
    /// through `setReadOnly` is freed once, not twice: that method rebuilds
    /// the state in place and carries the capability list across.
    pub fn deinit(self: *State) void {
        self.gpa.free(self.shared_heads);
        self.gpa.free(self.last_sent_heads);
        freeHashes(self.gpa, self.their_heads);
        freeHashes(self.gpa, self.their_need);
        if (self.their_have) |have| {
            for (have) |*entry| entry.deinit();
            self.gpa.free(have);
        }
        self.sent_hashes.deinit(self.gpa);
        if (self.their_capabilities) |caps| self.gpa.free(caps);
        self.* = undefined;
    }

    /// The persisted form: the type byte and `shared_heads`
    /// (`State::encode`, `state.rs:108-112`).
    ///
    /// `shared_heads` must be ascending, as `message.advanceHeads` leaves it
    /// (`sync.rs:849`) and as the assertion in `message.encodeHashes`
    /// assumes (`sync.rs:819-824`).
    pub fn encode(self: State, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.append(gpa, sync_state_type);
        try msg.encodeHashes(&out, gpa, self.shared_heads);
        return out.toOwnedSlice(gpa);
    }

    /// Reads a persisted state, ignoring anything after the hash list
    /// (`State::decode`, `state.rs:114-121`).
    ///
    /// The eleven fields the format does not carry come back at their
    /// defaults, except `their_have`, which comes back as an empty list
    /// rather than absent (`state.rs:139`).
    pub fn decode(gpa: Allocator, bytes: []const u8) ParseError!State {
        var in: Input = .init(bytes);
        return State.parse(gpa, &in);
    }

    /// Reads a persisted state, advancing `in` past the hash list
    /// (`State::parse`, `state.rs:123-157`).
    pub fn parse(gpa: Allocator, in: *Input) ParseError!State {
        // `state.rs:125-129` reports the one byte it expected along with the
        // one it found; the expected set is a constant, so only the value
        // travels.
        if (try in.takeByte() != sync_state_type) return error.InvalidMagic;

        var shared_heads: std.ArrayList(ChangeHash) = .empty;
        errdefer shared_heads.deinit(gpa);
        try in.readCountThen(HashSink{ .in = in, .gpa = gpa, .out = &shared_heads }, hash_size, HashSink.collect);

        return .{
            .gpa = gpa,
            .shared_heads = try shared_heads.toOwnedSlice(gpa),
            .last_sent_heads = &.{},
            .their_heads = null,
            .their_need = null,
            .their_have = try gpa.alloc(Have, 0),
            .sent_hashes = .empty,
            .in_flight = false,
            .have_responded = false,
            .their_capabilities = null,
            .read_only = false,
            .peer_read_only = false,
            .needs_reset = false,
        };
    }

    /// Switches read-only mode (`State::set_read_only`, `state.rs:159-184`).
    ///
    /// Going read-only changes three fields so that the next generated
    /// message exists and carries `READ_ONLY` (`state.rs:176-183`). Going
    /// read-write resets everything but `their_capabilities` and sets
    /// `needs_reset`, so the peer clears its `sent_hashes` and resends the
    /// changes we ignored (`state.rs:164-175`). Setting the mode it already
    /// has does nothing (`state.rs:160-162`).
    pub fn setReadOnly(self: *State, read_only: bool) void {
        if (self.read_only == read_only) return;
        if (self.read_only and !read_only) {
            // The capabilities are the one thing that survives, so they are
            // detached before `deinit` frees the list they point into.
            const caps = self.their_capabilities;
            const gpa = self.gpa;
            self.their_capabilities = null;
            self.deinit();
            self.* = .{
                .gpa = gpa,
                .shared_heads = &.{},
                .last_sent_heads = &.{},
                .their_heads = null,
                .their_need = null,
                .their_have = null,
                .sent_hashes = .empty,
                .in_flight = false,
                .have_responded = false,
                .their_capabilities = caps,
                .read_only = false,
                .peer_read_only = false,
                .needs_reset = true,
            };
        } else {
            self.read_only = true;
            self.in_flight = false;
            self.have_responded = false;
        }
    }

    /// Whether the peer said it is read-only (`state.rs:187-189`).
    pub fn isPeerReadOnly(self: State) bool {
        return self.peer_read_only;
    }

    /// Whether the peer understands `MessageFlags.sync_reset`
    /// (`state.rs:191-196`).
    pub fn peerSupportsSyncReset(self: State) bool {
        const caps = self.their_capabilities orelse return false;
        return indexOfCapability(caps, .sync_reset) != null;
    }

    /// Whether to answer with the whole document: the peer advertised no
    /// heads at all, and it can read one (`state.rs:198-200`).
    ///
    /// The empty head list is how a brand new peer, or one that has lost its
    /// data, says "send me everything".
    pub fn sendDoc(self: State) bool {
        const heads = self.their_heads orelse return false;
        return heads.len == 0 and self.supportsV2Messages();
    }

    /// The peer's `have` list and `need` list, when it has sent both
    /// (`state.rs:202-206`).
    pub fn their(self: State) ?Their {
        const have = self.their_have orelse return null;
        const need = self.their_need orelse return null;
        return .{ .have = have, .need = need };
    }

    /// Whether the peer reads V2 messages, which it does if it has ever sent
    /// a flags section (`state.rs:208-212`, `sync.rs:404-411`).
    pub fn supportsV2Messages(self: State) bool {
        const caps = self.their_capabilities orelse return false;
        return indexOfCapability(caps, .message_v2) != null;
    }

    /// Records `hash` in `sent_hashes`, keeping the set ascending and
    /// duplicate-free (`sync.rs:253`, upstream `BTreeSet::extend`).
    pub fn insertSent(self: *State, hash: ChangeHash) !void {
        // The binary search is over a sorted set, so an insert is an insert
        // and not an append-with-a-sort.
        var low: usize = 0;
        var high: usize = self.sent_hashes.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (ChangeHash.order(self.sent_hashes.items[mid], hash)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return,
            }
        }
        try self.sent_hashes.insert(self.gpa, low, hash);
    }

    /// Empties `sent_hashes` (`sync.rs:415`, `sync.rs:446`).
    pub fn clearSent(self: *State) void {
        self.sent_hashes.clearRetainingCapacity();
    }

    /// Replaces the capability list with a fresh copy of `caps`
    /// (`sync.rs:407-411`).
    ///
    /// Capabilities are replaced, never accumulated: a peer that stops
    /// advertising sync-reset support loses it.
    pub fn setTheirCapabilities(self: *State, caps: []const Capability) !void {
        if (self.their_capabilities) |old| self.gpa.free(old);
        self.their_capabilities = try self.gpa.dupe(Capability, caps);
    }

    /// The capabilities implied by a flags section (`sync.rs:404-411`): V2
    /// support, because the section exists at all, plus sync-reset support
    /// when the bit says so.
    pub fn capabilitiesFor(flags: MessageFlags) []const Capability {
        if (flags.contains(MessageFlags.supports_sync_reset)) {
            return &.{ .message_v2, .sync_reset };
        }
        return &.{.message_v2};
    }
};

const HashSink = struct {
    in: *Input,
    gpa: Allocator,
    out: *std.ArrayList(ChangeHash),

    fn collect(self: HashSink, count: usize) ParseError!void {
        try self.out.ensureUnusedCapacity(self.gpa, count);
        for (0..count) |_| self.out.appendAssumeCapacity(.{ .bytes = try self.in.takeArray(ChangeHash) });
    }
};

fn freeHashes(gpa: Allocator, hashes: ?[]ChangeHash) void {
    if (hashes) |owned| gpa.free(owned);
}

fn indexOfCapability(caps: []const Capability, needle: Capability) ?usize {
    for (caps, 0..) |cap, index| {
        if (cap == needle) return index;
    }
    return null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "an empty state is two bytes" {
    const gpa = testing.allocator;
    var state = State.new(gpa);
    defer state.deinit();

    const bytes = try state.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ sync_state_type, 0x00 }, bytes);

    var back = try State.decode(gpa, bytes);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 0), back.shared_heads.len);
    try testing.expectEqual(@as(usize, 0), back.last_sent_heads.len);
    try testing.expectEqual(@as(?[]ChangeHash, null), back.their_heads);
    try testing.expectEqual(@as(?[]ChangeHash, null), back.their_need);
    try testing.expectEqual(@as(usize, 0), back.their_have.?.len);
    try testing.expectEqual(@as(usize, 0), back.sent_hashes.items.len);
    try testing.expectEqual(@as(?[]Capability, null), back.their_capabilities);
    try testing.expect(!back.in_flight);
    try testing.expect(!back.have_responded);
    try testing.expect(!back.read_only);
    try testing.expect(!back.peer_read_only);
    try testing.expect(!back.needs_reset);
}

test "a state round trips its shared heads and nothing else" {
    const gpa = testing.allocator;
    const a = try ChangeHash.parse(gpa, "0a" ** 32);
    const b = try ChangeHash.parse(gpa, "0b" ** 32);

    var state = State.new(gpa);
    defer state.deinit();
    state.shared_heads = try gpa.dupe(ChangeHash, &.{ a, b });
    // Everything below is dropped by the format, so it is set to something
    // the round trip must not preserve.
    state.last_sent_heads = try gpa.dupe(ChangeHash, &.{a});
    state.their_heads = try gpa.dupe(ChangeHash, &.{b});
    state.their_need = try gpa.dupe(ChangeHash, &.{a});
    try state.insertSent(a);
    try state.insertSent(b);
    state.in_flight = true;
    state.have_responded = true;
    state.read_only = true;
    state.peer_read_only = true;
    state.needs_reset = true;
    try state.setTheirCapabilities(&.{ .message_v2, .sync_reset });

    const bytes = try state.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 2 + 64), bytes.len);
    try testing.expectEqualSlices(u8, &[_]u8{ sync_state_type, 0x02 }, bytes[0..2]);

    var back = try State.decode(gpa, bytes);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.shared_heads.len);
    try testing.expect(ChangeHash.eql(back.shared_heads[0], a));
    try testing.expect(ChangeHash.eql(back.shared_heads[1], b));
    try testing.expectEqual(@as(usize, 0), back.last_sent_heads.len);
    try testing.expectEqual(@as(?[]ChangeHash, null), back.their_heads);
    try testing.expectEqual(@as(?[]ChangeHash, null), back.their_need);
    try testing.expectEqual(@as(usize, 0), back.sent_hashes.items.len);
    try testing.expectEqual(@as(?[]Capability, null), back.their_capabilities);
    try testing.expect(!back.in_flight);
    try testing.expect(!back.have_responded);
    try testing.expect(!back.read_only);
    try testing.expect(!back.peer_read_only);
    try testing.expect(!back.needs_reset);
}

test "the state type byte is the only one a state accepts" {
    const gpa = testing.allocator;
    const a = try ChangeHash.parse(gpa, "0a" ** 32);

    var state = State.new(gpa);
    defer state.deinit();
    state.shared_heads = try gpa.dupe(ChangeHash, &.{a});
    const bytes = try state.encode(gpa);
    defer gpa.free(bytes);
    // 0x42 is the *V1 message* type byte, not the state's.
    try testing.expectError(error.InvalidMagic, State.decode(gpa, &[_]u8{msg.message_type_sync}));
    try testing.expectError(error.InvalidMagic, State.decode(gpa, &[_]u8{ 0x44, 0x00 }));
    try testing.expectError(error.UnexpectedEnd, State.decode(gpa, &[_]u8{}));
    // A count with nothing behind it, and a count the rest of the input
    // cannot hold.
    try testing.expectError(error.UnexpectedEnd, State.decode(gpa, &[_]u8{sync_state_type}));
    try testing.expectError(
        error.LengthExceedsInput,
        State.decode(gpa, &[_]u8{ sync_state_type, 0x02, 0x00 }),
    );
    // A truncated hash, and a count whose uleb128 runs off the end.
    try testing.expectError(
        error.LengthExceedsInput,
        State.decode(gpa, &[_]u8{ sync_state_type, 0x01, 0x00, 0x00, 0x00 }),
    );
    try testing.expectError(
        error.UnexpectedEnd,
        State.decode(gpa, &[_]u8{ sync_state_type, 0x80 }),
    );
    // A two-byte count of 128 with nothing behind it.
    try testing.expectError(
        error.LengthExceedsInput,
        State.decode(gpa, &[_]u8{ sync_state_type, 0x80, 0x01 }),
    );
    // Bytes after the hash list are not an error: a state may be stored
    // beside other data (`state.rs:115-121`).
    const padded = try gpa.alloc(u8, bytes.len + 2);
    defer gpa.free(padded);
    @memcpy(padded[0..bytes.len], bytes);
    padded[bytes.len] = 0xde;
    padded[bytes.len + 1] = 0xad;
    var back = try State.decode(gpa, padded);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.shared_heads.len);
}

test "capabilities decide the version, and only a flags section creates them" {
    const gpa = testing.allocator;
    var state = State.new(gpa);
    defer state.deinit();

    // A peer that has never sent a flags section is a v1-only peer, and
    // `send_doc` needs it to have advertised no heads as well.
    try testing.expect(!state.supportsV2Messages());
    try testing.expect(!state.peerSupportsSyncReset());
    try testing.expect(!state.sendDoc());
    try testing.expectEqual(@as(?Their, null), state.their());

    // A section that carries the sync-reset bit: the peer both understands
    // the flag and is being asked to act on it.
    var reset_flag: msg.MessageFlags = .none();
    reset_flag.set(msg.MessageFlags.sync_reset);
    reset_flag.set(msg.MessageFlags.supports_sync_reset);
    const both = State.capabilitiesFor(reset_flag);
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectEqual(Capability.message_v2, both[0]);
    try testing.expectEqual(Capability.sync_reset, both[1]);

    var read_only_flag: msg.MessageFlags = .none();
    read_only_flag.set(msg.MessageFlags.read_only);
    // A section without the sync-reset bit advertises v2 and nothing else.
    const v2_only = State.capabilitiesFor(read_only_flag);
    try testing.expectEqual(@as(usize, 1), v2_only.len);
    try testing.expectEqual(Capability.message_v2, v2_only[0]);

    try state.setTheirCapabilities(both);
    try testing.expect(state.supportsV2Messages());
    try testing.expect(state.peerSupportsSyncReset());
    try testing.expect(!state.sendDoc());

    // A peer advertising no heads, and one that can read v2, is a peer to
    // send the whole document to. The receive path *moves* the list out of
    // the message it came from; here each replacement is freed first.
    state.their_heads = try gpa.dupe(ChangeHash, &.{});
    try testing.expect(state.sendDoc());
    gpa.free(state.their_heads.?);
    state.their_heads = try gpa.dupe(ChangeHash, &.{.zero});
    try testing.expect(!state.sendDoc());

    // A v1-only peer is never sent the document, whatever its heads say.
    try state.setTheirCapabilities(v2_only[0..0]);
    try testing.expect(!state.supportsV2Messages());
    try testing.expect(!state.peerSupportsSyncReset());
    gpa.free(state.their_heads.?);
    state.their_heads = try gpa.dupe(ChangeHash, &.{});
    try testing.expect(!state.sendDoc());
}

test "their needs both halves of what the peer said" {
    const gpa = testing.allocator;

    // A decoded state carries an empty `have` and no `need`, so it has not
    // heard both halves yet.
    var restored = try State.decode(gpa, &[_]u8{ sync_state_type, 0x00 });
    defer restored.deinit();
    try testing.expectEqual(@as(?Their, null), restored.their());

    var have: std.ArrayList(Have) = .empty;
    errdefer {
        for (have.items) |*entry| entry.deinit();
        have.deinit(gpa);
    }
    try have.append(gpa, .empty(gpa));
    restored.their_have = try have.toOwnedSlice(gpa);
    restored.their_need = try gpa.dupe(ChangeHash, &.{});
    const their = restored.their().?;
    try testing.expectEqual(@as(usize, 1), their.have.len);
    try testing.expectEqual(@as(usize, 0), their.need.len);
}

test "leaving read-only resets the exchange and keeps the capabilities" {
    const gpa = testing.allocator;
    const a = try ChangeHash.parse(gpa, "0a" ** 32);

    // A fresh read-only state, which is a default state with one flag set.
    var fresh = State.newReadOnly(gpa);
    defer fresh.deinit();
    try testing.expect(fresh.read_only);
    try testing.expect(!fresh.needs_reset);
    try testing.expectEqual(@as(usize, 0), fresh.shared_heads.len);

    var state = State.new(gpa);
    defer state.deinit();
    try state.setTheirCapabilities(&.{ .message_v2, .sync_reset });
    state.shared_heads = try gpa.dupe(ChangeHash, &.{a});
    try state.insertSent(a);
    state.in_flight = true;
    state.have_responded = true;
    // Read-write to read-only only unblocks generation.
    state.setReadOnly(true);
    try testing.expect(state.read_only);
    try testing.expect(!state.in_flight);
    try testing.expect(!state.have_responded);
    // Everything else survives: the peer still knows what we have.
    try testing.expectEqual(@as(usize, 1), state.shared_heads.len);
    try testing.expectEqual(@as(usize, 2), state.their_capabilities.?.len);

    // Read-only to read-write throws the exchange away but keeps what the
    // peer advertised, and asks for a reset.
    state.setReadOnly(false);
    try testing.expect(!state.read_only);
    try testing.expect(state.needs_reset);
    try testing.expect(!state.in_flight);
    try testing.expect(!state.have_responded);
    try testing.expectEqual(@as(usize, 0), state.shared_heads.len);
    try testing.expectEqual(@as(usize, 0), state.sent_hashes.items.len);
    try testing.expectEqual(@as(usize, 2), state.their_capabilities.?.len);
    try testing.expect(state.peerSupportsSyncReset());

    // Setting the mode a state already has changes nothing at all
    // (`state.rs:160-162`), so the one-shot reset flag survives a second
    // `setReadOnly(false)`. Going read-only does not clear it either
    // (`state.rs:176-183`): only generating a message does (`sync.rs:267`).
    state.setReadOnly(false);
    try testing.expect(state.needs_reset);
    state.setReadOnly(true);
    try testing.expect(state.read_only);
    try testing.expect(state.needs_reset);
    try testing.expect(!state.have_responded);
    state.setReadOnly(true);
    try testing.expect(state.needs_reset);
}

test "sent hashes are a set" {
    const gpa = testing.allocator;
    const a = try ChangeHash.parse(gpa, "0a" ** 32);
    const b = try ChangeHash.parse(gpa, "0b" ** 32);
    const c = try ChangeHash.parse(gpa, "0c" ** 32);

    var state = State.new(gpa);
    defer state.deinit();
    // Inserted out of order and twice, so the set must still be ascending
    // and duplicate-free, which is what makes it a `BTreeSet` upstream.
    try state.insertSent(c);
    try state.insertSent(a);
    try state.insertSent(b);
    try state.insertSent(a);
    try testing.expectEqual(@as(usize, 3), state.sent_hashes.items.len);
    try testing.expect(ChangeHash.eql(state.sent_hashes.items[0], a));
    try testing.expect(ChangeHash.eql(state.sent_hashes.items[1], b));
    try testing.expect(ChangeHash.eql(state.sent_hashes.items[2], c));

    state.clearSent();
    try testing.expectEqual(@as(usize, 0), state.sent_hashes.items.len);
    try state.insertSent(b);
    try testing.expectEqual(@as(usize, 1), state.sent_hashes.items.len);
}

test "a have is a last-sync list and a bloom" {
    const gpa = testing.allocator;

    var have = Have.empty(gpa);
    defer have.deinit();
    try testing.expectEqual(@as(usize, 0), have.last_sync.len);
    try testing.expectEqual(@as(u32, 0), have.bloom.num_entries);
    // An empty `have` is zero bytes of bloom on the wire, which is what makes
    // it cheap enough to put in every generated message.
    const bytes = try have.bloom.toBytes(gpa);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

/// Decodes a state and encodes it back, for the allocation-failure test
/// below.
fn decodeThenEncodeState(gpa: Allocator, bytes: []const u8) !void {
    var state = try State.decode(gpa, bytes);
    defer state.deinit();
    const again = try state.encode(gpa);
    gpa.free(again);
}

test "a state survives every allocation failure" {
    const gpa = testing.allocator;
    var state = State.new(gpa);
    defer state.deinit();
    state.shared_heads = try gpa.dupe(ChangeHash, &.{
        try ChangeHash.parse(gpa, "0a" ** 32),
        try ChangeHash.parse(gpa, "0b" ** 32),
    });
    const bytes = try state.encode(gpa);
    defer gpa.free(bytes);
    try testing.checkAllAllocationFailures(gpa, decodeThenEncodeState, .{bytes});
}
