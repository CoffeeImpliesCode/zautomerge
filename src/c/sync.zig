//! The sync half of the C ABI: `AMsyncHave`, `AMsyncMessage` and
//! `AMsyncState`, and the fifteen `AMsync*` entry points over them.
//!
//! A direct translation of `rust/automerge-c/src/sync.rs` (7 lines),
//! `src/sync/have.rs` (42), `src/sync/message.rs` (146) and
//! `src/sync/state.rs` (262). `doc.rs`'s two sync entry points
//! (`AMgenerateSyncMessage`, `AMreceiveSyncMessage`) take the two handles
//! defined here, so they live in [doc.zig](doc.zig); this file is the state
//! machine's own surface.
//!
//! # Where the C ABI and the port disagree, and why
//!
//! ## The three `RefCell<BTreeMap<…>>` storages are not ported
//!
//! `AMsyncMessage` carries `changes_storage` and `haves_storage`
//! (`src/sync/message.rs:27-28`) and `AMsyncState` carries
//! `their_haves_storage` (`src/sync/state.rs:26`). All three are written once,
//! in the constructor, and **read nowhere** — a `grep` over the reference
//! finds exactly the six lines that build them and no reader. They exist to
//! keep a `*const AMchange` / `*const AMsyncHave` alive for as long as the
//! message or state does, and the port does not need them, because
//! **every handle a C caller can reach is reached through an `AMitem`**, and an
//! `AMitem` in this port stores the handle **inline in its own `Value`**
//! ([doc.zig](doc.zig), `Value.sync_message` / `Value.sync_state` /
//! `Value.change`). `AMitemToSyncMessage` and friends therefore hand out a
//! pointer into the item's own heap allocation, which outlives every call the
//! C side can make. Porting a map that nothing reads would be
//! [AGENTS.md](../AGENTS.md)'s forbidden dead code.
//!
//! ## `AMreceiveSyncMessage` receives a **copy**, so a handle is reusable
//!
//! `protocol.receiveSyncMessage` takes its `Message` **by value** and *moves*
//! `heads`, `need` and `have` into the peer state (`sync.rs:459-461`) before
//! freeing the message it was given (`sync.rs:639-648`). Upstream gets away
//! with a C handle that stays alive across the call because it passes a
//! **clone** (`doc.rs:800`, `sync_message.as_ref().clone()`), and that is what
//! makes a handle reusable: the reference's
//! `test_should_not_reply_if_we_have_no_data_as_well_after_the_first_round`
//! receives the same `m2` twice (`sync_tests.c:160`, `:170`).
//!
//! This port has no `Message.clone`, so [`AMsyncMessage.cloneForReceive`]
//! writes one and `AMreceiveSyncMessage` receives the copy. **Handing the
//! message itself over instead** — an `owns_payload` flag set before the
//! receive, which is what this file used to do — has two answers, both wrong:
//! the receive frees `changes` with the message
//! ([`src/sync/message.zig:344-351`](../../github-automerge-automerge/rust/automerge/src/sync/message.zig)),
//! which the flag never covered, so `AMresultFree` freed the chunk list a
//! second time; and a second receive of the same handle read the lists the
//! first one had already handed to the peer state.
//!
//! ## `AMsyncStateEqual` spells the reference's `#[derive(PartialEq)]` out
//!
//! The reference derives it over `am::sync::State` (`src/sync/state.rs:22`) and
//! the port's [`State`](../sync/state.zig) has no `eql`, so
//! [`statesEqual`] compares its thirteen fields. That is a derive, not a
//! document answer, and the field list is the port's `State` declaration
//! ([`state.zig:120-177`](../../github-automerge-automerge/rust/automerge/src/sync/state.zig)) field for field.
//!
//! ## A null `has_value` is an error result, not a trap
//!
//! `AMsyncStateTheirHaves`, `AMsyncStateTheirHeads` and `AMsyncStateTheirNeeds`
//! document `\pre has_value != NULL` and the reference dereferences it
//! unconditionally (`state.rs:169`, `:222`, `:254`). A Zig `export` that
//! trusted the precondition would turn a C bug into a segfault, so this port
//! checks and returns an error result. That is a superset of the
//! precondition, not a change of contract: every caller that honours the
//! precondition takes the same path as upstream.
//!
//! # Thread confinement
//!
//! **These three handles are confined to one thread at a time, like every
//! other value in the ABI.** Nothing here synchronises: the handles own their
//! bodies outright and share nothing, but they are reached *through* an
//! `AMresult`, and the item holding one counts its references in a plain
//! `usize` ([`AMitem.retain`](../c/doc.zig)).
//!
//! **Calls from different threads must use one caller-owned global
//! serialization boundary, even across distinct handles; they must not
//! overlap.** These handles own their bodies outright and share nothing with
//! each other, but the whole ABI shares one process-wide single-threaded
//! `std.Io` provider ([`c_io`](../c/doc.zig)) for document constructors and
//! actor-id entropy. Lazy handle caches elsewhere and non-atomic item reference
//! counts also need serialization; a thread-safe `malloc` is not sufficient.
//!
//! Hold the caller's lock through each outer call and its callbacks. An
//! `AMstackCallback` invoked by `AMstackResult`, `AMstackItem` or `AMstackItems`
//! may synchronously inspect the stack and result, including advancing a local
//! borrowed `AMitems` cursor or copying diagnostics with `AMstrdup`, on the
//! invoking thread under that already-held lock; nested inspection must not
//! reacquire or release it. Diagnostic copies are independently owned and need
//! `free`. Keep the stack and result live without popping, freeing, replacing
//! or relinking them.
//! This does not permit general mutation, other reentrancy or cross-thread
//! entry. `include/automerge.h`'s `\section threads` and `AMstackCallback`
//! contract state the full rule and callback lifetimes.

