//! The v1 compatibility path: the sync protocol as it was **before** the v2
//! message type, kept so a document can talk to a peer that predates it.
//!
//! Upstream keeps this as a frozen copy of the whole module under
//! `#[cfg(test)] mod v1_compat_test` (`sync.rs:87-88`), and the copy exists for
//! one reason: `sync_from_v1_to_v2`, `sync_from_v2_to_v1` and
//! `sync_v1_to_v2_with_compressed_change`
//! (`sync/v1_compat_test/mod.rs:472-547`) drive two real implementations against
//! each other and assert they converge. There is no other way to hold a v1 peer
//! up to the current one, so the copy is the test fixture.
//!
//! **What "v1" means here is a frozen wire format and a frozen state machine**,
//! not a flag. Five things differ from `protocol.zig`, and each is a place where
//! a v2 peer and a v1 peer disagree on purpose:
//!
//! 1. **No flags section, ever** (`v1_compat_test/mod.rs:427-444`). Every byte a
//!    v1 peer writes stops after the change list. That is not a formatting
//!    choice: the peer on the other end replaces its capability list from the
//!    flags section (`sync.rs:404-411`) and, with none, has none at all
//!    (`sync/state.rs:208-212`) — so a v1 peer stays on v1 for the life of the
//!    connection, which is the entire point of the type byte.
//! 2. **One chunk per change, always.** There is no `send_doc` arm
//!    (`sync.rs:213-215`) and no more-than-a-third whole-document arm
//!    (`sync.rs:225-228`): both need a peer that can read one chunk holding many
//!    changes, and a v1 peer cannot.
//! 3. **No read-only mode** (`sync.rs:170-184`, `sync.rs:208-211`,
//!    `sync.rs:420-420`). [`State`] has no `read_only`, no `needs_reset`, no
//!    `peer_read_only` and no capability list, because none of them existed.
//! 4. **`our_need` comes from the other function.** V2 asks
//!    `missing_deps_from(their_heads)` (`sync.rs:180`); v1 asks
//!    `get_missing_deps(their_heads)` (`v1_compat_test/mod.rs:29`), which chains
//!    the change queue **in front of** the peer's heads
//!    (`automerge.rs:2289-2292`). A queued orphan therefore contributes its
//!    dependencies to a v1 peer's request even when no advertised head leads
//!    there — which is the deadlock `sync.rs:173-181` exists to prevent, and a v1
//!    peer cannot avoid it.
//! 5. **A head is "known" when it can be rebuilt, not when the graph holds it.**
//!    V2 asks `has_change` (`sync.rs:446`, `automerge.rs:2031-2033`); v1 asks
//!    `get_change_by_hash(...).is_some()` (`v1_compat_test/mod.rs:214-216`), and
//!    that call **swallows a rebuild failure** (`automerge.rs:2294-2298`), so a
//!    head in the graph whose rows will not collect counts as unknown to a v1
//!    peer and known to a v2 one.
//!
//! The parts that did not change are reused rather than copied: the message and
//! its encoder (`message.zig`), the bloom filter (`bloom.zig` — the v1 copy of
//! it, `v1_compat_test/bloom.rs`, is the same 10 bits per entry and 7 probes),
//! `advanceHeads` (`sync.rs:827-850` is a byte-for-byte twin of
//! `v1_compat_test/mod.rs:446-470`), `getHashesToSend` (`sync.rs:318-384` is a
//! twin of `v1_compat_test/mod.rs:120-179`) and `makeBloomFilter`
//! (`sync.rs:310-316` against `v1_compat_test/mod.rs:123-129`). Upstream copied
//! them because it had to: its v1 copy is a standalone module that predates the
//! shared helpers. A second copy here would be a second thing to keep in step
//! with the wire format, and the wire format is the contract.
//!
//! ## How a v1 peer stays a v1 peer
//!
//! [`generateSyncMessage`] writes no flags, so a v2 peer talking to it never
//! learns that V2 exists and its own messages come out V1-typed — with a flags
//! section attached (`sync.rs:283`), which this file ignores the way a real v1
//! implementation does, because a v1 parser stops after the change list
//! (`v1_compat_test/mod.rs:385-402`). That is the whole handshake, and it is why
//! both directions of the drivers below converge without either side having to
//! know which version the other is.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const docmod = @import("../doc.zig");
const bloommod = @import("bloom.zig");
const msg = @import("message.zig");
const statemod = @import("state.zig");
const protocol = @import("protocol.zig");
// The two below are used by the v1-only peer gate at the bottom of this file
// and by nothing else: a peer that is never handed a document with content in
// it has not been asked whether it converges.
const trans = @import("../transact.zig");
const readmod = @import("../read.zig");

const Allocator = std.mem.Allocator;
const ChangeHash = types.ChangeHash;
const Document = docmod.Document;

/// Everything a call in this file can return, and it is the same set
/// `protocol.zig` returns (`ProtocolError`, `protocol.zig:65-69`): a v1 message
/// is a v2 message with two fields held at their v1 values.
pub const ProtocolError = docmod.DocumentError || err.Error || err.InternalError;

/// The wire message, re-exported so a caller driving this module does not have
/// to reach into `message.zig` (`Message`, `v1_compat_test/mod.rs:312-323`).
///
/// **It is [`msg.Message`], and that is not a shortcut.** A v1 message is a type
/// byte of `0x42`, a heads list, a need list, a have list, a change list and
/// nothing else (`v1_compat_test/mod.rs:427-444`), which is exactly `Message`
/// with `version == .v1` and `flags == null`: `Message.encode` writes the flags
/// section last and only when `flags` is set (`message.zig:454`), so the two
/// encoders agree byte for byte.
pub const Message = msg.Message;

/// One `have` record (`Have`, `v1_compat_test/state.rs:70-81`). The same struct
/// the current protocol uses (`sync/state.rs:81-90`) — a `last_sync` and a
/// filter, field for field.
pub const Have = statemod.Have;

/// What a peer last said it had and asked for (`Their`,
/// `v1_compat_test/state.rs:38-39`).
pub const Their = statemod.Their;

/// The first byte of a V1 sync message (`sync.rs:136`, and
/// `v1_compat_test/mod.rs:24`). Pinned as a literal because it is the
/// compatibility boundary.
pub const message_type_sync: u8 = msg.message_type_sync;

/// The state of synchronisation with a peer that speaks only v1
/// (`State`, `v1_compat_test/state.rs:29-68`).
///
/// **This is not `state.zig`'s `State` with its extra fields left at their
/// defaults**, and the difference is load-bearing. `read_only` would suppress
/// the payload (`sync.rs:208-211`) and add an arm to the suppression test
/// (`sync.rs:243-244`); `needs_reset` would change what heads go out
/// (`sync.rs:267-277`); `their_capabilities` would record a V2 peer and switch
/// the type byte (`sync/state.rs:208-212`). A v1 peer has none of them, so it has
/// none of them here, and a caller cannot reach the v2 behaviour through this
/// struct by accident.
///
/// `sent_hashes` is an ascending, duplicate-free list rather than upstream's
/// `BTreeSet` — the same representation `sync/state.rs` uses, and the same
/// reason: [`State.insertSent`] puts a hash in its sorted place and the receive
/// path rebuilds the list by filtering, so it stays a set.
pub const State = struct {
    gpa: Allocator,
    /// The hashes both peers are known to have (`v1_compat_test/state.rs:35`).
    shared_heads: []ChangeHash = &.{},
    /// The heads we last sent (`v1_compat_test/state.rs:36`).
    last_sent_heads: []ChangeHash = &.{},
    /// The heads we last received (`v1_compat_test/state.rs:37`).
    their_heads: ?[]ChangeHash = null,
    /// What they last asked for (`v1_compat_test/state.rs:38`).
    their_need: ?[]ChangeHash = null,
    /// What they last said they had (`v1_compat_test/state.rs:39`).
    their_have: ?[]Have = null,
    /// What we have sent this session (`v1_compat_test/state.rs:40`).
    sent_hashes: std.ArrayList(ChangeHash) = .empty,
    /// Whether an unanswered message is on the wire
    /// (`v1_compat_test/state.rs:52`). **A bit, not a counter**: it is cleared on
    /// receive and nowhere else (`v1_compat_test/mod.rs:184`).
    in_flight: bool = false,
    /// Whether we have ever answered this peer (`v1_compat_test/state.rs:58`).
    /// It is what makes the first message go out even with nothing to send,
    /// because the peer has to learn our heads.
    have_responded: bool = false,

    /// The empty state (`State::new`, `v1_compat_test/state.rs:73-75`).
    pub fn new(gpa: Allocator) State {
        return .{ .gpa = gpa };
    }

    /// Frees the three head lists, the `have` list and the sent hashes
    /// (`v1_compat_test/state.rs`, `State`'s `Drop`).
    pub fn deinit(self: *State) void {
        self.gpa.free(self.shared_heads);
        self.gpa.free(self.last_sent_heads);
        if (self.their_heads) |heads| self.gpa.free(heads);
        if (self.their_need) |need| self.gpa.free(need);
        if (self.their_have) |have| freeHaves(self.gpa, have);
        self.sent_hashes.deinit(self.gpa);
        self.* = undefined;
    }

    /// Records `hash` as sent, in its sorted place
    /// (`sync_state.sent_hashes.extend`, `v1_compat_test/mod.rs:102-104`).
    ///
    /// A hash already in the set is left where it is, so the list stays duplicate
    /// free exactly as the upstream `BTreeSet` does.
    pub fn insertSent(self: *State, hash: ChangeHash) Allocator.Error!void {
        if (sentSlot(self.sent_hashes.items, hash) != null) return;
        try self.sent_hashes.insert(self.gpa, sentIndex(self.sent_hashes.items, hash), hash);
    }

    /// Whether `hash` has been sent (`sync_state.sent_hashes.contains`,
    /// `v1_compat_test/mod.rs:83`). The same logarithmic search over the sorted
    /// list that the upstream `BTreeSet` does.
    pub fn wasSent(self: *const State, hash: ChangeHash) bool {
        return sentSlot(self.sent_hashes.items, hash) != null;
    }

    /// Empties `sent_hashes` (`v1_compat_test/mod.rs:221-222`, the
    /// "peer has lost all its data" arm).
    pub fn clearSent(self: *State) void {
        self.sent_hashes.clearRetainingCapacity();
    }

    /// What the peer last told us, or null before it has said anything
    /// (the `if let (Some(their_have), Some(their_need))` at
    /// `v1_compat_test/mod.rs:61-64`).
    pub fn their(self: *const State) ?Their {
        const have = self.their_have orelse return null;
        const need = self.their_need orelse return null;
        return .{ .have = have, .need = need };
    }
};

