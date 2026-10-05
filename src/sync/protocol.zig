//! The document-side state machine of the sync protocol: the `SyncDoc` half.
//!
//! The wire format is `message.zig`, the per-peer bookkeeping is `state.zig`
//! and the filter is `bloom.zig`. What is left — what upstream spreads over
//! `impl SyncDoc for Automerge` (`sync.rs:166-307`), `make_bloom_filter`
//! (`sync.rs:310-316`), `get_hashes_to_send` (`sync.rs:318-384`),
//! `receive_sync_message_inner` (`sync.rs:386-464`) and the whole of
//! `sync/message_builder.rs` — is the part that **decides**: which changes go
//! on the wire, whether a message is generated at all, and what the peer's
//! bookkeeping becomes afterwards. That decision is what makes the protocol
//! terminate, so the clauses are written where they are evaluated rather than
//! only in this comment.
//!
//! The three things a reader must not get wrong:
//!
//! 1. **Silence is the common answer.** `generateSyncMessage` returns null
//!    whenever the heads have not moved, we have already responded, and either
//!    the peer's heads are our heads or the peer is read-only, and there is
//!    nothing to send; or whenever a message is already in flight
//!    (`sync.rs:242-249`). A generator that sends when it should be silent
//!    makes two peers talk forever.
//! 2. **`in_flight` is a bit, not a counter** (`state.rs:47-53`,
//!    `sync.rs:392`). It is cleared on receive and nowhere else, which is what
//!    the second clause above is for.
//! 3. **The shared heads advance from what we applied, not from what the peer
//!    claimed** (`sync.rs:423-427`, then `sync.rs:437-457`). A peer
//!    advertising a head we do not have leaves our shared heads exactly where
//!    they were, so a lagging or lying peer cannot corrupt the record of what
//!    was agreed.
//!
//! The version handshake has no message of its own at this commit: a peer that
//! sends the trailing flags section can read V2, and one that never sends one
//! cannot (`sync.rs:404-411`, `state.rs:208-212`). The half that **records**
//! what the peer sent is [`State.setTheirCapabilities`] with
//! [`State.capabilitiesFor`]; the half that **reads it back** is
//! [`State.supportsV2Messages`], which [`MessageBuilder.new`] consults to pick
//! the type byte; and the half that **writes** it is
//! [`MessageVersion.encode`](message.zig).
//!
//! **One allocator, not two.** Every allocation a [`State`], a [`Message`] or
//! a [`MessageBuilder`] holds or releases comes from the one `gpa` it was
//! built with, and every value that crosses a boundary here — the sets a
//! builder consumes, the three lists a receive moves into the state — is
//! released through that value's own `gpa`. A slice from a different
//! allocator, or a stack array, is freed by whichever teardown runs first.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const docmod = @import("../doc.zig");
const graphmod = @import("../change_graph.zig");
const bloommod = @import("bloom.zig");
const msg = @import("message.zig");
const statemod = @import("state.zig");
const chunkmod = @import("../storage/chunk.zig");

// The four below are used by the converge tests at the bottom of this file and
// by nothing else: they are the write surface and the read surface, and a sync
// test that does not write and does not read cannot check what a sync produced.
const trans = @import("../transact.zig");
const readmod = @import("../read.zig");
const optypes = @import("../opset/types.zig");
const marksmod = @import("../marks.zig");
const value = @import("../value.zig");

const Allocator = std.mem.Allocator;
const Error = err.Error;
const InternalError = err.InternalError;
const ChangeHash = types.ChangeHash;
// Named here so a test that writes a capability list directly does not have to
// spell out the element type of `State.their_capabilities`.
const Capability = msg.Capability;
/// One `have` record: a `last_sync` list and a bloom filter
/// (`Have`, `sync/state.rs:81-90`).
pub const Have = statemod.Have;

/// The per-peer state [`generateSyncMessage`] and [`receiveSyncMessage`] read
/// and write (`State`, `sync/state.rs:32-78`). Re-exported so a caller does
/// not have to reach into `state.zig` for it.
pub const State = statemod.State;

const Document = docmod.Document;

/// Everything a call in this file can return. Every part of it is one of the
/// three sets in `error.zig`: `DocumentError` is built out of `ParseError`,
/// `Error` and `InternalError`, and running out of memory is
/// `error.OutOfMemory` in all three.
pub const ProtocolError = docmod.DocumentError || Error || InternalError;

/// The record this file produces and consumes, re-exported so a caller does
/// not have to reach into `message.zig` for it.
pub const Message = msg.Message;

/// The first byte of a V1 sync message (`sync.rs:136`).
pub const message_type_sync: u8 = msg.message_type_sync;

/// The first byte of a V2 sync message (`sync.rs:137`).
pub const message_type_sync_v2: u8 = msg.message_type_sync_v2;

/// A change as the builder sees it: its framed chunk and its hash
/// (`Change`, `sync/message_builder.rs:30`).
///
/// **Borrowed.** `raw` is the framed change chunk, byte for byte what
/// `Change::raw_bytes` is upstream, and it is valid only while the buffer it
/// was built from is. The builder copies it, so a caller may free its
/// temporaries as soon as the builder exists.
pub const ChangePayload = struct {
    /// The framed change chunk (`change.zig:196`).
    raw: []const u8,
    /// The change's hash, `SHA-256(0x01 ‖ uleb128(len) ‖ body)`.
    hash: ChangeHash,
};

/// The version and chunk-shape decision, and the three fields every generated
/// message carries (`MessageBuilder`, `sync/message_builder.rs:7-118`).
///
/// Upstream builds this in a chain of consuming methods and ends with
/// `build`; here the setters move ownership into the builder and `build` moves
/// it out into a [`Message`], so the same sequence reads
/// `builder.setHeads(..); …; return builder.build()`. `deinit` frees whatever
/// `build` has not taken, which is what makes the early `return null` of a
/// suppressed message correct rather than a leak.
///
/// Single-threaded, as every type here is: no lock and no callback, so one
/// builder per message needs external synchronization between threads, and
/// nothing reenters. Copying the value copies slice headers over one set of
/// allocations, so two builders built from one another deinit the same bytes
/// twice.
pub const MessageBuilder = struct {
    /// The allocator every list in the builder was taken from and is released
    /// with. **It must be the caller's `gpa` for any slice a setter is given**,
    /// because `deinit` and the [`Message`] `build` returns free those slices
    /// through this value. It is borrowed for the life of the builder; the
    /// allocator itself is not owned.
    gpa: Allocator,
    /// The heads to write. Empty until [`MessageBuilder.setHeads`].
    heads: []ChangeHash = &.{},
    /// The changes this side is asking for. Empty until
    /// [`MessageBuilder.setNeed`].
    need: []ChangeHash = &.{},
    /// What this side says it has. Empty until [`MessageBuilder.setHave`].
    have: []Have = &.{},
    /// The payload chunks. `build` hands them to the message.
    chunks: msg.ChunkList,
    /// The hashes of the changes the payload carries, in payload order.
    ///
    /// This is the list `sent_hashes` is extended with (`sync.rs:253`) and the
    /// list [`MessageBuilder.isEmpty`] reads, and it is deliberately **not**
    /// the payload length: a whole-document message carries one chunk and
    /// every hash in the graph (`sync.rs:213-215`), so the two are
    /// independent facts.
    hashes: []ChangeHash,
    /// The trailing flags section, set by [`MessageBuilder.setFlags`].
    flags: ?msg.MessageFlags = null,
    /// The type byte this builder writes.
    version: msg.MessageVersion,

    /// A builder for `payloads` in the version the peer reads
    /// (`MessageBuilder::new`, `sync/message_builder.rs:18-24`).
    ///
    /// The version is the peer's to declare, not ours to choose. A peer that
    /// has never sent a flags section has no capability list
    /// (`state.rs:208-212`) and gets V1, one chunk per change. A peer that has
    /// sent one gets V2, where the same changes travel as a single chunk
    /// (`sync/message_builder.rs:55-63`). The body bytes are identical either
    /// way (`sync.rs:652-656`); only the type byte and the chunk count differ.
    pub fn new(
        gpa: Allocator,
        payloads: []const ChangePayload,
        state: *const State,
    ) Allocator.Error!MessageBuilder {
        if (state.supportsV2Messages()) return newV2FromChanges(gpa, payloads);
        return newV1(gpa, payloads);
    }

    /// One chunk per change, and a V1 type byte
    /// (`MessageBuilder::new_v1`, `sync/message_builder.rs:26-41`).
    pub fn newV1(gpa: Allocator, payloads: []const ChangePayload) Allocator.Error!MessageBuilder {
        var items: std.ArrayList([]u8) = .empty;
        errdefer {
            for (items.items) |item| gpa.free(item);
            items.deinit(gpa);
        }
        var hashes: std.ArrayList(ChangeHash) = .empty;
        errdefer hashes.deinit(gpa);
        for (payloads) |payload| {
            {
                const chunk = try gpa.dupe(u8, payload.raw);
                errdefer gpa.free(chunk);
                try items.append(gpa, chunk);
            }
            try hashes.append(gpa, payload.hash);
        }

        // Each allocation gets exactly one guard, and both guards are armed
        // before the last fallible step, so a success hands them to the
        // builder with nothing left to unwind.
        const owned_hashes = try hashes.toOwnedSlice(gpa);
        errdefer gpa.free(owned_hashes);
        const owned_items = try items.toOwnedSlice(gpa);
        errdefer {
            for (owned_items) |item| gpa.free(item);
            gpa.free(owned_items);
        }
        return .{
            .gpa = gpa,
            .chunks = .{ .items = owned_items, .gpa = gpa },
            .hashes = owned_hashes,
            .version = .v1,
        };
    }

    /// Every change concatenated into one chunk, and a V2 type byte
    /// (`MessageBuilder::new_v2_from_changes`,
    /// `sync/message_builder.rs:55-63`).
    ///
    /// An empty payload gives no chunk (`sync/message_builder.rs:66-67`),
    /// which is a V2 message with an empty `changes` section — not a V1 one.
    pub fn newV2FromChanges(
        gpa: Allocator,
        payloads: []const ChangePayload,
    ) Allocator.Error!MessageBuilder {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);
        var hashes: std.ArrayList(ChangeHash) = .empty;
        defer hashes.deinit(gpa);
        for (payloads) |payload| {
            try joined.appendSlice(gpa, payload.raw);
            try hashes.append(gpa, payload.hash);
        }

        const owned_hashes = try hashes.toOwnedSlice(gpa);
        errdefer gpa.free(owned_hashes);
        const owned_data = try joined.toOwnedSlice(gpa);
        errdefer gpa.free(owned_data);
        if (owned_data.len == 0) {
            return .{
                .gpa = gpa,
                .chunks = .empty(gpa),
                .hashes = owned_hashes,
                .version = .v2,
            };
        }
        const items = try gpa.alloc([]u8, 1);
        errdefer gpa.free(items);
        items[0] = owned_data;
        return .{
            .gpa = gpa,
            .chunks = .{ .items = items, .gpa = gpa },
            .hashes = owned_hashes,
            .version = .v2,
        };
    }

    /// One chunk holding `data` — a whole `save()` — and a V2 type byte
    /// (`MessageBuilder::new_v2`, `sync/message_builder.rs:65-78`).
    ///
    /// **Takes ownership of `data` and `hashes` on every path**, both returns
    /// included, because upstream takes them by value
    /// (`sync/message_builder.rs:65`) and this is the Zig shape of that. A
    /// caller that runs out of memory here has nothing left to unwind.
    ///
    /// Empty `data` gives no chunk and no hashes
    /// (`sync/message_builder.rs:66-67`), so the builder is empty by hash even
    /// though it has a version to write.
    pub fn newV2(
        gpa: Allocator,
        data: []u8,
        hashes: []ChangeHash,
    ) Allocator.Error!MessageBuilder {
        if (data.len == 0) {
            gpa.free(data);
            gpa.free(hashes);
            return .{ .gpa = gpa, .chunks = .empty(gpa), .hashes = &.{}, .version = .v2 };
        }
        const items = gpa.alloc([]u8, 1) catch |e| {
            gpa.free(data);
            gpa.free(hashes);
            return e;
        };
        items[0] = data;
        return .{
            .gpa = gpa,
            .chunks = .{ .items = items, .gpa = gpa },
            .hashes = hashes,
            .version = .v2,
        };
    }

    /// Whether there is nothing to send (`MessageBuilder::is_empty`,
    /// `sync/message_builder.rs:80-82`).
    ///
    /// **It is `hashes` and not `changes` that is tested**, and the difference
    /// is the whole reason a whole-document send is never suppressed: one
    /// chunk and every hash in the graph is a builder with a non-empty hash
    /// list.
    pub fn isEmpty(self: *const MessageBuilder) bool {
        return self.hashes.len == 0;
    }

    /// The hashes of the changes the payload carries
    /// (`MessageBuilder::hashes`, `sync/message_builder.rs:84-86`). Borrowed
    /// from the builder and valid until `build` or `deinit`.
    ///
    /// Named for what it returns rather than for what upstream calls it,
    /// because the field it reads is called `hashes` and a struct cannot have
    /// both.
    pub fn payloadHashes(self: *const MessageBuilder) []const ChangeHash {
        return self.hashes;
    }

    /// Takes `heads` as the message's heads
    /// (`MessageBuilder::heads`, `sync/message_builder.rs:88-91`).
    ///
    /// **Takes ownership of `heads`**: it must come from the builder's own
    /// `gpa`, and neither `deinit` nor a `build` that follows frees it twice —
    /// `build` moves it into the [`Message`], which then frees it, and
    /// `deinit` frees it when there is no `build`. A stack array or a slice
    /// from another allocator is freed by whichever of the two runs first.
    pub fn setHeads(self: *MessageBuilder, heads: []ChangeHash) void {
        self.heads = heads;
    }

    /// Takes `need` as the changes the message asks for
    /// (`MessageBuilder::need`, `sync/message_builder.rs:93-96`).
    ///
    /// **Takes ownership of `need`**, on the same terms as
    /// [`MessageBuilder.setHeads`].
    pub fn setNeed(self: *MessageBuilder, need: []ChangeHash) void {
        self.need = need;
    }

    /// Takes `have` as the message's `have` list
    /// (`MessageBuilder::have`, `sync/message_builder.rs:98-101`).
    ///
    /// **Takes ownership of the list and of every `Have` in it**: `have` must
    /// come from the builder's own `gpa`, and each entry must have been built
    /// with that same allocator, because `freeHaves` calls `Have.deinit` on
    /// each one on whichever of `deinit` and `build` runs first.
    pub fn setHave(self: *MessageBuilder, have: []Have) void {
        self.have = have;
    }

    /// Sets the trailing flags section
    /// (`MessageBuilder::flags`, `sync/message_builder.rs:103-106`). Takes a
    /// value, so there is no ownership to transfer; `null` is written by
    /// setting nothing.
    pub fn setFlags(self: *MessageBuilder, flags: msg.MessageFlags) void {
        self.flags = flags;
    }

    /// The message (`MessageBuilder::build`, `sync/message_builder.rs:108-117`).
    ///
    /// Moves `heads`, `need`, `have` and the chunks into it and clears them
    /// here, so a `defer builder.deinit()` on the caller's side frees only
    /// `hashes`. The caller owns the result and releases it with
    /// `Message.deinit`, or hands it to [`receiveSyncMessage`], which frees it
    /// and moves three of its lists into the [`State`].
    pub fn build(self: *MessageBuilder) Message {
        const out = Message{
            .gpa = self.gpa,
            .heads = self.heads,
            .need = self.need,
            .have = self.have,
            .changes = self.chunks,
            .flags = self.flags,
            .version = self.version,
        };
        self.heads = &.{};
        self.need = &.{};
        self.have = &.{};
        self.chunks = .empty(self.gpa);
        return out;
    }

    /// Frees everything `build` has not taken, and `hashes` always
    /// (`sync/message_builder.rs:7-15`).
    pub fn deinit(self: *MessageBuilder) void {
        self.gpa.free(self.heads);
        self.gpa.free(self.need);
        freeHaves(self.gpa, self.have);
        self.chunks.deinit();
        self.gpa.free(self.hashes);
        self.* = undefined;
    }
};

/// The next message for this peer, or null when there is nothing to say
/// (`Automerge::generate_sync_message`, `sync.rs:167-288`).
///
/// **The result is the fixed point of the exchange**, and getting the
/// suppression rule wrong is what makes two peers talk forever, so the
/// clauses are spelled out where they are evaluated. `null` is a real answer
/// and a caller must not substitute an empty message for it: an empty message
/// still tells the peer our heads and clears `in_flight`, so a peer that keeps
/// being told is a peer that keeps answering.
///
/// The state this reads and writes, in the order upstream touches it:
///
/// 1. `our_heads`, then `our_need` — which is empty in read-only mode
///    (`sync.rs:170-184`).
/// 2. `our_have` — one `have` built from `shared_heads`, and **only if every
///    change we need is in the peer's advertised heads** (`sync.rs:190-194`).
///    Withholding it is what stops a peer whose queue holds an orphan from
///    being able to answer anything else.
/// 3. A reset message, when the peer's *first* `have` names a change we do
///    not have (`sync.rs:196-205`). Only the first `have` is inspected, which
///    is upstream's rule and not a claim that it is a good one.
/// 4. The payload: nothing at all for a read-only peer, or before the first
///    message is received; the whole document when the peer has no heads and
///    reads V2; the changes the peer is missing otherwise
///    (`sync.rs:208-236`).
/// 5. The suppression test (`sync.rs:242-249`).
///
/// **The caller owns a non-null result** and releases it with
/// [`Message.deinit`], or hands it to [`receiveSyncMessage`], which frees it
/// and moves `heads`, `need` and `have` into `state`. `null` owns nothing. The
/// `Message` carries `state`'s own `gpa`, which must be the allocator `state`
/// and `doc` were built with.
///
/// **What an error leaves behind.** Nothing this call allocated survives it:
/// the builder is released before the error returns, and `state` is never left
/// holding a freed list, because `last_sent_heads` is replaced only from an
/// allocation that completed first (`sync.rs:251-253`). Nothing is rolled back
/// past that point, so a caller that retries may find `have_responded` already
/// set.
/// `sent_hashes` is **not** in that sentence any more: it is extended by
/// one `State.extendSent` over the whole payload hash list
/// (`protocol.zig:588`), and that is a single allocation, so either every hash
/// the message carries is in the set or none of them is. What no error path
/// reaches is the tail: `needs_reset` keeps its value until the heads that
/// carry the reset exist, and `in_flight` is never set.
pub fn generateSyncMessage(
    gpa: Allocator,
    doc: *Document,
    state: *State,
) ProtocolError!?Message {
    const our_heads = try doc.getHeads(gpa);
    defer gpa.free(our_heads);

    // `sync.rs:170-184`. A read-only side asks for nothing, and otherwise the
    // request is the first hash on each path back from **the peer's advertised
    // heads** that we have neither applied nor queued
    // (`missing_deps_from`, `automerge.rs:2037-2066`). This is deliberately
    // not `Document.getMissingDeps`: that chains the queue in front of the
    // heads and would advertise the dependencies of orphans this peer cannot
    // possibly satisfy, which blocks the sync outright
    // (`sync.rs:173-181`). The reason this file writes against the graph and
    // the queue rather than through the document is that
    // `Document.getMissingDeps` implements the *other* function,
    // `get_missing_deps` (`automerge.rs:2289-2292`), and the two differ in
    // exactly the start set.
    var our_need: []ChangeHash = &.{};
    errdefer gpa.free(our_need);
    if (!state.read_only) {
        var pending: std.ArrayList(graphmod.PendingChange) = .empty;
        defer pending.deinit(gpa);
        for (doc.queue.slice()) |queued| {
            try pending.append(gpa, .{ .hash = queued.hash, .deps = queued.deps });
        }
        our_need = try doc.graph.missingDepsFrom(
            gpa,
            state.their_heads orelse &.{},
            pending.items,
        );
    }

    // `sync.rs:190-194`. `all` over an empty `our_need` is true, so a
    // read-only side always advertises what it has.
    var our_have: []Have = &.{};
    errdefer freeHaves(gpa, our_have);
    if (everyNeedIsIn(state.their_heads, our_need)) {
        var entry = try makeBloomFilter(gpa, doc, state.shared_heads);
        errdefer entry.deinit();
        our_have = try gpa.alloc(Have, 1);
        our_have[0] = entry;
    }

    // `sync.rs:196-206`, in full:
    //
    //     if let Some(ref their_have) = sync_state.their_have {
    //         if let Some(first_have) = their_have.first().as_ref() {
    //             if !first_have.last_sync.iter().all(|h| self.has_change(h)) {
    //                 return Some(Message::reset(our_heads));
    //             }
    //         }
    //     }
    //
    // A peer whose **first** `have` names a change we do not have is talking
    // about a history we are not part of, and the answer is to start again.
    // Only the first record is inspected, which is upstream's rule and not a
    // claim that it is a good one.
    //
    // **An empty `their_have` is a real state, and the reference has one.**
    // `their_have.first()` is `None` on an empty `Vec`, so the whole block is
    // skipped and generation **continues** into `buildPayload`. Two reference
    // facts put a peer in that state:
    //
    // * a *restored* `State` comes back with `their_have: Some(vec![])`
    //   rather than `None` (`state.rs:139`), because a decoded state must
    //   answer `their()` where a fresh one does not (`state.rs:202-206`); and
    // * a **reset** message carries exactly one `Have` whose `last_sync` is
    //   empty (`sync.rs:625-638`, `Message::reset`), so the peer that receives
    //   one stores a one-element list it may not be able to read anything
    //   from.
    //
    // The answer is therefore **a real message**, built from `their_heads` and
    // `their_need` exactly as for any other peer — not a reset, and not
    // silence. Returning early on an empty list would strand a peer that has
    // synced before and came back; the two facts are different states and the
    // reference distinguishes them. The `len > 0` below is the `if let
    // Some(first_have)` and nothing more: it is the *shape* of the
    // discrimination, not a defence.
    if (state.their_have) |their_have| {
        if (their_have.len > 0) {
            for (their_have[0].last_sync) |hash| {
                if (!doc.graph.hasChange(hash)) {
                    // `Message.reset` **borrows** `our_heads` — it copies them
                    // into its own list (`message.zig:368-371`) — so the reset
                    // owns none of what was computed above, and `our_need` and
                    // `our_have` are released here.
                    //
                    // The `errdefer`s above do **not** do it on this path: this
                    // is a successful return, and an `errdefer` that only runs
                    // on failure is a leak on every early return.
                    //
                    // `try`, not a `catch` that frees: the failure path leaves
                    // both lists to the armed `errdefer`s, so they are freed
                    // exactly once either way. A `catch` that freed them here
                    // would free them twice, and a `catch` that emptied the
                    // locals instead would lose the only owner and leak both.
                    // The `builder.setNeed` below empties its locals instead,
                    // because there the builder **takes** the lists rather than
                    // borrowing them — the opposite of this arm.
                    const reset = try Message.reset(gpa, our_heads);
                    gpa.free(our_need);
                    freeHaves(gpa, our_have);
                    return reset;
                }
            }
        }
    }

    var builder = try buildPayload(gpa, doc, state);
    defer builder.deinit();
    // The request and the advertisement move into the builder before anything
    // else can fail, so the `return null` below cannot leak them and a later
    // error frees them exactly once, through `deinit`. The errdefers above see
    // the emptied locals and do nothing.
    builder.setNeed(our_need);
    builder.setHave(our_have);
    our_need = &.{};
    our_have = &.{};

    // `sync.rs:238-249`, in full. Both comparisons are order sensitive, as
    // upstream's `Vec` equality is.
    const heads_unchanged = hashesEqual(state.last_sent_heads, our_heads);
    const heads_equal = if (state.their_heads) |their| hashesEqual(their, our_heads) else false;
    if (heads_unchanged and state.have_responded) {
        // Nothing has moved, we have already said hello, and either the peer
        // is at our heads or we are read-only, and there is nothing to send.
        if ((heads_equal or state.read_only) and builder.isEmpty()) return null;
        // A message is already on its way. This is the clause that stops two
        // peers from looping, and it is a **bit**: it says "one is in flight",
        // not "two are".
        if (state.in_flight) return null;
    }

    // `sync.rs:251-253`. The new list is built before the old one is released,
    // so a failure here cannot leave the state holding a freed pointer.
    //
    // **The whole payload at once.** Upstream writes
    // `sent_hashes.extend(message_builder.hashes())` (`sync.rs:253`) into a
    // `BTreeSet`; this list is sorted, so the same call is
    // `State.extendSent(builder.payloadHashes())`. The list is the builder's own
    // and is borrowed here, not retained: `State.extendSent` copies it and
    // `defer builder.deinit()` below frees it.
    //
    // One hash at a time was a memmove of half the list per carried hash, which
    // is `O(k*n)` per message and `O(k^2 R^2)` over a session of `R`
    // unanswered messages. The batch costs one sort and one merge instead. A
    // caller outside this file needs no change for this: the loop that used to
    // stand here was the only caller of the single-hash insert.
    state.have_responded = true;
    const sent_heads = try gpa.dupe(ChangeHash, our_heads);
    gpa.free(state.last_sent_heads);
    state.last_sent_heads = sent_heads;
    try state.extendSent(builder.payloadHashes());

    // `sync.rs:255-259`. `flags` is attached unconditionally
    // (`sync.rs:283`), so **every** generated message carries a flags section
    // and the peer learns we read V2 from the very first message.
    var flags = msg.MessageFlags.none();
    flags.set(msg.MessageFlags.supports_sync_reset);
    if (state.read_only) flags.set(msg.MessageFlags.read_only);

    // `sync.rs:267-277`. Coming out of read-only, the peer has to forget what
    // it thinks it sent us. A peer that advertises sync-reset support is told
    // so with the flag; one that does not is sent empty heads, which drives
    // it into the "I have lost everything" path that clears the same thing
    // (`sync.rs:443-447`, and `switch_to_read_write_with_old_peer`,
    // `sync.rs:2452-2494`). `needs_reset` is consumed either way, **but only
    // once the heads that carry the reset exist**: a failure above returns with
    // the flag still set, so the next message carries the reset rather than
    // dropping it with nothing else to say that it was dropped.
    var heads_to_send: []ChangeHash = &.{};
    errdefer gpa.free(heads_to_send);
    if (state.needs_reset) {
        if (state.peerSupportsSyncReset()) {
            flags.set(msg.MessageFlags.sync_reset);
            heads_to_send = try gpa.dupe(ChangeHash, our_heads);
        } else {
            heads_to_send = try gpa.dupe(ChangeHash, &.{});
        }
        state.needs_reset = false;
    } else {
        heads_to_send = try gpa.dupe(ChangeHash, our_heads);
    }

    builder.setHeads(heads_to_send);
    builder.setFlags(flags);
    state.in_flight = true;
    return builder.build();
}