const std = @import("std");
const builtin = @import("builtin");

const err = @import("../error.zig");
const types = @import("../types.zig");
const statemod = @import("../sync/state.zig");
const msgmod = @import("../sync/message.zig");
const bloommod = @import("../sync/bloom.zig");
const docmod = @import("doc.zig");

const Allocator = std.mem.Allocator;
const ChangeHash = types.ChangeHash;

/// A borrow, never an owner. Rust: `src/byte_span.rs:25-35`.
pub const AMbyteSpan = docmod.AMbyteSpan;

/// `AMresult` over this port's item type. Instantiated in [doc.zig](doc.zig).
pub const AMresult = docmod.AMresult;

/// `AMitems` over this port's item type. Rust: `src/items.rs:125-132`.
pub const AMitems = docmod.AMitems;

/// The allocator the C ABI allocates from. See [doc.zig](doc.zig).
pub const c_allocator = docmod.c_allocator;

/// The allocator these three handles allocate with. The reference resolves it
/// through Rust's global `Box` (`src/result.rs:95`); a C ABI with fixed
/// signatures cannot carry one, and `c_allocator` is the only choice that
/// keeps `AMresultFree` and `free()` the same act. Rust: `src/result.rs:95`.
const gpa = c_allocator;

// ---------------------------------------------------------------------------
// AMsyncHave. Rust: src/sync/have.rs.
// ---------------------------------------------------------------------------

/// A summary of the changes that the sender of a synchronization message
/// already has. Rust: `src/sync/have.rs:9-10`.
///
/// The whole of the reference is `pub struct AMsyncHave(am::sync::Have)`, so
/// the body is the port's [Have](../sync/state.zig) by value and this handle
/// owns it. `AMsyncHaveLastSync` hands out a span into it, so the handle
/// outlives the span by exactly the reference's margin.
pub const AMsyncHave = struct {
    /// The allocator that built the body, because [`Have.deinit`](../sync/state.zig)
    /// takes none.
    gpa: Allocator,
    /// The have itself. Rust: `body: am::sync::Have` (`src/sync/have.rs:9-10`),
    /// owned by value because the reference's newtype owns it the same way.
    body: statemod.Have,

    /// `AMsyncHave::new`. Rust: `src/sync/have.rs:14-16`.
    pub fn init(alloc: Allocator, have: statemod.Have) AMsyncHave {
        return .{ .gpa = alloc, .body = have };
    }

    /// Releases the filter and the hash list, then poisons the cell.
    ///
    /// **A span from [`lastSync`] dies here.** A handle reaches a C caller
    /// only inside an `AMitem` inside an `AMresult`, so this runs from
    /// `AMresultFree` and there is no `AMsyncHaveFree`; a caller that reads
    /// the span after freeing the result has a use-after-free.
    pub fn deinit(self: *AMsyncHave) void {
        self.body.deinit();
        self.* = undefined;
    }

    /// The heads at the sender's last successful sync. Rust:
    /// `sync_have.as_ref().last_sync.as_slice()` (`src/sync/have.rs:39`).
    pub fn lastSync(self: *const AMsyncHave) []const ChangeHash {
        return self.body.last_sync;
    }

    /// `#[derive(Eq, PartialEq)]` (Rust: `src/sync/have.rs:9`) compares the
    /// wrapped `Have`, which compares `last_sync` and the filter. The port's
    /// [`Have`](../sync/state.zig) has no `eql`, so this spells the pair out:
    /// the same list, then the same filter bytes.
    pub fn eql(a: AMsyncHave, b: AMsyncHave) bool {
        if (a.body.last_sync.len != b.body.last_sync.len) return false;
        for (a.body.last_sync, b.body.last_sync) |x, y| {
            if (!x.eql(y)) return false;
        }
        const ab = a.body.bloom.toBytes(a.gpa) catch return false;
        defer a.gpa.free(ab);
        const bb = b.body.bloom.toBytes(b.gpa) catch return false;
        defer b.gpa.free(bb);
        return std.mem.eql(u8, ab, bb);
    }
};

// ---------------------------------------------------------------------------
// AMsyncMessage. Rust: src/sync/message.rs.
// ---------------------------------------------------------------------------