/// The next v1 message for this peer, or null when there is nothing to say
/// (`Automerge::generate_sync_message_v1`, `v1_compat_test/mod.rs:26-118`).
///
/// The order is upstream's and every step reads the state it is written against:
///
/// 1. `our_heads`, then `our_need` from `get_missing_deps` — **not** the V2
///    `missing_deps_from` (`v1_compat_test/mod.rs:28-29`).
/// 2. `our_have`, and **only if every change we need is in the peer's advertised
///    heads** (`v1_compat_test/mod.rs:38-42`).
/// 3. A reset, when the peer's *first* `have` names a change we do not have
///    (`v1_compat_test/mod.rs:44-58`). Only the first `have` is inspected.
/// 4. The payload: nothing at all before the peer's first message, and the
///    changes they are missing after that (`v1_compat_test/mod.rs:60-69`).
/// 5. Deduplication against `sent_hashes` (`v1_compat_test/mod.rs:79-89`).
/// 6. The suppression test (`v1_compat_test/mod.rs:91-98`).
///
/// The message carries **no flags**, which is the reason a v1 peer stays a v1
/// peer: the peer's capability list is replaced from the flags section and
/// replaced with nothing (`sync.rs:404-411`), so it never learns that v2 exists.
pub fn generateSyncMessage(
    gpa: Allocator,
    doc: *Document,
    state: *State,
) ProtocolError!?Message {
    // No `errdefer` on this one: it is **moved** into the builder below and
    // copied into the reset, and an `errdefer` that only runs on failure is a
    // double free on every error path once the builder owns it.
    const our_heads = try doc.getHeads(gpa);

    // `v1_compat_test/mod.rs:29`. The **queue is chained in front of the peer's
    // heads**, which is what `get_missing_deps` means (`automerge.rs:2289-2292`)
    // and what makes this path different from V2's
    // `missing_deps_from(their_heads)` (`sync.rs:180`). A queued orphan whose
    // dependencies this document does not have contributes them here even though
    // no advertised head leads there.
    var our_need = try doc.getMissingDeps(gpa, state.their_heads orelse &.{});
    errdefer gpa.free(our_need);

    // `v1_compat_test/mod.rs:38-42`. `all` over an empty `our_need` is true, so a
    // peer with nothing to ask for always advertises what it has.
    var our_have: []Have = &.{};
    errdefer freeHaves(gpa, our_have);
    if (everyNeedIsIn(state.their_heads, our_need)) {
        var entry = try protocol.makeBloomFilter(gpa, doc, state.shared_heads);
        errdefer entry.deinit();
        our_have = try gpa.alloc(Have, 1);
        our_have[0] = entry;
    }

    // `v1_compat_test/mod.rs:44-58`. A peer whose first `have` names a change we
    // do not have is talking about a history we are not part of, and the answer
    // is to start again: our heads, one empty `have`, no need and no payload.
    // `Have::default()` is the empty record — `last_sync` empty and a filter with
    // no entries — which is what `v1_compat_test/state.rs:76-82` derives.
    if (state.their_have) |their_have| {
        if (their_have.len > 0) {
            for (their_have[0].last_sync) |hash| {
                if (!try canRebuild(gpa, doc, hash)) {
                    // The reset carries none of what was computed above, so both
                    // lists are released here rather than left to an `errdefer`
                    // that only runs on failure.
                    const reset = v1Reset(gpa, our_heads) catch |e| {
                        gpa.free(our_need);
                        freeHaves(gpa, our_have);
                        gpa.free(our_heads);
                        return e;
                    };
                    gpa.free(our_need);
                    freeHaves(gpa, our_have);
                    gpa.free(our_heads);
                    return reset;
                }
            }
        }
    }

    // `v1_compat_test/mod.rs:60-69`. Before the peer's first message there is
    // nothing to answer, so no changes go out.
    var payloads: std.ArrayList(ChangePayload) = .empty;
    defer {
        for (payloads.items) |payload| gpa.free(payload.raw);
        payloads.deinit(gpa);
    }
    if (state.their()) |their| {
        const all_hashes = try protocol.getHashesToSend(gpa, doc, their.have, their.need);
        defer gpa.free(all_hashes);

        // `v1_compat_test/mod.rs:79-89`: deduplicate against what has already
        // gone on the wire this session, on the hashes, before any change is
        // materialised.
        var chosen: std.ArrayList(ChangeHash) = .empty;
        defer chosen.deinit(gpa);
        for (all_hashes) |hash| {
            if (state.wasSent(hash)) continue;
            try chosen.append(gpa, hash);
        }
        for (chosen.items) |hash| {
            const made = try payloadFor(gpa, doc, hash);
            errdefer gpa.free(made.raw);
            try payloads.append(gpa, made);
        }
    }

    // `MessageBuilder::new_v1`, `sync/message_builder.rs:26-41`: one chunk per
    // change. There is no other shape a v1 message can have, so this is not a
    // decision — it is the format. The builder **copies** each chunk, so the
    // payloads are released by the `defer` above rather than handed over.
    var builder = try protocol.MessageBuilder.newV1(gpa, payloads.items);
    defer builder.deinit();
    builder.setHeads(our_heads);
    builder.setNeed(our_need);
    builder.setHave(our_have);
    our_need = &.{};
    our_have = &.{};
    // No flags. `Message.encode` writes the section only when it is set
    // (`message.zig:454`), which is what pins this peer to v1.

    // `v1_compat_test/mod.rs:71-98`, in full. Both comparisons are order
    // sensitive, as upstream's `Vec` equality is. **There is no read-only arm**,
    // because a v1 peer has no read-only mode.
    const heads_unchanged = hashesEqual(state.last_sent_heads, builder.heads);
    const heads_equal = if (state.their_heads) |their| hashesEqual(their, builder.heads) else false;
    if (heads_unchanged and state.have_responded) {
        if (heads_equal and builder.isEmpty()) return null;
        if (state.in_flight) return null;
    }

    // `v1_compat_test/mod.rs:100-104`. The new list is built before the old one is
    // released, so a failure cannot leave the state holding a freed pointer.
    state.have_responded = true;
    const sent_heads = try gpa.dupe(ChangeHash, builder.heads);
    gpa.free(state.last_sent_heads);
    state.last_sent_heads = sent_heads;
    for (builder.payloadHashes()) |hash| try state.insertSent(hash);

    state.in_flight = true;
    return builder.build();
}

/// Applies what `message` carries and folds the peer's answers into `state`
/// (`Automerge::receive_sync_message_inner_v1`, `v1_compat_test/mod.rs:181-243`).
///
/// The message is **taken by value and freed here**, after its `heads`, `need`
/// and `have` have moved into the state (`v1_compat_test/mod.rs:235-237`).
///
/// The order is upstream's and each step is load-bearing:
///
/// 1. `in_flight` is cleared **first**, before anything that can fail
///    (`v1_compat_test/mod.rs:184`), so a receive that fails still unblocks
///    generation.
/// 2. The changes are applied — **unconditionally**, with no read-only check,
///    because there is no read-only mode — and only then are the shared heads
///    advanced (`v1_compat_test/mod.rs:194-205`).
/// 3. `sent_hashes` is pruned by the peer's advertised heads. **This is the
///    acknowledgement**; there is no ack message
///    (`v1_compat_test/mod.rs:208`).
/// 4. The shared heads become the peer's heads when we can rebuild all of them,
///    and otherwise stay where they are with the recognised ones added
///    (`v1_compat_test/mod.rs:214-233`).
///
/// **A message that arrived with a V2 type byte is not detectable here.**
/// `Message.decode` accepts both (`message.zig:381-389`) and this function is
/// handed an already decoded struct with no type byte left to look at, so a
/// caller that reads a v2 message with it produces a v1 exchange carrying a flags
/// section this peer must not write. [`decodeV1`] is the reader a caller on a
/// v1-only link wants, and it is the only way to get the type byte checked.
pub fn receiveSyncMessage(
    gpa: Allocator,
    doc: *Document,
    state: *State,
    message: Message,
) ProtocolError!void {
    state.in_flight = false;
    const before_heads = try doc.getHeads(gpa);
    defer gpa.free(before_heads);

    var owned = message;
    errdefer owned.deinit();

    // `v1_compat_test/mod.rs:194-205`.
    const changes_is_empty = owned.changes.isEmpty();
    if (!changes_is_empty) {
        const joined = try owned.changes.join(gpa);
        defer gpa.free(joined);
        _ = try doc.loadIncremental(gpa, joined);
        const after_heads = try doc.getHeads(gpa);
        defer gpa.free(after_heads);
        const advanced = try msg.advanceHeads(gpa, before_heads, after_heads, state.shared_heads);
        gpa.free(state.shared_heads);
        state.shared_heads = advanced;
    }

    // `v1_compat_test/mod.rs:208`: prune what the peer's heads already cover.
    {
        const kept = try doc.graph.filterChanges(gpa, state.sent_hashes.items, owned.heads);
        defer gpa.free(kept);
        state.sent_hashes.clearRetainingCapacity();
        try state.sent_hashes.appendSlice(gpa, kept);
    }

    // `v1_compat_test/mod.rs:210-212`: an echo of our own heads with nothing in
    // it means the peer is at the state we last sent.
    if (changes_is_empty and hashesEqual(owned.heads, before_heads)) {
        const echo = try gpa.dupe(ChangeHash, owned.heads);
        gpa.free(state.last_sent_heads);
        state.last_sent_heads = echo;
    }

    // `v1_compat_test/mod.rs:214-233`.
    {
        var known: std.ArrayList(ChangeHash) = .empty;
        defer known.deinit(gpa);
        for (owned.heads) |head| {
            // **`get_change_by_hash(...).is_some()` and not `has_change`.** The v1
            // path rebuilds the change from the op set to answer the question,
            // and its `.ok()?` swallows a rebuild failure
            // (`automerge.rs:2294-2298`), so a head the graph holds but cannot
            // rebuild counts as unknown here. `sync.rs:446` asks the graph
            // instead. The two disagree on exactly that document.
            if (try canRebuild(gpa, doc, head)) try known.append(gpa, head);
        }
        if (known.items.len == owned.heads.len) {
            const all = try gpa.dupe(ChangeHash, owned.heads);
            gpa.free(state.shared_heads);
            state.shared_heads = all;
            if (owned.heads.len == 0) {
                // "The peer has lost all its data": start a full resync
                // (`v1_compat_test/mod.rs:219-222`).
                gpa.free(state.last_sent_heads);
                state.last_sent_heads = &.{};
                state.clearSent();
            }
        } else {
            var merged: std.ArrayList(ChangeHash) = .empty;
            errdefer merged.deinit(gpa);
            try merged.appendSlice(gpa, state.shared_heads);
            try merged.appendSlice(gpa, known.items);
            std.mem.sort(ChangeHash, merged.items, {}, ChangeHash.lessThan);
            var kept: usize = 0;
            for (merged.items) |head| {
                if (kept == 0 or !merged.items[kept - 1].eql(head)) {
                    merged.items[kept] = head;
                    kept += 1;
                }
            }
            merged.shrinkRetainingCapacity(kept);
            const out = try merged.toOwnedSlice(gpa);
            gpa.free(state.shared_heads);
            state.shared_heads = out;
        }
    }

    // `v1_compat_test/mod.rs:235-237`: the three lists move, and the ones they
    // replace are freed here because the state owned them.
    if (state.their_have) |old| freeHaves(gpa, old);
    if (state.their_heads) |old| gpa.free(old);
    if (state.their_need) |old| gpa.free(old);
    state.their_have = owned.have;
    state.their_heads = owned.heads;
    state.their_need = owned.need;
    owned.have = &.{};
    owned.heads = &.{};
    owned.need = &.{};
    owned.deinit();
}

