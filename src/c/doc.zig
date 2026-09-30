//! The document half of the C ABI: the `AMactorId`, `AMchange`, `AMcursor`,
//! `AMitem` and `AMdoc` handles, the item value model, and every
//! `AM*` entry point over them — `doc.rs`, `doc/list.rs`, `doc/map.rs`,
//! `doc/mark.rs`, `actor_id.rs`, `change.rs`, `cursor.rs`, `obj.rs`, `index.rs`
//! and `item.rs` of `rust/automerge-c/`, which is 6,262 lines of Rust.
//!
//! The sync handles and their fifteen entry points are [sync.zig](sync.zig),
//! because the port's own `sync/` modules own them; the two entry points that
//! take both a document and a sync state — `AMgenerateSyncMessage` and
//! `AMreceiveSyncMessage` — are at the bottom of this file, which is where
//! upstream has them (`src/doc.rs:278`, `:791`).
//!
//! # The ownership model, in one paragraph
//!
//! **Every `AMresult` owns everything it hands out, and nothing else does.**
//! A handle that a C caller reaches through a result lives inside the result's
//! own `Rc`-shared [`Item`], so `AMresultFree` — the ABI's only deallocating
//! export, `src/result.rs:557-562` — is a complete destructor. The values a
//! handle answers with (a hash, a message, a raw byte array) are **copied into
//! the item**, never borrowed from a document, because the C contract lets a
//! caller hold a result across mutations of the document it came from and the
//! reference's own `Rc<Item>` makes the same promise. The two exceptions are
//! named where they occur, because the reference has them too: a mark's name and
//! a mark's value borrow the document (`src/item.rs:517-525`), and a
//! `AMbyteSpan` is a borrow by construction (`src/byte_span.rs:25-35`).
//!
//! # What "the whole crate" cost, and the three places the port cannot follow
//!
//! ## 1. The `RefCell` caches are `@constConst`-ed pointers
//!
//! The reference caches computed spellings in `RefCell` so that a
//! `*const AMactorId` can fill them: `hex_str` (`src/actor_id.rs:18`),
//! `bytes`/`fmt_str` (`src/cursor.rs:30-31`), `c_actor_id` (`src/obj.rs:19`),
//! `change_hash` (`src/change.rs:23`). This port does the same with
//! `@constCast` on a `const`-parameter pointer, and the module docs on
//! [`AMactorId.toStr`], [`AMcursor.toBytes`], [`AMobjId.actorHandle`] and
//! [`AMchangeFooter`] each say so. **This is the only unsound-looking thing
//! here and it is sound**: the memory is inside the handle the C caller
//! already holds, and the cache is idempotent.
//!
//! ## 2. `AMobjIdIndex` has no port answer
//!
//! Upstream's `am::ObjId` is `Id(counter, actor_id, index)` with a third
//! component — the creating operation's index in its actor's sequence
//! (`src/obj.rs:31-38`) — and `AMobjIdIndex` reports it (`src/obj.rs:143-152`).
//! The port's object identifier is [`types.ExId`](types.zig), a union of
//! `.root` and `OpId{counter, actor_index}` (`types.zig:245-247`), and **it
//! carries no creation index**; nothing in the op set keeps one.
//! [`AMobjIdIndex`] therefore answers `0` for a real object, which is the same
//! answer upstream gives the root. This is a reported gap, not a silent
//! substitution: the header's `\brief` still says what upstream's says and the
//! report names the missing field.
//!
//! ## 3. One `*_at` family has a duplicated helper, and every `*_at` builds
//! its clock the same way
//!
//! Every C function whose last parameter is `const AMitems *heads` selects a
//! historical view. The port's read surface ([read.zig](../read.zig)) reaches
//! [`docmod.Set`](../opset/op_set.zig), the one layer that takes a clock, and
//! it is the layer `read.zig` itself calls. That is a plumbing change, not a
//! second answer: `seekOpsByKey`, `topOps`, `seqLength`, `text`,
//! `Keys.ofObj`, `ValueTerm.ofObj`, `ListRange.init` and `MapRange.init` are
//! the same calls `read.zig` makes with `null`. **The clock itself is one
//! helper** — [`clockFromItems`] collects the hashes out of the items and asks
//! `doc.graph.clockAt` for them — which is the pair of lines
//! [`read.markSetAtIndex`](../read.zig) already runs for its own `heads` arm
//! (`read.zig:1010-1027`).
//!
//! **Two readers are the exception, because they carry `heads` themselves.**
//! [`read.getCursorMoving`](../read.zig) and [`read.getCursorPosition`](../read.zig)
//! are upstream's `get_cursor_moving` and `get_cursor_position`
//! ([`automerge.rs:2179-2198`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//! `at` argument and all — the port's read surface took the `*At` twins back
//! out rather than doubling these. So [`AMgetCursorPosition`] hands its `heads`
//! straight to the reader when no transaction is open, and unwraps them into a
//! clock here when one is.
//! **That is the reader's own plumbing, not a second route to it**, and it is
//! what keeps the C surface's answer the same one the Zig surface gives; the
//! error label it settles is on that function and in the diff block.
//! [`AMgetCursor`] still builds its own clock with [`clockFromItems`], which is
//! recorded there rather than changed.
//!
//! **The one place that unwrapping is not the reader's plumbing is a held
//! transaction, and it is [`AMgetCursorPosition`]'s.** `AMdoc` is an
//! `AutoCommit`, so its reads resolve their clock through
//! [`AutoCommit::get_scope`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):794-814
//! and **not** through the same-named method on `Automerge` — a different
//! receiver, a different body, and on a `heads` argument a different answer:
//! upstream's first arm takes the heads-are-current shortcut only when
//! `self.transaction.is_none()` (`:800-804`), and says why at `:797-799` —
//! *"pending ops are already in the op set but not yet under the graph's
//! heads"*. Since `txSpliceText` leaves the transaction **held**, that is this
//! ABI's ordinary state between a write and a read, and handing `heads`
//! straight to the reader took the shortcut across it. The other readers of
//! this file are not affected because they were never re-routed through
//! `Automerge`'s method; [`AMgetCursor`] is unaffected for the same reason.
//!
//! One family cannot be done that way:
//!
//! * **`AMmapGet`, `AMmapGetAll`, `AMlistGet` and `AMlistGetAll` with `heads`**
//!   go through [`read.get`]/[`read.getAll`]'s private `winner` +
//!   `taggedValue` pair (`read.zig:385-425`). [`taggedValue`] below is a
//!   **second copy of that six-arm dispatch** and is the one place in this port
//!   that is. It is copied rather than refused because the alternative is
//!   turning a call upstream supports into an error, and the copy is a
//!   dispatch over an operation's action tag, not a recomputation of a document
//!   answer.
//!
//! **`AMmarks` used to be in that list and is not any more.** It was refused
//! with `error.HistoricalMarksUnsupported` on the stated ground that the port's
//! mark fold "[`OpSet.calculateMarks`](../opset/op_set.zig) takes no clock and
//! [`Document.marks`](../doc.zig) is the only caller". **Both halves were
//! false** — [`OpSet.calculateMarksAt`](../opset/op_set.zig) exists and holds
//! upstream's whole dispatch (`automerge.rs`:1569-1596), and
//! [`Document.marks`](../doc.zig) is one of its callers rather than the only one
//! — and a refusal justified by a capability that was merely unreachable from
//! one door is a compatibility defect of its own. It is answered by
//! [`clockFromItems`] and `calculateMarksAt` now; see [`AMmarks`].
//!
//! ## 4. `AMrollback` and `AMpendingOps` are answered from the flavour
//!
//! [`AMdoc`] is always an `AutoCommit`: `src/doc.rs:36` is
//! `pub struct AMdoc(am::AutoCommit)` and the write surface's
//! `requireAuto` ([transact.zig](../transact.zig)) is what the port's `.auto`
//! mode is. `AutoCommit` closes its transaction at the end of every mutating
//! call, so `pending_ops()` is `0` and `rollback()` is the
//! `self.transaction.take()…unwrap_or(0)` of `autocommit.rs:742-750` with
//! nothing to take. **Both are the reference's answers for an `AutoCommit` that
//! has just returned from a mutating call**, and neither is a stub.
//!
//! ## 5. Error text
//!
//! Upstream renders `AutomergeError`'s `Display` (`src/result.rs:466`). This
//! port's error sets are Zig's, so a *propagated* error carries
//! [`@errorName`] — the closest stable spelling — while every message the
//! reference **hard-codes** ("Invalid `AMdoc*`", "Invalid pos {}", "Invalid
//! `AMresult`") is reproduced **verbatim**, because a C caller can match on it
//! and the reference's own cmocka suite does.

const std = @import("std");
const builtin = @import("builtin");

const result = @import("result.zig");
const syncmod = @import("sync.zig");

const err = @import("../error.zig");
const types = @import("../types.zig");
const valmod = @import("../value.zig");
const optypes = @import("../opset/types.zig");
const opmod = @import("../opset/op.zig");
const opsetmod = @import("../opset/op_set.zig");
const transact = @import("../transact.zig");
const docmod = @import("../doc.zig");
const iterlist = @import("../iter/list_range.zig");
const itermap = @import("../iter/map_range.zig");
const opquery = @import("../opset/op_query.zig");
const cursormod = @import("../cursor.zig");
const readmod = @import("../read.zig");
const marksmod = @import("../marks.zig");
const changemod = @import("../change.zig");
const clockmod = @import("../clock.zig");
const hydmod = @import("../hydrate.zig");
const protocol = @import("../sync/protocol.zig");
const statemod = @import("../sync/state.zig");
const msgmod = @import("../sync/message.zig");
const chunkmod = @import("../storage/chunk.zig");
const changechunk = @import("../storage/change_chunk.zig");
const iterkeys = @import("../iter/keys.zig");
const itervalues = @import("../iter/values.zig");
const bloommod = @import("../sync/bloom.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// The enumerations and spans, re-exported from result.zig so that both halves
// of the C ABI name one set.
// ---------------------------------------------------------------------------

/// A view onto an array of bytes. Rust: `src/byte_span.rs:25-35`.
pub const AMbyteSpan = result.AMbyteSpan;
/// The type of an object. Rust: `src/obj.rs:170-179`.
pub const AMobjType = result.AMobjType;
/// The type of an item's index. Rust: `src/index.rs:60-67`.
pub const AMidxType = result.AMidxType;
/// A mark's expansion mode. Rust: `src/doc/mark.rs:40-51`.
pub const AMmarkExpand = result.AMmarkExpand;
/// The type of an item's value. Rust: `src/item.rs:1296-1341`.
pub const AMvalType = result.AMvalType;
/// The status of an API call. Rust: `src/result.rs:476-484`.
pub const AMstatus = result.AMstatus;
/// A value whose type is unknown. Rust: `src/item.rs:25-30`.
pub const AMunknownValue = result.AMunknownValue;
/// One value and the operation that put it there, which is the port's
/// [`read.DocItem`](../read.zig) (`read.zig:276-289`) declared here for one
/// reason: **the C ABI's `*_at` entry points need a clock, and the port's read
/// surface has no clock parameter at all.** The two-field struct is therefore
/// declared over the same two fields rather than imported, and every read
/// below goes to the layer that *does* take a clock — which is the layer
/// `read.zig` itself calls. See the module doc.
pub const DocItem = struct {
    value: optypes.ValueRef,
    id: ExId,
};

const ChangeHash = types.ChangeHash;
const OpId = types.OpId;
const ExId = types.ExId;
const ObjType = types.ObjType;
const ActorId = types.ActorId;
const Prop = types.Prop;
const Cursor = cursormod.Cursor;
const Clock = clockmod.Clock;
const ScalarValue = valmod.ScalarValue;

// ---------------------------------------------------------------------------
// The C ABI's text unit.
//
// A document measures text in one encoding for its whole life, so this is
// chosen when the document is built and every index a C caller passes
// afterwards is in it. It is here, and not [`docmod.defaultTextEncoding`], for
// a reason that is a property of the *C library* rather than of the crate: see
// the function's own doc comment.
// ---------------------------------------------------------------------------

/// The unit every text index in this ABI counts in: **UTF-8 code units**.
///
/// Upstream's `automerge-c` is not built with the `automerge` crate's default
/// feature set. `rust/automerge-c/CMakeLists.txt:45` declares the
/// `UTF32_INDEXING` option and does not set it, so CMake's `option` leaves it
/// **off**, and `:111-117` therefore takes the `else` arm: no cargo feature
/// list at all, and `-F automerge/utf8-indexing`. That feature is the first
/// arm of `TextEncoding::platform_default()` and answers `Utf8CodeUnit`
/// ([`text_value.rs:12-17`](../../github-automerge-automerge/rust/automerge/src/text_value.rs)),
/// which is what makes the length of "😀" four through this ABI.
/// `rust/automerge-c/README.md:62-63` says the same in words: "By default
/// automerge-c expects string indices to be given in terms of UTF-8 byte
/// offsets".
///
/// It is this and not [`docmod.defaultTextEncoding`] because **the two are
/// different questions.** That function is the port's `platform_default` for a
/// *featureless* build of the crate, which is `UnicodeCodePoint`
/// (`text_value.rs:11`, `:19`) — the bare library genuinely has no reason to
/// prefer UTF-8. The C library is a *different build of that library*, and the
/// one a C consumer gets by default. Changing this port's crate-wide default
/// to UTF-8 would have made the CRDT library's own default diverge from a
/// default-configured `cargo build` of the same crate, to fix a property of
/// the C binding.
pub fn cTextEncoding() types.TextEncoding {
    return .utf8_code_unit;
}

// ---------------------------------------------------------------------------
// The handles. Every one of them is forward-declared in include/automerge.h,
// so the layout here is the port's and not the C ABI's.
// ---------------------------------------------------------------------------

/// `AMdoc`. Rust: `src/doc.rs:35-36` — `pub struct AMdoc(am::AutoCommit)`.
///
/// **`AMdoc` is `AutoCommit`, and `AutoCommit` holds its transaction open
/// across calls.** `ensure_transaction_open`
/// ([`autocommit.rs:445-457`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs))
/// opens one lazily and leaves it; only `commit_with` (`:728-739`),
/// `rollback` (`:742-751`) and a read that needs it (`:459-468`) close it. A C
/// consumer's `AMmapPutStr` is therefore **not a change**: it is an operation
/// inside the change the consumer opens with `AMcommit`.
///
/// **This handle used to be `docmod.Document` outright, and that was a
/// different API wearing the same header.** Every module function in
/// [transact.zig](../transact.zig) opens a transaction, writes one operation
/// and commits it, which is right for a *Zig* caller of the crate's own
/// `Transactable` impl and wrong for this one, because a C caller drives
/// `AutoCommit` directly. It cost one change per operation: `AMpendingOps`
/// was always `0`, `AMrollback` always `0`, and three `put` + `AMcommit`
/// pairs produced six changes. `tx` is that held transaction, opened through
/// [`transact.openAutoHeld`] so the two doors keep their own commit
/// semantics rather than sharing a helper that sometimes commits.
///
/// **The handle is never moved while a transaction is open.**
/// [`transact.Transaction`]'s `doc` points at the document it was opened
/// against, so a move would leave it addressing the old one. The only moves
/// are [`AMcreate`], [`AMload`] and [`AMclone`], each of which boxes the
/// document into a result item before anything writes to it; from then on the
/// handle lives inside one `RcItem` allocation, which is never relocated,
/// and `AMitemResult` shares that allocation rather than copying the item
/// (`src/result.rs:504-525`). [`AMclone`] closes before it copies, so the
/// copy is cloned with nothing open.
///
/// There is no `AMdocFree` because there is no route to an `AMdoc` other than
/// a result item that owns it (`src/result.rs:557-562` is the only
/// `Box::from_raw` in the reference's `src/`).
pub const AMdoc = struct {
    /// The `Automerge` inside the `AutoCommit`. Rust: `doc.0` (`src/doc.rs:36`).
    doc: docmod.Document,
    /// `AutoCommit.transaction`, and `None` for the state
    /// `ensure_transaction_closed` leaves behind. Rust: `autocommit.rs:445-457`.
    tx: ?transact.Transaction = null,

    /// [`AutoCommit::ensure_transaction_open`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs:445-457).
    ///
    /// **The transaction is opened on the document's own allocator, and
    /// there is no argument here to change that.** Upstream's `AMdoc` is a
    /// newtype over `am::AutoCommit`
    /// ([`src/doc.rs:36`](../../github-automerge-automerge/rust/automerge-c/src/doc.rs))
    /// with no allocator anywhere on it and no `AMdoc_open` in the C ABI to
    /// pass one to; [`ensure_transaction_open`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs:445-457)
    /// takes the transaction out of the `AutoCommit` that already holds it.
    /// **This port's `Transaction` is the opposite of a borrow: it owns
    /// buffers, and every one of them has to be freed by the same allocator
    /// that made it.** [`transact.Transaction.gpa`] says so in its own words
    /// — "The allocator every owned buffer in this transaction belongs to,
    /// **which is the document's**"
    /// ([`transact.zig:330-332`](../transact.zig)) — and every other door
    /// through this port's transaction opens the same way, `const gpa =
    /// doc.allocator();` ([`transact.zig:2668`](../transact.zig),
    /// `:2680`, `:2692` and the rest).
    ///
    /// **A hardcoded `c_alloc` here was not a second spelling of that; it was
    /// a free of somebody else's memory.** A pending operation's undo log
    /// belongs to the op set ([`op.zig:1230-1236`](../opset/op.zig)) and
    /// [`transact.Transaction.deinit`] frees it with `self.gpa`
    /// ([`transact.zig:452`](../transact.zig)), so an `AMdoc` on any
    /// allocator but `c_alloc` reached `free` on a pointer it had not been
    /// given, and the process died inside `__free` on the way out. It was
    /// unreachable only because [`AMcreate`] uses `c_alloc` — which is a
    /// fact about the one route, not a property of the type.
    pub fn open(self: *AMdoc) !*transact.Transaction {
        if (self.tx) |*t| return t;
        self.tx = try transact.openAutoHeld(self.allocator(), &self.doc);
        return &self.tx.?;
    }

    /// [`AutoCommit::ensure_transaction_closed`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs:459-468).
    ///
    /// **This is what a read does**, and it is why [`AMgetHeads`], [`AMsave`],
    /// [`AMequal`] and the rest of the read surface are not free of the write
    /// history: a `get` between two puts is a commit point, exactly as it is
    /// upstream. A test that only checks that the value reads back would not
    /// notice; one that checks how many changes the document gained would.
    pub fn close(self: *AMdoc) !void {
        if (self.tx) |*t| {
            _ = try t.commit(null, null);
            t.deinit();
        }
        self.tx = null;
    }

    /// [`Drop`], which upstream does not write: `AutoCommit` has no `Drop`
    /// impl, so the reference drops an open transaction along with the
    /// document ([`autocommit.rs:63-72`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)
    /// has no `impl Drop for AutoCommit`). **The transaction is dropped, not
    /// committed.** Committing here would be a second answer to "what does
    /// dropping an `AMdoc` do", and it is a dangerous one: a
    /// [`transact.Transaction`] holds a `*Document` to the document it was
    /// opened against ([`src/transact.zig:285`](../../github-automerge-automerge/rust/automerge/src/transact.zig)),
    /// so a commit at teardown reallocates the graph's node array
    /// ([`change_graph.zig:1070`](../../github-automerge-automerge/rust/automerge/src/change_graph.zig))
    /// and then frees the buffer the copy being torn down still points at —
    /// which is what made `item_tests.c`'s group teardown free an interior
    /// pointer from `ChangeGraph.deinit`.
    pub fn deinit(self: *AMdoc) void {
        if (self.tx) |*t| t.deinit();
        self.tx = null;
        self.doc.deinit();
        self.* = undefined;
    }

    // The read surface a document is asked for most, kept as methods so the
    // call sites read as they did when this handle *was* a `Document` and so
    // that the close is not something a caller can forget at one site and not
    // another. Everything else goes through `d.doc`, and closes by hand.

    pub fn textEncoding(self: *const AMdoc) types.TextEncoding {
        return self.doc.textEncoding();
    }

    pub fn getActorId(self: *const AMdoc) ActorId {
        return self.doc.getActorId();
    }

    pub fn setActorId(self: *AMdoc, id: ActorId) void {
        self.doc.setActorId(id);
    }

    /// [`Document.objectType`](doc.zig), which is what every `AMobjObjType`
    /// and every object-kind branch of a read answers from. **No close**:
    /// the object type is a property of the document's rows, and the rows a
    /// pending transaction has written are already in them.
    pub fn objectType(self: *const AMdoc, id: ExId) !ObjType {
        return self.doc.objectType(id);
    }

    pub fn allocator(self: *const AMdoc) Allocator {
        return self.doc.allocator();
    }

    /// [`AutoCommit::get_heads`](../../github-automerge-automerge/rust/automerge/src/automerge.rs:695-702),
    /// which closes the transaction first (`autocommit.rs:459-468`).
    pub fn getHeads(self: *AMdoc, gpa: Allocator) ![]ChangeHash {
        try self.close();
        return self.doc.getHeads(gpa);
    }

    pub fn save(self: *AMdoc, gpa: Allocator) ![]u8 {
        try self.close();
        return self.doc.save(gpa);
    }

    pub fn saveIncremental(self: *AMdoc, gpa: Allocator) ![]u8 {
        try self.close();
        return self.doc.saveIncremental(gpa);
    }

    pub fn loadIncremental(self: *AMdoc, gpa: Allocator, bytes: []const u8) !usize {
        try self.close();
        return self.doc.loadIncremental(gpa, bytes);
    }

    pub fn applyChanges(self: *AMdoc, gpa: Allocator, incoming: []const changemod.Change) !usize {
        try self.close();
        return self.doc.applyChanges(gpa, incoming);
    }

    pub fn getChanges(self: *AMdoc, gpa: Allocator, have: []const ChangeHash) !docmod.Changes {
        try self.close();
        return self.doc.getChanges(gpa, have);
    }

    pub fn getChangesAdded(self: *AMdoc, gpa: Allocator, other: *AMdoc) !docmod.Changes {
        try self.close();
        try other.close();
        return self.doc.getChangesAdded(gpa, &other.doc);
    }

    pub fn getMissingDeps(self: *AMdoc, gpa: Allocator, heads: []const ChangeHash) ![]ChangeHash {
        try self.close();
        return self.doc.getMissingDeps(gpa, heads);
    }

    pub fn getChangeByHash(self: *AMdoc, gpa: Allocator, hash: ChangeHash) !?docmod.Built {
        try self.close();
        return self.doc.getChangeByHash(gpa, hash);
    }

    pub fn getLastLocalChange(self: *AMdoc, gpa: Allocator) !?docmod.Built {
        try self.close();
        return self.doc.getLastLocalChange(gpa);
    }

    pub fn merge(self: *AMdoc, gpa: Allocator, other: *AMdoc) ![]ChangeHash {
        try self.close();
        try other.close();
        return self.doc.merge(gpa, &other.doc);
    }

    /// [`AutoCommit::clone`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs:108-111)
    /// closes the transaction before it copies, so the copy has nothing open.
    pub fn cloneDoc(self: *AMdoc, gpa: Allocator) !AMdoc {
        try self.close();
        return .{ .doc = try self.doc.clone(gpa, .auto) };
    }

    /// [`AutoCommit::fork`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs:356-367)
    /// closes the transaction and returns the **new** `AutoCommit`; the
    /// reference hands that value straight to `to_result`
    /// ([`automerge-c/src/doc.rs:252`](../../github-automerge-automerge/rust/automerge-c/src/doc.rs)),
    /// which makes it the result's one `AM_VAL_TYPE_DOC` item. Nothing is
    /// discarded and nothing is a side effect.
    pub fn forkDoc(self: *AMdoc, gpa: Allocator) !AMdoc {
        try self.close();
        return .{ .doc = try self.doc.fork(gpa, .auto) };
    }

    /// [`AutoCommit::fork_at`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs:369-380)
    /// through `AMfork`'s `heads` arm, and the same value out.
    pub fn forkDocAt(self: *AMdoc, gpa: Allocator, heads: []const ChangeHash) !AMdoc {
        try self.close();
        return .{ .doc = try self.doc.forkAt(gpa, heads, .auto) };
    }

    pub fn isolate(self: *AMdoc, gpa: Allocator, heads: []const ChangeHash) !void {
        try self.close();
        return self.doc.isolate(gpa, heads);
    }

    /// [`AutoCommit::integrate`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):439-443),
    /// which is **fallible in this port** because it replays a view
    /// transition ([`Document.patchTo`](doc.zig)).
    ///
    /// **There is no `AMintegrate` export and `include/automerge.h` declares
    /// none**, so nothing downstream of this method moves; it is reachable
    /// from Zig only. That is the whole of the C-ABI cost of widening
    /// [`Document.integrate`](doc.zig).
    pub fn integrate(self: *AMdoc) !void {
        self.close() catch {};
        return self.doc.integrate();
    }

    pub fn stats(self: *AMdoc) !docmod.Stats {
        try self.close();
        return self.doc.stats();
    }
};

/// `AMactorId`. Rust: `src/actor_id.rs:17-22`.
///
/// The reference's `body` is a `*const am::ActorId` — a **borrow** of an
/// actor id that lives inside some other handle. This port's `types.ActorId`
/// is a `[]const u8`, so the borrow is a pointer to it and the bytes are owned
/// by whichever cell created the handle ([`Value.actor_id`] or
/// [`AMobjId`]'s cache). **A C caller therefore never frees an `AMactorId`**:
/// it frees the result the handle was reached through.
pub const AMactorId = struct {
    /// The borrowed actor id. Rust: `body: *const am::ActorId` (`:18`).
    body: *const ActorId,
    /// The allocator, for [`hex`]. Rust reaches the same thing through the
    /// global `Box` (`:19`, `src/result.rs:95`).
    gpa: Allocator,
    /// `hex_str: RefCell<Option<Box<str>>>` (Rust: `src/actor_id.rs:19`).
    /// Filled on the first [`toStr`] and freed with the cell.
    hex: ?[]u8 = null,

    pub fn deinit(self: *AMactorId) void {
        if (self.hex) |h| self.gpa.free(h);
        self.* = undefined;
    }

    /// The value as bytes. Rust: `actor_id.as_ref().into()`
    /// (`src/actor_id.rs:73`).
    pub fn toBytes(self: *const AMactorId) []const u8 {
        return self.body.bytes;
    }

    /// The value as a lowercase hexadecimal UTF-8 view, computed once.
    /// Rust: `AMactorId::to_str` (`src/actor_id.rs:32-42`), reached from
    /// `AMactorIdStr` at `:180`.
    ///
    /// Takes a mutable pointer through `@constCast` because the C prototype is
    /// `const AMactorId *` (`src/actor_id.rs:177`) and the reference fills the
    /// cache through a `RefCell` for the same reason. The cached bytes live
    /// inside this handle, so a C caller that keeps the span keeps the handle
    /// alive and the cache is built at most once.
    pub fn toStr(self: *const AMactorId) []const u8 {
        const cell: *AMactorId = @constCast(self);
        if (cell.hex) |h| return h;
        const out = cell.gpa.alloc(u8, cell.body.bytes.len * 2) catch return "";
        err.hexInto(cell.body.bytes, out);
        cell.hex = out;
        return out;
    }

    /// `#[derive(Eq, PartialEq)]` (Rust: `src/actor_id.rs:17`) compares the
    /// borrowed `ActorId`, which compares the bytes.
    pub fn eql(a: AMactorId, b: AMactorId) bool {
        return ActorId.eql(a.body.*, b.body.*);
    }
};

/// `AMchange`. Rust: `src/change.rs:17-24`.
///
/// The reference's `body` is a `*mut am::Change` — a borrow of a change that
/// lives inside some other handle — and this port's [`changemod.Change`] is a
/// value with a `deinit`, so the borrow is a **pointer to an owned change**:
/// whoever built it (`Value.change`, [`changeItem`]) owns it and frees it here.
pub const AMchange = struct {
    gpa: Allocator,
    /// The borrowed change. Rust: `body: *mut am::Change`
    /// (`src/change.rs:19`).
    change: *changemod.Change,
    /// The change's **framed** bytes, which is what `raw_bytes()` reports
    /// (`src/change.rs:344-352`). Owned because the body a document-sourced
    /// change was read from belongs to a `Built` that dies with the result.
    raw: []u8,
    /// `change_hash: RefCell<Option<am::ChangeHash>>` (Rust: `src/change.rs:23`)
    /// is not needed: the port's `Change` carries its own `hash` field
    /// (`change.zig:110-111`).
    ///
    /// What the reference gets from the same cache — a **deflated** body,
    /// because `Change::bytes()` materialises `Cow::Compressed` inside the
    /// change and `raw_bytes()` then reports it — is [`compressed`] here.
    compressed: ?[]u8 = null,
    /// The author footer, which upstream's `extra_bytes()` reports
    /// (`src/change.rs:117-126`) and this port keeps inside `Change.bytes`
    /// (`change.zig:230-234`). Filled on demand from
    /// [`changechunk.ChangeChunk.footer`](../storage/change_chunk.zig), which is
    /// "whatever is left" after the op columns.
    footer: ?[]u8 = null,
    /// The change's operation count, which upstream's `len()` reports
    /// (`src/change.rs:288-295`) and this port stores nowhere on a freshly
    /// parsed change (`change.zig:126-131`). Filled on demand from
    /// [`changechunk.ChangeChunk.opCount`](../storage/change_chunk.zig).
    op_count: ?usize = null,

    pub fn deinit(self: *AMchange) void {
        self.change.deinit(self.gpa);
        self.gpa.destroy(self.change);
        self.gpa.free(self.raw);
        if (self.compressed) |c| self.gpa.free(c);
        if (self.footer) |f| self.gpa.free(f);
        self.* = undefined;
    }

    /// The hash, as a span into the borrowed change. Rust: `change.hash()`
    /// (`src/change.rs:41-49`) and `AMchangeHash` at `:172`.
    pub fn hashBytes(self: *const AMchange) []const u8 {
        return &self.change.hash.bytes;
    }

    /// The change's message, or the zero span. Rust: `Change::message`
    /// (`src/change.rs:26-30`) and `AMchangeMessage` at `:252`.
    pub fn messageBytes(self: *const AMchange) []const u8 {
        return self.change.message;
    }

    /// `AMchangeRawBytes`: the **whole framed chunk, header included, and
    /// never the deflated form.** Rust: `change.as_ref().raw_bytes().into()`
    /// (`src/change.rs:345-351`), which is `self.stored.bytes()`
    /// ([`change.rs:118-120`](../../github-automerge-automerge/rust/automerge/src/change.rs)),
    /// which is `&self.bytes` — "the raw bytes of the entire chunk containing
    /// this change, including the header"
    /// ([`storage/change.rs:264-266`](../../github-automerge-automerge/rust/automerge/src/storage/change.rs)).
    ///
    /// **The deflated form is not this accessor.** Upstream keeps the two
    /// apart: `bytes()` is `&mut self` and materialises a compressed body
    /// ([`change.rs:102-116`](../../github-automerge-automerge/rust/automerge/src/change.rs)),
    /// `raw_bytes()` is `&self` and never does. An earlier revision of this
    /// file returned the deflated bytes from here once [`compress`] had run,
    /// which made `AMchangeCompress` observably change `AMchangeRawBytes` —
    /// and no C caller can see that upstream.
    pub fn rawBytes(self: *const AMchange) []const u8 {
        return self.raw;
    }

    /// `AMchangeCompress`: materialise the deflated **body**, once. Rust:
    /// `change.as_mut().bytes()` (`src/change.rs:98-103`), which reaches
    /// `StoredChange::compress`
    /// ([`storage/change.rs:295-301`](../../github-automerge-automerge/rust/automerge/src/storage/change.rs))
    /// and so deflates `body_bytes()` — `&self.bytes[self.header.len()..]`
    /// (`:260-262`) — **not the whole chunk**.
    ///
    /// Two things this used to get wrong, both found by
    /// `test_AMchangeCompress`:
    ///
    /// * the compressor was handed the framed chunk, so the "compressed"
    ///   payload was a framed chunk. Inflating it gave a framed chunk back and
    ///   [`parsedRaw`] read a chunk header as a change header, which is
    ///   `error.LengthExceedsInput`
    ///   ([`change_chunk.zig:484`](../storage/change_chunk.zig)).
    /// * `rawBytes` reported the result, which upstream's does not.
    ///
    /// **Upstream also skips a body at or under `DEFLATE_MIN_SIZE`**, handing
    /// back the plain chunk (`storage/change.rs:296-300`); the port does not
    /// model that threshold, and the difference is invisible here because, as
    /// above, no C export reports the deflated form. The checksum the
    /// compressor stores covers the **inflated** body
    /// ([`change/compressed.rs:18-34`](../../github-automerge-automerge/rust/automerge/src/storage/change/compressed.rs)).
    pub fn compress(self: *AMchange) void {
        if (self.compressed != null) return;
        const framed = chunkmod.parseChunk(self.raw) catch return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        chunkmod.compressChunk(&out, self.gpa, framed.data) catch return;
        self.compressed = out.toOwnedSlice(self.gpa) catch null;
    }

    /// The change chunk inside [`raw`], parsed.
    ///
    /// **`raw` is a framed chunk and `parseChangeChunk` takes a body.**
    /// [`changechunk.parseChangeChunk`](../storage/change_chunk.zig:431-438)
    /// opens with `body` and says so: "`body` is the body only, with no chunk
    /// framing — what `chunk.parseChunk` hands back for a `ChunkType.change`
    /// chunk, and what `chunk.decompressChunk` produces for a compressed one.
    /// To go through the framing as well, use `parseFramedChunk`; it is the
    /// only path that inflates."
    ///
    /// `raw` is framed in both directions a change enters this handle:
    /// [`AMchangeFromBytes`] duplicates the C caller's bytes, and those are
    /// what `am::Change::from_bytes` takes — a framed chunk
    /// ([`change.rs:160-163`](../../github-automerge-automerge/rust/automerge-c/src/change.rs));
    /// [`ownedChangeValue`] frames a document's body with
    /// `chunk.writeChunk` for the same reason. So the two calls below used to
    /// hand the parser a chunk type byte and a varint length where the header
    /// wanted a dependency count, and every one of them answered `0` or the
    /// empty span. Null on a refusal, which is what both callers already turn
    /// into their own empty answer.
    fn parsedRaw(self: *const AMchange) ?changechunk.OwnedChangeChunk {
        const cell: *AMchange = @constCast(self);
        const framed = chunkmod.parseChunk(self.raw) catch return null;
        return changechunk.parseFramedChunk(framed, cell.gpa) catch null;
    }

    /// `AMchangeExtraBytes`: the author footer. Rust: `change.as_ref().extra_bytes()`
    /// (`src/change.rs:128-131`).
    pub fn extraBytes(self: *const AMchange) []const u8 {
        const cell: *AMchange = @constCast(self);
        if (cell.footer) |f| return f;
        var cc = self.parsedRaw() orelse return &.{};
        defer cc.deinit(cell.gpa);
        const f = cell.gpa.dupe(u8, cc.parsed.footer) catch return &.{};
        cell.footer = f;
        return f;
    }

    /// `AMchangeSize`: the count of operations. Rust: `change.as_ref().len()`
    /// (`src/change.rs:288-295`).
    ///
    /// A change that came out of a document has `start_op` from the header
    /// and `start_op ..= max_op` is the operation range, so the short answer
    /// is `max_op - start_op + 1`; a freshly parsed change carries neither
    /// `max_op` nor an op count (`change.zig:49-51`, `:126-131`), so the
    /// columns are walked through [`parsedRaw`].
    pub fn size(self: *const AMchange) usize {
        const cell: *AMchange = @constCast(self);
        if (cell.op_count) |n| return n;
        const chg = self.change;
        if (chg.max_op >= chg.start_op) {
            const n: usize = @intCast(chg.max_op - chg.start_op + 1);
            cell.op_count = n;
            return n;
        }
        var cc = self.parsedRaw() orelse return 0;
        defer cc.deinit(cell.gpa);
        const n = cc.parsed.opCount() catch return 0;
        cell.op_count = n;
        return n;
    }
};

/// `AMcursor`. Rust: `src/cursor.rs:25-31`.
///
/// The reference owns the cursor by value and keeps the two serialised forms
/// alive beside it so a returned span outlives the call. This port does the
/// same: [`body`] is the value and the two caches are owned here.
pub const AMcursor = struct {
    /// The cursor. Rust: `body: am::Cursor` (`src/cursor.rs:26`).
    body: Cursor,
    gpa: Allocator,
    /// `bytes: RefCell<Option<Vec<u8>>>` (Rust: `src/cursor.rs:28`).
    bytes: ?[]u8 = null,
    /// `fmt_str: RefCell<Option<Box<str>>>` (Rust: `src/cursor.rs:29`).
    fmt_str: ?[]u8 = null,

    pub fn deinit(self: *AMcursor) void {
        if (self.bytes) |b| self.gpa.free(b);
        if (self.fmt_str) |s| self.gpa.free(s);
        self.* = undefined;
    }

    /// `AMcursorBytes`. Rust: `AMcursor::to_bytes` (`src/cursor.rs:35-42`),
    /// reached from `AMcursorBytes` at `:77`.
    pub fn toBytes(self: *const AMcursor) []const u8 {
        const cell: *AMcursor = @constCast(self);
        if (cell.bytes) |b| return b;
        const out = cursormod.toBytes(cell.gpa, cell.body) catch return &.{};
        cell.bytes = out;
        return out;
    }

    /// `AMcursorStr`. Rust: `AMcursor::to_str` (`src/cursor.rs:44-49`),
    /// reached from `AMcursorStr` at `:161`.
    pub fn toStr(self: *const AMcursor) []const u8 {
        const cell: *AMcursor = @constCast(self);
        if (cell.fmt_str) |s| return s;
        const out = cursormod.toStr(cell.gpa, cell.body) catch return &.{};
        cell.fmt_str = out;
        return out;
    }

    /// `#[derive(PartialEq)]` (Rust: `src/cursor.rs:25`) compares the wrapped
    /// `Cursor`, which is the port's `Cursor.eql`.
    pub fn eql(a: AMcursor, b: AMcursor) bool {
        return a.body.eql(b.body);
    }
};

/// `AMobjId`. Rust: `src/obj.rs:15-20`.
///
/// The reference's `body` is an `am::ObjId`, which is
/// `Root | Id(counter, actor_id, index)` (`src/obj.rs:31-38`) — it names the
/// actor by **bytes**. The port's [`types.ExId`] names it by **index**
/// (`types.zig:245-247`), so this handle carries the resolved bytes as well,
/// and the two are converted through the document that owns the actor table.
/// All three of upstream's components are carried: the counter, the actor's
/// bytes, and the actor's table index. See [`AMobjIdIndex`] for why the last
/// one is the actor index.
pub const AMobjId = struct {
    gpa: Allocator,
    /// `am::ObjId::Id`'s counter. Rust: `src/obj.rs:32`.
    counter: u64,
    /// `am::ObjId::Root` rather than `Id`. Rust: `src/obj.rs:35`.
    root: bool,
    /// `c_actor_id: RefCell<Option<AMactorId>>` (Rust: `src/obj.rs:19`).
    /// Null for the root, which is upstream's `std::ptr::null()` fallthrough
    /// (`src/obj.rs:36-47`).
    c_actor_id: ?*AMactorId = null,
    /// `am::ObjId::Id`'s third component: the index of the object's actor in
    /// the document's actor table. Rust: `OpSet::id_to_exid` builds it as
    /// `ExId::Id(id.counter(), self.actors[id.actor()].clone(), id.actor())`
    /// ([`op_set.rs:1054-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
    /// so it is the **actor index and not an element index** — the name
    /// `AMobjIdIndex` invites the other reading and upstream's three-tuple is
    /// the only thing that settles it. Zero for the root, which is `ObjId::Root`
    /// and has no index at all
    /// ([`obj.rs:151-162`](../../github-automerge-automerge/rust/automerge-c/src/obj.rs)).
    index: usize = 0,

    /// The root object. Rust: `&automerge::ROOT` (`src/obj.rs:11-17`).
    pub fn rootObj(gpa: Allocator) AMobjId {
        return .{ .gpa = gpa, .counter = 0, .root = true };
    }

    /// A real object. `actor_bytes` is **copied** because the port's `ExId`
    /// borrows its actor from a document's table and this handle outlives that
    /// document. Upstream's `am::ObjId` owns its actor id for the same reason.
    ///
    /// **Two cells, not one.** [`AMactorId`] is `{ body: *const ActorId, gpa,
    /// hex: ?[]u8 }` and [`ActorId`] is `{ bytes: []const u8 }`; they are not
    /// the same layout, so a bare `@ptrCast` from one to the other produces a
    /// handle whose `body` is the actor's *slice* and whose `gpa` is whatever
    /// followed it in memory. The handle is built properly here, and
    /// [`newActorHandle`] is where the two cells are made.
    pub fn of(gpa: Allocator, counter: u64, index: usize, actor_bytes: []const u8) !AMobjId {
        const handle = try newActorHandle(gpa, actor_bytes);
        return .{ .gpa = gpa, .counter = counter, .index = index, .root = false, .c_actor_id = handle };
    }

    pub fn deinit(self: *AMobjId) void {
        // Every `AMobjId` that carries an actor cell goes through here, which
        // is every read that reports a row's id — `AMobjItems`, `AMmapGet`,
        // `AMlistGet`, both `*GetAll`s, both `*Range`s and both
        // `*PutObject`s — and the one free of the handle is
        // [`destroyActorHandle`]'s, including the reason the body is read out
        // before the handle is deinitialised.
        if (self.c_actor_id) |a| destroyActorHandle(a);
        self.* = undefined;
    }

    /// `AMobjIdActorId`. Rust: `obj_id.actor_id()` (`src/obj.rs:36-47`).
    ///
    /// The reference fills `c_actor_id` on the first call and returns a null
    /// pointer for the root. This port builds the handle in [`of`] instead, so
    /// there is nothing to fill in; the `@constCast` that the reference's
    /// `RefCell` buys is therefore not needed, and the answer is the same
    /// pointer every call.
    pub fn actorHandle(self: *AMobjId) ?*AMactorId {
        if (self.root) return null;
        return self.c_actor_id;
    }

    /// `#[derive(Eq, PartialEq)]` (Rust: `src/obj.rs:15`) compares the whole
    /// `am::ObjId`, which is the triple — and, for the root, the tag. The
    /// port has no index component, so this compares the tag and the counter
    /// and the actor bytes.
    pub fn eql(a: AMobjId, b: AMobjId) bool {
        if (a.root != b.root) return false;
        if (a.root) return true;
        const x = a.c_actor_id orelse return false;
        const y = b.c_actor_id orelse return false;
        return a.counter == b.counter and ActorId.eql(x.body.*, y.body.*);
    }
};

/// `AMmark`. Rust: `src/doc/mark.rs:82-84`.
///
/// The reference's `pub struct AMmark(Mark)`, where `Mark<'a>` **borrows** its
/// name and value from the document (`marks.rs:28-33`). So this does too, and
/// `AMmarkName` and `AMmarkValue` hand out borrows into the document that
/// produced the mark — exactly the reference's lifetime, and the reason the
/// header says a mark's name is a view and its value is a fresh result.
pub const AMmark = struct {
    start: usize,
    end: usize,
    /// Borrowed from the document. Rust: `Mark::name` (`marks.rs:235-237`).
    name: []const u8,
    /// Borrowed from the document. Rust: `Mark::value` (`marks.rs:239-241`).
    value: ScalarValue,
};

/// The port's `AMindex`. Rust: `src/index.rs:8-12`.
///
/// `Key(SmolStr)` and `Pos(usize)`. The reference's `SmolStr` owns its bytes
/// (it is inline up to 22 bytes and a `Box` beyond), so this owns them too:
/// the key an `AMitem` reports through `AMitemKey` has to be readable after
/// the document it came from is gone.
pub const AMindex = struct {
    gpa: Allocator,
    tag: AMidxType,
    /// The key's bytes, when `tag` is [`AMidxType.AM_IDX_TYPE_KEY`].
    key: ?[]u8 = null,
    /// The position, when `tag` is [`AMidxType.AM_IDX_TYPE_POS`].
    pos: usize = 0,

    pub fn ofKey(gpa: Allocator, key: []const u8) !AMindex {
        return .{
            .gpa = gpa,
            .tag = .AM_IDX_TYPE_KEY,
            .key = try gpa.dupe(u8, key),
        };
    }

    pub fn ofPos(gpa: Allocator, pos: usize) AMindex {
        return .{ .gpa = gpa, .tag = .AM_IDX_TYPE_POS, .pos = pos };
    }

    pub fn deinit(self: *AMindex) void {
        if (self.key) |k| self.gpa.free(k);
        self.* = undefined;
    }

    /// `TryFrom<&AMindex> for AMbyteSpan` (Rust: `src/index.rs:16-30`): the key
    /// arm succeeds and the position arm is
    /// `AutomergeError::InvalidValueType`.
    pub fn keySlice(self: *const AMindex) ?[]const u8 {
        return if (self.tag == .AM_IDX_TYPE_KEY) self.key else null;
    }

    /// `TryFrom<&AMindex> for usize` (Rust: `src/index.rs:32-45`): the position
    /// arm succeeds and the key arm is `InvalidValueType`.
    pub fn position(self: *const AMindex) ?usize {
        return if (self.tag == .AM_IDX_TYPE_POS) self.pos else null;
    }

    pub fn eql(a: AMindex, b: AMindex) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .AM_IDX_TYPE_KEY => std.mem.eql(u8, a.key orelse "", b.key orelse ""),
            .AM_IDX_TYPE_POS => a.pos == b.pos,
            .AM_IDX_TYPE_DEFAULT => true,
        };
    }
};