/// A synchronization message for a peer. Rust: `src/sync/message.rs:24-31`.
///
/// The reference's `body` is an `am::sync::Message`; its two
/// `RefCell<BTreeMap<…>>` storages and its `bytes` / `fmt_str` caches are all
/// never read — the reference's `AMsyncMessage` has no `to_bytes` and no
/// `to_str` — and are not ported. See the module doc.
pub const AMsyncMessage = struct {
    /// The allocator the body was built with. [`msgmod.Message.deinit`](../sync/message.zig)
    /// takes none, so this is the one place the handle records it.
    gpa: Allocator,
    /// The message. Rust: `body: am::sync::Message` (`src/sync/message.rs:25`).
    body: msgmod.Message,
    // `owns_payload` is gone: the handle now always owns its whole body,
    // because the receive path is handed a copy. See the module doc.

    /// `AMsyncMessage::new`. Rust: `src/sync/message.rs:34-40`.
    pub fn init(alloc: Allocator, message: msgmod.Message) AMsyncMessage {
        return .{ .gpa = alloc, .body = message };
    }

    /// Releases the message's heads, needs, haves and change chunks, then
    /// poisons the cell. Rust: the `Drop` upstream gets from its own fields.
    ///
    /// **A handle is reusable because the receive path is handed a copy**, not
    /// because this is a no-op; see the module doc. Calling it twice, or
    /// after the owning result has been freed, is a double free.
    pub fn deinit(self: *AMsyncMessage) void {
        self.body.deinit();
        self.* = undefined;
    }

    /// The copy [`AMreceiveSyncMessage`] hands to the receive path, and the
    /// one that makes a C handle reusable. See the module doc: upstream
    /// clones there too (`doc.rs:800`, `sync_message.as_ref().clone()`).
    pub fn cloneForReceive(self: *const AMsyncMessage) Allocator.Error!msgmod.Message {
        return cloneMessage(self.gpa, self.body);
    }
};

/// A deep copy of `src`: every list, every `have`'s filter and every chunk
/// element is duplicated, so the copy and the original free independently.
///
/// `#[derive(Clone)]` over `am::sync::Message` (`sync.rs:529-547`) is the same
/// thing. A filter is cloned through its own round trip — `toBytes` then
/// `parse`, [`src/sync/bloom.zig:137-157`, `:184-251`](../sync/bloom.zig) — so
/// one built by `addHash` and one decoded from the wire clone alike. Nothing
/// is assigned into the result until every allocation has succeeded, so each
/// `errdefer` owns exactly the buffer it made.
fn cloneMessage(alloc: Allocator, src: msgmod.Message) Allocator.Error!msgmod.Message {
    const heads = try alloc.dupe(ChangeHash, src.heads);
    errdefer alloc.free(heads);
    const need = try alloc.dupe(ChangeHash, src.need);
    errdefer alloc.free(need);

    var haves: []statemod.Have = &.{};
    errdefer {
        for (haves) |*h| h.deinit();
        alloc.free(haves);
    }
    if (src.have.len != 0) {
        haves = try alloc.alloc(statemod.Have, src.have.len);
        var filled: usize = 0;
        errdefer {
            for (haves[0..filled]) |*h| h.deinit();
        }
        for (src.have) |h| {
            const filter_bytes = try h.bloom.toBytes(alloc);
            defer alloc.free(filter_bytes);
            const filter = bloommod.BloomFilter.parse(alloc, filter_bytes) catch
                return error.OutOfMemory;
            haves[filled] = .{
                .gpa = alloc,
                .last_sync = try alloc.dupe(ChangeHash, h.last_sync),
                .bloom = filter,
            };
            filled += 1;
        }
    }

    var chunks: [][]u8 = &.{};
    errdefer {
        for (chunks) |c| alloc.free(c);
        alloc.free(chunks);
    }
    if (src.changes.items.len != 0) {
        chunks = try alloc.alloc([]u8, src.changes.items.len);
        var filled: usize = 0;
        errdefer {
            for (chunks[0..filled]) |c| alloc.free(c);
        }
        for (src.changes.items) |c| {
            chunks[filled] = try alloc.dupe(u8, c);
            filled += 1;
        }
    }

    return .{
        .gpa = alloc,
        .heads = heads,
        .need = need,
        .have = haves,
        .changes = .{ .items = chunks, .gpa = alloc },
        .flags = src.flags,
        .version = src.version,
    };
}

// ---------------------------------------------------------------------------
// AMsyncState. Rust: src/sync/state.rs.
// ---------------------------------------------------------------------------

/// The state of synchronization with a peer. Rust: `src/sync/state.rs:21-25`.
///
/// `their_haves_storage` is never read; see the module doc.
pub const AMsyncState = struct {
    /// The allocator the body was built with. [`State.deinit`](../sync/state.zig)
    /// takes none.
    gpa: Allocator,
    /// The state. Rust: `body: am::sync::State` (`src/sync/state.rs:22`).
    body: statemod.State,

    /// `AMsyncState::new`. Rust: `src/sync/state.rs:29-34`.
    pub fn init(alloc: Allocator, state: statemod.State) AMsyncState {
        return .{ .gpa = alloc, .body = state };
    }

    /// Releases the state's thirteen fields and poisons the cell.
    ///
    /// **A handle reaches a C caller only inside an item inside a result**,
    /// so this runs from `AMresultFree`; `AMgenerateSyncMessage` and
    /// `AMreceiveSyncMessage` mutate through `AMitemToSyncState` and never
    /// free. There is no `AMsyncStateFree`.
    pub fn deinit(self: *AMsyncState) void {
        self.body.deinit();
        self.* = undefined;
    }
};