/// Applies what `message` carries and folds the peer's answers into `state`
/// (`Automerge::receive_sync_message_inner`, `sync.rs:386-464`).
///
/// The message is **taken by value and freed here**, after its `heads`, `need`
/// and `have` have moved into the state (`sync.rs:459-461`); the note on
/// `Message.deinit` says the same thing from the other side. The `changes`
/// are read, handed to [`Document.loadIncremental`], and freed with the
/// message.
///
/// The order below is load-bearing and is upstream's:
///
/// 1. `in_flight` is cleared **first**, before anything that can fail
///    (`sync.rs:392`), so a receive that fails still unblocks generation.
/// 2. The flags section, if there is one, replaces the peer's capability list
///    and carries two transient signals (`sync.rs:404-418`).
/// 3. The changes are applied and **only then** are the shared heads advanced
///    (`sync.rs:420-428`).
/// 4. `sent_hashes` is pruned by the peer's advertised heads
///    (`sync.rs:430-431`). **This is the acknowledgement.** There is no ack
///    message at this commit (`sync.rs:430`): a peer acknowledges by
///    advertising heads that descend from what it received.
/// 5. The shared heads become the peer's heads if we hold all of them, and
///    otherwise stay where they are with the ones we recognise added
///    (`sync.rs:437-457`).
///
/// `message` is freed on every path, the error path included, and the three
/// lists are moved into `state` only once nothing after the move can fail.
///
/// **What an error leaves behind.** `in_flight` is cleared on every path.
/// Everything else is in the order above, so an error reaches the caller with
/// whichever of these had already happened:
///
/// * `their_capabilities` is replaced first, all or nothing, and
///   `peer_read_only` and `sent_hashes` are written after it — so a failure
///   later in the same message keeps the peer's **new** capability list and
///   the `sent_hashes` that `sync_reset` cleared, and the previous
///   `peer_read_only` is already gone. A failure to duplicate the list itself
///   leaves the previous one in place.
/// * `shared_heads` is replaced only from an allocation that completed first,
///   so it is either the old list or the new one and never a freed pointer.
/// * **`sent_hashes` is the one field an error can empty**: it is cleared
///   before the pruned list is appended and the append is the fallible step
///   (`sync.rs:430-431`). An emptied set costs a resend, not a wrong answer.
/// * `their_have`, `their_heads` and `their_need` still hold what they held
///   before the call. The hand-over is the last thing the function does, and
///   nothing after it can fail.
/// * `doc` is whatever [`Document.loadIncremental`] made it, which is that
///   function's own contract and not restated here.
pub fn receiveSyncMessage(
    gpa: Allocator,
    doc: *Document,
    state: *State,
    message: Message,
) ProtocolError!void {
    return receiveSyncMessageImpl(gpa, doc, state, message, null);
}

/// Receives through the same protocol state machine with a borrowed external log.
/// Consumes `message` on every path. Actor mismatch leaves doc/state/log unchanged.
pub fn receiveSyncMessageWithPatchLog(
    gpa: Allocator,
    doc: *Document,
    state: *State,
    message: Message,
    log: *@import("../patches.zig").PatchLog,
) ProtocolError!void {
    return receiveSyncMessageImpl(gpa, doc, state, message, log);
}

fn receiveSyncMessageImpl(
    gpa: Allocator,
    doc: *Document,
    state: *State,
    message: Message,
    log: ?*@import("../patches.zig").PatchLog,
) ProtocolError!void {
    var owned = message;
    errdefer owned.deinit();
    if (log == null) state.in_flight = false;

    const before_heads = try doc.getHeads(gpa);
    defer gpa.free(before_heads);
    const changes_is_empty = owned.changes.isEmpty();
    if (log) |sink| {
        // Doc applies its branch-specific actor contract while loading once,
        // before peer flags or acknowledgement state can be published.
        if (!changes_is_empty and !state.read_only) {
            const joined = try owned.changes.join(gpa);
            defer gpa.free(joined);
            _ = try doc.loadIncrementalWithPatchLog(gpa, joined, sink);
        }
        state.in_flight = false;
    }

    // `sync.rs:404-418`. Capabilities are **replaced**, never accumulated, and
    // a message with no flags section leaves the previous list alone, so a
    // peer that once advertised V2 keeps it.
    if (owned.flags) |flags| {
        try state.setTheirCapabilities(State.capabilitiesFor(flags));
        // `sync.rs:414-416`: the peer is telling us to forget what it thinks
        // it has sent, because we ignored it while we were read-only.
        if (flags.contains(msg.MessageFlags.sync_reset)) state.clearSent();
        state.peer_read_only = flags.contains(msg.MessageFlags.read_only);
    }

    // `sync.rs:420-428`.
    if (!changes_is_empty and !state.read_only) {
        if (log == null) {
            const joined = try owned.changes.join(gpa);
            defer gpa.free(joined);
            _ = try doc.loadIncremental(gpa, joined);
        }
        const after_heads = try doc.getHeads(gpa);
        defer gpa.free(after_heads);
        // `advance_heads` (`sync.rs:827-850`): what we gained, plus the old
        // shared heads we still hold. It reads the **document's** heads, not
        // the peer's, and that is the whole of the rule.
        const advanced = try msg.advanceHeads(gpa, before_heads, after_heads, state.shared_heads);
        gpa.free(state.shared_heads);
        state.shared_heads = advanced;
    }

    // `sync.rs:430-431`: prune what the peer's heads already cover. A head the
    // document does not have is dropped first, as upstream filters it
    // (`automerge.rs:1211-1215`), and a candidate that is not one of this
    // graph's changes survives, as `remove_ancestors` leaves it
    // (`change_graph.rs:855-866`). The result is a **subsequence** of the input:
    // `filterChanges` walks `candidates` in order and appends each one at most
    // once (`change_graph.zig:1165-1174`), so a list that was ascending and
    // duplicate-free still is, and the prune cannot break the invariant
    // `State.extendSent` maintains.
    {
        const kept = try doc.graph.filterChanges(gpa, state.sent_hashes.items, owned.heads);
        defer gpa.free(kept);
        state.sent_hashes.clearRetainingCapacity();
        try state.sent_hashes.appendSlice(gpa, kept);
    }

    // `sync.rs:433-435`: an echo of our own heads with nothing in it means the
    // peer is at the state we last sent.
    if (changes_is_empty and hashesEqual(owned.heads, before_heads)) {
        const echo = try gpa.dupe(ChangeHash, owned.heads);
        gpa.free(state.last_sent_heads);
        state.last_sent_heads = echo;
    }

    // `sync.rs:437-457`.
    {
        var known: std.ArrayList(ChangeHash) = .empty;
        defer known.deinit(gpa);
        for (owned.heads) |head| {
            if (doc.graph.hasChange(head)) try known.append(gpa, head);
        }
        if (known.items.len == owned.heads.len) {
            // We hold everything the peer claims, so its heads are ours — as a
            // **set**, and in this file's order for one: `Message.parse` reads
            // the list in wire order and does not sort it
            // (`message.zig:640-645`), so a peer may advertise its heads in any
            // order at all. `shared_heads` is required to be ascending and
            // duplicate-free (`state.zig:227-230`, asserted by
            // `message.encodeHashes` at `message.zig:524-530`), which is what
            // the merge arm below and `message.advanceHeads` both produce.
            const all = try sortedUniqueHeads(gpa, owned.heads);
            gpa.free(state.shared_heads);
            state.shared_heads = all;
            if (owned.heads.len == 0) {
                // "The peer has lost all its data": start a full resync
                // (`sync.rs:443-447`).
                gpa.free(state.last_sent_heads);
                state.last_sent_heads = &.{};
                state.clearSent();
            }
        } else {
            // A head we do not have is not evidence of anything, so the shared
            // heads stay where they are with the recognised ones added. This
            // is the clause that keeps a lagging peer's advertisement from
            // moving the record of what was agreed.
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

    // `sync.rs:459-461`: the three lists move, and the ones they replace are
    // freed here because the state owned them.
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

/// The changes the peer is missing, each dependency before the change that
/// needs it (`Automerge::get_hashes_to_send`, `sync.rs:318-384`).
///
/// `have` is what the peer said it has and `need` is what it explicitly asked
/// for. The result is **owned by the caller** and is what
/// [`MessageBuilder`] turns into chunks, so its order is the order the chunks
/// go on the wire: `need` first, then the graph's own order
/// (`sync.rs:370-381`). A port that emitted chunks in hash-map order would
/// produce valid but different bytes, which is why neither arm below reads a
/// map's iteration order.
///
/// Repeated `need` entries remain repeated when `have` is empty, or when they
/// fall outside the derived graph selection. Entries in that graph selection
/// are emitted once in graph order (`sync.rs:323-329,370-381`).
///
/// Two things in here are easy to get wrong:
///
/// * the closure at `sync.rs:359-368` runs over **children**, not parents, so
///   it pulls in the descendants of everything being sent. Sending a change
///   without its descendants sends a change the peer cannot apply.
/// * a request for a change this document does not have is dropped, not
///   answered (`sync.rs:323-327`).
pub fn getHashesToSend(
    gpa: Allocator,
    doc: *Document,
    have: []const Have,
    need: []const ChangeHash,
) ProtocolError![]ChangeHash {
    // `sync.rs:323-327`.
    var wanted: std.ArrayList(ChangeHash) = .empty;
    defer wanted.deinit(gpa);
    for (need) |hash| {
        if (doc.graph.hasChange(hash)) try wanted.append(gpa, hash);
    }

    // `sync.rs:328-330`: with nothing to compare against, the answer is the
    // request.
    if (have.len == 0) return wanted.toOwnedSlice(gpa);

    // `sync.rs:331-339`: the union of every `last_sync`. A set, so a hash two
    // `have` records both name is taken once; the order does not matter,
    // because the graph folds the list into a clock and re-sorts.
    var last_sync: std.ArrayList(ChangeHash) = .empty;
    defer last_sync.deinit(gpa);
    var seen: HashSet = .empty;
    defer seen.deinit(gpa);
    for (have) |entry| {
        for (entry.last_sync) |hash| {
            if (seen.contains(hash)) continue;
            try seen.put(gpa, hash, {});
            try last_sync.append(gpa, hash);
        }
    }

    // `sync.rs:341`: the changes the peer's `last_sync` does not already
    // cover, in graph order, which is dependency order.
    const hashes = try doc.graph.getChanges(gpa, last_sync.items);
    defer gpa.free(hashes);

    // `dependents` inverts the parent edge: `dependents[dep]` is the list of
    // changes that need `dep` (`sync.rs:350-352`).
    var dependents: Dependents = .empty;
    defer {
        var values = dependents.valueIterator();
        while (values.next()) |list| list.deinit(gpa);
        dependents.deinit(gpa);
    }
    var to_send: HashSet = .empty;
    defer to_send.deinit(gpa);

    for (hashes) |hash| {
        // The walk borrows the graph's edge array and nothing here adds a
        // change, so the borrow holds for its length.
        var deps = doc.graph.depsForHash(hash);
        while (deps.next()) |dep| {
            const dep_hash = doc.graph.indexToHash(dep) orelse continue;
            const entry = try dependents.getOrPut(gpa, dep_hash);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(gpa, hash);
        }
        // `sync.rs:354-356`: **every** filter has to miss it, because any one
        // peer that claims to have it is a peer that will ignore it.
        var every_filter_misses = true;
        for (have) |entry| {
            if (entry.bloom.containsHash(hash)) {
                every_filter_misses = false;
                break;
            }
        }
        if (every_filter_misses) try to_send.put(gpa, hash, {});
    }

    // `sync.rs:359-368`.
    var stack: std.ArrayList(ChangeHash) = .empty;
    defer stack.deinit(gpa);
    {
        var keys = to_send.keyIterator();
        while (keys.next()) |key| try stack.append(gpa, key.*);
    }
    while (stack.pop()) |hash| {
        const children = dependents.get(hash) orelse continue;
        for (children.items) |child| {
            if (to_send.getOrPut(gpa, child)) |_| {} else |_| try stack.append(gpa, child);
        }
    }

    // `sync.rs:370-381`.
    var out: std.ArrayList(ChangeHash) = .empty;
    errdefer out.deinit(gpa);
    for (wanted.items) |hash| {
        if (!to_send.contains(hash)) try out.append(gpa, hash);
    }
    for (hashes) |hash| {
        if (to_send.contains(hash)) try out.append(gpa, hash);
    }
    return out.toOwnedSlice(gpa);
}

/// The `have` record for a message: the heads we last synced on, and a filter
/// over everything we have added since (`Automerge::make_bloom_filter`,
/// `sync.rs:310-316`).
///
/// **There is no persistent filter.** It is rebuilt from the change graph on
/// every generated message and lives exactly as long as the message
/// (`sync.rs:191`). `last_sync` is copied; the caller owns the result and frees
/// it with `deinit`.
pub fn makeBloomFilter(
    gpa: Allocator,
    doc: *Document,
    last_sync: []const ChangeHash,
) ProtocolError!Have {
    const hashes = try doc.graph.getChanges(gpa, last_sync);
    defer gpa.free(hashes);
    var filter = try bloommod.BloomFilter.fromHashes(gpa, hashes);
    errdefer filter.deinit();
    return .{
        .gpa = gpa,
        .last_sync = try gpa.dupe(ChangeHash, last_sync),
        .bloom = filter,
    };
}

// --- internals --------------------------------------------------------------

/// A change hash keyed map. The key is 32 bytes, so it is hashed as bytes
/// rather than field by field; the change graph and the change queue have the
/// same context, and theirs is private.
const HashContext = struct {
    pub fn hash(_: @This(), key: ChangeHash) u64 {
        return std.hash.Wyhash.hash(0, &key.bytes);
    }

    pub fn eql(_: @This(), a: ChangeHash, b: ChangeHash) bool {
        return a.eql(b);
    }
};

const HashSet = std.HashMapUnmanaged(ChangeHash, void, HashContext, 80);

/// A change hash to the changes that depend on it (`dependents`,
/// `sync.rs:344`). Each value owns its list.
const Dependents = std.HashMapUnmanaged(ChangeHash, std.ArrayList(ChangeHash), HashContext, 80);

/// The payload a message will carry, or the whole document
/// (`sync.rs:208-236`).
///
/// Split out of [`generateSyncMessage`] so that every temporary it allocates is
/// released before the caller can return null, and so what comes back is a
/// fully owned builder with nothing left to unwind.
fn buildPayload(
    gpa: Allocator,
    doc: *Document,
    state: *const State,
) ProtocolError!MessageBuilder {
    // `sync.rs:208-211`: the peer advertised `READ_ONLY`, so it will not
    // apply what we send. Nothing is computed and nothing is sent.
    if (state.isPeerReadOnly()) return MessageBuilder.new(gpa, &.{}, state);
    // `sync.rs:234-235`: before the first message is received there is nothing
    // to answer, so no changes go out.
    const their = state.their() orelse return MessageBuilder.new(gpa, &.{}, state);

    // `sync.rs:213-215`: the peer advertised no heads at all and can read one
    // chunk, so send the whole document rather than a change list.
    if (state.sendDoc()) return wholeDocument(gpa, doc);

    const all_hashes = try getHashesToSend(gpa, doc, their.have, their.need);
    defer gpa.free(all_hashes);

    // `sync.rs:221-224`: preserve selection order while excluding hashes
    // already sent. The allocated hash list is call-local and can be compacted.
    var selected_len: usize = 0;
    for (all_hashes) |hash| {
        if (sentContains(state, hash)) continue;
        all_hashes[selected_len] = hash;
        selected_len += 1;
    }
    const hashes = all_hashes[0..selected_len];

    // Choose the existing V2 snapshot before reconstructing any changes.
    // Count every selected occurrence, not unique hashes. Equality remains a
    // change batch (`sync.rs:225-231`).
    if (hashes.len > doc.graph.len() / 3 and state.supportsV2Messages()) {
        return wholeDocument(gpa, doc);
    }
    var changes = try doc.getChangesByHashes(gpa, hashes);
    defer changes.deinit(gpa);
    var payloads: std.ArrayList(ChangePayload) = .empty;
    // The builder copies the frames; every temporary remains ours until then.
    defer {
        for (payloads.items) |payload| gpa.free(payload.raw);
        payloads.deinit(gpa);
    }
    try payloads.ensureTotalCapacity(gpa, changes.len());
    for (changes.slice()) |built| {
        const raw = try built.change.encode(gpa);
        payloads.appendAssumeCapacity(.{ .raw = raw, .hash = built.change.hash });
    }
    return MessageBuilder.new(gpa, payloads.items, state);
}

/// The whole document as one chunk, and every hash in the graph
/// (`sync.rs:213-215`, `sync.rs:227-228`).
fn wholeDocument(gpa: Allocator, doc: *Document) ProtocolError!MessageBuilder {
    const hashes = try doc.graph.getChanges(gpa, &.{});
    // `newV2` takes ownership of both arguments on every path, so the only
    // step between the two allocations that can fail is this one, and it
    // unwinds itself.
    const data = doc.save(gpa) catch |e| {
        gpa.free(hashes);
        return e;
    };
    return MessageBuilder.newV2(gpa, data, hashes);
}

/// Whether `sent_hashes` holds `hash` (`sync.rs:223`). The list is ascending
/// and duplicate free — `State.extendSent` merges a message's hashes into
/// their sorted place, and the receive path rebuilds the list by filtering the
/// old one, which keeps that order — so this is the same logarithmic search the
/// upstream `BTreeSet` does.
fn sentContains(state: *const State, hash: ChangeHash) bool {
    const items = state.sent_hashes.items;
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (ChangeHash.order(items[mid], hash)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return true,
        }
    }
    return false;
}

/// Whether every hash of `need` is one the peer advertised. A peer that has
/// said nothing has advertised nothing, so an absent `their_heads` answers
/// false for a non-empty `need` and true for an empty one (`sync.rs:185-194`).
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
/// equality means (`sync.rs:238`, `sync.rs:240`, `sync.rs:433`).
fn hashesEqual(a: []const ChangeHash, b: []const ChangeHash) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

/// `heads` as this file stores a head set: ascending and duplicate-free.
///
/// A list that came off the wire is in the peer's order — `Message.parse`
/// appends in wire order and never sorts (`message.zig:640-645`) — so this is
/// where a peer's heads become the set `shared_heads` is documented to hold
/// (`state.zig:227-230`). It is the same set `message.advanceHeads` collects
/// upstream (`sync.rs:843-849`): sort, then drop the adjacent duplicates.
/// `heads` is borrowed and left alone; the caller owns the result.
fn sortedUniqueHeads(gpa: Allocator, heads: []const ChangeHash) ![]ChangeHash {
    var sorted: std.ArrayList(ChangeHash) = .empty;
    errdefer sorted.deinit(gpa);
    try sorted.appendSlice(gpa, heads);
    std.mem.sort(ChangeHash, sorted.items, {}, ChangeHash.lessThan);
    var kept: usize = 0;
    for (sorted.items) |head| {
        if (kept == 0 or !sorted.items[kept - 1].eql(head)) {
            sorted.items[kept] = head;
            kept += 1;
        }
    }
    sorted.shrinkRetainingCapacity(kept);
    return sorted.toOwnedSlice(gpa);
}

/// Frees a list of `have` records and the list.
fn freeHaves(gpa: Allocator, have: []Have) void {
    for (have) |*entry| entry.deinit();
    gpa.free(have);
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

/// Where the corpus lives, relative to the process working directory. A unit
/// test binary inherits the directory it was started in, which is the package
/// root under `zig build test` and this file's own directory under a direct
/// `zig test`, so the path is probed rather than assumed — the same convention
/// `sync/message.zig` uses.
const fixture_paths = [_][]const u8{
    "test/fixtures/",
    "../test/fixtures/",
    "../../test/fixtures/",
};

/// **Why the corpus here and a written document in the converge tests below.**
/// Both are available, and they answer different questions. The corpus files
/// are the **reference's own change chunks**, so a document built from them
/// carries the reference's hashes and the tests beside them are about the sync
/// state machine alone. The converge tests below write their changes through
/// this port's own transactions, because the question there is whether a change
/// *this* implementation writes is a change the reference wrote — and that a
/// locally committed change round-trips through `save` and a sync exchange, which
/// it does (`doc.zig`, "a locally built document saves, reloads, and comes back
/// with the same change hashes").
///
/// `test/golden/change.jsonl` is not one of the sources: those two chunks are
/// DEFLATE-wrapped. The two corpus files below are uncompressed.
const two_changes_fixture = "two_change_chunks.automerge";
const two_changes_out_of_order_fixture = "two_change_chunks_out_of_order.automerge";
const other_actor_fixture = "counter_value_is_ok.automerge";

/// The automerge chunk magic (`storage.rs:26`).
///
/// **The magic does not tell a document from a change.** Every framed chunk
/// opens with it, a change chunk included, so a payload that starts with it
/// has told us nothing yet. What tells them apart is the chunk-type byte at
/// [`chunk_type_offset`], and upstream discriminates on exactly that: it
/// parses the chunk and matches `Chunk::Document` (`sync.rs:1404-1407`).
const chunk_magic = [_]u8{ 0x85, 0x6f, 0x4a, 0x83 };

/// Where the chunk-type byte sits in a framed chunk: four of magic
/// (`storage.rs:26`), four of checksum (`chunk.rs:180-185`), then the type
/// itself (`chunk.rs:126-131`). A chunk shorter than this has no type and so
/// is not a document.
const chunk_type_offset = chunk_magic.len + types.checksum_size;

/// Upstream's driver gives up after ten rounds (`sync.rs:1354`, `:1375-1377`),
/// and so does this one: a generator that never goes silent is a bug, not a
/// slow convergence.
const max_rounds = 10;

/// Reads `name` from the first of `dirs` that holds a readable copy, or fails
/// naming the directories that were tried.
///
/// **Probed, not assumed**: a unit test binary inherits the directory it was
/// started in, which is the package root under `zig build test` and this file's
/// own directory under a direct `zig test`, so the same file has three plausible
/// spellings. The join is `{dir}{name}` with `dir` carrying the separator,
/// because the corpus and the golden files are addressed by **directory plus
/// name** and by **whole path** respectively, and conflating the two is how a
/// reader ends up asking for a directory.
fn readFrom(gpa: Allocator, dirs: []const []const u8, name: []const u8) ![]u8 {
    for (dirs) |dir| {
        const path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ dir, name });
        defer gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            path,
            gpa,
            .limited(1 << 22),
        ) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        return bytes;
    }
    std.debug.print("no {s} at any of", .{name});
    for (dirs) |dir| std.debug.print(" {s}{s}", .{ dir, name });
    std.debug.print("\n", .{});
    return error.GoldenVectorsNotFound;
}

/// Reads a corpus file, or fails naming the paths that were tried.
fn readFixture(gpa: Allocator, name: []const u8) ![]u8 {
    return readFrom(gpa, &fixture_paths, name);
}

/// Two change chunks by one actor, in dependency order
/// (`test/fixtures/two_change_chunks.automerge`).
fn twoChangeStream(gpa: Allocator) ![]u8 {
    return readFixture(gpa, two_changes_fixture);
}

/// The same two changes, dependent first
/// (`test/fixtures/two_change_chunks_out_of_order.automerge`).
fn outOfOrderStream(gpa: Allocator) ![]u8 {
    return readFixture(gpa, two_changes_out_of_order_fixture);
}

/// One change by a **different** actor, with no dependencies
/// (`test/fixtures/counter_value_is_ok.automerge`). This is what makes a
/// two-sided exchange genuine: the two documents start with changes neither has
/// seen, and neither depends on the other.
fn otherActorChange(gpa: Allocator) ![]u8 {
    return readFixture(gpa, other_actor_fixture);
}

/// One framed chunk of a stored change stream, with the hash the graph will
/// know it by.
const Framed = struct {
    bytes: []u8,
    hash: ChangeHash,
};

/// A stored change stream split into its framed chunks, each re-framed so it
/// can go into a message on its own.
/// This is a fixture helper, not the live sync message path.
///
/// **Re-framed, not copied:** `chunkmod.writeChunk` is the writer for the
/// framing `ChunkStream` reads, so the bytes a peer receives here are the bytes
/// a reader will accept, checksum included. The hash is `changeHashOf`, which is
/// what a change chunk's identity is (`chunk.rs:300-312`) — the same value
/// `parseChange` computes for the same body.
fn splitStream(gpa: Allocator, bytes: []const u8) ![]Framed {
    var stream = chunkmod.ChunkStream.init(bytes);
    var out: std.ArrayList(Framed) = .empty;
    errdefer {
        for (out.items) |framed| gpa.free(framed.bytes);
        out.deinit(gpa);
    }
    while (try stream.next()) |c| {
        var framed: std.ArrayList(u8) = .empty;
        errdefer framed.deinit(gpa);
        try chunkmod.writeChunk(&framed, gpa, c.typ, c.data);
        const owned = try framed.toOwnedSlice(gpa);
        errdefer gpa.free(owned);
        try out.append(gpa, .{
            .bytes = owned,
            .hash = chunkmod.changeHashOf(c.typ, c.data),
        });
    }
    return out.toOwnedSlice(gpa);
}

fn freeFramed(gpa: Allocator, frames: []Framed) void {
    for (frames) |framed| gpa.free(framed.bytes);
    gpa.free(frames);
}

fn splitStreamAndFree(gpa: Allocator, bytes: []const u8) !void {
    const frames = try splitStream(gpa, bytes);
    defer freeFramed(gpa, frames);
}

fn splitStreamRejectLater(gpa: Allocator, bytes: []const u8) !void {
    const frames = splitStream(gpa, bytes) catch |failure| switch (failure) {
        error.InvalidMagic => return,
        else => return failure,
    };
    defer freeFramed(gpa, frames);
    return error.TestUnexpectedResult;
}