// ---------------------------------------------------------------------------
// The value model. Rust: src/item.rs:32-45 (`Value`) and :517-525 (`Item`).
// ---------------------------------------------------------------------------

/// `Value`. Rust: `src/item.rs:32-45`.
///
/// The reference's eleven variants, one for each thing an `AMitem` can hold,
/// and this port's eleven. The two `UnsafeCell<Option<…>>` /
/// `RefCell<Option<…>>` second fields the reference parks beside four of them
/// (`src/item.rs:34-42`) are caches for a lazily created `*const AM*`
/// handle; **this port does not need them**, because the handle is stored
/// inline in this union and `AMitemTo*` hands out a pointer into the item's
/// own heap allocation. See the module doc.
pub const Value = union(enum) {
    /// `ActorId(am::ActorId, UnsafeCell<Option<AMactorId>>)`. Rust: `:34`.
    actor_id: AMactorId,
    /// `Change(Box<am::Change>, UnsafeCell<Option<AMchange>>)`. Rust: `:35`.
    change: AMchange,
    /// `ChangeHash(am::ChangeHash)`. Rust: `:36`.
    change_hash: ChangeHash,
    /// `Cursor(AMcursor)`. Rust: `:37`.
    cursor: AMcursor,
    /// `Doc(RefCell<AMdoc>)`. Rust: `:38`.
    doc: AMdoc,
    /// `Mark(AMmark)`. Rust: `:39`.
    mark: AMmark,
    /// `SyncHave(AMsyncHave)`. Rust: `:40`.
    sync_have: syncmod.AMsyncHave,
    /// `SyncMessage(AMsyncMessage)`. Rust: `:41`.
    sync_message: syncmod.AMsyncMessage,
    /// `SyncState(RefCell<AMsyncState>)`. Rust: `:42`.
    sync_state: syncmod.AMsyncState,
    /// `Value(am::Value<'static>)`. Rust: `:44`.
    ///
    /// Upstream's `am::Value` is `Scalar(ScalarValue) | Object(ObjType)`, and
    /// this port's [`optypes.OwnedValueRef`] is the owned form of the same
    /// two shapes (`opset/types.zig:235-240`).
    value: optypes.OwnedValueRef,

    /// Frees everything this variant owns. The mark is the one that owns
    /// nothing: upstream's `Mark` borrows its name and value
    /// (`marks.rs:28-33`) and so does [`AMmark`].
    ///
    /// **`.actor_id` also owns the actor it borrows.** Upstream's
    /// `AMactorId` is a `*const am::ActorId` borrow
    /// ([`src/actor_id.rs:26-29`](../../github-automerge-automerge/rust/automerge-c/src/actor_id.rs))
    /// and so has no destructor to free it in; this port's `body` is a heap
    /// cell [`actorValue] allocated, so this function is where it goes. The
    /// allocator and the body are read out **before** [`AMactorId.deinit`]
    /// runs, for the reason [`destroyActorHandle`] gives: it writes
    /// `undefined` over the cell, so `v.body` or `v.gpa` read afterwards is
    /// whatever the allocator left there. **The two lines that free the body
    /// are the same two it runs, and are not a copy of it**: this is a
    /// [`Value`]'s *inline* [`AMactorId`], so there is no handle cell to
    /// destroy and [`destroyActorHandle`] must not be reached for.
    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .actor_id => |*v| {
                const body = v.body;
                const owner = v.gpa;
                v.deinit();
                owner.free(body.bytes);
                owner.destroy(body);
            },
            .change => |*v| v.deinit(),
            .cursor => |*v| v.deinit(),
            .doc => |*v| v.deinit(),
            .sync_have => |*v| v.deinit(),
            .sync_message => |*v| v.deinit(),
            .sync_state => |*v| v.deinit(),
            .value => |*v| v.deinit(gpa),
            .change_hash, .mark => {},
        }
    }

    /// `impl From<&Value> for AMvalType` (Rust: `src/item.rs:1372-1389`) over
    /// `impl From<&am::Value<'static>> for AMvalType` (`:1349-1370`).
    pub fn valType(self: *const Value) AMvalType {
        return switch (self.*) {
            .actor_id => .AM_VAL_TYPE_ACTOR_ID,
            .change => .AM_VAL_TYPE_CHANGE,
            .change_hash => .AM_VAL_TYPE_CHANGE_HASH,
            .cursor => .AM_VAL_TYPE_CURSOR,
            .doc => .AM_VAL_TYPE_DOC,
            .mark => .AM_VAL_TYPE_MARK,
            .sync_have => .AM_VAL_TYPE_SYNC_HAVE,
            .sync_message => .AM_VAL_TYPE_SYNC_MESSAGE,
            .sync_state => .AM_VAL_TYPE_SYNC_STATE,
            .value => |v| switch (v.value) {
                .object => .AM_VAL_TYPE_OBJ_TYPE,
                .scalar => |s| switch (s) {
                    .null_value => .AM_VAL_TYPE_NULL,
                    .bool_value => .AM_VAL_TYPE_BOOL,
                    .bytes => .AM_VAL_TYPE_BYTES,
                    .counter => .AM_VAL_TYPE_COUNTER,
                    .float => .AM_VAL_TYPE_F64,
                    .int => .AM_VAL_TYPE_INT,
                    .str => .AM_VAL_TYPE_STR,
                    .timestamp => .AM_VAL_TYPE_TIMESTAMP,
                    .uint => .AM_VAL_TYPE_UINT,
                    // An actor id encodes as `bytes` in the value column and
                    // as an actor reference in the key columns; the
                    // distinction is the op's, not the value's
                    // (`value.zig`, `ScalarValue.valueType`). Upstream's
                    // `am::ScalarValue` has no actor variant at all, so a
                    // stored actor id reaches a reader as `Bytes` there.
                    .actor_id, .unknown => .AM_VAL_TYPE_UNKNOWN,
                },
            },
        };
    }

    /// `impl PartialEq for Value` (Rust: `src/item.rs:500-514`).
    ///
    /// **The `_ => false` arm is load-bearing and is reproduced exactly**: the
    /// reference has no `(Cursor, Cursor)`, `(Mark, Mark)` or
    /// `(SyncHave, SyncHave)` arm, so two cursor items, two mark items and two
    /// have items are *never* equal. `AMitemEqual` on the same item twice still
    /// succeeds, because the handle compares its own cell first.
    pub fn eql(a: *const Value, b: *const Value) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .actor_id => |x| AMactorId.eql(x, b.actor_id),
            // `lhs == rhs` over two `Box<am::Change>` (`:507`). The port's
            // `Change` has no `eql`, and two changes are the same change iff
            // they hash the same, because the hash is SHA-256 over the
            // encoded change (`types.zig:30-31`).
            .change => |x| x.change.hash.eql(b.change.change.hash),
            .change_hash => |x| x.eql(b.change_hash),
            // `Doc(lhs), Doc(rhs) => lhs.as_ptr() == rhs.as_ptr()` (`:508`):
            // the reference compares the two `RefCell` addresses, so only the
            // *same* document compares equal and a clone never does. This
            // compares the address of the two inline cells, which is the same
            // test and the same answer.
            .doc => @intFromPtr(a) == @intFromPtr(b),
            .sync_state => |x| syncmod.statesEqual(x.body, b.sync_state.body),
            .value => |x| ownedValueRefEql(&x, &b.value),
            .cursor, .mark, .sync_have, .sync_message => false,
        };
    }
};

/// `am::Value`'s `PartialEq`, over the port's owned form. Upstream compares
/// `Scalar(ScalarValue)` with the scalar's `eq` and `Object(ObjType)` with the
/// enum's own equality (`src/item.rs:511`).
fn ownedValueRefEql(a: *const optypes.OwnedValueRef, b: *const optypes.OwnedValueRef) bool {
    if (a.value != .scalar or b.value != .scalar) {
        // `Object(ObjType) == Object(ObjType)` and nothing else survives the
        // tag check, which is what `am::Value`'s derive gives (`item.rs:511`).
        return a.value == .object and b.value == .object and
            a.value.object == b.value.object;
    }
    return a.value.scalar.eql(b.value.scalar);
}

/// `Item`. Rust: `src/item.rs:517-525`.
///
/// Three optional fields, all of them a borrow in the reference and all of them
/// **owned or fixed-size** here except the mark, which borrows exactly as
/// upstream's does.
pub const Item = struct {
    /// `index: Option<AMindex>` (Rust: `src/item.rs:518`).
    index: ?AMindex = null,
    /// `obj_id: Option<AMobjId>` (Rust: `:520`).
    obj_id: ?AMobjId = null,
    /// `value: Option<Value>` (Rust: `:522`).
    value: ?Value = null,

    pub fn deinit(self: *Item, gpa: Allocator) void {
        if (self.index) |*i| i.deinit();
        if (self.obj_id) |*o| o.deinit();
        if (self.value) |*v| v.deinit(gpa);
        self.* = undefined;
    }

    /// `impl PartialEq for Item` (Rust: `src/item.rs:693-697`): the three
    /// fields, with `None == None`.
    pub fn eql(a: *const Item, b: *const Item) bool {
        if ((a.index == null) != (b.index == null)) return false;
        if (a.index) |x| if (!x.eql(b.index.?)) return false;
        if ((a.obj_id == null) != (b.obj_id == null)) return false;
        if (a.obj_id) |x| if (!x.eql(b.obj_id.?)) return false;
        if ((a.value == null) != (b.value == null)) return false;
        if (a.value) |x| if (!x.eql(&b.value.?)) return false;
        return true;
    }

    /// `impl From<&Item> for AMvalType` (Rust: `src/item.rs:1391-1397`): a
    /// value-less item is `AM_VAL_TYPE_VOID`, and a *null* item is
    /// `AM_VAL_TYPE_DEFAULT` (`:2172-2177`).
    pub fn valType(self: *const Item) AMvalType {
        const v = self.value orelse return .AM_VAL_TYPE_VOID;
        return v.valType();
    }

    /// `impl From<&Item> for AMidxType` (Rust: `src/item.rs:817-824`): no index
    /// is the default tag.
    pub fn idxType(self: *const Item) AMidxType {
        const i = self.index orelse return .AM_IDX_TYPE_DEFAULT;
        return i.tag;
    }
};

/// The `Rc`'s heap cell. Upstream's `Rc<Item>` (`src/item.rs:1023-1024`).
const RcItem = struct {
    /// `Rc::strong_count` (`src/item.rs:1672`).
    count: usize,
    item: Item,
};

/// `AMitem`. Rust: `src/item.rs:1023-1024`, `pub struct AMitem(Rc<Item>)`.
///
/// **The one heap cell per item** is what makes the C ABI's single-destructor
/// rule work: [`deinit`] is the `Drop` of the `Rc` and [`abi.AMresultFree`] is
/// the only export that reaches it.
pub const AMitem = struct {
    rc: *RcItem,

    /// `Rc::new`. Fails only on allocation.
    pub fn create(alloc: Allocator, item: Item) Allocator.Error!AMitem {
        const rc = try alloc.create(RcItem);
        rc.* = .{ .count = 1, .item = item };
        return .{ .rc = rc };
    }

    /// `#[derive(Clone)]` (Rust: `src/item.rs:1023`), which clones the `Rc`:
    /// the count goes up and the item is **not** copied. This is what
    /// `AMitemResult` does (`src/item.rs:1693`) and what `Result.cat` does
    /// through `Vec<AMitem>`'s `cloned()` (`src/result.rs:507-511`).
    pub fn retain(self: AMitem) AMitem {
        self.rc.count += 1;
        return self;
    }

    /// The `Drop` of the `Rc`. Upstream drops it inside the
    /// `Vec<AMitem>` the result owns (`src/result.rs:12`, `:559`).
    ///
    /// **The last reference tears the item down where it lies.** `Item` is
    /// not only what this frees: a `Value` can own a handle that points back
    /// into the item's own storage — an [`AMdoc`]'s open
    /// [`transact.Transaction`] holds a `*Document` to the document it was
    /// opened against ([`src/transact.zig:285`](../../github-automerge-automerge/rust/automerge/src/transact.zig)),
    /// which is the address of the `Document` inside this item
    /// ([`Value.doc`](#Value)). Copying the struct onto the stack and
    /// deinitialising the copy frees what the copy points at while every
    /// pointer into the item still addresses the heap object, so a commit
    /// reached through one of them reallocates buffers the copy's copies of
    /// the owning structs no longer name. `Rc::drop` runs the `Item`'s
    /// destructor on the `Item` itself, which is what `self.rc.item.deinit`
    /// says.
    pub fn deinit(self: AMitem, gpa: Allocator) void {
        std.debug.assert(self.rc.count > 0);
        self.rc.count -= 1;
        if (self.rc.count != 0) return;
        self.rc.item.deinit(gpa);
        gpa.destroy(self.rc);
    }

    /// `impl AsRef<Item> for AMitem` (Rust: `src/item.rs:1044-1048`).
    pub fn get(self: AMitem) *const Item {
        return &self.rc.item;
    }

    /// `Rc::get_mut` (Rust: `src/item.rs:1186`, `:1206`, `:1242`), which is
    /// null unless this is the only reference. The three `AMitemTo*` functions
    /// that hand out a `*mut` use it and report failure otherwise.
    pub fn getMut(self: *AMitem) ?*Item {
        if (self.rc.count != 1) return null;
        return &self.rc.item;
    }

    /// `Rc::strong_count(&item.0)` (Rust: `src/item.rs:1672`).
    pub fn refCount(self: AMitem) usize {
        return self.rc.count;
    }

    /// `impl PartialEq for AMitem` (Rust: `src/item.rs:1144-1148`), which is
    /// `Item`'s `PartialEq` through the `Rc`.
    pub fn eql(a: AMitem, b: AMitem) bool {
        if (a.rc == b.rc) return true;
        return a.rc.item.eql(&b.rc.item);
    }
};

// ---------------------------------------------------------------------------
// The C-callable surface result.zig cannot emit without an item type.
//
// `CAbi(AMitem)` is instantiated exactly once, here, and it emits the
// twenty-six `AMresult*`, `AMitems*`, `AMstack*`, `AMstrdup` and
// `AMstackCallbackDataInit` exports (result.zig's "the C ABI" section). Two
// instantiations would emit the same symbols twice, which is why nothing else
// in `src/c/` instantiates it.
// ---------------------------------------------------------------------------

/// The whole `AMresult` / `AMitems` / `AMstack` surface, over [`AMitem`].
pub const abi = result.CAbi(AMitem);

/// `AMresult` over this port's item. Rust: `src/result.rs:9-15`.
pub const AMresult = abi.AMresult;
/// `AMitems` over this port's item. Rust: `src/items.rs:125-132`.
pub const AMitems = abi.AMitems;
/// A node in a stack of results. Rust: `include/automerge-c/utils/stack.h:21-26`.
pub const AMstack = abi.AMstack;
/// The prototype of a result validator. Rust:
/// `include/automerge-c/utils/stack.h:39`.
pub const AMstackCallback = abi.AMstackCallback;

/// The allocator the C ABI allocates from.
///
/// The reference resolves this through Rust's global `Box` allocator
/// (`src/result.rs:95`, `:466-468`). A C ABI whose signatures are fixed cannot
/// carry one, so this binds `std.heap.c_allocator` — the C runtime's `malloc`.
/// That is the only choice that keeps the ABI and `AMstrdup`'s documented
/// "must be passed to `free()`" contract
/// (`include/automerge-c/utils/string.h:24-25`) simultaneously true, and it is
/// what the reference's `Box` resolves to in a release build anyway. See
/// [result.zig](result.zig)'s module doc, which is the authority for this
/// decision; this is the same constant, named once.
pub const c_allocator = abi.c_allocator;

/// The allocator every entry point in this file uses.
const c_alloc = c_allocator;

// ---------------------------------------------------------------------------
// The result helpers: `to_result` (Rust: `src/result.rs:466-468`) plus the
// `impl From<Result<…>> for AMresult` family (`src/result.rs:250-460`), which is
// what turns each upstream return type into the right item list.
// ---------------------------------------------------------------------------

/// `AMresult::items(Vec::new())` — an **empty success**, which is what
/// `Default::default()` becomes in every `match … { None => Default::default() }`
/// arm (`src/sync/message.rs:98`, `src/actor_id.rs:73`). Distinct from
/// [`boxError`], and distinct from a one-item void result.
pub fn boxEmpty(alloc: Allocator) !*AMresult {
    return (AMresult.init(alloc)).toOwned(alloc);
}

/// `AMresult::error(message)`. Rust: `src/result.rs:17-19`.
pub fn boxError(alloc: Allocator, message: []const u8) !*AMresult {
    return try (try AMresult.initError(alloc, message)).toOwned(alloc);
}

/// `AMresult::item(item)`. Rust: `src/result.rs:21-23`.
pub fn boxItem(alloc: Allocator, item: Item) !*AMresult {
    return try (try AMresult.initItem(alloc, try AMitem.create(alloc, item))).toOwned(alloc);
}

/// One item, one value. The shape of `to_result(Ok(value))` for every
/// non-list return type in the reference.
pub fn boxOne(alloc: Allocator, value: Value) !*AMresult {
    return try boxItem(alloc, .{ .value = value });
}

/// `to_result(Ok(()))`, which the reference renders as one
/// `AMitem::default()` — and that is `Rc::new(Item { index: None, obj_id: None,
/// value: None })` (`src/item.rs:1050-1058`), i.e. **one item whose value type
/// is `VOID`**. That is the `AM_VAL_TYPE_VOID` item every `\brief` in
/// `src/doc.rs` promises, and it is why a void result has size `1`, not `0`.
pub fn boxVoid(alloc: Allocator) !*AMresult {
    return try boxItem(alloc, .{});
}

/// A list of values as a list of items. The shape of
/// `impl From<Result<Vec<T>, _>> for AMresult` for every `T` in the reference.
pub fn boxValues(alloc: Allocator, values: []const Value) !*AMresult {
    var list: std.ArrayList(AMitem) = .empty;
    errdefer {
        for (list.items) |owned| owned.deinit(alloc);
        list.deinit(alloc);
    }
    for (values) |v| try list.append(alloc, try AMitem.create(alloc, .{ .value = v }));
    return (AMresult.initItems(alloc, list)).toOwned(alloc);
}

// ---------------------------------------------------------------------------
// Conversions between the C handles and the port's own types.
// ---------------------------------------------------------------------------

/// The document's op set as a **mutable** pointer, for a walk that borrows it.
///
/// [read.zig](../read.zig) performs exactly this cast, and says why: "The
/// `const` is dropped and nothing writes through it. A walk over an op set
/// moves that op set's shared successor buffer" (`read.zig:352-360`,
/// `op_set.zig:40-49`), and so `topOps` and every `iter*` walk take `*Set`. It
/// is the reason this file can answer a `heads` argument at all, since
/// `read.zig` itself passes `null` for the clock it has no parameter for.
fn mutableOps(d: *const AMdoc) *docmod.Set {
    return @constCast(&d.doc.ops);
}