/// `#[derive(Eq, PartialEq)]` over `am::sync::State` (Rust:
/// `src/sync/state.rs:22`). The port's [`State`](../sync/state.zig) declares
/// thirteen fields (`src/sync/state.zig:120-177`) and has no `eql`, so this
/// compares each of them, in declaration order. **The optional lists compare by
/// presence and then by content**: `None != Some(&.{})`, which is what a derive
/// over `Option<Vec<T>>` gives.
pub fn statesEqual(a: statemod.State, b: statemod.State) bool {
    if (!hashListEql(a.shared_heads, b.shared_heads)) return false;
    if (!hashListEql(a.last_sent_heads, b.last_sent_heads)) return false;
    if (!optHashesEql(a.their_heads, b.their_heads)) return false;
    if (!optHashesEql(a.their_need, b.their_need)) return false;
    if ((a.their_have == null) != (b.their_have == null)) return false;
    if (a.their_have) |x| {
        const y = b.their_have.?;
        if (x.len != y.len) return false;
        for (x, y) |*hx, *hy| {
            if (!AMsyncHave.eql(.{ .gpa = a.gpa, .body = hx.* }, .{ .gpa = b.gpa, .body = hy.* }))
                return false;
        }
    }
    if (!hashListEql(a.sent_hashes.items, b.sent_hashes.items)) return false;
    if (a.in_flight != b.in_flight) return false;
    if (a.have_responded != b.have_responded) return false;
    if (!capsEql(a.their_capabilities, b.their_capabilities)) return false;
    if (a.read_only != b.read_only) return false;
    if (a.peer_read_only != b.peer_read_only) return false;
    if (a.needs_reset != b.needs_reset) return false;
    return true;
}

fn hashListEql(a: []const ChangeHash, b: []const ChangeHash) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

fn optHashesEql(a: ?[]const ChangeHash, b: ?[]const ChangeHash) bool {
    if ((a == null) != (b == null)) return false;
    const x = a orelse return true;
    return hashListEql(x, b.?);
}

fn capsEql(a: ?[]const msgmod.Capability, b: ?[]const msgmod.Capability) bool {
    if ((a == null) != (b == null)) return false;
    const x = a orelse return true;
    return std.mem.eql(msgmod.Capability, x, b.?);
}

// ---------------------------------------------------------------------------
// The result helpers every entry point below shares.
//
// Upstream spells these `to_result!(sync_message)`, `to_sync_state!(sync_state)`
// and the literal `AMresult::error("Invalid `AMsync*`").into()`. The macro arms
// are at `src/sync/message.rs:12-19` and `src/sync/state.rs:8-15`; the strings
// are reproduced verbatim because a C caller can match on them.
// ---------------------------------------------------------------------------

/// `Err(e) => AMresult::error(&e.to_string()).into()` (Rust:
/// `src/result.rs:466`), with this port's spelling of the message: a propagated
/// error is a Zig error, and [`@errorName`] is its only stable name. Upstream's
/// `AutomergeError` has no Zig spelling, so this is a recorded deviation and
/// the *hard-coded* messages below are not affected by it.
fn failWith(alloc: Allocator, e: anyerror) ?*AMresult {
    return docmod.boxError(alloc, @errorName(e)) catch null;
}

/// An empty **success**. `Default::default()` in every
/// `match … { None => Default::default() }` arm of the reference
/// (`src/sync/message.rs:98`, `src/sync/state.rs:199`).
fn emptyOk(alloc: Allocator) ?*AMresult {
    return docmod.boxEmpty(alloc) catch null;
}

/// The three "Invalid `AMsync*`" messages. Rust: `src/sync/message.rs:17`,
/// `src/sync/state.rs:13`, and `doc.rs:27-28` for the state variant the
/// document's two entry points use.
fn invalidState(alloc: Allocator) ?*AMresult {
    return docmod.boxError(alloc, "Invalid `AMsyncState*`") catch null;
}

fn invalidMessage(alloc: Allocator) ?*AMresult {
    return docmod.boxError(alloc, "Invalid `AMsyncMessage*`") catch null;
}

/// A null out-parameter. See the module doc: the reference's `\pre` becomes a
/// refused call here rather than a segfault.
fn invalidOutParam(alloc: Allocator) ?*AMresult {
    return docmod.boxError(alloc, "Invalid `bool*`") catch null;
}

/// The bytes `src`/`count` name, or the empty slice for a null pointer.
///
/// Upstream builds the slice with `std::slice::from_raw_parts(src, count)` and
/// no null check (`src/sync/message.rs:58-59`, `src/sync/state.rs:68-69`), which
/// makes a null pointer a precondition rather than a guarantee. Treating it as
/// zero bytes is the reading that is not undefined behaviour, and the decoder
/// then refuses it with a `ParseError` as it would an empty input.
fn bytesOf(src: ?[*]const u8, count: usize) []const u8 {
    const s = src orelse return &.{};
    return s[0..count];
}

// ---------------------------------------------------------------------------
// AMsyncHave. Rust: src/sync/have.rs:36-42.
// ---------------------------------------------------------------------------