test "protocol splitStream spends only the required frame output allocation budget" {
    // Measure the writer and output-vector costs separately from parsing.
    // The fixture payloads are the same change streams used by message tests.
    const gpa = testing.allocator;
    for ([_][]const u8{ two_changes_out_of_order_fixture, other_actor_fixture }) |name| {
        const bytes = try readFixture(gpa, name);
        defer gpa.free(bytes);
        const chunks = try chunkmod.parseChunks(bytes, gpa);
        defer gpa.free(chunks);
        var output_cost: testing.FailingAllocator = .init(gpa, .{});
        const counted_output = output_cost.allocator();
        var vector: std.ArrayList(Framed) = .empty;
        defer vector.deinit(counted_output);
        for (chunks) |c| {
            var frame: std.ArrayList(u8) = .empty;
            defer frame.deinit(counted_output);
            try chunkmod.writeChunk(&frame, counted_output, c.typ, c.data);
            const owned = try frame.toOwnedSlice(counted_output);
            defer counted_output.free(owned);
            try vector.append(counted_output, .{
                .bytes = &.{},
                .hash = chunkmod.changeHashOf(c.typ, c.data),
            });
        }
        const owned_vector = try vector.toOwnedSlice(counted_output);
        defer counted_output.free(owned_vector);

        var actual_cost: testing.FailingAllocator = .init(gpa, .{});
        const counted_actual = actual_cost.allocator();
        const frames = try splitStream(counted_actual, bytes);
        defer freeFramed(counted_actual, frames);
        try testing.expectEqual(chunks.len, frames.len);
        for (chunks, frames) |c, framed| {
            try testing.expectEqualSlices(u8, c.frame, framed.bytes);
            try testing.expect(chunkmod.changeHashOf(c.typ, c.data).eql(framed.hash));
            try testing.expect(c.frame.ptr != framed.bytes.ptr);
        }
        try testing.expectEqual(output_cost.alloc_index, actual_cost.alloc_index);
        try testing.checkAllAllocationFailures(gpa, splitStreamAndFree, .{bytes});

        // A later bad header must discard frames already produced by the stream.
        const malformed = try std.mem.concat(gpa, u8, &.{ bytes, &.{ 0, 0, 0, 0 } });
        defer gpa.free(malformed);
        try splitStreamRejectLater(gpa, malformed);
        try testing.checkAllAllocationFailures(gpa, splitStreamRejectLater, .{malformed});
    }
}

/// A document that has applied `parts`, in order.
fn docWith(gpa: Allocator, parts: []const []const u8) !Document {
    var doc = try Document.init(gpa, std.testing.io);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    for (parts) |part| _ = try doc.loadIncremental(gpa, part);
    return doc;
}

/// The transport: encode, free the message, decode what the bytes say, and
/// hand that to [`receiveSyncMessage`]. Going through the wire format rather
/// than passing the struct across is the point — a peer never sees the struct.
fn deliver(gpa: Allocator, doc: *Document, state: *State, m: Message) !void {
    const bytes = try m.encode(gpa);
    var owned = m;
    owned.deinit();
    defer gpa.free(bytes);
    const decoded = try Message.decode(gpa, bytes);
    try receiveSyncMessage(gpa, doc, state, decoded);
}

/// A message written by hand, for the shapes a generator never produces: a peer
/// that advertises no capabilities, a payload of one specific change, a head
/// the receiver cannot possibly have.
fn handMessage(
    gpa: Allocator,
    heads: []const ChangeHash,
    chunks: []const []const u8,
    flags: ?msg.MessageFlags,
) !Message {
    const owned_heads = try gpa.dupe(ChangeHash, heads);
    errdefer gpa.free(owned_heads);
    var slots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (slots.items) |chunk| gpa.free(chunk);
        slots.deinit(gpa);
    }
    for (chunks) |source| {
        const copy = try gpa.dupe(u8, source);
        errdefer gpa.free(copy);
        try slots.append(gpa, copy);
    }
    return .{
        .gpa = gpa,
        .heads = owned_heads,
        .need = &.{},
        .have = &.{},
        .changes = .{ .items = try slots.toOwnedSlice(gpa), .gpa = gpa },
        .flags = flags,
        .version = .v2,
    };
}

/// A `have` whose `last_sync` is `last_sync` and whose filter is empty, the
/// shape a hand-written message needs and a generator never makes.
fn haveWithLastSync(gpa: Allocator, last_sync: []const ChangeHash) !Have {
    return .{
        .gpa = gpa,
        .last_sync = try gpa.dupe(ChangeHash, last_sync),
        .bloom = bloommod.BloomFilter.empty(gpa),
    };
}

/// Whether a message's payload is a whole saved document rather than a change
/// chunk.
///
/// **The chunk type, not the magic.** Every framed chunk opens with
/// [`chunk_magic`] — a change chunk included — so a payload that starts with
/// the magic is a change payload as often as not, and treating the magic as
/// the discriminator calls every change chunk a document. What separates them
/// is the type byte at [`chunk_type_offset`], and that is what upstream reads:
/// it parses the chunk and matches `Chunk::Document` (`sync.rs:1404-1407`).
///
/// The check is total over the bytes: a chunk too short to hold a type byte
/// has no type, and "no type" is not `document`.
fn carriesDocument(m: *const Message) bool {
    for (m.changes.iter()) |chunk| {
        if (chunk.len <= chunk_type_offset) continue;
        if (!std.mem.eql(u8, chunk[0..chunk_magic.len], chunk_magic[0..])) continue;
        if (chunk[chunk_type_offset] == @intFromEnum(chunkmod.ChunkType.document)) return true;
    }
    return false;
}

/// Compares two hash lists by content. `expectEqualSlices` would need `==` on
/// `ChangeHash`, and a port that wrote one would reintroduce exactly the
/// ambiguity `ChangeHash.eql` exists to remove.
fn expectSameHashes(expected: []const ChangeHash, actual: []const ChangeHash) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expect(want.eql(got));
}

/// The position of `needle` in `haystack`, for the dependency-order assertion
/// below.
fn indexOfHash(haystack: []const ChangeHash, needle: ChangeHash) ?usize {
    for (haystack, 0..) |hash, i| {
        if (hash.eql(needle)) return i;
    }
    return null;
}

/// True when `e` is a member of `err.ParseError` other than
/// `error.OutOfMemory`.
///
/// The exclusion is the point: a refusal is the parser declining untrusted
/// bytes, and running out of memory while trying is a failure of this port
/// rather than an answer about the input. Every member of the set is named, so
/// one added to `error.zig` later shows up here rather than as a silent pass.
fn isRefusal(e: anyerror) bool {
    return switch (e) {
        error.UnexpectedEnd,
        error.InvalidMagic,
        error.InvalidChecksum,
        error.InvalidChunkType,
        error.InvalidLeb128,
        error.Overflow,
        error.TooLarge,
        error.TooManyOps,
        error.TooManyDeps,
        error.MissingActor,
        error.InvalidDeflate,
        error.InvalidColumnSpec,
        error.DuplicateColumn,
        error.MissingColumn,
        error.ColumnOutOfBounds,
        error.UnexpectedNull,
        error.InvalidValueType,
        error.InvalidValue,
        error.InvalidValueMeta,
        error.InvalidAction,
        error.InvalidEncoding,
        error.InvalidTextEncoding,
        error.InvalidClock,
        error.LengthExceedsInput,
        error.TrailingBytes,
        error.Truncated,
        error.MissingPrefix,
        error.InvalidUtf8,
        error.InvalidPath,
        error.Unsupported,
        => true,
        else => false,
    };
}

/// Generates and fails if there is anything to say, freeing a message that
/// should not have existed so the failure is a failure and not a leak on top
/// of one.
fn expectSilent(gpa: Allocator, doc: *Document, state: *State) !void {
    if (try generateSyncMessage(gpa, doc, state)) |m| {
        var owned = m;
        owned.deinit();
        return error.ExpectedNoMessage;
    }
}

/// One round of the upstream driver: **generate from both sides before either
/// receives** (`sync`, `sync.rs:1354-1380`), which is the shape that exercises
/// the in-flight bit. Returns the number of rounds it took, or
/// `error.SyncDidNotConverge` past [`max_rounds`].
///
/// The `log`, when given, counts what went over the wire.
fn exchange(
    gpa: Allocator,
    a: *Document,
    sa: *State,
    b: *Document,
    sb: *State,
    log: ?*ExchangeLog,
) !usize {
    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        var from_a = try generateSyncMessage(gpa, a, sa);
        var from_b = try generateSyncMessage(gpa, b, sb);
        if (from_a == null and from_b == null) return round;

        if (from_a) |m| {
            from_a = null;
            if (log) |l| {
                l.a_sent += 1;
                if (carriesDocument(&m)) l.a_documents += 1;
            }
            try deliver(gpa, b, sb, m);
        }
        if (from_b) |m| {
            from_b = null;
            if (log) |l| {
                l.b_sent += 1;
                if (carriesDocument(&m)) l.b_documents += 1;
            }
            try deliver(gpa, a, sa, m);
        }
    }
    return error.SyncDidNotConverge;
}

/// What one exchange put on the wire, so a test can assert on the messages and
/// not only on the documents.
const ExchangeLog = struct {
    a_sent: usize = 0,
    b_sent: usize = 0,
    /// How many of those carried a whole saved document rather than changes.
    a_documents: usize = 0,
    b_documents: usize = 0,
};

test "two documents converge through generate and receive" {
    // The headline property, and the only assertion here that can fail for a
    // broken state machine: the two op sets are compared row for row
    // (`OpSet.debugCmp`, reached through `Document.debugCmp`) rather than by a
    // change count.
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    const other = try otherActorChange(gpa);
    defer gpa.free(other);

    var a = try docWith(gpa, &.{stream});
    defer a.deinit();
    var b = try docWith(gpa, &.{other});
    defer b.deinit();

    // Two changes against one, from actors neither has seen, and the two
    // documents are **not** the same document — which is what makes the
    // comparison below mean something. A checker that cannot fail is not a
    // checker.
    try testing.expectEqual(@as(u64, 2), a.stats().num_changes);
    try testing.expectEqual(@as(u64, 1), b.stats().num_changes);
    try testing.expectError(error.Invariant, a.debugCmp(&b));

    var sa = State.new(gpa);
    defer sa.deinit();
    var sb = State.new(gpa);
    defer sb.deinit();

    var log: ExchangeLog = .{};
    const rounds = try exchange(gpa, &a, &sa, &b, &sb, &log);

    // **Convergence is structural.**
    try b.debugCmp(&a);
    try testing.expectEqual(@as(u64, 3), a.stats().num_changes);
    try testing.expectEqual(a.stats().num_changes, b.stats().num_changes);
    try testing.expectEqual(a.stats().num_ops, b.stats().num_ops);
    try testing.expectEqual(a.stats().num_actors, b.stats().num_actors);

    // And the exchange reached its fixed point on both sides inside upstream's
    // ten rounds, with the round after that silent on both.
    try testing.expect(rounds > 0);
    try testing.expect(rounds < max_rounds);
    try testing.expect(log.a_sent > 0);
    try testing.expect(log.b_sent > 0);
    try expectSilent(gpa, &a, &sa);
    try expectSilent(gpa, &b, &sb);
}

test "two documents in sync generate nothing, not an empty message" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    const other = try otherActorChange(gpa);
    defer gpa.free(other);
    var a = try docWith(gpa, &.{stream});
    defer a.deinit();
    var b = try docWith(gpa, &.{other});
    defer b.deinit();

    var sa = State.new(gpa);
    defer sa.deinit();
    var sb = State.new(gpa);
    defer sb.deinit();
    _ = try exchange(gpa, &a, &sa, &b, &sb, null);
    try a.debugCmp(&b);

    // **Null, not a message with nothing in it.** An empty message still
    // advertises our heads and clears `in_flight`, so substituting one for
    // null leaves two peers talking to each other forever.
    try expectSilent(gpa, &a, &sa);
    try expectSilent(gpa, &b, &sb);

    // The states are in the state the rule describes, not merely quiet: a
    // generator that went quiet for some other reason passes the two calls
    // above and fails these.
    try testing.expect(sa.have_responded);
    try testing.expect(sb.have_responded);
    try testing.expect(!sa.in_flight);
    try testing.expect(!sb.in_flight);
    const heads_a = try a.getHeads(gpa);
    defer gpa.free(heads_a);
    const heads_b = try b.getHeads(gpa);
    defer gpa.free(heads_b);
    try expectSameHashes(heads_a, sa.last_sent_heads);
    try expectSameHashes(heads_b, sb.last_sent_heads);
    try expectSameHashes(heads_a, sa.their_heads.?);
    try expectSameHashes(heads_b, sb.their_heads.?);
    try expectSameHashes(heads_a, sa.shared_heads);
    try expectSameHashes(heads_b, sb.shared_heads);
}

test "a peer with no heads is sent the document once, and a read-only peer then nothing" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    const other = try otherActorChange(gpa);
    defer gpa.free(other);
    var a = try docWith(gpa, &.{ stream, other });
    defer a.deinit();
    var b = try Document.init(gpa, std.testing.io);
    defer b.deinit();
    b.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    try testing.expectEqual(@as(u64, 0), b.stats().num_changes);

    var sa = State.new(gpa);
    defer sa.deinit();
    var sb = State.new(gpa);
    defer sb.deinit();

    // Round one is a hello in both directions. `b` has nothing, so its heads
    // are empty, and that is what arms `send_doc` on `a`'s side
    // (`state.rs:198-200`).
    const first_a = (try generateSyncMessage(gpa, &a, &sa)).?;
    const first_b = (try generateSyncMessage(gpa, &b, &sb)).?;
    try deliver(gpa, &b, &sb, first_a);
    try deliver(gpa, &a, &sa, first_b);

    // Round two: `a` answers a peer that advertised no heads with the whole
    // document, in one chunk, as a V2 message (`sync.rs:213-215`).
    const second_a = (try generateSyncMessage(gpa, &a, &sa)).?;
    try testing.expectEqual(@as(usize, 1), second_a.changes.len());
    try testing.expect(carriesDocument(&second_a));
    try testing.expectEqual(@as(u8, 0x43), second_a.version.encode());
    try deliver(gpa, &b, &sb, second_a);
    // The peer now holds everything, and the document chunk was applied
    // rather than skipped.
    try testing.expectEqual(@as(u64, 3), b.stats().num_changes);
    try b.debugCmp(&a);

    // The peer becomes read-only: a subscriber that will take no more.
    // Upstream's `set_read_only` clears `have_responded`, so the next message
    // it generates is guaranteed and carries `READ_ONLY` (`state.rs:176-183`).
    sb.setReadOnly(true);
    try testing.expect(sb.read_only);
    try testing.expect(!sb.have_responded);
    const read_only_msg = (try generateSyncMessage(gpa, &b, &sb)).?;
    try testing.expect(read_only_msg.flags.?.contains(msg.MessageFlags.read_only));
    try testing.expect(read_only_msg.flags.?.contains(msg.MessageFlags.supports_sync_reset));
    try deliver(gpa, &a, &sa, read_only_msg);
    try testing.expect(sa.isPeerReadOnly());

    // **And now `a` is silent.** A peer that advertised `READ_ONLY` is never
    // sent changes (`sync.rs:208-211`), so the payload is empty; the heads
    // have not moved, we have responded, the heads are equal and the builder
    // is empty — all of `sync.rs:242-245` at once.
    try expectSilent(gpa, &a, &sa);

    // The rest of the exchange converges, and `a` sends **no second copy of
    // the document**: once the peer says it is read-only there is nothing left
    // to send it, and the >⅓ whole-document path is behind the same branch
    // (`sync.rs:208-211` comes before `sync.rs:225`).
    var log: ExchangeLog = .{};
    _ = try exchange(gpa, &a, &sa, &b, &sb, &log);
    try testing.expectEqual(@as(usize, 0), log.a_documents);
    try expectSilent(gpa, &a, &sa);
    try expectSilent(gpa, &b, &sb);
    // The discovery is one-directional and that is the whole shape of it: `a`
    // learned the peer is read-only, and the peer never learned `a` is not,
    // because `a` never said so. Upstream's two-sided version is
    // `both_peers_read_only`, `sync.rs:1496-1520`.
    try testing.expect(sa.isPeerReadOnly());
    try testing.expect(sb.read_only);
    try testing.expect(!sa.read_only);
}

test "a message in flight suppresses the next one" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    const other = try otherActorChange(gpa);
    defer gpa.free(other);

    // Two runs that differ in exactly one fact: whether anything came back
    // before the second generate. A suppression that could be explained by
    // "there is nothing to send" would suppress in both, so only the in-flight
    // bit separates them — which is what makes this a test of that clause and
    // not of the one above it.
    for ([_]bool{ false, true }) |answered| {
        var a = try docWith(gpa, &.{stream});
        defer a.deinit();
        var b = try docWith(gpa, &.{other});
        defer b.deinit();
        try testing.expectError(error.Invariant, a.debugCmp(&b));

        var sa = State.new(gpa);
        defer sa.deinit();
        var sb = State.new(gpa);
        defer sb.deinit();

        // Round one: the hello from both sides, generated before either is
        // delivered (`sync.rs:1354-1380`). Each advertises its own heads, an
        // empty bloom and **nothing else**: before a message has been received
        // there is no advertised head set to ask against, so `our_need` is
        // empty (`sync.rs:170-184`) and no changes are sent
        // (`sync.rs:234-235`).
        const hello_a = (try generateSyncMessage(gpa, &a, &sa)).?;
        const hello_b = (try generateSyncMessage(gpa, &b, &sb)).?;
        try testing.expect(sa.in_flight);
        try testing.expectEqual(@as(usize, 0), hello_a.need.len);
        try testing.expectEqual(@as(usize, 0), hello_b.need.len);
        try testing.expect(hello_a.changes.isEmpty());
        try testing.expect(hello_b.changes.isEmpty());
        const heads_a = try a.getHeads(gpa);
        defer gpa.free(heads_a);
        try expectSameHashes(heads_a, hello_a.heads);
        try deliver(gpa, &b, &sb, hello_a);
        try deliver(gpa, &a, &sa, hello_b);
        // Only now does either side know what to ask for.
        try testing.expect(sa.their_heads.?.len > 0);
        try testing.expect(sb.their_heads.?.len > 0);
        try testing.expect(!sa.in_flight);
        try testing.expect(!sb.in_flight);

        // Round two: `a` has changes the peer is missing, so what it builds is
        // **not** empty. It goes out, and in the first run it is never
        // answered.
        var second_a = (try generateSyncMessage(gpa, &a, &sa)).?;
        // A `defer`, not a trailing `deinit()`: the assertions below hand this
        // back on every failing path, and a message the testing allocator
        // reports as leaked takes the whole run with it.
        defer second_a.deinit();
        try testing.expect(!second_a.changes.isEmpty());
        try testing.expect(sa.in_flight);

        if (!answered) {
            // The state the suppression test reads, clause by clause. The
            // heads are unchanged, we have responded, the heads are **not**
            // equal and we are not read-only — so `sync.rs:243-245` is false
            // whatever the builder holds, and the only clause left is
            // `sync.rs:246-248`.
            try testing.expect(hashesEqual(sa.last_sent_heads, heads_a));
            try testing.expect(sa.have_responded);
            try testing.expect(!sa.read_only);
            try testing.expect(!hashesEqual(sa.their_heads.?, heads_a));
            try testing.expect(sa.in_flight);
            try expectSilent(gpa, &a, &sa);
            continue;
        }

        // In the second run the same state, with the bit cleared by a receive,
        // does send. That is the arm that makes the exchange make progress
        // rather than stall at the second round.
        const reply_b = (try generateSyncMessage(gpa, &b, &sb)).?;
        try testing.expect(!reply_b.changes.isEmpty());
        try deliver(gpa, &a, &sa, reply_b);
        try testing.expect(!sa.in_flight);
        var third_a = (try generateSyncMessage(gpa, &a, &sa)) orelse return error.ExpectedAMessage;
        third_a.deinit();
    }
}

test "a change that arrives before its dependency is queued, then applied" {
    const gpa = testing.allocator;
    const in_order = try twoChangeStream(gpa);
    defer gpa.free(in_order);
    const shuffled = try outOfOrderStream(gpa);
    defer gpa.free(shuffled);
    const frames = try splitStream(gpa, shuffled);
    defer freeFramed(gpa, frames);
    try testing.expectEqual(@as(usize, 2), frames.len);

    // The two files hold the same two changes, so a document built from the
    // shuffled frames in reverse order and one built from the in-order stream
    // have the same heads. That is what makes frame 0 the dependent one, and
    // the assertion is the heads rather than a comment saying so.
    var by_frames = try docWith(gpa, &.{ frames[1].bytes, frames[0].bytes });
    defer by_frames.deinit();
    var source = try docWith(gpa, &.{in_order});
    defer source.deinit();
    const source_heads = try source.getHeads(gpa);
    defer gpa.free(source_heads);
    const frame_heads = try by_frames.getHeads(gpa);
    defer gpa.free(frame_heads);
    try expectSameHashes(source_heads, frame_heads);
    try testing.expectEqual(@as(usize, 1), source_heads.len);
    const h_parent = frames[1].hash;
    const h_child = frames[0].hash;
    try testing.expectEqualSlices(u8, &h_child.bytes, &source_heads[0].bytes);
    try testing.expect(!h_parent.eql(h_child));

    var target = try Document.init(gpa, std.testing.io);
    defer target.deinit();
    target.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    var state = State.new(gpa);
    defer state.deinit();

    // The dependent change alone, and nothing else.
    const out_of_order = try handMessage(gpa, &.{frames[0].hash}, &.{frames[0].bytes}, null);
    try deliver(gpa, &target, &state, out_of_order);

    // **Queued, not applied and not refused.** This is the change queue's
    // behaviour (`change_queue.zig`), and the point of the test is that this
    // file does not defeat it: no error, no head, and the change held.
    try testing.expectEqual(@as(usize, 0), target.graph.len());
    try testing.expectEqual(@as(usize, 1), target.queue.len());
    const empty_heads = try target.getHeads(gpa);
    defer gpa.free(empty_heads);
    try testing.expectEqual(@as(usize, 0), empty_heads.len);

    // The request is the dependency the queued change is waiting for, and only
    // that: `missing_deps_from` walks *through* a queued change rather than
    // advertising the orphan itself (`automerge.rs:2051-2061`). A port that
    // advertised the orphan would deadlock here, because this peer cannot
    // satisfy it either.
    var asking = (try generateSyncMessage(gpa, &target, &state)).?;
    defer asking.deinit();
    try testing.expectEqual(@as(usize, 1), asking.need.len);
    try testing.expect(h_parent.eql(asking.need[0]));
    // And no payload: the queued change is not something this side can send.
    try testing.expect(asking.changes.isEmpty());

    // The dependency lands, and the queue drains inside the same receive.
    const in_order_message = try handMessage(
        gpa,
        &.{ h_parent, h_child },
        &.{frames[1].bytes},
        null,
    );
    try deliver(gpa, &target, &state, in_order_message);

    try testing.expectEqual(@as(usize, 0), target.queue.len());
    try testing.expectEqual(@as(usize, 2), target.graph.len());
    const heads = try target.getHeads(gpa);
    defer gpa.free(heads);
    try expectSameHashes(source_heads, heads);
    // The same document, structurally, as the one the changes came from.
    try target.debugCmp(&source);
}

test "a change the document already has changes nothing" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    var source = try docWith(gpa, &.{stream});
    defer source.deinit();
    var target = try Document.init(gpa, std.testing.io);
    defer target.deinit();
    target.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    var state = State.new(gpa);
    defer state.deinit();

    // Bring `target` up to date by hand, the way a transport would.
    const heads = try source.getHeads(gpa);
    defer gpa.free(heads);
    const first = try handMessage(gpa, heads, &.{stream}, null);
    try deliver(gpa, &target, &state, first);

    const before = target.stats();
    try testing.expectEqual(@as(u64, 2), before.num_changes);
    try target.debugCmp(&source);

    // **The same bytes again.** A peer re-sending what we already applied must
    // leave the document exactly as it was: no second row, no new head, no
    // error. The screen skips a change the graph already holds
    // (`batch.zig:2337`), and this is the test that says so.
    const again = try handMessage(gpa, heads, &.{stream}, null);
    try deliver(gpa, &target, &state, again);

    try testing.expectEqual(before.num_changes, target.stats().num_changes);
    try testing.expectEqual(before.num_ops, target.stats().num_ops);
    try testing.expectEqual(before.num_actors, target.stats().num_actors);
    try target.debugCmp(&source);
    const heads_now = try target.getHeads(gpa);
    defer gpa.free(heads_now);
    try expectSameHashes(heads, heads_now);
}

test "peers agree on V2 when both can, and stay on V1 when one cannot" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    var a = try docWith(gpa, &.{stream});
    defer a.deinit();
    var b = try Document.init(gpa, std.testing.io);
    defer b.deinit();
    b.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    var sa = State.new(gpa);
    defer sa.deinit();
    var sb = State.new(gpa);
    defer sb.deinit();

    // **The first message is V1**, because a fresh state has no capability
    // list at all (`state.rs:208-212`) and the version follows the peer's
    // (`sync/message_builder.rs:18-24`). The type byte is the compatibility
    // boundary, so it is pinned as a literal in both directions — on the
    // struct and on the bytes that go on the wire.
    const first_a = (try generateSyncMessage(gpa, &a, &sa)).?;
    try testing.expectEqual(@as(u8, 0x42), first_a.version.encode());
    const first_bytes = try first_a.encode(gpa);
    defer gpa.free(first_bytes);
    try testing.expectEqual(@as(u8, 0x42), first_bytes[0]);

    // That message carries a flags section (`sync.rs:283`), so the responder
    // reads V2 from now on and its very next message says so.
    try deliver(gpa, &b, &sb, first_a);
    try testing.expect(sb.supportsV2Messages());
    const reply_b = (try generateSyncMessage(gpa, &b, &sb)).?;
    try testing.expectEqual(@as(u8, 0x43), reply_b.version.encode());
    const reply_bytes = try reply_b.encode(gpa);
    defer gpa.free(reply_bytes);
    try testing.expectEqual(@as(u8, 0x43), reply_bytes[0]);
    try deliver(gpa, &a, &sa, reply_b);
    try testing.expect(sa.supportsV2Messages());

    // A peer that has **never** sent a flags section stays on V1 for the whole
    // connection, and is never sent a document chunk it could not read
    // (`state.rs:198-200`, `sync.rs:225`). At this commit a hand-written
    // unflagged message is the only way such a peer exists, because every
    // generated message carries flags.
    var c = try Document.init(gpa, std.testing.io);
    defer c.deinit();
    c.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    var sc = State.new(gpa);
    defer sc.deinit();
    const peer_heads = try a.getHeads(gpa);
    defer gpa.free(peer_heads);
    const unflagged = try handMessage(gpa, peer_heads, &.{}, null);
    try deliver(gpa, &c, &sc, unflagged);
    try testing.expectEqual(@as(?[]msg.Capability, null), sc.their_capabilities);
    try testing.expect(!sc.supportsV2Messages());

    var from_c = (try generateSyncMessage(gpa, &c, &sc)).?;
    defer from_c.deinit();
    try testing.expectEqual(@as(u8, 0x42), from_c.version.encode());
    // `c` has no heads, which is what would arm `send_doc`, and a v1 peer
    // must not be sent a document chunk: it has no way to read one.
    try testing.expect(!carriesDocument(&from_c));
}