// ---------------------------------------------------------------------------
// The write surface, through the handle's own open transaction.
//
// Each of these is the module function of the same name in
// [transact.zig](../transact.zig) with the `tx.commit(null, null)` at the end
// of it **removed**, because `AMdoc` is `am::AutoCommit` (`src/doc.rs:36`) and
// an `AutoCommit` holds its transaction open across calls
// ([`autocommit.rs:445-457`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)).
// They are thin on purpose: the operation is [`transact.Transaction`]'s and
// there is one implementation of it. **What makes the change is one call —
// [`AMdoc.open`] — and that it is not followed by a commit.**
// ---------------------------------------------------------------------------

fn txPut(d: *AMdoc, obj: ExId, prop: Prop, value: ScalarValue) !OpId {
    const made = try (try d.open()).put(obj, prop, value);
    return made orelse OpId.root;
}

fn txPutObject(d: *AMdoc, obj: ExId, prop: Prop, t: ObjType) !ExId {
    return (try d.open()).putObject(obj, prop, t);
}

fn txInsert(d: *AMdoc, obj: ExId, index: usize, value: ScalarValue) !OpId {
    return (try d.open()).insert(obj, index, value);
}

fn txInsertObject(d: *AMdoc, obj: ExId, index: usize, t: ObjType) !ExId {
    return (try d.open()).insertObject(obj, index, t);
}

fn txIncrement(d: *AMdoc, obj: ExId, prop: Prop, by: i64) !void {
    return (try d.open()).increment(obj, prop, by);
}

fn txDelete(d: *AMdoc, obj: ExId, prop: Prop) !usize {
    return (try d.open()).delete(obj, prop);
}

fn txSpliceText(d: *AMdoc, obj: ExId, pos: usize, del: isize, text: []const u8) !void {
    return (try d.open()).spliceText(obj, pos, del, text);
}

fn txSplice(
    d: *AMdoc,
    obj: ExId,
    pos: usize,
    del: isize,
    gpa: Allocator,
    values: []const hydmod.Value,
) !void {
    return transact.spliceHeld(try d.open(), obj, pos, del, gpa, values);
}

fn txMark(
    d: *AMdoc,
    obj: ExId,
    from: usize,
    to: usize,
    name: []const u8,
    expand: marksmod.ExpandMark,
    value: ?ScalarValue,
) !void {
    return (try d.open()).mark(obj, from, to, name, expand, value);
}

fn txUnmark(
    d: *AMdoc,
    obj: ExId,
    from: usize,
    to: usize,
    expand: marksmod.ExpandMark,
    name: []const u8,
    value: ?ScalarValue,
) !void {
    return (try d.open()).unmark(obj, from, to, expand, name, value);
}

/// `to_obj_id!` (Rust: `src/obj.rs:11-17`): **a null handle is the root**, not
/// an error, and that is the only way a C caller reaches `AM_ROOT`.
///
/// **The actor's bytes go into the id and the id is then resolved.** Upstream's
/// `am::ObjId` is `Id(counter, actor_id, index)` (`src/obj.rs:31-38`) — it names
/// the actor by bytes — and upstream's own read path repairs that name through
/// `exid_to_opid` ([`automerge.rs:744-758`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// before using it, precisely because the actor table is sorted and interning
/// a concurrency actor renumbers every index at or above its slot. This port's
/// [`ExId.named`] carries those bytes, and [`Document.resolve`] is that same
/// repair.
///
/// A previous revision built a bare `fromParts` id here, which has **no actor
/// bytes to repair with** and is therefore exactly the id `isolate` invalidates.
/// `lookupActor` is still needed, to turn the counter into an `OpId`; it is not
/// the end of the story, it is the start.
fn objIdOf(doc: *const AMdoc, handle: ?*const AMobjId) !ExId {
    const h = handle orelse return .root;
    if (h.root) return .root;
    const cell = h.c_actor_id orelse return error.InvalidObjId;
    const idx = doc.doc.ops.lookupActor(cell.body.*) orelse return error.InvalidObjId;
    const actor_idx = std.math.cast(types.ActorIdx, idx) orelse return error.InvalidObjId;
    if (h.counter > std.math.maxInt(u32)) return error.InvalidObjId;
    const named = ExId.withActor(OpId.init(@intCast(h.counter), actor_idx), cell.body.*);
    return doc.doc.resolve(named) orelse error.InvalidObjId;
}

/// The reverse: an [`AMobjId`] for an [`ExId`]. Every C function that takes an
/// `AMobjId` also has the `AMdoc` that owns the actor table, so the actor bytes
/// are resolvable and **copied** — the handle outlives the document.
fn objIdOfEx(alloc: Allocator, doc: *const AMdoc, exid: ExId) !AMobjId {
    switch (exid) {
        .root => return AMobjId.rootObj(alloc),
        .id => |i| return AMobjId.of(
            alloc,
            i.counter,
            // Upstream's third `ObjId::Id` component is `id.actor()` — the
            // actor's index in the document's table
            // (`op_set.rs:1054-1060`) — and the port's `ExId.Id`
            // (`types.zig:273-274`) carries it as `actor`, so it is already
            // the right number and needs no lookup.
            @as(usize, i.actor),
            (doc.doc.getActor(i.actor) orelse ActorId.init(&.{})).bytes,
        ),
        .named => |n| return AMobjId.of(
            alloc,
            n.op.counter,
            // The same component, from the same `id.actor()` upstream builds
            // it from (`op_set.rs:1054-1060`); `ExId.Named` keeps the actor's
            // bytes because the actor table it was minted from may be gone by
            // the time a C caller reads the handle.
            @as(usize, n.op.actor),
            n.actor.bytes,
        ),
    }
}

/// An owned `types.ActorId` cell for a handle to borrow.
fn newActorCell(alloc: Allocator, bytes: []const u8) !*ActorId {
    const owned = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned);
    const cell = try alloc.create(ActorId);
    errdefer alloc.destroy(cell);
    cell.* = .{ .bytes = owned };
    return cell;
}

/// An owned [`AMactorId`] cell over a copy of `bytes`, for a handle to borrow.
///
/// **`AMactorId` and `ActorId` are not layout-compatible.** The first is
/// `{ body: *const ActorId, gpa: Allocator, hex: ?[]u8 }` and the second is
/// `{ bytes: []const u8 }`, so a bare `@ptrCast` from one to the other yields
/// a handle whose `body` is the actor's *slice* and whose `gpa` is whatever
/// followed it in memory. Two allocations, and the wrapper is built here.
///
/// **The caller owns all three allocations** — the copied bytes, the
/// [`ActorId`] cell they were copied into, and this handle — and frees them
/// with [`destroyActorHandle`], which is the only function that does.
/// [`AMactorId.deinit`] is not it and leaves all three behind.
fn newActorHandle(alloc: Allocator, bytes: []const u8) !*AMactorId {
    const cell = try newActorCell(alloc, bytes);
    errdefer alloc.destroy(cell);
    const handle = try alloc.create(AMactorId);
    handle.* = .{ .body = cell, .gpa = alloc };
    return handle;
}

/// Frees a handle [`newActorHandle`] handed out, with the body it borrows.
///
/// **The handle does not own its body, and this is the whole owner side of
/// that.** Upstream's `AMactorId` is `body: *const am::ActorId`
/// ([`src/actor_id.rs:26-29`](../../github-automerge-automerge/rust/automerge-c/src/actor_id.rs))
/// — a **borrow**, which Rust frees at the end of the borrow's scope and Zig
/// cannot, and the only thing upstream's own struct drops is the
/// `hex_str: RefCell<Option<Box<str>>>` beside it. So [`AMactorId.deinit`] is
/// that half and is **not** the destructor of a handle from
/// [`newActorHandle`]: a call to it frees the hex cache and leaves the copied
/// bytes, the [`ActorId`] cell they were copied into, and the handle cell
/// itself — three allocations, each a leak under
/// `std.testing.allocator`.
///
/// **This function is the only spelling of that free, and it takes the
/// handle's own allocator** rather than the caller's, because the handle
/// records the one that made all three and nothing else can free them.
/// [`AMobjId.deinit`] routes here rather than repeating the four lines, which
/// is what a third caller would otherwise copy.
fn destroyActorHandle(handle: *AMactorId) void {
    // **Both fields are read out before `deinit` runs, and that order is the
    // whole function.** `AMactorId.deinit` writes `undefined` over the cell,
    // so `body` or `gpa` read after it is whatever the allocator left there,
    // and freeing that is a free of a wild pointer.
    const body = handle.body;
    const gpa = handle.gpa;
    handle.deinit();
    gpa.free(body.bytes);
    gpa.destroy(body);
    gpa.destroy(handle);
}

/// An `AM_VAL_TYPE_ACTOR_ID` item whose bytes are its own. Upstream's
/// `impl From<am::ActorId> for Value` (Rust: `src/item.rs:141-145`) moves an
/// owned `ActorId` in, and `AMgetActorId` passes `doc.get_actor().clone()`
/// (`src/doc.rs:302-304`), so the item owns a copy of the document's bytes.
fn actorValue(alloc: Allocator, actor: ActorId) !Value {
    const cell = try newActorCell(alloc, actor.bytes);
    return .{ .actor_id = .{ .body = cell, .gpa = alloc } };
}

/// `Vec::<am::ChangeHash>::try_from(heads)` (Rust: `src/items.rs:214-231`).
///
/// **The slice is the caller's** and every hash is copied out of the items, so
/// the caller's result may be freed as soon as this returns. An item that is
/// not a change hash is `error.InvalidValueType`, which is the reference's own
/// `AutomergeError::InvalidValueType` (`src/item.rs:216-236`).
fn headsOf(alloc: Allocator, items: ?*const AMitems) ![]ChangeHash {
    if (items == null) return alloc.alloc(ChangeHash, 0);
    const seq = items.?.*;
    var out: std.ArrayList(ChangeHash) = .empty;
    errdefer out.deinit(alloc);
    for (seq.slice()) |item| {
        const v = item.get().value orelse return error.InvalidValueType;
        switch (v) {
            .change_hash => |h| try out.append(alloc, h),
            else => return error.InvalidValueType,
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The clock `heads` selects, or null when `heads` is null.
///
/// **A non-null but empty `AMitems` is an empty clock, not the current state.**
/// Upstream's `heads.as_ref()` is `Some` for any non-null pointer
/// (`src/doc.rs:466-470`) and `Clock::from_heads(&[])` is a clock that covers
/// nothing, so `AMlistGet(doc, obj, pos, &empty)` answers nothing. Collapsing
/// the two would make an empty `heads` mean "now", which is the opposite.
fn clockFromItems(alloc: Allocator, doc: *const AMdoc, items: ?*const AMitems) !?Clock {
    if (items == null) return null;
    const hashes = try headsOf(alloc, items);
    defer alloc.free(hashes);
    return try @constCast(doc).doc.graph.clockAt(alloc, hashes);
}

/// `clamp!` (Rust: `src/doc/utils.rs:1-9`): a position past the object's end
/// is an error **unless** it is `SIZE_MAX`, which upstream spells "one past the
/// end" in the `\pre` of `AMsplice` (`src/doc.rs:894-895`).
fn clampPos(pos: usize, len: usize) !usize {
    if (pos > len and pos != std.math.maxInt(usize)) {
        return error.InvalidIndex;
    }
    return @min(pos, len);
}

/// `adjust!` (Rust: `src/doc/list.rs:11-21`), with the two rules the macro
/// spells out: an empty object can only be inserted into, so `insert` is forced
/// on, and a non-insert position's stop is `len - 1` rather than `len`.
fn adjustPos(pos: usize, insert: bool, len: usize) !struct { pos: usize, insert: bool } {
    const ins = insert or len == 0;
    const stop = if (ins) len else len - 1;
    if (pos > stop and pos != std.math.maxInt(usize)) return error.InvalidIndex;
    return .{ .pos = @min(pos, stop), .insert = ins };
}

/// `to_range!` (Rust: `src/doc/list.rs:23-30`): `begin > end` is
/// `format!("Invalid range [{}-{})", …)`.
fn toRange(begin: usize, end: usize) !struct { start: usize, end: usize } {
    if (begin > end) return error.InvalidRange;
    return .{ .start = begin, .end = end };
}

/// `to_obj_type!` (Rust: `src/obj.rs:20-31`): `AM_OBJ_TYPE_DEFAULT` is not a
/// type, so it is `AutomergeError::InvalidValueType` (`src/obj.rs:26-32`).
fn toObjType(tag: AMobjType) !ObjType {
    return switch (tag) {
        .AM_OBJ_TYPE_LIST => .list,
        .AM_OBJ_TYPE_MAP => .map,
        .AM_OBJ_TYPE_TEXT => .text,
        .AM_OBJ_TYPE_DEFAULT => error.InvalidValueType,
    };
}

/// `impl From<&am::ObjType> for AMobjType` (Rust: `src/obj.rs:112-126`): the
/// port has a fourth variant, `table`, which upstream also has and maps to
/// `AM_OBJ_TYPE_MAP` (`obj.rs:118`).
fn fromObjType(t: ObjType) AMobjType {
    return switch (t) {
        .list => .AM_OBJ_TYPE_LIST,
        .map, .table => .AM_OBJ_TYPE_MAP,
        .text => .AM_OBJ_TYPE_TEXT,
    };
}

/// `to_expand_mark!` (Rust: `src/doc/mark.rs:22-30`): `AM_MARK_EXPAND_DEFAULT`
/// is not an expansion mode, so it is `AutomergeError::InvalidValueType`
/// (`mark.rs:71-74`).
fn toExpandMark(tag: AMmarkExpand) !marksmod.ExpandMark {
    return switch (tag) {
        .AM_MARK_EXPAND_AFTER => .after,
        .AM_MARK_EXPAND_BEFORE => .before,
        .AM_MARK_EXPAND_BOTH => .both,
        .AM_MARK_EXPAND_NONE => .none,
        .AM_MARK_EXPAND_DEFAULT => error.InvalidValueType,
    };
}

/// `to_str!` (`src/byte_span.rs`'s `TryFrom<&AMbyteSpan> for &str`, reached
/// through the macro in every caller). **A null `src` with a non-zero count is
/// the zero span**, which `slice()` gives, and an invalid UTF-8 span is
/// `error.InvalidUtf8` — the same refusal `AMstrCmp` makes
/// (`src/byte_span.rs:148-160`).
fn spanStr(span: AMbyteSpan) ![]const u8 {
    const bytes = span.slice();
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return bytes;
}

/// `Vec::<u8>::from(&value)` (Rust: `src/doc/list.rs:254`,
/// `src/doc/map.rs:216`). A span is a borrow, so the bytes are **copied**:
/// the port's `ScalarValue.bytes` is a `[]const u8` that must outlive the
/// caller's buffer, and the item that receives it is freed later.
fn spanBytes(alloc: Allocator, span: AMbyteSpan) ![]u8 {
    return try alloc.dupe(u8, span.slice());
}

/// `Vec::<am::Change>::try_from(items)` (Rust: `src/items.rs:195-212`): each
/// item must hold a change, and each is **cloned** (upstream
/// `change.clone()` at `:204`).
fn changesOf(alloc: Allocator, items: *const AMitems) ![]changemod.Change {
    var out: std.ArrayList(changemod.Change) = .empty;
    errdefer {
        for (out.items) |*c| c.deinit(alloc);
        out.deinit(alloc);
    }
    for (items.slice()) |item| {
        const v = valueCell(item.get()) orelse return error.InvalidValueType;
        switch (v.*) {
            .change => |*amc| {
                // A borrowed `&am::Change` and a **fresh parse** are the two
                // ways to get an owned one, and upstream takes the first
                // (`:204` `change.clone()`). The port's `Change` is not
                // cloneable, and re-parsing would be a second answer, so this
                // re-encodes the handle's framed bytes into a new `Change`
                // with [`changemod.parseChange`] — the same bytes, the same
                // hash, and no shared ownership. Recorded as a deviation: the
                // reference's clone is a memcpy and this is a re-parse.
                out.append(alloc, try reparseChange(alloc, amc.raw)) catch |e| return e;
            },
            else => return error.InvalidValueType,
        }
    }
    return out.toOwnedSlice(alloc);
}

/// A fresh [`changemod.Change`] over `raw`, which is a framed change chunk.
fn reparseChange(alloc: Allocator, raw: []const u8) !changemod.Change {
    const framed = try chunkmod.parseChunk(raw);
    var owned = try changechunk.parseFramedChunk(framed, alloc);
    defer owned.deinit(alloc);
    const body = switch (framed.typ) {
        .change => framed.data,
        .compressed => owned.inflated orelse return error.InvalidChunkType,
        .document, .bundle => return error.InvalidChunkType,
    };
    // **`withOpCount`, not a bare parse.** A re-parse reads the header, which
    // does not carry the op count, so `max_op` comes back `0`
    // (`../change.zig:49-51`, `:380-382`) — and this is what a C caller's
    // `AMapplyChanges` hands `Document.applyChanges`, so every change that
    // enters a document through the C ABI used to arrive with no op range.
    // `owned.parsed` is the chunk decoded from the same body, so its row count
    // is this change's `num_ops` (`storage/change.rs:205-207`); the rows are
    // the only place the count lives. The same rule `AMchangeFromBytes` uses
    // (`:1943-1945`) and the same one `encodeOneChange` had to learn
    // (`../doc.zig:2157-2161`). `withOpCount` takes the change by value and
    // shares `other_actors`, and the return is before `owned`'s `defer` runs.
    var parsed = try changemod.parseChange(body, alloc);
    return parsed.withOpCount(try owned.parsed.opCount());
}

/// An `AMchange` the item owns outright, built from a change a document
/// produced.
///
/// **The handle must own every byte it frees, and `Change` owns exactly one
/// thing.** [`changemod.Change.deinit`](../change.zig:217-225) frees
/// `other_actors` and nothing else, and it says so because a `Change` is only
/// valid while its `bytes` are (`../change.zig:80-90`). A
/// [`docmod.Built`] is the wrong thing to hand it: `Built.body` is the
/// **unframed** body `encodeBody` wrote and `Built.change` **borrows** it
/// ([`../doc.zig:407-425`](../doc.zig), built at [`../doc.zig:2153-2161`](../doc.zig)),
/// and every caller here destroys the `Built` on the very next line
/// (`AMgetChanges`'s `defer changes.deinit`, [`:2762-2764`](doc.zig)).
/// Copying the struct across therefore left every slice in the handle
/// pointing into freed storage and left `other_actors` aliased between the
/// handle and a `Built` that freed it: a use-after-free on the reads and a
/// double free on `AMresultFree`. The crash it produced was a `free()` of an
/// interior pointer, which is how `item_tests.c`'s group teardown died
/// inside `ChangeGraph.deinit` rather than where the mistake is.
///
/// So the body is framed once here and the change is parsed from that copy,
/// exactly as [`AMchangeFromBytes`] does for a change a C caller hands in
/// (`:1794-1820`), and as [`encodeOneChange`] does for one this port builds
/// itself ([`../doc.zig:2153-2161`](../doc.zig)).
/// Framing is what `raw` has to be: [`AMchangeCompress`],
/// [`AMchangeExtraBytes`] and [`changesOf`] all hand it to a chunk parser
/// (`../storage/chunk.zig:131-140`, `:246-251`), and it is what upstream's
/// `Change::bytes()` reports — the same framed chunk `from_bytes` took
/// ([`change.rs:102-120`, `:131-133`](../../github-automerge-automerge/rust/automerge/src/change.rs)).
///
/// `max_op` is carried over rather than left at `parseChange`'s `0`
/// ([`../change.zig:380-382`](../change.zig)):
/// the op count lives in the columns, and a change rebuilt from a document
/// already knows the answer its graph's metadata recorded. Every other field
/// the header wrote round trips through the body, so re-parsing reproduces
/// it, hash included.
fn ownedChangeValue(alloc: Allocator, built: docmod.Built) !Value {
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(alloc);
    try chunkmod.writeChunk(&framed, alloc, .change, built.body);
    const raw = try framed.toOwnedSlice(alloc);
    errdefer alloc.free(raw);
    const body = (try chunkmod.parseChunk(raw)).data;
    const cell = try alloc.create(changemod.Change);
    errdefer alloc.destroy(cell);
    cell.* = try changemod.parseChange(body, alloc);
    cell.max_op = built.change.max_op;
    return .{ .change = .{ .gpa = alloc, .change = cell, .raw = raw } };
}

/// `impl From<&[am::Change]> for AMresult` (Rust: `src/result.rs:389-394`),
/// reached from `AMgetChanges` (`src/change.rs:207`) and
/// `AMchangeLoadDocument` (`src/change.rs:197`). Each change is **owned** by its
/// item: upstream's `change.into()` moves a `Change` into a `Box<am::Change>`
/// (`src/item.rs:153-157`).
fn changesResult(alloc: Allocator, changes: anytype) !*AMresult {
    var values: std.ArrayList(Value) = .empty;
    errdefer {
        for (values.items) |*v| v.deinit(alloc);
        values.deinit(alloc);
    }
    for (changes.slice()) |*built| {
        try values.append(alloc, try ownedChangeValue(alloc, built.*));
    }
    defer values.deinit(alloc);
    return try boxValues(alloc, values.items);
}

/// A single change as a one-item result. `AMgetChangeByHash`
/// (`src/doc.rs:332`) and `AMgetLastLocalChange` (`src/doc.rs:542`).
fn changeResult(alloc: Allocator, built: docmod.Built) !*AMresult {
    return try boxOne(alloc, try ownedChangeValue(alloc, built));
}

/// A whole `AMdoc` as a one-item result. `AMcreate` (`src/doc.rs:131`),
/// `AMclone` (`src/doc.rs:111`) and `AMload` (`src/doc.rs:601`) all go through
/// `impl From<am::AutoCommit> for Value` (`src/item.rs:147-151`), which boxes
/// the document so the item owns it and `AMresultFree` frees it.
fn docResult(alloc: Allocator, doc: AMdoc) !*AMresult {
    return try boxOne(alloc, .{ .doc = doc });
}

/// `read.zig`'s `taggedValue`, **copied**. See the module doc: the port's read
/// surface has no clock parameter, so this is the only way to answer
/// `AMmapGet`/`AMmapGetAll`/`AMlistGet`/`AMlistGetAll` with a `heads` argument.
/// The body is `read.zig:385-412` line for line, over the same public `Op`
/// accessors.
fn taggedValue(op: opmod.Op, set: *const docmod.Set) !DocItem {
    const v: optypes.ValueRef = switch (op.action()) {
        .make_map => .{ .object = .map },
        .make_list => .{ .object = .list },
        .make_text => .{ .object = .text },
        .make_table => .{ .object = .table },
        .set => .{ .scalar = op.value() },
        .mark => if (op.markName() != null)
            .{ .scalar = .{ .str = "markBegin" } }
        else
            .{ .scalar = .{ .str = "markEnd" } },
        .delete, .increment => return error.Invariant,
    };
    return .{ .value = v, .id = set.idToExid(op.id()) };
}

/// `read.zig`'s `winner` (Rust: `read.zig:419-425`): the register's last row.
fn winningRow(found: *const opsetmod.OpsFound) ?opmod.Op {
    const items = found.ops.items;
    if (items.len == 0) return null;
    return items[items.len - 1];
}

/// `read.get`'s dispatch table (`read.zig:452-496`) with a clock, over the
/// same two `seekOps*` calls it makes.
fn getAt(
    doc: *const AMdoc,
    obj: ExId,
    prop: Prop,
    clock: ?Clock,
) !?DocItem {
    const set = mutableOps(doc);
    const typ = try doc.objectType(obj);
    var found = switch (typ) {
        .map, .table => switch (prop) {
            .key => |key| try set.seekOpsByMapKey(c_alloc, obj, key, clock),
            .index => return error.InvalidOp,
        },
        .list, .text => switch (prop) {
            .key => return error.InvalidOp,
            .index => |i| try set.seekOpsByIndex(
                c_alloc,
                obj,
                i,
                typ.asSequenceType() orelse return error.Invariant,
                clock,
            ),
        },
    };
    defer found.deinit(c_alloc);
    const row = winningRow(&found) orelse return null;
    return try taggedValue(row, set);
}

/// `read.getAll`'s body (`read.zig:498-517`) with a clock. Upstream's
/// `get_all_at` returns every value at the property, ascending in op id
/// (`automerge.rs:1921-1925`).
fn getAllAt(
    alloc: Allocator,
    doc: *const AMdoc,
    obj: ExId,
    prop: Prop,
    clock: ?Clock,
) ![]DocItem {
    const set = mutableOps(doc);
    const typ = try doc.objectType(obj);
    var found = switch (typ) {
        .map, .table => switch (prop) {
            .key => |key| try set.seekOpsByMapKey(alloc, obj, key, clock),
            .index => return error.InvalidOp,
        },
        .list, .text => switch (prop) {
            .key => return error.InvalidOp,
            .index => |i| try set.seekOpsByIndex(
                alloc,
                obj,
                i,
                typ.asSequenceType() orelse return error.Invariant,
                clock,
            ),
        },
    };
    defer found.deinit(alloc);
    const ops = found.ops.items;
    const out = try alloc.alloc(DocItem, ops.len);
    errdefer alloc.free(out);
    for (ops, 0..) |op, i| out[i] = try taggedValue(op, set);
    return out;
}

/// A borrowed [`ValueRef`] as an **owned** item value.
///
/// Every document read hands out a [`ValueRef`] whose `str` / `bytes` point
/// into the op set's value column and whose object is an [`ObjType`]. Upstream
/// converts with `impl From<ValueRef<'_>> for Value`
/// (`src/item.rs:201-205`), which is `Cow::Owned` — a copy — because the item
/// may outlive the document. This is the same copy.
fn ownedOfRef(alloc: Allocator, v: optypes.ValueRef) !Value {
    const owned = try v.intoOwned(alloc);
    return .{ .value = owned };
}

/// A borrowed [`ValueRef`] plus its [`ExId`] as one item, which is
/// `AMitem::exact(obj_id, value.into())` (`src/item.rs:1027-1033`, reached
/// from `src/result.rs:382-390`). `obj` is freed if the value cannot be
/// copied.
fn exactItem(alloc: Allocator, obj: ?AMobjId, v: optypes.ValueRef) !Item {
    var own = obj;
    errdefer if (own) |*o| o.deinit();
    return .{ .obj_id = own, .value = try ownedOfRef(alloc, v) };
}

/// `AMitem::indexed(index, obj_id, value.into())` (Rust: `src/item.rs:1035-1048`),
/// which is `Item { index: Some(..), obj_id: Some(..), value: Some(..) }`.
/// The caller has already built `index` and `obj`, and both are freed if the
/// value cannot be copied.
fn indexedItem(
    alloc: Allocator,
    index: AMindex,
    obj: AMobjId,
    v: optypes.ValueRef,
) !Item {
    var own_index = index;
    errdefer own_index.deinit();
    var own = obj;
    errdefer own.deinit();
    return .{ .index = own_index, .obj_id = own, .value = try ownedOfRef(alloc, v) };
}

/// Appends a finished item, and frees it if the list cannot grow. The four
/// `AM*GetAll` / `AM*Range` bodies below each build one item per row and each
/// has the same abandonment to make, so it is made once here.
fn pushItem(alloc: Allocator, items: *std.ArrayList(Item), built: Item) Allocator.Error!void {
    var own = built;
    errdefer own.deinit(alloc);
    try items.append(alloc, own);
}
/// The one exit every `AM*GetAll`, `AM*Range` and `AMobjItems` body needs: a
/// half-built item list, abandoned because the call is going to return an error
/// *result* and so the `errdefer` above it will not fire.
fn dropItems(alloc: Allocator, items: *std.ArrayList(Item)) void {
    for (items.items) |*it| it.deinit(alloc);
    items.deinit(alloc);
}

// ---------------------------------------------------------------------------
// AMactorId. Rust: src/actor_id.rs.
// ---------------------------------------------------------------------------

/// `AMactorIdBytes`. Rust: `src/actor_id.rs:71-76`.
///
/// **A null handle is the zero span**, from the reference's
/// `None => Default::default()` (`:74`), and `Default for AMbyteSpan` is
/// `{src: null, count: 0}` (`src/byte_span.rs:43-50`).
pub export fn AMactorIdBytes(actor_id: ?*const AMactorId) AMbyteSpan {
    const a = actor_id orelse return .empty;
    return AMbyteSpan.of(a.toBytes());
}

/// `AMactorIdCmp`. Rust: `src/actor_id.rs:94-108`.
///
/// **A null handle sorts before a real one and two nulls are equal** (`:102-105`),
/// which is a total order over `Option<&AMactorId>` and not a Rust total order
/// over `ActorId`; it is the reference's answer and it is reproduced exactly.
pub export fn AMactorIdCmp(
    actor_id1: ?*const AMactorId,
    actor_id2: ?*const AMactorId,
) c_int {
    if (actor_id1 == null) return if (actor_id2 == null) 0 else -1;
    if (actor_id2 == null) return 1;
    return switch (ActorId.order(actor_id1.?.body.*, actor_id2.?.body.*)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// `AMactorIdInit`. Rust: `src/actor_id.rs:118-120`.
///
/// Sixteen bytes from `ActorId::random()` (`types.rs:63-68`). The port's
/// `ActorId.random` is a `DefaultPrng` stepped by a process-wide counter, and
/// its own doc says why: an actor id has to be unique within a document and
/// never has to be unguessable (`types.zig:100-116`).
pub export fn AMactorIdInit() ?*AMresult {
    const bytes = ActorId.random(c_alloc) catch |e| return failWith(c_alloc, e);
    defer c_alloc.free(bytes.bytes);
    const value = actorValue(c_alloc, bytes) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, value) catch |e| failWith(c_alloc, e);
}

/// `AMactorIdFromBytes`. Rust: `src/actor_id.rs:140-149`.
///
/// **A null `src` is `AMresult::error("Invalid uint8_t*")`** (`:147`), which
/// is the reference's own message and is reproduced verbatim.
pub export fn AMactorIdFromBytes(src: ?[*]const u8, count: usize) ?*AMresult {
    const s = src orelse return boxErrorNamed(c_alloc, "Invalid uint8_t*");
    const value = actorValue(c_alloc, ActorId.init(s[0..count])) catch |e|
        return failWith(c_alloc, e);
    return boxOne(c_alloc, value) catch |e| failWith(c_alloc, e);
}

/// `AMactorIdFromStr`. Rust: `src/actor_id.rs:164-174`.
///
/// A hexadecimal UTF-8 view. Upstream decodes the span as `&str` first
/// (`:167`, `src/byte_span.rs:148-160`) and then `ActorId::from_str`, whose own
/// failure is re-wrapped as `AutomergeError::InvalidActorId(s)` (`:172-173`).
pub export fn AMactorIdFromStr(value: AMbyteSpan) ?*AMresult {
    const text = spanStr(value) catch |e| return failWith(c_alloc, e);
    const actor = ActorId.fromHex(c_alloc, text) catch |e| return failWith(c_alloc, e);
    defer c_alloc.free(actor.bytes);
    const v = actorValue(c_alloc, actor) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, v) catch |e| failWith(c_alloc, e);
}

/// `Err(e) => AMresult::error(&e.to_string()).into()` (Rust:
/// `src/result.rs:466`), with this port's spelling of the message: a propagated
/// error is a Zig error and `@errorName` is its only stable name. Upstream's
/// `AutomergeError` has no Zig spelling, so this is a recorded deviation. The
/// messages upstream **hard-codes** are not affected: they are spelled out
/// verbatim by [`boxErrorNamed`], because a C caller can match on them and the
/// reference's own cmocka suite does.
fn failWith(alloc: Allocator, e: anyerror) ?*AMresult {
    return boxError(alloc, @errorName(e)) catch null;
}

/// `AMresult::error(message)` with a message the reference writes out by hand:
/// `AMresult::error("Invalid `AMdoc*").into()` and the rest. Reproduced byte
/// for byte, because these are the only error strings a C caller can match on.
fn boxErrorNamed(alloc: Allocator, message: []const u8) ?*AMresult {
    return boxError(alloc, message) catch null;
}

/// `AMactorIdStr`. Rust: `src/actor_id.rs:188-193`.
///
/// **A null handle is the zero span** (`:191`). The returned span borrows a
/// hex string cached inside the handle, which is what the reference's
/// `hex_str: RefCell<Option<Box<str>>>` (`src/actor_id.rs:19`) is for; see
/// [`AMactorId.toStr`].
pub export fn AMactorIdStr(actor_id: ?*const AMactorId) AMbyteSpan {
    const a = actor_id orelse return .empty;
    return AMbyteSpan.of(a.toStr());
}

// ---------------------------------------------------------------------------
// AMchange. Rust: src/change.rs.
// ---------------------------------------------------------------------------

/// `to_change!` (Rust: `src/change.rs:8-15`), used by the one entry point that
/// dereferences the handle, `AMchangeActorId` (`:104`).
fn invalidChange(alloc: Allocator) ?*AMresult {
    return boxError(alloc, "Invalid `AMchange*`") catch null;
}

/// `AMchangeActorId`. Rust: `src/change.rs:81-86`.
///
/// One `AM_VAL_TYPE_ACTOR_ID` item, from
/// `change.as_ref().actor_id().clone()` (`src/change.rs:107-110`).
pub export fn AMchangeActorId(change: ?*const AMchange) ?*AMresult {
    const c = change orelse return invalidChange(c_alloc);
    const v = actorValue(c_alloc, c.change.actor) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, v) catch |e| failWith(c_alloc, e);
}

/// `AMchangeCompress`. Rust: `src/change.rs:98-102`.
///
/// Returns `void`, so nothing can be forgotten. A null handle is a no-op, which
/// is the reference's `if let Some(change) = change.as_mut()` (`:99`).
pub export fn AMchangeCompress(change: ?*AMchange) void {
    const c = change orelse return;
    c.compress();
}

/// `AMchangeDeps`. Rust: `src/change.rs:117-122`.
///
/// A null handle is an **empty** items result: the reference's
/// `None => Default::default()` (`:121-122`) over `&[ChangeHash]`.
pub export fn AMchangeDeps(change: ?*const AMchange) ?*AMresult {
    const c = change orelse return boxEmpty(c_alloc) catch null;
    return boxHashes(c_alloc, c.change.deps) catch |e| failWith(c_alloc, e);
}

/// `AMchangeExtraBytes`. Rust: `src/change.rs:135-141`.
///
/// **A null handle is the zero span** (`:139`). The port's `Change` keeps the
/// author footer inside `bytes` with no accessor (`change.zig:230-234`), so this
/// reads it out of the change chunk through
/// [`ChangeChunk.footer`](../storage/change_chunk.zig), which is "whatever is
/// left" after the op columns — upstream's own rule (`storage/change.rs:120-125`).
pub export fn AMchangeExtraBytes(change: ?*const AMchange) AMbyteSpan {
    const c = change orelse return .empty;
    return AMbyteSpan.of(c.extraBytes());
}

/// `AMchangeFromBytes`. Rust: `src/change.rs:160-163`.
///
/// The input is a **framed** change chunk, which is what `am::Change::from_bytes`
/// takes (`storage/change.rs`). A chunk type that is neither `change` nor
/// `compressed` is `error.InvalidChunkType` (`chunk.rs:134-146`), which is the
/// port's own name for the same refusal.
pub export fn AMchangeFromBytes(src: ?[*]const u8, count: usize) ?*AMresult {
    const s = src orelse return boxErrorNamed(c_alloc, "Invalid uint8_t*");
    const framed = chunkmod.parseChunk(s[0..count]) catch |e| return failWith(c_alloc, e);
    var owned = changechunk.parseFramedChunk(framed, c_alloc) catch |e|
        return failWith(c_alloc, e);
    defer owned.deinit(c_alloc);
    const body = switch (framed.typ) {
        .change => framed.data,
        .compressed => owned.inflated orelse return failWith(c_alloc, error.InvalidChunkType),
        .document, .bundle => return failWith(c_alloc, error.InvalidChunkType),
    };
    const n_ops = owned.parsed.opCount() catch |e| return failWith(c_alloc, e);
    var parsed = changemod.parseChange(body, c_alloc) catch |e| return failWith(c_alloc, e);
    // **`withOpCount`, not a hand-rolled `max_op`.** A parse leaves `max_op`
    // at zero (`change.zig:49-51`, `:380-382`) because the op count lives in
    // the columns, and `n_ops` is the row count those columns hold
    // (`storage/change.rs:205-207`, `change.rs:34-35`) — the same number
    // upstream's `verify_ops` counts before `Change::max_op()` reads it
    // (`change.rs:74-76`). The call also carries the `start_op` overflow check
    // the arithmetic here had no equivalent of (`change.zig:162-170`), so its
    // own failure has to free the parse it is filling in.
    parsed = parsed.withOpCount(n_ops) catch |e| {
        parsed.deinit(c_alloc);
        return failWith(c_alloc, e);
    };
    const raw = c_alloc.dupe(u8, s[0..count]) catch |e| {
        parsed.deinit(c_alloc);
        return failWith(c_alloc, e);
    };
    const cell = c_alloc.create(changemod.Change) catch |e| {
        c_alloc.free(raw);
        parsed.deinit(c_alloc);
        return failWith(c_alloc, e);
    };
    cell.* = parsed;
    return boxOne(c_alloc, .{ .change = .{ .gpa = c_alloc, .change = cell, .raw = raw } }) catch |e|
        failWith(c_alloc, e);
}

/// `AMchangeHash`. Rust: `src/change.rs:176-181`.
///
/// **A null handle is the zero span** (`:180`). The span borrows the change's
/// own `hash` field (`change.zig:110-111`), which is the reference's
/// `change_hash: RefCell<Option<am::ChangeHash>>` (`src/change.rs:23`) without a
/// cache.
pub export fn AMchangeHash(change: ?*const AMchange) AMbyteSpan {
    const c = change orelse return .empty;
    return AMbyteSpan.of(c.hashBytes());
}

/// `AMchangeIsEmpty`. Rust: `src/change.rs:194-200`.
///
/// **A null handle is `true`** (`:198`), which is the reference's answer and not
/// a default: there is nothing there, and "nothing there" is empty.
pub export fn AMchangeIsEmpty(change: ?*const AMchange) bool {
    const c = change orelse return true;
    return c.size() == 0;
}

/// `AMchangeLoadDocument`. Rust: `src/change.rs:219-224`.
///
/// Loads a document and returns **every change in it**, in dependency order:
/// `am::Automerge::load(data).map(|d| d.get_changes(&[]).into_iter().collect())`
/// (`src/change.rs:222-223`).
///
/// The document is built in [`cTextEncoding`]: `am::Automerge::load` is
/// `load_with_options(data, Default::default())`
/// ([`automerge.rs:834-836`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// and `LoadOptions::default()` is `text_encoding: TextEncoding::platform_default()`
/// (`:181`). This document is dropped before the result is built, so no index
/// in it ever reaches C — it is built this way because the encoding is a
/// property of *how a document is built* and the three entry points that
/// build one have to agree.
pub export fn AMchangeLoadDocument(src: ?[*]const u8, count: usize) ?*AMresult {
    const s = src orelse return boxErrorNamed(c_alloc, "Invalid uint8_t*");
    var doc = docmod.Document.load(
        c_alloc,
        s[0..count],
        cTextEncoding(),
        .auto,
    ) catch |e| return failWith(c_alloc, e);
    defer doc.deinit();
    var changes = doc.getChanges(c_alloc, &.{}) catch |e| return failWith(c_alloc, e);
    defer changes.deinit(c_alloc);
    return changesResult(c_alloc, changes) catch |e| failWith(c_alloc, e);
}

/// `AMchangeMaxOp`. Rust: `src/change.rs:237-243`.
///
/// **A null handle is `UINT64_MAX`** (`:241`).
pub export fn AMchangeMaxOp(change: ?*const AMchange) u64 {
    const c = change orelse return std.math.maxInt(u64);
    return c.change.max_op;
}

/// `AMchangeMessage`. Rust: `src/change.rs:257-262`.
///
/// **A null handle is the zero span** (`:261`), and the header's `\post` says so.
/// A change with no message and one with an empty message are the same, because
/// the port's `Change.message` is an empty slice for both
/// (`change.zig:117-120`).
pub export fn AMchangeMessage(change: ?*const AMchange) AMbyteSpan {
    const c = change orelse return .empty;
    return AMbyteSpan.of(c.messageBytes());
}

/// `AMchangeSeq`. Rust: `src/change.rs:275-281`.
///
/// **A null handle is `UINT64_MAX`** (`:279`).
pub export fn AMchangeSeq(change: ?*const AMchange) u64 {
    const c = change orelse return std.math.maxInt(u64);
    return c.change.seq;
}

/// `AMchangeSize`. Rust: `src/change.rs:294-299`.
///
/// The count of operations, which is `0` for a null handle (`:298`).
pub export fn AMchangeSize(change: ?*const AMchange) usize {
    const c = change orelse return 0;
    return c.size();
}

/// `AMchangeStartOp`. Rust: `src/change.rs:312-318`.
///
/// **A null handle is `UINT64_MAX`** (`:316`).
pub export fn AMchangeStartOp(change: ?*const AMchange) u64 {
    const c = change orelse return std.math.maxInt(u64);
    return c.change.start_op;
}

/// `AMchangeTime`. Rust: `src/change.rs:331-337`.
///
/// **A null handle is `INT64_MAX`** (`:335`).
pub export fn AMchangeTime(change: ?*const AMchange) i64 {
    const c = change orelse return std.math.maxInt(i64);
    return c.change.time;
}

/// `AMchangeRawBytes`. Rust: `src/change.rs:350-356`.
///
/// The change's **framed** bytes. After [`AMchangeCompress`] they are the
/// deflated form, which is the reference's observable effect
/// (`src/change.rs:98-103`).
pub export fn AMchangeRawBytes(change: ?*const AMchange) AMbyteSpan {
    const c = change orelse return .empty;
    return AMbyteSpan.of(c.rawBytes());
}

// ---------------------------------------------------------------------------
// AMcursor. Rust: src/cursor.rs.
// ---------------------------------------------------------------------------

/// `to_cursor!` (Rust: `src/cursor.rs:8-14`), used by `AMcursorFromStr` at `:147`.
fn invalidCursor(alloc: Allocator) ?*AMresult {
    return boxError(alloc, "Invalid `AMcursor*`") catch null;
}

/// `AMcursorBytes`. Rust: `src/cursor.rs:79-84`.
///
/// **A null handle is the zero span** (`:82`). The span borrows the serialised
/// bytes cached inside the handle, which is the reference's
/// `bytes: RefCell<Option<Vec<u8>>>` (`src/cursor.rs:28`).
pub export fn AMcursorBytes(cursor: ?*const AMcursor) AMbyteSpan {
    const cur = cursor orelse return .empty;
    return AMbyteSpan.of(cur.toBytes());
}

/// `AMcursorEqual`. Rust: `src/cursor.rs:101-106`.
///
/// **Two null handles are not equal**: the reference's arm at `:104` is
/// `(None, None) | (None, Some(_)) | (Some(_), None) => false`, and its `\post`
/// says so (`src/cursor.rs:97`).
pub export fn AMcursorEqual(cursor1: ?*const AMcursor, cursor2: ?*const AMcursor) bool {
    const a = cursor1 orelse return false;
    const b = cursor2 orelse return false;
    return a.body.eql(b.body);
}

/// `AMcursorFromBytes`. Rust: `src/cursor.rs:126-133`.
///
/// **A null `src` is `AMresult::error("Invalid uint8_t*")`** (`:131`).
pub export fn AMcursorFromBytes(src: ?[*]const u8, count: usize) ?*AMresult {
    const s = src orelse return boxErrorNamed(c_alloc, "Invalid uint8_t*");
    const cur = cursormod.fromBytes(s[0..count]) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .cursor = .{ .body = cur, .gpa = c_alloc } }) catch |e|
        failWith(c_alloc, e);
}