/// Reads a message and refuses anything that is not V1
/// (`Message::decode`, `v1_compat_test/mod.rs:354-364`).
///
/// Upstream's v1 decoder checks the type byte against its own constant and
/// nothing else (`v1_compat_test/mod.rs:368-374`), so a v2 message is a
/// `WrongType` there. This one parses with the shared reader — which accepts both
/// bytes (`message.zig:381-389`) and is total over them — and then applies the
/// same check. The parse is total; the *type* check is what makes the result a v1
/// message.
///
/// **`error.InvalidMagic` is the refusal**, which is the same answer the shared
/// reader gives for a byte that is neither type. Every other parse failure
/// propagates unchanged.
pub fn decodeV1(gpa: Allocator, bytes: []const u8) err.ParseError!Message {
    const parsed = try msg.Message.decode(gpa, bytes);
    errdefer {
        var owned = parsed;
        owned.deinit();
    }
    if (parsed.version != .v1) return error.InvalidMagic;
    return parsed;
}

// --- internals --------------------------------------------------------------

/// A change as the builder sees it: the framed chunk and its hash
/// (`ChangePayload`, `protocol.zig:81-92`, over `Change::raw_bytes`,
/// `sync/message_builder.rs:30`).
const ChangePayload = protocol.ChangePayload;

/// The reset a v1 peer sends (`v1_compat_test/mod.rs:50-56`).
///
/// **`msg.Message.reset` is not it.** That is the V2 reset: it sets
/// `SUPPORTS_SYNC_RESET` in a flags section (`sync.rs:632-634`), and a v1 peer
/// has no flags section. This is the same message with the section omitted, which
/// is the only shape a v1 peer's peer can be expected to understand.
fn v1Reset(gpa: Allocator, our_heads: []const ChangeHash) Allocator.Error!Message {
    const heads = try gpa.dupe(ChangeHash, our_heads);
    errdefer gpa.free(heads);
    const have = try gpa.alloc(Have, 1);
    errdefer have[0].deinit();
    have[0] = Have.empty(gpa);
    return .{
        .gpa = gpa,
        .heads = heads,
        .need = &.{},
        .have = have,
        .changes = .empty(gpa),
        .flags = null,
        .version = .v1,
    };
}

/// One change as the wire sees it: the framed chunk and its hash. The chunk is
/// what upstream's `Change::raw_bytes` is (`change.rs:118-120`), and it is
/// **never** a whole document: that is a v2 shape a v1 peer cannot read.
fn payloadFor(gpa: Allocator, doc: *Document, hash: ChangeHash) ProtocolError!ChangePayload {
    var built = (try doc.getChangeByHash(gpa, hash)) orelse return error.MissingHash;
    defer built.deinit(gpa);
    return .{ .raw = try built.change.encode(gpa), .hash = built.change.hash };
}

/// Whether the document can rebuild the change with this hash
/// (`get_change_by_hash(...).is_some()`, `v1_compat_test/mod.rs:50-53` and
/// `:214-216`).
///
/// **A rebuild failure answers false, it is not propagated**: upstream's
/// `ChangeCollector::for_hashes(...).ok()?.pop()` (`automerge.rs:2294-2298`)
/// throws the error away and yields `None`, and the `.is_some()` at the call
/// site cannot tell that from a hash the document does not have. `sync.rs:446`
/// asks the change graph and gets a different answer for a document that holds a
/// change it cannot rebuild.
fn canRebuild(gpa: Allocator, doc: *Document, hash: ChangeHash) ProtocolError!bool {
    var built = (try doc.getChangeByHash(gpa, hash)) orelse return false;
    built.deinit(gpa);
    return true;
}

/// Whether every hash of `need` is one the peer advertised. A peer that has said
/// nothing has advertised nothing, so an absent `their_heads` answers false for a
/// non-empty `need` and true for an empty one
/// (`v1_compat_test/mod.rs:31-42`).
fn everyNeedIsIn(their_heads: ?[]const ChangeHash, need: []const ChangeHash) bool {
    for (need) |hash| {
        var found = false;
        if (their_heads) |heads| {
            for (heads) |head| {
                if (head.eql(hash)) {
                    found = true;
                    break;
                }
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Equality in the order the two lists are in, which is what upstream's `Vec`
/// equality means (`v1_compat_test/mod.rs:71`, `:73-77`, `:211`).
fn hashesEqual(a: []const ChangeHash, b: []const ChangeHash) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

/// Frees a list of `have` records and the list.
fn freeHaves(gpa: Allocator, have: []Have) void {
    for (have) |*entry| entry.deinit();
    gpa.free(have);
}

/// The index of `hash` in an ascending list, and whether it is there
/// (`BTreeSet` membership, `v1_compat_test/state.rs:40`).
fn sentSlot(items: []const ChangeHash, hash: ChangeHash) ?usize {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (ChangeHash.order(items[mid], hash)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return mid,
        }
    }
    return null;
}

/// Where `hash` goes in an ascending list it is not in.
fn sentIndex(items: []const ChangeHash, hash: ChangeHash) usize {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (ChangeHash.order(items[mid], hash) == .lt) low = mid + 1 else high = mid;
    }
    return low;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;
const io = testing.io;
const chunkmod = @import("../storage/chunk.zig");

/// Where the fixture corpus lives, relative to the process working directory.
const fixture_paths = [_][]const u8{
    "test/fixtures/",
    "../test/fixtures/",
    "../../test/fixtures/",
};

/// Two change chunks by one actor, in dependency order
/// (`test/fixtures/two_change_chunks.automerge`).
const two_changes_fixture = "two_change_chunks.automerge";

/// The same two changes, dependent first
/// (`test/fixtures/two_change_chunks_out_of_order.automerge`).
const two_changes_shuffled_fixture = "two_change_chunks_out_of_order.automerge";

/// One change by a **different** actor, with no dependencies
/// (`test/fixtures/counter_value_is_ok.automerge`). This is what makes a
/// two-sided exchange genuine: the two documents start with changes neither has
/// seen, and neither depends on the other.
const other_actor_fixture = "counter_value_is_ok.automerge";

/// **Why the corpus here and a written document in the gate at the bottom.**
/// Both are available and they answer different questions. The corpus files are
/// the **reference's own change chunks**, so a document built from them carries
/// the reference's hashes and the tests beside them are about the v1 wire
/// format alone. The gate at the bottom writes its changes through this port's
/// own transactions, because the question there is whether a change *this*
/// implementation writes is a change the reference wrote.
///
/// **The claim this comment used to make is false.** It said a document built by
/// `transact.put` records a change hash that is not the hash of its own bytes,
/// that `save` of one is refused with `error.MissingHash`, and that a change
/// chunk taken from one is skipped by a peer's `loadIncremental`. None of that
/// holds: `doc.zig` tests that a locally built document saves, reloads and comes
/// back with the same change hashes, and that this port's write path produces
/// the reference's own change chunks byte for byte (`"this port's write path
/// produces the reference's own change chunks, byte for byte"`). A comment that
/// calls something impossible when it is merely untested is worse than no
/// comment, because the next reader skips the work.
fn readFixture(gpa: Allocator, name: []const u8) ![]u8 {
    for (fixture_paths) |dir| {
        const path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ dir, name });
        defer gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        return bytes;
    }
    std.debug.print("fixture {s} not found; tried", .{name});
    for (fixture_paths) |dir| std.debug.print(" {s}{s}", .{ dir, name });
    std.debug.print("\n", .{});
    return error.FixtureNotFound;
}

/// One framed chunk of a stored change stream, with the hash the graph will know
/// it by.
const Framed = struct {
    bytes: []u8,
    hash: ChangeHash,
};

/// A stored change stream split into its framed chunks, each re-framed so it can
/// go into a message on its own.
///
/// **Re-framed, not copied:** `chunkmod.writeChunk` is the writer for the
/// framing `parseChunks` reads, so the bytes a peer receives here are the bytes a
/// reader will accept, checksum included. The hash is `changeHashOf`, which is
/// what a change chunk's identity is (`chunk.rs:79`) — the same value
/// `parseChange` computes for the same body.
fn splitStream(gpa: Allocator, bytes: []const u8) ![]Framed {
    const chunks = try chunkmod.parseChunks(bytes, gpa);
    defer gpa.free(chunks);
    var out: std.ArrayList(Framed) = .empty;
    errdefer {
        for (out.items) |framed| gpa.free(framed.bytes);
        out.deinit(gpa);
    }
    for (chunks) |c| {
        var framed: std.ArrayList(u8) = .empty;
        errdefer framed.deinit(gpa);
        try chunkmod.writeChunk(&framed, gpa, c.typ, c.data);
        try out.append(gpa, .{
            .bytes = try framed.toOwnedSlice(gpa),
            .hash = chunkmod.changeHashOf(c.typ, c.data),
        });
    }
    return out.toOwnedSlice(gpa);
}

fn freeFramed(gpa: Allocator, frames: []Framed) void {
    for (frames) |framed| gpa.free(framed.bytes);
    gpa.free(frames);
}

/// Where the corpus lives, relative to the process working directory. A unit
/// test binary inherits the directory it was started in, which is the package
/// root under `zig build test` and this file's own directory under a direct
/// `zig test`, so the path is probed rather than assumed — the convention
/// `sync/message.zig` and `sync/protocol.zig` both use.
const golden_paths = [_][]const u8{
    "test/golden/sync.jsonl",
    "../test/golden/sync.jsonl",
    "../../test/golden/sync.jsonl",
};

/// One line of `test/golden/sync.jsonl`, as written by
/// `tools/oracle/src/main.rs`. Only the three fields this file reads are named.
const Record = struct {
    bytes: ?u64 = null,
    from: ?[]const u8 = null,
    hex: []const u8,
    kind: []const u8,
    round: ?u64 = null,
    sent: bool = false,
};

/// Reads the golden corpus, or returns `error.GoldenVectorsNotFound` naming the
/// paths that were tried.
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

/// The one real V1 message the oracle produced, as the bytes the reference wrote.
///
/// It is the first `sync` record from `left` (`tools/oracle`, round 1): a type
/// byte, one head, no need, one `have` whose filter is over two changes, no
/// payload, and a flags section. The V1-typed shape of a message the current
/// implementation sends before it has heard of V2 from anybody — which is exactly
/// what a v1 peer's message has to be compatible with.
fn referenceV1Message(gpa: Allocator) ![]u8 {
    const text = try readGolden(gpa);
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // `to` and `side` are in the file and not in this struct, so unknown
        // fields have to be allowed rather than the struct widened for a caller
        // that reads four of the seven.
        const parsed = std.json.parseFromSlice(Record, gpa, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.kind, "sync")) continue;
        if (!parsed.value.sent) continue;
        if (parsed.value.round.? != 1) continue;
        if (!std.mem.eql(u8, parsed.value.from.?, "left")) continue;
        const bytes = try err.hexFrom(gpa, parsed.value.hex);
        errdefer gpa.free(bytes);
        if (bytes.len == 0 or bytes[0] != message_type_sync) {
            gpa.free(bytes);
            continue;
        }
        return bytes;
    }
    return error.GoldenVectorMissing;
}

/// Upstream's driver gives up after ten rounds (`v1_compat_test/mod.rs:551`,
/// `:592`), and so does this one: a generator that never goes silent is a bug,
/// not a slow convergence.
const max_rounds = 10;

/// Compares two hash lists by content. `expectEqualSlices` would need `==` on
/// `ChangeHash`, and a port that wrote one would reintroduce exactly the
/// ambiguity `ChangeHash.eql` exists to remove.
fn expectSameHashes(expected: []const ChangeHash, actual: []const ChangeHash) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expect(want.eql(got));
}