test "a malformed message is refused and the document is unchanged" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);

    var source = try docWith(gpa, &.{stream});
    defer source.deinit();
    var target = try Document.init(gpa, std.testing.io);
    defer target.deinit();
    target.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    var state = State.new(gpa);
    defer state.deinit();

    // One real message to mutate, so every shape below is a real message with
    // exactly one thing wrong with it.
    const source_heads = try source.getHeads(gpa);
    defer gpa.free(source_heads);
    var good = try handMessage(gpa, source_heads, &.{stream}, msg.MessageFlags.none());
    defer good.deinit();
    const good_bytes = try good.encode(gpa);
    defer gpa.free(good_bytes);
    try testing.expect(good_bytes.len > 8);
    // The control: these exact bytes are accepted, so a refusal below is the
    // mutation and not the message.
    {
        var control = try Message.decode(gpa, good_bytes);
        control.deinit();
    }

    const heads_before = try target.getHeads(gpa);
    defer gpa.free(heads_before);
    const changes_before = target.graph.len();
    try testing.expectEqual(@as(usize, 0), changes_before);

    // Three decode shapes. Each is a `ParseError`, and none reaches the
    // document: that is the property that matters, because a peer must not be
    // able to change anything with bytes we refused.
    const Refused = struct { bytes: []const u8, what: []const u8 };
    // A body cut in half: every prefix of a message is incomplete until its
    // last field, and a truncated body is the ordinary case.
    const truncated = good_bytes[0 .. good_bytes.len / 2];

    // A chunk length that runs past the end: no heads, no need, no have, one
    // chunk claiming 127 bytes, and nothing following.
    var overlong: std.ArrayList(u8) = .empty;
    defer overlong.deinit(gpa);
    try overlong.append(gpa, message_type_sync);
    try overlong.append(gpa, 0x00);
    try overlong.append(gpa, 0x00);
    try overlong.append(gpa, 0x00);
    try overlong.append(gpa, 0x01);
    try overlong.append(gpa, 0x7f);

    // A bloom section of the wrong length: one `have`, an empty `last_sync`,
    // and a bloom claiming ten bytes with none left.
    var bad_bloom: std.ArrayList(u8) = .empty;
    defer bad_bloom.deinit(gpa);
    try bad_bloom.append(gpa, message_type_sync_v2);
    try bad_bloom.append(gpa, 0x00);
    try bad_bloom.append(gpa, 0x00);
    try bad_bloom.append(gpa, 0x01);
    try bad_bloom.append(gpa, 0x00);
    try bad_bloom.append(gpa, 0x0a);

    const shapes = [_]Refused{
        .{ .bytes = truncated, .what = "a truncated body" },
        .{ .bytes = overlong.items, .what = "a length that runs past the end" },
        .{ .bytes = bad_bloom.items, .what = "a bloom section of the wrong length" },
    };
    for (shapes) |shape| {
        if (Message.decode(gpa, shape.bytes)) |accepted| {
            var owned = accepted;
            owned.deinit();
            std.debug.print("accepted a message that is {s}\n", .{shape.what});
            return error.ExpectedParseError;
        } else |e| {
            try testing.expect(isRefusal(e));
        }
        const heads_now = try target.getHeads(gpa);
        defer gpa.free(heads_now);
        try expectSameHashes(heads_before, heads_now);
        try testing.expectEqual(changes_before, target.graph.len());
    }

    // **A fourth shape, and the one this file owns**: bytes that decode into a
    // perfectly well-formed message and then cannot be loaded. A document
    // chunk magic followed by nothing is a message whose payload is a
    // truncated document, and the refusal has to come out of
    // `receiveSyncMessage` with the document untouched.
    var broken_chunk: std.ArrayList(u8) = .empty;
    defer broken_chunk.deinit(gpa);
    try broken_chunk.appendSlice(gpa, chunk_magic[0..]);
    var loadable = try handMessage(gpa, &.{}, &.{broken_chunk.items}, null);
    defer loadable.deinit();
    const loadable_bytes = try loadable.encode(gpa);
    defer gpa.free(loadable_bytes);

    state.in_flight = true;
    const decoded = try Message.decode(gpa, loadable_bytes);
    if (receiveSyncMessage(gpa, &target, &state, decoded)) |_| {
        return error.ExpectedParseError;
    } else |e| {
        try testing.expect(isRefusal(e));
    }
    const heads_now = try target.getHeads(gpa);
    defer gpa.free(heads_now);
    try expectSameHashes(heads_before, heads_now);
    try testing.expectEqual(changes_before, target.graph.len());
    // The one thing that **is** allowed to have changed: the in-flight bit is
    // cleared before anything can fail (`sync.rs:392`), so a refused message
    // unblocks generation rather than wedging the connection.
    try testing.expect(!state.in_flight);
}

test "the shared heads advance from what was sent, not from what was claimed" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    var source = try docWith(gpa, &.{stream});
    defer source.deinit();
    var target = try Document.init(gpa, std.testing.io);
    defer target.deinit();
    target.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    var state = State.new(gpa);
    defer state.deinit();

    const heads = try source.getHeads(gpa);
    defer gpa.free(heads);
    // Two heads the receiver cannot have and never will in this exchange.
    const unknown = ChangeHash{ .bytes = @splat(0x7e) };
    const unknown2 = ChangeHash{ .bytes = @splat(0x7d) };

    // The peer sends the changes **and** claims a head that is not among them.
    // `advance_heads` runs off the document's own heads (`sync.rs:423-427`),
    // and the claimed head is not one the document has, so the `else` arm at
    // `sync.rs:448-456` runs and the shared heads do not move.
    const with_claim = try handMessage(gpa, &.{unknown}, &.{stream}, null);
    try deliver(gpa, &target, &state, with_claim);
    try testing.expectEqual(@as(usize, 2), target.graph.len());
    try expectSameHashes(heads, state.shared_heads);
    // The claim is remembered as the peer's head, because that is what it is.
    // It is the **shared** record that refuses to move, and the difference
    // between the two is the whole rule.
    try expectSameHashes(&[_]ChangeHash{unknown}, state.their_heads.?);

    // A message that acknowledges nothing we recognise leaves the shared heads
    // exactly where they are.
    const acknowledging_nothing = try handMessage(gpa, &.{unknown2}, &.{}, null);
    try deliver(gpa, &target, &state, acknowledging_nothing);
    try expectSameHashes(heads, state.shared_heads);
    try testing.expectEqual(@as(usize, 2), target.graph.len());

    // A message whose heads we **do** hold moves them, and moves them to the
    // peer's heads rather than to a union with what we already had: the
    // `sync.rs:441-442` arm.
    const acknowledging = try handMessage(gpa, heads, &.{}, null);
    try deliver(gpa, &target, &state, acknowledging);
    try expectSameHashes(heads, state.shared_heads);
    // And the echo of our own heads with nothing in it is what refreshes
    // `last_sent_heads` (`sync.rs:433-435`).
    const echo = try handMessage(gpa, heads, &.{}, null);
    try deliver(gpa, &target, &state, echo);
    try expectSameHashes(heads, state.last_sent_heads);
}

test "the hashes to send are the peer's missing ones, in dependency order" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    const other = try otherActorChange(gpa);
    defer gpa.free(other);
    var source = try docWith(gpa, &.{ stream, other });
    defer source.deinit();
    try testing.expectEqual(@as(usize, 3), source.graph.len());
    const heads = try source.getHeads(gpa);
    defer gpa.free(heads);

    // No `have` at all: the answer is the request, minus anything this
    // document does not have (`sync.rs:323-330`).
    const missing = ChangeHash{ .bytes = @splat(0xff) };
    const asked = [_]ChangeHash{ heads[0], missing };
    const answered = try getHashesToSend(gpa, &source, &.{}, &asked);
    defer gpa.free(answered);
    try testing.expectEqual(@as(usize, 1), answered.len);
    try testing.expect(heads[0].eql(answered[0]));

    // A `have` with no `last_sync` and an **empty** filter: the peer claims
    // nothing at all, which is what a reset message and a fresh peer both send
    // (`sync/state.rs:86-89`). Every change is therefore missing, and they come
    // back in the graph's order — each dependency before the change that needs
    // it. A filter over *everything* would claim the opposite, and is the case
    // two paragraphs down.
    var empty_have = [_]Have{Have.empty(gpa)};
    defer for (&empty_have) |*entry| entry.deinit();
    const all = try getHashesToSend(gpa, &source, &empty_have, &.{});
    defer gpa.free(all);
    try testing.expectEqual(@as(usize, 3), all.len);
    for (all) |hash| {
        try testing.expect(source.hasChange(hash));
        var deps = source.graph.depsForHash(hash);
        while (deps.next()) |dep| {
            const dep_hash = source.graph.indexToHash(dep).?;
            // The dependency is earlier in the same list, so a consumer that
            // emitted the chunks in this order produces a stream the peer can
            // apply. A reader that did not enforce the order would pass this
            // either way; the assertion is the order, not the count.
            try testing.expect(indexOfHash(all, dep_hash).? < indexOfHash(all, hash).?);
        }
    }

    // A `have` already naming every head as its `last_sync` needs nothing: a
    // hash the peer's `last_sync` covers is not in `getChanges(last_sync)` at
    // all.
    var caught_up = [_]Have{try makeBloomFilter(gpa, &source, heads)};
    defer for (&caught_up) |*entry| entry.deinit();
    const nothing = try getHashesToSend(gpa, &source, &caught_up, &.{});
    defer gpa.free(nothing);
    try testing.expectEqual(@as(usize, 0), nothing.len);

    // Two heads, and only one of them is the end of a chain, so the filter's
    // effect on each is a different answer. `chain_only` and `solo_only` say
    // which is which without the test having to know a hash order.
    var chain_only = try docWith(gpa, &.{stream});
    defer chain_only.deinit();
    const chain_heads = try chain_only.getHeads(gpa);
    defer gpa.free(chain_heads);
    try testing.expectEqual(@as(usize, 1), chain_heads.len);
    var solo_only = try docWith(gpa, &.{other});
    defer solo_only.deinit();
    const solo_heads = try solo_only.getHeads(gpa);
    defer gpa.free(solo_heads);
    try testing.expectEqual(@as(usize, 1), solo_heads.len);
    try testing.expectEqual(@as(usize, 2), heads.len);

    // A filter claiming the **independent** head means that one is not sent,
    // and nothing else is disturbed: a peer that has a change is a peer that
    // will ignore it (`sync.rs:354-356`).
    var claims_solo = Have.empty(gpa);
    claims_solo.bloom = try bloommod.BloomFilter.fromHashes(gpa, solo_heads);
    var have_solo = [_]Have{claims_solo};
    defer for (&have_solo) |*entry| entry.deinit();
    const without_solo = try getHashesToSend(gpa, &source, &have_solo, &.{});
    defer gpa.free(without_solo);
    try testing.expect(indexOfHash(without_solo, solo_heads[0]) == null);
    try testing.expectEqual(@as(usize, 2), without_solo.len);

    // A filter claiming the head **at the end of the chain** changes nothing,
    // because the closure at `sync.rs:359-368` runs over children: the change
    // we do send depends on it, so sending the parent without it would send a
    // change the peer cannot apply. This is the clause upstream asserts
    // nothing about, and the one a port that walked parents would get wrong.
    var claims_chain = Have.empty(gpa);
    claims_chain.bloom = try bloommod.BloomFilter.fromHashes(gpa, chain_heads);
    var have_chain = [_]Have{claims_chain};
    defer for (&have_chain) |*entry| entry.deinit();
    const with_chain = try getHashesToSend(gpa, &source, &have_chain, &.{});
    defer gpa.free(with_chain);
    try testing.expect(indexOfHash(with_chain, chain_heads[0]) != null);
    try testing.expectEqual(@as(usize, 3), with_chain.len);
    for (with_chain) |hash| try testing.expect(source.hasChange(hash));
}

test "a peer whose first have names a change we lack gets a reset" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    var source = try docWith(gpa, &.{stream});
    defer source.deinit();
    var other = try Document.init(gpa, std.testing.io);
    defer other.deinit();
    other.setActorId(.{ .bytes = "cccccccccccccccccccccccccccccccc" });
    var state = State.new(gpa);
    defer state.deinit();

    const heads = try source.getHeads(gpa);
    defer gpa.free(heads);
    // A `have` whose `last_sync` names a change neither document has. Only the
    // **first** `have` is inspected (`sync.rs:197`), so this is one record and
    // not a list.
    //
    // **What the reference sends, and why this test expects a reset.** The
    // rule is `sync.rs:196-206`, and every word of it matters:
    //
    // * `their_have.first()` is `Some` here, so the second `if let` is
    //   reached at all — the empty-list case beside it is not
    //   (`sync.rs:197`);
    // * `last_sync.iter().all(|hash| self.has_change(hash))` is **false**,
    //   because `unknown` is in neither document (`sync.rs:198-201`).
    //   `Automerge::has_change` is `change_graph.has_change` and nothing else
    //   (`automerge.rs:2031-2033`) — it does not consult the change queue, so
    //   a received-but-unapplied change would still reset here, which is what
    //   `port`'s `doc.graph.hasChange` (`change_graph.zig:298-300`) does; and
    // * the answer is `Message::reset(our_heads)` (`sync.rs:203`), whose
    //   fields are fixed: `MessageVersion::V1`, `need: Vec::new()`,
    //   `have: vec![Have::default()]` — an empty `last_sync` and a filter with
    //   no entries — an empty payload, and `SUPPORTS_SYNC_RESET`
    //   (`sync.rs:625-638`).
    //
    // Note what the port returns **instead** of the peer's changes. The reset
    // branch is taken before any payload is built (`sync.rs:196-206` precedes
    // `sync.rs:208-236`), so a peer missing every change the other side named
    // is told to start again and is sent nothing to apply.
    const unknown = ChangeHash{ .bytes = @splat(0x5a) };
    var asking = try handMessage(gpa, heads, &.{}, null);
    errdefer asking.deinit();
    // The `have` moves into the message, and the message moves it into the
    // state, so there is nothing here to free. The two guards are armed in
    // this order on purpose: the array is owned from the allocation, the
    // record only once it is written, because `Have.deinit` on a slot that
    // was never filled releases undefined memory.
    var slots: []Have = try gpa.alloc(Have, 1);
    errdefer gpa.free(slots);
    slots[0] = try haveWithLastSync(gpa, &.{unknown});
    errdefer slots[0].deinit();
    asking.have = slots;
    try deliver(gpa, &other, &state, asking);

    // The answer is a reset: a V1 message with our heads, one empty `have`,
    // no payload, and sync-reset support advertised.
    var reset = (try generateSyncMessage(gpa, &other, &state)).?;
    // A `defer`, so an assertion below that fails is a failure of this test
    // rather than a leaked message reported against every test after it.
    defer reset.deinit();
    try testing.expectEqual(@as(u8, 0x42), reset.version.encode());
    try testing.expect(reset.changes.isEmpty());
    try testing.expectEqual(@as(usize, 1), reset.have.len);
    try testing.expectEqual(@as(usize, 0), reset.have[0].last_sync.len);
    try testing.expectEqual(@as(u32, 0), reset.have[0].bloom.num_entries);
    try testing.expect(reset.flags.?.contains(msg.MessageFlags.supports_sync_reset));
}

/// Generation for a peer whose **first** `have` names a change this document
/// does not have, for the allocation-failure test below.
///
/// The state is set up here rather than through a message so that the whole run
/// is the reset arm: `sync.rs:196-206` reads `their_have.first()` before it
/// builds a payload, and a real exchange would have to reach this state first.
fn generateResetArm(gpa: Allocator) !void {
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    var doc = try docWith(gpa, &.{stream});
    defer doc.deinit();
    var state = State.new(gpa);
    defer state.deinit();

    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    // A peer advertising a head this document does not have. That head lands on
    // our `need` list (`sync.rs:170-184`), and because the peer advertised
    // exactly what we need it lands on our `have` list too (`sync.rs:190-194`).
    // **So all three locals the reset arm releases are real allocations** and
    // the two guards above them are armed with something to free — which is the
    // only way an empty-slice guard can be shown to free the wrong thing.
    const unknown = ChangeHash{ .bytes = @splat(0x5a) };
    state.their_heads = try gpa.dupe(ChangeHash, &.{unknown});

    // Only the **first** `have` is inspected (`sync.rs:197`), so this is one
    // record and not a list, and its `last_sync` names the same change the peer
    // advertised.
    var slots: []Have = try gpa.alloc(Have, 1);
    errdefer gpa.free(slots);
    slots[0] = try haveWithLastSync(gpa, &.{unknown});
    state.their_have = slots;
    // The state owns the list from here on and `deinit` releases it on every
    // path below, so the guard above is emptied rather than left to fire a
    // second time.
    slots = &.{};

    var reset = (try generateSyncMessage(gpa, &doc, &state)) orelse
        return error.TestUnexpectedResult;
    // A `defer`, so an assertion that fails is a failure of this test rather
    // than a leaked message reported against every test after it.
    defer reset.deinit();
    // The reset carries our heads **copied**, which is the proof that
    // `Message.reset` borrows the argument rather than taking it over.
    try testing.expectEqual(heads.len, reset.heads.len);
    for (heads, reset.heads) |want, got| try testing.expect(want.eql(got));
    try testing.expectEqual(@as(usize, 1), reset.have.len);
}

test "the reset arm releases its lists once under every allocation failure" {
    const gpa = testing.allocator;
    // `Message.reset` borrows `our_heads` and allocates twice itself, so the
    // arm has two returns that each release `our_need` and `our_have` and one
    // failure path that must release them exactly once. The `errdefer`s handle
    // the failure path and the explicit frees handle the success path; a `catch`
    // that freed as well double freed, and one that emptied the locals instead
    // leaked them. Neither shows up in a test that only ever succeeds, because
    // the failure path needs an allocation to fail first.
    try testing.checkAllAllocationFailures(gpa, generateResetArm, .{});
}

/// One receive of a message carrying a flags section, run twice so the second
/// call is the one that replaces a capability list that already exists, for
/// the allocation-failure test below.
fn receiveTwiceWithFlags(gpa: Allocator) !void {
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    var doc = try docWith(gpa, &.{stream});
    defer doc.deinit();
    var state = State.new(gpa);
    defer state.deinit();

    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    var flags = msg.MessageFlags.none();
    flags.set(msg.MessageFlags.supports_sync_reset);
    try receiveSyncMessage(gpa, &doc, &state, try handMessage(gpa, heads, &.{}, flags));
    // The replacement, which is where the old list used to be released before
    // the copy that can fail — so a failure left the state pointing at freed
    // bytes that `supportsV2Messages` then read and `deinit` freed again.
    try receiveSyncMessage(gpa, &doc, &state, try handMessage(gpa, heads, &.{}, flags));

    try testing.expect(state.supportsV2Messages());
    try testing.expect(state.peerSupportsSyncReset());
}

test "a replaced capability list survives every allocation failure" {
    const gpa = testing.allocator;
    // Capabilities are replaced rather than accumulated (`sync.rs:407-411`),
    // so the second receive above frees a list that is still readable. Both
    // the read and the release have to survive the copy failing.
    // The sweep walks the receive's own setup as well, so the message has to
    // be owned before its **first** fallible step: the one that used to be
    // `getHeads` handed the caller a message it could not free.
    try testing.checkAllAllocationFailures(gpa, receiveTwiceWithFlags, .{});
}

/// One generation with `needs_reset` set, against a peer that understands
/// `SYNC_RESET`, run with the `index`th allocation failing. `saw_reset_kept`
/// records that at least one index actually failed, so a run that never
/// reached the reset cannot pass.
fn generateWithPendingReset(
    gpa: Allocator,
    doc: *Document,
    index: usize,
    saw_reset_kept: *bool,
) !void {
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = index });
    const limited = failing.allocator();
    var state = State.new(limited);
    defer state.deinit();
    state.needs_reset = true;
    // The peer understands the flag, so the reset goes out as the flag and our
    // heads rather than as the empty heads of the older path (`sync.rs:267-277`).
    // On an index where the setup itself runs out of memory there is nothing to
    // say about generation, so the index is passed over.
    const caps: []const Capability = &.{ .message_v2, .sync_reset };
    state.their_capabilities = limited.dupe(Capability, caps) catch return;

    if (generateSyncMessage(limited, doc, &state)) |maybe| {
        var out = maybe orelse return error.TestUnexpectedResult;
        defer out.deinit();
        try testing.expect(out.flags.?.contains(msg.MessageFlags.sync_reset));
        try testing.expect(!state.needs_reset);
    } else |failure| switch (failure) {
        error.OutOfMemory => {
            saw_reset_kept.* = true;
            // The heads that carry the reset are allocated **before** the flag
            // is spent (`sync.rs:267-277`), so a failure here leaves the flag
            // set: the next message carries the reset instead of the peer
            // silently keeping a `sent_hashes` we never told it to forget.
            try testing.expect(state.needs_reset);
        },
        else => return failure,
    }
}

test "a pending sync reset is not dropped when the message carrying it cannot be allocated" {
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    var doc = try docWith(gpa, &.{stream});
    defer doc.deinit();

    // How many allocations one full run makes, so every one of them is walked
    // rather than a guessed number of them.
    const budget = blk: {
        var probe: std.testing.FailingAllocator = .init(gpa, .{});
        const limited = probe.allocator();
        var state = State.new(limited);
        defer state.deinit();
        state.needs_reset = true;
        state.their_capabilities = try limited.dupe(Capability, &.{ .message_v2, .sync_reset });
        var out = (try generateSyncMessage(limited, &doc, &state)) orelse
            return error.TestUnexpectedResult;
        defer out.deinit();
        break :blk probe.alloc_index;
    };

    var saw_reset_kept = false;
    for (0..budget) |index| try generateWithPendingReset(gpa, &doc, index, &saw_reset_kept);
    try testing.expect(saw_reset_kept);
}

/// A document with two heads: the chain's own head, and a change by a second
/// actor that depends on nothing of it (`counter_value_is_ok.automerge`).
///
/// Two heads are what makes the order of a peer's advertisement observable at
/// all — a one-head list is ascending and descending at the same time.
fn twoHeadDoc(gpa: Allocator) !Document {
    const chain = try twoChangeStream(gpa);
    defer gpa.free(chain);
    const solo = try readFixture(gpa, other_actor_fixture);
    defer gpa.free(solo);
    return docWith(gpa, &.{ chain, solo });
}

test "a peer's heads are stored as a set, whatever order the peer wrote them" {
    // `Message.parse` appends the heads list in wire order and never sorts it
    // (`message.zig:640-645`), so a peer may advertise its heads in descending
    // order and this port has to read that. `shared_heads` is required to be
    // ascending and duplicate free — `State.encode` asserts it through
    // `message.encodeHashes` (`message.zig:524-530`) and the field is
    // persisted — so the arm that takes the peer's heads wholesale has to sort
    // them, exactly as the arm that merges them already does.
    const gpa = testing.allocator;
    var doc = try twoHeadDoc(gpa);
    defer doc.deinit();
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqual(@as(usize, 2), heads.len);

    // **The bytes, not the struct.** `Message.encode` is the very thing that
    // asserts the order, so a descending list cannot be produced by encoding
    // one; the wire format writes the hashes back to back, so exchanging the
    // two blocks of an encoded message produces the one message a conforming
    // encoder would never write and a conforming reader still has to accept.
    var encoded = try handMessage(gpa, heads, &.{}, null);
    defer encoded.deinit();
    const bytes = try encoded.encode(gpa);
    defer gpa.free(bytes);
    const first = std.mem.indexOf(u8, bytes, &heads[0].bytes) orelse
        return error.TestUnexpectedResult;
    const second = std.mem.indexOf(u8, bytes, &heads[1].bytes) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(first + heads[0].bytes.len, second);
    for (0..heads[0].bytes.len) |i| {
        std.mem.swap(u8, &bytes[first + i], &bytes[second + i]);
    }

    // The reader takes the list as it was written. This is the premise of the
    // test: without it the receive below would be sorting something that had
    // never been out of order.
    var decoded = try Message.decode(gpa, bytes);
    try testing.expectEqual(@as(usize, 2), decoded.heads.len);
    try testing.expect(decoded.heads[0].eql(heads[1]));
    try testing.expect(decoded.heads[1].eql(heads[0]));

    var state = State.new(gpa);
    defer state.deinit();
    try receiveSyncMessage(gpa, &doc, &state, decoded);

    // Both heads are ours, so they are the shared heads — as a set, ascending,
    // duplicate free.
    try testing.expectEqual(@as(usize, 2), state.shared_heads.len);
    for (state.shared_heads, 0..) |head, index| try testing.expect(head.eql(heads[index]));
    // The peer's own record keeps the order the peer wrote, because that is
    // what the peer said and nothing here re-sorts it.
    try testing.expectEqual(@as(usize, 2), state.their_heads.?.len);
    try testing.expect(state.their_heads.?[0].eql(heads[1]));
    try testing.expect(state.their_heads.?[1].eql(heads[0]));

    // And the persisted form writes them out, which is the assertion the
    // order above has to keep from tripping.
    const saved = try state.encode(gpa);
    defer gpa.free(saved);
    try testing.expectEqualSlices(u8, &.{ statemod.sync_state_type, 0x02 }, saved[0..2]);
}