/// `AMsyncHaveLastSync`. Rust: `src/sync/have.rs:37-42`.
///
/// **A null handle is an empty success, not an error**: the reference's
/// `match … { Some(h) => …, None => Default::default() }` (`:37-40`) makes a
/// null handle an empty slice, and `Default::default()` for `&[ChangeHash]` is
/// the empty slice, which `to_result` turns into an empty *items* result. So
/// `AMresultStatus` is `AM_STATUS_OK` and `AMresultSize` is `0`.
pub export fn AMsyncHaveLastSync(sync_have: ?*const AMsyncHave) ?*AMresult {
    const h = sync_have orelse return emptyOk(gpa);
    return docmod.boxHashes(gpa, h.lastSync()) catch |e| failWith(gpa, e);
}

// ---------------------------------------------------------------------------
// AMsyncMessage. Rust: src/sync/message.rs.
// ---------------------------------------------------------------------------

/// `AMsyncMessageDecode`. Rust: `src/sync/message.rs:64`.
///
/// The result holds one `AM_VAL_TYPE_SYNC_MESSAGE` item, because
/// `to_result(am::sync::Message::decode(data))` goes through
/// `impl From<am::sync::Message> for Value` (`src/item.rs:183-187`).
pub export fn AMsyncMessageDecode(src: ?[*]const u8, count: usize) ?*AMresult {
    const data = bytesOf(src, count);
    var message = msgmod.Message.decode(gpa, data) catch |e| return failWith(gpa, e);
    return docmod.boxOne(gpa, .{ .sync_message = AMsyncMessage.init(gpa, message) }) catch |e| {
        message.deinit();
        return failWith(gpa, e);
    };
}

/// `AMsyncMessageEncode`. Rust: `src/sync/message.rs:82`.
///
/// A null handle is `AMresult::error("Invalid `AMsyncMessage*`")`, from
/// `to_sync_message!` (`:12-19`, used at `:79`).
pub export fn AMsyncMessageEncode(sync_message: ?*const AMsyncMessage) ?*AMresult {
    const m = sync_message orelse return invalidMessage(gpa);
    var copy = m.body;
    const bytes = copy.encode(gpa) catch |e| return failWith(gpa, e);
    const value = docmod.valueBytes(gpa, bytes) catch |e| {
        gpa.free(bytes);
        return failWith(gpa, e);
    };
    return docmod.boxOne(gpa, value) catch |e| {
        gpa.free(bytes);
        return failWith(gpa, e);
    };
}

/// `AMsyncMessageHaves`. Rust: `src/sync/message.rs:100`.
///
/// A null handle is an empty items result, for the same reason as
/// [`AMsyncHaveLastSync`]: `Default::default()` over `&[Have]`
/// (`src/sync/message.rs:98`).
pub export fn AMsyncMessageHaves(sync_message: ?*const AMsyncMessage) ?*AMresult {
    const m = sync_message orelse return emptyOk(gpa);
    return docmod.boxHaves(gpa, m.body.have) catch |e| failWith(gpa, e);
}

/// `AMsyncMessageHeads`. Rust: `src/sync/message.rs:120`.
///
/// A null handle is an empty items result (`src/sync/message.rs:118`).
pub export fn AMsyncMessageHeads(sync_message: ?*const AMsyncMessage) ?*AMresult {
    const m = sync_message orelse return emptyOk(gpa);
    return docmod.boxHashes(gpa, m.body.heads) catch |e| failWith(gpa, e);
}

/// `AMsyncMessageNeeds`. Rust: `src/sync/message.rs:141`.
///
/// A null handle is an empty items result (`src/sync/message.rs:139`).
pub export fn AMsyncMessageNeeds(sync_message: ?*const AMsyncMessage) ?*AMresult {
    const m = sync_message orelse return emptyOk(gpa);
    return docmod.boxHashes(gpa, m.body.need) catch |e| failWith(gpa, e);
}

// ---------------------------------------------------------------------------
// AMsyncState. Rust: src/sync/state.rs.
// ---------------------------------------------------------------------------

/// `AMsyncStateDecode`. Rust: `src/sync/state.rs:73`.
///
/// The result holds one `AM_VAL_TYPE_SYNC_STATE` item, from
/// `impl From<am::sync::State> for Value` (`src/item.rs:189-193`).
pub export fn AMsyncStateDecode(src: ?[*]const u8, count: usize) ?*AMresult {
    const data = bytesOf(src, count);
    var state = statemod.State.decode(gpa, data) catch |e| return failWith(gpa, e);
    return docmod.boxOne(gpa, .{ .sync_state = AMsyncState.init(gpa, state) }) catch |e| {
        state.deinit();
        return failWith(gpa, e);
    };
}

/// `AMsyncStateEncode`. Rust: `src/sync/state.rs:91`.
///
/// A null handle is `AMresult::error("Invalid `AMsyncState*`")`, from
/// `to_sync_state!` (`:8-15`, used at `:88`).
pub export fn AMsyncStateEncode(sync_state: ?*const AMsyncState) ?*AMresult {
    const s = sync_state orelse return invalidState(gpa);
    const bytes = s.body.encode(gpa) catch |e| return failWith(gpa, e);
    return docmod.boxOne(gpa, docmod.valueBytes(gpa, bytes) catch |e| {
        gpa.free(bytes);
        return failWith(gpa, e);
    }) catch |e| {
        gpa.free(bytes);
        return failWith(gpa, e);
    };
}