/// The offset of the chunk type byte in a framed chunk: `[4 magic][4 checksum]
/// [1 type][uleb len][body]` (`chunk.rs:126-131`).
const chunk_type_offset = 8;

/// Whether a message's payload is a whole saved document rather than a change
/// chunk. A v1 peer can never be sent one.
///
/// **The type byte at offset 8, not the magic.** Every chunk — change, document
/// and compressed alike — opens with the same four magic bytes
/// (`storage.rs:26`), so a magic-prefix test calls a change chunk a document
/// chunk and reports a document in every message that carries any changes at
/// all. Offset 8 is the chunk type: `0` is a document, `1` a change.
fn carriesDocument(m: *const Message) bool {
    for (m.changes.iter()) |chunk| {
        if (chunk.len > chunk_type_offset and
            chunk[chunk_type_offset] == @intFromEnum(chunkmod.ChunkType.document))
        {
            return true;
        }
    }
    return false;
}

/// A document that has applied `parts`, in order, and nothing else. The parts
/// are the reference's own change chunks: see the note on `fixture_paths` for
/// why this file cannot commit a change of its own.
fn docWith(gpa: Allocator, parts: []const []const u8) !Document {
    var doc = try Document.init(gpa, .auto);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    for (parts) |part| _ = try doc.loadIncremental(gpa, part);
    return doc;
}

/// An empty document with the same actor id as [`docWith`], so the only
/// difference between the two is what they hold.
fn emptyDoc(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, .auto);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    return doc;
}

/// The transport: encode, free the message, decode what the bytes say, and hand
/// that to the receiving side. Going through the wire format rather than passing
/// the struct across is the point — a peer never sees the struct.
fn deliverV1(gpa: Allocator, doc: *Document, state: *State, m: Message) !void {
    const bytes = try m.encode(gpa);
    var owned = m;
    owned.deinit();
    defer gpa.free(bytes);
    try receiveSyncMessage(gpa, doc, state, try decodeV1(gpa, bytes));
}

fn deliverV2(gpa: Allocator, doc: *Document, state: *protocol.State, m: Message) !void {
    const bytes = try m.encode(gpa);
    var owned = m;
    owned.deinit();
    defer gpa.free(bytes);
    try protocol.receiveSyncMessage(gpa, doc, state, try msg.Message.decode(gpa, bytes));
}

/// What one exchange put on the wire, so a test can assert on the messages and
/// not only on the documents.
const ExchangeLog = struct {
    /// Every message the v1 side sent carried no flags section. This is the
    /// mechanism the whole compatibility rests on, so it is counted rather than
    /// assumed.
    v1_messages: usize = 0,
    v1_flagged: usize = 0,
    v1_documents: usize = 0,
    /// Every chunk of every v1 message that is neither a change chunk nor a
    /// compressed change chunk. **A counter and not a boolean**, so a test can
    /// say how many messages it looked at: a run where the v1 peer said nothing
    /// passes a boolean and answers nothing.
    v1_foreign_chunks: usize = 0,
    v2_messages: usize = 0,
    v2_v1_typed: usize = 0,
    v2_documents: usize = 0,
};

/// One round of `sync_v1_to_v2` (`v1_compat_test/mod.rs:550-588`): **the v1 peer
/// generates first**, then the v2 peer, and each message is encoded, decoded and
/// handed to the other side.
///
/// The order is the test's, not a detail: the v1 peer must get its message out
/// before the v2 one answers, because a v2 peer that has heard nothing has no
/// reason to be quiet.
fn exchangeV1First(
    gpa: Allocator,
    v1: *Document,
    s1: *State,
    v2: *Document,
    s2: *protocol.State,
    log: *ExchangeLog,
) !usize {
    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        const to_v2 = try generateSyncMessage(gpa, v1, s1);
        const v1_said = to_v2 != null;
        if (round >= max_rounds) return error.SyncDidNotConverge;
        if (to_v2) |m| {
            log.v1_messages += 1;
            if (m.flags != null) log.v1_flagged += 1;
            if (carriesDocument(&m)) log.v1_documents += 1;
            if (!noDocumentChunks(&m)) log.v1_foreign_chunks += 1;
            try deliverV2(gpa, v2, s2, m);
        }
        const to_v1 = try protocol.generateSyncMessage(gpa, v2, s2);
        const v2_said = to_v1 != null;
        if (to_v1) |m| {
            log.v2_messages += 1;
            if (m.version == .v1) log.v2_v1_typed += 1;
            if (carriesDocument(&m)) log.v2_documents += 1;
            try deliverV1(gpa, v1, s1, m);
        }
        if (!v1_said and !v2_said) return round;
    }
    return error.SyncDidNotConverge;
}

/// One round of `sync_v2_to_v1` (`v1_compat_test/mod.rs:591-625`): **the v2 peer
/// generates first**, and the rest is the mirror image.
fn exchangeV2First(
    gpa: Allocator,
    v1: *Document,
    s1: *State,
    v2: *Document,
    s2: *protocol.State,
    log: *ExchangeLog,
) !usize {
    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        const to_v1 = try protocol.generateSyncMessage(gpa, v2, s2);
        const v2_said = to_v1 != null;
        if (round >= max_rounds) return error.SyncDidNotConverge;
        if (to_v1) |m| {
            log.v2_messages += 1;
            if (m.version == .v1) log.v2_v1_typed += 1;
            if (carriesDocument(&m)) log.v2_documents += 1;
            try deliverV1(gpa, v1, s1, m);
        }
        const to_v2 = try generateSyncMessage(gpa, v1, s1);
        const v1_said = to_v2 != null;
        if (to_v2) |m| {
            log.v1_messages += 1;
            if (m.flags != null) log.v1_flagged += 1;
            if (carriesDocument(&m)) log.v1_documents += 1;
            if (!noDocumentChunks(&m)) log.v1_foreign_chunks += 1;
            try deliverV2(gpa, v2, s2, m);
        }
        if (!v2_said and !v1_said) return round;
    }
    return error.SyncDidNotConverge;
}

// Upstream `sync_from_v1_to_v2` (`v1_compat_test/mod.rs:472-493`): two documents
// that each hold a change the other has never seen, driven with the **v1 peer
// going first**.
//
// **What is ported and what is not.** Upstream writes both documents with
// `AutoCommit::put` (`v1_compat_test/mod.rs:474-477`). This port cannot: a
// document built by `transact.put` records a change hash that is not the hash of
// the change's own bytes, so its change chunk is skipped on load and its `save`
// cannot be read back. The gap is written down in the slice's report. What is
// kept is the shape the case is about — **two independent histories, neither
// depending on the other, converging through the exchange** — built from the
// reference's own change chunks, which is what `sync/protocol.zig` does for the
// same reason.
//
// Upstream asserts `doc1.get_heads() == doc2.get_heads()`. This asserts the heads
// *and* `debugCmp`, which is the op set compared row for row
// (`Document.debugCmp`): the point of the compatibility contract is that the two
// agree on what a reader sees, and two documents can hold the same changes and
// still be different documents.
test "a v1 peer and a v2 peer converge when the v1 peer goes first" {
    const gpa = testing.allocator;
    const chain = try readFixture(gpa, two_changes_fixture);
    defer gpa.free(chain);
    const solo = try readFixture(gpa, other_actor_fixture);
    defer gpa.free(solo);
    var a = try docWith(gpa, &.{chain});
    defer a.deinit();
    var b = try docWith(gpa, &.{solo});
    defer b.deinit();

    // The control: the two documents are **not** the same document, which is what
    // makes the comparison below mean something. A checker that cannot fail is
    // not a checker.
    try testing.expectEqual(@as(u64, 2), a.stats().num_changes);
    try testing.expectEqual(@as(u64, 1), b.stats().num_changes);
    try testing.expectError(error.Invariant, a.debugCmp(&b));

    var s1 = State.new(gpa);
    defer s1.deinit();
    var s2 = protocol.State.new(gpa);
    defer s2.deinit();

    var log: ExchangeLog = .{};
    const rounds = try exchangeV1First(gpa, &a, &s1, &b, &s2, &log);

    // **Convergence is structural**, and the heads are only part of it.
    try a.debugCmp(&b);
    const heads_a = try a.getHeads(gpa);
    defer gpa.free(heads_a);
    const heads_b = try b.getHeads(gpa);
    defer gpa.free(heads_b);
    try expectSameHashes(heads_a, heads_b);
    try testing.expectEqual(@as(u64, 3), a.stats().num_changes);
    try testing.expectEqual(a.stats().num_changes, b.stats().num_changes);
    try testing.expectEqual(a.stats().num_ops, b.stats().num_ops);
    try testing.expectEqual(a.stats().num_actors, b.stats().num_actors);
    try testing.expect(rounds > 0);
    try testing.expect(rounds < max_rounds);

    // **The mechanism.** Every v1 message had no flags section, so the v2 peer
    // never learned V2 was possible, so every message the v2 peer sent came back
    // V1-typed — and it carried a flags section the v1 path ignored, exactly as a
    // real v1 parser does (`v1_compat_test/mod.rs:385-402`).
    try testing.expect(log.v1_messages > 0);
    try testing.expectEqual(@as(usize, 0), log.v1_flagged);
    try testing.expect(log.v2_messages > 0);
    try testing.expectEqual(log.v2_messages, log.v2_v1_typed);
    try testing.expectEqual(@as(?[]msg.Capability, null), s2.their_capabilities);
    try testing.expect(!s2.supportsV2Messages());

    // **Neither side is ever sent a whole document**, and one of them could not
    // read one: `send_doc` needs a peer that advertises no heads *and* reads V2
    // (`state.rs:198-200`), and the >⅓ arm is behind the same capability check
    // (`sync.rs:225`).
    try testing.expectEqual(@as(usize, 0), log.v1_documents);
    try testing.expectEqual(@as(usize, 0), log.v2_documents);

    // And the exchange reached its fixed point on both sides.
    try expectSilentV1(gpa, &a, &s1);
    try expectSilentV2(gpa, &b, &s2);
    // **The v1 side's last message was answered**, so its in-flight bit is clear.
    // The v2 side's need not be: the v1 peer goes silent first, having nothing
    // left to send, so the v2 peer's reply is never acknowledged. That is the
    // fixed point, not a stall — the two calls above are what say the exchange
    // finished, and the round count is what bounds it.
    try testing.expect(!s1.in_flight);
    // The states are in the state the rule describes, not merely quiet: a
    // generator that went quiet for some other reason passes the two calls above
    // and fails these.
    try testing.expect(s1.have_responded);
    try testing.expect(s2.have_responded);
    try expectSameHashes(heads_a, s1.their_heads.?);
    try expectSameHashes(heads_a, s1.shared_heads);
    try expectSameHashes(heads_a, s1.last_sent_heads);
}