test "an empty their_have is a peer we have spoken to before, and it gets a message" {
    // `state.rs:140`: a **decoded** state comes back with
    // `their_have: Some(Vec::new())` — an empty *list*, not a null — while a
    // fresh one has `None` (`state.rs:32`, `:92-94`). Both are legitimate states and
    // `sync.rs:196-206` reads only the **first** record, so on the empty list
    // `their_have.first()` is `None`, the reset block is skipped, and
    // generation continues into `sync.rs:208-236`.
    //
    // The answer is a real message, and a restored state is exactly where that
    // matters: a peer that persists its sync state has kept only the shared
    // heads (`state.rs:108-112`) and has forgotten what the other side has, so
    // the only way to make progress is to re-advertise our own `have` and our
    // heads and let the other side answer. A reset would be the wrong answer
    // twice over — it advertises nothing (`sync.rs:625-638`), so the exchange
    // it starts has nothing to work from.
    const gpa = testing.allocator;
    const stream = try twoChangeStream(gpa);
    defer gpa.free(stream);
    var peer = try docWith(gpa, &.{stream});
    defer peer.deinit();
    const heads = try peer.getHeads(gpa);
    defer gpa.free(heads);

    // `State::encode` writes the type byte and the shared heads and nothing
    // else, so this block is the whole of what survives a session.
    const encoded = blk: {
        var written = State.new(gpa);
        written.shared_heads = try gpa.dupe(ChangeHash, heads);
        defer written.deinit();
        break :blk try written.encode(gpa);
    };
    defer gpa.free(encoded);

    var restored = try State.decode(gpa, encoded);
    defer restored.deinit();
    // The three facts the empty case rests on.
    try testing.expect(restored.their_have != null);
    try testing.expectEqual(@as(usize, 0), restored.their_have.?.len);
    try testing.expect(restored.their_heads == null);
    try testing.expect(restored.their_need == null);

    // `defer`, never a trailing `deinit()`: an assertion below that fails
    // returns early, and an un-freed message is a leak the testing allocator
    // reports against this test — which costs every test after it, not just
    // this one.
    var message = (try generateSyncMessage(gpa, &peer, &restored)).?;
    defer message.deinit();

    // A message, and its `have` is the one this situation names: the shared
    // heads the state was restored with, in `last_sync`, and an **empty**
    // filter. A reset carries neither (`sync.rs:625-638`, `Have::default()`),
    // so the two answers differ on both fields at once.
    //
    // **The filter is over what we have added since `last_sync`, not over
    // everything we have.** `make_bloom_filter` (`sync.rs:310-316`) calls
    // `change_graph.get_hashes(&last_sync)` (`change_graph.rs:476-487`),
    // which folds `last_sync` into a clock and returns everything the clock
    // does not already cover — the doc on the field says the same thing in
    // words: "a bloom filter summarising all of the changes that the sender
    // of the message has added **since the last sync**"
    // (`sync/state.rs:85-90`). Here `last_sync` *is* our own heads, so nothing
    // has been added since and `from_hashes` over an empty iterator is
    // `num_entries: 0` with no bits (`bloom.rs:125-140`).
    //
    // The reference says so on the wire. `test/golden/sync.jsonl` line 5 is a
    // `left -> right` message of the oracle's `sync` scenario, recorded by
    // running the reference: it carries one `have` whose `last_sync` is two
    // hashes and whose filter is **0 entries, 0 bits** — the converged case,
    // which is this case. Lines 1-3 of the same file are the other end of it:
    // a state with no shared heads, so `get_hashes(&[])` is every hash in the
    // graph and the filter holds 2 entries.
    try testing.expectEqual(@as(usize, 1), message.have.len);
    try expectSameHashes(heads, message.have[0].last_sync);
    try testing.expectEqual(@as(u32, 0), message.have[0].bloom.num_entries);
    try testing.expectEqual(@as(usize, 0), message.have[0].bloom.bits.len);

    // The other empty shape is a peer that has never spoken to us: `None`
    // rather than `Some(&[])`. It gets the same answer, because `sync.rs:196`
    // asks `if let Some` and `sync.rs:197` asks `if let Some(first_have)` —
    // and neither of those two arms can reach `their_have[0]`.
    //
    // **The filter is populated here, and the difference is `shared_heads`.**
    // A fresh state has none (`state.rs:32`, `:92-94`), `get_hashes(&[])` returns the
    // whole graph (`change_graph.rs:477-479`), and the two changes this
    // document holds become two entries.
    var fresh = State.new(gpa);
    defer fresh.deinit();
    try testing.expect(fresh.their_have == null);
    var first_message = (try generateSyncMessage(gpa, &peer, &fresh)).?;
    defer first_message.deinit();
    try testing.expectEqual(@as(usize, 1), first_message.have.len);
    try testing.expectEqual(@as(usize, 0), first_message.have[0].last_sync.len);
    try testing.expectEqual(@as(u32, 2), first_message.have[0].bloom.num_entries);
}

// --- the converge scenario -------------------------------------------------
//
// `tools/oracle` drives the **reference** through the merge the tests below are
// about and prints, for each side: the base document, every sync message of
// every round, the heads, the `save()` bytes and the **materialised** document
// as a JSON tree. It does that twice, once per driver shape, and the two
// transcripts are separate files because the round count is a property of the
// driver and not of the protocol.
//
// **Why the expectations come from the oracle and not from this file.** Every
// awkward case below has an answer that is not obvious from the CRDT rules —
// which side's `put` wins, whether a `delete` beats a concurrent `put`, whether
// a mark covers text spliced into it — and an expectation written here would be
// the port's own opinion of those answers. A checker that agrees with the port
// cannot catch a port that is wrong in the same way twice. So the expected
// materialisation is the reference's, printed by the reference.

const converge_golden_paths = [_][]const u8{
    "test/golden/",
    "../test/golden/",
    "../../test/golden/",
};

/// **Which driver recorded a transcript.** The two differ in when each side
/// generates relative to when the other delivers, and the exchange they run is
/// not the same length.
///
/// * `sequential` — the oracle's `converge`: the left peer generates, the right
///   peer receives what it generated, and only then does the right peer
///   generate (`main.rs:686-709`). Every side answers with what it already
///   knows about the other, so round 1 carries a change or a document from
///   **each** side, and the exchange is over in two traffic rounds.
/// * `parallel` — the reference's **own** test driver, which is the loop every
///   sync test in `sync.rs` uses: generate from both sides, and only then
///   deliver both (`sync.rs:1364-1380`). Neither first message knows anything
///   about the other side, so both are head-only; the changes follow in round
///   2 and the acknowledgement in round 3.
///
/// **The number is not transferable between them**, which is the whole reason
/// this is an enum and not a single file. A round count measured in one shape
/// says nothing about the other, and a gate that pins one while driving the
/// other is measuring its own driver rather than the protocol.
const ConvergeShape = enum {
    sequential,
    parallel,

    /// The transcript's file name, joined onto [`converge_golden_paths`].
    fn goldenName(self: ConvergeShape) []const u8 {
        return switch (self) {
            .sequential => "converge.jsonl",
            .parallel => "converge-parallel.jsonl",
        };
    }

    /// The prefix every record kind in this shape's file carries, so a record
    /// names the driver that produced it.
    fn prefix(self: ConvergeShape) []const u8 {
        return switch (self) {
            .sequential => "converge",
            .parallel => "converge-parallel",
        };
    }
};

/// One record of a `Converge` transcript, from either `converge.jsonl` or
/// `converge-parallel.jsonl`.
///
/// **`ignore_unknown_fields`, and deliberately so**: this is the oracle's
/// schema and not this file's, so a field it grows must not stop this file from
/// reading the records it does use, and a field this file reads is named here
/// so that a rename in the oracle shows up as a refusal rather than as a field
/// that silently reads null.
const ConvergeRecord = struct {
    kind: []const u8,
    side: ?[]const u8 = null,
    round: ?u64 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    sent: ?bool = null,
    hex: ?[]const u8 = null,
    heads: ?[]const []const u8 = null,
    root: ?std.json.Value = null,
    actor_a: ?[]const u8 = null,
    actor_b: ?[]const u8 = null,
    time: ?i64 = null,
    /// `converge-parallel-rounds` only: the number of rounds in which at least
    /// one side spoke, and the round the fixed point starts at
    /// (`converge_parallel_command`, `tools/oracle/src/main.rs`).
    traffic_rounds: ?u64 = null,
    silent_from: ?u64 = null,
};

/// A converge transcript, parsed and kept alive.
///
/// The parsed rows borrow the file text, so the two are one allocation of
/// lifetimes: `deinit` frees every row and then the text, and nothing here
/// outlives the `Converge`.
/// The stack buffer a record-kind lookup builds its name in. The longest name
/// either shape can produce is `converge-parallel-state`, and this is twice
/// that, so the assert in [`Converge.kindBuf`] cannot fire for any suffix a
/// caller in this file uses.
const kind_buf_len = 64;

const Converge = struct {
    gpa: Allocator,
    /// Which driver produced it, and therefore which file it came from.
    shape: ConvergeShape,
    text: []u8,
    rows: std.ArrayList(std.json.Parsed(ConvergeRecord)),

    fn load(gpa: Allocator, shape: ConvergeShape) !Converge {
        var self: Converge = .{ .gpa = gpa, .shape = shape, .text = &.{}, .rows = .empty };
        errdefer self.deinit();
        self.text = try readFrom(gpa, &converge_golden_paths, shape.goldenName());
        var lines = std.mem.splitScalar(u8, self.text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try self.rows.append(
                gpa,
                try std.json.parseFromSlice(
                    ConvergeRecord,
                    gpa,
                    line,
                    .{ .ignore_unknown_fields = true },
                ),
            );
        }
        return self;
    }

    fn deinit(self: *Converge) void {
        for (self.rows.items) |*row| row.deinit();
        self.rows.deinit(self.gpa);
        self.gpa.free(self.text);
        self.* = undefined;
    }

    /// `"<prefix>-<suffix>"`, the record kind for this shape. A stack buffer in
    /// the caller, because the result never outlives the lookup that built it.
    ///
    /// **Infallible, and deliberately so**: a `bufPrint` here would put
    /// `error.NoSpaceLeft` in the error set of every lookup, and
    /// [`ConvergeCheckError`] is a closed set that has no business growing a
    /// formatting failure into a tree-comparison error. Both operands are
    /// compile-time constants in every call, so the length is known and the
    /// only thing that can be wrong is a suffix longer than the buffer.
    fn kindBuf(self: *const Converge, suffix: []const u8, buf: *[kind_buf_len]u8) []const u8 {
        const prefix = self.shape.prefix();
        const len = prefix.len + 1 + suffix.len;
        std.debug.assert(len <= buf.len);
        @memcpy(buf[0..prefix.len], prefix);
        buf[prefix.len] = '-';
        @memcpy(buf[prefix.len + 1 ..][0..suffix.len], suffix);
        return buf[0..len];
    }

    /// The first record whose kind ends in `suffix`.
    fn first(self: *const Converge, suffix: []const u8) !*const ConvergeRecord {
        var buf: [kind_buf_len]u8 = undefined;
        const kind = self.kindBuf(suffix, &buf);
        for (self.rows.items) |*row| {
            if (std.mem.eql(u8, row.value.kind, kind)) return &row.value;
        }
        std.debug.print("{s} has no `{s}` record\n", .{ self.shape.goldenName(), kind });
        return error.ConvergeRecordMissing;
    }

    /// The one record whose kind ends in `suffix`, for `side`, or an error
    /// naming what is missing.
    fn forSide(self: *const Converge, suffix: []const u8, side: []const u8) !*const ConvergeRecord {
        var buf: [kind_buf_len]u8 = undefined;
        const kind = self.kindBuf(suffix, &buf);
        for (self.rows.items) |*row| {
            if (!std.mem.eql(u8, row.value.kind, kind)) continue;
            const name = row.value.side orelse continue;
            if (std.mem.eql(u8, name, side)) return &row.value;
        }
        std.debug.print("{s} has no `{s}` record for side `{s}`\n", .{
            self.shape.goldenName(), kind, side,
        });
        return error.ConvergeRecordMissing;
    }

    /// The record of the exchange for `round` in the direction `from`.
    fn recordedFor(
        self: *const Converge,
        round: u64,
        from: []const u8,
    ) !*const ConvergeRecord {
        var buf: [kind_buf_len]u8 = undefined;
        const kind = self.kindBuf("sync", &buf);
        for (self.rows.items) |*row| {
            if (!std.mem.eql(u8, row.value.kind, kind)) continue;
            if (row.value.round.? != round) continue;
            if (!std.mem.eql(u8, row.value.from.?, from)) continue;
            return &row.value;
        }
        std.debug.print("{s} has no round {d} from `{s}`\n", .{
            self.shape.goldenName(), round, from,
        });
        return error.ConvergeRecordMissing;
    }
};

/// The converge scenario's base document, loaded from the reference's own
/// `save()` bytes.
///
/// Raw documents are returned because callers author changes in explicit transactions.
fn convergeBase(gpa: Allocator, converge: *const Converge) !Document {
    const record = try converge.first("base");
    const bytes = try err.hexFrom(gpa, record.hex.?);
    defer gpa.free(bytes);
    return Document.load(gpa, std.testing.io, bytes, docmod.defaultTextEncoding());
}

/// The scenario's left actor, as the oracle wrote it.
///
/// **Decoded, not used as the bytes themselves.** The oracle's `actor()`
/// (`main.rs:554-557`) hex-decodes its constants, so `ACTOR_A` is *fifteen*
/// bytes of `a1 01 a1 01 …` and reading the constant as a string gives a
/// thirty-byte actor that no peer of this document has ever heard of — a
/// document whose changes hash differently and whose messages are refused.
fn convergeActor(gpa: Allocator, converge: *const Converge, which: []const u8) ![]u8 {
    const record = try converge.first("base");
    const hex = switch (which[0]) {
        'a' => record.actor_a,
        'b' => record.actor_b,
        else => return error.UnknownActor,
    } orelse return error.ConvergeRecordMissing;
    return err.hexFrom(gpa, hex);
}

/// The timestamp every commit in the scenario carries (`TIME`, `main.rs:51`).
fn convergeTime(converge: *const Converge) !i64 {
    const record = try converge.first("base");
    return record.time orelse return error.ConvergeRecordMissing;
}

/// The left peer's single commit, in the order the reference makes it
/// (`converge_left`, `tools/oracle/src/main.rs`).
///
/// | case | call |
/// |---|---|
/// | a write on each side, concurrently, on one key | `put(ROOT, "contested", …)` |
/// | a write on one side only | `put(ROOT, "only_left", …)` |
/// | a counter incremented on this side | `increment(ROOT, "counter", 1)` |
/// | a delete here of a key the other side edits | `delete(ROOT, "doomed")` |
/// | a mark here over a span the other side splices into | `mark(text, 1..4)` |
///
/// **The order is part of the script, not a style choice.** A change's hash is a
/// hash of its encoded operations, so a replay in a different order is a
/// different change and every message downstream of it differs.
fn convergeLeft(gpa: Allocator, doc: *Document, actor: []const u8, time: i64) !void {
    doc.setActorId(.{ .bytes = actor });
    // Read the text object's id **before** the transaction opens, because a
    // transaction's ids and the document's rows are two things and reading
    // through the document mid-transaction is not the shape either is written
    // for.
    const text = (try readmod.get(doc, .root, .{ .key = "text" })).?.id;
    var t = try trans.Transaction.open(gpa, doc);
    // This private fixture caller destroys doc on error; success commits below.
    defer t.deinitClosed();
    _ = try t.put(.root, .{ .key = "contested" }, .{ .str = "left" });
    _ = try t.put(.root, .{ .key = "only_left" }, .{ .int = 1 });
    try t.increment(.root, .{ .key = "counter" }, 1);
    _ = try t.delete(.root, .{ .key = "doomed" });
    try t.mark(text, 1, 4, "bold", .both, .{ .bool_value = true });
    try t.spliceText(text, 8, 0, "!");
    var committed = try t.commitWith(.{ .message = "left", .time = time });
    defer committed.deinit(gpa);
}

/// The right peer's single commit: the mirror of [`convergeLeft`], case for
/// case, and the one place where "the same key" and "the same span" mean the
/// other side's edit.
fn convergeRight(gpa: Allocator, doc: *Document, actor: []const u8, time: i64) !void {
    doc.setActorId(.{ .bytes = actor });
    const text = (try readmod.get(doc, .root, .{ .key = "text" })).?.id;
    var t = try trans.Transaction.open(gpa, doc);
    // The private fixture caller destroys doc on error.
    defer t.deinitClosed();
    _ = try t.put(.root, .{ .key = "contested" }, .{ .str = "right" });
    _ = try t.put(.root, .{ .key = "only_right" }, .{ .int = 2 });
    try t.increment(.root, .{ .key = "counter" }, 2);
    _ = try t.put(.root, .{ .key = "doomed" }, .{ .str = "edited" });
    // **Inside** the span `convergeLeft` marked, not at either anchor: whether
    // the mark covers it does not depend on `ExpandMark`, which is what makes
    // this the case that shows the mark survived the merge.
    try t.spliceText(text, 2, 0, "XY");
    var committed = try t.commitWith(.{ .message = "right", .time = time });
    defer committed.deinit(gpa);
}

/// How many rounds the exchange takes, **read from the reference's own
/// transcript for the shape being driven** rather than written here
/// (`converge-parallel-rounds` in `test/golden/converge-parallel.jsonl`,
/// emitted by `converge_parallel_command`).
///
/// A literal would be the same number with one more place to be wrong, and the
/// number is the whole assertion. It is also **not the same in the two
/// shapes**, which is why this is a lookup and not a constant:
///
/// * the one-sided driver reaches its fixed point in **two** traffic rounds,
///   because the right peer has already seen the left peer's heads when it
///   answers, so its first message is a document;
/// * the reference's own driver — generate from both, then deliver both
///   (`sync.rs:1364-1380`), which is what [`exchange`] implements — reaches it
///   in **three**, because neither first message knows anything about the other
///   side: round 1 is two head-only announcements, round 2 is two documents,
///   and round 3 is the acknowledgement, which carries heads and nothing else.
///   The oracle recorded `traffic_rounds: 3`, `silent_from: 4`.
///
/// **What a round is, is upstream's**: a driver counts a round in which *either*
/// side spoke and stops at the first round in which *neither* did
/// (`sync.rs:1367-1369`, `:1379`). A message that carries no changes and no
/// document is still a round — it is how a peer learns the heads it has in
/// common — and the third round is exactly that.
///
/// **Pinned, not merely bounded.** A loop that needs a fifth round has found
/// something — a message that is generated when it should be silent, or one
/// that is not — and "it converged eventually" is not a statement worth making
/// about a protocol whose whole termination argument is the suppression rule
/// (`sync.rs:242-249`).
fn convergeTrafficRounds(converge: *const Converge) !usize {
    const record = try converge.first("rounds");
    return @intCast(record.traffic_rounds orelse return error.ConvergeRecordMissing);
}

/// Where a mismatch is, in the tree the oracle printed. Grown and truncated on
/// the way down, so a failure names `text.marks[0].end` rather than a row
/// number.
const TreePath = std.ArrayList(u8);

/// What the converge tree check can raise.
///
/// **Named rather than inferred, and the reason is the recursion**: the check
/// walks a document whose children are checked by the same walk, so an inferred
/// error set is a dependency loop. Naming it also says what a failure means: a
/// mismatch is `error.ConvergeMismatch` and a missing field in the golden is
/// `error.ConvergeRecordMissing`, and neither is a parse failure of this file's
/// own bytes.
const ConvergeCheckError = error{
    ConvergeMismatch,
    ConvergeRecordMissing,
    ExpectedJsonObject,
    OutOfMemory,
} || readmod.ReadError || docmod.MarkError || err.ParseError;

fn reportMismatch(path: *const TreePath, what: []const u8, want: anytype, got: anytype) error{ConvergeMismatch} {
    std.debug.print("converge: at '{s}' the {s} is {any}, the oracle's is {any}\n", .{
        path.items, what, got, want,
    });
    return error.ConvergeMismatch;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The type name the oracle prints for a scalar, which is the name this file
/// has to produce (`render_scalar`/`scalar_type`, `tools/oracle/src/main.rs`).
fn scalarTypeName(scalar: value.ScalarValue) []const u8 {
    return switch (scalar) {
        .bytes, .actor_id => "bytes",
        .str => "str",
        .int => "int",
        .uint => "uint",
        .float => "float",
        .counter => "counter",
        .timestamp => "timestamp",
        .bool_value => "bool",
        .unknown => "unknown",
        .null_value => "null",
    };
}

fn objTypeName(t: types.ObjType) []const u8 {
    return switch (t) {
        .map => "map",
        .table => "table",
        .list => "list",
        .text => "text",
    };
}

/// The visible children of a map or a list, checked against the oracle's
/// rendering of the same object.
///
/// **A map's keys are sorted and a list's are not, on both sides.** Key order
/// in a map is not an observable of the document, so it is pinned to sorted
/// order; element order in a list *is* the document, so it is compared position
/// by position and the count has to match on both sides.
fn checkChildren(
    gpa: Allocator,
    doc: *Document,
    obj: types.ExId,
    node: std.json.Value,
    path: *TreePath,
) ConvergeCheckError!void {
    const listed = switch (node) {
        .array => |a| a,
        else => return reportMismatch(path, "children", "an array", @tagName(node)),
    };
    if (try doc.objectType(obj) == .list) {
        const n = try readmod.length(doc, obj);
        if (n != listed.items.len) return reportMismatch(path, "length", listed.items.len, n);
        for (listed.items, 0..) |child, i| {
            const item = (try readmod.get(doc, obj, .{ .index = i })) orelse
                return reportMismatch(path, "element", "a value", "nothing");
            const mark = path.items.len;
            try path.append(gpa, '[');
            var buf: [20]u8 = undefined;
            try path.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{i}) catch "???");
            try path.append(gpa, ']');
            try checkChild(gpa, doc, item.value, item.id, try childOf(child, "node"), path);
            path.shrinkRetainingCapacity(mark);
        }
        return;
    }

    // The keys, **copied, with the walk released before anything recurses.**
    // Two reasons, both upstream-shaped: a key that is a sequence anchor is
    // rendered into the walk's own fixed buffer and is valid only until the
    // next `next()` (`Keys.render`, [iter/keys.zig]), so a borrowed list would
    // alias one buffer; and only one `Keys` may be alive per document at a
    // time ([read.zig:623-626](read.zig)), which the recursion below would
    // otherwise break.
    var keys: std.ArrayList([]u8) = .empty;
    defer {
        for (keys.items) |k| gpa.free(k);
        keys.deinit(gpa);
    }
    {
        var it = try readmod.keys(doc, obj);
        defer it.deinit(gpa);
        while (try it.next()) |k| try keys.append(gpa, try gpa.dupe(u8, k));
    }
    std.mem.sort([]u8, keys.items, {}, lessThanString);
    if (keys.items.len != listed.items.len) {
        return reportMismatch(path, "key count", listed.items.len, keys.items.len);
    }
    for (listed.items, keys.items) |child, key| {
        const named = try childOf(child, "key");
        const name = switch (named) {
            .string => |s| s,
            else => return reportMismatch(path, "key", "a string", @tagName(named)),
        };
        if (!std.mem.eql(u8, name, key)) return reportMismatch(path, "key", key, name);
        const item = (try readmod.get(doc, obj, .{ .key = key })) orelse
            return reportMismatch(path, "key", key, "nothing");
        const mark = path.items.len;
        try path.append(gpa, '.');
        try path.appendSlice(gpa, key);
        try checkChild(gpa, doc, item.value, item.id, try childOf(child, "node"), path);
        path.shrinkRetainingCapacity(mark);
    }
}

/// The value under `field` of a JSON object, or an error naming the field.
fn childOf(node: std.json.Value, field: []const u8) ConvergeCheckError!std.json.Value {
    const object = switch (node) {
        .object => |o| o,
        else => return error.ExpectedJsonObject,
    };
    return object.get(field) orelse {
        std.debug.print("converge: no `{s}` field in a record field\n", .{field});
        return error.ConvergeRecordMissing;
    };
}

/// One materialised value against the oracle's `{"type": …}` rendering of it.
fn checkChild(
    gpa: Allocator,
    doc: *Document,
    found: optypes.ValueRef,
    id: types.ExId,
    node: std.json.Value,
    path: *TreePath,
) ConvergeCheckError!void {
    const want_type = switch (try childOf(node, "type")) {
        .string => |s| s,
        else => return error.ConvergeRecordMissing,
    };
    switch (found) {
        .scalar => |scalar| {
            if (!std.mem.eql(u8, want_type, scalarTypeName(scalar))) {
                return reportMismatch(path, "type", want_type, scalarTypeName(scalar));
            }
            try checkScalar(gpa, scalar, node, path);
        },
        .object => |t| {
            if (!std.mem.eql(u8, want_type, objTypeName(t))) {
                return reportMismatch(path, "type", want_type, objTypeName(t));
            }
            switch (t) {
                .text => {
                    const want_text = switch (try childOf(node, "text")) {
                        .string => |s| s,
                        else => return error.ConvergeRecordMissing,
                    };
                    const got_text = try readmod.text(doc, id, gpa);
                    defer gpa.free(got_text);
                    if (!std.mem.eql(u8, got_text, want_text)) {
                        return reportMismatch(path, "text", want_text, got_text);
                    }
                    try checkMarks(gpa, doc, id, try childOf(node, "marks"), path);
                },
                .list => try checkChildren(gpa, doc, id, try childOf(node, "elements"), path),
                .map, .table => try checkChildren(gpa, doc, id, try childOf(node, "entries"), path),
            }
        },
    }
}

/// A scalar against the oracle's `value` field.
///
/// **A counter's value is a decimal string, not a number**, and that is the
/// oracle's choice (`render_scalar`, `tools/oracle/src/main.rs`): a JSON number
/// would drag the two implementations' float formatting into a comparison that
/// is about the counter. The scenario holds no floats, and a counter is an
/// `i64` however it is read.
fn checkScalar(
    gpa: Allocator,
    scalar: value.ScalarValue,
    node: std.json.Value,
    path: *TreePath,
) ConvergeCheckError!void {
    const want = try childOf(node, "value");
    switch (scalar) {
        .str => |s| {
            const w = switch (want) {
                .string => |x| x,
                else => return reportMismatch(path, "value", "a string", @tagName(want)),
            };
            if (!std.mem.eql(u8, s, w)) return reportMismatch(path, "value", w, s);
        },
        .int => |n| {
            const w = switch (want) {
                .integer => |x| x,
                else => return reportMismatch(path, "value", "an integer", @tagName(want)),
            };
            if (n != w) return reportMismatch(path, "value", w, n);
        },
        .uint => |n| {
            const w = switch (want) {
                .integer => |x| x,
                else => return reportMismatch(path, "value", "an integer", @tagName(want)),
            };
            if (n != @as(u64, @intCast(w))) return reportMismatch(path, "value", w, n);
        },
        .bool_value => |b| {
            const w = switch (want) {
                .bool => |x| x,
                else => return reportMismatch(path, "value", "a bool", @tagName(want)),
            };
            if (b != w) return reportMismatch(path, "value", w, b);
        },
        .counter => |c| {
            const w = switch (want) {
                .string => |x| x,
                else => return reportMismatch(path, "value", "a decimal string", @tagName(want)),
            };
            var buf: [24]u8 = undefined;
            const got = std.fmt.bufPrint(&buf, "{d}", .{c.current}) catch "?";
            if (!std.mem.eql(u8, got, w)) return reportMismatch(path, "value", w, got);
        },
        .timestamp => |t| {
            const w = switch (want) {
                .integer => |x| x,
                else => return reportMismatch(path, "value", "an integer", @tagName(want)),
            };
            if (t != w) return reportMismatch(path, "value", w, t);
        },
        .null_value => switch (want) {
            .null => {},
            else => return reportMismatch(path, "value", "null", @tagName(want)),
        },
        .float => |f| {
            const w = switch (want) {
                .float => |x| x,
                else => return reportMismatch(path, "value", "a float", @tagName(want)),
            };
            if (f != w) return reportMismatch(path, "value", w, f);
        },
        .bytes => |b| try checkHex(gpa, b, want, path),
        .actor_id => |a| try checkHex(gpa, a.bytes, want, path),
        .unknown => |u| try checkHex(gpa, u.bytes, want, path),
    }
}