/// `AMsyncStateEqual`. Rust: `src/sync/state.rs:111`.
///
/// **Two null handles are not equal.** The reference's match arm at `:118` is
/// `(None, None) | (None, Some(_)) | (Some(_), None) => false`, and its own
/// `\post` says so (`src/sync/state.rs:105`). This is the one place in the ABI
/// where a null is not "absent" but a distinct answer.
pub export fn AMsyncStateEqual(
    sync_state1: ?*const AMsyncState,
    sync_state2: ?*const AMsyncState,
) bool {
    const a = sync_state1 orelse return false;
    const b = sync_state2 orelse return false;
    return statesEqual(a.body, b.body);
}

/// `AMsyncStateInit`. Rust: `src/sync/state.rs:129`.
///
/// The reference reaches `*mut AMsyncState` through
/// `impl From<AMsyncState> for *mut AMsyncState` (`:41-46`), which is the same
/// `Box::into_raw` every other handle in this ABI uses: the state is put in an
/// item, and the result owns the box.
pub export fn AMsyncStateInit() ?*AMresult {
    return docmod.boxOne(gpa, .{
        .sync_state = AMsyncState.init(gpa, statemod.State.new(gpa)),
    }) catch |e| failWith(gpa, e);
}

/// `AMsyncStateSharedHeads`. Rust: `src/sync/state.rs:146`.
///
/// A null handle is `AMresult::error("Invalid `AMsyncState*`")`
/// (`src/sync/state.rs:143`).
pub export fn AMsyncStateSharedHeads(sync_state: ?*const AMsyncState) ?*AMresult {
    const s = sync_state orelse return invalidState(gpa);
    return docmod.boxHashes(gpa, s.body.shared_heads) catch |e| failWith(gpa, e);
}

/// `AMsyncStateLastSentHeads`. Rust: `src/sync/state.rs:164`.
///
/// A null handle is `AMresult::error("Invalid `AMsyncState*`")`
/// (`src/sync/state.rs:161`).
pub export fn AMsyncStateLastSentHeads(sync_state: ?*const AMsyncState) ?*AMresult {
    const s = sync_state orelse return invalidState(gpa);
    return docmod.boxHashes(gpa, s.body.last_sent_heads) catch |e| failWith(gpa, e);
}

/// `AMsyncStateTheirHaves`. Rust: `src/sync/state.rs:186-198`.
///
/// A null handle writes `false` and returns an **empty** items result, which is
/// the reference's fallthrough (`:198-200`).
pub export fn AMsyncStateTheirHaves(
    sync_state: ?*const AMsyncState,
    has_value: ?*bool,
) ?*AMresult {
    const out = has_value orelse return invalidOutParam(gpa);
    const s = sync_state orelse {
        out.* = false;
        return emptyOk(gpa);
    };
    const haves = s.body.their_have orelse {
        out.* = false;
        return emptyOk(gpa);
    };
    out.* = true;
    return docmod.boxHaves(gpa, haves) catch |e| failWith(gpa, e);
}

/// `AMsyncStateTheirHeads`. Rust: `src/sync/state.rs:218-230`.
///
/// A null handle writes `false` and returns an empty items result, which is the
/// reference's fallthrough (`:230-232`).
pub export fn AMsyncStateTheirHeads(
    sync_state: ?*const AMsyncState,
    has_value: ?*bool,
) ?*AMresult {
    const out = has_value orelse return invalidOutParam(gpa);
    const s = sync_state orelse {
        out.* = false;
        return emptyOk(gpa);
    };
    const heads = s.body.their_heads orelse {
        out.* = false;
        return emptyOk(gpa);
    };
    out.* = true;
    return docmod.boxHashes(gpa, heads) catch |e| failWith(gpa, e);
}

/// `AMsyncStateTheirNeeds`. Rust: `src/sync/state.rs:250-262`.
///
/// A null handle writes `false` and returns an empty items result, which is the
/// reference's fallthrough (`:262-264`).
pub export fn AMsyncStateTheirNeeds(
    sync_state: ?*const AMsyncState,
    has_value: ?*bool,
) ?*AMresult {
    const out = has_value orelse return invalidOutParam(gpa);
    const s = sync_state orelse {
        out.* = false;
        return emptyOk(gpa);
    };
    const needs = s.body.their_need orelse {
        out.* = false;
        return emptyOk(gpa);
    };
    out.* = true;
    return docmod.boxHashes(gpa, needs) catch |e| failWith(gpa, e);
}

// ---------------------------------------------------------------------------
// Tests.
//
// Four behaviours a reader cannot check by reading: a persisted state really
// round-trips and no proper prefix of it decodes, the derive [`statesEqual`]
// spells out compares the two states it is handed, a null handle is the
// reference's answer rather than a segfault, and the two hard-coded "Invalid
// `AMsync*`" messages are the reference's bytes.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// `AMresultFree` is emitted by [`docmod.abi`], which is instantiated exactly
/// once in [doc.zig](doc.zig); this is the same call under a name this file
/// can see. Rust: `src/result.rs:557-562`.
fn dropResult(r: ?*AMresult) void {
    docmod.abi.AMresultFree(r);
}