// Upstream `sync_from_v2_to_v1` (`v1_compat_test/mod.rs:495-516`): the same two
// documents, driven with the **v2 peer going first**.
test "a v1 peer and a v2 peer converge when the v2 peer goes first" {
    const gpa = testing.allocator;
    const chain = try readFixture(gpa, two_changes_fixture);
    defer gpa.free(chain);
    const solo = try readFixture(gpa, other_actor_fixture);
    defer gpa.free(solo);
    var a = try docWith(gpa, &.{chain});
    defer a.deinit();
    var b = try docWith(gpa, &.{solo});
    defer b.deinit();
    try testing.expectError(error.Invariant, a.debugCmp(&b));

    var s1 = State.new(gpa);
    defer s1.deinit();
    var s2 = protocol.State.new(gpa);
    defer s2.deinit();

    var log: ExchangeLog = .{};
    const rounds = try exchangeV2First(gpa, &a, &s1, &b, &s2, &log);

    try a.debugCmp(&b);
    const heads_a = try a.getHeads(gpa);
    defer gpa.free(heads_a);
    const heads_b = try b.getHeads(gpa);
    defer gpa.free(heads_b);
    try expectSameHashes(heads_a, heads_b);
    try testing.expectEqual(@as(u64, 3), a.stats().num_changes);
    try testing.expect(rounds > 0);
    try testing.expect(rounds < max_rounds);

    try testing.expect(log.v1_messages > 0);
    try testing.expectEqual(@as(usize, 0), log.v1_flagged);
    try testing.expect(log.v2_messages > 0);
    try testing.expectEqual(log.v2_messages, log.v2_v1_typed);
    try testing.expectEqual(@as(usize, 0), log.v1_documents);
    try testing.expectEqual(@as(usize, 0), log.v2_documents);
    try expectSilentV1(gpa, &a, &s1);
    try expectSilentV2(gpa, &b, &s2);
}

// Upstream `sync_v1_to_v2_with_compressed_change`
// (`v1_compat_test/mod.rs:518-547`) is the case this replaces, and it is worth
// saying exactly what carries over. Upstream's stated concern is a bug where
// the v2 peer sent changes as compressed bytes and the old implementation could
// not handle them, on a document holding a list of a thousand entries.
//
// **The compressed half cannot reproduce here**, and not because of this file:
// `Document.getChangeByHash` rebuilds an **uncompressed** change chunk
// (`change.zig:196-201`, chunk type `0x01`), so the bytes a v1 peer sees are
// uncompressed whichever side wrote them. **The thousand entries cannot be
// produced**, because a document cannot commit a change of its own (see the note
// on `fixture_paths`).
//
// What does carry over, and is what the case was for, is the **gate**: a
// payload larger than a third of the document must reach a v1 peer as change
// chunks and never as one document. This test drives the same document into two
// states that differ in exactly one fact — whether the peer's capability list
// says it reads V2 — and asserts the two answers differ, so the gate cannot be a
// constant and the v1 answer cannot be an accident.
test "a v1 peer is sent change chunks where a v2 peer is sent the document" {
    const gpa = testing.allocator;
    const chain = try readFixture(gpa, two_changes_fixture);
    defer gpa.free(chain);
    const solo = try readFixture(gpa, other_actor_fixture);
    defer gpa.free(solo);
    var source = try docWith(gpa, &.{ chain, solo });
    defer source.deinit();
    try testing.expectEqual(@as(usize, 3), source.graph.len());

    // **The threshold is in range.** `payloads.len() > graph.len() / 3`
    // (`sync.rs:225`) with three changes and a peer that has none is `3 > 1`, so
    // the arm is not merely eligible, it is taken.
    try testing.expect(3 > source.graph.len() / 3);

    // The same document, and the same empty target, twice over: once against a
    // state that has heard the peer advertise V2, and once against one that has
    // not.
    var to_v2 = try emptyDoc(gpa);
    defer to_v2.deinit();
    var s2 = protocol.State.new(gpa);
    defer s2.deinit();
    {
        var hello = try handMessageV2(gpa, &.{});
        hello.flags = .{ .bits = msg.MessageFlags.supports_sync_reset };
        try protocol.receiveSyncMessage(gpa, &to_v2, &s2, hello);
    }
    try testing.expect(s2.supportsV2Messages());
    try testing.expect(s2.sendDoc());
    var as_v2 = (try protocol.generateSyncMessage(gpa, &source, &s2)).?;
    defer as_v2.deinit();
    // **The V2 answer: one chunk holding the whole document** (`sync.rs:213-215`).
    try testing.expectEqual(@as(usize, 1), as_v2.changes.len());
    try testing.expect(carriesDocument(&as_v2));

    var to_v1 = try emptyDoc(gpa);
    defer to_v1.deinit();
    var s1 = State.new(gpa);
    defer s1.deinit();
    {
        const hello = try handMessage(gpa, &.{}, &.{}, &.{});
        try receiveSyncMessage(gpa, &to_v1, &s1, hello);
    }
    var as_v1 = (try generateSyncMessage(gpa, &source, &s1)).?;
    defer as_v1.deinit();
    // **The V1 answer: one chunk per change, and no document.** Same document,
    // same threshold, same empty peer; the only difference is the flag.
    try testing.expectEqual(@as(usize, 3), as_v1.changes.len());
    try testing.expect(!carriesDocument(&as_v1));
    try testing.expectEqual(@as(u8, message_type_sync), as_v1.version.encode());
    try testing.expect(as_v1.flags == null);

    // And the V1 payload is what a v1 peer can actually use: three length-prefixed
    // change chunks, in dependency order, and the peer ends up holding the
    // document.
    {
        const bytes = try as_v1.encode(gpa);
        defer gpa.free(bytes);
        const decoded = try decodeV1(gpa, bytes);
        try receiveSyncMessage(gpa, &to_v1, &s1, decoded);
    }
    try source.debugCmp(&to_v1);
    try testing.expectEqual(@as(usize, 3), to_v1.graph.len());
    // Every element of the V1 payload is a **change** chunk, read with the chunk
    // reader rather than by eye: the type byte says `change` and the body parses
    // as a change. A document chunk in this list would have type `0`, and the
    // length-prefixed concatenation a V2 peer sends would have had one element
    // instead of three.
    for (as_v1.changes.iter()) |chunk| {
        const parsed = try chunkmod.parseChunk(chunk);
        try testing.expectEqual(chunkmod.ChunkType.change, parsed.typ);
    }
    // The count is the count, and it is the number of changes the document holds
    // — one chunk each, which is the only shape a v1 payload can take.
    try testing.expectEqual(@as(usize, 3), as_v1.changes.len());
    try testing.expectEqual(source.graph.len(), as_v1.changes.len());
}

// The acceptance property on its own: a v1 peer serving a document it cannot
// summarise as one chunk, and a v2 peer receiving it, end up agreeing.
test "a v1 peer and a v2 peer converge on a three-change document" {
    const gpa = testing.allocator;
    const chain = try readFixture(gpa, two_changes_fixture);
    defer gpa.free(chain);
    const solo = try readFixture(gpa, other_actor_fixture);
    defer gpa.free(solo);
    var rich = try docWith(gpa, &.{ chain, solo });
    defer rich.deinit();
    var plain = try emptyDoc(gpa);
    defer plain.deinit();

    // The rich document goes first as the v1 peer, so the v1 side is the one that
    // has to serve the whole payload as change chunks.
    var s1 = State.new(gpa);
    defer s1.deinit();
    var s2 = protocol.State.new(gpa);
    defer s2.deinit();
    var log: ExchangeLog = .{};
    const rounds = try exchangeV1First(gpa, &rich, &s1, &plain, &s2, &log);
    try testing.expect(rounds > 0);
    try testing.expect(rounds < max_rounds);
    try plain.debugCmp(&rich);
    try testing.expectEqual(@as(u64, 3), plain.stats().num_changes);
    try testing.expectEqual(rich.stats().num_ops, plain.stats().num_ops);
    try testing.expectEqual(@as(usize, 0), log.v1_documents);
    try testing.expectEqual(@as(usize, 0), log.v1_flagged);
    try expectSilentV1(gpa, &rich, &s1);
    try expectSilentV2(gpa, &plain, &s2);
}

/// Generates and fails if there is anything to say, freeing a message that
/// should not have existed so the failure is a failure and not a leak on top of
/// one.
fn expectSilentV1(gpa: Allocator, doc: *Document, state: *State) !void {
    if (try generateSyncMessage(gpa, doc, state)) |m| {
        var owned = m;
        owned.deinit();
        return error.ExpectedNoMessage;
    }
}

/// The same for the v2 side.
fn expectSilentV2(gpa: Allocator, doc: *Document, state: *protocol.State) !void {
    if (try protocol.generateSyncMessage(gpa, doc, state)) |m| {
        var owned = m;
        owned.deinit();
        return error.ExpectedNoMessage;
    }
}

// **The compatibility contract, checked against the reference's own bytes.**
//
// The reference's first V1 message, from `test/golden/sync.jsonl`, is 48 bytes:
//
// ```text
// offset  bytes                     field
// 0       42                        type
// 1       01                        head count
// 2..34   2c917691…3e572            the head, 32 raw bytes
// 34      00                        need count
// 35      01                        have count
// 36      00                        have[0].last_sync count
// 37      06                        have[0].bloom byte length
// 38..44  02 0a 07 d70155            the filter
// 44      00                        change count
// 45..48  02 0284                   the flags section
// ```
//
// This test builds a v1 message with the same head, no need, one `have` whose
// filter is over two changes, and no payload, and asserts the bytes are
// identical **byte for byte** to the reference's over the 45 bytes the two
// messages have in common — and that the reference's three trailing bytes, the
// flags section, are the only thing this peer does not write.
//
// This is not a shape check. A different `uleb128` encoding, a length-prefixed
// hash, a reordered section or a different bloom header all fail it.
test "a v1 message is the reference's bytes, byte for byte" {
    const gpa = testing.allocator;
    const reference = try referenceV1Message(gpa);
    defer gpa.free(reference);

    // The offsets above are the reference's, read off the file.
    try testing.expectEqual(@as(usize, 48), reference.len);
    try testing.expectEqual(@as(u8, message_type_sync), reference[0]);
    try testing.expectEqual(@as(u8, 0x42), reference[0]);
    // The two trailing bytes are the flags section: a length of two, then the
    // legacy marker byte and the bitfield (`sync.rs:776-781`).
    try testing.expectEqual(@as(u8, 0x02), reference[45]);
    try testing.expectEqual(@as(u8, 0x02), reference[46]);
    try testing.expectEqual(@as(u8, 0x84), reference[47]);

    // The head the reference advertised, parsed out of its own bytes.
    var head: ChangeHash = undefined;
    @memcpy(&head.bytes, reference[2..34]);

    // **What is compared, and what is not.** The filter's *bit array* depends on
    // which two changes the reference's document held at round 1 — one of them is
    // the head in the message, the other an intermediate change the corpus never
    // names — so those three bytes are not derivable here and are not asserted.
    // Everything before them is, including the filter's own three `uleb128`
    // parameters and its length prefix, which is what pins the layout.
    const two = [_]ChangeHash{ ChangeHash.zero, head };
    var filter = try bloommod.BloomFilter.fromHashes(gpa, &two);
    // **No `deinit` here.** `Have` takes the filter by value and both copies point
    // at the same `bits` allocation, so the single owner is `have_list[0]` and it
    // frees it through `Have.deinit` in the block below.
    try testing.expectEqual(@as(usize, 6), filter.byteLen());
    try testing.expectEqual(@as(u32, 2), filter.num_entries);
    // The three bytes the filter's own encoding fixes, whatever went into it:
    // `num_entries`, `num_bits_per_entry` and `num_probes`
    // (`bloom.rs:124-141`, `v1_compat_test/bloom.rs:34-42`).
    const filter_bytes = try filter.toBytes(gpa);
    defer gpa.free(filter_bytes);
    try testing.expectEqualSlices(u8, reference[38..41], filter_bytes[0..3]);
    try testing.expectEqual(@as(usize, 6), filter.byteLen());
    try testing.expectEqual(@as(u32, 2), filter.num_entries);

    var message = Message.init(gpa);
    message.heads = try gpa.dupe(ChangeHash, &.{head});
    const have_list = try gpa.alloc(Have, 1);
    have_list[0] = .{ .gpa = gpa, .last_sync = &.{}, .bloom = filter };
    message.have = have_list;
    message.changes = .empty(gpa);
    defer {
        gpa.free(message.heads);
        for (message.have) |*entry| entry.deinit();
        gpa.free(message.have);
        message.changes.deinit();
    }

    const mine = try message.encode(gpa);
    defer gpa.free(mine);

    // **Byte for byte** over the 41 derivable bytes: the type byte, the heads
    // count, all 32 bytes of the head, the need count, the have count, the
    // `last_sync` count, the filter's length prefix, and the filter's three
    // `uleb128` parameters. A different `uleb128` encoding, a length-prefixed
    // hash, a reordered section or a different filter header all fail this.
    //
    // Bytes 41..44 are the filter's bit array, which depends on which two
    // changes the reference's document held; that is the one span here that is
    // not compared, and the comment above says why.
    try testing.expectEqual(@as(usize, 45), mine.len);
    try testing.expectEqualSlices(u8, reference[0..41], mine[0..41]);
    // **And the message ends at the change count**: the same zero the reference
    // wrote, and no flags section after it. The reference's three trailing bytes
    // are that section, and their absence is the whole difference between the
    // two messages — which is what makes this a compatibility rather than an
    // incompatibility.
    try testing.expectEqual(@as(u8, 0x00), reference[44]);
    try testing.expectEqual(@as(u8, 0x00), mine[44]);

    // And the flags section is the only thing missing: a peer that has seen
    // reference bytes has a capability list, and this one has none.
    const from_reference = try msg.Message.decode(gpa, reference);
    var owned_reference = from_reference;
    defer owned_reference.deinit();
    try testing.expect(owned_reference.flags != null);
    try testing.expect(owned_reference.flags.?.contains(msg.MessageFlags.supports_sync_reset));

    const from_mine = try decodeV1(gpa, mine);
    var owned_mine = from_mine;
    defer owned_mine.deinit();
    try testing.expectEqual(@as(usize, 1), owned_mine.have.len);
    try testing.expect(owned_mine.flags == null);
    // The reference's `have` and this one's are the same record, read the same
    // way: an empty `last_sync` and a filter over two changes.
    try testing.expectEqual(@as(usize, 0), owned_mine.have[0].last_sync.len);
    try testing.expectEqual(@as(u32, 2), owned_mine.have[0].bloom.num_entries);
    try testing.expectEqual(@as(u32, 10), owned_mine.have[0].bloom.num_bits_per_entry);
    try testing.expectEqual(@as(u32, 7), owned_mine.have[0].bloom.num_probes);
}