/// A byte-carrying scalar against the oracle's `{"hex": …}` rendering.
fn checkHex(gpa: Allocator, bytes: []const u8, want: std.json.Value, path: *TreePath) ConvergeCheckError!void {
    const w = switch (try childOf(want, "hex")) {
        .string => |x| x,
        else => return error.ConvergeRecordMissing,
    };
    const want_bytes = try err.hexFrom(gpa, w);
    defer gpa.free(want_bytes);
    if (!std.mem.eql(u8, bytes, want_bytes)) {
        const got = try std.fmt.allocPrint(gpa, "{x}", .{bytes});
        defer gpa.free(got);
        return reportMismatch(path, "hex", w, got);
    }
}

/// The marks over a text object, in `(start, end, name)` order, against the
/// oracle's `marks` array.
fn checkMarks(
    gpa: Allocator,
    doc: *Document,
    id: types.ExId,
    node: std.json.Value,
    path: *TreePath,
) ConvergeCheckError!void {
    const listed = switch (node) {
        .array => |a| a,
        else => return error.ConvergeRecordMissing,
    };
    const found = try doc.marks(gpa, id);
    defer gpa.free(found);
    const Order = struct {
        fn lessThan(_: void, a: marksmod.Mark, b: marksmod.Mark) bool {
            if (a.start != b.start) return a.start < b.start;
            if (a.end != b.end) return a.end < b.end;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    };
    std.mem.sort(marksmod.Mark, found, {}, Order.lessThan);
    if (found.len != listed.items.len) {
        return reportMismatch(path, "mark count", listed.items.len, found.len);
    }
    for (found, listed.items) |mark, entry| {
        const start = switch (try childOf(entry, "start")) {
            .integer => |x| x,
            else => return error.ConvergeRecordMissing,
        };
        const end = switch (try childOf(entry, "end")) {
            .integer => |x| x,
            else => return error.ConvergeRecordMissing,
        };
        const name = switch (try childOf(entry, "name")) {
            .string => |x| x,
            else => return error.ConvergeRecordMissing,
        };
        if (mark.start != start) return reportMismatch(path, "mark start", start, mark.start);
        if (mark.end != end) return reportMismatch(path, "mark end", end, mark.end);
        if (!std.mem.eql(u8, mark.name, name)) return reportMismatch(path, "mark name", name, mark.name);
        try checkScalar(gpa, mark.value, entry, path);
    }
}

/// A document's root against a side's `converge-state` record.
fn expectReferenceState(
    gpa: Allocator,
    doc: *Document,
    converge: *const Converge,
    side: []const u8,
) ConvergeCheckError!void {
    const record = try converge.forSide("state", side);
    var path: TreePath = .empty;
    defer path.deinit(gpa);
    try checkChildren(gpa, doc, .root, record.root orelse return error.ConvergeRecordMissing, &path);
}

/// A document's heads against a side's `converge-heads` record, **as a set**.
///
/// A set and not a list: `getHeads` returns the graph's head order and the
/// oracle printed its own, and two documents that hold the same changes agree
/// on the set rather than on the order the graph happened to walk them in.
fn expectReferenceHeads(
    gpa: Allocator,
    doc: *const Document,
    converge: *const Converge,
    side: []const u8,
) !void {
    const record = try converge.forSide("heads", side);
    const want = record.heads orelse return error.ConvergeRecordMissing;
    const got = try doc.getHeads(gpa);
    defer gpa.free(got);
    if (got.len != want.len) {
        std.debug.print("converge: side {s} has {d} heads, the reference recorded {d}\n", .{
            side, got.len, want.len,
        });
        return error.ConvergeMismatch;
    }
    for (got) |hash| {
        var present = false;
        for (want) |hex| {
            const bytes = try err.hexFrom(gpa, hex);
            defer gpa.free(bytes);
            if (std.mem.eql(u8, &hash.bytes, bytes)) present = true;
        }
        if (!present) {
            std.debug.print("converge: side {s} holds the head {x}, which the reference did not record\n", .{
                side, hash.bytes,
            });
            return error.ConvergeMismatch;
        }
    }
}

/// The two documents of the converge scenario: each one the base plus its own
/// single change, made with the reference's actor, timestamp and commit message
/// so that both changes hash to the hashes the reference computed.
fn convergePair(
    gpa: Allocator,
    converge: *const Converge,
) ![2]Document {
    const time = try convergeTime(converge);
    const actor_a = try convergeActor(gpa, converge, "a");
    defer gpa.free(actor_a);
    const actor_b = try convergeActor(gpa, converge, "b");
    defer gpa.free(actor_b);

    var left = try convergeBase(gpa, converge);
    errdefer left.deinit();
    try convergeLeft(gpa, &left, actor_a, time);
    var right = try convergeBase(gpa, converge);
    errdefer right.deinit();
    try convergeRight(gpa, &right, actor_b, time);
    return .{ left, right };
}

/// How many rounds the oracle's converge subcommands recorded
/// (`CONVERGE_ROUNDS` and `CONVERGE_PARALLEL_ROUNDS`, which is the same
/// number, `tools/oracle/src/main.rs`). A fixed count rather than a loop bound
/// on silence, so a transcript that stopped early is a different length rather
/// than a shorter one.
const converge_rounds = 6;

/// What one replay of the recorded exchange put on the wire.
const WireLog = struct {
    v1_messages: usize = 0,
    v2_messages: usize = 0,
    /// Messages that carried a whole document, and so were not compared byte for
    /// byte — see [`replayConverge`] for why.
    document_chunks: usize = 0,
    /// Messages that were byte-identical to the reference's. **Counted and not
    /// assumed**, so a transcript that stopped early cannot pass a test that
    /// only checks the failures.
    identical_messages: usize = 0,
};

/// Whether a whole **recorded** message carries a document chunk.
///
/// Decoded rather than sniffed: [`carriesDocument`] already reads the chunk type
/// at the offset that matters, and re-deriving that offset here would be a
/// second place for it to be wrong.
fn carriesDocumentBytes(gpa: Allocator, bytes: []const u8) !bool {
    var decoded = try Message.decode(gpa, bytes);
    defer decoded.deinit();
    return carriesDocument(&decoded);
}

/// Replays the reference's recorded exchange against a pair of documents.
///
/// **The message the documents generate is compared with the message the
/// reference recorded, byte for byte, in every round and both directions** —
/// including the rounds where the reference sent nothing, where this side must
/// be silent too. Convergence can be reached by two implementations that both
/// misunderstand the format, so the bytes are the assertion and the converged
/// documents are the consequence.
///
/// **The shape comes from the transcript, not from this function.**
/// `converge.shape` says which driver recorded the exchange, and the replay
/// drives that same shape — see [`ConvergeShape`]. Replaying the reference's
/// one-sided transcript with a two-sided driver would compare this port's
/// messages against a transcript in which the peer answered earlier than it
/// could here, and every difference would be the driver's rather than the
/// port's.
///
/// `own_bytes` chooses which message the receiving document is handed: the one
/// this port generated, or the reference's recorded bytes decoded and applied.
/// With the equality above the two are the same bytes, and running both is what
/// turns "this port's messages are the reference's messages" into "the
/// reference's messages drive this port to the same document" — the direction
/// an equality of bytes alone does not execute.
fn replayConverge(
    gpa: Allocator,
    converge: *const Converge,
    left: *Document,
    sa: *State,
    right: *Document,
    sb: *State,
    own_bytes: bool,
    log: *WireLog,
) !void {
    const sides = [_][2][]const u8{ .{ "left", "right" }, .{ "right", "left" } };
    var round: u64 = 1;
    while (round <= converge_rounds) : (round += 1) {
        // `[0]` is left→right and `[1]` is right→left, and the loop below keeps
        // that order in both shapes: the only thing the shape changes is
        // whether a message is delivered before the other side generates.
        var out: [2]?[]u8 = .{ null, null };
        defer {
            for (&out) |*slot| {
                if (slot.*) |bytes| gpa.free(bytes);
            }
        }
        for (sides, 0..) |side, i| {
            const doc, const state, const peer, const peer_state =
                sidesOf(side[0], left, sa, right, sb);
            const bytes = try replayStep(
                gpa,
                converge,
                round,
                side[0],
                side[1],
                doc,
                state,
                own_bytes,
                log,
            );
            // **The one-sided driver delivers before the other side
            // generates** (`main.rs:686-709`), so the next `generate_sync_message`
            // runs against a state that already holds what this message carried.
            if (converge.shape == .sequential) {
                try deliverStep(gpa, peer, peer_state, bytes);
            } else {
                out[i] = bytes;
            }
        }
        // **The parallel driver generates from both sides first**
        // (`sync.rs:1364-1380`), so neither first message knows anything about
        // the other side. That is the whole difference between the two
        // transcripts, and it is why the delivery cannot move up into the
        // loop above.
        if (converge.shape == .parallel) {
            for (sides, 0..) |side, i| {
                const peer, const peer_state = if (std.mem.eql(u8, side[0], "left"))
                    .{ right, sb }
                else
                    .{ left, sa };
                try deliverStep(gpa, peer, peer_state, out[i]);
                out[i] = null;
            }
        }
    }
}

/// The four pointers one direction of the exchange needs: the sending document
/// and its state, and the receiving document and its state.
fn sidesOf(
    from: []const u8,
    left: *Document,
    sa: *State,
    right: *Document,
    sb: *State,
) struct { *Document, *State, *Document, *State } {
    return if (std.mem.eql(u8, from, "left"))
        .{ left, sa, right, sb }
    else
        .{ right, sb, left, sa };
}

/// Hands `bytes` to `peer`, or does nothing when the round produced none.
/// **Takes ownership**: `bytes` is freed here, and `slot` is cleared by the
/// caller so nothing frees it twice.
fn deliverStep(gpa: Allocator, peer: *Document, peer_state: *State, bytes: ?[]u8) !void {
    const raw = bytes orelse return;
    defer gpa.free(raw);
    try receiveSyncMessage(gpa, peer, peer_state, try Message.decode(gpa, raw));
}

/// One direction of one round: generate, check the message against what the
/// reference recorded in that slot, and hand back the bytes to deliver.
///
/// Returns null for a round the reference recorded as silent, and **only** for
/// such a round: a message here is a difference, not an extra.
fn replayStep(
    gpa: Allocator,
    converge: *const Converge,
    round: u64,
    from: []const u8,
    to: []const u8,
    doc: *Document,
    state: *State,
    own_bytes: bool,
    log: *WireLog,
) !?[]u8 {
    const record = try converge.recordedFor(round, from);
    var generated = try generateSyncMessage(gpa, doc, state);
    if (!record.sent.?) {
        // Silence is a real answer and the reference recorded silence,
        // so a message here is a difference and not an extra.
        if (generated) |*extra| {
            extra.deinit();
            std.debug.print(
                "{s}: round {d} {s} generated a message the reference did not send\n",
                .{ converge.shape.goldenName(), round, from },
            );
            return error.ConvergeMismatch;
        }
        return null;
    }
    var mine = generated orelse {
        std.debug.print(
            "{s}: round {d} {s} was silent where the reference sent {d} bytes\n",
            .{ converge.shape.goldenName(), round, from, record.hex.?.len / 2 },
        );
        return error.ConvergeMismatch;
    };
    generated = null;
    const encoded = try mine.encode(gpa);
    // A `defer` and not an `errdefer`: the success path copies the bytes it
    // wants to hand on and then still owns `encoded` until this returns.
    defer gpa.free(encoded);
    errdefer mine.deinit();
    const theirs = try err.hexFrom(gpa, record.hex.?);
    defer gpa.free(theirs);
    // **A message that carries a whole document is a `save()` on the wire, and
    // `save()` bytes are not a compatibility contract.**
    // [AGENTS.md](AGENTS.md) says so in as many words — DEFLATE is not
    // reproducible across implementations — and the whole-document arm
    // (`sync.rs:213-215`, `sync.rs:225-228`) is `save()`'s bytes exactly. So
    // that message is pinned by its **type byte** and by what it does to the
    // receiving document, which is checked after the loop, and every other
    // message is compared byte for byte. The reference sends one too: the
    // round-1 right-to-left chunk is type `0x00`, a document.
    if (carriesDocument(&mine)) {
        if (encoded[0] != theirs[0]) {
            return error.ConvergeMismatch;
        }
        if (!(try carriesDocumentBytes(gpa, theirs))) {
            return error.ConvergeMismatch;
        }
        log.document_chunks += 1;
    } else if (!std.mem.eql(u8, encoded, theirs)) {
        std.debug.print(
            "{s}: round {d} {s} -> {s} is {d} bytes, the reference's are {d}\n",
            .{ converge.shape.goldenName(), round, from, to, encoded.len, theirs.len },
        );
        std.debug.print("  this port: {x}\n  reference: {x}\n", .{ encoded, theirs });
        return error.ConvergeMismatch;
    } else {
        log.identical_messages += 1;
    }
    if (encoded[0] == message_type_sync) log.v1_messages += 1 else log.v2_messages += 1;

    const delivered = if (own_bytes) try gpa.dupe(u8, encoded) else try gpa.dupe(u8, theirs);
    mine.deinit();
    return delivered;
}

test "two documents converge on every awkward case, and two concurrent increments sum" {
    // **The gate: two Zig documents in a sync loop, run to convergence, checked
    // element by element.** Every awkward case is in one exchange, because the
    // cases interact — a counter both sides increment, a key one side deletes
    // while the other edits it, a mark one side writes over a span the other
    // splices into — and an exchange carrying only one of them has not been
    // asked the hard question.
    const gpa = testing.allocator;
    // **The parallel transcript**, because [`exchange`] is the reference's own
    // driver shape and this is that driver's transcript for these two
    // documents. The one-sided transcript is a different exchange of the same
    // merge, and the byte-for-byte test is asserted against that one.
    var converge = try Converge.load(gpa, .parallel);
    defer converge.deinit();

    var pair = try convergePair(gpa, &converge);
    defer pair[0].deinit();
    defer pair[1].deinit();
    const left = &pair[0];
    const right = &pair[1];

    // **The control.** The two documents are the same base and two different
    // changes, so they are not the same document, and a checker that cannot
    // fail is not a checker.
    try testing.expectEqual(@as(u64, 2), left.stats().num_changes);
    try testing.expectEqual(@as(u64, 2), right.stats().num_changes);
    const left_heads = try left.getHeads(gpa);
    defer gpa.free(left_heads);
    const right_heads = try right.getHeads(gpa);
    defer gpa.free(right_heads);
    try testing.expectEqual(@as(usize, 1), left_heads.len);
    try testing.expectEqual(@as(usize, 1), right_heads.len);
    try testing.expect(!left_heads[0].eql(right_heads[0]));

    var sa = State.new(gpa);
    defer sa.deinit();
    var sb = State.new(gpa);
    defer sb.deinit();

    var log: ExchangeLog = .{};
    const rounds = try exchange(gpa, left, &sa, right, &sb, &log);

    // **The loop terminates, in the number of rounds the reference's own driver
    // took on these same two documents.** `exchange` is that driver
    // (`sync.rs:1364-1380`), so the number to match is this transcript's, and
    // it is read out of the transcript rather than written here — see
    // [`convergeTrafficRounds`] for why it is three and not the two the
    // one-sided transcript records.
    try testing.expectEqual(try convergeTrafficRounds(&converge), rounds);
    try expectSilent(gpa, left, &sa);
    try expectSilent(gpa, right, &sb);
    try testing.expect(log.a_sent > 0);
    try testing.expect(log.b_sent > 0);

    // **Both documents materialise equal, and equal to the reference's.** Not by
    // head count and not by length: element by element, through the read path,
    // against the tree the reference printed.
    try expectReferenceState(gpa, left, &converge, "left");
    try expectReferenceState(gpa, right, &converge, "right");
    try expectReferenceHeads(gpa, left, &converge, "left");
    try expectReferenceHeads(gpa, right, &converge, "right");

    // The same answer, read directly, for the two cases a hash cannot
    // distinguish: a counter that sums, and a mark that grew over a splice.
    for ([_]*Document{ left, right }) |doc| {
        const counter = (try readmod.get(doc, .root, .{ .key = "counter" })).?;
        try testing.expectEqual(@as(i64, 13), counter.value.scalar.counter.current);
        const text = (try readmod.get(doc, .root, .{ .key = "text" })).?;
        const got_text = try readmod.text(doc, text.id, gpa);
        defer gpa.free(got_text);
        try testing.expectEqualStrings("abXYcdefgh!", got_text);
        const found = try doc.marks(gpa, text.id);
        defer gpa.free(found);
        try testing.expectEqual(@as(usize, 1), found.len);
        try testing.expectEqualStrings("bold", found[0].name);
        // `bold` covered `[1, 4)` of `abcdefgh`; the splice at index 2 put two
        // characters inside it, and `ExpandMark::Both` is what carried the end
        // anchor out to 6.
        try testing.expectEqual(@as(usize, 1), found[0].start);
        try testing.expectEqual(@as(usize, 6), found[0].end);
    }
}

test "a Zig and a Rust document sync in both directions, byte for byte" {
    // **The compatibility contract, and the direction an equality of converged
    // documents cannot reach.** Two implementations that both misunderstand the
    // wire format agree with each other, so the assertion is on the message
    // bytes: every message this port generates is byte-identical to the one the
    // reference generated for the same state, in every round and both
    // directions, and every message it receives is the reference's own bytes.
    const gpa = testing.allocator;
    // **The one-sided transcript**, and the byte counts below are its own: one
    // V1, three V2, one of them a whole document. The parallel transcript is a
    // different exchange of the same merge and gets its own block at the end
    // of this test, because its message count is different.
    var converge = try Converge.load(gpa, .sequential);
    defer converge.deinit();

    // **The state, first.** The change this port writes has to *be* the change
    // the reference wrote, or the messages that follow cannot be compared: a
    // difference in one op id changes every hash a message carries.
    {
        var pair = try convergePair(gpa, &converge);
        defer pair[0].deinit();
        defer pair[1].deinit();
        // **The change this port wrote is the change the reference wrote.** The
        // reference's left side ends on two heads — its own change and the
        // right's — and exactly one of them is not the base's head, so that one
        // is the left change and it is the hash a message will carry.
        var base = try convergeBase(gpa, &converge);
        defer base.deinit();
        const base_heads = try base.getHeads(gpa);
        defer gpa.free(base_heads);
        const mine = try pair[0].getHeads(gpa);
        defer gpa.free(mine);
        try testing.expectEqual(@as(usize, 1), mine.len);
        const recorded = (try converge.forSide("heads", "left")).heads.?;
        var matched = false;
        for (recorded) |hex| {
            const bytes = try err.hexFrom(gpa, hex);
            defer gpa.free(bytes);
            if (std.mem.eql(u8, &base_heads[0].bytes, bytes)) continue;
            if (std.mem.eql(u8, &mine[0].bytes, bytes)) matched = true;
        }
        try testing.expect(matched);
    }

    // **The exchange, with this port's own bytes on the wire.** Every recorded
    // message, including the four rounds the reference was silent in, and
    // including the one V1-typed message: the version negotiation is part of the
    // transcript and a peer that only ever agreed on V2 would pass every other
    // assertion here.
    {
        var pair = try convergePair(gpa, &converge);
        defer pair[0].deinit();
        defer pair[1].deinit();
        var sa = State.new(gpa);
        defer sa.deinit();
        var sb = State.new(gpa);
        defer sb.deinit();
        var log: WireLog = .{};
        try replayConverge(gpa, &converge, &pair[0], &sa, &pair[1], &sb, true, &log);

        // **One V1 and three V2**, which is what the transcript holds: the first
        // message a peer ever sends is V1-typed because nothing has told it V2
        // exists, and every message after the first has.
        try testing.expectEqual(@as(usize, 1), log.v1_messages);
        try testing.expectEqual(@as(usize, 3), log.v2_messages);
        // The whole document goes over the wire once, as a document chunk: the
        // peer missing more than a third of it is sent the document
        // (`sync.rs:225-228`), and a V1-typed message cannot carry one. That one
        // message is a `save()`, and `save()` bytes are not the contract
        // ([AGENTS.md](AGENTS.md)), so it is pinned by its type byte and by the
        // convergence below rather than by equality.
        try testing.expectEqual(@as(usize, 1), log.document_chunks);
        // **The other three are byte-identical, and the number says so** — a
        // count, not a boolean, so a replay that compared nothing cannot pass.
        try testing.expectEqual(@as(usize, 3), log.identical_messages);

        try expectSilent(gpa, &pair[0], &sa);
        try expectSilent(gpa, &pair[1], &sb);
        try expectReferenceHeads(gpa, &pair[0], &converge, "left");
        try expectReferenceHeads(gpa, &pair[1], &converge, "right");
        try expectReferenceState(gpa, &pair[0], &converge, "left");
        try expectReferenceState(gpa, &pair[1], &converge, "right");
    }

    // **The other direction, executed.** The same transcript, but every
    // receiving document is handed the bytes the reference recorded rather
    // than the ones this port produced. The messages are already asserted
    // equal, so what this run adds is that the reference's own bytes — a V1
    // message, three V2 messages and a whole document among them — parse here
    // and leave the reference's document behind.
    {
        var pair = try convergePair(gpa, &converge);
        defer pair[0].deinit();
        defer pair[1].deinit();
        var sa = State.new(gpa);
        defer sa.deinit();
        var sb = State.new(gpa);
        defer sb.deinit();
        var log: WireLog = .{};
        try replayConverge(gpa, &converge, &pair[0], &sa, &pair[1], &sb, false, &log);
        try testing.expectEqual(@as(usize, 1), log.v1_messages);
        try testing.expectEqual(@as(usize, 3), log.v2_messages);
        try testing.expectEqual(@as(usize, 1), log.document_chunks);
        try testing.expectEqual(@as(usize, 3), log.identical_messages);
        try expectReferenceHeads(gpa, &pair[0], &converge, "left");
        try expectReferenceHeads(gpa, &pair[1], &converge, "right");
        try expectReferenceState(gpa, &pair[0], &converge, "left");
        try expectReferenceState(gpa, &pair[1], &converge, "right");
    }

    // **The other driver, byte for byte too.** The same two documents driven
    // the way the reference's own driver drives them (`sync.rs:1364-1380`),
    // against `converge-parallel.jsonl`. This is the block that says the round
    // count is three for the *same* reason the reference's is three: round 1
    // is two head-only announcements, round 2 is two documents, and round 3 is
    // the acknowledgement, which carries the two heads the peers now share and
    // **no changes and no document at all**. The three 111-byte round-3
    // messages are the visible form of `get_hashes_to_send` returning nothing
    // because the peer's bloom filter already covers every hash the sender
    // holds (`sync.rs:318-384`, `sync.rs:225-228` not taken).
    //
    // The counts are the transcript's, not a shape argument: two V1 messages,
    // because **both** first messages are sent before either peer has heard of
    // V2, and four V2.
    {
        var parallel = try Converge.load(gpa, .parallel);
        defer parallel.deinit();
        var pair = try convergePair(gpa, &parallel);
        defer pair[0].deinit();
        defer pair[1].deinit();
        var sa = State.new(gpa);
        defer sa.deinit();
        var sb = State.new(gpa);
        defer sb.deinit();
        var log: WireLog = .{};
        try replayConverge(gpa, &parallel, &pair[0], &sa, &pair[1], &sb, true, &log);
        try testing.expectEqual(@as(usize, 2), log.v1_messages);
        try testing.expectEqual(@as(usize, 4), log.v2_messages);
        // **Two documents, one per side**, each from the "more than a third of
        // the document" arm (`sync.rs:225-228`): a two-change document in which
        // the peer is missing the one change we made is one change, and
        // `1 > 2 / 3` is true.
        try testing.expectEqual(@as(usize, 2), log.document_chunks);
        // The other four are byte-identical, and the count says so.
        try testing.expectEqual(@as(usize, 4), log.identical_messages);
        try expectSilent(gpa, &pair[0], &sa);
        try expectSilent(gpa, &pair[1], &sb);
        try expectReferenceHeads(gpa, &pair[0], &parallel, "left");
        try expectReferenceHeads(gpa, &pair[1], &parallel, "right");
        try expectReferenceState(gpa, &pair[0], &parallel, "left");
        try expectReferenceState(gpa, &pair[1], &parallel, "right");
    }
}

/// One `put` and one commit, which is what every line of the two tests below
/// does to a document. A transaction rather than an autocommit document,
/// because a test that needs to interleave a read between the write and the
/// commit cannot use one.
fn putAndCommit(
    gpa: Allocator,
    doc: *Document,
    key: []const u8,
    scalar: value.ScalarValue,
    time: i64,
) !void {
    var t = try trans.Transaction.open(gpa, doc);
    // Every caller owns doc and destroys it on fixture failure.
    defer t.deinitClosed();
    _ = try t.put(.root, .{ .key = key }, scalar);
    var committed = try t.commitWith(.{ .message = "put", .time = time });
    defer committed.deinit(gpa);
}

/// The last change `from` committed, applied to `into` **out of band** — by
/// `apply_changes` rather than through a sync message, so `into`'s sync state
/// is never told about it. That is what both tests below are about: a peer
/// whose document gained a change without a message, while a `State` for it is
/// live.
fn applyLastLocalChange(gpa: Allocator, from: *Document, into: *Document) !void {
    var built = (try from.getLastLocalChange(gpa)) orelse return error.Invariant;
    defer built.deinit(gpa);
    _ = try into.applyChanges(gpa, &.{built.change});
}

test "a change applied out of band, concurrent to the last sync heads" {
    // Upstream `should_handle_lots_of_branching_and_merging`,
    // `sync.rs:1268-1310`, and the specification for the C suite's
    // `test_should_handle_histories_with_lots_of_branching_and_merging`
    // (`test/c/suite/ported_wasm/sync_tests.c:1165`).
    //
    // **The case the converge gate cannot reach.** Every change in the converge
    // scenario arrives in a sync message, so its `State` always knows about it.
    // Here two changes per round are handed over by `apply_changes` with a live
    // `State` on each side, and the last one lands *concurrent to the last sync
    // heads* — upstream's own words, and the reason the final `sync` takes the
    // slower path (`sync.rs:1300`).
    const gpa = testing.allocator;
    // Raw documents use explicit transactions to create each authored change.
    var doc1 = try Document.init(gpa, std.testing.io);
    defer doc1.deinit();
    doc1.setActorId(.{ .bytes = "0123456789abcdef" });
    var doc2 = try Document.init(gpa, std.testing.io);
    defer doc2.deinit();
    doc2.setActorId(.{ .bytes = "89abcdef01234567" });
    var doc3 = try Document.init(gpa, std.testing.io);
    defer doc3.deinit();
    doc3.setActorId(.{ .bytes = "fedcba9876543210" });

    // `sync.rs:1275-1286`: `doc3` commits one change of its own, which nothing
    // else has seen and which only reaches `doc2` at the end.
    try putAndCommit(gpa, &doc3, "n3", .{ .int = 0 }, 0);

    var s1 = State.new(gpa);
    defer s1.deinit();
    var s2 = State.new(gpa);
    defer s2.deinit();

    // `sync.rs:1289-1296`.
    for (1..20) |i| {
        const at: i64 = @intCast(i);
        try putAndCommit(gpa, &doc1, "n1", .{ .int = at }, at);
        try putAndCommit(gpa, &doc2, "n2", .{ .int = at }, at);
        try applyLastLocalChange(gpa, &doc2, &doc1);
        try applyLastLocalChange(gpa, &doc1, &doc2);
    }

    _ = try exchange(gpa, &doc1, &s1, &doc2, &s2, null);

    // `sync.rs:1301-1305`: the change that is concurrent to the last sync
    // heads, and a fresh local change on each side alongside it.
    try applyLastLocalChange(gpa, &doc3, &doc2);
    try putAndCommit(gpa, &doc1, "n1", .{ .str = "final" }, 100);
    try putAndCommit(gpa, &doc2, "n1", .{ .str = "final" }, 100);

    _ = try exchange(gpa, &doc1, &s1, &doc2, &s2, null);

    // `sync.rs:1309`. The two documents differ by 39 changes and the
    // acknowledgement path had to survive all of it.
    const heads1 = try doc1.getHeads(gpa);
    defer gpa.free(heads1);
    const heads2 = try doc2.getHeads(gpa);
    defer gpa.free(heads2);
    try expectSameHashes(heads1, heads2);
    try doc1.debugCmp(&doc2);
}

test "the in-flight bit does not sabotage a concurrent change" {
    // Upstream `in_flight_logic_should_not_sabotage_concurrent_changes`,
    // `sync.rs:1312-1352`, which reproduces `automerge/automerge#702`.
    //
    // **The failure upstream describes is the one this file's suppression rule
    // could cause**: both ends return `None` from `generate_sync_message` —
    // nothing to send — while the documents differ. `in_flight` is the clause
    // that stops a second message going out, so a state that clears it wrongly
    // is a state that stalls (`sync.rs:246-248`).
    const gpa = testing.allocator;
    // **300 rounds, and the count is upstream's**: the case depends on bloom
    // filter false positives, so one pass would usually never reach the
    // interesting state (`sync.rs:1321-1322`). A shorter loop here would be a
    // test that cannot fail.
    //
    // **It is expensive, on purpose, and the number is here so nobody cuts it
    // blind.** Measured in isolation on this machine, Debug: not complete at
    // roughly 8 minutes, complete by roughly 11. That is 300 real sync
    // exchanges against real documents, each compressing and hashing changes —
    // not a hang, and not 300 assertions. The cost is a Debug artefact, so the
    // fix is to run the sync tests optimised, **not** to lower 300: the count
    // encodes a property of the bloom filter, and a loop that no longer reaches
    // the false positive is a test that has quietly stopped being able to fail.
    for (0..300) |_| {
        var doc1 = try Document.init(gpa, std.testing.io);
        defer doc1.deinit();
        var doc2 = try Document.init(gpa, std.testing.io);
        defer doc2.deinit();
        var s1 = State.new(gpa);
        defer s1.deinit();
        var s2 = State.new(gpa);
        defer s2.deinit();

        _ = try exchange(gpa, &doc1, &s1, &doc2, &s2, null);

        // `sync.rs:1333-1340`: doc2 makes a change and sends it. The unwrap is
        // upstream's, and it is sound: there is a new local change and
        // `last_sent_heads` has not moved since the exchange above.
        try putAndCommit(gpa, &doc2, "x", .{ .int = 0 }, 0);
        var outgoing = (try generateSyncMessage(gpa, &doc2, &s2)) orelse
            return error.ExpectedAMessage;
        defer outgoing.deinit();
        const bytes = try outgoing.encode(gpa);
        defer gpa.free(bytes);
        try receiveSyncMessage(gpa, &doc1, &s1, try Message.decode(gpa, bytes));

        // `sync.rs:1342-1344`: **before** doc2 is answered, doc1 makes a change
        // of its own. Its reply is now concurrent with the message doc2 is
        // still waiting to have acknowledged, which is the shape that strands
        // a peer whose `in_flight` bit is wrong.
        try putAndCommit(gpa, &doc1, "x", .{ .int = 1 }, 0);

        _ = try exchange(gpa, &doc1, &s1, &doc2, &s2, null);

        // `sync.rs:1350`. Equal heads is the property; the fact that both
        // generators have gone quiet is what `exchange` already established by
        // returning, so asserting them again would be a tautology.
        const heads1 = try doc1.getHeads(gpa);
        defer gpa.free(heads1);
        const heads2 = try doc2.getHeads(gpa);
        defer gpa.free(heads2);
        try expectSameHashes(heads1, heads2);
    }
}

// ── the whole-document arm ──────────────────────────────────────────────────

/// One `(total, prefix)` case, exactly as the reference measured it.
///
/// **Every number below came out of `zig build conformance -- third`**
/// (`tools/oracle/src/third.rs`), not out of reading the Rust. That
/// subcommand builds this same sender and this same peer, hands the peer's own
/// first message to the sender, and reports three facts the port cannot be
/// asked to justify from its own source: the **divisor**
/// `change_graph.len()`, the number of hashes the sender actually put in the
/// payload, and **which payload went on the wire**.
const ThirdCase = struct {
    /// How many changes the sender's document holds.
    ///
    /// **This is the divisor, and it is the sender's change count, not the
    /// peer's.** `sync.rs:225` divides `self.change_graph.len()`, and
    /// `change_graph.rs:188-190` returns `self.actors.len()` where `actors` is
    /// one `ActorIdx` per change — the survey makes the same point at
    /// `docs/survey/04-sync.md:829`, and it is what makes `total - prefix`
    /// irrelevant to the threshold.
    total: usize,
    /// How many of the sender's changes, taken as a **prefix**, the peer
    /// really holds. The peer is a document built by applying those changes,
    /// so its `have` filter and its heads are true by construction.
    prefix: usize,
    /// The sender's head after `total` commits. One hash pins the whole chain,
    /// because every change depends on the one before it.
    sender_head: []const u8,
    /// The peer's head after `prefix` commits, or empty when `prefix` is zero
    /// and there is none.
    peer_head: []const u8,
    /// `total / 3`: the **integer** division at `sync.rs:225`. `31 / 3` is 10
    /// and `33 / 3` is 11, so the two cases below it are what distinguish a
    /// truncating division from a rounding one.
    threshold: usize,
    /// How many changes the sender put in the payload, **measured** the same
    /// way the oracle measured it: the message is delivered to the peer and
    /// the peer is counted afterwards. Nothing here is computed from
    /// `total - prefix`, so a bloom false positive or a wrong walk in
    /// `getHashesToSend` (`sync.rs:318-384`) cannot hide behind the arithmetic.
    hashes_to_send: usize,
    /// Whether the payload was a whole `save()` rather than a change list.
    document: bool,
};

/// The corpus, as the reference produced it.
///
/// **`total = 30` carries the boundary and the two arms.** `prefix = 0` is the
/// `send_doc` control; `prefix = 19` is one change past the threshold and must
/// be a document; `prefix = 20` is exactly at it and must be a change list,
/// which is where a `>=` instead of a `>` shows up; `prefix = 21` and
/// `prefix = 29` are the rest of the change-list arm, and a port that always
/// sent the document would fail both. The `total = 31, 32, 33` pairs repeat the
/// same boundary with a truncating divisor, and `3` and `9` repeat it at the
/// smallest sizes where `total / 3` is 1 and 3.
///
/// **Every number is what the oracle recorded**, and the test re-derives the
/// relationship between them: a document goes out exactly when the measured
/// `hashes_to_send` is above the truncating third of `total`. That check is on
/// the *corpus* — the code under test is [`buildPayload`], and what it
/// produced is read off the wire by [`carriesDocument`].
const third_cases = [_]ThirdCase{
    // **The control, and it is a different arm.** A peer holding nothing
    // advertises empty heads, which is `send_doc()` (`state.rs:198-200`), and
    // the document that goes out is the consequence of that rather than of
    // `sync.rs:225`. It is in the corpus so the boundary of the arm under test
    // is visible: everything below it is decided by the count, this is not.
    .{
        .total = 30,
        .prefix = 0,
        .sender_head = "d66ca609610ac3d4121d79bc0a38ca8e97b214b7109323bb6e38f8b37689bd4f",
        .peer_head = "",
        .threshold = 10,
        .hashes_to_send = 30,
        .document = true,
    },
    // `30 / 3 == 10`.
    .{
        .total = 30,
        .prefix = 19,
        .sender_head = "d66ca609610ac3d4121d79bc0a38ca8e97b214b7109323bb6e38f8b37689bd4f",
        .peer_head = "79ba1745f9db079eb25652725b682cedf9ecef9bd437496d9755a4a2aa5d435d",
        .threshold = 10,
        .hashes_to_send = 11,
        .document = true,
    },
    // **The boundary.** Ten hashes to send against a threshold of ten, and
    // `10 > 10` is false: a change list.
    .{
        .total = 30,
        .prefix = 20,
        .sender_head = "d66ca609610ac3d4121d79bc0a38ca8e97b214b7109323bb6e38f8b37689bd4f",
        .peer_head = "8a6ad25e318f7c88f37eb76310ac705afda6267982baa6149e92e8c4edf70895",
        .threshold = 10,
        .hashes_to_send = 10,
        .document = false,
    },
    .{
        .total = 30,
        .prefix = 21,
        .sender_head = "d66ca609610ac3d4121d79bc0a38ca8e97b214b7109323bb6e38f8b37689bd4f",
        .peer_head = "d4210ddf962514c1b303d4ccd402431799127ec8daa89e33c6180102f20486f4",
        .threshold = 10,
        .hashes_to_send = 9,
        .document = false,
    },
    // A peer holding nearly everything: one change is one change.
    .{
        .total = 30,
        .prefix = 29,
        .sender_head = "d66ca609610ac3d4121d79bc0a38ca8e97b214b7109323bb6e38f8b37689bd4f",
        .peer_head = "de1ee5838e7d29e72382fe2dd957a71fe3c0d32f8e280fc265e5445018fdf31e",
        .threshold = 10,
        .hashes_to_send = 1,
        .document = false,
    },
    // `31 / 3 == 10` — the divisor truncates, so the boundary has not moved.
    .{
        .total = 31,
        .prefix = 20,
        .sender_head = "e744feb1b1b148898515c5e40289efb21a5b72c388fe0df9a449fb5b92b46912",
        .peer_head = "8a6ad25e318f7c88f37eb76310ac705afda6267982baa6149e92e8c4edf70895",
        .threshold = 10,
        .hashes_to_send = 11,
        .document = true,
    },
    .{
        .total = 31,
        .prefix = 21,
        .sender_head = "e744feb1b1b148898515c5e40289efb21a5b72c388fe0df9a449fb5b92b46912",
        .peer_head = "d4210ddf962514c1b303d4ccd402431799127ec8daa89e33c6180102f20486f4",
        .threshold = 10,
        .hashes_to_send = 10,
        .document = false,
    },
    // `32 / 3 == 10`.
    .{
        .total = 32,
        .prefix = 21,
        .sender_head = "dbdc3e2a255d7c7ee1ad2756156124070be00e7f80235ecd85c2b22c03aaf3be",
        .peer_head = "d4210ddf962514c1b303d4ccd402431799127ec8daa89e33c6180102f20486f4",
        .threshold = 10,
        .hashes_to_send = 11,
        .document = true,
    },
    .{
        .total = 32,
        .prefix = 22,
        .sender_head = "dbdc3e2a255d7c7ee1ad2756156124070be00e7f80235ecd85c2b22c03aaf3be",
        .peer_head = "08cccea37bde48fee2e083927f32c69b8d7b76f93552f8d9f9fd03976dfb2931",
        .threshold = 10,
        .hashes_to_send = 10,
        .document = false,
    },
    // `33 / 3 == 11` — exact, and one **below** a division that rounded up. A
    // port that computed `(total + 2) / 3` would send a document here.
    .{
        .total = 33,
        .prefix = 21,
        .sender_head = "92a42e766f3d44b0c7f7e2ef4c97cf2069bd9a4e4f14a913a6cc1f2cb671b145",
        .peer_head = "d4210ddf962514c1b303d4ccd402431799127ec8daa89e33c6180102f20486f4",
        .threshold = 11,
        .hashes_to_send = 12,
        .document = true,
    },
    .{
        .total = 33,
        .prefix = 22,
        .sender_head = "92a42e766f3d44b0c7f7e2ef4c97cf2069bd9a4e4f14a913a6cc1f2cb671b145",
        .peer_head = "08cccea37bde48fee2e083927f32c69b8d7b76f93552f8d9f9fd03976dfb2931",
        .threshold = 11,
        .hashes_to_send = 11,
        .document = false,
    },
    // `3 / 3 == 1`: the smallest document where a third is one change.
    .{
        .total = 3,
        .prefix = 1,
        .sender_head = "5fd8e0e7a0eafef881fa218af382ec72a46cb61fb8359d6906a4cccfc86a9844",
        .peer_head = "54715646042f02870c76489bd4ed77b2d04c28be9f409483ebc5ca3405805087",
        .threshold = 1,
        .hashes_to_send = 2,
        .document = true,
    },
    .{
        .total = 3,
        .prefix = 2,
        .sender_head = "5fd8e0e7a0eafef881fa218af382ec72a46cb61fb8359d6906a4cccfc86a9844",
        .peer_head = "b15f7a879d876e7757c3deb4881aec53b2cf304c438757a3c86c6c285fb74ba2",
        .threshold = 1,
        .hashes_to_send = 1,
        .document = false,
    },
    // `9 / 3 == 3`.
    .{
        .total = 9,
        .prefix = 5,
        .sender_head = "abc8bbd298c95c79475fe9a6c3fb0e8ebd13781341ddfd42a07496e36aec80e9",
        .peer_head = "8d68dfa4859bb2b133db361a4ea9b04cccdf4137756d34884a9936bf32209b9b",
        .threshold = 3,
        .hashes_to_send = 4,
        .document = true,
    },
    .{
        .total = 9,
        .prefix = 6,
        .sender_head = "abc8bbd298c95c79475fe9a6c3fb0e8ebd13781341ddfd42a07496e36aec80e9",
        .peer_head = "c2f3304533e3d9a377e8cfedf97d474d3d69a03b5671f04e763c8358d8a3ef18",
        .threshold = 3,
        .hashes_to_send = 3,
        .document = false,
    },
};

/// The actor the oracle's `third` sender writes with (`ACTOR_A`, `main.rs`),
/// **as hex**: `third.rs` decodes it with the oracle's `actor()` before handing
/// it to the reference, so the document's actor is the raw bytes that hex spells
/// — not the ASCII characters of the hex. An actor id is not sixteen bytes by
/// definition, and `ACTOR_A` is **fifteen**: a constant copied with an extra
/// `a1` still parses, still loads, and hashes every change differently.
const third_actor_a = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

/// The actor the oracle's `third` peer writes with (`ACTOR_B`, `main.rs`),
/// also as hex. The peer never writes anything: it exists so that the peer and
/// the sender are two actors, which is what the reference builds too.
const third_actor_b = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

/// `TIME` from `main.rs`, the timestamp on every commit of the fixture.
const third_time: i64 = 1_700_000_000;

/// The key, and the commit message, of every change in the fixture
/// (`third.rs`: `sender.put(ROOT, "k", index)` then `commit_with(...)`).
///
/// The message is not decoration. A change's hash is taken over its encoded
/// bytes and the commit message is one of those bytes, so `"k"` here and
/// `"put"` anywhere else is a different history with different hashes and
/// different bloom-filter collisions.
const third_key = "k";

// The whole-document arm of `sync.rs:225-228`, on both sides of its boundary.
//
// **The failure this exists for is silent.** A peer that sends a whole
// document when it should send a change list does not error, does not
// diverge, and fails no round-trip assertion: it ships its entire history to
// a peer that already holds almost all of it, on every sync, forever. The
// half that matters most is therefore the one that says a change list went
// out — a fix that always sends the document is indistinguishable from a
// correct implementation on the "fires" half alone.
//
// **The peer is real, and that is the point.** The peer is a document built
// by applying the sender's own first `prefix` changes, and the sender's
// `their_have` and `their_heads` are whatever the peer's *own* generated
// message left behind (`sync.rs:386-464`). Nothing about the peer's state is
// written by hand. A synthesised `their_have` is the trap: `get_hashes_to_send`
// walks **descendants** of everything the filter misses (`sync.rs:359-368`), so
// on a history with forks the set it walks is not the set that was excluded,
// and a fixture meant to be a small minority quietly becomes a large one.
//
// **The payload is asserted by type, not by length.** `carriesDocument`
// reads the chunk-type byte (`chunk.rs:232-237`), which is what upstream
// reads (`sync.rs:1404-1407`); a length check is satisfied by a change list
// of the right size and proves nothing.
test "a third of the document is the boundary, and at it a change list goes out" {
    const gpa = testing.allocator;
    // Decoded, not copied: see `third_actor_a`.
    const actor_a = try err.hexFrom(gpa, third_actor_a);
    defer gpa.free(actor_a);
    const actor_b = try err.hexFrom(gpa, third_actor_b);
    defer gpa.free(actor_b);
    for (third_cases) |case| {
        var sender = try Document.init(gpa, std.testing.io);
        defer sender.deinit();
        sender.setActorId(.{ .bytes = actor_a });
        for (0..case.total) |index| {
            // One `put` of `index` and one commit, all at the same timestamp,
            // all with the same one-character commit message: the script
            // `third` replays. The commit message is part of the encoded
            // change and therefore part of its hash, so it is written out here
            // rather than borrowed from a helper whose message is its own.
            var t = try trans.Transaction.open(gpa, &sender);
            // Sender is destroyed if any setup step returns an error.
            defer t.deinitClosed();
            _ = try t.put(.root, .{ .key = third_key }, .{ .int = @intCast(index) });
            var committed = try t.commitWith(.{ .message = third_key, .time = third_time });
            defer committed.deinit(gpa);
        }
        // **The fixture is the reference's fixture.** The head hash pins every
        // change behind it — each one depends on the one before it — and the
        // change count is the divisor `sync.rs:225` divides by.
        try expectHeadHex(gpa, &sender, case.sender_head);
        try testing.expectEqual(case.total, sender.graph.len());
        // The recorded divisor is the **truncating** third of the recorded
        // count: `31 / 3` is 10 and `33 / 3` is 11, and both appear above.
        try testing.expectEqual(case.total / 3, case.threshold);
        // And the recorded payload is what the recorded count and the recorded
        // divisor say it must be. This is a check on the corpus rather than on
        // `buildPayload`: the arm's own output is read off the wire below.
        try testing.expectEqual(case.hashes_to_send > case.threshold, case.document);

        // The peer, holding a real prefix of the sender's own changes.
        var peer = try Document.init(gpa, std.testing.io);
        defer peer.deinit();
        peer.setActorId(.{ .bytes = actor_b });
        var all = try sender.getChanges(gpa, &.{});
        defer all.deinit(gpa);
        for (all.slice()[0..case.prefix]) |built| {
            _ = try peer.applyChanges(gpa, &.{built.change});
        }
        try testing.expectEqual(case.prefix, peer.graph.len());
        if (case.peer_head.len != 0) try expectHeadHex(gpa, &peer, case.peer_head);

        // The peer's own first message, handed to the sender. This is what fills
        // the sender's `their_have` and `their_heads` with facts.
        var sender_state = State.new(gpa);
        defer sender_state.deinit();
        var peer_state = State.new(gpa);
        defer peer_state.deinit();
        const hello = (try generateSyncMessage(gpa, &peer, &peer_state)) orelse
            return error.ExpectedAMessage;
        try receiveSyncMessage(gpa, &sender, &sender_state, hello);

        // And now the message the arm decides. It is **encoded before it is
        // judged and delivered from those bytes**, because
        // `receiveSyncMessage` takes the message by value and frees it: a test
        // that asserted first and delivered afterwards would leak the message
        // on every failing path, and a leak report next to a real assertion
        // failure is the kind of noise that hides one.
        var reply = (try generateSyncMessage(gpa, &sender, &sender_state)) orelse
            return error.ExpectedAMessage;
        const reply_bytes = try reply.encode(gpa);
        reply.deinit();
        defer gpa.free(reply_bytes);

        // **The payload is what is asserted**, and it is read off the chunk
        // type byte rather than off a length: a change list of the right size
        // is the wrong payload, and a length check cannot tell them apart.
        var reply_message = try Message.decode(gpa, reply_bytes);
        defer reply_message.deinit();
        try testing.expectEqual(case.document, carriesDocument(&reply_message));
        // The whole-document arm is V2-only (`sync.rs:225`), and V2 packs every
        // change into a single chunk, so a change list here is also one chunk.
        try testing.expectEqual(msg.MessageVersion.v2, reply_message.version);
        try testing.expectEqual(@as(usize, 1), reply_message.changes.items.len);

        // Delivering the message counts what the peer gained, which is the
        // count the oracle recorded — the same measurement, on the same
        // fixture, rather than `total - prefix` assumed.
        try receiveSyncMessage(
            gpa,
            &peer,
            &peer_state,
            try Message.decode(gpa, reply_bytes),
        );
        try testing.expectEqual(case.total, peer.graph.len());
        try testing.expectEqual(
            case.hashes_to_send,
            peer.graph.len() - case.prefix,
        );
    }
}

/// That the document holds exactly the head the reference recorded, named in
/// hex. A change hash is `SHA-256` over the encoded change, so one hash pins
/// every change behind it: a fixture that drifted by one put, one timestamp or
/// one commit message fails here rather than quietly measuring a different
/// history.
fn expectHeadHex(gpa: Allocator, doc: *const Document, hex: []const u8) !void {
    const want = try err.hexFrom(gpa, hex);
    defer gpa.free(want);
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqual(@as(usize, 1), heads.len);
    try testing.expectEqualSlices(u8, want, &heads[0].bytes);
}

/// `sent` is the ascending, duplicate-free set of the document's own hashes
/// from `from` to `to`, which is what one `generateSyncMessage` must have
/// recorded for the payload it just built.
///
/// The expectation is read **off the document, not off the payload**: the
/// hashes are enumerated from the change graph and sorted, so a message that
/// carried the wrong hashes, carried one twice, or recorded them out of order
/// all fail here rather than passing a length check.
fn expectSentHashes(
    gpa: Allocator,
    doc: *Document,
    sent: []const ChangeHash,
    from: usize,
    to: usize,
) !void {
    var built = try doc.getChanges(gpa, &.{});
    defer built.deinit(gpa);
    var expected: std.ArrayList(ChangeHash) = .empty;
    defer expected.deinit(gpa);
    try testing.expectEqual(to - from, sent.len);
    for (built.slice()[from..to]) |one| try expected.append(gpa, one.change.hash);
    std.mem.sort(ChangeHash, expected.items, {}, ChangeHash.lessThan);
    try testing.expectEqualSlices(ChangeHash, expected.items, sent);
}

test "a generated message records every hash it carried, once, in order" {
    // The line under test is the bulk extend in `generateSyncMessage`
    // (`protocol.zig:588`), which is what replaced one `State.insertSent` call
    // per carried hash. What has to survive the change is the set, not the
    // call shape: `sent_hashes` is ascending and duplicate-free because
    // `State.encode` asserts it (`message.zig:524-530`) and `sentContains`
    // binary-searches it, and a merge that kept the order but lost a hash, or
    // kept the hashes but recorded one twice, would still be a set by length.
    //
    // Both payload arms are here. The first message is the **whole document**
    // — the peer advertised no heads and reads V2, so `sendDoc`
    // (`state.zig:341-344`) answers with every hash in the graph and one extend
    // records all of them. The second is a **change list**: five new hashes
    // into an empty set, which is the shape `sync-roundtrip` runs twenty-four
    // times over.
    const gpa = testing.allocator;
    var sender = try Document.init(gpa, testing.io);
    defer sender.deinit();
    sender.setActorId(.{ .bytes = "sync-sent-hashes-local" });
    var peer = try Document.init(gpa, testing.io);
    defer peer.deinit();
    peer.setActorId(.{ .bytes = "sync-sent-hashes-peer" });

    for (0..12) |index| {
        try putAndCommit(gpa, &sender, "k", .{ .int = @intCast(index) }, @intCast(index));
    }
    try testing.expectEqual(@as(usize, 12), sender.graph.len());

    var sender_state = State.new(gpa);
    defer sender_state.deinit();
    var peer_state = State.new(gpa);
    defer peer_state.deinit();

    // The peer's own first message, which is what tells the sender that the
    // peer reads V2 and holds nothing.
    {
        const hello = (try generateSyncMessage(gpa, &peer, &peer_state)) orelse
            return error.ExpectedAMessage;
        try deliver(gpa, &sender, &sender_state, hello);
    }
    // The whole document, recorded as a set of twelve.
    {
        const snapshot = (try generateSyncMessage(gpa, &sender, &sender_state)) orelse
            return error.ExpectedAMessage;
        try expectSentHashes(gpa, &sender, sender_state.sent_hashes.items, 0, 12);
        try deliver(gpa, &peer, &peer_state, snapshot);
    }
    // The peer's answer covers all of it, so the prune takes every hash back
    // out (`sync.rs:430-431`, `protocol.zig:728-731`) — and the prune is the
    // other thing that has to leave the set ascending, because it rebuilds the
    // list by filtering the old one.
    {
        const answer = (try generateSyncMessage(gpa, &peer, &peer_state)) orelse
            return error.ExpectedAMessage;
        try deliver(gpa, &sender, &sender_state, answer);
        try testing.expectEqual(@as(usize, 0), sender_state.sent_hashes.items.len);
    }
    // A delta: five changes, one payload, one extend.
    for (0..5) |index| {
        try putAndCommit(gpa, &sender, "k2", .{ .int = @intCast(index) }, @intCast(100 + index));
    }
    {
        const delta = (try generateSyncMessage(gpa, &sender, &sender_state)) orelse
            return error.ExpectedAMessage;
        try expectSentHashes(gpa, &sender, sender_state.sent_hashes.items, 12, 17);
        try deliver(gpa, &peer, &peer_state, delta);
    }
    try testing.expectEqual(@as(usize, 17), peer.graph.len());
}

// ── Zig 0.16.0 / upstream ───────────────────────────────────────────────────
//
// **diff — none.** Upstream reads
//
// ```rust
// if hashes.len() > self.change_graph.len() / 3 && sync_state.supports_v2_messages()
// ```
//
// (`sync.rs:225`) and the port reads the same decision at `protocol.zig:995`:
// `hashes.len` counts the vector after the `sent_hashes` filter of
// `sync.rs:221-224`; `doc.graph.len()` is
// `change_graph.len()` (`change_graph.rs:188-190`, the sender's **change**
// count — not the peer's, not an actor count, not a clock length), `/ 3` is an
// unsigned integer division and therefore truncating, `>` is `>` and not `>=`,
// and `state.supportsV2Messages()` is `state.rs:208-212`. So this commit adds
// the test that pins the arm and changes no behaviour.
//
// **The numbers in `third_cases` are measurements, not inferences.** They came
// from `zig build conformance -- third`, the oracle subcommand in
// `tools/oracle/src/third.rs`, which builds the same sender and the same peer,
// lets the peer's own first message fill the sender's `their_have` and
// `their_heads`, and then reports the divisor, the number of hashes the
// reference put in the payload and **which payload it sent**. The Zig side
// re-measures the count the same way — deliver the message, count the peer —
// rather than computing `total - prefix`, so a bloom false positive or a wrong
// walk in `getHashes_to_send` cannot hide behind the arithmetic.
//
// **The test has been shown to fail, on both halves.** Three mutations of
// `protocol.zig:995`, each reverted, each caught:
//
// | mutation | what the test said |
// |---|---|
// | `>=` instead of `>` | `expected false, found true` — the boundary case |
// | `if (state.supportsV2Messages())`, i.e. always the document | `expected false, found true` |
// | `/ 2` instead of `/ 3` | `expected true, found false` |
//
// A test that passes for a wrong port is not a deliverable, and the two
// directions matter separately: "always send the document" is invisible to
// the half of the corpus that expects a document.
//
// **One fixture trap, recorded because it cost a round.** `ACTOR_A` in
// `tools/oracle/src/main.rs` is **fifteen** bytes, not sixteen, and a change
// hash is `SHA-256` over bytes that include the author's id: copying the
// constant with one more `a1` builds a document that parses, loads, converges
// and reports a plausible `hashes_to_send` for every case — and is a different
// history throughout. `third_actor_a` is the decoded form, and
// `expectHeadHex` is what makes the mistake loud.
//
// ── The empty `their_have`, and the filter that is empty with it ─────────────
//
// **The reset block is right and the test beside it was wrong.** Upstream reads
//
// ```rust
// if let Some(ref their_have) = sync_state.their_have {
//     if let Some(first_have) = their_have.first().as_ref() {
//         if !first_have.last_sync.iter().all(|hash| self.has_change(hash)) {
//             return Some(Message::reset(our_heads));
//         }
//     }
// }
// ```
//
// (`sync.rs:196-206`). `their_have.first()` is `None` on an empty `Vec`, so the
// **second** `if let` is the one that cannot be reached by a peer that has
// spoken to us and forgotten: generation continues into `sync.rs:208-236` and
// the peer gets a message. `port` reads the same thing as `their_have.len > 0`
// (`protocol.zig:512-540`), which is the *shape* of the discrimination and not a
// defence against it. The state that puts a peer there is real:
// `State::parse` writes `their_have: Some(Vec::new())` (`state.rs:140`), while
// `State::default` leaves it `None` (`state.rs:32`, `:92-94`), and a peer's own reset
// message carries `Have::default()` (`sync.rs:625-638`).
//
// **What the test got wrong was the filter.** It read
//
// ```rust
// fn make_bloom_filter(&self, last_sync: Vec<ChangeHash>) -> Have {
//     let hashes = self.change_graph.get_hashes(&last_sync);
// ```
//
// (`sync.rs:310-316`) as "a filter over every change we have". It is a filter
// over every change we have added **since** `last_sync` — the field says so
// (`sync/state.rs:88-90`), and `get_hashes` says so (`change_graph.rs:476-487`,
// which folds `last_sync` into a clock and returns what the clock does not
// cover). With `shared_heads` restored to *our own heads* there is nothing
// added since, and `BloomFilter::from_hashes` over an empty iterator is
// `num_entries: 0` with no bits (`bloom.rs:125-140`). The reference says the
// same thing on the wire: `test/golden/sync.jsonl` line 5, recorded by running
// it, is a message carrying one `have` whose `last_sync` is two hashes and
// whose filter is **0 entries, 0 bits**; lines 1-3, with no shared heads yet,
// are 2 entries each.
//
// **`make_bloom_filter` does not leak and neither does `generate_sync_message`.**
// The leak that took the run down was the *caller's*: the test returned
// `error.TestUnexpectedResult` from the `num_entries > 0` assertion before the
// `message.deinit()` on its last line, so all three allocations the message
// owned — `protocol.zig:468` the `have` array, `:910` the `last_sync` copy and
// `:595` the heads — were reported as leaks against the one test, and a leak
// report is charged to every test after it. A failing assertion in these tests
// must never leak, so every message a test owns between an assertion and a
// free is now released by `defer` rather than by a trailing `deinit()`.

test "API parity external sync log retains receive event order" {
    // Two receives share one caller-owned log and produce an ordered mirror update.
    const PatchLog = @import("../patches.zig").PatchLog;
    const gpa = testing.allocator;
    var source = try Document.init(gpa, testing.io);
    defer source.deinit();
    var target = try Document.init(gpa, testing.io);
    defer target.deinit();
    var state = State.new(gpa);
    defer state.deinit();
    var log = PatchLog.active(gpa);
    defer log.deinit();
    for ([_][]const u8{ "first", "second" }, 0..) |key, index| {
        try putAndCommit(gpa, &source, key, .{ .int = @intCast(index) }, 0);
        if (index == 0) try log.bind(source.patchIdentity(), source.ops.actors.items);
        var change = (try source.getLastLocalChange(gpa)).?;
        defer change.deinit(gpa);
        var message = Message.init(gpa);
        message.heads = try source.getHeads(gpa);
        message.changes.items = try gpa.alloc([]u8, 1);
        message.changes.items[0] = try change.change.encode(gpa);
        try @This().receiveSyncMessageWithPatchLog(gpa, &target, &state, message, &log);
        const source_heads = try source.getHeads(gpa);
        defer gpa.free(source_heads);
        try expectSameHashes(source_heads, state.shared_heads);
    }
    var patches = try log.makePatches(Document, &target);
    defer patches.deinit();
    try testing.expectEqual(@as(usize, 2), patches.items.items.len);
    try testing.expectEqualStrings("first", patches.items.items[0].action.put_map.key);
    try testing.expectEqualStrings("second", patches.items.items[1].action.put_map.key);
    const first = (try readmod.get(&target, .root, .{ .key = "first" })).?;
    const second = (try readmod.get(&target, .root, .{ .key = "second" })).?;
    try testing.expectEqual(@as(i64, 0), first.value.scalar.int);
    try testing.expectEqual(@as(i64, 1), second.value.scalar.int);
}

test "API parity external sync accepts compatible empty message across documents" {
    // Empty actor tables are compatible even when the document owners differ.
    const PatchLog = @import("../patches.zig").PatchLog;
    const gpa = testing.allocator;
    var owner = try Document.init(gpa, testing.io);
    defer owner.deinit();
    var target = try Document.init(gpa, testing.io);
    defer target.deinit();
    var log = PatchLog.active(gpa);
    defer log.deinit();
    try log.bind(owner.patchIdentity(), owner.ops.actors.items);
    var state = State.new(gpa);
    defer state.deinit();
    state.in_flight = true;
    state.peer_read_only = true;
    var message = Message.init(gpa);
    message.flags = .{ .bits = msg.MessageFlags.sync_reset };
    try @This().receiveSyncMessageWithPatchLog(gpa, &target, &state, message, &log);
    try testing.expect(!state.in_flight);
    try testing.expect(!state.peer_read_only);
    try testing.expect(state.their_capabilities != null);
    try testing.expectEqual(@as(usize, 0), target.graph.len());
    try testing.expectEqual(@as(usize, 0), log.events.items.len);
}

test "API parity external sync actor mismatch preserves document peer state and retained log" {
    // A nonempty B receiver cannot publish an A-owned event stream, including reset flags.
    const gpa = testing.allocator;
    var owner = try Document.init(gpa, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = "A" });
    // Raw transactions default to inactive logs; retain a real A-owned event.
    var sink = @import("../patches.zig").PatchLog.active(gpa);
    defer sink.deinit();
    var tx = try trans.Transaction.openWithPatchLog(gpa, &owner, &sink, null);
    defer tx.deinitClosed();
    _ = try tx.put(.root, .{ .key = "owned" }, .{ .bool_value = true });
    var committed = try tx.commit();
    defer committed.deinit(gpa);
    var log = committed.patch_log.take();
    defer log.deinit();
    var target = try Document.init(gpa, testing.io);
    defer target.deinit();
    target.setActorId(.{ .bytes = "B" });
    try putAndCommit(gpa, &target, "base", .{ .bool_value = true }, 0);
    var source = try target.fork(gpa);
    defer source.deinit();
    source.setActorId(.{ .bytes = "B" });
    try putAndCommit(gpa, &source, "incoming", .{ .int = 2 }, 0);
    var incoming = (try source.getLastLocalChange(gpa)).?;
    defer incoming.deinit(gpa);
    const before_save = try target.save(gpa);
    defer gpa.free(before_save);
    const before_heads = try target.getHeads(gpa);
    defer gpa.free(before_heads);
    try testing.expectEqual(@as(usize, 1), target.graph.len());
    try testing.expectEqual(@as(usize, 1), before_heads.len);
    try expectSameHashes(before_heads, incoming.change.deps);
    try testing.expectEqualStrings("B", incoming.change.actor.bytes);
    try testing.expectEqual(@as(usize, 1), log.actors.items.len);
    try testing.expectEqualStrings("A", log.actors.items[0].bytes);
    try testing.expect(log.isActive());
    try testing.expectEqual(@as(usize, 1), log.events.items.len);
    try testing.expectError(error.PatchLogMismatch, log.validateActors(target.ops.actors.items));
    const before_actor = target.actor;
    const before_base = (try readmod.get(&target, .root, .{ .key = "base" })).?;
    try testing.expect(before_base.value.scalar.bool_value);
    try testing.expect((try readmod.get(&target, .root, .{ .key = "incoming" })) == null);
    const before_actors = target.ops.actors.items.ptr;
    const before_events = log.events.items;
    const before_log_actors = log.actors.items;
    const before_completed = log.completed.items.items;
    const before_identity = log.identity;
    var state = State.new(gpa);
    defer state.deinit();
    state.in_flight = true;
    state.peer_read_only = true;
    state.have_responded = true;
    state.needs_reset = true;
    state.shared_heads = try gpa.dupe(ChangeHash, before_heads);
    state.last_sent_heads = try gpa.dupe(ChangeHash, before_heads);
    state.their_heads = try gpa.dupe(ChangeHash, before_heads);
    state.their_need = try gpa.dupe(ChangeHash, before_heads);
    try state.extendSent(before_heads);
    const before_state = state;
    var message = Message.init(gpa);
    errdefer message.deinit();
    message.flags = .{ .bits = msg.MessageFlags.sync_reset };
    message.heads = try source.getHeads(gpa);
    {
        const encoded = try incoming.change.encode(gpa);
        errdefer gpa.free(encoded);
        message.changes.items = try gpa.alloc([]u8, 1);
        message.changes.items[0] = encoded;
    }
    const consumed = message;
    message = Message.init(gpa);
    try testing.expectError(error.PatchLogMismatch, @This().receiveSyncMessageWithPatchLog(gpa, &target, &state, consumed, &log));
    try testing.expectEqualDeep(before_state, state);
    const after_save = try target.save(gpa);
    defer gpa.free(after_save);
    const after_heads = try target.getHeads(gpa);
    defer gpa.free(after_heads);
    try testing.expectEqualSlices(u8, before_save, after_save);
    try expectSameHashes(before_heads, after_heads);
    try testing.expect(before_actors == target.ops.actors.items.ptr);
    try testing.expectEqual(@as(usize, 1), target.ops.actors.items.len);
    try testing.expectEqualStrings("B", target.ops.actors.items[0].bytes);
    try testing.expectEqualDeep(before_actor, target.actor);
    const after_base = (try readmod.get(&target, .root, .{ .key = "base" })).?;
    try testing.expect(after_base.id.eql(before_base.id));
    try testing.expect(after_base.value.scalar.bool_value);
    try testing.expect((try readmod.get(&target, .root, .{ .key = "incoming" })) == null);
    try testing.expect(before_events.ptr == log.events.items.ptr);
    try testing.expectEqual(before_events.len, log.events.items.len);
    try testing.expect(before_log_actors.ptr == log.actors.items.ptr);
    try testing.expectEqual(before_log_actors.len, log.actors.items.len);
    try testing.expect(before_completed.ptr == log.completed.items.items.ptr);
    try testing.expectEqual(before_completed.len, log.completed.items.items.len);
    try testing.expectEqual(before_identity, log.identity);
    var retained = try log.makePatches(Document, &owner);
    defer retained.deinit();
    try testing.expectEqual(@as(usize, 1), retained.items.items.len);
    try testing.expectEqualStrings("owned", retained.items.items[0].action.put_map.key);
    try testing.expect(retained.items.items[0].action.put_map.value.scalar.bool_value);
}