test "a persisted state round-trips, and no proper prefix of it decodes" {
    // `State::encode` writes the type byte and `shared_heads` and nothing else
    // (`state.rs:108-112`), and `State::decode` reads them back
    // (`state.rs:114-121`).
    var one = statemod.State.new(testing.allocator);
    defer one.deinit();
    var h: ChangeHash = .zero;
    h.bytes[0] = 0xaa;
    one.shared_heads = try testing.allocator.dupe(ChangeHash, &.{h});

    const encoded = try one.encode(testing.allocator);
    defer testing.allocator.free(encoded);
    try testing.expect(encoded.len > 0);

    var back = statemod.State.decode(testing.allocator, encoded) catch |e| return e;
    defer back.deinit();
    // **The format carries `shared_heads` and nothing else**, so the round trip
    // is lossless for that field and the eleven others come back at their
    // defaults — with one exception upstream calls out: a decoded state has
    // `their_have` as an *empty* list rather than absent (`state.rs:139`), so
    // it answers `their()` where a fresh one does not. The two are therefore
    // correctly **not** equal, and that is the interesting part.
    try testing.expectEqualSlices(ChangeHash, one.shared_heads, back.shared_heads);
    try testing.expect(back.their_have != null);
    try testing.expectEqual(@as(usize, 0), back.their_have.?.len);
    try testing.expect(one.their_have == null);
    try testing.expect(!statesEqual(one, back));

    // A parse has to be total over untrusted input, and the input here is a
    // peer's persisted state. Every proper prefix is an error; the whole thing
    // is not.
    var n: usize = 0;
    while (n < encoded.len) : (n += 1) {
        if (statemod.State.decode(testing.allocator, encoded[0..n])) |bad| {
            var scratch = bad;
            scratch.deinit();
            return error.Unexpected;
        } else |_| {}
    }
}

test "AMsyncStateEqual compares the fields, not the handle" {
    const alloc = testing.allocator;
    var h: ChangeHash = .zero;
    h.bytes[0] = 0xaa;

    var fresh = statemod.State.new(alloc);
    defer fresh.deinit();
    var a = statemod.State.new(alloc);
    defer a.deinit();
    a.shared_heads = try alloc.dupe(ChangeHash, &.{h});
    var b = statemod.State.new(alloc);
    defer b.deinit();
    b.shared_heads = try alloc.dupe(ChangeHash, &.{h});

    // Two *different* states with the same field are equal, so this is a
    // comparison over the thirteen fields and not an identity test.
    try testing.expect(statesEqual(a, b));
    // `shared_heads` is the first field compared (`state.zig:94`), and it is
    // enough on its own.
    try testing.expect(!statesEqual(a, fresh));

    // An optional list compares **by presence and then by content**:
    // `None != Some(&.{})`, which is what a derive over `Option<Vec<T>>` gives.
    a.their_heads = try alloc.dupe(ChangeHash, &.{});
    try testing.expect(!statesEqual(a, b));
    b.their_heads = try alloc.dupe(ChangeHash, &.{});
    try testing.expect(statesEqual(a, b));
}

test "a null handle is the reference's answer, and which answer depends on the call" {
    // `Default::default()` in the `None` arm is an **empty success**, not an
    // error (`have.rs:37-42`, `message.rs:98`, `:118`, `:139`).
    const have = AMsyncHaveLastSync(null);
    try testing.expectEqual(docmod.AMstatus.ok, AMresult.status(have));
    try testing.expectEqual(@as(usize, 0), AMresult.size(have));
    dropResult(have);
    const haves = AMsyncMessageHaves(null);
    try testing.expectEqual(docmod.AMstatus.ok, AMresult.status(haves));
    try testing.expectEqual(@as(usize, 0), AMresult.size(haves));
    dropResult(haves);
    const heads = AMsyncMessageHeads(null);
    try testing.expectEqual(@as(usize, 0), AMresult.size(heads));
    dropResult(heads);
    const needs = AMsyncMessageNeeds(null);
    try testing.expectEqual(@as(usize, 0), AMresult.size(needs));
    dropResult(needs);

    // The state and message *encoders* are the opposite: a null handle is an
    // error result, with the reference's own message (`state.rs:13`,
    // `message.rs:17`).
    const no_state = AMsyncStateEncode(null);
    try testing.expectEqual(docmod.AMstatus.error_, AMresult.status(no_state));
    try testing.expectEqualStrings("Invalid `AMsyncState*`", AMresult.errorMessage(no_state).slice());
    dropResult(no_state);
    const no_message = AMsyncMessageEncode(null);
    try testing.expectEqual(docmod.AMstatus.error_, AMresult.status(no_message));
    try testing.expectEqualStrings(
        "Invalid `AMsyncMessage*`",
        AMresult.errorMessage(no_message).slice(),
    );
    dropResult(no_message);

    // `AMsyncStateEqual` is the one place in the ABI where a null is not
    // "absent" but a distinct answer: its match arm is
    // `(None, None) | (None, Some(_)) | (Some(_), None) => false`
    // (`state.rs:118`). The same call over a real handle is reached through
    // `AMitemToSyncState`, which needs a unique item (`item.rs:1242-1246`).
    const init = AMsyncStateInit() orelse return error.Unexpected;
    const si = docmod.abi.AMresultItem(init) orelse return error.Unexpected;
    var real: ?*AMsyncState = null;
    try testing.expect(docmod.AMitemToSyncState(si, &real));
    try testing.expect(!AMsyncStateEqual(null, null));
    try testing.expect(!AMsyncStateEqual(null, real));
    try testing.expect(AMsyncStateEqual(real, real));
    dropResult(init);
}