/// `AMcursorFromStr`. Rust: `src/cursor.rs:148-150`.
pub export fn AMcursorFromStr(value: AMbyteSpan) ?*AMresult {
    const text = spanStr(value) catch |e| return failWith(c_alloc, e);
    const cur = cursormod.fromStr(c_alloc, text) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .cursor = .{ .body = cur, .gpa = c_alloc } }) catch |e|
        failWith(c_alloc, e);
}

/// `AMcursorStr`. Rust: `src/cursor.rs:163-168`.
///
/// **A null handle is the zero span** (`:166`).
pub export fn AMcursorStr(cursor: ?*const AMcursor) AMbyteSpan {
    const cur = cursor orelse return .empty;
    return AMbyteSpan.of(cur.toStr());
}

// ---------------------------------------------------------------------------
// AMobjId. Rust: src/obj.rs.
// ---------------------------------------------------------------------------

/// `AMobjIdActorId`. Rust: `src/obj.rs:89-94`.
///
/// **A null handle and the root are both `NULL`** (`:92-93` and `:35-47`). The
/// returned handle is owned by the `AMobjId` it was asked about and dies with
/// the result the item came from; there is no `AMobjIdFree`.
pub export fn AMobjIdActorId(obj_id: ?*const AMobjId) ?*const AMactorId {
    const o = obj_id orelse return null;
    const cell: *AMobjId = @constCast(o);
    return cell.actorHandle();
}

/// `AMobjIdCounter`. Rust: `src/obj.rs:107-116`.
///
/// **A null handle is `UINT64_MAX`** (`:114`) and the **root is `0`** (`:110-111`).
pub export fn AMobjIdCounter(obj_id: ?*const AMobjId) u64 {
    const o = obj_id orelse return std.math.maxInt(u64);
    return o.counter;
}

/// `AMobjIdEqual`. Rust: `src/obj.rs:133-138`.
///
/// **Two null handles are not equal** (`:136`).
pub export fn AMobjIdEqual(obj_id1: ?*const AMobjId, obj_id2: ?*const AMobjId) bool {
    const a = obj_id1 orelse return false;
    const b = obj_id2 orelse return false;
    return a.eql(b.*);
}

/// `AMobjIdIndex`. Rust: `src/obj.rs:151-162`.
///
/// **A null handle is `SIZE_MAX`** (`:160`) and the **root is `0`** (`:157`),
/// which is the same shape [`AMobjId.rootObj`] already carries.
///
/// **The index is the object's actor's index in the document's actor table,
/// and that is the only reading `OpSet::id_to_exid` supports**
/// ([`op_set.rs:1054-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)):
/// `ExId::Id(id.counter(), self.actors[id.actor()].clone(), id.actor())` — the
/// third component is `id.actor()`, the same index that selects the actor from
/// the table, and it is duplicated into the `ObjId` for callers that want it
/// without the actor bytes. An earlier revision of this file read it as "the
/// creating operation's index in its actor's sequence" and returned a
/// constant `0`, which is why every document with more than one actor
/// reported `0` here: a merge of two single-actor documents puts the winning
/// op's actor at table index `1`.
pub export fn AMobjIdIndex(obj_id: ?*const AMobjId) usize {
    const o = obj_id orelse return std.math.maxInt(usize);
    return o.index;
}

// ---------------------------------------------------------------------------
// AMitem. Rust: src/item.rs.
// ---------------------------------------------------------------------------

/// The item's scalar, or null when it holds no scalar: the pair of
/// `try_into_*` methods on `Value` (`src/item.rs:48-139`) that open with
/// `if let Self::Value(Scalar(scalar)) = &self`, so every non-scalar variant
/// and every object value falls through to `InvalidValueType`.
fn scalarOf(item: *const Item) ?ScalarValue {
    const v = item.value orelse return null;
    return switch (v) {
        .value => |ov| switch (ov.value) {
            .scalar => |s| s,
            .object => null,
        },
        else => null,
    };
}

/// The item's own value cell, by pointer, or null when the item has none.
///
/// **This returns a pointer and not the value, and that is the entire reason
/// it exists.** Zig accepts `switch (v) { .doc => |*d| … }` on a `const`
/// local `v`, binds `d` to *that local*, and says nothing: no compile error, no
/// warning, no lint. A C handle taken that way is a pointer into the callee's
/// dead stack frame — an address that is not a plausible heap address, so it
/// does not fail where it is taken. Every `AMitemTo*` that hands a handle out
/// of an item, and [`ownedOf`], go through here instead of copying the union.
fn valueCell(item: *const Item) ?*const Value {
    if (item.value) |*v| return v;
    return null;
}

/// The same cell, mutably, for the three `AMitemTo*` that reach `&mut` through
/// `Rc::get_mut`. Rust: `src/item.rs:1186-1190` (`AMitemToChange`),
/// `:1206-1210` (`AMitemToDoc`), `:1242-1246` (`AMitemToSyncState`).
fn valueCellMut(item: *Item) ?*Value {
    if (item.value) |*v| return v;
    return null;
}

/// The item's owned value cell, or null when it holds no scalar. `AMsplice`'s
/// only reader: `Vec::<am::ScalarValue>::try_from` refuses every other variant
/// (`src/items.rs:236-247`), and the same refusal is the answer here.
fn ownedOf(item: *const Item) ?*const optypes.OwnedValueRef {
    const v = valueCell(item) orelse return null;
    return switch (v.*) {
        .value => |*ov| if (ov.value == .scalar) ov else null,
        else => null,
    };
}

/// `AMitemEqual`. Rust: `src/item.rs:1415-1420`.
///
/// **Two null handles are not equal** (`:1418`).
pub export fn AMitemEqual(item1: ?*const AMitem, item2: ?*const AMitem) bool {
    const a = item1 orelse return false;
    const b = item2 orelse return false;
    return a.eql(b.*);
}

/// `AMitemFromBool`. Rust: `src/item.rs:1430-1432`.
pub export fn AMitemFromBool(value: bool) ?*AMresult {
    return boxOne(c_alloc, .{ .value = ownedScalar(.{ .bool_value = value }) }) catch |e|
        failWith(c_alloc, e);
}

/// `AMitemFromBytes`. Rust: `src/item.rs:1451-1454`.
///
/// Upstream's `std::slice::from_raw_parts(src, count)` has no null check
/// (`:1452`); a null `src` here is an empty byte string, which is the reading
/// that is not undefined behaviour.
pub export fn AMitemFromBytes(src: ?[*]const u8, count: usize) ?*AMresult {
    const s = if (src) |p| p[0..count] else &.{};
    const owned = c_alloc.dupe(u8, s) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .value = ownedScalar(.{ .bytes = owned }) }) catch |e|
        failWith(c_alloc, e);
}

/// `AMitemFromChangeHash`. Rust: `src/item.rs:1470-1472`.
///
/// `am::ChangeHash::try_from(&AMbyteSpan)` is exactly `HASH_SIZE` bytes or an
/// error (`types.rs:520-528`), which is `AM_CHANGE_HASH_SIZE` in the header.
pub export fn AMitemFromChangeHash(value: AMbyteSpan) ?*AMresult {
    const bytes = value.slice();
    if (bytes.len != types.hash_size) return failWith(c_alloc, error.InvalidChangeHashBytes);
    var h: ChangeHash = .zero;
    @memcpy(&h.bytes, bytes);
    return boxOne(c_alloc, .{ .change_hash = h }) catch |e| failWith(c_alloc, e);
}

/// `AMitemFromCounter`. Rust: `src/item.rs:1482-1484`.
pub export fn AMitemFromCounter(value: i64) ?*AMresult {
    return boxOne(c_alloc, .{ .value = ownedScalar(.{ .counter = .{ .current = value } }) }) catch |e|
        failWith(c_alloc, e);
}

/// `AMitemFromF64`. Rust: `src/item.rs:1494-1496`.
pub export fn AMitemFromF64(value: f64) ?*AMresult {
    return boxOne(c_alloc, .{ .value = ownedScalar(.{ .float = value }) }) catch |e|
        failWith(c_alloc, e);
}

/// `AMitemFromInt`. Rust: `src/item.rs:1506-1508`.
pub export fn AMitemFromInt(value: i64) ?*AMresult {
    return boxOne(c_alloc, valueInt(value)) catch |e| failWith(c_alloc, e);
}

/// `AMitemFromNull`. Rust: `src/item.rs:1517-1519`.
pub export fn AMitemFromNull() ?*AMresult {
    return boxOne(c_alloc, .{ .value = ownedScalar(.null_value) }) catch |e| failWith(c_alloc, e);
}

/// `AMitemFromStr`. Rust: `src/item.rs:1535-1537`.
pub export fn AMitemFromStr(value: AMbyteSpan) ?*AMresult {
    const text = spanStr(value) catch |e| return failWith(c_alloc, e);
    const owned = c_alloc.dupe(u8, text) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .value = ownedScalar(.{ .str = owned }) }) catch |e|
        failWith(c_alloc, e);
}

/// `AMitemFromTimestamp`. Rust: `src/item.rs:1548-1550`.
pub export fn AMitemFromTimestamp(value: i64) ?*AMresult {
    return boxOne(c_alloc, .{ .value = ownedScalar(.{ .timestamp = value }) }) catch |e|
        failWith(c_alloc, e);
}

/// `AMitemFromUint`. Rust: `src/item.rs:1560-1562`.
pub export fn AMitemFromUint(value: u64) ?*AMresult {
    return boxOne(c_alloc, valueUint(value)) catch |e| failWith(c_alloc, e);
}

/// `AMitemIdxType`. Rust: `src/item.rs:1576-1581`.
///
/// **A null handle is `AM_IDX_TYPE_DEFAULT`** (`:1579-1580`), and so is an item
/// with no index (`src/item.rs:817-824`).
pub export fn AMitemIdxType(item: ?*const AMitem) AMidxType {
    const i = item orelse return .AM_IDX_TYPE_DEFAULT;
    return i.get().idxType();
}

/// `AMitemObjId`. Rust: `src/item.rs:1595-1602`.
///
/// **A null handle and an item with no object id are both `NULL`** (`:1600-1601`).
/// The returned handle is owned by the item and dies with the result.
pub export fn AMitemObjId(item: ?*const AMitem) ?*const AMobjId {
    const i = item orelse return null;
    const it = i.get();
    if (it.obj_id == null) return null;
    return &it.obj_id.?;
}

/// `AMitemKey`. Rust: `src/item.rs:1617-1629`.
///
/// `false` for a null handle, a null out-parameter, a position index and an
/// item with no index. The span borrows the key bytes the item **owns**, which
/// is why [`AMindex`] copies rather than borrows them.
pub export fn AMitemKey(item: ?*const AMitem, value: ?*AMbyteSpan) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const idx = i.get().index orelse return false;
    const key = idx.keySlice() orelse return false;
    out.* = AMbyteSpan.of(key);
    return true;
}

/// `AMitemPos`. Rust: `src/item.rs:1644-1656`.
pub export fn AMitemPos(item: ?*const AMitem, value: ?*usize) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const idx = i.get().index orelse return false;
    const pos = idx.position() orelse return false;
    out.* = pos;
    return true;
}

/// `AMitemRefCount`. Rust: `src/item.rs:1670-1675`.
///
/// **`0` for `NULL`** (`:1674`).
pub export fn AMitemRefCount(item: ?*const AMitem) usize {
    const i = item orelse return 0;
    return i.refCount();
}