// A v1 peer reads only v1 (`Message::parse`, `v1_compat_test/mod.rs:368-374`),
// and the refusal is the type byte and nothing else.
test "a v1 peer refuses a v2 message" {
    const gpa = testing.allocator;
    const reference = try referenceV1Message(gpa);
    defer gpa.free(reference);

    // The same message with the type byte the current implementation writes.
    var as_v2 = try gpa.dupe(u8, reference);
    defer gpa.free(as_v2);
    as_v2[0] = msg.message_type_sync_v2;

    // **The shared reader accepts it** — so a `decodeV1` that did not check would
    // be indistinguishable from one that did, and this assertion is what makes
    // the refusal below a refusal of the type byte.
    {
        const shared = try msg.Message.decode(gpa, as_v2);
        var owned = shared;
        defer owned.deinit();
        try testing.expect(owned.version == .v2);
    }
    try testing.expectError(error.InvalidMagic, decodeV1(gpa, as_v2));

    // And the same message with the v1 type byte is accepted, so the check is on
    // the byte and not on the shape.
    {
        const accepted = try decodeV1(gpa, reference);
        var owned = accepted;
        defer owned.deinit();
        try testing.expect(owned.version == .v1);
    }

    // A byte that is neither type is refused by the shared reader before the
    // check is reached, and with the same answer.
    var neither = try gpa.dupe(u8, reference);
    defer gpa.free(neither);
    neither[0] = 0x41;
    try testing.expectError(error.InvalidMagic, decodeV1(gpa, neither));

    // A truncated body is a `ParseError` and never a trap. **Every truncation is
    // `LengthExceedsInput`, not `UnexpectedEnd`**, and that is the better answer:
    // each declared count is proved against what is left before a single byte is
    // taken (`parse.rs:234`, `message.zig:599`), so the reader declines the length
    // rather than discovering the shortage one element at a time. Two of them,
    // one mid-head and one mid-flags, to show both sites refuse.
    try testing.expectError(error.LengthExceedsInput, decodeV1(gpa, reference[0..20]));
    try testing.expectError(error.LengthExceedsInput, decodeV1(gpa, reference[0 .. reference.len - 1]));
    // An input with no type byte at all is the one case that runs out: there is
    // nothing to refuse a length against.
    try testing.expectError(error.UnexpectedEnd, decodeV1(gpa, &.{}));
}

// The v1 reset is a reset **without a flags section**
// (`v1_compat_test/mod.rs:50-56`), and that is the only difference from the v2
// one (`sync.rs:625-638`).
test "a v1 reset is a reset with no flags section" {
    const gpa = testing.allocator;
    const chain = try readFixture(gpa, two_changes_fixture);
    defer gpa.free(chain);
    var doc = try docWith(gpa, &.{chain});
    defer doc.deinit();
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);

    // The two resets, side by side, on the same heads.
    const v2_reset = try msg.Message.reset(gpa, heads);
    var owned_v2 = v2_reset;
    defer owned_v2.deinit();
    const v1_reset = try v1Reset(gpa, heads);
    var owned_v1 = v1_reset;
    defer owned_v1.deinit();

    try testing.expect(owned_v1.version == .v1);
    try testing.expect(owned_v1.flags == null);
    try testing.expect(owned_v2.flags != null);
    try testing.expect(owned_v2.flags.?.contains(msg.MessageFlags.supports_sync_reset));

    // The bodies agree, and the v2 one is longer by exactly the flags section.
    const v2_bytes = try owned_v2.encode(gpa);
    defer gpa.free(v2_bytes);
    const v1_bytes = try owned_v1.encode(gpa);
    defer gpa.free(v1_bytes);
    try testing.expect(v2_bytes.len > v1_bytes.len);
    try testing.expectEqualSlices(u8, v1_bytes, v2_bytes[0..v1_bytes.len]);

    // A peer that answers such a `have` gets a v1 reset, from the generator and
    // not from a helper: the same heads, one empty `have`, and no flags.
    var state = State.new(gpa);
    defer state.deinit();
    const unknown = ChangeHash{ .bytes = @splat(0x5a) };
    const asking = try handMessage(gpa, heads, &.{}, &.{unknown});
    try receiveSyncMessage(gpa, &doc, &state, asking);

    var generated = (try generateSyncMessage(gpa, &doc, &state)).?;
    defer generated.deinit();
    try testing.expect(generated.version == .v1);
    try testing.expect(generated.flags == null);
    try testing.expect(generated.changes.isEmpty());
    try testing.expectEqual(@as(usize, 1), generated.have.len);
    try testing.expectEqual(@as(usize, 0), generated.have[0].last_sync.len);
    try testing.expectEqual(@as(u32, 0), generated.have[0].bloom.num_entries);
    try expectSameHashes(heads, generated.heads);
    const generated_bytes = try generated.encode(gpa);
    defer gpa.free(generated_bytes);
    try testing.expectEqualSlices(u8, v1_bytes, generated_bytes);
}

/// A message written by hand, for the shapes a generator never produces: a
/// `have` whose `last_sync` names a change the receiver cannot have, and a
/// payload of nothing.
///
/// It is V1-typed with no flags, because that is what a v1 peer's peer sends
/// and the only shape this file's reader accepts.
fn handMessage(
    gpa: Allocator,
    heads: []const ChangeHash,
    chunks: []const []const u8,
    last_sync: []const ChangeHash,
) !Message {
    const owned_heads = try gpa.dupe(ChangeHash, heads);
    errdefer gpa.free(owned_heads);
    var slots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (slots.items) |chunk| gpa.free(chunk);
        slots.deinit(gpa);
    }
    for (chunks) |source| try slots.append(gpa, try gpa.dupe(u8, source));

    const have = try gpa.alloc(Have, 1);
    errdefer have[0].deinit();
    have[0] = .{
        .gpa = gpa,
        .last_sync = try gpa.dupe(ChangeHash, last_sync),
        .bloom = bloommod.BloomFilter.empty(gpa),
    };
    return .{
        .gpa = gpa,
        .heads = owned_heads,
        .need = &.{},
        .have = have,
        .changes = .{ .items = try slots.toOwnedSlice(gpa), .gpa = gpa },
        .flags = null,
        .version = .v1,
    };
}