test "API parity external sync does not migrate actors for empty or read only receives" {
    // An ignored payload cannot create an actor mismatch that the reference never checks.
    const PatchLog = @import("../patches.zig").PatchLog;
    const gpa = testing.allocator;
    var owner = try Document.init(gpa, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = "A" });
    try putAndCommit(gpa, &owner, "owned", .{ .bool_value = true }, 0);
    var target = try Document.init(gpa, testing.io);
    defer target.deinit();
    target.setActorId(.{ .bytes = "B" });
    try putAndCommit(gpa, &target, "base", .{ .bool_value = true }, 0);
    var log = PatchLog.active(gpa);
    defer log.deinit();
    try log.bind(owner.patchIdentity(), owner.ops.actors.items);
    const log_actors = log.actors.items;
    const log_identity = log.identity;
    const before = try target.save(gpa);
    defer gpa.free(before);
    for ([_]bool{ false, true }) |read_only| {
        var state = State.new(gpa);
        defer state.deinit();
        state.read_only = read_only;
        state.in_flight = true;
        var message = Message.init(gpa);
        errdefer message.deinit();
        message.flags = .{ .bits = msg.MessageFlags.sync_reset };
        if (read_only) {
            var incoming = (try target.getLastLocalChange(gpa)).?;
            defer incoming.deinit(gpa);
            const encoded = try incoming.change.encode(gpa);
            errdefer gpa.free(encoded);
            message.changes.items = try gpa.alloc([]u8, 1);
            message.changes.items[0] = encoded;
        }
        const consumed = message;
        message = Message.init(gpa);
        try @This().receiveSyncMessageWithPatchLog(gpa, &target, &state, consumed, &log);
        try testing.expect(!state.in_flight);
        try testing.expectEqual(read_only, state.read_only);
    }
    const after = try target.save(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
    try testing.expect(log_actors.ptr == log.actors.items.ptr);
    try testing.expectEqual(log_actors.len, log.actors.items.len);
    try testing.expectEqual(log_identity, log.identity);
    try testing.expectEqual(@as(usize, 0), log.events.items.len);
}