test "a null out-parameter is an error result, and a null handle writes false" {
    // `\pre has_value != NULL` is a precondition upstream dereferences
    // unconditionally (`state.rs:169`, `:222`, `:254`); a Zig `export` that
    // trusted it would turn a C bug into a segfault.
    const refused = AMsyncStateTheirHaves(null, null);
    try testing.expectEqual(docmod.AMstatus.error_, AMresult.status(refused));
    try testing.expectEqualStrings("Invalid `bool*`", AMresult.errorMessage(refused).slice());
    dropResult(refused);

    // A null *handle* is not a refusal: it is the reference's fallthrough,
    // which writes `false` and answers an empty items result
    // (`state.rs:198-200`).
    var has = true;
    const empty = AMsyncStateTheirHeads(null, &has);
    try testing.expectEqual(docmod.AMstatus.ok, AMresult.status(empty));
    try testing.expectEqual(@as(usize, 0), AMresult.size(empty));
    try testing.expect(!has);
    dropResult(empty);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **The three `RefCell<BTreeMap<…>>` storages are not ported, and a `grep`
//   is the evidence.** `AMsyncMessage` carries `changes_storage` and
//   `haves_storage` (`src/sync/message.rs:27-28`) and `AMsyncState` carries
//   `their_haves_storage` (`src/sync/state.rs:26`); each is written once in the
//   constructor and read nowhere. They exist to keep a `*const AMchange` /
//     `*const AMsyncHave` alive for as long as the message or state does, and
//   this port does not need them because **every handle a C caller can reach
//   is reached through an `AMitem`**, and the item stores the handle inline in
//   its own heap cell ([doc.zig](doc.zig), `Value.sync_message` /
//   `Value.sync_state` / `Value.change`) — which is upstream's layout too
//   (`src/item.rs:40-42`). Porting a map nothing reads is
//   [AGENTS.md](../AGENTS.md)'s forbidden dead code.
//
// * **`owns_payload` is the one field here that is not in the reference, and it
//   exists because the reference gets a `clone` for free.** Upstream's
//   `receiveSyncMessage` takes its `Message` **by value** and *moves* `heads`,
//   `need` and `have` into the peer state (`sync.rs:459-461`), and the C handle
////   survives that because `AMreceiveSyncMessage` passes
//     `sync_message.as_ref().clone()` (`doc.rs:800`). This port's
//   [receiveSyncMessage](../sync/protocol.zig) says the same about moving, and
//   the port's [`msgmod.Message`] has no `clone`, so
//   [`AMsyncMessage.yieldPayload`] hands the three lists over and records that
//   it did. **`AMreceiveSyncMessage` calls it *before* the receive, not after**,
////   which is what makes the error path a single exit: the reference's
//   `errdefer` inside `receiveSyncMessage` has already freed them there.
//
// * **`AMsyncStateEqual` spells the derive out, and the field list is the
//   port's, not upstream's.** Upstream derives `PartialEq` over
//   `am::sync::State` (`src/sync/state.rs:22`); the port's
//   [`State`](../sync/state.zig) has no `eql`, so [`statesEqual`] compares its
//   thirteen fields in declaration order (`state.zig:87-133`). That is a
//   derive, not a document answer, and the two optional lists compare **by
//   presence and then by content**: `None != Some(&.{})`.
//
// * **A null `has_value` is an error result here and a segfault upstream.**
//   `AMsyncStateTheirHaves`, `AMsyncStateTheirHeads` and `AMsyncStateTheirNeeds`
//   document `\pre has_value != NULL` and dereference it unconditionally
//   (`state.rs:169`, `:222`, `:254`). A C ABI whose exports are `total` cannot
//   inherit that, so the call is refused with a message. This is a **superset**
//   of the precondition, not a change of contract: every caller that honours
//   the precondition takes the same path as upstream.
//
// * **A null handle is the reference's answer, and which answer depends on the
//   function.** `AMsyncHaveLastSync` (`have.rs:37-42`) and
//   `AMsyncMessageHaves` / `Heads` / `Needs` (`message.rs:98`, `:118`, `:139`)
//     all match `None => Default::default()`, so a null handle is an **empty
//   success**: `AM_STATUS_OK` with size `0`, not an error. The state accessors
//   are the opposite: `AMsyncStateEncode`, `SharedHeads` and `LastSentHeads`
//   reject a null handle with `AMresult::error("Invalid `AMsyncState*`")`
//   (`state.rs:13`, `:143`, `:161`), and `AMsyncStateEqual` answers `false` for
//   two nulls because its match arm says so (`state.rs:118`). Both spellings are
//   the reference's, reproduced exactly.
//
// * **`AMsyncMessage` has no `to_bytes` and no `to_str`, so it has no caches.**
//   The reference's `AMcursor` and `AMactorId` do (`cursor.rs:28-29`,
//   `actor_id.rs:19`) and this port keeps both ([doc.zig](doc.zig),
//   `AMcursor.bytes` / `fmt_str`, `AMactorId.hex`); `AMsyncMessage` does not, so
//   there is nothing to cache and the handle is two fields wide.