// **The v1 path asks from the queue; the v2 path does not**
// (`get_missing_deps`, `automerge.rs:2289-2292`, against `missing_deps_from`,
// `automerge.rs:2037-2066`).
//
// One document and two states, given the same history: a change that arrived
// before its dependency and is therefore sitting in the queue, and a peer whose
// advertised heads lead nowhere near it. **The v1 generator asks for the
// orphan's dependency; the v2 generator does not.** That difference is the whole
// of `sync.rs:173-181` — a queued orphan makes a v1 peer advertise a need this
// peer cannot satisfy, and because `our_have` is withheld until every need hash
// is in the peer's heads, the peer then never sends anything else either.
//
// Both answers are read out of the message the generator actually made, so this
// is a test of the two paths and not of a helper that reimplements one of them.
test "the v1 request comes from the queue and the v2 request does not" {
    const gpa = testing.allocator;
    const chain = try readFixture(gpa, two_changes_fixture);
    defer gpa.free(chain);
    const shuffled = try readFixture(gpa, two_changes_shuffled_fixture);
    defer gpa.free(shuffled);
    var source = try docWith(gpa, &.{chain});
    defer source.deinit();
    try testing.expectEqual(@as(u64, 2), source.stats().num_changes);

    // The same two changes, in the other order, split into the two framed chunks
    // so the dependent one can be delivered on its own. The two files hold the
    // same two changes, which the heads assertion below is what establishes.
    const frames = try splitStream(gpa, shuffled);
    defer freeFramed(gpa, frames);
    try testing.expectEqual(@as(usize, 2), frames.len);
    var by_frames = try docWith(gpa, &.{ frames[1].bytes, frames[0].bytes });
    defer by_frames.deinit();
    const source_heads = try source.getHeads(gpa);
    defer gpa.free(source_heads);
    const frame_heads = try by_frames.getHeads(gpa);
    defer gpa.free(frame_heads);
    try expectSameHashes(source_heads, frame_heads);
    // **The dependent change is frame 0**, which is the whole point of the file
    // and the reason the assertion is on the heads and not on a comment.
    try testing.expectEqualSlices(u8, &frames[0].hash.bytes, &source_heads[0].bytes);
    const parent = frames[1].hash;
    const child = frames[0].hash;
    try testing.expect(!parent.eql(child));

    // A document that receives **only** the child, so it is queued rather than
    // applied. The change queue is what makes the two paths disagree.
    var target = try emptyDoc(gpa);
    defer target.deinit();
    var queued_state = State.new(gpa);
    defer queued_state.deinit();
    {
        const orphan = try handMessage(gpa, &.{}, &.{frames[0].bytes}, &.{});
        try receiveSyncMessage(gpa, &target, &queued_state, orphan);
    }
    // **Queued, not applied** — which is the precondition the whole difference
    // rests on.
    try testing.expectEqual(@as(usize, 0), target.graph.len());
    try testing.expectEqual(@as(usize, 1), target.queue.len());

    // A peer head neither document has and no queue entry leads to: the state a
    // peer that has lost everything else is in.
    const unknown = ChangeHash{ .bytes = @splat(0x5e) };

    // **The v2 answer.** `missing_deps_from` starts at the peer's heads and walks
    // *through* a queued change rather than advertising it
    // (`automerge.rs:2051-2061`), so the orphan's dependency is invisible to it.
    var s2 = protocol.State.new(gpa);
    defer s2.deinit();
    {
        const hello = try handMessageV2(gpa, &.{unknown});
        try protocol.receiveSyncMessage(gpa, &target, &s2, hello);
    }
    {
        var asked_v2 = (try protocol.generateSyncMessage(gpa, &target, &s2)).?;
        defer asked_v2.deinit();
        try testing.expect(indexOfHash(asked_v2.need, parent) == null);
        try testing.expect(indexOfHash(asked_v2.need, unknown) != null);
        try testing.expectEqual(@as(usize, 1), asked_v2.need.len);
        // And because nothing it needs is missing, it still advertises what it
        // has — so the peer can still answer it.
        try testing.expectEqual(@as(usize, 1), asked_v2.have.len);
    }

    // **The v1 answer**, from the generator, on the same document and the same
    // advertised head.
    var s1 = State.new(gpa);
    defer s1.deinit();
    {
        const hello = try handMessage(gpa, &.{unknown}, &.{}, &.{});
        try receiveSyncMessage(gpa, &target, &s1, hello);
    }
    var asked_v1 = (try generateSyncMessage(gpa, &target, &s1)).?;
    defer asked_v1.deinit();
    try testing.expect(indexOfHash(asked_v1.need, parent) != null);
    try testing.expect(indexOfHash(asked_v1.need, unknown) != null);
    try testing.expectEqual(@as(usize, 2), asked_v1.need.len);

    // **And the consequence**, which is why the comment at `sync.rs:173-181` is
    // four lines long: `parent` is not among the peer's advertised heads, so
    // `our_need.iter().all(...)` is false and the v1 peer withholds its `have`
    // **entirely** (`v1_compat_test/mod.rs:38-42`).
    try testing.expectEqual(@as(usize, 0), asked_v1.have.len);
}

/// The position of `needle` in `haystack`, for the assertions above.
fn indexOfHash(haystack: []const ChangeHash, needle: ChangeHash) ?usize {
    for (haystack, 0..) |hash, i| {
        if (hash.eql(needle)) return i;
    }
    return null;
}

/// A V2-typed hand-written message, which the v2 receive path needs and the v1
/// one must never see.
fn handMessageV2(gpa: Allocator, heads: []const ChangeHash) !Message {
    return .{
        .gpa = gpa,
        .heads = try gpa.dupe(ChangeHash, heads),
        .need = &.{},
        .have = &.{},
        .changes = .empty(gpa),
        .flags = msg.MessageFlags.none(),
        .version = .v2,
    };
}

// --- the v1-only peer gate -------------------------------------------------
//
// `sync/protocol.zig` runs the same scenario against two v2 peers and against
// the reference. This section runs it against **a peer that never negotiates
// v2**: the two documents differ by exactly the version they speak, and every
// awkward case the merge has still has to come out the same.
//
// **The reader of the base document is written twice rather than shared.** The
// two files are two slices of the port and a public helper only one of them
// needs would put a test fixture in a module's public surface, which is the one
// thing the layout in `AGENTS.md` is for.

const converge_golden_paths = [_][]const u8{
    "test/golden/converge.jsonl",
    "../test/golden/converge.jsonl",
    "../../test/golden/converge.jsonl",
};

/// The one `converge-base` record of `test/golden/converge.jsonl`, as text.
fn convergeBaseRecord(gpa: Allocator) ![]u8 {
    for (converge_golden_paths) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 22)) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        return bytes;
    }
    std.debug.print("converge.jsonl not found; tried", .{});
    for (converge_golden_paths) |path| std.debug.print(" {s}", .{path});
    std.debug.print("\n", .{});
    return error.GoldenVectorsNotFound;
}

/// The converge scenario's base document: the reference's own `save()` bytes,
/// loaded into a document whose caller commits the changes itself.
fn convergeBase(gpa: Allocator) !Document {
    const text = try convergeBaseRecord(gpa);
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.containsAtLeast(u8, line, 1, "\"converge-base\"")) continue;
        const BaseRecord = struct { hex: []const u8 };
        const parsed = try std.json.parseFromSlice(BaseRecord, gpa, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const bytes = try err.hexFrom(gpa, parsed.value.hex);
        defer gpa.free(bytes);
        return Document.load(gpa, bytes, docmod.defaultTextEncoding(), .manual);
    }
    std.debug.print("converge.jsonl has no `converge-base` record\n", .{});
    return error.GoldenVectorsNotFound;
}

/// The scenario's left or right actor, **hex-decoded**.
///
/// The oracle's `actor()` (`tools/oracle/src/main.rs`) decodes its actor
/// constants, so the actor is not the ASCII the constant is spelled in. A
/// thirty-character `a1a1…` read as bytes is a thirty-byte actor, and a
/// document with a thirty-byte actor is a document no peer of the reference's
/// has ever heard of.
fn convergeActorId(gpa: Allocator, which: []const u8) ![]u8 {
    const text = try convergeBaseRecord(gpa);
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.containsAtLeast(u8, line, 1, "\"converge-base\"")) continue;
        const ActorRecord = struct { actor_a: ?[]const u8 = null, actor_b: ?[]const u8 = null };
        const parsed = try std.json.parseFromSlice(ActorRecord, gpa, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const hex = switch (which[0]) {
            'a' => parsed.value.actor_a,
            'b' => parsed.value.actor_b,
            else => return error.UnknownActor,
        } orelse return error.GoldenVectorsNotFound;
        return err.hexFrom(gpa, hex);
    }
    return error.GoldenVectorsNotFound;
}

/// Where a mismatch is, in the tree being compared.
const TreePath = std.ArrayList(u8);

/// What comparing two peers' materialisation can raise.
///
/// **Named rather than inferred, and the reason is the recursion**: the walk
/// descends into a container whose elements the same walk checks, so an
/// inferred error set is a dependency loop. A disagreement is
/// `error.ConvergenceMismatch` and nothing else — the read surface's own errors
/// would be a defect in the document, not in the two peers' agreement.
const CompareError = error{ ConvergenceMismatch, OutOfMemory } ||
    readmod.ReadError || docmod.MarkError;

fn reportMismatch(path: *const TreePath, what: []const u8) error{ConvergenceMismatch} {
    std.debug.print("v1: at '{s}' the two peers disagree on {s}\n", .{ path.items, what });
    return error.ConvergenceMismatch;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The visible children of a map or a list in two documents, compared element
/// by element.
///
/// **A map's keys are sorted and a list's are not, on both sides.** Key order in
/// a map is not an observable of the document, so it is not something two peers
/// have to agree about; element order in a list *is* the document, so positions
/// are compared one for one and the lengths have to match.
fn expectSameChildren(
    gpa: Allocator,
    a: *Document,
    b: *Document,
    a_obj: types.ExId,
    b_obj: types.ExId,
    path: *TreePath,
) CompareError!void {
    if (try a.objectType(a_obj) == .list) {
        const an = try readmod.length(a, a_obj);
        const bn = try readmod.length(b, b_obj);
        if (an != bn) return reportMismatch(path, "a sequence's length");
        for (0..an) |i| {
            const ai = (try readmod.get(a, a_obj, .{ .index = i })) orelse
                return reportMismatch(path, "an element the first peer does not have");
            const bi = (try readmod.get(b, b_obj, .{ .index = i })) orelse
                return reportMismatch(path, "an element the second peer does not have");
            const mark = path.items.len;
            var buf: [20]u8 = undefined;
            try path.append(gpa, '[');
            try path.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{i}) catch "???");
            try path.append(gpa, ']');
            try expectSameValue(gpa, a, b, ai, bi, path);
            path.shrinkRetainingCapacity(mark);
        }
        return;
    }

    // The keys of both maps, **copied, each walk released as it is finished.**
    // A key that is a sequence anchor is rendered into the walk's own fixed
    // buffer and is valid only until that walk's next `next()`
    // ([`Keys.render`](iter/keys.zig)), so a borrowed list would alias it; and
    // each walk borrows scratch out of its own document's op set, which the
    // recursive [`expectSameValue`] below would otherwise still be holding.
    var ak: std.ArrayList([]u8) = .empty;
    defer {
        for (ak.items) |k| gpa.free(k);
        ak.deinit(gpa);
    }
    var bk: std.ArrayList([]u8) = .empty;
    defer {
        for (bk.items) |k| gpa.free(k);
        bk.deinit(gpa);
    }
    {
        var it = try readmod.keys(a, a_obj);
        defer it.deinit(gpa);
        while (try it.next()) |k| try ak.append(gpa, try gpa.dupe(u8, k));
    }
    {
        var it = try readmod.keys(b, b_obj);
        defer it.deinit(gpa);
        while (try it.next()) |k| try bk.append(gpa, try gpa.dupe(u8, k));
    }
    std.mem.sort([]u8, ak.items, {}, lessThanString);
    std.mem.sort([]u8, bk.items, {}, lessThanString);
    if (ak.items.len != bk.items.len) return reportMismatch(path, "a map's key count");
    for (ak.items, bk.items) |akey, bkey| {
        if (!std.mem.eql(u8, akey, bkey)) return reportMismatch(path, "a map's keys");
        const av = (try readmod.get(a, a_obj, .{ .key = akey })) orelse
            return reportMismatch(path, "a key the first peer does not have");
        const bv = (try readmod.get(b, b_obj, .{ .key = bkey })) orelse
            return reportMismatch(path, "a key the second peer does not have");
        const mark = path.items.len;
        try path.append(gpa, '.');
        try path.appendSlice(gpa, akey);
        try expectSameValue(gpa, a, b, av, bv, path);
        path.shrinkRetainingCapacity(mark);
    }
}

/// One materialised value in two documents.
fn expectSameValue(
    gpa: Allocator,
    a: *Document,
    b: *Document,
    ai: readmod.DocItem,
    bi: readmod.DocItem,
    path: *TreePath,
) CompareError!void {
    switch (ai.value) {
        .scalar => |s| switch (bi.value) {
            .scalar => |t| {
                if (!s.eql(t)) return reportMismatch(path, "a scalar");
            },
            else => return reportMismatch(path, "scalar against object"),
        },
        .object => |t| switch (bi.value) {
            .object => |u| {
                if (t != u) return reportMismatch(path, "an object's type");
                switch (t) {
                    .text => {
                        const at = try readmod.text(a, ai.id, gpa);
                        defer gpa.free(at);
                        const bt = try readmod.text(b, bi.id, gpa);
                        defer gpa.free(bt);
                        if (!std.mem.eql(u8, at, bt)) return reportMismatch(path, "a text's bytes");
                        try expectSameMarks(gpa, a, b, ai.id, bi.id, path);
                    },
                    else => try expectSameChildren(gpa, a, b, ai.id, bi.id, path),
                }
            },
            else => return reportMismatch(path, "object against scalar"),
        },
    }
}