fn generateOrderedBatchAndFree(
    gpa: Allocator,
    sender: *Document,
    requested: []const ChangeHash,
    framed: []const Framed,
    v2: bool,
) !void {
    var state = State.new(gpa);
    defer state.deinit();
    state.their_heads = try gpa.dupe(ChangeHash, &.{framed[0].hash});
    state.their_have = try gpa.alloc(Have, 0);
    state.their_need = try gpa.dupe(ChangeHash, requested);
    if (v2) state.their_capabilities = try gpa.dupe(Capability, &.{.message_v2});
    var message = (try generateSyncMessage(gpa, sender, &state)) orelse
        return error.ExpectedAMessage;
    defer message.deinit();
    try testing.expectEqual(
        if (v2) msg.MessageVersion.v2 else msg.MessageVersion.v1,
        message.version,
    );
    try testing.expect(!carriesDocument(&message));
    const joined = try message.changes.join(gpa);
    defer gpa.free(joined);
    const actual = try splitStream(gpa, joined);
    defer {
        for (actual) |frame| gpa.free(frame.bytes);
        gpa.free(actual);
    }
    try testing.expectEqual(requested.len, actual.len);
    for (actual, requested) |frame, hash| {
        try testing.expect(hash.eql(frame.hash));
        for (framed) |expected| {
            if (!expected.hash.eql(hash)) continue;
            try testing.expectEqualSlices(u8, expected.bytes, frame.bytes);
        }
    }
    // Without an acknowledgement the selected hashes are not sent twice.
    state.in_flight = false;
    const repeated = try generateSyncMessage(gpa, sender, &state);
    if (repeated) |owned| {
        var reply = owned;
        defer reply.deinit();
        try testing.expect(reply.changes.isEmpty());
    }
}

test "sync change batches retain requested wire order in V1 and threshold-equal V2" {
    const gpa = testing.allocator;
    const bytes = try twoChangeStream(gpa);
    defer gpa.free(bytes);
    const framed = try splitStream(gpa, bytes);
    defer {
        for (framed) |frame| gpa.free(frame.bytes);
        gpa.free(framed);
    }
    var sender = try docWith(gpa, &.{bytes});
    defer sender.deinit();
    sender.setActorId(.{ .bytes = "ordered-batch-sender" });
    const requested = [_]ChangeHash{ framed[1].hash, framed[0].hash };
    // V1 must still send changes when the selected set exceeds a third.
    try generateOrderedBatchAndFree(gpa, &sender, &requested, framed, false);
    for (0..4) |i| {
        try putAndCommit(gpa, &sender, "more", .{ .int = @intCast(i) }, @intCast(i));
    }
    for ([_]bool{ false, true }) |v2| {
        try generateOrderedBatchAndFree(gpa, &sender, &requested, framed, v2);
        try testing.checkAllAllocationFailures(
            gpa,
            generateOrderedBatchAndFree,
            .{ &sender, &requested, framed, v2 },
        );
        try generateOrderedBatchAndFree(gpa, &sender, &requested, framed, v2);
    }
}

test "growing sync history sends only new changes while acknowledgements are withheld" {
    const gpa = testing.allocator;
    var sender = try Document.init(gpa, testing.io);
    defer sender.deinit();
    sender.setActorId(.{ .bytes = "withheld-ack-sender" });
    var peer = try Document.init(gpa, testing.io);
    defer peer.deinit();
    var sender_state = State.new(gpa);
    defer sender_state.deinit();
    var peer_state = State.new(gpa);
    defer peer_state.deinit();
    for (0..12) |i| {
        try putAndCommit(gpa, &sender, "base", .{ .int = @intCast(i) }, @intCast(i));
    }
    try deliver(gpa, &sender, &sender_state, (try generateSyncMessage(gpa, &peer, &peer_state)).?);
    try deliver(gpa, &peer, &peer_state, (try generateSyncMessage(gpa, &sender, &sender_state)).?);
    try deliver(gpa, &sender, &sender_state, (try generateSyncMessage(gpa, &peer, &peer_state)).?);
    for (0..3) |i| {
        try putAndCommit(gpa, &sender, "delta", .{ .int = @intCast(i) }, @intCast(100 + i));
        var latest = (try sender.getLastLocalChange(gpa)).?;
        defer latest.deinit(gpa);
        const expected = try latest.change.encode(gpa);
        defer gpa.free(expected);
        var outgoing = (try generateSyncMessage(gpa, &sender, &sender_state)).?;
        errdefer outgoing.deinit();
        try testing.expectEqual(@as(usize, 1), outgoing.changes.items.len);
        try testing.expectEqualSlices(u8, expected, outgoing.changes.items[0]);
        try expectSentHashes(gpa, &sender, sender_state.sent_hashes.items, 12, 13 + i);
        const transferred = outgoing;
        outgoing = Message.init(gpa);
        try deliver(gpa, &peer, &peer_state, transferred);
    }
    try sender.debugCmp(&peer);
    // Deliver just the eventual acknowledgement, then the retained sent set clears.
    try deliver(gpa, &sender, &sender_state, (try generateSyncMessage(gpa, &peer, &peer_state)).?);
    try testing.expectEqual(@as(usize, 0), sender_state.sent_hashes.items.len);
}

fn generateDuplicateNeedAndFree(
    gpa: Allocator,
    sender: *Document,
    requested: []const ChangeHash,
    framed: []const Framed,
    v2: bool,
    with_have: bool,
    document: bool,
) !void {
    var peer = Message.init(gpa);
    defer peer.deinit();
    peer.version = if (v2) .v2 else .v1;
    if (v2) peer.flags = .{ .bits = 0 };
    peer.heads = try gpa.dupe(ChangeHash, &.{framed[0].hash});
    peer.need = try gpa.dupe(ChangeHash, requested);
    if (with_have) {
        // Nothing is in to_send, so even with have every need occurrence survives.
        var have = try haveWithLastSync(gpa, sender.graph.getHeads());
        errdefer have.deinit();
        peer.have = try gpa.alloc(Have, 1);
        peer.have[0] = have;
    }
    const peer_bytes = try peer.encode(gpa);
    defer gpa.free(peer_bytes);
    var state = State.new(gpa);
    defer state.deinit();
    try receiveSyncMessage(gpa, sender, &state, try Message.decode(gpa, peer_bytes));
    try expectSameHashes(requested, state.their_need.?);
    var message = (try generateSyncMessage(gpa, sender, &state)) orelse
        return error.ExpectedAMessage;
    defer message.deinit();
    const encoded = try message.encode(gpa);
    defer gpa.free(encoded);
    var decoded = try Message.decode(gpa, encoded);
    defer decoded.deinit();
    try testing.expectEqual(
        if (v2) msg.MessageVersion.v2 else msg.MessageVersion.v1,
        decoded.version,
    );
    try testing.expectEqual(document, carriesDocument(&decoded));
    if (!document) {
        const joined = try decoded.changes.join(gpa);
        defer gpa.free(joined);
        const actual = try splitStream(gpa, joined);
        defer {
            for (actual) |frame| gpa.free(frame.bytes);
            gpa.free(actual);
        }
        try testing.expectEqual(requested.len, actual.len);
        for (actual, requested) |frame, hash| {
            try testing.expect(hash.eql(frame.hash));
            const expected = blk: {
                for (framed) |candidate| {
                    if (candidate.hash.eql(hash)) break :blk candidate;
                }
                return error.TestUnexpectedResult;
            };
            try testing.expectEqualSlices(u8, expected.bytes, frame.bytes);
        }
    }
    state.in_flight = false;
    if (try generateSyncMessage(gpa, sender, &state)) |owned| {
        var reply = owned;
        defer reply.deinit();
        try testing.expect(reply.changes.isEmpty());
    }
}

test "duplicate encoded peer need retains exact frames and counts occurrences at the V2 boundary" {
    // Three occurrences equal the threshold; four exceed it even with only two unique hashes.
    const gpa = testing.allocator;
    const bytes = try twoChangeStream(gpa);
    defer gpa.free(bytes);
    const original = try splitStream(gpa, bytes);
    defer {
        for (original) |frame| gpa.free(frame.bytes);
        gpa.free(original);
    }
    var sender = try docWith(gpa, &.{bytes});
    defer sender.deinit();
    sender.setActorId(.{ .bytes = "duplicate-need-sender" });
    const empty_hash = try sender.emptyCommit(gpa, "empty", 0);
    var empty = (try sender.getChangeByHash(gpa, empty_hash)).?;
    defer empty.deinit(gpa);
    const empty_bytes = try empty.change.encode(gpa);
    defer gpa.free(empty_bytes);
    const framed = [_]Framed{
        original[0],
        original[1],
        .{ .bytes = empty_bytes, .hash = empty_hash },
    };
    for (0..6) |i| {
        try putAndCommit(gpa, &sender, "more", .{ .int = @intCast(i) }, @intCast(i));
    }
    try testing.expectEqual(@as(usize, 9), sender.graph.len());
    var equal = [_]ChangeHash{ original[0].hash, original[0].hash, empty_hash };
    var above = [_]ChangeHash{ original[1].hash, empty_hash, original[1].hash, empty_hash };
    // The wire encoder accepts sorted lists with repeats; decoding must keep every repeat.
    std.mem.sort(ChangeHash, &equal, {}, ChangeHash.lessThan);
    std.mem.sort(ChangeHash, &above, {}, ChangeHash.lessThan);
    for ([_]bool{ false, true }) |v2| {
        for ([_]bool{ false, true }) |with_have| {
            for ([_][]const ChangeHash{ &equal, &above }) |requested| {
                const document = v2 and requested.len > sender.graph.len() / 3;
                try generateDuplicateNeedAndFree(
                    gpa,
                    &sender,
                    requested,
                    &framed,
                    v2,
                    with_have,
                    document,
                );
                try testing.checkAllAllocationFailures(
                    gpa,
                    generateDuplicateNeedAndFree,
                    .{ &sender, requested, framed[0..], v2, with_have, document },
                );
                try generateDuplicateNeedAndFree(
                    gpa,
                    &sender,
                    requested,
                    &framed,
                    v2,
                    with_have,
                    document,
                );
            }
        }
    }
}