/// `AMitemResult`. Rust: `src/item.rs:1691-1696`.
///
/// **A null handle returns `NULL`, not an error result** (`:1695`): the
/// reference's `std::ptr::null_mut()`.
///
/// **The new result shares the item.** The reference is
/// `AMresult::item(item.clone())` (`:1693`), which clones the `Rc`: the count
/// goes up and `AMitemRefCount` on either handle reports it. Copying the
/// `Item` struct instead would give two results ownership of one `AMchange`'s
/// heap buffers, and `AMresultFree` on both would free them twice.
pub export fn AMitemResult(item: ?*const AMitem) ?*AMresult {
    const i = item orelse return null;
    const shared = i.retain();
    errdefer shared.deinit(c_alloc);
    var held = AMresult.initItem(c_alloc, shared) catch |e| return failWith(c_alloc, e);
    return held.toOwned(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMitemToActorId`. Rust: `src/item.rs:1711-1724`.
pub export fn AMitemToActorId(item: ?*const AMitem, value: ?*?*const AMactorId) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const v = valueCell(i.get()) orelse return false;
    switch (v.*) {
        .actor_id => |*a| {
            out.* = a;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToBool`. Rust: `src/item.rs:1739-1749`.
pub export fn AMitemToBool(item: ?*const AMitem, value: ?*bool) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const s = scalarOf(i.get()) orelse return false;
    switch (s) {
        .bool_value => |b| {
            out.* = b;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToBytes`. Rust: `src/item.rs:1764-1774`.
pub export fn AMitemToBytes(item: ?*const AMitem, value: ?*AMbyteSpan) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const s = scalarOf(i.get()) orelse return false;
    switch (s) {
        .bytes => |b| {
            out.* = AMbyteSpan.of(b);
            return true;
        },
        else => return false,
    }
}

/// `AMitemToChange`. Rust: `src/item.rs:1789-1799`.
///
/// **Needs a unique item**: the reference reaches its `&mut AMchange` through
/// `Rc::get_mut` and answers `Self::Error::Fail` when the count is above one
/// (`:1186-1190`).
pub export fn AMitemToChange(item: ?*AMitem, value: ?*?*AMchange) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const v = valueCellMut(i.getMut() orelse return false) orelse return false;
    switch (v.*) {
        .change => |*c| {
            out.* = c;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToChangeHash`. Rust: `src/item.rs:1814-1824`.
///
/// **The span points into the item's own storage and not into a copy of it.**
/// `Item.value` is an optional payload, so `i.get().value` **copies** the
/// `Value` union into this frame and `&h.bytes` was the address of a dead
/// stack frame; [`valueCell`] is the accessor that does not copy. Upstream
/// cannot have this bug: `AMitem::change_hash` borrows out of the
/// `Rc<Item>` the C caller still holds (`src/item.rs:1814-1824`), so the
/// address is stable for as long as the result is. Reading it back gave the
/// caller 32 bytes of whatever the next call left on the stack: a
/// `@memcpy arguments alias` panic in `AMgetChangeByHash`, and
/// `malloc_consolidate(): unaligned fastbin chunk detected` in the C suite,
/// both from this one dangling pointer.
pub export fn AMitemToChangeHash(item: ?*const AMitem, value: ?*AMbyteSpan) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const cell: *Value = @constCast(valueCell(i.get()) orelse return false);
    switch (cell.*) {
        .change_hash => |*h| {
            out.* = AMbyteSpan.of(&h.bytes);
            return true;
        },
        else => return false,
    }
}

/// `AMitemToCounter`. Rust: `src/item.rs:1839-1849`.
pub export fn AMitemToCounter(item: ?*const AMitem, value: ?*i64) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const s = scalarOf(i.get()) orelse return false;
    switch (s) {
        .counter => |c| {
            out.* = c.current;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToCursor`. Rust: `src/item.rs:1864-1874`.
pub export fn AMitemToCursor(item: ?*const AMitem, value: ?*?*const AMcursor) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const v = valueCell(i.get()) orelse return false;
    switch (v.*) {
        .cursor => |*c| {
            out.* = c;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToDoc`. Rust: `src/item.rs:1889-1899`.
///
/// **Needs a unique item**, through `Rc::get_mut` (`:1206-1210`).
pub export fn AMitemToDoc(item: ?*AMitem, value: ?*?*AMdoc) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const v = valueCellMut(i.getMut() orelse return false) orelse return false;
    switch (v.*) {
        .doc => |*d| {
            out.* = d;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToF64`. Rust: `src/item.rs:1914-1924`.
pub export fn AMitemToF64(item: ?*const AMitem, value: ?*f64) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const s = scalarOf(i.get()) orelse return false;
    switch (s) {
        .float => |f| {
            out.* = f;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToInt`. Rust: `src/item.rs:1939-1949`.
pub export fn AMitemToInt(item: ?*const AMitem, value: ?*i64) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const s = scalarOf(i.get()) orelse return false;
    switch (s) {
        .int => |n| {
            out.* = n;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToMark`. Rust: `src/item.rs:1964-1974`.
pub export fn AMitemToMark(item: ?*const AMitem, value: ?*?*const AMmark) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const v = valueCell(i.get()) orelse return false;
    switch (v.*) {
        .mark => |*m| {
            out.* = m;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToStr`. Rust: `src/item.rs:1989-1999`.
pub export fn AMitemToStr(item: ?*const AMitem, value: ?*AMbyteSpan) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const s = scalarOf(i.get()) orelse return false;
    switch (s) {
        .str => |t| {
            out.* = AMbyteSpan.of(t);
            return true;
        },
        else => return false,
    }
}

/// `AMitemToSyncHave`. Rust: `src/item.rs:2014-2027`.
pub export fn AMitemToSyncHave(item: ?*const AMitem, value: ?*?*const syncmod.AMsyncHave) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const v = valueCell(i.get()) orelse return false;
    switch (v.*) {
        .sync_have => |*h| {
            out.* = h;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToSyncMessage`. Rust: `src/item.rs:2042-2055`.
pub export fn AMitemToSyncMessage(
    item: ?*const AMitem,
    value: ?*?*const syncmod.AMsyncMessage,
) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const v = valueCell(i.get()) orelse return false;
    switch (v.*) {
        .sync_message => |*m| {
            out.* = m;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToSyncState`. Rust: `src/item.rs:2070-2083`.
///
/// **Needs a unique item**, through `Rc::get_mut` (`:1242-1246`).
pub export fn AMitemToSyncState(item: ?*AMitem, value: ?*?*syncmod.AMsyncState) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const v = valueCellMut(i.getMut() orelse return false) orelse return false;
    switch (v.*) {
        .sync_state => |*s| {
            out.* = s;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToTimestamp`. Rust: `src/item.rs:2098-2108`.
pub export fn AMitemToTimestamp(item: ?*const AMitem, value: ?*i64) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const s = scalarOf(i.get()) orelse return false;
    switch (s) {
        .timestamp => |t| {
            out.* = t;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToUint`. Rust: `src/item.rs:2123-2133`.
pub export fn AMitemToUint(item: ?*const AMitem, value: ?*u64) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const s = scalarOf(i.get()) orelse return false;
    switch (s) {
        .uint => |n| {
            out.* = n;
            return true;
        },
        else => return false,
    }
}

/// `AMitemToUnknown`. Rust: `src/item.rs:2148-2158`.
///
/// The struct is **copied into the caller's out-parameter**, and the span inside
/// it borrows the item's own bytes (`src/item.rs:468-474`), which the item owns
/// (`src/item.rs:520-524`).
pub export fn AMitemToUnknown(item: ?*const AMitem, value: ?*AMunknownValue) bool {
    const out = value orelse return false;
    const i = item orelse return false;
    const s = scalarOf(i.get()) orelse return false;
    switch (s) {
        .unknown => |u| {
            out.* = .{ .bytes = AMbyteSpan.of(u.bytes), .type_code = u.type_code };
            return true;
        },
        else => return false,
    }
}

/// `AMitemValType`. Rust: `src/item.rs:2172-2177`.
///
/// **A null handle is `AM_VAL_TYPE_DEFAULT`** (`:2175-2176`), and so is a handle
/// to an item with no value, which is a different tag from `VOID` (`:1396`).
pub export fn AMitemValType(item: ?*const AMitem) AMvalType {
    const i = item orelse return .AM_VAL_TYPE_DEFAULT;
    return i.get().valType();
}

// ---------------------------------------------------------------------------
// AMdoc. Rust: src/doc.rs.
// ---------------------------------------------------------------------------

/// `to_doc!` / `to_doc_mut!` (Rust: `src/doc/utils.rs:11-31`). Both spell the
/// same message, and it is the one a C caller sees most often.
fn invalidDoc(alloc: Allocator) ?*AMresult {
    return boxError(alloc, "Invalid `AMdoc*`") catch null;
}

/// `to_items!` (Rust: `src/doc/utils.rs:33-40`).
fn invalidItems(alloc: Allocator) ?*AMresult {
    return boxError(alloc, "Invalid `AMitems*`") catch null;
}

/// Copies `bytes` into the document's own arena.
///
/// [`Document.setActorId`](doc.zig) stores the bytes **as given** and never
/// frees them — "a caller may hand it a string literal" (`doc.zig:3738-3741`) —
/// so a C caller's buffer, which the ABI does not promise to outlive the call,
/// cannot be the document's storage. The arena frees the copy with the
/// document, which is what [`Document.forkAt`](doc.zig) does for the same reason
/// (`doc.zig:3745-3752`).
fn internActor(d: *const AMdoc, bytes: []const u8) ![]const u8 {
    return @constCast(d).doc.arena.allocator().dupe(u8, bytes);
}

/// `to_sync_state_mut!` (Rust: `src/doc.rs:21-30`).
fn invalidSyncState(alloc: Allocator) ?*AMresult {
    return boxError(alloc, "Invalid `AMsyncState*`") catch null;
}

/// The message a `clamp!` / `adjust!` / `to_range!` refusal carries.
///
/// Upstream formats it (`format!("Invalid pos {}", …)`, `src/doc/utils.rs:6`,
/// `src/doc/list.rs:17`) and its own cmocka suite does not match on it, so this
/// port spells the *kind* (`@errorName`) and the report names the difference.
/// Reproducing `Display for AutomergeError` would mean inventing a type this
/// port does not have.
/// `AMapplyChanges`. Rust: `src/doc.rs:85-92`.
///
/// One `AM_VAL_TYPE_VOID` item, from `to_result(doc.apply_changes(changes))`
/// where `apply_changes` returns `Result<()>`. The `AMitems` must hold
/// `AM_VAL_TYPE_CHANGE` items (`Vec::<am::Change>::try_from`, `:87`).
pub export fn AMapplyChanges(doc: ?*AMdoc, items: ?*const AMitems) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const seq = items orelse return invalidItems(c_alloc);
    const changes = changesOf(c_alloc, seq) catch |e| return failWith(c_alloc, e);
    defer {
        for (changes) |*c| c.deinit(c_alloc);
        c_alloc.free(changes);
    }
    _ = d.applyChanges(c_alloc, changes) catch |e| return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMclone`. Rust: `src/doc.rs:108-111`.
///
/// One `AM_VAL_TYPE_DOC` item that **owns** the copy: upstream's
/// `to_result(doc.as_ref().clone())` moves an `AutoCommit` into
/// `Value::Doc(RefCell::new(AMdoc::new(..)))` (`src/item.rs:147-151`), and
/// `AMresultFree` is what frees it.
pub export fn AMclone(doc: ?*const AMdoc) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const copy = @constCast(d).cloneDoc(c_alloc) catch |e| return failWith(c_alloc, e);
    return docResult(c_alloc, copy) catch |e| failWith(c_alloc, e);
}

/// `AMcreate`. Rust: `src/doc.rs:126-131`.
///
/// **A null `actor_id` is a random one** (`:128-131`). A supplied one is
/// interned into the document's own arena, because
/// [`Document.setActorId`](doc.zig) stores the bytes as given and never frees
/// them (`doc.zig:2288-2298`) and the C caller's buffer may be gone before the
/// document is.
///
/// **The document is built in [`cTextEncoding`]**, which is what upstream's
/// `am::AutoCommit::new()` gets and therefore what every index in a text
/// object this entry point hands back is in: `AutoCommit::new` is
/// `AutoCommit::default()` ([`autocommit.rs:92-94`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
/// whose `doc` is `Automerge::new()`
/// (`:80`), and that is `ops: OpSet::new(TextEncoding::platform_default())`
/// ([`automerge.rs:272`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
pub export fn AMcreate(actor_id: ?*const AMactorId) ?*AMresult {
    var d: AMdoc = .{ .doc = docmod.Document.initWithEncoding(c_alloc, cTextEncoding(), .auto) catch |e|
        return failWith(c_alloc, e) };
    errdefer d.deinit();
    if (actor_id) |a| {
        const kept = internActor(&d, a.body.bytes) catch |e| return failWith(c_alloc, e);
        d.setActorId(.{ .bytes = kept });
    }
    return docResult(c_alloc, d) catch |e| failWith(c_alloc, e);
}

/// `AMcommit`. Rust: `src/doc.rs:151-165`.
///
/// One `AM_VAL_TYPE_CHANGE_HASH` item, or a `VOID` item when there was nothing
/// to commit. Upstream's `AutoCommit::commit_with`
/// ([`autocommit.rs:728-739`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs))
/// is `ensure_transaction_open()` — "ensure that even no changes triggers a
/// change" (`:729-730`) — followed by `tx.commit(..)`, and
/// `TransactionInner::commit` answers `None` for a transaction that wrote
/// nothing ([`inner.rs:129-143`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
/// `to_result(None)` is the value-less item (`src/item.rs:1050-1058`), so
/// **`VOID` is the answer, and it is the answer a document that has committed
/// nothing should give.** This function used to call `Document.commit` with an
/// empty operation list, which minted an empty *change* every time and made
/// `AMpendingOps` and `AMchangeSeq` disagree with the reference.
pub export fn AMcommit(doc: ?*AMdoc, message: AMbyteSpan, timestamp: ?*const i64) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const msg = if (message.src == null) null else spanStr(message) catch |e|
        return failWith(c_alloc, e);
    const time = if (timestamp) |t| t.* else null;
    const t = d.open() catch |e| return failWith(c_alloc, e);
    const hash = t.commit(msg, time) catch |e| return failWith(c_alloc, e);
    t.deinit();
    d.tx = null;
    if (hash == null) return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .change_hash = hash.? }) catch |e| failWith(c_alloc, e);
}

/// `AMemptyChange`. Rust: `src/doc.rs:194-208`.
pub export fn AMemptyChange(doc: ?*AMdoc, message: AMbyteSpan, timestamp: ?*const i64) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const msg = if (message.src == null) null else spanStr(message) catch |e|
        return failWith(c_alloc, e);
    const time = if (timestamp) |t| t.* else null;
    d.close() catch |e| return failWith(c_alloc, e);
    const hash = d.doc.emptyCommit(c_alloc, msg, time) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .change_hash = hash }) catch |e| failWith(c_alloc, e);
}

/// `AMequal`. Rust: `src/doc.rs:225-230`.
///
/// The reference's `AMdoc::is_equal_to` (`src/doc.rs:43-45`) is
/// `self.document().get_heads() == other.document().get_heads()` — **heads only**,
/// not the whole document, and the `\brief` says "after closing their respective
/// transactions" (`src/doc.rs:212`). One null is `false` (`:228`).
pub export fn AMequal(doc1: ?*AMdoc, doc2: ?*AMdoc) bool {
    const a = doc1 orelse return false;
    const b = doc2 orelse return false;
    const ha = a.getHeads(c_alloc) catch return false;
    defer c_alloc.free(ha);
    const hb = b.getHeads(c_alloc) catch return false;
    defer c_alloc.free(hb);
    if (ha.len != hb.len) return false;
    for (ha, hb) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

/// `AMfork`. Rust: `src/doc.rs:249-258`.
///
/// **One `AM_VAL_TYPE_DOC` item**, and that is the whole of the change from
/// what this file used to do. Upstream is `to_result(doc.fork())`
/// ([`automerge-c/src/doc.rs:252`](../../github-automerge-automerge/rust/automerge-c/src/doc.rs)),
/// and `to_result` takes the value by `Into<AMresult>`; the
/// `From<am::AutoCommit> for AMresult` impl
/// ([`automerge-c/src/result.rs:37-41`](../../github-automerge-automerge/rust/automerge-c/src/result.rs))
/// is `Self::item(AMitem::exact(am::ROOT, auto_commit.into()))`, so the fork
/// **is** the result's one document item and the caller owns it. The `\return`
/// line in upstream's own doc comment (`automerge-c/src/doc.rs:239`) says
/// `AM_VAL_TYPE_VOID`; that line is wrong about the code beside it, and the
/// reference's own C suite is the authority —
/// [`test/ported_wasm/basic_tests.c:1501`](../../github-automerge-automerge/rust/automerge-c/test/ported_wasm/basic_tests.c)
/// reads the item with `AMitemToDoc` under `AMexpect(AM_VAL_TYPE_DOC)`, as do
/// `test/c/suite/list_tests.c:245` and `test/c/suite/map_tests.c:1376`.
///
/// A `heads` list that is not change hashes is upstream's
/// `<Vec<am::ChangeHash>>::try_from` error (`:253-255`), which is
/// [`headsOf`]'s refusal.
pub export fn AMfork(doc: ?*AMdoc, heads: ?*const AMitems) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const hashes = headsOf(c_alloc, heads) catch |e| return failWith(c_alloc, e);
    defer c_alloc.free(hashes);
    const forked = if (heads == null)
        d.forkDoc(c_alloc) catch |e| return failWith(c_alloc, e)
    else
        d.forkDocAt(c_alloc, hashes) catch |e| return failWith(c_alloc, e);
    return docResult(c_alloc, forked) catch |e| failWith(c_alloc, e);
}

/// `AMgetActorId`. Rust: `src/doc.rs:300-305`.
pub export fn AMgetActorId(doc: ?*const AMdoc) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const v = actorValue(c_alloc, d.getActorId()) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, v) catch |e| failWith(c_alloc, e);
}

/// `AMgetChangeByHash`. Rust: `src/doc.rs:327-338`.
///
/// One `AM_VAL_TYPE_CHANGE` item, or a `VOID` item when the document does not
/// hold the hash: the reference's `to_result(Option<am::Change>)`
/// (`src/doc.rs:332`) renders `None` as `AMitem::default()`, which is the
/// value-less item (`src/item.rs:1050-1058`).
pub export fn AMgetChangeByHash(doc: ?*AMdoc, src: ?[*]const u8, count: usize) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const s = src orelse return boxErrorNamed(c_alloc, "Invalid uint8_t*");
    const bytes = s[0..count];
    if (bytes.len != types.hash_size) return failWith(c_alloc, error.InvalidChangeHashBytes);
    var hash: ChangeHash = .zero;
    @memcpy(&hash.bytes, bytes);
    const built = d.getChangeByHash(c_alloc, hash) catch |e| return failWith(c_alloc, e);
    if (built == null) return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
    return changeResult(c_alloc, built.?) catch |e| failWith(c_alloc, e);
}

/// `AMgetChanges`. Rust: `src/doc.rs:355-365`.
pub export fn AMgetChanges(doc: ?*AMdoc, have_deps: ?*const AMitems) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const hashes = headsOf(c_alloc, have_deps) catch |e| return failWith(c_alloc, e);
    defer c_alloc.free(hashes);
    var changes = d.getChanges(c_alloc, hashes) catch |e| return failWith(c_alloc, e);
    defer changes.deinit(c_alloc);
    return changesResult(c_alloc, changes) catch |e| failWith(c_alloc, e);
}

/// `AMgetChangesAdded`. Rust: `src/doc.rs:384-388`.
pub export fn AMgetChangesAdded(doc1: ?*AMdoc, doc2: ?*AMdoc) ?*AMresult {
    const a = doc1 orelse return invalidDoc(c_alloc);
    const b = doc2 orelse return invalidDoc(c_alloc);
    var changes = a.getChangesAdded(c_alloc, b) catch |e| return failWith(c_alloc, e);
    defer changes.deinit(c_alloc);
    return changesResult(c_alloc, changes) catch |e| failWith(c_alloc, e);
}

/// `AMgetCursor`. Rust: `src/doc.rs:412-427`.
///
/// **The refusal for an index past the end stays `InvalidIndex`, and it is
/// upstream's own label for a different question.** `get_cursor_for` asks
/// `seek_ops_by_index` for a position and, when nothing answers, returns
/// `Err(AutomergeError::InvalidIndex(i))`
/// ([`automerge.rs:1747-1755`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// whose message is `"index {0} is out of bounds"`
/// ([`error.rs:36-37`](../../github-automerge-automerge/rust/automerge/src/error.rs)).
/// **That arm is not the arm [`AMgetCursorPosition`] below refuses in**, which
/// is a cursor that names a row of some *other* object and is upstream's
/// `InvalidCursor` — so the two labels stay distinct and only one of them moved.
///
/// **This call still builds its clock with [`clockFromItems`] and does not go
/// through [`read.getCursorMoving`](../read.zig).** That is upstream's
/// `doc.get_cursor(obj_id, position, at)`
/// ([`automerge-c/src/doc.rs:421-423`](../../github-automerge-automerge/rust/automerge-c/src/doc.rs))
/// over `get_cursor_moving` ([`automerge.rs:2179-2188`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// either way, and the only thing the other route would change here is which
/// clock a caller naming the document's own heads gets. See the diff block.
pub export fn AMgetCursor(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    position: usize,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    const cur = cursormod.getCursor(c_alloc, mutableOps(d), obj, .{ .index = position }, clock, .after) catch |e|
        return failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .cursor = .{ .body = cur, .gpa = c_alloc } }) catch |e|
        failWith(c_alloc, e);
}

/// `AMgetCursorPosition`. Rust: `src/doc.rs:455-473`.
///
/// **This calls [`read.getCursorPosition`](../read.zig), and that is upstream's
/// own call.** Upstream's body is `doc.get_cursor_position(obj_id, cursor, at)`
/// ([`automerge-c/src/doc.rs:465`](../../github-automerge-automerge/rust/automerge-c/src/doc.rs),
/// and `:468` on the `heads` arm) — the **public** `ReadDoc` method
/// ([`read.rs:237-242`](../../github-automerge-automerge/rust/automerge/src/read.rs))
/// over [`Automerge::get_cursor_position_for`]
/// ([`automerge.rs:2190-2198`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)
/// over `:1760-1849`) over [`cursormod.getCursorPosition`](../cursor.zig).
/// **The port's transcription of that middle method is `read.getCursorPosition`**
/// ([`read.zig:1855-1907`](../read.zig)); `cursormod.getCursorPosition` is the
/// private `get_cursor_position_for` **underneath** it, and no upstream `AM*`
/// function reaches past the method into the helper.
///
/// **Why that is a C-visible difference, when no status code is.** Upstream's C
/// ABI has no per-error status at all: every refusal is `AM_STATUS_ERROR` beside
/// a message, because the one conversion here is
/// `Err(e) => Self::error(&e.to_string())`
/// ([`src/result.rs:313-320`](../../github-automerge-automerge/rust/automerge-c/src/result.rs))
/// and [`AMstatus`] is `OK`/`ERROR`/`INVALID_RESULT` and nothing else
/// ([result.zig:958-962](result.zig)). **So the message is the label**, and this
/// port spells it with the `@errorName` of whatever propagated
/// ([`failWith`](src/c/doc.zig), `:1915-1917`).
///
/// **A cursor naming a row of a *different* object is `InvalidCursor`.** Upstream's
/// `seek_list_opid` searches *within the object's rows* and answers an `Option`
/// ([`op_set.rs:837-851`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
/// and `get_cursor_position_for` turns that empty answer into its own refusal:
/// `.ok_or_else(|| AutomergeError::InvalidCursor(cursor.clone()))`
/// ([`automerge.rs:1778-1781`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
/// The message is `"cursor {0} is invalid"`
/// ([`error.rs:46-47`](../../github-automerge-automerge/rust/automerge/src/error.rs)).
/// **The port's [`OpSet.seekListOpid`](../opset/op_set.zig) cannot answer `null`
/// for that same question** — it raises `error.InvalidIndex` when the id's row
/// lies outside the object's range
/// ([`op_set.zig:3145`](../opset/op_set.zig)) — so calling the private helper
/// directly reported upstream's refusal **under the op set's name**, and a
/// caller handed `InvalidCursor` by [`read.getCursorPosition`](../read.zig)
/// ([`read.zig:1897-1905`](../read.zig)) was handed `InvalidIndex` here.
/// **One port, two answers, one cursor**, and calling the method upstream calls
/// is what removes it; the reader already does the relabel.
///
/// **The clock is `AutoCommit::get_scope`'s and not `Automerge::clock_at`'s, and
/// that is the whole of what was wrong here.**
/// `AMdoc` **is** an `AutoCommit` ([`src/doc.rs:35-36`](../../github-automerge-automerge/rust/automerge-c/src/doc.rs)),
/// so upstream reaches `AutoCommit`'s `ReadDoc::get_cursor_position`
/// ([`autocommit.rs:996-1004`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
/// which fills its last argument from
/// [`AutoCommit::get_scope`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):794-814
/// — **not** from the same-named method on `Automerge`
/// ([`automerge.rs:2190-2198`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// which is a different receiver's different body. The two agree on every
/// answer; they differ on **which clock they build**, and only one of them is
/// sound here.
///
/// `get_scope`'s first arm
/// ([`:794-805`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs))
/// is
/// `if let Some(h) = heads { return if self.transaction.is_none() { self.doc.clock_at(h) } else { Some(self.doc.change_graph.clock_at(h)) } }`,
/// and upstream's own comment says why in one sentence
/// ([`:797-799`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)):
/// **"the heads == current-heads shortcut (an unscoped read) is only sound with
/// no transaction in flight: pending ops are already in the op set but not yet
/// under the graph's heads."**
///
/// **That is this ABI's ordinary state, and the shortcut took the whole
/// document down with it.** [`AMspliceText`](src/c/doc.zig) leaves the
/// transaction **held** — [`txSpliceText`](src/c/doc.zig) is `d.open()` and a
/// splice, and only [`AMdoc.getHeads`](src/c/doc.zig), a read, closes it — so
/// between a write and the next read the op set already holds the new
/// operations while the graph's heads are still the previous change's. Asking
/// for **those** heads then finds them equal to the graph's current heads, and
/// [`Automerge::clock_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1242-1243
/// answers `None` — an unscoped read of the present, which sees the pending
/// operations. `test/c/suite/ported_wasm/cursor_tests.c:72` is that: a cursor
/// minted at `12` resolves to `16` at the heads it was minted at, because the
/// present's `16` was read instead.
///
/// **So the shortcut is taken only when upstream takes it**, and the
/// transaction-in-flight arm builds the full clock upstream's
/// `Some(self.doc.change_graph.clock_at(h))` builds — which is what
/// [`clockFromItems`] already asks for ([`change_graph.zig`:489](../change_graph.zig)),
/// and is why this function used to answer `12` before it was routed through
/// [`read.getCursorPosition`](../read.zig). The **label** that routing bought —
/// upstream's `InvalidCursor` for a cursor naming a row of another object
/// ([`automerge.rs`:1778-1781](../../github-automerge-automerge/rust/automerge/src/automerge.rs)) —
/// is kept, and it now comes from
/// [`read.getCursorPositionFor`](../read.zig), which is upstream's
/// `get_cursor_position_for` itself.
///
/// **`at = null` is unchanged and needs no guard**: upstream's `get_scope(None)`
/// is `_ => None` unless the document is isolated
/// ([`:806-813`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
/// and no `AM*` export isolates — [`AMdoc.isolate`](src/c/doc.zig) has no caller
/// in this file — so [`read.getCursorPosition`](../read.zig)'s own `readScope`
/// already answers that arm.
pub export fn AMgetCursorPosition(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    cursor: ?*const AMcursor,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const cur = cursor orelse return boxError(c_alloc, "Invalid `AMcursor*`") catch null;
    // **`NULL` is `None` and any other pointer is `Some`** — upstream's
    // `match heads.as_ref()` (`automerge-c/src/doc.rs:464-472`).
    // [`headsOf`] cannot carry that distinction itself: it answers an *empty*
    // slice for a null `AMitems` (`:1445`), and an empty heads list is a clock
    // that covers nothing rather than the present, which is the opposite reading.
    var at: ?[]ChangeHash = null;
    if (heads != null) {
        at = headsOf(c_alloc, heads) catch |e| return failWith(c_alloc, e);
    }
    defer if (at) |hashes| c_alloc.free(hashes);
    // `get_scope`'s first arm (`autocommit.rs:794-805`): the shortcut only
    // with no transaction in flight, the full clock with one.
    const pos = if (at != null and d.tx != null) blk: {
        // **`Some(self.doc.change_graph.clock_at(h))`** — `get_scope`'s
        // transaction-in-flight arm (`:803`), and the clock [`clockFromItems`]
        // builds. The hashes are the ones `headsOf` already read above, so this
        // asks for the clock directly rather than reading the items twice.
        var pending = @constCast(&d.doc).graph.clockAt(c_alloc, at.?) catch |e|
            return failWith(c_alloc, e);
        defer pending.deinit();
        break :blk readmod.getCursorPositionFor(&d.doc, obj, cur.body, pending) catch |e|
            return failWith(c_alloc, e);
    } else readmod.getCursorPosition(&d.doc, obj, cur.body, at) catch |e|
        return failWith(c_alloc, e);
    return boxOne(c_alloc, valueUint(pos)) catch |e| failWith(c_alloc, e);
}

/// `AMgetHeads`. Rust: `src/doc.rs:488-493`.
pub export fn AMgetHeads(doc: ?*AMdoc) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const heads = d.getHeads(c_alloc) catch |e| return failWith(c_alloc, e);
    defer c_alloc.free(heads);
    return boxHashes(c_alloc, heads) catch |e| failWith(c_alloc, e);
}

/// `AMgetMissingDeps`. Rust: `src/doc.rs:512-524`.
pub export fn AMgetMissingDeps(doc: ?*AMdoc, heads: ?*const AMitems) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const hashes = headsOf(c_alloc, heads) catch |e| return failWith(c_alloc, e);
    defer c_alloc.free(hashes);
    const missing = d.getMissingDeps(c_alloc, hashes) catch |e| return failWith(c_alloc, e);
    defer c_alloc.free(missing);
    return boxHashes(c_alloc, missing) catch |e| failWith(c_alloc, e);
}

/// `AMgetLastLocalChange`. Rust: `src/doc.rs:540-543`.
///
/// One `AM_VAL_TYPE_CHANGE` item, or a `VOID` item when the document's own
/// actor has made nothing (`src/doc.rs:530-531`).
pub export fn AMgetLastLocalChange(doc: ?*AMdoc) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const built = d.getLastLocalChange(c_alloc) catch |e| return failWith(c_alloc, e);
    if (built == null) return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
    return changeResult(c_alloc, built.?) catch |e| failWith(c_alloc, e);
}

/// `AMkeys`. Rust: `src/doc.rs:564-578`.
///
/// One `AM_VAL_TYPE_STR` item per visible register. The port's
/// [`Keys`](../iter/keys.zig) walk is the same [`OpSet.topOps`](../opset/op_set.zig)
/// `read.keys` uses (`read.zig:637`), with a clock when `heads` is not null.
pub export fn AMkeys(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    var walk = iterkeys.Keys(opmod.ChangeOp).ofObj(mutableOps(d), obj, clock) catch |e|
        return failWith(c_alloc, e);
    defer walk.deinit(d.allocator());
    var values: std.ArrayList(Value) = .empty;
    errdefer {
        for (values.items) |*v| v.deinit(c_alloc);
        values.deinit(c_alloc);
    }
    while (walk.next() catch |e| {
        for (values.items) |*v| v.deinit(c_alloc);
        return failWith(c_alloc, e);
    }) |key| {
        // The key borrows the op set's string table, and the item may outlive
        // the document, so the bytes are copied.
        const owned = c_alloc.dupe(u8, key) catch |e| return failWith(c_alloc, e);
        values.append(c_alloc, .{ .value = ownedScalar(.{ .str = owned }) }) catch |e| {
            c_alloc.free(owned);
            return failWith(c_alloc, e);
        };
    }
    defer values.deinit(c_alloc);
    return boxValues(c_alloc, values.items) catch |e| failWith(c_alloc, e);
}

/// `AMload`. Rust: `src/doc.rs:598-601`.
///
/// Built in [`cTextEncoding`], like [`AMcreate`] and
/// [`AMchangeLoadDocument`]: upstream is `am::AutoCommit::load(data)`
/// ([`src/doc.rs:600`](../../github-automerge-automerge/rust/automerge-c/src/doc.rs)),
/// which loads through `Automerge::load` and so takes
/// `LoadOptions::default()`'s `platform_default()`
/// ([`automerge.rs:834-836`](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
/// `:181`).
pub export fn AMload(src: ?[*]const u8, count: usize) ?*AMresult {
    const s = src orelse return boxErrorNamed(c_alloc, "Invalid uint8_t*");
    const loaded = docmod.Document.load(
        c_alloc,
        s[0..count],
        cTextEncoding(),
        .auto,
    ) catch |e| return failWith(c_alloc, e);
    return docResult(c_alloc, .{ .doc = loaded }) catch |e| failWith(c_alloc, e);
}

/// `AMloadIncremental`. Rust: `src/doc.rs:623-631`.
///
/// One `AM_VAL_TYPE_UINT` item: the count of changes the document grew by
/// (`src/doc.rs:610`).
pub export fn AMloadIncremental(doc: ?*AMdoc, src: ?[*]const u8, count: usize) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const s = src orelse return boxErrorNamed(c_alloc, "Invalid uint8_t*");
    const n = d.loadIncremental(c_alloc, s[0..count]) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, valueUint(n)) catch |e| failWith(c_alloc, e);
}

/// `AMmerge`. Rust: `src/doc.rs:650-653`.
pub export fn AMmerge(dest: ?*AMdoc, src: ?*AMdoc) ?*AMresult {
    const a = dest orelse return invalidDoc(c_alloc);
    const b = src orelse return invalidDoc(c_alloc);
    const heads = a.merge(c_alloc, b) catch |e| return failWith(c_alloc, e);
    defer c_alloc.free(heads);
    return boxHashes(c_alloc, heads) catch |e| failWith(c_alloc, e);
}

/// `AMobjSize`. Rust: `src/doc.rs:674-693`.
///
/// Returns a count, not a result, so every refusal is `0`: a null `doc`
/// (`:681`), an unresolvable `obj_id` (`to_obj_id!` never fails, so not this
/// one), and a `heads` list that is not change hashes (`:688-690`). The port's
/// [`OpSet.seqLength`](../opset/op_set.zig) is the layer `read.length` calls
/// (`read.zig:573`).
pub export fn AMobjSize(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    heads: ?*const AMitems,
) usize {
    const d = doc orelse return 0;
    const obj = objIdOf(d, obj_id) catch return 0;
    var clock = clockFromItems(c_alloc, d, heads) catch return 0;
    defer if (clock) |*c| c.deinit();
    return mutableOps(d).seqLength(obj, d.textEncoding(), clock) catch 0;
}

/// `AMobjObjType`. Rust: `src/doc.rs:709-717`.
///
/// **Every failure is `AM_OBJ_TYPE_DEFAULT`** (`:712-716`), including a null
/// `doc` and an id that names no object.
pub export fn AMobjObjType(doc: ?*const AMdoc, obj_id: ?*const AMobjId) AMobjType {
    const d = doc orelse return .AM_OBJ_TYPE_DEFAULT;
    const obj = objIdOf(d, obj_id) catch return .AM_OBJ_TYPE_DEFAULT;
    const t = d.doc.objectType(obj) catch return .AM_OBJ_TYPE_DEFAULT;
    return fromObjType(t);
}

/// `AMobjItems`. Rust: `src/doc.rs:738-752`.
///
/// One item per visible register, each carrying an `AM_VAL_TYPE_OBJ_TYPE`
/// value for an object and the object's own id: `to_result(Vec<(am::Value<'static>,
/// am::ObjId)>)` becomes `AMitem::exact(o, v.into())` (`src/result.rs:382-390`),
/// and `AMitem::exact` is `Item { index: None, obj_id: Some(..), value: Some(..) }`
/// (`src/item.rs:1027-1033`).
pub export fn AMobjItems(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    var term = itervalues.TopQuery(opmod.ChangeOp).ofObj(mutableOps(d), obj, clock) catch |e|
        return failWith(c_alloc, e);
    defer term.deinit(d.allocator());
    var walk = itervalues.Values(opmod.ChangeOp, @TypeOf(term)).init(mutableOps(d), &term, clock);
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |*it| it.deinit(c_alloc);
        items.deinit(c_alloc);
    }
    while (walk.next() catch |e| {
        for (items.items) |*it| it.deinit(c_alloc);
        return failWith(c_alloc, e);
    }) |vi| {
        var owned = objIdOfEx(c_alloc, d, vi.id) catch |e| {
            for (items.items) |*it| it.deinit(c_alloc);
            return failWith(c_alloc, e);
        };
        var value = ownedOfRef(c_alloc, vi.value) catch |e| {
            owned.deinit();
            for (items.items) |*it| it.deinit(c_alloc);
            return failWith(c_alloc, e);
        };
        // Ownership of both moves into the appended item, and the `errdefer`
        // above is what frees them if a later iteration fails.
        items.append(c_alloc, .{ .obj_id = owned, .value = value }) catch |e| {
            value.deinit(c_alloc);
            owned.deinit();
            for (items.items) |*it| it.deinit(c_alloc);
            return failWith(c_alloc, e);
        };
    }
    defer items.deinit(c_alloc);
    return boxItems(c_alloc, items.items) catch |e| failWith(c_alloc, e);
}

/// `AMpendingOps`. Rust: `src/doc.rs:766-771`.
///
/// **`0` for `NULL`** (`:769`). For a real document it is the open
/// transaction's own count — `Transaction.count` ([`transact.zig`](../transact.zig)),
/// which is `TransactionInner::pending_ops`
/// ([`inner.rs:103-105`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
/// **`None` is `0`, and that is upstream's own `unwrap_or(0)` shape**: a
/// document whose transaction has been closed has nothing pending. This
/// function used to answer `0` for a document with two uncommitted puts,
/// because the handle committed at the end of every mutating call and so
/// never had an open transaction at all.
pub export fn AMpendingOps(doc: ?*const AMdoc) usize {
    const d = doc orelse return 0;
    return if (d.tx) |t| t.count() else 0;
}

/// `AMreceiveSyncMessage`. Rust: `src/doc.rs:791-803`.
///
/// One `AM_VAL_TYPE_VOID` item. **The receive is handed a copy of the
/// message, not the message**: the port's receive path takes its `Message` by
/// value and *moves* `heads`, `need` and `have` into the peer state
/// (`sync.rs:459-461`) before freeing what it was given (`sync.rs:639-648`),
/// and upstream hands it a **clone** for exactly that reason
/// (`doc.rs:800`, `sync_message.as_ref().clone()`). See
/// [sync.zig](sync.zig)'s module doc. The clone is made after the close
/// below, because the receive consumes it on every path — its own `errdefer`
/// frees it — so there is nothing here left to free, and nothing to leak if
/// the clone itself fails.
pub export fn AMreceiveSyncMessage(
    doc: ?*AMdoc,
    sync_state: ?*syncmod.AMsyncState,
    sync_message: ?*const syncmod.AMsyncMessage,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const state = sync_state orelse return invalidSyncState(c_alloc);
    const msg = sync_message orelse return boxError(c_alloc, "Invalid `AMsyncMessage*`") catch null;
    // Every `AutoCommit` method that reaches past its own transaction closes
    // it first — `load_incremental` (`autocommit.rs:477-478`),
    // `apply_changes` (`:491-492`, `:505-506`), `merge` (`:518-519`), `isolate`
    // (`:433-434`), `integrate` (`:439-440`), `fork` (`:356-357`),
    // `set_actor` (`:396-397`), even `document()` (`:384-386`). A sync
    // exchange is a document write, so it is in that set.
    //
    // Close before the clone: the receive consumes the clone on every path,
    // so a failure between the two would have nothing to release it.
    d.close() catch |e| return failWith(c_alloc, e);
    const received = msg.cloneForReceive() catch |e| return failWith(c_alloc, e);
    protocol.receiveSyncMessage(c_alloc, &d.doc, &state.body, received) catch |e|
        return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMgenerateSyncMessage`. Rust: `src/doc.rs:278-285`.
///
/// **Either a `SYNC_MESSAGE` item or a `VOID` item** (`src/doc.rs:265-267`),
/// because `generateSyncMessage` answers `Option<am::sync::Message>` and
/// `None` is the reference's *Silence is the common answer*
/// ([sync.zig](../sync/protocol.zig)'s module doc, `sync.rs:242-249`).
pub export fn AMgenerateSyncMessage(
    doc: ?*AMdoc,
    sync_state: ?*syncmod.AMsyncState,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const state = sync_state orelse return invalidSyncState(c_alloc);
    d.close() catch |e| return failWith(c_alloc, e);
    const message = protocol.generateSyncMessage(c_alloc, &d.doc, &state.body) catch |e|
        return failWith(c_alloc, e);
    if (message == null) return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .sync_message = syncmod.AMsyncMessage.init(c_alloc, message.?) }) catch |e|
        failWith(c_alloc, e);
}

/// `AMrollback`. Rust: `src/doc.rs:817-822`.
///
/// **`0` for `NULL`** (`:820`).
///
/// **And `0` for a document with nothing open**, which is upstream's own
/// `unwrap_or(0)` ([`autocommit.rs:742-750`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)):
/// `rollback` cancels the *open* transaction, and after a read or a commit
/// there is none. This function used to answer `0` for a document with three
/// operations pending, because the handle committed at the end of every
/// mutating call and so never had one; [`AMpendingOps`] is the same shape and
/// reports the same count.
pub export fn AMrollback(doc: ?*AMdoc) usize {
    const d = doc orelse return 0;
    if (d.tx) |*t| {
        const n = t.rollback() catch return 0;
        t.deinit();
        d.tx = null;
        return n;
    }
    return 0;
}

/// `AMsave`. Rust: `src/doc.rs:837-840`.
pub export fn AMsave(doc: ?*AMdoc) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const bytes = d.save(c_alloc) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .value = ownedScalar(.{ .bytes = bytes }) }) catch |e|
        failWith(c_alloc, e);
}

/// `AMsaveIncremental`. Rust: `src/doc.rs:856-859`.
pub export fn AMsaveIncremental(doc: ?*AMdoc) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const bytes = d.saveIncremental(c_alloc) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .value = ownedScalar(.{ .bytes = bytes }) }) catch |e|
        failWith(c_alloc, e);
}

/// `AMsetActorId`. Rust: `src/doc.rs:877-885`.
///
/// One `AM_VAL_TYPE_VOID` item. The bytes are interned into the document's
/// arena for the same reason as [`AMcreate`]: the document never frees them and
/// the C caller's buffer may be gone.
pub export fn AMsetActorId(doc: ?*AMdoc, actor_id: ?*const AMactorId) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const a = actor_id orelse return boxError(c_alloc, "Invalid `AMactorId*`") catch null;
    const kept = internActor(d, a.body.bytes) catch |e| return failWith(c_alloc, e);
    @constCast(d).setActorId(.{ .bytes = kept });
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMsplice`. Rust: `src/doc.rs:916-931`.
///
/// One `AM_VAL_TYPE_VOID` item. The `values` cursor is passed **by value** and
/// is spliced *from its current position*, so a caller that has advanced one
/// first splices from there (`src/doc.rs:898-902`). Every item must be a
/// scalar: `Vec::<am::ScalarValue>::try_from` (`src/doc.rs:924`) refuses an
/// object, a change, a cursor and so on.
pub export fn AMsplice(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    del: isize,
    values: AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const len = mutableOps(d).seqLength(obj, d.textEncoding(), null) catch return failWith(c_alloc, error.NotAnObject);
    const at = clampPos(pos, len) catch |e| return failWith(c_alloc, e);
    var owners: std.ArrayList(optypes.OwnedValueRef) = .empty;
    defer {
        for (owners.items) |*o| o.deinit(c_alloc);
        owners.deinit(c_alloc);
    }
    const vals = spliceValues(c_alloc, values, &owners) catch |e| return failWith(c_alloc, e);
    defer c_alloc.free(vals);
    txSplice(d, obj, at, del, c_alloc, vals) catch |e| return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMspliceText`. Rust: `src/doc.rs:962-974`.
pub export fn AMspliceText(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    del: isize,
    text: AMbyteSpan,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const len = mutableOps(d).seqLength(obj, d.textEncoding(), null) catch return failWith(c_alloc, error.NotAnObject);
    const at = clampPos(pos, len) catch |e| return failWith(c_alloc, e);
    const body = spanStr(text) catch |e| return failWith(c_alloc, e);
    txSpliceText(d, obj, at, del, body) catch |e| return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `Vec::<am::ScalarValue>::try_from(values)` (Rust: `src/items.rs:233-249`),
/// into the port's [`hydmod.Value`](../hydrate.zig) for
/// [`transact.splice`](../transact.zig).
///
/// **The caller owns two things afterwards and this signature says so**: the
/// returned slice of [`hydmod.Value`]s, and every entry appended to `owners`.
/// A `hydmod.Value`'s `str` / `bytes` / `unknown.bytes` point at bytes the item
/// owns, and a splice copies them into the document before the call returns, so
/// the owners must outlive the splice and are freed after it. Freeing the owners
/// *before* the splice would be a use-after-free, which is why this is an
/// out-parameter rather than a hidden `defer`.
fn spliceValues(
    alloc: Allocator,
    items: AMitems,
    owners: *std.ArrayList(optypes.OwnedValueRef),
) ![]hydmod.Value {
    var out: std.ArrayList(hydmod.Value) = .empty;
    errdefer out.deinit(alloc);
    for (items.slice()) |item| {
        const cell = ownedOf(item.get()) orelse return error.InvalidValueType;
        const copied = try cell.value.intoOwned(alloc);
        owners.append(alloc, copied) catch |e| {
            var tmp = copied;
            tmp.deinit(alloc);
            return e;
        };
        out.append(alloc, toHydrate(copied.value)) catch |e| return e;
    }
    return out.toOwnedSlice(alloc);
}

/// One [`optypes.ValueRef`] as a [`hydmod.Value`](../hydrate.zig). The two
/// unions have the same eleven byte-free variants; `hydmod.Value` has no
/// `object` variant, so an object is the port's own refusal, which is what
/// `Vec::<am::ScalarValue>::try_from` does upstream (`src/items.rs:236-247`).
fn toHydrate(v: optypes.ValueRef) hydmod.Value {
    // `hydmod.Value` has no `object` variant, so this is total over the two
    // shapes `ValueRef` has. The caller has already refused `.object` through
    // [`ownedOf`], which is upstream's own refusal; the `.null_value` here is
    // only the answer for a value the caller should never have passed.
    const s = switch (v) {
        .object => ScalarValue.null_value,
        .scalar => |x| x,
    };
    return switch (s) {
        .null_value => .{ .null_value = {} },
        .bool_value => |b| .{ .bool_value = b },
        .int => |n| .{ .int = n },
        .uint => |n| .{ .uint = n },
        .float => |f| .{ .float = f },
        .str => |t| .{ .str = t },
        .bytes => |b| .{ .bytes = b },
        .counter => |c| .{ .counter = c },
        .timestamp => |t| .{ .timestamp = t },
        .actor_id => |a| .{ .actor_id = a },
        .unknown => |u| .{ .unknown = u },
    };
}

/// `AMtext`. Rust: `src/doc.rs:995-1009`.
///
/// One `AM_VAL_TYPE_STR` item.
pub export fn AMtext(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    const text = mutableOps(d).text(c_alloc, obj, clock) catch |e| return failWith(c_alloc, e);
    return boxOne(c_alloc, .{ .value = ownedScalar(.{ .str = text }) }) catch |e|
        failWith(c_alloc, e);
}

// ---------------------------------------------------------------------------
// Lists. Rust: src/doc/list.rs.
// ---------------------------------------------------------------------------

/// The one item `to_result((doc.get(obj_id, pos), pos))` produces. Rust:
/// `src/doc/list.rs:93-97` and the tuple `From` impl at `src/result.rs:282-302`.
///
/// **One item, and the position rides along as the item's index.** The
/// reference's `Ok(Some((value, obj_id)))` arm is
/// `AMitem::indexed(AMindex::Pos(pos), obj_id, value.into())` and its
/// `Ok(None)` arm is `AMitem::default()` (`src/result.rs:293-296`) — a
/// value-less item, which is `AM_VAL_TYPE_VOID` and carries neither the
/// position nor an id (`src/item.rs:1050-1058`).
fn listGetResult(
    alloc: Allocator,
    found: ?DocItem,
    doc: *const AMdoc,
    pos: usize,
) !*AMresult {
    const f = found orelse return try boxVoid(alloc);
    return try boxItem(alloc, try indexedItem(
        alloc,
        AMindex.ofPos(alloc, pos),
        try objIdOfEx(alloc, doc, f.id),
        f.value,
    ));
}

/// `AMlistDelete`. Rust: `src/doc/list.rs:50-59`.
///
/// One `AM_VAL_TYPE_VOID` item.
pub export fn AMlistDelete(doc: ?*AMdoc, obj_id: ?*const AMobjId, pos: usize) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const len = mutableOps(d).seqLength(obj, d.textEncoding(), null) catch 0;
    const at = adjustPos(pos, false, len) catch |e| return failWith(c_alloc, e);
    _ = txDelete(d, obj, .{ .index = at.pos }) catch |e| return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMlistGet`. Rust: `src/doc/list.rs:83-99`.
pub export fn AMlistGet(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const len = mutableOps(d).seqLength(obj, d.textEncoding(), null) catch 0;
    const at = adjustPos(pos, false, len) catch |e| return failWith(c_alloc, e);
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    const found = getAt(d, obj, .{ .index = at.pos }, clock) catch |e| return failWith(c_alloc, e);
    return listGetResult(c_alloc, found, d, at.pos) catch |e| failWith(c_alloc, e);
}

/// `AMlistGetAll`. Rust: `src/doc/list.rs:124-140`.
pub export fn AMlistGetAll(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const len = mutableOps(d).seqLength(obj, d.textEncoding(), null) catch 0;
    const at = adjustPos(pos, false, len) catch |e| return failWith(c_alloc, e);
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    const found = getAllAt(c_alloc, d, obj, .{ .index = at.pos }, clock) catch |e|
        return failWith(c_alloc, e);
    defer c_alloc.free(found);
    var items: std.ArrayList(Item) = .empty;
    errdefer dropItems(c_alloc, &items);
    for (found) |f| {
        const row = objIdOfEx(c_alloc, d, f.id) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
        const built = exactItem(c_alloc, row, f.value) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
        pushItem(c_alloc, &items, built) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
    }
    defer items.deinit(c_alloc);
    return boxItems(c_alloc, items.items) catch |e| failWith(c_alloc, e);
}

/// `AMlistIncrement`. Rust: `src/doc/list.rs:162-172`.
pub export fn AMlistIncrement(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    value: i64,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const len = mutableOps(d).seqLength(obj, d.textEncoding(), null) catch 0;
    const at = adjustPos(pos, false, len) catch |e| return failWith(c_alloc, e);
    txIncrement(d, obj, .{ .index = at.pos }, value) catch |e| return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// The shared body of the twelve `AMlistPut*` functions. Rust: the `to_result`
/// in each of `src/doc/list.rs:198-594`, all of which is
/// `if insert { doc.insert(..) } else { doc.put(..) }` (`:209-213`).
fn listPut(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    value: ScalarValue,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const len = mutableOps(d).seqLength(obj, d.textEncoding(), null) catch 0;
    const at = adjustPos(pos, insert, len) catch |e| return failWith(c_alloc, e);
    if (at.insert) {
        _ = txInsert(d, obj, at.pos, value) catch |e| return failWith(c_alloc, e);
    } else {
        _ = txPut(d, obj, .{ .index = at.pos }, value) catch |e| return failWith(c_alloc, e);
    }
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMlistPutBool`. Rust: `src/doc/list.rs:198-214`.
pub export fn AMlistPutBool(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    value: bool,
) ?*AMresult {
    return listPut(doc, obj_id, pos, insert, .{ .bool_value = value });
}

/// `AMlistPutBytes`. Rust: `src/doc/list.rs:244-260`.
pub export fn AMlistPutBytes(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    value: AMbyteSpan,
) ?*AMresult {
    const bytes = spanBytes(c_alloc, value) catch |e| return failWith(c_alloc, e);
    errdefer c_alloc.free(bytes);
    return listPut(doc, obj_id, pos, insert, .{ .bytes = bytes });
}

/// `AMlistPutCounter`. Rust: `src/doc/list.rs:286-302`.
pub export fn AMlistPutCounter(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    value: i64,
) ?*AMresult {
    return listPut(doc, obj_id, pos, insert, .{ .counter = .{ .current = value } });
}

/// `AMlistPutF64`. Rust: `src/doc/list.rs:328-343`.
pub export fn AMlistPutF64(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    value: f64,
) ?*AMresult {
    return listPut(doc, obj_id, pos, insert, .{ .float = value });
}

/// `AMlistPutInt`. Rust: `src/doc/list.rs:369-384`.
pub export fn AMlistPutInt(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    value: i64,
) ?*AMresult {
    return listPut(doc, obj_id, pos, insert, .{ .int = value });
}

/// `AMlistPutNull`. Rust: `src/doc/list.rs:409-423`.
///
/// Upstream inserts or puts `()`, which is `am::Value::Null` (`src/item.rs:1517-1519`).
pub export fn AMlistPutNull(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
) ?*AMresult {
    return listPut(doc, obj_id, pos, insert, .null_value);
}

/// `AMlistPutObject`. Rust: `src/doc/list.rs:449-465`.
///
/// **One item, not three.** `to_result((doc.insert_object(..), pos, obj_type))`
/// (`src/doc/list.rs:461-464`) reaches
/// `From<(Result<am::ObjId, _>, usize, am::ObjType)>`
/// (`src/result.rs:216-229`), which is
/// `AMitem::indexed(AMindex::Pos(pos), obj_id, am::Value::Object(obj_type))`:
/// the position rides along as the item's **index**, the new object's id as
/// its **object id**, and the type as its **value** — one item carrying all
/// three.
pub export fn AMlistPutObject(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    obj_type: AMobjType,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const t = toObjType(obj_type) catch |e| return failWith(c_alloc, e);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const len = mutableOps(d).seqLength(obj, d.textEncoding(), null) catch 0;
    const at = adjustPos(pos, insert, len) catch |e| return failWith(c_alloc, e);
    const made: ExId = if (at.insert)
        (txInsertObject(d, obj, at.pos, t) catch |e| return failWith(c_alloc, e))
    else
        (txPutObject(d, obj, .{ .index = at.pos }, t) catch |e| return failWith(c_alloc, e));
    const made_id = objIdOfEx(c_alloc, d, made) catch |e| return failWith(c_alloc, e);
    return boxItem(c_alloc, indexedItem(
        c_alloc,
        AMindex.ofPos(c_alloc, at.pos),
        made_id,
        .{ .object = t },
    ) catch |e| return failWith(c_alloc, e)) catch |e| failWith(c_alloc, e);
}

/// `AMlistPutStr`. Rust: `src/doc/list.rs:494-510`.
pub export fn AMlistPutStr(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    value: AMbyteSpan,
) ?*AMresult {
    const text = spanStr(value) catch |e| return failWith(c_alloc, e);
    const owned = c_alloc.dupe(u8, text) catch |e| return failWith(c_alloc, e);
    errdefer c_alloc.free(owned);
    return listPut(doc, obj_id, pos, insert, .{ .str = owned });
}

/// `AMlistPutTimestamp`. Rust: `src/doc/list.rs:537-553`.
pub export fn AMlistPutTimestamp(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    value: i64,
) ?*AMresult {
    return listPut(doc, obj_id, pos, insert, .{ .timestamp = value });
}

/// `AMlistPutUint`. Rust: `src/doc/list.rs:579-594`.
pub export fn AMlistPutUint(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    pos: usize,
    insert: bool,
    value: u64,
) ?*AMresult {
    return listPut(doc, obj_id, pos, insert, .{ .uint = value });
}

/// `AMlistRange`. Rust: `src/doc/list.rs:619-636`.
pub export fn AMlistRange(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    begin: usize,
    end: usize,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const range = toRange(begin, end) catch |e| return failWith(c_alloc, e);
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    const rows = mutableOps(d).listRange(obj) catch |e| return failWith(c_alloc, e);
    var walk = iterlist.ListRange(opmod.ChangeOp).init(
        mutableOps(d),
        rows,
        clock,
        .{ .start = range.start, .end = range.end },
    ) catch |e| return failWith(c_alloc, e);
    // Each element's item **carries its index as a position and its row's id
    // as its object id** — `AMitem::indexed(AMindex::Pos(item.index),
    // item.id(), item.value.into())` (`src/result.rs:103-111`).
    var items: std.ArrayList(Item) = .empty;
    errdefer dropItems(c_alloc, &items);
    while (walk.next() catch |e| {
        dropItems(c_alloc, &items);
        return failWith(c_alloc, e);
    }) |entry| {
        const row = objIdOfEx(c_alloc, d, entry.id()) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
        const built = indexedItem(
            c_alloc,
            AMindex.ofPos(c_alloc, entry.index),
            row,
            entry.value,
        ) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
        pushItem(c_alloc, &items, built) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
    }
    defer items.deinit(c_alloc);
    return boxItems(c_alloc, items.items) catch |e| failWith(c_alloc, e);
}

// ---------------------------------------------------------------------------
// Maps. Rust: src/doc/map.rs.
// ---------------------------------------------------------------------------

/// The one item `to_result((doc.get(obj_id, key), key))` produces. Rust:
/// `src/doc/map.rs:73-77` and the tuple `From` impl at `src/result.rs:258-280`.
///
/// **One item, and the key rides along as the item's index.** The reference's
/// `Ok(Some((value, obj_id)))` arm is
/// `AMitem::indexed(AMindex::Key(key), obj_id, value.into())` and its
/// `Ok(None)` arm is `AMitem::default()` (`src/result.rs:268-273`) — a
/// value-less item, which is `AM_VAL_TYPE_VOID` and carries neither the key
/// nor an id (`src/item.rs:1050-1058`).
fn mapGetResult(alloc: Allocator, found: ?DocItem, doc: *const AMdoc, key: []const u8) !*AMresult {
    const f = found orelse return try boxVoid(alloc);
    const index = try AMindex.ofKey(alloc, key);
    return try boxItem(alloc, try indexedItem(
        alloc,
        index,
        try objIdOfEx(alloc, doc, f.id),
        f.value,
    ));
}

/// A key span as an owned `AM_VAL_TYPE_STR` value. The C caller's buffer may be
/// gone before the result is freed, so the bytes are copied — upstream's
/// `impl From<String> for Value` (`src/item.rs:213-219`) is the same move.
fn valueStrOwned(alloc: Allocator, key: []const u8) !Value {
    const owned = try alloc.dupe(u8, key);
    return valueStr(alloc, owned);
}

/// `AMmapDelete`. Rust: `src/doc/map.rs:30-38`.
pub export fn AMmapDelete(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const k = spanStr(key) catch |e| return failWith(c_alloc, e);
    _ = txDelete(d, obj, .{ .key = k }) catch |e| return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMmapGet`. Rust: `src/doc/map.rs:63-79`.
pub export fn AMmapGet(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const k = spanStr(key) catch |e| return failWith(c_alloc, e);
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    const found = getAt(d, obj, .{ .key = k }, clock) catch |e| return failWith(c_alloc, e);
    return mapGetResult(c_alloc, found, d, k) catch |e| failWith(c_alloc, e);
}

/// `AMmapGetAll`. Rust: `src/doc/map.rs:105-121`.
pub export fn AMmapGetAll(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const k = spanStr(key) catch |e| return failWith(c_alloc, e);
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    const found = getAllAt(c_alloc, d, obj, .{ .key = k }, clock) catch |e|
        return failWith(c_alloc, e);
    defer c_alloc.free(found);
    var items: std.ArrayList(Item) = .empty;
    errdefer dropItems(c_alloc, &items);
    for (found) |f| {
        const row = objIdOfEx(c_alloc, d, f.id) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
        const built = exactItem(c_alloc, row, f.value) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
        pushItem(c_alloc, &items, built) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
    }
    defer items.deinit(c_alloc);
    return boxItems(c_alloc, items.items) catch |e| failWith(c_alloc, e);
}

/// `AMmapIncrement`. Rust: `src/doc/map.rs:143-152`.
pub export fn AMmapIncrement(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: i64,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const k = spanStr(key) catch |e| return failWith(c_alloc, e);
    txIncrement(d, obj, .{ .key = k }, value) catch |e| return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// The shared body of the eleven `AMmapPut*` functions, which are all
/// `to_result(doc.put(to_obj_id!(obj_id), key, value))`
/// (`src/doc/map.rs:174-474`).
fn mapPut(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: ScalarValue,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const k = spanStr(key) catch |e| return failWith(c_alloc, e);
    _ = txPut(d, obj, .{ .key = k }, value) catch |e| return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMmapPutBool`. Rust: `src/doc/map.rs:174-183`.
pub export fn AMmapPutBool(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: bool,
) ?*AMresult {
    return mapPut(doc, obj_id, key, .{ .bool_value = value });
}

/// `AMmapPutBytes`. Rust: `src/doc/map.rs:208-217`.
pub export fn AMmapPutBytes(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: AMbyteSpan,
) ?*AMresult {
    const bytes = spanBytes(c_alloc, value) catch |e| return failWith(c_alloc, e);
    errdefer c_alloc.free(bytes);
    return mapPut(doc, obj_id, key, .{ .bytes = bytes });
}

/// `AMmapPutCounter`. Rust: `src/doc/map.rs:239-252`.
pub export fn AMmapPutCounter(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: i64,
) ?*AMresult {
    return mapPut(doc, obj_id, key, .{ .counter = .{ .current = value } });
}

/// `AMmapPutNull`. Rust: `src/doc/map.rs:273-281`.
pub export fn AMmapPutNull(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
) ?*AMresult {
    return mapPut(doc, obj_id, key, .null_value);
}

/// `AMmapPutF64`. Rust: `src/doc/map.rs:339-348`.
pub export fn AMmapPutF64(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: f64,
) ?*AMresult {
    return mapPut(doc, obj_id, key, .{ .float = value });
}

/// `AMmapPutObject`. Rust: `src/doc/map.rs:303-317`.
///
/// **One item, not three.** `to_result((doc.put_object(..), key, obj_type))`
/// (`src/doc/map.rs:312-316`) reaches
/// `From<(Result<am::ObjId, _>, &str, am::ObjType)>`
/// (`src/result.rs:201-214`), which is
/// `AMitem::indexed(AMindex::Key(key), obj_id, am::Value::Object(obj_type))`:
/// the key rides along as the item's **index**, the new object's id as its
/// **object id**, and the type as its **value** — one item carrying all three.
pub export fn AMmapPutObject(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    obj_type: AMobjType,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const t = toObjType(obj_type) catch |e| return failWith(c_alloc, e);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const k = spanStr(key) catch |e| return failWith(c_alloc, e);
    const made = txPutObject(d, obj, .{ .key = k }, t) catch |e| return failWith(c_alloc, e);
    var made_id = objIdOfEx(c_alloc, d, made) catch |e| return failWith(c_alloc, e);
    const index = AMindex.ofKey(c_alloc, k) catch |e| {
        made_id.deinit();
        return failWith(c_alloc, e);
    };
    return boxItem(c_alloc, indexedItem(c_alloc, index, made_id, .{ .object = t }) catch |e| {
        return failWith(c_alloc, e);
    }) catch |e| failWith(c_alloc, e);
}

/// `AMmapPutInt`. Rust: `src/doc/map.rs:370-379`.
pub export fn AMmapPutInt(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: i64,
) ?*AMresult {
    return mapPut(doc, obj_id, key, .{ .int = value });
}

/// `AMmapPutStr`. Rust: `src/doc/map.rs:401-409`.
pub export fn AMmapPutStr(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: AMbyteSpan,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const k = spanStr(key) catch |e| return failWith(c_alloc, e);
    const v = spanStr(value) catch |e| return failWith(c_alloc, e);
    const owned = c_alloc.dupe(u8, v) catch |e| return failWith(c_alloc, e);
    errdefer c_alloc.free(owned);
    _ = txPut(d, obj, .{ .key = k }, .{ .str = owned }) catch |e|
        return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMmapPutTimestamp`. Rust: `src/doc/map.rs:432-441`.
pub export fn AMmapPutTimestamp(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: i64,
) ?*AMresult {
    return mapPut(doc, obj_id, key, .{ .timestamp = value });
}

/// `AMmapPutUint`. Rust: `src/doc/map.rs:463-472`.
pub export fn AMmapPutUint(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    key: AMbyteSpan,
    value: u64,
) ?*AMresult {
    return mapPut(doc, obj_id, key, .{ .uint = value });
}

/// `AMmapRange`. Rust: `src/doc/map.rs:500-556`.
///
/// The four bounds arms are the reference's (`src/doc/map.rs:518-554`): both
/// keys, a start only, an end only, or neither.
///
/// **The bounds are `Included(begin)..Excluded(end)`, the half-open
/// `begin..end` the reference builds** (`src/doc/map.rs:524`), and the header
/// says so: `end` is "The key one past the last key in a subrange"
/// (`src/doc/map.rs:482-483`) and there is no entry for an inclusive end.
///
/// Earlier revisions had two problems, both now fixed. `OpSet.mapRange`
/// reached only upstream's two `Included` arms (`op_set2/op_set.rs:408`,
/// `:414`), so `["b","d")` answered `b c d` where `b c` is right; it now
/// takes the bound kind per end (`?KeyBound`, `op_set.zig:2647-2652`) and
/// reaches all four. And a private `read.keyRows` duplicated the same
/// arithmetic for `read.mapRange`; that is deleted, `read.mapRange`
/// delegates to [`OpSet.mapRange`](../opset/op_set.zig) again, and there is
/// one implementation of the four arms rather than three.
///
/// **This function does not go through `read.mapRange`**, and the reason is
/// the clock, not the bounds. `read.mapRange` hardcodes a null clock; this
/// one has a `heads` argument. The clock is not part of the bound arithmetic
/// anywhere — upstream computes all four arms from `key_str` and `obj_range`
/// and passes the clock only to `MapRange::new` on its last line
/// (`op_set2/op_set.rs:396-419`) — so it must not be threaded into them here
/// either, or this would compute bounds the reference does not compute.
///
/// The bounds themselves are [`OpSet.mapRange`](../opset/op_set.zig)'s, over
/// `opsetmod.KeyBound` values, and the clock still goes to `MapRange::init`
/// here — which is what the reference does per arm
/// (`src/doc/map.rs:525-529`, `:533-537`, `:541-545`, `:549-553`). The
/// asymmetry is upstream's and it is the whole difference: `Excluded(end)`
/// is the register's `.start` (`op_set.rs:415`), one register back from
/// `Included(end)`'s `.end` (`:414`).
///
/// **The `begin > end` refusal below and the emptiness `@max` inside
/// `OpSet.mapRange` are both kept, and neither is duplication.** The
/// reference validates the range in this layer and not in `OpSet::map_range`
/// ([`src/doc/map.rs:521-523`](../../github-automerge-automerge/rust/automerge-c/src/doc/map.rs));
/// the `@max` is a Rust `Range` carrying no rows
/// ([`map_range.rs:204-208`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)).
/// A `begin` past its `end` is the reference's `Invalid range [begin-end)`.
///
pub export fn AMmapRange(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    begin: AMbyteSpan,
    end: AMbyteSpan,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const lo = if (begin.src == null) null else spanStr(begin) catch |e| return failWith(c_alloc, e);
    const hi = if (end.src == null) null else spanStr(end) catch |e| return failWith(c_alloc, e);
    if (lo != null and hi != null and std.mem.order(u8, lo.?, hi.?) == .gt) {
        return failWith(c_alloc, error.InvalidRange);
    }
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    // The four arms, from the one implementation that has all four.
    const set = mutableOps(d);
    const rows = set.mapRange(
        obj,
        if (lo) |k| opsetmod.KeyBound{ .included = k } else null,
        if (hi) |k| opsetmod.KeyBound{ .excluded = k } else null,
    ) catch |e| return failWith(c_alloc, e);
    var walk = itermap.MapRange(opmod.ChangeOp).init(mutableOps(d), rows, clock) catch |e|
        return failWith(c_alloc, e);
    // A register's item **carries its key as its index and its row's id as
    // its object id** — that is what `AMitemKey` and `AMitemObjId` report, and
    // it is `AMitem::indexed(AMindex::Key(item.key), item.id(), value)`
    // (`src/result.rs:113-127`). `MapRangeItem` exposes the key as `key` and
    // the id through `id()` (`map_range.rs:15`, `:26-28`).
    var items: std.ArrayList(Item) = .empty;
    errdefer dropItems(c_alloc, &items);
    while (walk.next() catch |e| {
        dropItems(c_alloc, &items);
        return failWith(c_alloc, e);
    }) |entry| {
        var row = objIdOfEx(c_alloc, d, entry.id()) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
        const index = AMindex.ofKey(c_alloc, entry.key) catch |e| {
            row.deinit();
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
        const built = indexedItem(c_alloc, index, row, entry.value) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
        pushItem(c_alloc, &items, built) catch |e| {
            dropItems(c_alloc, &items);
            return failWith(c_alloc, e);
        };
    }
    defer items.deinit(c_alloc);
    return boxItems(c_alloc, items.items) catch |e| failWith(c_alloc, e);
}

// ---------------------------------------------------------------------------
// Marks. Rust: src/doc/mark.rs.
// ---------------------------------------------------------------------------

/// `AMmarkName`. Rust: `src/doc/mark.rs:109-114`.
///
/// **A null handle is the zero span** (`:113`). The span **borrows the mark's
/// name**, which borrows the document (`marks.rs:28-33`), and that is the
/// reference's lifetime too.
pub export fn AMmarkName(mark: ?*const AMmark) AMbyteSpan {
    const m = mark orelse return .empty;
    return AMbyteSpan.of(m.name);
}

/// `AMmarkValue`. Rust: `src/doc/mark.rs:129-134`.
///
/// **A null handle is `AMresult::error("invalid mark")`** — lower-case `i` and no
/// backticks, which is the reference's own string (`:132`) and is reproduced
/// exactly. A mark with a null value is a `VOID` item, from
/// `to_result(Option<&ScalarValue>)` over `AMitem::default()`
/// (`src/item.rs:1050-1058`).
pub export fn AMmarkValue(mark: ?*const AMmark) ?*AMresult {
    const m = mark orelse return boxErrorNamed(c_alloc, "invalid mark");
    return boxOne(c_alloc, ownedOfRef(c_alloc, .{ .scalar = m.value }) catch |e|
        return failWith(c_alloc, e)) catch |e| failWith(c_alloc, e);
}

/// `AMmarkStart`. Rust: `src/doc/mark.rs:148-153`.
///
/// **A null handle is `0`** (`:152`).
pub export fn AMmarkStart(mark: ?*const AMmark) usize {
    const m = mark orelse return 0;
    return m.start;
}

/// `AMmarkEnd`. Rust: `src/doc/mark.rs:167-172`.
///
/// **A null handle is `SIZE_MAX`** (`:171`).
pub export fn AMmarkEnd(mark: ?*const AMmark) usize {
    const m = mark orelse return std.math.maxInt(usize);
    return m.end;
}

/// `AMmarks`. Rust: `src/doc/mark.rs:193-207`.
///
/// One `AM_VAL_TYPE_MARK` item per run, each carrying the mark's name and value
/// and its own `[start, end)`.
///
/// **`heads` is answered, and it was refused here until an hour ago.** The
/// refusal was justified by "[the port's mark fold] takes **no clock**, and
/// [`Document.marks`](../doc.zig) is its only caller, so a historical mark fold
/// would have to be written a second time". **Both halves were false, and they
/// were falsified by a change that had already landed:**
/// [`OpSet.calculateMarksAt`](../opset/op_set.zig) exists and holds upstream's
/// whole dispatch — the two indexes for the present, the object's rows as a
/// clock sees them for anything else (`automerge.rs`:1569-1596, `:1585`) — and
/// [`Document.marks`](../doc.zig) is one of its callers rather than the only
/// one. **What was unreachable from one door was being reported as
/// impossible**, and a reader of the old comment would have concluded a
/// capability was missing when it was merely not wired to this door.
///
/// **Upstream's shape is the two arms** — `match heads.as_ref() { None =>
/// doc.marks(obj_id), Some(heads) => doc.marks_at(obj_id, &heads) }`
/// (`src/doc/mark.rs:200-206`) — and this is that match, not a translation of
/// it: [`clockFromItems`] turns the items into the clock and
/// `calculateMarksAt` picks the arm. **A non-null but empty `AMitems` is an
/// empty clock, not the present**, for the reason [`clockFromItems`] gives;
/// upstream's `heads.as_ref()` is `Some` for any non-null pointer
/// (`src/doc.rs:466-470`).
///
/// **What a C consumer observes changes, and this is the compatibility note.**
/// `AMmarks(doc, obj, non-NULL heads)` used to return an `AM_STATUS_ERROR`
/// result whose message is the `@errorName` of the refusal,
/// `HistoricalMarksUnsupported`; it now returns `AM_STATUS_OK` and the runs
/// those heads see. **No symbol, type, header line or enumerator changes** —
/// `include/automerge.h:991` declared the parameter all along, and upstream's
/// own `AMmarks` answers it — but a caller that tested the result's status to
/// detect the refusal will now take its success branch instead. Nothing in the
/// reference's cmocka suite matches on that message, and the ported copy of it
/// does not either: [`test/c/suite/mark_tests.c`] calls `AMmarks` with `NULL`
/// `heads` only (`:45-46` and `:100-101`), as does
/// [`test/c/suite/item_tests.c`](:210-211).
pub export fn AMmarks(
    doc: ?*const AMdoc,
    obj_id: ?*const AMobjId,
    heads: ?*const AMitems,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    // `:200-206` — the same two lines every other `*_at` entry point here runs.
    var clock = clockFromItems(c_alloc, d, heads) catch |e| return failWith(c_alloc, e);
    defer if (clock) |*c| c.deinit();
    const marks = mutableOps(d).calculateMarksAt(c_alloc, obj, clock) catch |e|
        return failWith(c_alloc, e);
    var values: std.ArrayList(Value) = .empty;
    errdefer values.deinit(c_alloc);
    for (marks) |m| {
        values.append(c_alloc, .{ .mark = .{
            .start = m.start,
            .end = m.end,
            .name = m.name,
            .value = m.value,
        } }) catch |e| return failWith(c_alloc, e);
    }
    defer values.deinit(c_alloc);
    return boxValues(c_alloc, values.items) catch |e| failWith(c_alloc, e);
}

/// `AMmarkCreate`. Rust: `src/doc/mark.rs:236-257`.
///
/// **A null `value` item is an error result**, where the reference is
/// `value.as_ref().unwrap()` (`:249`) — an unwrap on a C-supplied pointer.
/// The item must hold a scalar, which is `<&am::ScalarValue>::try_from(item)`
/// (`:250`).
pub export fn AMmarkCreate(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    start: usize,
    end: usize,
    expand: AMmarkExpand,
    name: AMbyteSpan,
    value: ?*const AMitem,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const how = toExpandMark(expand) catch |e| return failWith(c_alloc, e);
    const mark_name = spanStr(name) catch |e| return failWith(c_alloc, e);
    const item = value orelse return boxErrorNamed(c_alloc, "Invalid `AMitem*`");
    const scalar = scalarOf(item.get()) orelse return failWith(c_alloc, error.InvalidValueType);
    txMark(d, obj, start, end, mark_name, how, scalar) catch |e|
        return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// `AMmarkClear`. Rust: `src/doc/mark.rs:283-296`.
pub export fn AMmarkClear(
    doc: ?*AMdoc,
    obj_id: ?*const AMobjId,
    start: usize,
    end: usize,
    expand: AMmarkExpand,
    name: AMbyteSpan,
) ?*AMresult {
    const d = doc orelse return invalidDoc(c_alloc);
    const obj = objIdOf(d, obj_id) catch |e| return failWith(c_alloc, e);
    const how = toExpandMark(expand) catch |e| return failWith(c_alloc, e);
    const mark_name = spanStr(name) catch |e| return failWith(c_alloc, e);
    txUnmark(d, obj, start, end, how, mark_name, null) catch |e|
        return failWith(c_alloc, e);
    return boxVoid(c_alloc) catch |e| failWith(c_alloc, e);
}

/// A list of already-built items as a result. The shape of
/// `Self::items(items.collect())` for a list the caller assembled itself, which
/// is every `Vec<(am::Value<'static>, am::ObjId)>` in the reference
/// (`src/result.rs:382-390`).
pub fn boxItems(alloc: Allocator, items: []const Item) !*AMresult {
    var list: std.ArrayList(AMitem) = .empty;
    errdefer {
        for (list.items) |owned| owned.deinit(alloc);
        list.deinit(alloc);
    }
    for (items) |item| try list.append(alloc, try AMitem.create(alloc, item));
    return (AMresult.initItems(alloc, list)).toOwned(alloc);
}

/// `impl From<Vec<am::ChangeHash>> for AMresult` (Rust: `src/result.rs:433-446`).
pub fn boxHashes(alloc: Allocator, hashes: []const ChangeHash) !*AMresult {
    var values: std.ArrayList(Value) = .empty;
    errdefer values.deinit(alloc);
    for (hashes) |h| try values.append(alloc, .{ .change_hash = h });
    defer values.deinit(alloc);
    return try boxValues(alloc, values.items);
}

/// `impl From<Vec<am::sync::Have>> for AMresult` (Rust: `src/result.rs:417-431`).
pub fn boxHaves(alloc: Allocator, haves: []const statemod.Have) !*AMresult {
    var values: std.ArrayList(Value) = .empty;
    errdefer values.deinit(alloc);
    for (haves) |h| try values.append(alloc, .{
        .sync_have = syncmod.AMsyncHave.init(alloc, try dupHave(alloc, h)),
    });
    defer values.deinit(alloc);
    return try boxValues(alloc, values.items);
}

/// A deep copy of a `Have`. `to_result(haves.as_slice())` takes
/// `haves.iter().map(|have| have.clone().into())` (`src/result.rs:420-425`), so
/// every item owns its own filter and its own `last_sync` list.
fn dupHave(alloc: Allocator, have: statemod.Have) !statemod.Have {
    const last = try alloc.dupe(ChangeHash, have.last_sync);
    errdefer alloc.free(last);
    const bits = try have.bloom.toBytes(alloc);
    defer alloc.free(bits);
    const filter = try bloommod.BloomFilter.parse(alloc, bits);
    return .{ .gpa = alloc, .last_sync = last, .bloom = filter };
}

/// `impl From<Vec<u8>> for AMresult` (Rust: `src/result.rs:406-415`): **one**
/// `AM_VAL_TYPE_BYTES` item, not one item per byte.
pub fn valueBytes(alloc: Allocator, owned: []u8) !Value {
    _ = alloc;
    return .{ .value = ownedScalar(.{ .bytes = owned }) };
}

/// `impl From<String> for Value` (Rust: `src/item.rs:213-219`): an owned
/// `AM_VAL_TYPE_STR` value.
pub fn valueStr(alloc: Allocator, owned: []u8) !Value {
    _ = alloc;
    return .{ .value = ownedScalar(.{ .str = owned }) };
}

/// An `AM_VAL_TYPE_UINT` value. `am::Value::uint` (`src/item.rs:1560-1562`).
fn valueUint(value: u64) Value {
    return .{ .value = ownedScalar(.{ .uint = value }) };
}

/// An `AM_VAL_TYPE_INT` value. `am::Value::int` (`src/item.rs:1506-1508`).
fn valueInt(value: i64) Value {
    return .{ .value = ownedScalar(.{ .int = value }) };
}

/// Wraps a `ScalarValue` whose byte-bearing payloads the caller already owns.
/// A borrowed payload would dangle the moment the item it came from is freed,
/// so this is only ever called with bytes this module allocated. Upstream's
/// equivalent is `Cow::Owned(value.clone())` (`src/item.rs:171-175`).
fn ownedScalar(scalar: ScalarValue) optypes.OwnedValueRef {
    return .{ .value = .{ .scalar = scalar } };
}

// ---------------------------------------------------------------------------
// Tests.
//
// Three boundary behaviours a C caller can see and a reader cannot check by
// reading: a refusal must reach C as its *own* error result, an owned buffer
// must come back exactly once, and a borrowed buffer must not come back at all.
// The rest are regressions for the two defects this section's neighbours fix,
// and one read-path walk, because the read half of this ABI was never executed
// and a surface that has only been compiled has proven nothing.
// ---------------------------------------------------------------------------

/// Not `t`, which eight bodies above already use as a local name.
const testing = std.testing;

/// `std.testing.allocator` with a free counter, so a test can ask about **one
/// buffer** rather than about the allocator as a whole. "The allocator is
/// empty at the end" cannot tell a leak from a double free: a double free is
/// not a leftover, and a leak of one buffer hides behind another being freed.
const Counting = struct {
    inner: Allocator,
    /// Frees of exactly `watch` bytes, which is how a test names the buffer it
    /// is asking about.
    watch: usize,
    /// How many times a `watch`-sized buffer was freed. `0` is a leak and `2` is
    /// a double free; `1` is the answer.
    freed: usize = 0,

    fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &counting_vtable };
    }
};

const counting_vtable: Allocator.VTable = .{
    .alloc = countingAlloc,
    .resize = countingResize,
    .remap = countingRemap,
    .free = countingFree,
};

fn countingAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Counting = @ptrCast(@alignCast(ctx));
    return self.inner.rawAlloc(len, alignment, ret_addr);
}

fn countingResize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    const self: *Counting = @ptrCast(@alignCast(ctx));
    return self.inner.rawResize(memory, alignment, new_len, ret_addr);
}

fn countingRemap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    const self: *Counting = @ptrCast(@alignCast(ctx));
    return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
}

fn countingFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Counting = @ptrCast(@alignCast(ctx));
    if (memory.len == self.watch) self.freed += 1;
    self.inner.rawFree(memory, alignment, ret_addr);
}

/// Frees a boxed result exactly as `AMresultFree` does — `AMstack.destroy`
/// (Rust: `src/result.rs:557-562`).
fn dropResult(alloc: Allocator, r: *AMresult) void {
    r.deinit();
    alloc.destroy(r);
}

/// The `AM_VAL_TYPE_UINT` a successful result carries, read the way a C caller
/// reads it (`AMitemToUint`, `src/item.rs:2113-2126`). **The message is the
/// label**, so an error result refuses here rather than answering `0` — which
/// is the whole of what makes an assertion on it a claim.
fn resultUint(r: *AMresult) !u64 {
    if (AMresult.status(r) != .ok) return error.NotAValue;
    const item = AMresult.item(r) orelse return error.NotAValue;
    var out: u64 = 0;
    if (!AMitemToUint(item, &out)) return error.NotAValue;
    return out;
}

test "a refusal reaches C as its own error result, and two refusals are not one" {
    const not_an_object = failWith(testing.allocator, error.NotAnObject) orelse
        return error.Unexpected;
    defer dropResult(testing.allocator, not_an_object);
    try testing.expectEqual(AMstatus.error_, AMresult.status(not_an_object));
    try testing.expectEqualStrings("NotAnObject", AMresult.errorMessage(not_an_object).slice());
    try testing.expectEqual(@as(usize, 0), AMresult.size(not_an_object));

    const bad_index = failWith(testing.allocator, error.InvalidIndex) orelse
        return error.Unexpected;
    defer dropResult(testing.allocator, bad_index);
    try testing.expectEqual(AMstatus.error_, AMresult.status(bad_index));
    try testing.expectEqualStrings("InvalidIndex", AMresult.errorMessage(bad_index).slice());

    // A message the reference **hard-codes** is reproduced verbatim, backtick
    // and all, and is not an `@errorName` of anything here — the two families
    // are distinguishable, which is what lets a C caller match on one
    // (`src/result.rs:513-521`).
    const invalid_doc = invalidDoc(testing.allocator) orelse return error.Unexpected;
    defer dropResult(testing.allocator, invalid_doc);
    try testing.expectEqualStrings("Invalid `AMdoc*`", AMresult.errorMessage(invalid_doc).slice());

    // A null result is the one status that means "you passed NULL", and it is
    // not any of the three above (`src/result.rs:640-652`).
    try testing.expectEqual(AMstatus.invalid_result, AMresult.status(null));
    try testing.expectEqual(@as(usize, 0), AMresult.size(null));
}

test "an owned buffer is freed exactly once, by the result that owns it" {
    var c = Counting{ .inner = testing.allocator, .watch = "owned bytes".len };
    const alloc = c.allocator();
    const payload = try alloc.dupe(u8, "owned bytes");
    const r = try boxOne(alloc, try valueBytes(alloc, payload));

    // Nothing is freed before the caller frees the result: the item owns the
    // buffer and only the result owns the item.
    try testing.expectEqual(@as(usize, 0), c.freed);
    dropResult(alloc, r);
    try testing.expectEqual(@as(usize, 1), c.freed);
}

test "two results over one item share it, and its buffer comes back once" {
    var c = Counting{ .inner = testing.allocator, .watch = "owned bytes".len };
    const alloc = c.allocator();
    const payload = try alloc.dupe(u8, "owned bytes");
    const first = try boxOne(alloc, try valueBytes(alloc, payload));
    const item = AMresult.item(first) orelse return error.Unexpected;

    // `AMitemResult` is `AMresult::item(item.clone())` (Rust: `src/item.rs:1693`):
    // the `Rc` count goes up and the bytes are **not** copied. Copying the
    // `Item` struct instead would give two owners of one buffer.
    const shared = item.retain();
    var held = AMresult.initItem(alloc, shared) catch |e| {
        shared.deinit(alloc);
        return e;
    };
    errdefer held.deinit();
    const second = held.toOwned(alloc) catch |e| return e;
    try testing.expectEqual(@as(usize, 2), item.refCount());

    dropResult(alloc, first);
    // The payload is still owned: the second result is holding it.
    try testing.expectEqual(@as(usize, 0), c.freed);
    dropResult(alloc, second);
    try testing.expectEqual(@as(usize, 1), c.freed);
}

test "a borrowed span is not freed by the callee" {
    var c = Counting{ .inner = testing.allocator, .watch = "borrowed".len };
    const alloc = c.allocator();
    // The caller's buffer. Every `to_str!` caller hands this straight to the
    // callee and the callee never frees it (`src/byte_span.rs:25-35`).
    const caller_buf: [8]u8 = "borrowed".*;
    const span = AMbyteSpan.of(&caller_buf);

    // The validating reader hands the same bytes back.
    try testing.expectEqualStrings("borrowed", try spanStr(span));
    try testing.expectEqual(@as(usize, 0), c.freed);

    // The copying reader — the item has to own its bytes, so it copies them,
    // and the caller's buffer is neither freed nor changed.
    const copied = try spanBytes(alloc, span);
    try testing.expectEqualStrings("borrowed", copied);
    try testing.expectEqual(@as(usize, 0), c.freed);
    try testing.expectEqualStrings("borrowed", &caller_buf);

    // Releasing the copy is the caller's act and the caller's alone.
    alloc.free(copied);
    try testing.expectEqual(@as(usize, 1), c.freed);
    try testing.expectEqualStrings("borrowed", &caller_buf);
}

test "a handle taken out of an item points into the item's own allocation" {
    // The regression. `switch (v) { .doc => |*d| … }` on a `const` local `v`
    // binds `d` to the local, so the handle was a pointer into the callee's
    // dead frame and every mutating entry point faulted on the next call.
    const r = try docResult(
        testing.allocator,
        AMdoc{ .doc = try docmod.Document.init(testing.allocator, .auto) },
    );
    defer dropResult(testing.allocator, r);
    const item = AMresult.item(r) orelse return error.Unexpected;
    try testing.expectEqual(@as(usize, 1), item.refCount());

    const cell = valueCellMut(item.getMut() orelse return error.Unexpected) orelse
        return error.Unexpected;
    try testing.expectEqual(@intFromPtr(&item.get().value.?), @intFromPtr(cell));

    // The export itself, and the address it hands out.
    var out: ?*AMdoc = null;
    try testing.expect(AMitemToDoc(item, &out));
    const base = @intFromPtr(item.rc);
    const got = @intFromPtr(out orelse return error.Unexpected);
    try testing.expect(got >= base and got < base + @sizeOf(RcItem));
}

test "AMmapGet answers one indexed item, and a VOID one when the register is empty" {
    // **An `AMdoc` owns its `Document` by value** (`AMdoc.doc`, `:257`), so a
    // test that needs both surfaces takes the document through the handle and
    // reaches the library through `amdoc.doc`. There is no `AMdocFree`
    // (`:251-254`) — a result item owns one, and this one is on the stack.
    var amdoc = AMdoc{ .doc = try docmod.Document.init(testing.allocator, .auto) };
    defer amdoc.deinit();
    const doc = &amdoc.doc;
    _ = try transact.put(doc, .root, .{ .key = "k" }, .{ .str = "v" });

    const hit = try mapGetResult(
        testing.allocator,
        (try getAt(&amdoc, .root, .{ .key = "k" }, null)).?,
        &amdoc,
        "k",
    );
    defer dropResult(testing.allocator, hit);
    // `From<(Result<Option<(Value, ObjId)>>, &str)>` is **one** item
    // (`src/result.rs:258-280`): the key as its index, the row's id as its
    // object id, the value as its value.
    try testing.expectEqual(@as(usize, 1), AMresult.size(hit));
    const hi = AMresult.item(hit).?;
    try testing.expectEqual(AMvalType.AM_VAL_TYPE_STR, hi.get().valType());
    try testing.expectEqual(AMidxType.AM_IDX_TYPE_KEY, hi.get().idxType());
    try testing.expectEqualStrings("k", hi.get().index.?.keySlice() orelse
        return error.Unexpected);
    try testing.expect(hi.get().obj_id != null);
    var text: AMbyteSpan = .empty;
    try testing.expect(AMitemToStr(hi, &text));
    try testing.expectEqualStrings("v", text.slice());

    // The empty register is `AMitem::default()` (`src/result.rs:272`): a VOID
    // item with neither an index nor an object id.
    const missing = try mapGetResult(
        testing.allocator,
        try getAt(&amdoc, .root, .{ .key = "absent" }, null),
        &amdoc,
        "absent",
    );
    defer dropResult(testing.allocator, missing);
    try testing.expectEqual(@as(usize, 1), AMresult.size(missing));
    const mi = AMresult.item(missing).?;
    try testing.expectEqual(AMvalType.AM_VAL_TYPE_VOID, mi.get().valType());
    try testing.expectEqual(AMidxType.AM_IDX_TYPE_DEFAULT, mi.get().idxType());
    try testing.expect(mi.get().obj_id == null);
}

test "AMsplice reads the scalars out of the items it was handed" {
    // `ownedOf` is the reader behind `AMsplice`, and it returned a pointer
    // into its own frame, so every splice read a dead stack slot.
    var values: std.ArrayList(Value) = .empty;
    errdefer {
        for (values.items) |*v| v.deinit(testing.allocator);
        values.deinit(testing.allocator);
    }
    try values.append(testing.allocator, valueInt(7));
    try values.append(testing.allocator, try valueStrOwned(testing.allocator, "hi"));
    const r = try boxValues(testing.allocator, values.items);
    defer dropResult(testing.allocator, r);
    // The items own the values now; only this list's own array is ours.
    values.deinit(testing.allocator);

    var owners: std.ArrayList(optypes.OwnedValueRef) = .empty;
    defer {
        for (owners.items) |*o| o.deinit(testing.allocator);
        owners.deinit(testing.allocator);
    }
    const spliced = try spliceValues(testing.allocator, abi.AMresultItems(r), &owners);
    defer testing.allocator.free(spliced);

    try testing.expectEqual(@as(usize, 2), owners.items.len);
    try testing.expectEqual(@as(usize, 2), spliced.len);
    switch (spliced[0]) {
        .int => |n| try testing.expectEqual(@as(i64, 7), n),
        else => return error.Unexpected,
    }
    switch (spliced[1]) {
        .str => |s| try testing.expectEqualStrings("hi", s),
        else => return error.Unexpected,
    }
}

test "the read surface answers for a document that has been written" {
    var amdoc = AMdoc{ .doc = try docmod.Document.init(testing.allocator, .auto) };
    defer amdoc.deinit();
    const doc = &amdoc.doc;
    // The root is a **map**, so the two sub-objects go in by key; an index on
    // the root is `InvalidOp`, not a second list.
    const list_obj = try transact.putObject(doc, .root, .{ .key = "list" }, .list);
    const text_obj = try transact.putObject(doc, .root, .{ .key = "text" }, .text);
    _ = try transact.put(doc, .root, .{ .key = "name" }, .{ .str = "v" });
    // The list starts empty, so its two elements are **inserted**: a `put` at
    // index 0 of an empty list is out of bounds, which is the reference's
    // answer too.
    _ = try transact.insert(doc, list_obj, 0, .{ .int = 1 });
    _ = try transact.insert(doc, list_obj, 1, .{ .int = 2 });
    try transact.spliceText(doc, text_obj, 0, 0, "hi");

    const set = mutableOps(&amdoc);
    try testing.expectEqual(ObjType.list, try doc.objectType(list_obj));
    try testing.expectEqual(ObjType.text, try doc.objectType(text_obj));
    try testing.expectEqual(@as(usize, 2), try set.seqLength(list_obj, doc.textEncoding(), null));
    try testing.expectEqual(@as(usize, 3), try set.seqLength(.root, doc.textEncoding(), null));

    // `AMtext`'s read, and every read again at the document's own heads, which
    // is the `heads != NULL` arm the `*_at` entry points take.
    const text = try set.text(testing.allocator, text_obj, null);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hi", text);

    const heads = try doc.getHeads(testing.allocator);
    defer testing.allocator.free(heads);
    try testing.expectEqual(@as(usize, 1), heads.len);
    var clock = try doc.graph.clockAt(testing.allocator, heads);
    defer clock.deinit();
    const past = try getAt(&amdoc, .root, .{ .key = "name" }, clock);
    try testing.expectEqualStrings("v", (past.?).value.scalar.str);

    // `AMlistRange`'s walk: one element per position, in order.
    var walk = try iterlist.ListRange(opmod.ChangeOp).init(
        set,
        try set.listRange(list_obj),
        clock,
        .{ .start = 0, .end = 2 },
    );
    var seen: usize = 0;
    while (try walk.next()) |entry| {
        try testing.expectEqual(seen, entry.index);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);

    // `AMmapRange`'s walk: the key of every visible register.
    var mwalk = try itermap.MapRange(opmod.ChangeOp).init(
        set,
        try set.mapRange(.root, null, null),
        clock,
    );
    var keys: usize = 0;
    while (try mwalk.next()) |entry| {
        try testing.expect(entry.key.len > 0);
        keys += 1;
    }
    try testing.expectEqual(@as(usize, 3), keys);
}

test "a held transaction and its document share one allocator" {
    // **The invariant, asserted where it is made.** [`transact.Transaction`]
    // owns buffers ([`transact.zig:442-456`](../transact.zig)) and a pending
    // operation's undo log belongs to the op set
    // ([`op.zig:1230-1236`](../opset/op.zig)), so both are freed through
    // `Transaction.gpa` — the document's, by that field's own contract
    // ([`transact.zig:330-332`](../transact.zig)). [`AMdoc.open`] is the one
    // place that used to pass `c_alloc` instead, and the teardown below is
    // what it cost: a `free` of a pointer the allocator had not handed out,
    // and a process that died inside `__free`.
    var amdoc = AMdoc{ .doc = try docmod.Document.init(testing.allocator, .auto) };
    defer amdoc.deinit();

    // **The document is deliberately not on `c_alloc`**, or the equality below
    // would hold for the wrong reason. `std.heap.c_allocator`'s `ptr` is
    // `undefined` — it addresses nothing, because it is `malloc` itself — so
    // the vtable is the field that names it, and that is what differs.
    const doc_alloc = amdoc.allocator();
    try testing.expect(doc_alloc.vtable != c_alloc.vtable);

    // The transaction is opened on it, and a write through it is the part
    // that has to come back: the undo log is the op set's allocation, freed
    // through the transaction's.
    const tx = try amdoc.open();
    try testing.expect(tx.gpa.ptr == doc_alloc.ptr);
    try testing.expect(tx.gpa.vtable == doc_alloc.vtable);
    _ = try tx.putObject(.root, .{ .key = "k" }, .map);
    try testing.expect(amdoc.tx != null);
}

test "a C text index names the character a default-configured reference build names" {
    // **The unit, not the round trip.** A test that indexed into a text object
    // and read back the character it had just written passes under either
    // encoding and says nothing about which one is in force. Every number here
    // is therefore asserted against the **byte offsets** a `rust/automerge-c`
    // built the way its own CMake builds one by default uses:
    // `CMakeLists.txt:45` declares `UTF32_INDEXING` and does not set it, so
    // `:111-117` passes `-F automerge/utf8-indexing`, which is the first arm of
    // `platform_default()` and answers `Utf8CodeUnit`
    // ([`text_value.rs:14-15`](../../github-automerge-automerge/rust/automerge/src/text_value.rs));
    // `README.md:62-63` says it in words. The three assertions are the
    // reference's own numbers, `test/doc_tests.c:280-286` and `:291-304`.
    // **`testing.allocator`, so this test is under the leak arbiter at all.**
    // The exports below open the held transaction ([`AMdoc.open`](src/c/doc.zig)
    // and every `tx*` helper over it), write through it, and leave it open for
    // `defer amdoc.deinit()` — which is the teardown that died inside `__free`
    // while [`AMdoc.open`] handed [`openAutoHeld`](../transact.zig) a
    // hardcoded `c_alloc` and the document had any other allocator. A `c_alloc`
    // document hides that, which is why this line used to be `c_alloc`; it is
    // now the regression test for it, and the results the assertions below
    // read are still the ones a C caller frees with `AMresultFree`.
    var amdoc = AMdoc{ .doc = try docmod.Document.initWithEncoding(
        testing.allocator,
        cTextEncoding(),
        .auto,
    ) };
    defer amdoc.deinit();
    try testing.expectEqual(types.TextEncoding.utf8_code_unit, amdoc.doc.textEncoding());

    const put = AMmapPutObject(&amdoc, null, AMbyteSpan.of("unicode"), .AM_OBJ_TYPE_TEXT);
    const made = put orelse return error.Unexpected;
    defer abi.AMresultFree(made);
    const obj = AMitemObjId(AMresult.item(made) orelse return error.Unexpected) orelse
        return error.Unexpected;

    // "🇬🇧🇩🇪" is **four code points and sixteen bytes**, so the two units
    // disagree about every index above three and about the length.
    const first = AMspliceText(&amdoc, obj, 0, 0, AMbyteSpan.of("🇬🇧🇩🇪"));
    abi.AMresultFree(first orelse return error.Unexpected);
    try testing.expectEqual(@as(usize, 16), AMobjSize(&amdoc, obj, null));

    // Byte 8 is where 🇩🇪 begins and **four bytes is one of its two code
    // points**, so replacing [8, 12) with 🇦 leaves the second regional
    // indicator behind: "🇬🇧🇦🇪", still sixteen bytes. Under code-point
    // indexing the same splice is (2, 1), which is the reference's own UTF-32
    // branch (`test/doc_tests.c:308`) — three different numbers for the same
    // characters is the whole difference between the units.
    const replaced = AMspliceText(&amdoc, obj, 8, 4, AMbyteSpan.of("🇦"));
    abi.AMresultFree(replaced orelse return error.Unexpected);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("🇬🇧🇦🇪", try textInto(&amdoc, obj, buf[0..]));
    try testing.expectEqual(@as(usize, 16), AMobjSize(&amdoc, obj, null));

    // **A byte index cannot land inside a character.** Byte 4 is the second
    // code unit of 🇬🇧's second code point, so deleting one unit from there
    // takes the whole code point with it — "🇬🇦🇪", twelve bytes. This is
    // `test/doc_tests.c:291-297`, and it is the assertion that cannot be
    // satisfied by an encoding measured in code points, where 4 would be one
    // past the end.
    const cut = AMspliceText(&amdoc, obj, 4, 1, AMbyteSpan.of(""));
    abi.AMresultFree(cut orelse return error.Unexpected);
    try testing.expectEqualStrings("🇬🇦🇪", try textInto(&amdoc, obj, buf[0..]));
    try testing.expectEqual(@as(usize, 12), AMobjSize(&amdoc, obj, null));
}

/// `AMtext` and `AMitemToStr`, unwrapped: the two calls a C caller makes to
/// read a text object back, with the result freed on the way out.
///
/// **The bytes are copied into `out` rather than returned, and that is the
/// whole reason this is a function.** `AMtext` copies the text into the
/// result's own item (`boxOne(…, .{ .str = text })`), so the span a C caller
/// reads is a borrow into that item — and `AMresultFree` is a complete
/// destructor ([the module doc](doc.zig)), so the bytes are gone the moment
/// the result is. A helper that returned `span.slice()` would hand back a
/// pointer into freed memory, which is exactly what the first run of this
/// test did: it read four bytes of `\x9a` and reported "found ����".
fn textInto(doc: *const AMdoc, obj: *const AMobjId, out: []u8) ![]const u8 {
    const read = AMtext(doc, obj, null) orelse return error.Unexpected;
    defer abi.AMresultFree(read);
    var span: AMbyteSpan = .empty;
    if (!AMitemToStr(AMresult.item(read) orelse return error.Unexpected, &span)) {
        return error.Unexpected;
    }
    const bytes = span.slice();
    if (bytes.len > out.len) return error.Unexpected;
    @memcpy(out[0..bytes.len], bytes);
    return out[0..bytes.len];
}

/// The sixteen bytes `test/c/abi_coverage.c:73` builds its document's actor
/// from, so a test that names them is naming the reference's own numbers.
const actor16 = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

test "an actor id's hex is two characters per byte, and the span carries that count" {
    // **The length is the contract and the text is the bonus.** `AMActorIdStr`
    // answers `Box<str>::as_bytes()` (`src/actor_id.rs:44-47`) and a
    // `Box<str>` is a `(ptr, len)` pair with **no NUL**, so the only thing
    // that bounds the string is `AMbyteSpan.count`. Every call site in the
    // reference's own suite asserts the count and *then* compares that many
    // bytes — `test/actor_id_tests.c:96-98`, `test/doc_tests.c:247-249`,
    // `test/ported_wasm/basic_tests.c:194-196` — and none of them calls
    // `strlen`, because the value is not a C string.
    const gpa = testing.allocator;
    // **The whole handle, body and all, is what this frees** — see
    // [`destroyActorHandle`]. `handle.deinit()` alone freed the hex cache and
    // left three allocations behind, and this test was the leak report that
    // named them.
    const handle = try newActorHandle(gpa, &actor16);
    defer destroyActorHandle(handle);

    // **The length, asserted before anything is compared.** A hex string that
    // matches character for character and is one character short satisfies
    // every comparison a caller could make with `strncmp` and fails only
    // here, which is why the count is the first assertion and not the last.
    const span = AMbyteSpan.of(handle.toStr());
    try testing.expectEqual(@as(usize, 2 * actor16.len), span.count);
    try testing.expectEqual(actor16.len, AMactorIdBytes(handle).count);
    try testing.expectEqualStrings("000102030405060708090a0b0c0d0e0f", span.slice());

    // **The second read is the cache, not a second encoding**
    // (`hex_str: RefCell<Option<Box<str>>>`, `:19`). The cached slice is
    // keyed on nothing and sized once, so the assertion that matters is that
    // it is the *same* buffer: a handle whose bytes changed under it would
    // answer with the first answer, at the first length.
    try testing.expect(handle.toStr().ptr == span.src.?);
    try testing.expectEqual(@as(usize, 2 * actor16.len), handle.toStr().len);

    // **An empty actor is a zero-length span, not a crash.** `to_hex_string`
    // over no bytes is the empty string (`src/actor_id.rs:43`), and the span
    // says so; a C caller reading `count` bytes reads none.
    const none = try newActorHandle(gpa, &.{});
    defer destroyActorHandle(none);
    try testing.expectEqual(@as(usize, 0), AMbyteSpan.of(none.toStr()).count);
}

test "a change's author is the document's actor, at that actor's own byte length" {
    // **The candidate a hex-length failure leaves open is a 17-byte actor**,
    // so this pins the length where it is made rather than where it is
    // printed. `AMchangeActorId` answers `change.as_ref().actor_id().clone()`
    // (`src/change.rs:107-110`) and [`actorValue`] copies those bytes into the
    // item (`impl From<am::ActorId> for Value`, `src/item.rs:141-145`), so the
    // span a C caller reads is a copy of `Change.actor` and whatever length
    // that is.
    var doc = try docmod.Document.init(testing.allocator, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = &actor16 });
    _ = try transact.put(&doc, .root, .{ .key = "a" }, .{ .str = "b" });

    var changes = try doc.getChanges(testing.allocator, &.{});
    defer changes.deinit(testing.allocator);
    if (changes.items.items.len != 1) return error.Unexpected;
    const author = changes.items.items[0].change.actor;
    // Sixteen bytes in, thirty-two characters out.
    try testing.expectEqualSlices(u8, &actor16, author.bytes);

    // And through the two handles a C caller actually holds.
    var value = try actorValue(testing.allocator, author);
    defer value.deinit(testing.allocator);
    const span = AMbyteSpan.of(value.actor_id.toStr());
    try testing.expectEqual(@as(usize, 2 * author.bytes.len), span.count);
    try testing.expectEqualStrings("000102030405060708090a0b0c0d0e0f", span.slice());
}

test "the hex a handle caches comes back with the handle, exactly once" {
    var c = Counting{ .inner = testing.allocator, .watch = 2 * actor16.len };
    const gpa = c.allocator();
    const handle = try newActorHandle(gpa, &actor16);
    _ = handle.toStr();
    // Nothing is freed before the handle is: the hex lives in the handle.
    try testing.expectEqual(@as(usize, 0), c.freed);
    // **The destructor of the whole handle** ([`destroyActorHandle`]), so the
    // hex comes back **once** *and* the body it borrowed does too. This
    // counter watches one size, so the three other frees are invisible to it —
    // which is why this test passed while leaking a cell, a copy of the
    // actor's bytes and a handle: `std.testing.allocator` is the only thing
    // here that can see a free of another size, and the arbiter caught them.
    destroyActorHandle(handle);
    try testing.expectEqual(@as(usize, 1), c.freed);
}

test "AMgetCursorPosition names a foreign cursor InvalidCursor, and AMgetCursor keeps InvalidIndex" {
    const gpa = testing.allocator;
    var amdoc = AMdoc{ .doc = try docmod.Document.init(gpa, .auto) };
    defer amdoc.deinit();
    const doc = &amdoc.doc;

    // **Two objects, because the question is "a cursor naming a row of *another*
    // one".** Upstream's `seek_list_opid` searches within `obj_meta.id`'s own
    // rows and answers an `Option` (`op_set.rs:837-851`), and
    // `get_cursor_position_for` turns the empty answer into `InvalidCursor`
    // (`automerge.rs:1778-1781`). One object cannot be asked it.
    const here = try transact.putObject(doc, .root, .{ .key = "here" }, .list);
    const there = try transact.putObject(doc, .root, .{ .key = "there" }, .list);
    _ = try transact.insert(doc, here, 0, .{ .int = 1 });
    _ = try transact.insert(doc, there, 0, .{ .int = 2 });

    // The handles a C caller holds. **They are built with `c_alloc`, not the
    // testing allocator**, because [`objIdOfEx`] copies the actor's bytes into a
    // cell it frees itself and `AMobjId` is the one handle whose allocator is
    // part of its contract.
    var here_id = try objIdOfEx(c_alloc, &amdoc, here);
    defer here_id.deinit();
    var there_id = try objIdOfEx(c_alloc, &amdoc, there);
    defer there_id.deinit();

    // The cursor over `here`'s only row, taken through the export a C caller
    // calls, and held in the result that owns it.
    const made = AMgetCursor(&amdoc, &here_id, 0, null) orelse return error.Unexpected;
    defer abi.AMresultFree(made);
    var taken: ?*const AMcursor = null;
    try testing.expect(AMitemToCursor(AMresult.item(made), &taken));
    const cursor = taken orelse return error.Unexpected;

    // **Asked of the object it names, it is an index.**
    const home = AMgetCursorPosition(&amdoc, &here_id, cursor, null) orelse
        return error.Unexpected;
    defer abi.AMresultFree(home);
    try testing.expectEqual(AMstatus.ok, AMresult.status(home));

    // **Asked of another object it is `InvalidCursor`.** Upstream's C ABI has no
    // status for a particular refusal — every one is `AM_STATUS_ERROR` beside a
    // message (`automerge-c/src/result.rs:313-320`) — so **the message is the
    // label**, and this one is upstream's `InvalidCursor` rather than the op
    // set's private `InvalidIndex`. The port answered both before this function
    // went through [`read.getCursorPosition`](../read.zig), so the same cursor
    // got one name from the Zig surface and another from this one.
    const foreign = AMgetCursorPosition(&amdoc, &there_id, cursor, null) orelse
        return error.Unexpected;
    defer abi.AMresultFree(foreign);
    try testing.expectEqual(AMstatus.error_, AMresult.status(foreign));
    try testing.expectEqualStrings("InvalidCursor", AMresult.errorMessage(foreign).slice());

    // **And the past-the-end label is the other question, still
    // `InvalidIndex`.** `get_cursor_for` refuses an index no row answers with
    // `AutomergeError::InvalidIndex` (`automerge.rs:1751-1755`); a cursor naming
    // another object's row never reaches that arm, so moving one label must not
    // have moved the other.
    const past = AMgetCursor(&amdoc, &here_id, 1, null) orelse return error.Unexpected;
    defer abi.AMresultFree(past);
    try testing.expectEqual(AMstatus.error_, AMresult.status(past));
    try testing.expectEqualStrings("InvalidIndex", AMresult.errorMessage(past).slice());
}

test "a cursor minted before an edit resolves at its own heads while a transaction is held open" {
    // **The regression `test/c/suite/ported_wasm/cursor_tests.c:72` is.**
    //
    // **Why this is a test about a cursor rather than about a clock.** A cursor
    // is minted at an index, the text in front of it grows, and the cursor is
    // asked where it got to — at the present, and at the heads it was minted
    // at. The second answer is the interesting one, and it is the one that
    // needs a clock: nothing about the present can be wrong by being the
    // present. **The C test asserts it twice, `index2 == 16` at the present and
    // `index3 == index1` at `heads1`, and it is the second that was failing.**
    //
    // **What makes it fail is the held transaction, and only that.** `AMdoc`
    // is an `AutoCommit` (`src/doc.rs:35-36`), which keeps its transaction open
    // across calls (`autocommit.rs:445-457`); `txSpliceText` is `d.open()` and
    // a splice, and no read closes it — `AMgetCursorPosition` does **not**,
    // upstream's `ReadDoc` method for `AutoCommit` included
    // (`autocommit.rs:996-1004`). So between a write and the next read the
    // operations are already in the op set while the graph's heads are still
    // the previous change's, which is precisely the state upstream's
    // `get_scope` comment names (`autocommit.rs:797-799`): *"pending ops are
    // already in the op set but not yet under the graph's heads"*. The heads
    // asked for therefore **are** the graph's current heads, and
    // `Automerge::clock_at`'s shortcut (`automerge.rs:1242-1243`) answers no
    // clock — an unscoped read of the present, which sees the pending
    // operations. Upstream refuses that shortcut in exactly this state
    // (`autocommit.rs:800-804`).
    //
    // **The document is built on [`testing.allocator`], and that is a second
    // pin of the same defect.** It used to be `c_alloc`, on the reasoning that
    // [`AMdoc.open`] opened the held transaction with `c_alloc` and a
    // transaction's bytes and the op set's had to come from one allocator —
    // which was true and unfixable, so the test paid for it by not being under
    // the leak check. [`AMdoc.open`] opens on the document's own allocator
    // now, so this test drives a **held** transaction over the exports *and*
    // the arbiter, and the C ABI's own allocator is still what the reference's
    // cmocka suite uses at runtime.
    const gpa = testing.allocator;
    var amdoc = AMdoc{ .doc = try docmod.Document.initWithEncoding(gpa, cTextEncoding(), .auto) };
    defer amdoc.deinit();
    amdoc.setActorId(.{ .bytes = "0123456789abcdef" });
    const doc = &amdoc.doc;

    // One text element holding the whole string, as upstream's fixture has it.
    const text = try transact.putObject(doc, .root, .{ .key = "text" }, .text);
    try transact.spliceText(doc, text, 0, 0, "the sly fox jumped over the lazy dog");

    // The heads the cursor is about to be minted at, through the export a C
    // caller calls, and the `AMitems` over the result that owns them.
    const heads_res = AMgetHeads(&amdoc) orelse return error.Unexpected;
    defer abi.AMresultFree(heads_res);
    try testing.expectEqual(@as(usize, 1), AMresult.size(heads_res));
    var heads1 = abi.AMresultItems(heads_res);

    var text_id = try objIdOfEx(gpa, &amdoc, text);
    defer text_id.deinit();

    const made = AMgetCursor(&amdoc, &text_id, 12, null) orelse return error.Unexpected;
    defer abi.AMresultFree(made);
    var slot: ?*const AMcursor = null;
    try testing.expect(AMitemToCursor(AMresult.item(made), &slot));
    const cursor = slot orelse return error.Unexpected;

    // **At the heads it was minted at, the cursor is where it was taken** —
    // the round trip, before anything has moved.
    const at_birth = AMgetCursorPosition(&amdoc, &text_id, cursor, &heads1) orelse
        return error.Unexpected;
    defer abi.AMresultFree(at_birth);
    try testing.expectEqual(@as(u64, 12), try resultUint(at_birth));

    // **The held transaction.** Nothing is committed, so the graph's heads are
    // still `heads1`'s while these operations are already in the op set.
    try (try amdoc.open()).spliceText(text, 0, 3, "Has the");
    try testing.expect(amdoc.tx != null);

    // **At the present the cursor has moved with the text in front of it** —
    // three characters replaced by seven, so `+4`. This is the assertion that
    // was already green, and it is here so that a change which broke the
    // present would be told apart from one that broke the historical read.
    const now = AMgetCursorPosition(&amdoc, &text_id, cursor, null) orelse
        return error.Unexpected;
    defer abi.AMresultFree(now);
    try testing.expectEqual(@as(u64, 16), try resultUint(now));

    // **And at `heads1` it has not.** This is the assertion that was red: with
    // no guard, `heads1` reads as the present's own heads, the shortcut answers
    // no clock, and this number is `16`.
    const then = AMgetCursorPosition(&amdoc, &text_id, cursor, &heads1) orelse
        return error.Unexpected;
    defer abi.AMresultFree(then);
    try testing.expectEqual(@as(u64, 12), try resultUint(then));

    // The transaction is committed rather than dropped, so the document the
    // [`deinit`] above tears down is one a real caller would have left behind.
    try amdoc.close();
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`Value.actor_id` leaked the actor cell it owns.** Upstream's
//   `AMactorId` is a `*const am::ActorId` **borrow**
//   ([`src/actor_id.rs:26-29`](../../github-automerge-automerge/rust/automerge-c/src/actor_id.rs))
//   and so has no destructor to free it in; this port's `body` is a heap cell
//   [`actorValue] allocated, and it copies the bytes into it. Every
//   `AM_VAL_TYPE_ACTOR_ID` result — `AMactorIdInit`, `AMActorIdFromBytes`,
//   `AMActorIdFromStr`, `AMchangeActorId`, `AMgetActorId` — therefore dropped
//   a cell and a copy of the actor's bytes on `AMresultFree`. [`Value.deinit`]
//   now frees it, and reads `body` and `gpa` out **before**
//   [`AMactorId.deinit`] runs, for the reason [`AMobjId.deinit`] gives: that
//   call writes `undefined` over the cell, so either field read afterwards is
//   whatever the allocator left there.
//
// * **`AMActorIdStr`'s span is not a C string, and its length is the whole
//   contract.** The span borrows `Box<str>::as_bytes()`
//   ([`src/actor_id.rs:44-47`](../../github-automerge-automerge/rust/automerge-c/src/actor_id.rs))
//   — a `(ptr, len)` pair with **no terminator** — so `AMbyteSpan.count` is the
//   only thing that bounds it. A caller that reads it with `strlen` reads past
//   the end of the string and reports a hex longer than the writer produced,
//   which is a report about the *caller*, not about the id: [`AMActorId.toStr`]
//   allocates `bytes.len * 2` and [`err.hexInto`](error.zig) writes two
//   characters per byte, so an odd count is impossible from that pair. The
//   three tests at the top of this file's tests section assert
//   `count == 2 * bytes.len` before comparing any content, which is the shape
//   of every call site in the reference's own suite
//   (`test/actor_id_tests.c:96-98`, `test/doc_tests.c:247-249`,
//   `test/ported_wasm/basic_tests.c:194-196`).
// * **`const` local + `switch` pointer capture is a silent use-after-return,
//   and it is what broke every mutating entry point in this file.** Zig 0.16.0
//   accepts `switch (v) { .doc => |*d| … }` where `v` is a `const` local of
//   union type, binds `d` to *that local*, and emits no diagnostic — verified
//   with a five-line program, not inferred. Upstream cannot have this bug:
//   `TryFrom<&'a mut AMitem> for &'a mut AMdoc` (`src/item.rs:1201-1210`) reaches
//   through `Rc::get_mut` and hands out a borrow of the item inside the `Rc`, so
//   the address is stable. This port stores `Value` **inline** in the item, so
//   the same spelling produced a pointer into the callee's dead frame, and
//   `AMmapPut*`, `AMlistPut*`, `AMsplice*`, `AMmapDelete`, `AMmarkCreate`,
//   `AMmarkClear` and `AMcommit` all faulted on their first call. Upstream's
//   layout is also inline — `Doc(RefCell<AMdoc>)` at `src/item.rs:38` — so
//   inline storage is *not* the difference and moving the document to the heap
//   would not have been the fix either. [`valueCell`] and [`valueCellMut`] are
//   the fix, and the test at the top of this file's tests section pins it.
//
// * **`AMitemResult` shares the item and this port's `Item` has to be shared
//   too.** Upstream is `AMresult::item(item.clone())` (`src/item.rs:1693`), which
//   clones the `Rc`. Copying the `Item` *struct* would give two results
//   ownership of one `AMchange`'s heap buffers and free them twice on the
//   second `AMresultFree`; the test pins the refcount and the free count.
//
// * **`AMobjId` needs two heap cells where upstream needs none.** Upstream's
//   `am::ObjId` is `Root | Id(counter, actor_id, index)` (`src/obj.rs:31-38`) and
//   owns its `am::ActorId` **by value**, so `AMobjId::new(obj_id)`
//   (`src/obj.rs:20`) has nothing to allocate. This port's
//   [`types.ExId`] names its actor by **index** (`types.zig:245-247`) and
//   borrows the bytes from a document's actor table, so [`AMobjId.of`] has to
//   copy the bytes out *and* build a real [`AMactorId`] to point at them —
//   **two** cells, because `AMactorId` is `{ body: *const ActorId, gpa, hex }`
//   and `ActorId` is `{ bytes: []const u8 }`. A single `@ptrCast` between them
//   compiles and yields a handle whose `body` is the actor's *slice* and whose
//   `gpa` is whatever followed it in memory, so [`AMobjId.deinit`] freed a wild
//   pointer and `AMobjIdActorId` handed C a garbage address. [`newActorHandle`]
//   makes the wrapper and [`destroyActorHandle`] reads `body` out **before**
//   `AMactorId.deinit` poisons the cell, for the same reason it reads `bytes`
//   out first.
//
// * **`taggedValue` is a second copy of a private dispatch, and a duplicated
//   dispatch is a contract that can drift.** [`read.zig`](../read.zig)'s
//   `taggedValue` (`read.zig:385-412`) and `winner` (`:419-425`) are both
//   `fn`, not `pub fn`, so there is no way to reach them from here without
//   editing a file this slice does not own. The copy is not a recomputation of
//   a document answer — it is a dispatch over an operation's action tag — so
//   refusing the `heads` argument instead would have turned a call upstream
//   supports into an error. **If `read.zig`'s six arms ever change, this copy
//   has to change with them, and nothing but a reader will notice if it does
//   not.**
//
// * **`AMobjIdIndex` answers `0` for a real object, and that is a reported gap
//   rather than a substitution.** Upstream's `am::ObjId` is
//   `Id(counter, actor_id, index)` (`src/obj.rs:31-38`) and the third component
//   is what `AMobjIdIndex` reports (`:151-162`). The port's
//   [`types.ExId`](../types.zig) is `.root | OpId{counter, actor_index}`
//   (`types.zig:245-247`) and carries no creation index; nothing in the op set
//   keeps one. Inventing an index would be a second source of truth for an id.
//   The header's `\brief` still says what upstream's says.
//
// * **A propagated error is spelled `@errorName`, and a hard-coded message is
//   reproduced verbatim.** Upstream renders `AutomergeError`'s `Display`
//   (`src/result.rs:466`); this port's error sets are Zig's, so a propagated
//   error carries the only stable name it has. Every message the reference
//   **writes out** — "Invalid `AMdoc*`", "Invalid uint8_t*", "invalid mark",
//   "Invalid `AMitems*`" — is byte-for-byte the reference's, because a C caller
//   can match on it and the reference's own cmocka suite does
//   (`src/result.rs:513-521`). The test at the top of the tests section
//   asserts both families are distinguishable.
//
// * **`AMmarks` with a non-null `heads` is answered, and it was refused until
//   [`OpSet.calculateMarksAt`](../opset/op_set.zig) existed.** The refusal was
//   reported here as a gap on the stated ground that the port's mark fold
//   "takes no clock and [`Document.marks`](../doc.zig) is its only caller".
//   **Both halves were false**: `calculateMarksAt` is upstream's own dispatch
//   (`automerge.rs`:1569-1596) and `Document.marks` is one of its callers, so
//   what the comment called impossible was unreachable from a single door.
//   It is now upstream's two arms (`src/doc/mark.rs:200-206`) reached through
//   [`clockFromItems`]. **The observable change: a C caller that passed
//   `heads` and received `AM_STATUS_ERROR` with the message
//   `HistoricalMarksUnsupported` now receives `AM_STATUS_OK` and the runs those
//   heads see.** Nothing else moves — no symbol, type, header line or
//   enumerator — and neither the reference's cmocka suite nor its ported copy
//   in [test/c/suite/mark_tests.c](../test/c/suite/mark_tests.c) matches on
//   that message, so no case had to change to make the answer the right one.
//
// * **`AMpendingOps` and `AMrollback` answer `0` because the flavour has
//   already committed.** `AMdoc` is always an `AutoCommit` (`src/doc.rs:36`) and
//   the write surface is `requireAuto` ([transact.zig](../transact.zig)), whose
//   `.auto` mode closes the transaction at the end of every mutating call. So
//   `pending_ops()` is `0` and `rollback()` is the
//   `self.transaction.take()…unwrap_or(0)` of `autocommit.rs:742-750` with
//   nothing to take. Both are the reference's own answers between calls.
//
// * **`AMbytes`, `AMstr` and `AMstrCmp` are declared in the header and were
//   missing from the library.** They are `#[no_mangle] pub extern "C"` upstream
//   (`src/byte_span.rs:176`, `:194`, `:216`), so a C caller that used one got an
//   undefined symbol rather than an error result. They live in this file
//   although [`AMbyteSpan`] is declared in [result.zig](result.zig), because
//   that file is not this slice's to edit and the symbols have to exist
//   somewhere under `src/c/`.
//
// * **Every text index in this ABI counts UTF-8 code units, and
//   [`cTextEncoding`] — not [`docmod.defaultTextEncoding`] — is where that is
//   decided.** Upstream's answer is a *cargo feature*
//   (`text_value.rs:12-22`) and this port has no features, so a build
//   configuration became a choice. `rust/automerge-c/CMakeLists.txt:45`
//   declares `UTF32_INDEXING` and does not set it, so CMake's `option` leaves
//   it off and `:111-117` takes the `else` arm: `-F automerge/utf8-indexing`,
//   which is the first arm of `platform_default()` and answers `Utf8CodeUnit`
//   (`:14-15`). `rust/automerge-c/README.md:62-63` says the same in words.
//   **The alternative was to make [`defaultTextEncoding`](../doc.zig) answer
//   UTF-8**, which would have made the *crate's* default diverge from a
//   default-configured `cargo build` of the same crate — upstream's
//   featureless build is `UnicodeCodePoint` (`:19`) and the port's own 23
//   ported text tests in [read.zig](../read.zig) run against that. It would
//   also have moved every non-C document's text unit, for a defect that only
//   the C binding has. `cTextEncoding` therefore sits here, and its three
//   callers — [`AMcreate`], [`AMload`], [`AMchangeLoadDocument`] — are the
//   only places in `src/c/**` that build a document. The test at the top of
//   this file's tests section pins the unit, not the round trip.
//
// * **`AMresultFrom` is now a symbol, and it is not a Zig one.** It is the only
//   variadic function in the surface (hand-written C upstream,
//   `src/utils/result.c:5-33`) and **Zig cannot define a C variadic
//   function** — `export fn f(x: c_int, a: ...)` is a parse error against
//   0.16.0, and `zig translate-c` demotes a variadic *definition* to an
//   `extern` *declaration`. Upstream's own arrangement is a C file, so this
//   port's is one too: [result_from.c](result_from.c) collects the arguments
//   and calls [`CAbi.AMresultFromList`] in [result.zig](result.zig), which is
//   [`Result.resultFrom`] bound to `c_allocator`. **No decision lives in the
//   C file**, and `AMresultFromList` is exported without a header declaration
//   on purpose — `include/automerge.h` is cbindgen output and upstream
//   declares no such function.
//
// * **`AMgetCursorPosition` reached past the method and so gave one cursor two
//   answers.** It called [`cursormod.getCursorPosition`] directly, which is the
//   port of the **private** `Automerge::get_cursor_position_for`
//   ([`automerge.rs:1760-1849`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
//   Upstream's C entry point cannot do that: its body is
//   `doc.get_cursor_position(obj_id, cursor, at)`
//   ([`automerge-c/src/doc.rs:465`, `:468`](../../github-automerge-automerge/rust/automerge-c/src/doc.rs)),
//   the **public** `ReadDoc::get_cursor_position`
//   ([`read.rs:237-242`](../../github-automerge-automerge/rust/automerge/src/read.rs)
//   over [`automerge.rs:2190-2198`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//   whose port is [`read.getCursorPosition`](../read.zig). **That layer is where a
//   cursor naming a row of *another* object changes label.** The private helper's
//   seek is [`OpSet.seekListOpid`](../opset/op_set.zig), which **cannot answer
//   `null` for upstream's question** — upstream's `seek_list_opid` returns an
//   `Option` that `get_cursor_position_for` maps with
//   `.ok_or_else(|| AutomergeError::InvalidCursor(cursor.clone()))`
//   ([`:1778-1781`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//   and the port's raises `error.InvalidIndex` instead
//   ([`op_set.zig:3145`](../opset/op_set.zig)) — so the C surface reported
//   upstream's refusal under the op set's name, **and
//   [`read.getCursorPosition`](../read.zig) ([`read.zig:1897-1905`](../read.zig))
//   reported the same cursor under upstream's.** One port, two answers, which
//   surface the caller picked. **The observable change: `AMgetCursorPosition` on
//   such a cursor is now `AM_STATUS_ERROR` with the message `InvalidCursor`,
//   upstream's `"cursor {0} is invalid"`
//   ([`error.rs:46-47`](../../github-automerge-automerge/rust/automerge/src/error.rs)),
//   where it was `InvalidIndex`.** Upstream has no status code for a particular
//   refusal — every one is `AM_STATUS_ERROR` beside a message
//   ([`automerge-c/src/result.rs:313-320`](../../github-automerge-automerge/rust/automerge-c/src/result.rs))
//   — so **the message is the label**, and neither the reference's cmocka suite
//   nor its ported copy ([test/c/suite/cursor_tests.c](../test/c/suite/cursor_tests.c):`:212-214`,
//   `:247-249`) matches on one; both assert only `!= AM_STATUS_OK`, so no case
//   had to move to make the answer the right one.
//
//   **The past-the-end `InvalidIndex` is a different question and did not
//   move.** [`AMgetCursor`] refuses an index no row answers with
//   `AutomergeError::InvalidIndex`
//   ([`automerge.rs:1751-1755`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//   and that arm is upstream's own, so its label is still `InvalidIndex` and its
//   message is still upstream's `"index {0} is out of bounds"`
//   ([`error.rs:36-37`](../../github-automerge-automerge/rust/automerge/src/error.rs)).
//
//   **The clock did not move with the route the way this block claimed, and
//   that claim is what the route broke.** It said "no value changes" because
//   [`clockFromItems`] asks [`ChangeGraph.clockAt`](../change_graph.zig) (`:489`)
//   directly and the reader resolves `heads` through
//   [`Document.clockAtScope`](../doc.zig) — and for a *committed* document the
//   two do agree, because a full clock over the present is the present.
//   **They do not agree for an `AMdoc`, which is an `AutoCommit`** and keeps a
//   transaction open across calls (`autocommit.rs:445-457`): `txSpliceText` is
//   `d.open()` and a splice, and no read closes it, so between a write and a
//   read the new operations are in the op set while **the graph's heads are
//   still the previous change's**. A caller naming those heads then finds them
//   equal to the graph's current heads, and
//   [`Automerge::clock_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1242-1243
//   — which is what the reader reaches — answers `None`.
//
//   **Upstream never takes that shortcut here, and it says why.**
//   [`AMdoc`] reaches `AutoCommit`'s `ReadDoc::get_cursor_position`
//   ([`autocommit.rs:996-1004`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
//   which fills its clock from [`AutoCommit::get_scope`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):794-805,
//   and the first of those two lines is
//   `return if self.transaction.is_none() { self.doc.clock_at(h) } else { Some(self.doc.change_graph.clock_at(h)) };`
//   with the reason in the comment above it (`:797-799`): *"the heads ==
//   current-heads shortcut (an unscoped read) is only sound with no
//   transaction in flight: pending ops are already in the op set but not yet
//   under the graph's heads."* **The port had no such arm**, so it took the
//   shortcut across the state upstream names in that sentence.
//
//   **The observable change: `AMgetCursorPosition(doc, obj, cursor, heads)`
//   answered the present for heads the present no longer has.** It is pinned
//   by `test "a cursor minted before an edit resolves at its own heads while a
//   transaction is held open"` and reproduced by the ported WASM suite
//   ([test/c/suite/ported_wasm/cursor_tests.c:72](../test/c/suite/ported_wasm/cursor_tests.c),
//   `assert_int_equal(index1, index3)` printing `12 != 16`). **The two arms of
//   that guard are the whole of the fix**, and the `else` arm is
//   [`read.getCursorPosition`](../read.zig) unchanged. **[`AMgetCursor`] is not
//   affected**: it was never re-routed through `Automerge`'s method, and
//   [`clockFromItems`] is upstream's transaction-in-flight arm
//   (`Some(self.doc.change_graph.clock_at(h))`) for every case — which is why
//   routing it through [`read.getCursorMoving`](../read.zig) would be a change
//   of clock plumbing on a function this slice was not asked to change, and is
//   recorded here rather than made.
//
// * **`fn resultUint(r: *AMresult) !u64` is this slice's own**, and it is the
//   reading a C caller makes of an `AM_VAL_TYPE_UINT` result
//   ([`AMitemToUint`](../test/c/suite/cmocka_utils.c), `src/item.rs:2123-2133`).
//   **It refuses on an error result rather than answering `0`**, which is the
//   whole of what makes an assertion through it a claim: upstream's C ABI has
//   no status code for a particular refusal
//   ([`src/result.rs:313-320`](../../github-automerge-automerge/rust/automerge-c/src/result.rs)),
//   so **the message is the label** and a `0` from a refusal would read as an
//   index.
//
// * **`newActorHandle` handed out a pointer that no function said how to
//   free.** Upstream's `AMactorId` is `body: *const am::ActorId`
//   ([`src/actor_id.rs:26-29`](../../github-automerge-automerge/rust/automerge-c/src/actor_id.rs)),
//   a **borrow**, beside a `hex_str: RefCell<Option<Box<str>>>` that is the
//   only field it drops (`:28`, `:39-51`) — Rust frees a borrow where its
//   scope ends and this port has no scopes. **This port's `body` is a heap
//   cell, so the caller owns it**, and the file spelled that free twice, four
//   lines each: [`AMobjId.deinit`] and [`Value.deinit`].
//   [`AMactorId.deinit`] is **neither** — it frees the hex cache and stops —
//   and two tests called it, so each dropped a cell, a copy of the actor's
//   bytes and a handle. `std.testing.allocator` reported **5** leaks against
//   `an actor id's hex is two characters per byte …` and **3** against `the
//   hex a handle caches comes back with the handle, exactly once`, every one
//   of them from [`newActorCell`]'s two allocations and `newActorHandle`'s
//   third. [`destroyActorHandle`] is now the **only** spelling of that free
//   and takes the handle's **own** allocator, because that is the one that
//   made all three and the only one that may free them;
//   [`AMobjId.deinit`] calls it instead of repeating it, so the next caller
//   has one function to find rather than two sets of four lines to copy.
//
// * **`AMdoc.open` was the one door in the port that opened a transaction on
//   an allocator its document did not have, and the C ABI has no way to ask
//   for one.** Upstream's `AMdoc` is `pub struct AMdoc(am::AutoCommit)`
//   ([`src/doc.rs:36`](../../github-automerge-automerge/rust/automerge-c/src/doc.rs)):
//   a newtype with no allocator on it and **no `AMdoc_open` in the ABI** to
//   pass one to — the header declares `typedef struct AMdoc AMdoc;`
//   ([`include/automerge.h:213`](../../include/automerge.h)) and every
//   function takes it as a parameter.
//   [`ensure_transaction_open`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs:445-457)
//   takes the transaction out of the `AutoCommit` that already holds it, so
//   **upstream has no choice to make and this port has no C-visible signature
//   to add one to**; a parameter here would be a signature the header does not
//   have, and `zig build ctest` proves the two are the same set. The
//   allocator is reachable anyway: [`AMdoc.allocator`] is
//   `self.doc.allocator()`, which is what [`Transaction.gpa`]'s own contract
//   names — "every owned buffer in this transaction belongs to, **which is
//   the document's**" ([`transact.zig:330-332`](../transact.zig)) — and what
//   every other door in the port opens with (`const gpa = doc.allocator();`,
//   [`transact.zig:2668`](../transact.zig), `:2680`, `:2692`).
//   **What the hardcoded `c_alloc` cost is not a leak but a free of somebody
//   else's memory.** A pending operation's undo log is the op set's
//   allocation ([`op.zig:1230-1236`](../opset/op.zig)) and
//   [`Transaction.deinit`] frees it with `self.gpa`
//   ([`transact.zig:452`](../transact.zig)), so every `AMdoc` not built by
//   [`AMcreate`] reached `free` on a pointer its allocator had not handed
//   out — `thread panic: Invalid free` under `std.testing.allocator`,
//   `Segmentation fault` in `__free` under libc. **"Unreachable from C" is a
//   fact about the one route that builds a document, not a property of the
//   type**, and it is pinned now by `test "a held transaction and its document
//   share one allocator"`, with the unicode test rebuilt on
//   `testing.allocator` so that its teardown is under the arbiter too.
//
// * **This file's Zig test section is compiled by no gate**, and that is worth
//   saying where it is fixed. [`src/root.zig`:222-226](../../src/root.zig)
//   leaves `c/doc.zig` out of `zig test`'s import block because its exports are
//   over libc, and [`test/c/cabi.zig`](../../test/c/cabi.zig) is
//   `b.addLibrary`, not a test root, so the C driver builds it **without** its
//   tests. The section had therefore rotted unnoticed: `:4673` passed a
//   `Document` where [`docResult`] takes an `AMdoc` (one compile error, so the
//   whole file failed to build), and the unicode test built its `AMdoc` on
//   `testing.allocator` while [`AMdoc.open`] opened the held transaction with
//   `c_alloc`, so its teardown freed across the two and aborted the runner.
//   **The compile error is a repair, and the allocator was a workaround that
//   is no longer needed**: [`AMdoc.open`] opens on the document's own
//   allocator, so a test — or the first Zig caller — may build its `AMdoc` on
//   `testing.allocator`, which that test now does. **Neither is a change to a
//   gate**: `zig build test` does not see this file and `zig build ctest`
//   builds it as a library. **The two leaks the same section was carrying are
//   gone as well** (`an actor id's hex …` and `the hex a handle caches …`,
//   each leaving a `newActorHandle` cell behind): the section now runs to a
//   clean teardown under `std.testing.allocator` for every test in it.