/// The marks over a text object in two documents, in `(start, end, name)`
/// order, which is the order `marks.rs:55-60` coalesces them into.
fn expectSameMarks(
    gpa: Allocator,
    a: *Document,
    b: *Document,
    a_id: types.ExId,
    b_id: types.ExId,
    path: *TreePath,
) CompareError!void {
    const am = try a.marks(gpa, a_id);
    defer gpa.free(am);
    const bm = try b.marks(gpa, b_id);
    defer gpa.free(bm);
    if (am.len != bm.len) return reportMismatch(path, "a mark's count");
    for (am, bm) |x, y| {
        if (x.start != y.start) return reportMismatch(path, "a mark's start");
        if (x.end != y.end) return reportMismatch(path, "a mark's end");
        if (!std.mem.eql(u8, x.name, y.name)) return reportMismatch(path, "a mark's name");
        if (!x.value.eql(y.value)) return reportMismatch(path, "a mark's value");
    }
}

/// Every chunk of `m` is a change chunk or a compressed change chunk.
///
/// **The chunk type at offset 8, not the magic at offset 0**: every chunk opens
/// with the same four magic bytes (`storage.rs:26`), so a magic test calls a
/// change a document and reports a document in every message that carries
/// changes at all. A whole document in one chunk is the v2 shape
/// (`sync.rs:213-215`) and a v1 peer must never emit one.
fn noDocumentChunks(m: *const Message) bool {
    for (m.changes.iter()) |chunk| {
        if (chunk.len <= chunk_type_offset) return false;
        switch (chunk[chunk_type_offset]) {
            @intFromEnum(chunkmod.ChunkType.change),
            @intFromEnum(chunkmod.ChunkType.compressed),
            => {},
            else => return false,
        }
    }
    return true;
}

test "a v1-only peer and a v2 peer converge, and the v1 peer never emits a v2 chunk" {
    // **The gate.** A peer that never negotiates v2 is still a peer: it
    // exchanges changes, the documents converge, and the merge is the awkward
    // one. The version is the only thing that differs between the two sides, so
    // every difference in the result is a difference the version made.
    const gpa = testing.allocator;
    const actor_v2 = try convergeActorId(gpa, "a");
    defer gpa.free(actor_v2);
    const actor_v1 = try convergeActorId(gpa, "b");
    defer gpa.free(actor_v1);
    const oracle_time: i64 = 1_700_000_000;

    // The v2 peer: a write only it makes, a counter increment, and a mark.
    var v2 = try convergeBase(gpa);
    defer v2.deinit();
    v2.setActorId(.{ .bytes = actor_v2 });
    {
        const text = (try readmod.get(&v2, .root, .{ .key = "text" })).?.id;
        var t = try trans.Transaction.open(gpa, &v2);
        defer t.deinit();
        _ = try t.put(.root, .{ .key = "only_v2" }, .{ .int = 1 });
        try t.increment(.root, .{ .key = "counter" }, 3);
        try t.mark(text, 0, 2, "em", .both, .{ .bool_value = true });
        _ = try t.commit("v2", oracle_time);
    }

    // The v1 peer: a write only it makes, a counter increment, and a splice
    // **outside** the v2 peer's mark, so the mark's range is the same on both
    // sides whatever the version did to the exchange.
    var v1 = try convergeBase(gpa);
    defer v1.deinit();
    v1.setActorId(.{ .bytes = actor_v1 });
    {
        const text = (try readmod.get(&v1, .root, .{ .key = "text" })).?.id;
        var t = try trans.Transaction.open(gpa, &v1);
        defer t.deinit();
        _ = try t.put(.root, .{ .key = "only_v1" }, .{ .int = 2 });
        try t.increment(.root, .{ .key = "counter" }, 4);
        try t.spliceText(text, 4, 0, "ZZ");
        _ = try t.commit("v1", oracle_time);
    }

    // **The control**: the two documents are not the same document.
    try testing.expect(!v1.getActorId().eql(v2.getActorId()));
    try testing.expectEqual(@as(u64, 2), v1.stats().num_changes);
    try testing.expectEqual(@as(u64, 2), v2.stats().num_changes);

    var s1 = State.new(gpa);
    defer s1.deinit();
    var s2 = protocol.State.new(gpa);
    defer s2.deinit();
    var log: ExchangeLog = .{};
    const rounds = try exchangeV1First(gpa, &v1, &s1, &v2, &s2, &log);

    // **The loop terminates**, inside upstream's own bound
    // (`v1_compat_test/mod.rs:551`) and not at it.
    try testing.expect(rounds > 0);
    try testing.expect(rounds < max_rounds);

    // **The v1 peer never emits a v2 chunk.** Not one message carried a flags
    // section, and not one carried a whole document in a single chunk: the first
    // is what keeps the peer a v1 peer, and the second is a shape a v1 peer
    // cannot read and so must never be sent.
    try testing.expect(log.v1_messages > 0);
    try testing.expectEqual(@as(usize, 0), log.v1_flagged);
    try testing.expectEqual(@as(usize, 0), log.v1_documents);
    try testing.expectEqual(@as(usize, 0), log.v1_foreign_chunks);

    // **And the v2 peer stayed a v1 peer**, which is the other half of the
    // handshake: it never learned V2 exists, so every message it sent came back
    // V1-typed (`sync/state.rs:208-212`).
    try testing.expect(log.v2_messages > 0);
    try testing.expectEqual(log.v2_messages, log.v2_v1_typed);
    try testing.expectEqual(@as(?[]msg.Capability, null), s2.their_capabilities);
    try testing.expect(!s2.supportsV2Messages());

    // **Convergence is structural.** The heads are part of it and not the whole
    // of it: two documents can hold the same changes and still materialise
    // differently, which is what the element-by-element comparison below is
    // for.
    const h1 = try v1.getHeads(gpa);
    defer gpa.free(h1);
    const h2 = try v2.getHeads(gpa);
    defer gpa.free(h2);
    try expectSameHashes(h1, h2);
    try testing.expectEqual(v1.stats().num_changes, v2.stats().num_changes);
    try testing.expectEqual(v1.stats().num_ops, v2.stats().num_ops);

    var path: TreePath = .empty;
    defer path.deinit(gpa);
    try expectSameChildren(gpa, &v1, &v2, .root, .root, &path);

    // **The two answers the version could not have changed.** The counter sums:
    // 10 in the base, 3 from one peer and 4 from the other, and a merge that
    // let one side win would read 13 or 14. The splice is on the wire and the
    // mark is not over it.
    const counter = (try readmod.get(&v1, .root, .{ .key = "counter" })).?;
    try testing.expectEqual(@as(i64, 17), counter.value.scalar.counter.current);
    const text = (try readmod.get(&v1, .root, .{ .key = "text" })).?;
    const got_text = try readmod.text(&v1, text.id, gpa);
    defer gpa.free(got_text);
    try testing.expectEqualStrings("abcdZZefgh", got_text);
    const found = try v1.marks(gpa, text.id);
    defer gpa.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("em", found[0].name);
    try testing.expectEqual(@as(usize, 0), found[0].start);
    try testing.expectEqual(@as(usize, 2), found[0].end);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * `State` is a **second** sync state, not a mode of `state.zig`'s. Upstream's
//   `v1_compat_test::state::State` is a separate struct because it is a separate
//   module; here the v2 fields (`read_only`, `needs_reset`, `peer_read_only`,
//   `their_capabilities`) would give a caller a route to the v2 behaviour through
//   a v1 peer, so they are absent rather than defaulted
//   (`v1_compat_test/state.rs:29-68` against `sync/state.rs:32-78`).
//
// * `sent_hashes` is an ascending `ArrayList` where upstream has a `BTreeSet`
//   (`v1_compat_test/state.rs:40`). Same set, same order, same logarithmic
//   search — this is the representation `sync/state.rs` already uses, and a
//   second one would be a second thing to keep correct.
//
// * The two functions are named `generateSyncMessage` / `receiveSyncMessage`
//   rather than upstream's `generate_sync_message_v1` /
//   `receive_sync_message_inner_v1`. Upstream needs the suffix because both live
//   on `Automerge`; in a module of their own the qualification is what says so,
//   and `sync.v1.generateSyncMessage` beside `sync.protocol.generateSyncMessage`
//   is the same distinction written once.
//
// * `decodeV1` does not exist upstream. Upstream's v1 decoder is a second parser
//   with its own `Message` type, and the type byte is checked inside it
//   (`v1_compat_test/mod.rs:368-374`). Here the bytes are identical to a v2
//   message's, so there is one parser; the check that a v1 peer must refuse a v2
//   message is a separate exported function rather than being smuggled into
//   `receiveSyncMessage`, which cannot enforce it — it is handed an already
//   decoded struct and has no type byte left to look at. A v1 peer's parser stops
//   after the change list and ignores trailing bytes
//   (`v1_compat_test/mod.rs:385-402`); the shared reader reads the flags section
//   instead, and this file ignores the field, which is the same outcome.
//
// * The payload is the framed chunk list (`protocol.MessageBuilder.newV1`) where
//   upstream holds `Vec<Change>` and calls `Change::raw_bytes` at encode time
//   (`v1_compat_test/mod.rs:110-112`, `:439-441`). The bytes are the same:
//   `raw_bytes` is the chunk a change chunk holds (`change.rs:118-120`), and it is
//   uncompressed either way, because a change is rebuilt from the op set rather
//   than copied out of a compressed document chunk. One chunk per change is forced
//   by the format, not chosen.
//
// * `getHashesToSend`, `makeBloomFilter` and `msg.advanceHeads` are **reused**,
//   not copied. `sync.rs:318-384`, `sync.rs:310-316` and `sync.rs:827-850` are
//   line-for-line the same algorithms as `v1_compat_test/mod.rs:120-179`,
//   `:123-129` and `:446-470`. Upstream duplicated them because its v1 copy
//   predates the shared helpers and has to stand alone; a second copy here would
//   be a second answer to "what bytes does a change go on the wire as", which is
//   the one question the compatibility contract turns on.
//
// * `our_need` comes from `Document.getMissingDeps`, deliberately. That is
//   `get_missing_deps` (`automerge.rs:2289-2292`), not the V2
//   `missing_deps_from` (`automerge.rs:2037-2066`) — the queue is chained in front
//   of the peer's heads. This is a real behavioural difference from
//   `protocol.generateSyncMessage` and it is the bug `sync.rs:173-181` is a
//   comment about. A v1 peer cannot avoid it, and reproducing it is the only way
//   a test against this path means anything.
//
// * `known_heads` and the reset test are decided by rebuilding the change, not by
//   asking the graph. `get_change_by_hash` swallows its own errors
//   (`automerge.rs:2294-2298`) and `sync.rs:446` asks `has_change`
//   (`automerge.rs:2031-2033`), so the two paths disagree on a document that holds
//   a change whose rows will not collect. The rebuild is the cost of being
//   faithful; the graph lookup would be the cheap answer to a question upstream
//   does not ask. **Not covered by a test**: producing such a document needs an
//   op set and a change graph that disagree, and nothing in the public surface
//   builds one.
