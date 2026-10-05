//! The single native transaction engine over a raw Document.
//!
//! AutoCommit and the C owner hold this same journal across writes. Native
//! callers keep the document and transaction addresses stable until terminal
//! commit/rollback. Commit returns a hash and the transaction-owned PatchLog;
//! callers dispose or transfer that log, including inactive results.
//!
//! Every queued operation owns its slice payloads through the journal. Pending
//! stores the TxOp undo view and ChangeOp encoding view of the same operation.
//! Batches queue builders, then publish one op-set splice; unpublished entries
//! are discarded rather than undone when a producer refuses before publication.
//!
//! Ordinary readers use the transaction write clock, including its pending
//! operations. Explicit-head readers borrow retained historical clocks that
//! survive selecting another read view. Hydration deliberately follows raw
//! Document semantics instead of the write scope.
//!
//! deinit is fallible: it rolls back an open journal, retaining the journal and
//! its sole patch owner on refusal. deinitClosed is resource-only disposal after
//! a terminal transition, or when the entire raw document is being destroyed.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");
const valuemod = @import("value.zig");
const marksmod = @import("marks.zig");
const clockmod = @import("clock.zig");
const column = @import("hexane/column.zig");
const opmod = @import("opset/op.zig");
const opitermod = @import("opset/op_iter.zig");
const insertmod = @import("opset/insert.zig");
const opsetmod = @import("opset/op_set.zig");
const docmod = @import("doc.zig");
const hydmod = @import("hydrate.zig");
const spansmod = @import("iter/spans.zig");
const changerec = @import("change.zig");
const readmod = @import("read.zig");
const textdiff = @import("textdiff.zig");
const patchesmod = @import("patches.zig");
const batchmod = @import("opset/batch.zig");
const transactionmod = @import("transaction.zig");

const Allocator = std.mem.Allocator;
const Action = valuemod.Action;
const ActorIdx = types.ActorIdx;
const ChangeHash = types.ChangeHash;
const ChangeOp = opmod.ChangeOp;
const Clock = clockmod.Clock;
const Document = docmod.Document;
const ElemId = types.ElemId;
const Error = err.Error;
const ExId = types.ExId;
const InternalError = err.InternalError;
const Mark = marksmod.Mark;
const MarkSet = marksmod.MarkSet;
const ExpandMark = marksmod.ExpandMark;
const UpdateSpansConfig = marksmod.UpdateSpansConfig;
const ObjMeta = types.ObjMeta;
const ObjType = types.ObjType;
const Op = opmod.Op;
const OpId = types.OpId;
const OpRange = opmod.OpRange;
const OpType = valuemod.OpType;
const ParseError = err.ParseError;
const Prop = types.Prop;
const ResolvedAction = opmod.ResolvedAction;
const RowRange = column.RowRange;
const ScalarValue = valuemod.ScalarValue;
const SequenceType = types.SequenceType;
const Set = docmod.Set;
const SuccInsert = opmod.SuccInsert;
const SuccUndo = opmod.SuccUndo;
const TextEncoding = types.TextEncoding;
const TxOp = opmod.TxOp;
const Value = valuemod.Value;

const testing = std.testing;

/// A span of a text object: a run of text with the marks open over it, or a
/// block marker. Re-exported from [iter/spans.zig](iter/spans.zig), which owns
/// the walk that produces one and the ownership rule for its payloads.
pub const Span = spansmod.Span;
/// Borrowed rich-span input; block maps are copied into this journal owner.
pub const SpanInput = spansmod.SpanInput;

// ── Errors ──────────────────────────────────────────────────────────────────

/// Everything a write can raise.
///
/// **The public functions in this file return [`Error`],** because that is what
/// `API.md`'s `## Write` section names. This is the wider set the bodies work
/// in: the op set's walks raise their own refusals
/// ([`opitermod.ReadOpError`](opset/op_iter.zig),
/// [`insertmod.ResolveError`](opset/insert.zig),
/// [`opsetmod.SearchError`](opset/op_set.zig)), a document load or commit
/// raises [`docmod.LoadError`](doc.zig), and a check upstream treats as
/// impossible raises [`err.InternalError`]. [`asError`] is the one place the
/// narrow set is produced, so a caller never has to match two error sets.
pub const WriteError = Error || ParseError || InternalError ||
    opitermod.ReadOpError || opsetmod.SearchError || docmod.LoadError ||
    readmod.DiffError || readmod.HydrateError || readmod.ChangeError || error{ChangeType};

/// The document [`Error`] an internal refusal becomes.
///
/// **The mapping is by category and not one for one, and that is deliberate.**
/// `ParseError` is the set that must be total over untrusted bytes
/// ([error.zig:6-12](../error.zig)); nothing in this file is reachable from
/// untrusted bytes, so a `ParseError` reaching here is an internal
/// disagreement rather than a document, and it becomes `error.Fail` rather than
/// a variant that would tell a caller it had bad input. `error.OutOfMemory` and
/// the two index refusals keep their own names because a caller can act on them.
fn asError(e: WriteError) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidIndex, error.IndexOutOfBounds => error.InvalidIndex,
        error.MissingCounter => error.MissingCounter,
        error.NotAnObject => error.NotAnObject,
        error.InvalidOp => error.InvalidOp,
        error.InvalidObjId, error.InvalidObjIdFormat => error.InvalidObjId,
        error.InvalidValueType => error.InvalidValueType,
        error.EncodingError => error.EncodingError,
        error.MissingActor, error.InvalidActorIndex => error.InvalidActorIndex,
        error.InvalidCharacter, error.InvalidUtf8 => error.InvalidUtf8,
        error.MissingHash, error.MissingDeps => error.MissingHash,
        else => error.Fail,
    };
}

// ── Pending ─────────────────────────────────────────────────────────────────

/// One operation a transaction has made, in both of the shapes this file needs.
///
/// **`tx` is what a rollback reads and `op` is what the document reads.** The
/// split is the module doc's second decision: the document's op set is
/// `OpSet(ChangeOp)` and its `splice` is typed to that, while
/// [`OpSet.undoOp`](opset/op_set.zig) takes a `TxOp` and reads `pos`, `undo`
/// and `reset_range` off it. `tx` owns the predecessor storage; `op` borrows
/// it and never escapes the pending transaction. Callers must not mutate that
/// storage while the view lives. Dispose `op` before its owner `tx`.
pub const Pending = struct {
    /// The operation and owner of its predecessor storage.
    tx: TxOp,
    /// The op set and change encoder view, borrowing `tx`'s predecessors.
    op: ChangeOp,
    /// False while a batch owns queued builders not yet published as rows.
    published: bool = true,

    /// Frees the borrowing view before its predecessor owner. Other slice
    /// payloads belong to the journal's `owned` buffers, released separately.
    pub fn deinit(self: *Pending, gpa: Allocator) void {
        self.op.deinit(gpa);
        self.tx.deinit(gpa);
        self.* = undefined;
    }
};

/// A transaction-only change view borrowing the paired `TxOp`'s predecessors.
/// The caller transfers both into `Pending`; the view must not escape it.
fn changeOpOf(op: *const TxOp) ChangeOp {
    return ChangeOp.initBorrowingTxPred(op);
}

/// The one operation an insert produced ([`InsertedOp`],
/// [`inner.rs:36-46`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
///
/// `pos` is the row it landed at and `index` the position it took in the
/// sequence, and a mark's two anchors are read through this
/// ([`insert_mark_end_after`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
pub const Inserted = struct {
    /// The operation's own id, which is also its `ElemId`.
    id: OpId,
    /// The row it was spliced at.
    pos: usize,
    /// The position it took in the sequence.
    index: usize,
};

// ── Transaction ─────────────────────────────────────────────────────────────

/// A borrowed transaction: the pending operations, the identity they will be
/// committed under, and the scope they are written against.
///
/// **This is upstream's `TransactionInner`**
/// ([`inner.rs:22-34`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
/// with the `Vec` fields spelled as this port's unmanaged lists and the
/// `Option<Clock>` scope kept as the heads the clock is built from. It borrows
/// the document and cannot outlive it.
///
/// `message` and `time` are upstream's two fields
/// ([`inner.rs:25-26`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs));
/// [`commit`] takes an override for each, which is upstream's
/// `commit_impl`'s `if message.is_some()` / `if let Some(t)` (`:152-158`).
/// A producer refusal after publication or batch queuing makes the transaction
/// rollback-only. Commit allocation refusal alone remains open for commit retry.
pub const Transaction = struct {
    /// The allocator every owned buffer in this transaction belongs to, which
    /// is the document's.
    gpa: Allocator,
    /// Borrowed document. Keep it at this address until transaction disposal;
    /// do not mutate it through another transaction or write entry point.
    doc: *Document,
    /// The actor this transaction creates operations for
    /// ([`inner.rs:23`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    actor: ActorIdx,
    /// The sequence number the change it commits will carry.
    seq: u64,
    /// The counter of the change's first operation. **Global, not per actor**
    /// ([`automerge.rs:566-567`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    start_op: u64,
    /// Owned, sorted dependency hashes, independent of the document's heads.
    /// Moved from `TransactionArgs`; freed by `deinit` (`inner.rs:30,198`).
    deps: []ChangeHash,
    /// The heads this transaction reads at, **borrowed**. Null is an unscoped
    /// read of the present document, which is what takes the indexed fast
    /// paths ([`op_set.rs:569-576`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
    /// Native automatic recovery rebinds this borrow to its own owned `deps`
    /// before the wrapper returns, so releasing isolation does not invalidate it.
    scope_heads: ?[]const ChangeHash,
    /// The clock over `scope_heads`, built on first use and null until then.
    scope: ?Clock,
    /// Whether `scope` has been decided, which is not the same as being null.
    scope_built: bool,
    /// Owned operation undo records in insertion order. Commit drains them;
    /// rollback removes and disposes each successfully undone record.
    pending: std.ArrayList(Pending),
    /// Borrowed commit message; keep bytes live until commit returns.
    message: ?[]const u8 = null,
    /// The commit time. Upstream's default is zero, not "now"
    /// ([`inner.rs:68-91`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    time: i64 = 0,
    /// Whether this transaction has been committed or rolled back. Upstream
    /// takes the inner out of its `Option` for exactly this
    /// ([`manual_transaction.rs:135-145`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)),
    /// and a second application of either is a bug here rather than a no-op.
    closed: bool = false,
    /// Rollback-only after partial production or a rollback attempt. No further
    /// writes or commit are permitted.
    rolling_back: bool = false,
    /// Number of operations already undone, retained across rollback retries.
    cancelled: usize = 0,
    /// Owned `textFor` cache. A successful next `textFor` call replaces it;
    /// a failed call preserves it. `deinit` frees the last buffer.
    text_cache: ?[]u8 = null,
    /// The bytes a queued operation's value borrows, freed by [`deinit`].
    ///
    /// **Upstream's `TxOp` holds an `OpBuilder<'static>`**
    /// ([`op.rs:164-170`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    /// so a `ScalarValue<'static>` can only be `Cow::Owned`
    /// ([`types.rs:566-570`](../../github-automerge-automerge/rust/automerge/src/op_set2/types.rs))
    /// and a borrowed `&str` cannot be put in a `pending` vector at all: the
    /// borrow checker refuses it. Zig has no lifetime parameter to copy, so
    /// the port cannot refuse it, and the copy lands here instead —
    /// upstream's `BatchInsertion::splice_text` builds an **owned**
    /// `Vec<ScalarValue>` before its loop for the same reason
    /// ([`inner.rs:1481-1501`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    ///
    /// It is not a nicety. Every `textdiff` hook builds the text it splices
    /// in a local and frees it when the call returns —
    /// [`TxHook.insert`](textdiff.zig) and [`TxHook.replace`](textdiff.zig)
    /// on a `concat`, [`BlockDiffHook.insert`](textdiff.zig) on a `run` — so
    /// an operation that borrowed it would be reading freed bytes by the time
    /// [`commit`] encodes the change.
    owned: std.ArrayList([]u8),
    /// Deep-owned maps held at stable addresses for rich-span diff descriptors.
    ///
    /// **Each map is its own allocation, not a slot in this list**, and that is
    /// the whole point: a [`Block`] hands the diff a `*const hydmod.Map`, and
    /// [`updateSpans`] writes operations whose keys and values are borrowed
    /// from that map — so the map has to outlive the diff, and its address has
    /// to stay put while the diff runs. An `ArrayList` of maps by value gives
    /// neither once the list grows, and the reservation that used to stand in
    /// for the second was only ever a guess: it allowed `spans.len + 1` blocks
    /// while the *old* side of the diff walks every block the document already
    /// holds, and that is a number nothing there knows. A pointer per map is
    /// stable by construction.
    ///
    /// This is the same debt [`ownText`] pays for a spliced character, on the
    /// other side of the same diff.
    blocks: std.ArrayList(*hydmod.Map),
    /// The sole patch owner for this transaction, moved out on successful commit.
    patch_log: patchesmod.PatchLog,
    /// Clone-only ownership for a scope that otherwise borrows constructor heads.
    scope_heads_owned: ?[]ChangeHash = null,

    /// A transaction over `args`, which it takes ownership of
    /// ([`TransactionInner::new`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):68-91).
    ///
    /// **Constructing one allocates nothing.** `pending` is an empty
    /// unmanaged list, the scope clock is not built, and `deps` is *moved* out
    /// of the arguments the caller already holds — upstream's `TransactionInner`
    /// moves `deps` the same way, out of a `TransactionArgs` that
    /// [`Document.transactionArgs`](doc.zig) allocated.
    pub fn init(gpa: Allocator, doc: *Document, args: docmod.Document.TransactionArgs) Transaction {
        return .{
            .gpa = gpa,
            .doc = doc,
            .actor = args.actor_index,
            .seq = args.seq,
            .start_op = args.start_op,
            .deps = args.deps,
            .scope_heads = args.scope,
            .scope = null,
            .scope_built = false,
            .pending = .empty,
            .blocks = .empty,
            .owned = .empty,
            .patch_log = patchesmod.PatchLog.inactive(gpa),
        };
    }

    /// Close an open journal by rollback, then release its resources.
    /// On refusal the exact journal and patch owner remain available for retry.
    pub fn deinit(self: *Transaction) WriteError!void {
        if (!self.closed) _ = try self.rollback();
        self.deinitClosed();
    }

    /// Resource-only disposal after commit/rollback, or while destroying the
    /// entire owning document. Never use this to abandon rows in a live document.
    pub fn deinitClosed(self: *Transaction) void {
        if (self.text_cache) |bytes| self.gpa.free(bytes);
        for (self.owned.items) |bytes| self.gpa.free(bytes);
        self.owned.deinit(self.gpa);
        for (self.blocks.items) |map| {
            map.deinit();
            self.gpa.destroy(map);
        }
        self.blocks.deinit(self.gpa);
        if (self.scope) |*clock| clock.deinit();
        for (self.pending.items) |*item| item.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.gpa.free(self.deps);
        if (self.scope_heads_owned) |heads| self.gpa.free(heads);
        self.patch_log.deinit();
        self.* = undefined;
    }

    /// Open a journal over the raw document. Constructor refusal leaves the
    /// document unchanged; the dependency/scope owner moves only on success.
    pub fn open(gpa: Allocator, doc: *Document) WriteError!Transaction {
        return openAt(gpa, doc, null);
    }

    /// `heads` is borrowed for the journal lifetime.
    pub fn openAt(gpa: Allocator, doc: *Document, heads: ?[]const ChangeHash) WriteError!Transaction {
        var prepared = try doc.prepareTransactionArgs(gpa, heads);
        defer prepared.deinit();
        return Transaction.init(gpa, doc, doc.publishTransactionArgs(&prepared));
    }

    /// Consume an actor-compatible external log only after constructor preflight.
    /// Current/scoped actor insertion is included; refusal preserves both owners.
    pub fn openWithPatchLog(
        gpa: Allocator,
        doc: *Document,
        log: *patchesmod.PatchLog,
        heads: ?[]const ChangeHash,
    ) WriteError!Transaction {
        var prepared = try doc.prepareTransactionArgs(gpa, heads);
        defer prepared.deinit();
        // Prepared actors include a newly selected current or concurrency actor,
        // but neither actor insertion nor queue pruning has been published.
        try log.validateActors(prepared.actors);
        try log.bindBegin(doc.patchIdentity(), prepared.actors, prepared.args.seq, prepared.args.actor_index);
        var out = Transaction.init(gpa, doc, doc.publishTransactionArgs(&prepared));
        out.patch_log.deinit();
        out.patch_log = log.take();
        return out;
    }

    /// Duplicate a journal against an exact pending-row clone of its raw
    /// document. The source remains open; all payloads, undo records and patch
    /// checkpoint storage are independent. `target_doc` must stay at this address.
    pub fn cloneInto(self: *const Transaction, gpa: Allocator, target_doc: *Document) WriteError!Transaction {
        var out = self.*;
        out.gpa = gpa;
        out.doc = target_doc;
        out.deps = try gpa.dupe(ChangeHash, self.deps);
        out.scope_heads_owned = null;
        out.scope = null;
        out.pending = .empty;
        out.owned = .empty;
        out.blocks = .empty;
        out.text_cache = null;
        out.patch_log = patchesmod.PatchLog.inactive(gpa);
        errdefer out.deinitClosed();
        if (self.scope_heads) |heads| {
            const copied = try gpa.dupe(ChangeHash, heads);
            out.scope_heads_owned = copied;
            out.scope_heads = copied;
        }
        if (self.scope) |scope| {
            out.scope = .{
                .gpa = gpa,
                .len = scope.len,
                .slots = try gpa.dupe(u32, scope.slots),
            };
        }
        if (self.message) |message| out.message = try out.ownText(message);
        out.patch_log = try self.patch_log.cloneAndRebind(gpa, target_doc.patchIdentity());
        try out.pending.ensureTotalCapacity(gpa, self.pending.items.len);
        for (self.pending.items) |*item| {
            var tx = item.tx;
            tx.bld = try out.cloneBuilder(&item.tx.bld);
            tx.undo = .empty;
            errdefer tx.deinit(gpa);
            try tx.undo.appendSlice(gpa, item.tx.undo.items);
            // Borrow the cloned builder's predecessor storage, never the source's.
            var change = changeOpOf(&tx);
            errdefer change.deinit(gpa);
            change.pos = item.op.pos;
            change.subsort = item.op.subsort;
            change.conflicted = item.op.conflicted;
            try change.succs.appendSlice(gpa, item.op.succs.items);
            out.pending.appendAssumeCapacity(.{ .tx = tx, .op = change, .published = item.published });
        }
        return out;
    }

    fn cloneBuilder(self: *Transaction, source: *const opmod.OpBuilder) WriteError!opmod.OpBuilder {
        var out = source.*;
        out._pred = .empty;
        errdefer out._pred.deinit(self.gpa);
        try out._pred.appendSlice(self.gpa, source._pred.items);
        try self.ownBuilderPayload(&out);
        return out;
    }

    /// Intern every slice carried by a queued builder in this journal owner.
    fn ownBuilderPayload(self: *Transaction, builder: *opmod.OpBuilder) WriteError!void {
        // Actor bytes are authoritative after transaction actor insertion.
        // A batch parent may not have a resident make row yet. Resolve its
        // identity without rechecking object existence already validated by
        // the public writer or established by the batch's own make operation.
        builder._obj = switch (builder._obj) {
            .named => self.doc.ops.resolveIdentity(builder._obj) orelse return error.NotAnObject,
            else => builder._obj,
        };
        switch (builder._key) {
            .map => |key| builder._key = .{ .map = try self.ownText(key) },
            else => {},
        }
        builder._value = switch (builder._value) {
            .str => |value| .{ .str = try self.ownText(value) },
            .bytes => |value| .{ .bytes = try self.ownText(value) },
            .actor_id => |actor| .{ .actor_id = .{ .bytes = try self.ownText(actor.bytes) } },
            .unknown => |value| .{ .unknown = .{
                .type_code = value.type_code,
                .bytes = try self.ownText(value.bytes),
            } },
            else => builder._value,
        };
        if (builder._mark_name) |name| builder._mark_name = try self.ownText(name);
    }

    /// How many operations this transaction has made
    /// ([`TransactionInner::pending_ops`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):103-105).
    pub fn count(self: *const Transaction) usize {
        return self.pending.items.len;
    }

    /// The change this transaction will depend on, **borrowed** from the
    /// transaction ([`TransactionInner::get_deps`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1386-1388).
    ///
    /// Valid until [`deinit`] frees `deps`, and unchanged by any operation.
    pub fn baseHeads(self: *const Transaction) []const ChangeHash {
        return self.deps;
    }

    /// The id the next operation will carry
    /// ([`next_id`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):295-297):
    /// `start_op + pending_ops()`, which is why the ids are contiguous.
    pub fn nextId(self: *const Transaction) OpId {
        return OpId.init(
            std.math.cast(u32, self.start_op + self.pending.items.len) orelse std.math.maxInt(u32),
            self.actor,
        );
    }

    /// The scope clock, built on first use and kept
    /// ([`get_scope`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1382-1384).
    ///
    /// **Null for an unscoped transaction, and that is the fast path**: a query
    /// with no clock is the one that can use the index
    /// ([`op_set.rs:569-576`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
    ///
    /// **Public because it is [`get`](transact.zig)'s and
    /// [`markSetAtIndex`](transact.zig)'s argument**, which is upstream's
    /// `get_scope(None)` ([`manual_transaction.rs:113-122`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)):
    /// the clock a read through this transaction runs at. That method takes the
    /// transaction's own scope and **not** the document's, which is the whole
    /// difference between a read here and a read through the document.
    pub fn scopeClock(self: *Transaction) readmod.ReadError!?Clock {
        if (!self.scope_built) {
            if (self.scope_heads) |heads| {
                var clock = try self.doc.graph.clockAt(self.gpa, heads);
                errdefer clock.deinit();
                // **`clock.isolate(actor_index)`**
                // ([`automerge.rs:1266`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
                // and it is load-bearing rather than tidying. Upstream builds
                // the clock **once**, in `isolate_actor`, marks it there and
                // hands the marked clock to the transaction as its scope
                // (`:1276-1280`); this builds it per transaction from the
                // heads, so the mark has to be made here or it is lost.
                //
                // What it buys: the operations this transaction is about to
                // write are in no change at `heads` and so in no clock at
                // `heads`, and [`exidToObj`] refuses an object its scope
                // cannot see. Without the mark the first write works — the
                // `created_in_transaction` escape hatch covers it — and the
                // second does not. `isolate(&[])` is the sharpest case: its
                // clock is empty, so *every* object is out of scope from the
                // second transaction onwards.
                try clock.isolate(self.actor);
                self.scope = clock;
            }
            self.scope_built = true;
        }
        return self.scope;
    }

    /// The object and its type, refusing one the scope cannot see
    /// ([`exid_to_obj`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):107-122).
    ///
    /// The escape hatch is upstream's and it is load-bearing: an object this
    /// transaction created is not under any clock, because it is not in any
    /// change yet, so a scoped transaction must be able to write into it.
    ///
    /// **`meta.id` is the resolved id, not the one the caller passed.**
    /// Upstream's `exid_to_obj` calls `doc.exid_to_obj`
    /// ([`inner.rs:108`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    /// which re-resolves the actor index
    /// ([`automerge.rs:788-792`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// and the operations this transaction then queues are anchored on the
    /// object as the *op set* numbers it. A stale index would put every one of
    /// them in the wrong object, so the resolution is not only a lookup: it is
    /// what the write is anchored to.
    fn exidToObj(self: *Transaction, id: ExId) WriteError!ObjMeta {
        try self.requireOpen();
        const live = self.doc.ops.resolveObjId(id) orelse return error.NotAnObject;
        const obj = ObjMeta{ .id = live, .typ = self.doc.ops.objectType(live) orelse return error.NotAnObject };
        const oid = live.opId() orelse return obj; // the root is always in scope
        const ctr = @as(u64, oid.counter);
        const made_here = oid.actor == self.actor and
            ctr >= self.start_op and
            ctr < self.start_op + self.pending.items.len;
        if (made_here) return obj;
        if (try self.scopeClock()) |clock| {
            if (!clock.contains(oid)) return error.InvalidObjId;
        }
        return obj;
    }

    /// The type the transaction was asked for, or `error.InvalidOp` when the
    /// object is not of that kind. Upstream matches the pair
    /// (`Prop::Map(_), ObjType::Map` and two more) and answers
    /// `AutomergeError::InvalidOp(obj.typ)` for the rest
    /// ([`inner.rs:252-257`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    fn requireType(obj: ObjMeta, want: ObjType) WriteError!void {
        if (obj.typ == want) return;
        return error.InvalidOp;
    }

    /// `error.InvalidOp` once this transaction has been committed or rolled
    /// back.
    ///
    /// **Upstream cannot reach this state and the port can.** `commit` and
    /// `rollback` take `self` by value (`inner.rs:129`, `:211`), so a spent
    /// transaction is gone and there is nothing left to write with; here the
    /// transaction outlives the call and the door has to be shut at runtime.
    /// It matters because [`nextId`] is `start_op + pending.len`
    /// (`inner.rs:294-296`): a spent transaction whose pending list has been
    /// drained answers `start_op`, and the next operation it wrote would land
    /// on an op id the document already holds — the same collision that a
    /// `max_op` of zero produces.
    fn requireOpen(self: *const Transaction) WriteError!void {
        if (self.closed or self.rolling_back)
            return error.InvalidOp;
    }

    // ── Producing an operation ───────────────────────────────────────────

    /// Splices `tx` in at the row it names, records the successor edges, and
    /// queues it ([`insert_local_op`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):308-329).
    ///
    /// **Upstream's five steps are all here**, and the order matters: the
    /// successor edges go on *after* the row exists, and `reset_top` goes on
    /// after *those*, because it recomputes winners over a range the edges just
    /// changed.
    fn insertLocalOp(
        self: *Transaction,
        tx: TxOp,
        succ: []const SuccInsert,
        range: RowRange,
    ) WriteError!void {
        try self.requireOpen();
        var op = tx;
        var transferred = false;
        errdefer if (!transferred) op.deinit(self.gpa);
        if (self.start_op + self.pending.items.len > std.math.maxInt(u32)) return error.Overflow;
        try self.ownBuilderPayload(&op.bld);

        var change = changeOpOf(&op);
        errdefer if (!transferred) change.deinit(self.gpa);
        try self.pending.ensureUnusedCapacity(self.gpa, 1);
        const added = try self.doc.ops.splice(op.pos, &.{change});
        self.doc.invalidateHistoricalScopes();
        // Publication transfers undo ownership before any successor or index
        // mutation can refuse. A partially produced operation is rollback-only.
        self.pending.appendAssumeCapacity(.{ .tx = op, .op = change });
        transferred = true;
        errdefer self.rolling_back = true;
        const retained = &self.pending.items[self.pending.items.len - 1].tx;
        try self.doc.ops.addSuccWithUndo(succ, &retained.undo);
        if (self.scope_heads != null) {
            retained.reset_range = .{ .start = range.start, .end = range.end };
            try self.doc.ops.resetTop(.{
                .start = range.start,
                .end = range.end + added,
            });
        }
    }

    fn patchValue(action: Action, scalar: ScalarValue) batchmod.PatchValue {
        if (action.objType()) |typ| return .{ .object = typ };
        return .{ .scalar = scalar };
    }

    fn incrementReplacement(rows: []const Op, resolved: ResolvedAction) ?batchmod.PatchValue {
        if (!resolved.isIncrement() or rows.len <= 1) return null;
        for (rows) |row| if (row.value() == .counter) {
            return .{ .scalar = row.value() };
        };
        return null;
    }

    fn checkPatchLog(self: *Transaction) WriteError!void {
        if (self.patch_log.oom) {
            self.rolling_back = true;
            return error.OutOfMemory;
        }
    }

    /// Record each producer event, not a final-state reconstruction at commit.
    fn finalizeOp(self: *Transaction, op: *const TxOp, marks_set: ?*const MarkSet, replaced: ?batchmod.PatchValue) WriteError!void {
        if (!self.patch_log.recording or op.noop or op.isMark()) return;
        const obj = op.objId();
        const id = op.id();
        const prop = op.prop();
        const value = patchValue(op.bld._action, op.value());
        if (op.bld._insert) {
            if (op.obj_type == .text) {
                self.patch_log.splice(obj, op.index, op.asStr(), marks_set);
            } else {
                self.patch_log.insert(obj, op.index, value, id, false);
            }
        } else if (op.isDelete()) {
            switch (prop) {
                .key => |key| self.patch_log.deleteMap(obj, key),
                .index => |index| self.patch_log.deleteSeq(obj, index, 1),
            }
        } else if (op.getIncrementValue()) |delta| {
            if (replaced) |old| {
                var materialized = old;
                materialized.scalar.counter.current +%= delta;
                switch (prop) {
                    .key => |key| self.patch_log.putMap(obj, key, materialized, id, false, false),
                    .index => |index| self.patch_log.putSeq(obj, index, materialized, id, false, false),
                }
            } else switch (prop) {
                .key => |key| self.patch_log.incrementMap(obj, key, delta, id),
                .index => |index| self.patch_log.incrementSeq(obj, index, delta, id),
            }
        } else if (op.obj_type == .text and prop == .index and replaced != null) {
            self.patch_log.replaceSeq(obj, op.index, replaced.?, value, id, false, false, .text, self.doc.textEncoding(), marks_set);
        } else switch (prop) {
            .key => |key| self.patch_log.putMap(obj, key, value, id, false, false),
            .index => |index| self.patch_log.putSeq(obj, index, value, id, false, false),
        }
        try self.checkPatchLog();
    }

    /// An operation on a map key ([`local_map_op`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):446-493).
    ///
    /// Null for a write that changes nothing, which is upstream's
    /// `resolve_action` answering `None` at `:1489-1492` and `:1504-1508`:
    /// a `put` that repeats the register's only value, and a `delete` of a
    /// register with no rows.
    fn localMapOp(
        self: *Transaction,
        obj: ObjMeta,
        key: []const u8,
        action: OpType,
    ) WriteError!?OpId {
        const id = self.nextId();
        var query = try self.doc.ops.seekOpsByMapKey(
            self.gpa,
            obj.id,
            key,
            try self.scopeClock(),
        );
        defer query.deinit(self.gpa);

        const resolved = query.resolveAction(action) orelse return null;
        // `inner.rs:466-468` — an increment needs *one* counter, not all of
        // them, because a conflicted register is still a counter register.
        if (resolved.isIncrement() and !anyCounter(query.ops.items)) {
            return error.MissingCounter;
        }

        const pred_len = query.ops.items.len;
        var pred_inline: [1]OpId = undefined;
        const pred = if (pred_len <= pred_inline.len)
            pred_inline[0..pred_len]
        else
            try self.gpa.alloc(OpId, pred_len);
        defer if (pred_len > pred_inline.len) self.gpa.free(pred);
        for (query.ops.items, pred) |row, *slot| slot.* = row.id();

        // Both existing registers and absent keys supply their exact sorted
        // end through the query (`transaction/inner.rs:473`).
        const pos = query.end_pos;
        var succ_inline: [1]SuccInsert = undefined;
        const succ = if (pred_len <= succ_inline.len)
            succ_inline[0..pred_len]
        else
            try self.gpa.alloc(SuccInsert, pred_len);
        defer if (pred_len > succ_inline.len) self.gpa.free(succ);
        const tx = try TxOp.map(self.gpa, id, obj, pos, resolved, key, pred);
        const inc = tx.getIncrementValue();
        for (query.ops.items, succ) |row, *slot| slot.* = row.addSucc(id, inc);

        try self.insertLocalOp(tx, succ, query.range);
        try self.finalizeOp(&self.pending.items[self.pending.items.len - 1].tx, null, incrementReplacement(query.ops.items, resolved));
        return id;
    }

    /// An operation on a sequence element
    /// ([`local_list_op`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):495-558).
    ///
    /// **The element comes from the register's *first* row**, not its winner
    /// (`inner.rs:511-514`), and a register with no rows is
    /// `error.InvalidIndex` here while the map path's is "nothing to do" — the
    /// asymmetry is upstream's and it is deliberate.
    fn localListOp(
        self: *Transaction,
        obj: ObjMeta,
        index: usize,
        action: OpType,
    ) WriteError!?OpId {
        const seq = obj.typ.asSequenceType() orelse return error.InvalidOp;
        var query = try self.doc.ops.seekOpsByIndex(
            self.gpa,
            obj.id,
            index,
            seq,
            try self.scopeClock(),
        );
        defer query.deinit(self.gpa);

        const id = self.nextId();
        const elem = blk: {
            if (query.ops.items.len == 0) break :blk null;
            break :blk query.ops.items[0].cursor() catch null;
        } orelse return error.InvalidIndex;

        const resolved = query.resolveAction(action) orelse return null;
        if (resolved.isIncrement() and !anyCounter(query.ops.items)) {
            return error.MissingCounter;
        }

        const pred = try self.gpa.alloc(OpId, query.ops.items.len);
        defer self.gpa.free(pred);
        for (query.ops.items, pred) |row, *slot| slot.* = row.id();

        const succ = try self.gpa.alloc(SuccInsert, query.ops.items.len);
        defer self.gpa.free(succ);
        const tx = try TxOp.list(
            self.gpa,
            id,
            obj,
            query.end_pos,
            query.index,
            resolved,
            elem,
            pred,
        );
        const inc = tx.getIncrementValue();
        for (query.ops.items, succ) |row, *slot| slot.* = row.addSucc(id, inc);

        try self.insertLocalOp(tx, succ, query.range);
        const replacement: ?batchmod.PatchValue = incrementReplacement(query.ops.items, resolved) orelse if (seq == .text and query.ops.items.len != 0)
            patchValue(query.ops.items[0].action(), query.ops.items[0].value())
        else
            null;
        try self.finalizeOp(&self.pending.items[self.pending.items.len - 1].tx, null, replacement);
        return id;
    }

    /// An operation on one property, dispatched on the property's kind
    /// ([`local_op`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):432-444).
    fn localOp(
        self: *Transaction,
        obj: ObjMeta,
        prop: Prop,
        action: OpType,
    ) WriteError!?OpId {
        return switch (prop) {
            .key => |k| self.localMapOp(obj, k, action),
            .index => |i| self.localListOp(obj, i, action),
        };
    }

    /// An insert into a sequence
    /// ([`do_insert`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):367-402).
    ///
    /// The row position, the index it lands at and the element it hangs by all
    /// come from one [`OpSet.queryInsertAt`](opset/op_set.zig) answer, which is
    /// upstream's `QueryNth` (`op_set.rs:1441-1446`).
    fn doInsert(
        self: *Transaction,
        obj: ObjMeta,
        seq: SequenceType,
        index: usize,
        action: OpType,
    ) WriteError!Inserted {
        try self.requireOpen();
        const id = self.nextId();
        var query = try self.doc.ops.queryInsertAt(
            self.gpa,
            obj.id,
            index,
            seq,
            try self.scopeClock(),
        );
        defer query.deinit(self.gpa);

        const tx = try TxOp.insertOp(
            self.gpa,
            id,
            obj,
            query.pos,
            query.index,
            action,
            query.elemid,
        );
        // `inner.rs:396-399` — an insert has no predecessors, so no successor
        // edges and no `reset_top`, and the row goes in on its own.
        try self.insertLocalOp(tx, &.{}, .{ .start = 0, .end = 0 });
        try self.finalizeOp(&self.pending.items[self.pending.items.len - 1].tx, if (query.marks) |*set| set else null, null);
        return .{ .id = id, .pos = query.pos, .index = query.index };
    }

    /// A mark's closing anchor, placed immediately after its opening one
    /// ([`insert_mark_end_after`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):404-430).
    ///
    /// **This is not a convenience.** When a mark's `[start, end)` lies inside
    /// one multi-unit text element both anchors resolve to the same op-set
    /// position, and a plain end insert would land *before* the begin, which
    /// inverts the mark index and produces a document that will not reload
    /// (`inner.rs:833-840`).
    fn insertMarkEndAfter(
        self: *Transaction,
        obj: ObjMeta,
        begin: Inserted,
        expand: bool,
    ) WriteError!Inserted {
        const id = self.nextId();
        const tx = try TxOp.insertOp(
            self.gpa,
            id,
            obj,
            begin.pos + 1,
            begin.index,
            .{ .mark_end = .{ .expand = expand } },
            ElemId.fromOpId(begin.id),
        );
        try self.insertLocalOp(tx, &.{}, .{ .start = 0, .end = 0 });
        return .{ .id = id, .pos = begin.pos + 1, .index = begin.index };
    }

    // ── The methods ──────────────────────────────────────────────────────

    /// Writes `value` at `prop` ([`put`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):241-260).
    pub fn put(
        self: *Transaction,
        obj: ExId,
        prop: Prop,
        value: ScalarValue,
    ) WriteError!?OpId {
        const meta = try self.exidToObj(obj);
        // `inner.rs:252-257` — the property and the object type have to agree,
        // and the three arms that pass are the whole of it.
        switch (meta.typ) {
            .map, .table => if (prop != .key) return error.InvalidOp,
            .list, .text => if (prop != .index) return error.InvalidOp,
        }
        return self.localOp(meta, prop, .{ .put = value });
    }

    /// Creates an object at `prop`
    /// ([`put_object`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):275-292).
    ///
    /// **Always produces an operation.** Upstream `unwrap`s the option
    /// (`inner.rs:291`) and cannot be wrong: `resolve_action` only answers
    /// `None` for a repeated `put` and for a `delete` of nothing
    /// ([`op_set.rs:1489-1508`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
    /// and a `make` is neither.
    pub fn putObject(
        self: *Transaction,
        obj: ExId,
        prop: Prop,
        t: ObjType,
    ) WriteError!ExId {
        const meta = try self.exidToObj(obj);
        // `inner.rs:285-289` — a text object takes no `put_object`; the three
        // arms differ from `put`'s, which allows a sequence index on text.
        switch (meta.typ) {
            .map, .table => if (prop != .key) return error.InvalidOp,
            .list => if (prop != .index) return error.InvalidOp,
            .text => return error.InvalidOp,
        }
        const id = (try self.localOp(meta, prop, .{ .make = t })) orelse
            return error.Invariant;
        return self.doc.idToExid(id);
    }

    /// Inserts `value` at `index`
    /// ([`insert`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):331-347).
    pub fn insert(
        self: *Transaction,
        obj: ExId,
        index: usize,
        value: ScalarValue,
    ) WriteError!OpId {
        const meta = try self.exidToObj(obj);
        const seq = meta.typ.asSequenceType() orelse return error.InvalidOp;
        const id = try self.doInsert(meta, seq, index, .{ .put = value });
        return id.id;
    }

    /// Creates an object at `index` in a sequence
    /// ([`insert_object`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):349-365).
    pub fn insertObject(
        self: *Transaction,
        obj: ExId,
        index: usize,
        t: ObjType,
    ) WriteError!ExId {
        const meta = try self.exidToObj(obj);
        const seq = meta.typ.asSequenceType() orelse return error.InvalidOp;
        const id = try self.doInsert(meta, seq, index, .{ .make = t });
        return self.doc.idToExid(id.id);
    }

    /// Adds `by` to the counter at `prop`
    /// ([`increment`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):560-571).
    pub fn increment(
        self: *Transaction,
        obj: ExId,
        prop: Prop,
        by: i64,
    ) WriteError!void {
        const meta = try self.exidToObj(obj);
        _ = try self.localOp(meta, prop, .{ .increment = by });
    }

    /// Removes the value at `prop`
    /// ([`delete`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):573-598).
    ///
    /// **A text object is a one-element splice and everything else is a single
    /// `local_op`** (`inner.rs:582-595`), because a text element can be several
    /// units wide and a delete has to name the whole element.
    ///
    /// The count is how many delete operations were written: zero for a key that
    /// was not there, one for a map or list element, and one per *element* for
    /// a text splice. It is not a width; the width is what the caller's
    /// `del` was.
    pub fn delete(
        self: *Transaction,
        obj: ExId,
        prop: Prop,
    ) WriteError!usize {
        const meta = try self.exidToObj(obj);
        const before = self.pending.items.len;
        if (meta.typ == .text) {
            const index = prop.asIndex() orelse return error.InvalidOp;
            try self.innerSplice(meta, index, 1, .{ .text = "" });
        } else {
            _ = try self.localOp(meta, prop, .delete);
        }
        return self.pending.items.len - before;
    }

    /// Cuts a text block out of `obj` at `index`
    /// ([`split_block`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):893-929).
    pub fn splitBlock(self: *Transaction, obj: ExId, index: usize) WriteError!ExId {
        try self.requireOpen();
        const meta = try self.exidToObj(obj);
        try requireType(meta, .text);
        var query = try self.doc.ops.queryInsertAt(
            self.gpa,
            meta.id,
            index,
            .text,
            try self.scopeClock(),
        );
        defer query.deinit(self.gpa);

        const id = self.nextId();
        const tx = try TxOp.insertObj(
            self.gpa,
            id,
            meta,
            query.pos,
            query.index,
            .map,
            query.elemid,
        );
        try self.insertLocalOp(tx, &.{}, .{ .start = 0, .end = 0 });
        if (self.patch_log.recording) {
            self.patch_log.insert(meta.id, query.index, .{ .object = .map }, id, false);
            try self.checkPatchLog();
        }
        return self.doc.idToExid(id);
    }

    /// Removes the block at `index`, joining its text back together
    /// ([`join_block`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):931-982).
    pub fn joinBlock(self: *Transaction, text_obj: ExId, index: usize) WriteError!void {
        try self.requireOpen();
        const meta = try self.exidToObj(text_obj);
        try requireType(meta, .text);

        var query = try self.doc.ops.seekOpsByIndex(
            self.gpa,
            meta.id,
            index,
            .text,
            try self.scopeClock(),
        );
        defer query.deinit(self.gpa);
        // `inner.rs:954-955` — `next_back`, the element at the index, and
        // nothing there is `error.InvalidIndex`.
        if (query.ops.items.len == 0) return error.InvalidIndex;
        const target = query.ops.items[query.ops.items.len - 1];
        const elem = switch (target.elemidOrKey()) {
            .seq => |e| e,
            .map => return error.InvalidOp,
        };

        // `inner.rs:962-969` — upstream `unwrap`s this lookup, having just
        // found the row by index; the port refuses instead of trapping, and
        // the case cannot arise.
        const found = (try self.doc.ops.seekListOpid(
            meta.id,
            target.id(),
            .text,
            try self.scopeClock(),
        )) orelse return error.InvalidIndex;

        const id = self.nextId();
        var op = try TxOp.listDel(
            self.gpa,
            id,
            meta,
            index,
            elem,
            &.{found.op.id()},
        );
        var transferred = false;
        errdefer if (!transferred) op.deinit(self.gpa);
        const succ = [_]SuccInsert{found.op.addSucc(id, null)};
        try self.ownBuilderPayload(&op.bld);
        var change = changeOpOf(&op);
        errdefer if (!transferred) change.deinit(self.gpa);
        try self.pending.append(self.gpa, .{ .tx = op, .op = change });
        transferred = true;
        errdefer self.rolling_back = true;
        try self.doc.ops.addSuccWithUndo(
            &succ,
            &self.pending.items[self.pending.items.len - 1].tx.undo,
        );
        self.doc.invalidateHistoricalScopes();
        try self.finalizeOp(&self.pending.items[self.pending.items.len - 1].tx, null, null);
    }

    /// Replaces the block at `index` with a fresh empty one
    /// ([`replace_block`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):984-993).
    pub fn replaceBlock(self: *Transaction, text_obj: ExId, index: usize) WriteError!ExId {
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        try self.joinBlock(text_obj, index);
        return self.splitBlock(text_obj, index);
    }

    /// Writes a mark over `[from, to)` ([`mark`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):801-876).
    ///
    /// **`name` and `value` are borrowed** from the caller. A null `value` is
    /// the mark's own null (`op_set2/types.rs:59-60`), which is what upstream's
    /// `unmark` writes.
    pub fn mark(
        self: *Transaction,
        obj: ExId,
        from: usize,
        to: usize,
        name: []const u8,
        expand: ExpandMark,
        value: ?ScalarValue,
    ) WriteError!void {
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        const meta = try self.exidToObj(obj);
        try requireType(meta, .text);
        // `inner.rs:813-825` — a zero-width mark with no expansion is a begin
        // and an end at the same anchor, which is nonsensical, and upstream
        // writes nothing at all.
        if (from == to and expand == .none) return;

        const begin = try self.doInsert(meta, .text, from, .{ .mark_begin = .{
            .expand = expand.expandsBefore(),
            .name = name,
            .value = value orelse .null_value,
        } });

        const end: Inserted = if (from == to)
            try self.insertMarkEndAfter(meta, begin, expand.expandsAfter())
        else blk: {
            // `inner.rs:841-856` — the end's position is asked for *after* the
            // begin has been spliced, because that splice moved everything
            // after it.
            var probe = try self.doc.ops.queryInsertAt(
                self.gpa,
                meta.id,
                to,
                .text,
                try self.scopeClock(),
            );
            defer probe.deinit(self.gpa);
            if (probe.pos > begin.pos) {
                break :blk try self.doInsert(
                    meta,
                    .text,
                    to,
                    .{ .mark_end = .{ .expand = expand.expandsAfter() } },
                );
            }
            break :blk try self.insertMarkEndAfter(meta, begin, expand.expandsAfter());
        };

        // `inner.rs:861-866` — upstream `debug_assert!`s this; the port raises
        // `error.Invariant`, because a mark end before its begin is a document
        // that will not reload and a debug build is not where that is found.
        if (end.pos <= begin.pos) return error.Invariant;
        if (self.patch_log.recording) {
            self.patch_log.markSingle(meta.id, begin.index, end.index - begin.index, name, value orelse .null_value);
            try self.checkPatchLog();
        }
    }

    /// Removes a mark over `[from, to)`
    /// ([`unmark`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):879-891).
    ///
    /// Null removes the named mark (`inner.rs:879-891`). A non-null value is
    /// forwarded to `mark` and applies that value instead; this port retains
    /// the value parameter required by `API.md`.
    pub fn unmark(
        self: *Transaction,
        obj: ExId,
        from: usize,
        to: usize,
        expand: ExpandMark,
        name: []const u8,
        value: ?ScalarValue,
    ) WriteError!void {
        return self.mark(obj, from, to, name, expand, value);
    }

    /// Splice hydrated scalar/object values using this journal's allocator.
    pub fn splice(self: *Transaction, obj: ExId, pos: usize, del: isize, values_input: []const hydmod.Value) WriteError!void {
        const meta = try self.exidToObj(obj);
        switch (meta.typ) {
            .list => try self.innerSplice(meta, pos, del, .{ .list = values_input }),
            .text => {
                const joined = try joinTextValues(self.gpa, values_input);
                defer self.gpa.free(joined);
                try self.innerSplice(meta, pos, del, .{ .text = joined });
            },
            else => return error.InvalidOp,
        }
    }

    // ── Splices ──────────────────────────────────────────────────────────

    /// Inserts `values` and removes `del` units at `pos`
    /// ([`inner_splice`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):673-799).
    ///
    /// **A negative `del` is measured back from `pos`** (`inner.rs:684-691`),
    /// and a `del` that reaches past the front of the sequence is
    /// `error.InvalidIndex` rather than a clamp.
    fn innerSplice(
        self: *Transaction,
        obj: ObjMeta,
        pos: usize,
        del_in: isize,
        what: SpliceKind,
    ) WriteError!void {
        try self.requireOpen();
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        var index = pos;
        var del = del_in;
        if (del < 0) {
            const back: usize = std.math.cast(usize, @abs(del)) orelse
                return error.InvalidIndex;
            if (back > index) return error.InvalidIndex;
            index -= back;
            del = std.math.cast(isize, back) orelse return error.InvalidIndex;
        }
        const want: usize = @intCast(@max(del, 0));
        const seq = switch (what) {
            .list => SequenceType.list,
            .text => SequenceType.text,
        };

        var inserted_width: usize = 0;
        if (!what.isEmpty()) {
            var query = try self.doc.ops.queryInsertAt(
                self.gpa,
                obj.id,
                index,
                seq,
                try self.scopeClock(),
            );
            defer query.deinit(self.gpa);
            index = query.index;
            inserted_width = switch (what) {
                .text => |t| blk: {
                    var batch = Batch.init(self, query.pos);
                    const w = try batch.spliceText(obj, query.elemid, t, query.index, if (query.marks) |*set| set else null);
                    try batch.finish();
                    break :blk w;
                },
                .list => |values_input| try self.spliceListValues(obj, query.pos, query.elemid, query.index, values_input),
            };
        }

        // The deletions start *after* what was inserted (`inner.rs:757`), walk
        // forward, and re-query per element: a delete that lands inside a
        // multi-unit element has to move to its end first
        // (`inner.rs:764-772`).
        var delete_index = index + inserted_width;
        var deleted: usize = 0;
        while (deleted < want) {
            var query = try self.doc.ops.seekOpsByIndex(
                self.gpa,
                obj.id,
                delete_index,
                seq,
                try self.scopeClock(),
            );
            defer query.deinit(self.gpa);
            if (query.ops.items.len == 0) break;
            const step = query.width(seq, self.doc.textEncoding());
            if (query.index < delete_index) {
                delete_index = query.index + step;
                continue;
            }
            const elem = query.elemid() orelse return error.InvalidIndex;
            try self.deleteOne(obj, delete_index, elem, query.ops.items);
            deleted += step;
        }
        if (self.patch_log.recording and deleted != 0) {
            self.patch_log.deleteSeq(obj.id, delete_index, deleted);
            try self.checkPatchLog();
        }
    }

    /// One delete operation over a register, with its successor edges
    /// ([`next_delete`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):298-306
    /// and the loop at `:759-792`).
    fn deleteOne(
        self: *Transaction,
        obj: ObjMeta,
        index: usize,
        elem: ElemId,
        rows: []const Op,
    ) WriteError!void {
        const id = self.nextId();
        const pred = try self.gpa.alloc(OpId, rows.len);
        defer self.gpa.free(pred);
        for (rows, pred) |row, *slot| slot.* = row.id();

        const succ = try self.gpa.alloc(SuccInsert, rows.len);
        defer self.gpa.free(succ);
        var op = try TxOp.listDel(self.gpa, id, obj, index, elem, pred);
        var transferred = false;
        errdefer if (!transferred) op.deinit(self.gpa);
        for (rows, succ) |row, *slot| slot.* = row.addSucc(id, null);
        try self.ownBuilderPayload(&op.bld);
        var change = changeOpOf(&op);
        errdefer if (!transferred) change.deinit(self.gpa);
        try self.pending.append(self.gpa, .{ .tx = op, .op = change });
        transferred = true;
        errdefer self.rolling_back = true;
        try self.doc.ops.addSuccWithUndo(
            succ,
            &self.pending.items[self.pending.items.len - 1].tx.undo,
        );
    }

    /// Inserts a list of hydrated values at `pos`
    /// ([`inner.rs:710-748`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    ///
    /// **Two batches and two splices**, and that is the point: the root
    /// operations go in at `pos` and every descendant is appended at the end of
    /// the op set, so a list of nested objects costs two partition/splice/index
    /// passes rather than one per object.
    fn spliceListValues(
        self: *Transaction,
        obj: ObjMeta,
        pos: usize,
        after: ElemId,
        index: usize,
        values_input: []const hydmod.Value,
    ) WriteError!usize {
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        var queue: Queue = .init(self.gpa);
        defer queue.deinit();

        {
            var batch = Batch.init(self, pos);
            var elem = after;
            for (values_input, 0..) |_, i| {
                // **The queue borrows `values`, not the loop's copy.**
                // Upstream walks `values.iter().enumerate()`
                // ([`inner.rs:719`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
                // so `value` there is a borrow into the `Vec` and outlives the
                // loop; a `for` capture is a copy in a stack slot the next
                // iteration overwrites, so `&value` was a pointer to whatever
                // the *last* element happened to be — which is why a splice
                // of `[1, [7], "three"]` walked the scalar `"three"` as if it
                // were the nested list and answered `error.InvalidOp`.
                const value = &values_input[i];
                const made = valueObjectType(value.*);
                const action: OpType = if (made) |t|
                    .{ .make = t }
                else
                    .{ .put = value.toScalar() orelse return error.NotAnObject };
                const id = try batch.append(try TxOp.insertOp(
                    self.gpa,
                    self.nextId(),
                    obj,
                    batch.nextPos(),
                    index + i,
                    action,
                    elem,
                ));
                elem = ElemId.fromOpId(id);
                if (made) |t| try queue.push(ObjMeta{ .id = self.doc.idToExid(id), .typ = t }, value);
            }
            try batch.finish();
        }
        if (queue.len() != 0) {
            var batch = Batch.init(self, self.doc.ops.len());
            try batch.bfs(&queue);
            try batch.finish();
        }
        return values_input.len;
    }

    // ── Commit and rollback ──────────────────────────────────────────────

    /// The change's operations, in the shape [`Document.commit`] takes.
    ///
    /// The array holds **borrows** of the queued operations' `ChangeOp`s; the
    /// transaction still owns them and the caller frees only the array.
    fn changeOps(self: *const Transaction, gpa: Allocator) Allocator.Error![]const ChangeOp {
        const out = try gpa.alloc(ChangeOp, self.pending.items.len);
        for (self.pending.items, out) |*item, *slot| slot.* = item.op;
        return out;
    }

    /// Commits what this transaction has done
    /// ([`TransactionInner::commit`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):129-143).
    ///
    /// **Null for a transaction that wrote nothing**, and that is not a
    /// degenerate case: upstream drops the actor it created for the transaction
    /// and returns no change, so an empty `put` — one that repeated a value —
    /// does not add a change to the document. `TransactionInner::empty`
    /// (`:94-101`) is the one path that produces a zero-operation change, and
    /// that is [`docmod.Document.emptyCommit`].
    ///
    /// `message` and `time` override this transaction's own when they are not
    /// null, which is upstream's `if message.is_some()` /
    /// `if let Some(t)` at `:152-158`.
    /// Allocation refusal from a writable transaction leaves it open for commit
    /// retry or rollback. A partial producer refusal is instead rollback-only.
    /// Metadata overrides apply only on success. Do not dispose an open
    /// transaction without undoing its rows.
    pub fn commit(self: *Transaction) WriteError!transactionmod.CommitResult {
        return self.commitWith(transactionmod.CommitOptions.none);
    }

    pub fn commitWith(self: *Transaction, options: transactionmod.CommitOptions) WriteError!transactionmod.CommitResult {
        try self.requireOpen();
        if (self.patch_log.oom) return error.OutOfMemory;
        if (self.pending.items.len == 0) {
            try self.doc.removeUnusedActors(self.gpa);
            self.patch_log.finishTransaction(self.doc.ops.actors.items);
            self.closed = true;
            return .{ .hash = null, .patch_log = self.patch_log.take() };
        }
        const commit_message = options.message orelse self.message;
        const commit_time = options.time orelse self.time;
        const ops = try self.changeOps(self.gpa);
        defer self.gpa.free(ops);
        // **The change's metadata is this transaction's, and it is handed over
        // rather than re-derived.** Upstream's `TransactionInner::commit_impl`
        // is handed its own `actor`, `seq` and `start_op` and reads them in
        // `change_meta` ([`inner.rs`:146-189](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
        // and `AutoCommit` builds the isolation **once**, at
        // `ensure_transaction_open`
        // ([`autocommit.rs`:445-457](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
        // before a single op is written.
        //
        // **Re-deriving it here is what put an isolated change on the wrong
        // actor**, and it was not a subtle one: [`Document.commit`](doc.zig)
        // called `transactionArgs(gpa, self.isolation)`, `self.isolation` is
        // null for a transaction opened with
        // [`Transaction.openAt`](transact.zig) rather than
        // [`Document.isolate`](doc.zig), so the re-derivation took the
        // *unscoped* arm and named the document's own actor. Measured on
        // `test/upstream_doc_test.zig`'s "a transaction can be opened at
        // historical heads": the third transaction wrote its rows as actor 1
        // and its change landed in the graph as actor 0 (`seq = 3,
        // maxOp = 25`, with actor 1 at `seq = 0`), so the fourth transaction's
        // `isolate_actor` walk found the fork covered and reused it, and
        // `Clock.isolate` then marked a slot holding the previous change's
        // ops — one change too new, which is the whole of that test's
        // failure.
        //
        // `deps` stays this transaction's and is **not** freed here:
        // [`Document.commit`](doc.zig) borrows it, and
        // [`Transaction.deinit`](transact.zig) still owns it.
        const hash = try self.doc.commit(self.gpa, .{
            .actor_index = self.actor,
            .seq = self.seq,
            .start_op = self.start_op,
            .deps = self.deps,
            .scope = self.scope_heads,
            .author = null,
        }, ops, commit_message, commit_time);
        for (self.pending.items) |*item| item.deinit(self.gpa);
        self.pending.clearRetainingCapacity();
        self.message = commit_message;
        self.time = commit_time;
        self.closed = true;
        self.patch_log.finishTransaction(self.doc.ops.actors.items);
        return .{ .hash = hash, .patch_log = self.patch_log.take() };
    }

    /// Takes back everything this transaction did, and returns how many
    /// operations it cancelled
    /// ([`TransactionInner::rollback`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):211-227).
    ///
    /// Undo runs in reverse order (`inner.rs:211-227`). On refusal, successful
    /// undo records are already disposed and `cancelled` records progress.
    /// Retry `rollback` to continue; writes and commit are then refused.
    pub fn rollback(self: *Transaction) WriteError!usize {
        if (self.closed) return error.InvalidOp;
        self.rolling_back = true;
        while (self.pending.items.len != 0) {
            const last = self.pending.items.len - 1;
            if (self.pending.items[last].published) {
                try self.doc.ops.undoOp(&self.pending.items[last].tx);
            }
            self.doc.invalidateHistoricalScopes();
            var item = self.pending.pop().?;
            item.deinit(self.gpa);
            self.cancelled += 1;
        }
        try self.doc.removeUnusedActors(self.gpa);
        self.patch_log.rollbackTransaction(self.doc.ops.actors.items);
        self.closed = true;
        return self.cancelled;
    }

    /// Move the retained log after terminal rollback. Calling before closure
    /// would split the sole transaction owner and is not permitted.
    pub fn takePatchLog(self: *Transaction) patchesmod.PatchLog {
        std.debug.assert(self.closed);
        return self.patch_log.take();
    }

    // ── The read side ──────────────────────────────────────────────────

    /// The value at `obj`'s property `prop`, with the id of the operation that
    /// put it there, **as this transaction sees it**
    /// ([`impl_read_doc_for_tx!`](../../github-automerge-automerge/rust/automerge/src/transaction.rs):241-248).
    ///
    /// ```
    /// self.doc.get_for(obj, prop.into(), self.get_scope(None))
    /// ```
    ///
    /// The complete ReadDoc surface below shares this transaction's write clock;
    /// each explicit-head variant instead borrows a retained historical clock.
    ///
    /// **`get_scope(None)` is not `get_scope(heads)`, and `None` is not "no
    /// scope".** [`manual_transaction.rs:113-122`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)
    /// is the whole rule:
    ///
    /// | argument | the clock the read runs at |
    /// |---|---|
    /// | `Some(h)` | `doc.change_graph.clock_at(h)` — the heads, and **never** the transaction's own scope |
    /// | `None` | [`scopeClock`](transact.zig), which is null only when the transaction was opened without heads |
    ///
    /// So **a read through a scoped transaction is scoped even when the caller
    /// names no heads**: a transaction opened at some heads reads the document
    /// as it stood at those heads, while [`readmod.get`](read.zig) on the same
    /// document at the same moment reads the present. Both are right; the test
    /// `test "a read through a scoped transaction is scoped, and a read through the document is not"`
    /// is the one that says which is which. Upstream's `can_transaction_at`
    /// ([`test.rs:2507-2546`](../../github-automerge-automerge/rust/automerge/tests/test.rs))
    /// is four such reads.
    ///
    /// **It also sees this transaction's own pending writes**, because they are
    /// rows in the document's op set before the transaction ends
    /// ([`inner.rs:308-328`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    /// and this read goes through that op set. `test.rs:2517-2521` is upstream's
    /// own statement of it: `tx.put(..)` and then `tx.get(..)` answers the new
    /// value.
    ///
    /// **Ownership and refusals are [`readmod.getAtScope`](read.zig)'s**: a
    /// borrowed [`readmod.DocItem`](read.zig) valid until the next mutation, and
    /// `NotAnObject` / `InvalidOp` / `null` for the three cases its table names.
    pub fn get(self: *Transaction, obj: ExId, prop: Prop) readmod.ReadError!?readmod.DocItem {
        return readmod.getAtScope(self.doc, obj, prop, try self.scopeClock());
    }

    pub fn allocator(self: *const Transaction) Allocator {
        return self.gpa;
    }

    fn readClock(self: *Transaction, heads: ?[]const ChangeHash) readmod.ReadError!?Clock {
        if (heads) |at| return try readmod.historicalScope(self.doc, at);
        return self.scopeClock();
    }

    pub fn getAt(self: *Transaction, obj: ExId, prop: Prop, heads: []const ChangeHash) readmod.ReadError!?readmod.DocItem {
        return readmod.getAtScope(self.doc, obj, prop, try self.readClock(heads));
    }

    pub fn getAll(self: *Transaction, obj: ExId, prop: Prop, gpa: Allocator) readmod.ReadError![]readmod.DocItem {
        return readmod.getAllAtScope(self.doc, obj, prop, try self.scopeClock(), gpa);
    }

    pub fn getAllAt(self: *Transaction, obj: ExId, prop: Prop, heads: []const ChangeHash, gpa: Allocator) readmod.ReadError![]readmod.DocItem {
        return readmod.getAllAtScope(self.doc, obj, prop, try self.readClock(heads), gpa);
    }

    pub fn keys(self: *Transaction, obj: ExId) readmod.ReadError!readmod.Keys {
        return readmod.keysAtScope(self.doc, obj, try self.scopeClock());
    }

    pub fn keysAt(self: *Transaction, obj: ExId, heads: []const ChangeHash) readmod.ReadError!readmod.Keys {
        return readmod.keysAtScope(self.doc, obj, try self.readClock(heads));
    }

    pub fn mapRange(self: *Transaction, obj: ExId, range: readmod.KeyRange) readmod.ReadError!readmod.MapRange {
        return readmod.mapRangeAtScope(self.doc, obj, range, try self.scopeClock());
    }

    pub fn mapRangeAt(self: *Transaction, obj: ExId, range: readmod.KeyRange, heads: []const ChangeHash) readmod.ReadError!readmod.MapRange {
        return readmod.mapRangeAtScope(self.doc, obj, range, try self.readClock(heads));
    }

    pub fn listRange(self: *Transaction, obj: ExId, range: readmod.IndexRange) readmod.ReadError!readmod.ListRange {
        return readmod.listRangeAtScope(self.doc, obj, range, try self.scopeClock());
    }

    pub fn listRangeAt(self: *Transaction, obj: ExId, range: readmod.IndexRange, heads: []const ChangeHash) readmod.ReadError!readmod.ListRange {
        return readmod.listRangeAtScope(self.doc, obj, range, try self.readClock(heads));
    }

    pub fn values(self: *Transaction, obj: ExId, term: *readmod.ValueTerm) readmod.ReadError!readmod.Values {
        return readmod.valuesAtScope(self.doc, obj, term, try self.scopeClock());
    }

    pub fn valuesAt(self: *Transaction, obj: ExId, heads: []const ChangeHash, term: *readmod.ValueTerm) readmod.ReadError!readmod.Values {
        return readmod.valuesAtScope(self.doc, obj, term, try self.readClock(heads));
    }

    pub fn length(self: *Transaction, obj: ExId) readmod.ReadError!usize {
        return readmod.lengthAtScope(self.doc, obj, try self.scopeClock());
    }

    pub fn lengthAt(self: *Transaction, obj: ExId, heads: []const ChangeHash) readmod.ReadError!usize {
        return readmod.lengthAtScope(self.doc, obj, try self.readClock(heads));
    }

    pub fn objectType(self: *const Transaction, obj: ExId) Error!ObjType {
        return self.doc.objectType(obj);
    }

    pub fn text(self: *Transaction, obj: ExId, gpa: Allocator) readmod.ReadError![]u8 {
        return readmod.textAtScope(self.doc, obj, try self.scopeClock(), gpa);
    }

    pub fn textAt(self: *Transaction, obj: ExId, heads: []const ChangeHash, gpa: Allocator) readmod.ReadError![]u8 {
        return readmod.textAtScope(self.doc, obj, try self.readClock(heads), gpa);
    }

    pub fn spans(self: *Transaction, obj: ExId, gpa: Allocator) readmod.ReadError!readmod.Spans {
        return readmod.spansAtScope(self.doc, obj, try self.scopeClock(), gpa);
    }

    pub fn spansAt(self: *Transaction, obj: ExId, heads: []const ChangeHash, gpa: Allocator) readmod.ReadError!readmod.Spans {
        return readmod.spansAtScope(self.doc, obj, try self.readClock(heads), gpa);
    }

    pub fn marks(self: *Transaction, obj: ExId, gpa: Allocator) readmod.ReadError![]Mark {
        return readmod.marksAtScope(self.doc, obj, try self.scopeClock(), gpa);
    }

    pub fn marksAt(self: *Transaction, obj: ExId, heads: []const ChangeHash, gpa: Allocator) readmod.ReadError![]Mark {
        return readmod.marksAtScope(self.doc, obj, try self.readClock(heads), gpa);
    }

    pub fn getMarks(self: *Transaction, obj: ExId, from: usize, max: usize, gpa: Allocator) readmod.ReadError![]Mark {
        return readmod.getMarksAtScope(self.doc, obj, from, max, try self.scopeClock(), gpa);
    }

    pub fn parents(self: *Transaction, obj: ExId) readmod.ReadError!readmod.Parents {
        return readmod.parentsAtScope(self.doc, obj, try self.scopeClock());
    }

    pub fn parentsAt(self: *Transaction, obj: ExId, heads: []const ChangeHash) readmod.ReadError!readmod.Parents {
        return readmod.parentsAtScope(self.doc, obj, try self.readClock(heads));
    }

    pub fn iter(self: *Transaction, gpa: Allocator) readmod.DiffError!readmod.DocIter {
        return readmod.iterAtScope(self.doc, .root, try self.scopeClock(), gpa);
    }

    pub fn iterAt(self: *Transaction, obj: ExId, heads: ?[]const ChangeHash, gpa: Allocator) readmod.DiffError!readmod.DocIter {
        return readmod.iterAtScope(self.doc, obj, try self.readClock(heads), gpa);
    }

    pub fn getCursor(self: *Transaction, obj: ExId, pos: readmod.CursorPosition, heads: ?[]const ChangeHash, gpa: Allocator) readmod.ReadError!readmod.Cursor {
        return self.getCursorMoving(obj, pos, heads, .after, gpa);
    }

    pub fn getCursorMoving(self: *Transaction, obj: ExId, pos: readmod.CursorPosition, heads: ?[]const ChangeHash, bias: readmod.Bias, gpa: Allocator) readmod.ReadError!readmod.Cursor {
        return readmod.getCursorMovingAtScope(self.doc, obj, pos, bias, try self.readClock(heads), gpa);
    }

    pub fn getCursorPosition(self: *Transaction, obj: ExId, cursor: readmod.Cursor, heads: ?[]const ChangeHash) readmod.ReadError!usize {
        return readmod.getCursorPositionFor(self.doc, obj, cursor, try self.readClock(heads));
    }

    /// Hydration is the ReadDoc exception: it resolves the raw document view,
    /// not this transaction's write scope.
    pub fn hydrate(self: *Transaction, obj: ExId, heads: ?[]const ChangeHash, gpa: Allocator) readmod.HydrateError!hydmod.Value {
        return readmod.hydrate(self.doc, obj, heads, gpa);
    }

    pub fn getMissingDeps(self: *const Transaction, heads: []const ChangeHash, gpa: Allocator) readmod.ChangeError![]ChangeHash {
        return readmod.getMissingDeps(self.doc, heads, gpa);
    }

    pub fn getChangeByHash(self: *const Transaction, hash: ChangeHash, gpa: Allocator) readmod.ChangeError!?docmod.Built {
        return readmod.getChangeByHash(self.doc, hash, gpa);
    }

    pub fn stats(self: *const Transaction) docmod.Stats {
        return self.doc.stats();
    }

    /// The marks covering `index` of the sequence `obj`, at `heads` or at this
    /// transaction's own scope
    /// ([`impl_read_doc_for_tx!`](../../github-automerge-automerge/rust/automerge/src/transaction.rs):231-239).
    ///
    /// ```
    /// self.doc.get_marks_for(obj.as_ref(), index, self.get_scope(heads))
    /// ```
    ///
    /// **Upstream's `ReadDoc::get_marks` on a transaction.** The port spells it
    /// `markSetAtIndex` and not `getMarks` because
    /// [`readmod.getMarks`](read.zig) is a *window* over `[]Mark` and not
    /// upstream's method at all; the single-index `MarkSet` read is this one
    /// and [`readmod.markSetAtIndex`](read.zig).
    ///
    /// **`heads` is [`get`](transact.zig)'s argument, unchanged**: `Some(h)`
    /// reads at `clock_at(h)` and `None` reads at [`scopeClock`](transact.zig).
    /// The difference is not cosmetic here, it is the whole test: upstream's
    /// `get_marks_at_heads` ([`test.rs:2681-2713`](../../github-automerge-automerge/rust/automerge/tests/test.rs))
    /// sets the mark to `Null` **in an open transaction** and then reads at the
    /// heads from before that mark, and gets the old mark back — because the
    /// pending operation is in the op set but in no clock at those heads.
    ///
    /// **Ownership: the set is the caller's**, `MarkSet.deinit` it, and its
    /// names are the document's, valid until the next mutation.
    pub fn markSetAtIndex(
        self: *Transaction,
        obj: ExId,
        index: usize,
        heads: ?[]const ChangeHash,
        gpa: Allocator,
    ) readmod.ReadError!marksmod.MarkSet {
        return readmod.markSetAtScope(self.doc, obj, index, try self.readClock(heads), gpa);
    }

    // ── The diff sinks ───────────────────────────────────────────────────

    /// [`textdiff.Sink`]'s `textFor` ([`doc.text_for`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):22).
    ///
    /// Borrowed bytes remain valid until the next successful `textFor` or
    /// `deinit`. Failure preserves the previous buffer. Do not free the slice.
    ///
    /// **The scope clock is the transaction's** — `doc.text_for(text_obj,
    /// tx.get_scope().clone())` (`:22`) — so an isolated transaction diffs
    /// against the text *as the isolation sees it* and not the whole
    /// document, and the id is resolved first for the reason
    /// [`exidToObj`] gives: [`OpSet.text`](opset/op_set.zig) scopes rows by the
    /// id it is handed, so a stale index would read no rows at all and the diff
    /// would see an empty old text and re-insert everything.
    pub fn textFor(self: *Transaction, obj: ExId) WriteError![]const u8 {
        const live = self.doc.resolve(obj) orelse return error.NotAnObject;
        const bytes = try self.doc.ops.text(self.gpa, live, try self.scopeClock());
        if (self.text_cache) |previous| self.gpa.free(previous);
        self.text_cache = bytes;
        return bytes;
    }

    /// Takes the transaction's own copy of `text` and returns it, for the
    /// value of an operation this transaction is about to queue.
    ///
    /// **This is the write half of [`textFor`]'s contract.** A diff hook
    /// builds the text it splices in a local and frees it when the call
    /// returns — [`TxHook.insert`](textdiff.zig) and
    /// [`TxHook.replace`](textdiff.zig) on a `concat`,
    /// [`BlockDiffHook.insert`](textdiff.zig) on a `run` — while the
    /// operations it produces are queued and not encoded until [`commit`], so
    /// an operation that borrowed the hook's buffer reads freed bytes there.
    /// Upstream needs no such function because its `TxOp` holds an
    /// `OpBuilder<'static>` ([`op.rs:164-170`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    /// which a borrow of a local cannot satisfy.
    fn ownText(self: *Transaction, text_input: []const u8) WriteError![]const u8 {
        const copy = try self.gpa.dupe(u8, text_input);
        errdefer self.gpa.free(copy);
        try self.owned.append(self.gpa, copy);
        return copy;
    }

    /// [`textdiff.Sink`]'s `textEncoding` ([`:26`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
    pub fn textEncoding(self: *const Transaction) TextEncoding {
        return self.doc.textEncoding();
    }

    /// [`textdiff.Sink`]'s `spliceText` ([`tx.splice_text`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):85-92).
    ///
    /// **`text` is borrowed for the call only**; the operations written from
    /// it keep the transaction's own copy of every unit, so the change
    /// [`commit`] encodes still reads the characters that were spliced in.
    pub fn spliceText(
        self: *Transaction,
        obj: ExId,
        index: usize,
        del: isize,
        text_input: []const u8,
    ) WriteError!void {
        const meta = try self.exidToObj(obj);
        try requireType(meta, .text);
        try self.innerSplice(meta, index, del, .{ .text = text_input });
    }

    /// The block at `index`, for [`textdiff.updateBlock`]
    /// ([`doc.get(obj, index)`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):510-512).
    pub fn blockAt(self: *Transaction, obj: ExId, index: usize) WriteError!?ExId {
        const meta = try self.exidToObj(obj);
        var query = try self.doc.ops.seekOpsByIndex(
            self.gpa,
            meta.id,
            index,
            .text,
            try self.scopeClock(),
        );
        defer query.deinit(self.gpa);
        if (query.ops.items.len == 0) return null;
        const last = query.ops.items[query.ops.items.len - 1];
        if (last.action().objType() == null) return null;
        return self.doc.idToExid(last.id());
    }

    /// [`textdiff.updateText`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):15-44)
    /// over this transaction.
    ///
    /// **The diff is handed `meta.id`, the resolved id, not the caller's.**
    /// Upstream can pass the caller's because its [`ExId`](types.zig) carries
    /// the actor's bytes and every reader below re-resolves them
    /// ([`automerge.rs:744-758`](../../github-automerge-automerge/rust/automerge/src/automerge.rs));
    /// the port's readers take the op set's object id directly, so the
    /// resolution has to have happened once, here, and the resolved value is
    /// what the diff anchors its splices on.
    pub fn updateText(self: *Transaction, obj: ExId, new_text: []const u8) WriteError!void {
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        const meta = try self.exidToObj(obj);
        try requireType(meta, .text);
        var sink = TextSink{ .tx = self };
        try textdiff.myersDiff(self.gpa, TextSink, &sink, meta.id, new_text);
    }

    /// One register of the object being brought in line, **copied out of the
    /// op set** — see [`updateMapValue`] for why the copy is the whole point.
    const CurrentRegister = struct {
        /// The register's key, the op set's own copy of it.
        key: []const u8,
        /// The winner row, by value.
        old: opmod.Op,
    };

    /// Gives the object `id` the contents of `value`
    /// ([`update_map`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1096-1146).
    ///
    /// **Keys are visited in sorted order, twice.** Hydrated maps and the sets
    /// built from them have no order of their own, so additions and deletions
    /// are sorted before they are applied — upstream says why at `:1128-1131`
    /// and it is determinism of the operation ids, not tidiness.
    ///
    /// **The walk is drained into owned copies before a single operation is
    /// written** (`inner.rs:1105-1109`, the `.collect::<Vec<_>>()` on
    /// `map_range`). That collect is load-bearing rather than incidental:
    /// `update_value` takes `&mut self` and `&mut Automerge`, so Rust cannot
    /// let the loop keep a borrow of `doc.ops()` across it — upstream has to
    /// own the key, the value and the id before the first write. The port has
    /// no such check, and writing inside the walk splices new rows under a
    /// [`opmod.Op`] that is a borrow of the op set's successor scratch and a
    /// key that is a slice of its string table; the walk then read past the
    /// end of a column and answered `error.Fail` from the middle of
    /// `updateObject`. The copies are what upstream's borrow checker asks for.
    pub fn updateMapValue(self: *Transaction, id: ExId, value: *const hydmod.Map) WriteError!void {
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        const meta = try self.exidToObj(id);
        if (meta.typ != .map and meta.typ != .table) return error.InvalidOp;

        var current: std.ArrayList(CurrentRegister) = .empty;
        defer {
            for (current.items) |c| self.gpa.free(c.key);
            current.deinit(self.gpa);
        }
        {
            var winners = try self.doc.ops.topOps(meta.id, try self.scopeClock());
            defer winners.deinit(self.gpa);
            while (try winners.next()) |row| {
                const key = switch (row.key()) {
                    .map => |k| k,
                    .seq => continue,
                };
                const owned = try self.gpa.dupe(u8, key);
                errdefer self.gpa.free(owned);
                try current.append(self.gpa, .{ .key = owned, .old = row });
            }
        }

        var delenda: std.ArrayList([]const u8) = .empty;
        defer delenda.deinit(self.gpa);
        var present: std.StringHashMapUnmanaged(void) = .empty;
        defer present.deinit(self.gpa);

        for (current.items) |c| {
            try present.put(self.gpa, c.key, {});
            if (value.get(c.key)) |new| {
                try self.updateValue(meta.id, .{ .key = c.key }, new, c.old);
            } else {
                try delenda.append(self.gpa, c.key);
            }
        }
        std.mem.sort([]const u8, delenda.items, {}, strLessThan);

        // Additions, sorted (`inner.rs:1132-1139`).
        var added: std.ArrayList([]const u8) = .empty;
        defer added.deinit(self.gpa);
        var it = value.entries.iterator();
        while (it.next()) |entry| {
            if (!present.contains(entry.key_ptr.*)) {
                try added.append(self.gpa, entry.key_ptr.*);
            }
        }
        std.mem.sort([]const u8, added.items, {}, strLessThan);
        for (added.items) |key| {
            if (Transaction.entryValue(value, key)) |v| try self.updateValue(meta.id, .{ .key = key }, v, null);
        }
        // Deletions, sorted (`inner.rs:1140-1144`).
        for (delenda.items) |key| {
            const n = try self.delete(meta.id, .{ .key = key });
            _ = n;
        }
    }

    /// Brings a list object in line with `value`
    /// ([`update_list`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1148-1201).
    ///
    /// **Both sequences are zipped against an endless `None`** (`inner.rs:1158-1164`),
    /// so the loop runs until one side runs out *and the other does too*, and
    /// a shorter new list turns the tail into `to_delete` rather than
    /// stopping. The walk is drained into owned rows before the first write,
    /// for the reason [`updateMapValue`] gives: an [`opmod.Op`] borrows the op
    /// set's successor scratch, and a write inside the walk splices new rows
    /// under it.
    pub fn updateListValue(self: *Transaction, id: ExId, value: *const hydmod.List) WriteError!void {
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        const meta = try self.exidToObj(id);
        if (meta.typ != .list) return error.InvalidOp;

        var old: std.ArrayList(opmod.Op) = .empty;
        defer old.deinit(self.gpa);
        {
            var winners = try self.doc.ops.topOps(meta.id, try self.scopeClock());
            defer winners.deinit(self.gpa);
            while (try winners.next()) |row| try old.append(self.gpa, row);
        }

        var to_delete: usize = 0;
        var index: usize = 0;
        while (true) : (index += 1) {
            const o: ?opmod.Op = if (index < old.items.len) old.items[index] else null;
            const n: ?*const hydmod.Value = if (index < value.count()) value.get(index) else null;
            // `inner.rs:1168-1195`. **The order of the two arms is upstream's
            // and it matters in neither direction**, but the `(None, None)`
            // arm is the loop's only exit: both sequences are zipped against
            // an endless `None`, so the pair only reaches it once each side
            // has run out.
            if (o == null and n == null) break;
            // `inner.rs:1169-1181` and `:1182-1191`: replace in place when
            // there is an old row, insert at the end when there is not.
            if (n) |new| {
                try self.updateValue(meta.id, .{ .index = index }, new, o);
            } else {
                to_delete += 1;
            }
        }
        // `inner.rs:1197-1199`: **the first `to_delete` indices, highest
        // first**, because deleting index 0 shifts everything down.
        var i = to_delete;
        while (i > 0) {
            i -= 1;
            _ = try self.delete(meta.id, .{ .index = i });
        }
    }

    /// Brings a text object in line with `value`
    /// ([`crate::text_diff::myers_diff`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):22).
    ///
    /// Upstream's arm is a call and not a method of its own
    /// (`inner.rs:1219-1221`), so this is [`updateText`] with the hydrated
    /// text's own bytes: a diff against the current text, which is what
    /// `myers_diff` takes.
    /// Update an existing object without changing its type.
    pub fn updateObject(self: *Transaction, id: ExId, value: *const hydmod.Value) WriteError!void {
        try self.requireOpen();
        const before = self.pending.items.len;
        errdefer if (self.pending.items.len != before) {
            self.rolling_back = true;
        };
        const meta = try self.exidToObj(id);
        switch (value.*) {
            .object => |object| switch (object) {
                .map => |*map| if (meta.typ == .map) return self.updateMapValue(id, map),
                .list => |*list| if (meta.typ == .list) return self.updateListValue(id, list),
                .text => |*text_value| if (meta.typ == .text) return self.updateTextValue(id, text_value),
            },
            else => {},
        }
        return error.ChangeType;
    }

    pub fn updateTextValue(self: *Transaction, id: ExId, value: *const hydmod.Text) WriteError!void {
        const rendered = try value.makeString(self.gpa);
        defer self.gpa.free(rendered);
        return self.updateText(id, rendered);
    }

    /// The value `key` holds in `value`, borrowed from it, or null.
    fn entryValue(value: *const hydmod.Map, key: []const u8) ?*const hydmod.Value {
        return value.get(key);
    }

    /// One property of one object, brought to `new_value`
    /// ([`update_value`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1203-1256).
    fn updateValue(
        self: *Transaction,
        parent: ExId,
        prop: Prop,
        new_value: *const hydmod.Value,
        old: ?opmod.Op,
    ) WriteError!void {
        // `inner.rs:1212-1221` — one arm per pair of *same kind*, and the
        // kinds are compared, not just the new value's: a table is a map for
        // this purpose, because `update_map` writes keys either way.
        //
        // **All three arms are load-bearing.** The port had only the map one,
        // and every list or text below a hydrated root fell through to the
        // wholesale replace and then to `error.NotAnObject` — which is how
        // `rollback_after_save_load_of_deep_hydrated_root_map_from_fuzz_trace`
        // died at depth 42 (`test.rs:601-614`, `fuzz_hydrated_value` returns a
        // list or a text at three seeds in four).
        if (old) |row| {
            const made = row.action().objType();
            const live = self.doc.idToExid(row.id());
            switch (new_value.*) {
                .object => |o| switch (o) {
                    .map => |m| if (made == .map or made == .table) {
                        return self.updateMapValue(live, &m);
                    },
                    .list => |l| if (made == .list) {
                        return self.updateListValue(live, &l);
                    },
                    .text => |t| if (made == .text) {
                        return self.updateTextValue(live, &t);
                    },
                },
                else => {},
            }
        }
        // Otherwise the type is changing or there is nothing there, and the
        // object is replaced wholesale (`inner.rs:1222-1255`).
        switch (new_value.*) {
            .object => |o| switch (o) {
                .map => |m| {
                    const id = try self.makeChild(parent, prop, .map);
                    return self.updateMapValue(id, &m);
                },
                .list => |l| {
                    const id = try self.makeChild(parent, prop, .list);
                    return self.updateListValue(id, &l);
                },
                .text => |t| {
                    const id = try self.makeChild(parent, prop, .text);
                    // `inner.rs:1242-1245`: a new text object is filled by
                    // splicing the whole string in at zero, not by a diff
                    // against an empty one.
                    const rendered = try t.makeString(self.gpa);
                    defer self.gpa.free(rendered);
                    return self.spliceText(id, 0, 0, rendered);
                },
            },
            else => {},
        }
        const scalar = new_value.toScalar() orelse return error.NotAnObject;
        switch (prop) {
            .index => |i| _ = try self.insert(parent, i, scalar),
            .key => |k| _ = try self.put(parent, .{ .key = k }, scalar),
        }
    }

    /// Creates an object at `prop` for [`updateValue`] to fill
    /// ([`inner.rs:1225-1230`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    fn makeChild(self: *Transaction, parent: ExId, prop: Prop, t: ObjType) WriteError!ExId {
        return switch (prop) {
            .index => |i| self.insertObject(parent, i, t),
            .key => |k| self.putObject(parent, .{ .key = k }, t),
        };
    }

    /// Creates an object of type `t` at `prop` and returns it, batched
    /// ([`batch_create_object`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1269-1331).
    ///
    /// **This is the root half of upstream's method.** Upstream's takes the
    /// whole `hydrate::Value` and fills it with
    /// [`batch_bfs`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1539-1603;
    /// `API.md` narrows it to a type, so this makes the object and leaves it
    /// empty. [`batchCreateValue`] is the same method with the value, and
    /// [`initRootFromHydrate`] is the same batch over the document root.
    pub fn batchCreateObject(
        self: *Transaction,
        obj: ExId,
        prop: Prop,
        t: ObjType,
    ) WriteError!ExId {
        const meta = try self.exidToObj(obj);
        switch (meta.typ) {
            .map, .table => if (prop != .key) return error.InvalidOp,
            .list => if (prop != .index) return error.InvalidOp,
            .text => return error.InvalidOp,
        }
        const id = (try self.localOp(meta, prop, .{ .make = t })) orelse
            return error.Invariant;
        return self.doc.idToExid(id);
    }

    /// Creates an object of the kind `value` is and fills it, in one batch
    /// ([`batch_create_object`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1269-1331).
    pub fn batchCreateValue(
        self: *Transaction,
        obj: ExId,
        prop: Prop,
        value: hydmod.Value,
        as_insert: bool,
    ) WriteError!ExId {
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        const meta = try self.exidToObj(obj);
        const root_type = valueObjectType(value) orelse return error.NotAnObject;
        // `inner.rs:1280-1285`. **A sequence property on a list is allowed
        // whether or not this is an insert**: upstream refuses only
        // `(Prop::Seq, false, ObjType::Text)`, and a list takes both an
        // insert and a replace at an index. The port used to refuse
        // `(Prop::Seq, false, ObjType::List)` too, which is the shape
        // `diff_exposes_list_object_when_conflict_winner_is_removed` writes
        // (`test.rs:4273`, `batch_create_object(&list, 0, &value, false)`).
        switch (meta.typ) {
            .map, .table => if (prop != .key) return error.InvalidOp,
            .list => if (prop != .index) return error.InvalidOp,
            .text => if (prop != .index or !as_insert) return error.InvalidOp,
        }
        // `inner.rs:1296-1313`: **only a `Prop::Seq` insert goes through
        // `do_insert`.** Every other combination — a map key, and a sequence
        // index without `insert` — is a `local_op`, which for a sequence index
        // is a replace in place.
        const id: OpId = switch (prop) {
            .index => |i| if (as_insert)
                (try self.doInsert(meta, meta.typ.asSequenceType() orelse return error.InvalidOp, i, .{ .make = root_type })).id
            else
                (try self.localOp(meta, prop, .{ .make = root_type })) orelse
                    return error.Invariant,
            .key => (try self.localOp(meta, prop, .{ .make = root_type })) orelse
                return error.Invariant,
        };
        errdefer self.rolling_back = true;

        var queue: Queue = .init(self.gpa);
        defer queue.deinit();
        try queue.push(ObjMeta{ .id = self.doc.idToExid(id), .typ = root_type }, &value);
        var batch = Batch.init(self, self.doc.ops.len());
        try batch.bfs(&queue);
        try batch.finish();
        return self.doc.idToExid(id);
    }

    /// Fills the document root from `value`
    /// ([`batch_init_root_map`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1334-1380).
    ///
    /// **Keys are sorted before anything is written** (`inner.rs:1350`), which
    /// is what makes the operation ids — and so the change hash — the same on
    /// every run over the same value.
    ///
    /// Fresh documents use the reference's single contiguous splice. A retained
    /// root cannot: its registers and earlier child objects already occupy the
    /// physical order. Publish those root rows at their full register ends,
    /// preserving sorted creation order, then batch only the fresh BFS children.
    pub fn initRootFromHydrate(self: *Transaction, value: *const hydmod.Map) WriteError!void {
        try self.requireOpen();
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        const root = ObjMeta.root();
        const fresh_document = self.doc.ops.len() == 0;
        var batch = Batch.init(self, self.doc.ops.len());
        var queue: Queue = .init(self.gpa);
        defer queue.deinit();

        var key_names: std.ArrayList([]const u8) = .empty;
        defer key_names.deinit(self.gpa);
        var it = value.entries.iterator();
        while (it.next()) |entry| try key_names.append(self.gpa, entry.key_ptr.*);
        std.mem.sort([]const u8, key_names.items, {}, strLessThan);

        for (key_names.items) |key| {
            const child = Transaction.entryValue(value, key) orelse continue;
            const made = valueObjectType(child.*);
            const action: OpType = if (made) |t|
                .{ .make = t }
            else
                .{ .put = child.toScalar() orelse return error.NotAnObject };
            const id = if (fresh_document)
                try batch.appendRoot(root, key, action)
            else
                try self.insertHydratedRoot(key, action);
            if (made) |t| {
                try queue.push(ObjMeta{ .id = self.doc.idToExid(id), .typ = t }, child);
            }
        }
        if (!fresh_document) batch = Batch.init(self, self.doc.ops.len());
        try batch.bfs(&queue);
        try batch.finish();
    }

    /// Publishes the reference initializer's no-predecessor operation, not an
    /// ordinary map overwrite/no-op (`inner.rs:1356-1364`). Only placement and
    /// derived winner indexes differ from the fresh-object batch path.
    fn insertHydratedRoot(self: *Transaction, key: []const u8, action: OpType) WriteError!OpId {
        const rows = try self.doc.ops.propRange(.root, key);
        const id = self.nextId();
        var op = try TxOp.map(self.gpa, id, ObjMeta.root(), rows.end, .{
            .visible_update = action,
        }, key, &.{});
        // Empty predecessors retain existing conflicts/history. The newest
        // root row wins, but earlier visible rows must lose their top bit.
        // Undo owns this range before publication or winner updates can refuse.
        if (rows.start != rows.end) op.reset_range = .{ .start = rows.start, .end = rows.end };
        try self.insertLocalOp(op, &.{}, rows);
        errdefer self.rolling_back = true;
        if (self.scope_heads == null and rows.start != rows.end) {
            try self.doc.ops.resetTop(.{ .start = rows.start, .end = rows.end + 1 });
        }
        try self.finalizeOp(&self.pending.items[self.pending.items.len - 1].tx, null, null);
        return id;
    }

    /// Brings a text object in line with `spans`, marks and all
    /// ([`myers_block_diff`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):136-163
    /// and [`apply_marks_diff`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):165-248).
    ///
    /// **Two passes, and the second one is why this is not a splice.** The
    /// first brings the text and the block structure in line; the second
    /// re-derives every mark from the spans, because a mark is not part of the
    /// text's bytes and a diff over graphemes cannot see one.
    pub fn updateSpans(self: *Transaction, obj: ExId, spans_input: []const SpanInput) WriteError!void {
        var config = UpdateSpansConfig.init(self.gpa);
        defer config.deinit();
        return self.updateSpansWithConfig(obj, &config, spans_input);
    }

    /// [`updateSpans`] with the expand flags in `config`
    /// ([`myers_block_diff`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):136-143,
    /// which takes `config: &crate::marks::UpdateSpansConfig` and hands it to
    /// the mark pass at [`:162`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
    ///
    /// **`config` is borrowed** and is read only by the second pass, and only
    /// for a mark name the config names. An empty config is upstream's
    /// `UpdateSpansConfig::default()`, so this is what [`updateSpans`] calls.
    pub fn updateSpansWithConfig(
        self: *Transaction,
        obj: ExId,
        config: *const UpdateSpansConfig,
        spans_input: []const SpanInput,
    ) WriteError!void {
        const before = self.pending.items.len;
        errdefer if (self.pending.items.len != before) {
            self.rolling_back = true;
        };
        const meta = try self.exidToObj(obj);
        try requireType(meta, .text);

        var old: std.ArrayList(textdiff.BlockOrGrapheme(Block)) = .empty;
        // **Every grapheme in `old` is a copy this function made.**
        // [`textdiff.graphemes`](textdiff.zig) returns slices into the span's
        // text and the span is given back at the end of its iteration, so a
        // grapheme taken by pointer would be a slice into freed bytes by the
        // time the diff reads it — a use-after-free that only faults when the
        // freed block has been handed to something else.
        defer {
            for (old.items) |item| switch (item) {
                .grapheme => |g| self.gpa.free(g),
                .block => {},
            };
            old.deinit(self.gpa);
        }
        // **The block maps belong to the transaction, not to this call.** The
        // operations the diff writes borrow their keys and values from them and
        // are not encoded until `commit`, which is after this returns; and a
        // [`Block`] carries a pointer to one that must not move while the diff
        // runs. `Transaction.blocks` gives both — see its doc for why it is a
        // list of pointers and not a list of maps.

        // The old side, as blocks and grapheme clusters
        // (`spans_as_grapheme`, `text_diff.rs:446-473`).
        {
            var walk = try spansmod.Spans(opmod.ChangeOp).init(
                self.gpa,
                &self.doc.ops,
                try self.doc.ops.spans(meta.id),
                try self.scopeClock(),
                self.doc.textEncoding(),
            );
            defer walk.deinit();
            while (try walk.next()) |found| {
                // The walk hands the span over (`Spans.next`, `spans.zig:1332`),
                // and the bytes in it are the caller's from here.
                var span = found;
                switch (span) {
                    .text => |t| {
                        defer span.deinit(self.gpa);
                        const gs = try textdiff.graphemes(self.gpa, t.text);
                        defer self.gpa.free(gs);
                        for (gs) |g| {
                            const copied = try self.gpa.dupe(u8, g);
                            errdefer self.gpa.free(copied);
                            try old.append(self.gpa, .{ .grapheme = copied });
                        }
                    },
                    .block => |map| {
                        var transferred = false;
                        defer if (!transferred) span.deinit(self.gpa);
                        const block = try self.ownBlock(map);
                        transferred = true;
                        try old.append(self.gpa, .{ .block = block });
                    },
                }
            }
        }

        const new_spans = try self.gpa.alloc(textdiff.BlockOrText(Block), spans_input.len);
        defer self.gpa.free(new_spans);
        for (spans_input, new_spans) |span, *slot| {
            slot.* = switch (span) {
                .text => |t| .{ .text = t.text },
                .block => |map| .{ .block = try self.dupBlock(map) },
            };
        }

        var sink = TextSink{ .tx = self };
        try textdiff.myersBlockDiff(
            self.gpa,
            TextSink,
            Block,
            &sink,
            meta.id,
            old.items,
            new_spans,
        );
        try self.applyMarkDiff(meta.id, config, spans_input);
    }

    /// The second pass of [`updateSpansWithConfig`]
    /// ([`apply_marks_diff`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):165-248).
    ///
    /// **Every mark is removed and every mark is written**, and the "is it
    /// already there" test is the whole of the diff
    /// (`text_diff.rs:238-248`): a mark that survives is the one whose name,
    /// value and range all match, so a span that carries a mark the document
    /// already has writes nothing.
    ///
    /// **The config is asked twice, once per mark, and both times with the
    /// mark's own name** ([`text_diff.rs`:216-226`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)
    /// for the removals, [`:229-245`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)
    /// for the writes): upstream's `.per_mark_expands.get(name).copied()
    /// .unwrap_or(config.default_expand)`, which is [`UpdateSpansConfig.expandFor`].
    /// Upstream removes with the flag of the mark it is removing and not of the
    /// span that is taking its place, and so does this.
    ///
    /// **Every mark is removed and every mark is written**, and the "is it
    /// already there" test is the whole of the diff
    /// (`text_diff.rs:238-248`): a mark that survives is the one whose name,
    /// value and range all match, so a span that carries a mark the document
    /// already has writes nothing.
    fn applyMarkDiff(
        self: *Transaction,
        obj: ExId,
        config: *const UpdateSpansConfig,
        spans_input: []const SpanInput,
    ) WriteError!void {
        var wanted: std.ArrayList(Mark) = .empty;
        defer wanted.deinit(self.gpa);
        var idx: usize = 0;
        const enc = self.doc.textEncoding();
        for (spans_input) |span| switch (span) {
            .block => idx += 1, // a block is one position (`text_diff.rs:172-175`)
            .text => |t| {
                const width = enc.width(t.text);
                if (t.marks) |set| {
                    var mit = set.iter();
                    while (mit.next()) |entry| {
                        try wanted.append(self.gpa, .{
                            .name = entry.name,
                            .value = entry.value,
                            .start = idx,
                            .end = idx + width,
                        });
                    }
                }
                idx += width;
            },
        };

        const current = try self.doc.ops.calculateMarksAt(self.gpa, obj, try self.scopeClock());
        defer self.gpa.free(current);
        for (current) |have| {
            const keep = blk: {
                for (wanted.items) |w| {
                    if (std.mem.eql(u8, w.name, have.name) and w.value.eql(have.value) and
                        w.start == have.start and w.end == have.end) break :blk true;
                }
                break :blk false;
            };
            if (keep) continue;
            try self.unmark(obj, have.start, have.end, config.expandFor(have.name), have.name, null);
        }
        for (wanted.items) |w| {
            var present = false;
            const now = try self.doc.ops.calculateMarks(self.gpa, obj);
            defer self.gpa.free(now);
            for (now) |have| {
                if (std.mem.eql(u8, have.name, w.name) and have.value.eql(w.value) and
                    have.start == w.start and have.end == w.end)
                {
                    present = true;
                    break;
                }
            }
            if (present) continue;
            try self.mark(obj, w.start, w.end, w.name, config.expandFor(w.name), w.value);
        }
    }

    /// Consume a map only after its stable owner slot is fully reserved.
    fn ownBlock(self: *Transaction, map: hydmod.Map) WriteError!Block {
        const slot = try self.gpa.create(hydmod.Map);
        errdefer self.gpa.destroy(slot);
        try self.blocks.ensureUnusedCapacity(self.gpa, 1);
        slot.* = map;
        self.blocks.appendAssumeCapacity(slot);
        return .{ .id = map.id, .map = slot };
    }

    fn dupBlock(self: *Transaction, map: *const hydmod.Map) WriteError!Block {
        var copy = try map.dup(self.gpa);
        errdefer copy.deinit();
        return self.ownBlock(copy);
    }
};

/// The block side of a span diff: an object in the document and its hydrated
/// contents.
///
/// **It borrows, and the owner is the [`Transaction`] that built it.**
/// [`textdiff.BlockOrGrapheme`] copies a block by value into a list it does
/// not own and never frees, so a block that owned its map would be freed twice
/// or not at all; the maps themselves live in [`Transaction.blocks`], one
/// allocation each, so the address in `map` is good for the whole
/// transaction. [`eql`] is
/// content equality, which is upstream's derived `PartialEq`
/// ([`text_diff.rs:260`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)) —
/// two blocks with the same contents are equal whatever they are called.
pub const Block = struct {
    /// The object the block marker names.
    id: ExId,
    /// Its contents, owned by [`Transaction.blocks`] at a fixed address.
    map: *const hydmod.Map,

    /// Content equality, as the block diff compares blocks
    /// ([`BlockOrGrapheme.eql`](textdiff.zig)).
    pub fn eql(a: Block, b: Block) bool {
        return a.map.eql(b.map);
    }
};

/// The sink [`textdiff.myersDiff`] and [`textdiff.myersBlockDiff`] drive.
///
/// **It is an adapter and not [`Transaction`] itself, for one reason: the
/// error set.** `textdiff`'s hooks are declared `err.Error!T`
/// ([`textdiff.zig:758-789`](textdiff.zig), `:903-1029`) — the *document*
/// error set, not this file's wider [`WriteError`] — and a type parameter that
/// is handed `*Transaction` would have to satisfy that. So every method here
/// narrows through [`asError`], which is the same narrowing the module-level
/// functions do, and the transaction's own methods keep the wide set so
/// `transaction.zig` can forward them without losing a refusal on the way.
///
/// Each method's upstream counterpart is named in the table
/// [`textdiff.TxHook`](textdiff.zig):725-731 gives, and
/// [`textdiff.BlockDiffHook`](textdiff.zig):872-880 gives the three more.
pub const TextSink = struct {
    /// The transaction the diff writes through.
    tx: *Transaction,

    /// `doc.text_for` ([`text_diff.rs:22`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
    pub fn textFor(self: *TextSink, obj: ExId) Error![]const u8 {
        return self.tx.textFor(obj) catch |e| return asError(e);
    }

    /// `doc.text_encoding` ([`:26`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
    pub fn textEncoding(self: *const TextSink) TextEncoding {
        return self.tx.textEncoding();
    }

    /// `tx.splice_text` ([`:85-92`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
    pub fn spliceText(
        self: *TextSink,
        obj: ExId,
        index: usize,
        del: isize,
        text: []const u8,
    ) Error!void {
        self.tx.spliceText(obj, index, del, text) catch |e| return asError(e);
    }

    /// `tx.delete` ([`:300`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
    pub fn delete(self: *TextSink, obj: ExId, index: usize) Error!void {
        _ = self.tx.delete(obj, .{ .index = index }) catch |e| return asError(e);
    }

    /// `tx.join_block` ([`:299-300`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
    pub fn joinBlock(self: *TextSink, obj: ExId, index: usize) Error!void {
        self.tx.joinBlock(obj, index) catch |e| return asError(e);
    }

    /// `tx.split_block` ([`:498`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
    pub fn splitBlock(self: *TextSink, obj: ExId, index: usize) Error!ExId {
        return self.tx.splitBlock(obj, index) catch |e| return asError(e);
    }

    /// `doc.get(obj, index)` ([`:510-512`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
    pub fn blockAt(self: *TextSink, obj: ExId, index: usize) Error!?ExId {
        return self.tx.blockAt(obj, index) catch |e| return asError(e);
    }

    /// `tx.update_map` ([`:499`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs),
    /// `:513-515`).
    pub fn updateMap(self: *TextSink, id: ExId, block: Block) Error!void {
        self.tx.updateMapValue(id, block.map) catch |e| return asError(e);
    }
};

/// Lexicographic byte order, which is what "sorted" means for a map key
/// everywhere in this file ([`inner.rs:1136`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
/// `:1350`).
fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The object a hydrated value is, or null for a scalar
/// ([`value_to_op_type`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1526-1533).
///
/// **This port's [`hydmod.Value`] has no `objectType`**, because it flattened
/// upstream's `Scalar(..) | Map | List | Text` into eleven scalar cases plus
/// one `object` case ([hydrate.zig](hydrate.zig):267-305) and the question then
/// has to be asked of the `object` arm. Upstream's answer is the same: a
/// scalar has no object type, so `batch_create_object` refuses it
/// (`inner.rs:1292`).
fn valueObjectType(v: hydmod.Value) ?ObjType {
    return switch (v) {
        .object => |o| switch (o) {
            .map => .map,
            .list => .list,
            .text => .text,
        },
        else => null,
    };
}

/// Whether any of `rows` holds a counter
/// ([`inner.rs:466`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)):
/// *one* counter is enough, because a conflicted register of counters is still
/// a counter register.
fn anyCounter(rows: []const Op) bool {
    for (rows) |row| {
        if (row.isCounter()) return true;
    }
    return false;
}

// ── Splices ─────────────────────────────────────────────────────────────────

/// What a splice writes: a list of values, or a run of text.
///
/// Upstream's `SpliceType` ([`inner.rs:1407-1426`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
/// and the two answers it gives — the sequence type and whether there is
/// anything to write — are both here.
const SpliceKind = union(enum) {
    /// A run of text, borrowed from the caller.
    text: []const u8,
    /// Values to insert, borrowed from the caller.
    list: []const hydmod.Value,

    /// The sequence type this writes into (`SpliceType::seq_type`, `:1413-1419`).
    fn seqType(self: SpliceKind) SequenceType {
        return switch (self) {
            .list => .list,
            .text => .text,
        };
    }

    /// Whether there is anything to write (`SpliceType::is_empty`, `:1420-1426`).
    fn isEmpty(self: SpliceKind) bool {
        return switch (self) {
            .list => |v| v.len == 0,
            .text => |t| t.len == 0,
        };
    }
};

/// Borrowed codepoint units for the three non-grapheme encodings
/// ([`inner.rs:1481-1491`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
///
/// **The other three encodings split by code point, not by cluster**, and that
/// is upstream's own comment rather than an accident
/// (`inner.rs:1482-1486`): the grapheme encoding arrived after the others and
/// they were not changed.
const CodepointIterator = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn next(self: *CodepointIterator) error{InvalidUtf8}!?[]const u8 {
        if (self.offset == self.bytes.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(self.bytes[self.offset]) catch return error.InvalidUtf8;
        const end = @min(self.offset + n, self.bytes.len);
        const unit = self.bytes[self.offset..end];
        self.offset = end;
        return unit;
    }

    /// Check every lead byte before any operation is appended. Continuations
    /// and truncated units retain their existing downstream handling.
    fn preflight(bytes: []const u8) error{InvalidUtf8}!void {
        var units: CodepointIterator = .{ .bytes = bytes };
        while (try units.next() != null) {}
    }
};

/// A queue of `(container, value)` pairs, breadth first
/// ([`batch_bfs`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1539-1603).
///
/// Upstream's is a `VecDeque` of borrowed pairs and this is a list of borrowed
/// pairs with a head index, which is the same order for the same reason: it is
/// a queue, and that is what makes a nested object's operations come out
/// parents-before-children and siblings in sorted key order.
const Queue = struct {
    gpa: Allocator,
    items: std.ArrayList(Entry),
    head: usize,

    const Entry = struct {
        container: ObjMeta,
        value: *const hydmod.Value,
    };

    fn init(gpa: Allocator) Queue {
        return .{ .gpa = gpa, .items = .empty, .head = 0 };
    }

    fn deinit(self: *Queue) void {
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    fn len(self: *const Queue) usize {
        return self.items.items.len;
    }

    fn push(self: *Queue, container: ObjMeta, value: *const hydmod.Value) Allocator.Error!void {
        // The caller's value outlives the queue.
        try self.items.append(self.gpa, .{ .container = container, .value = value });
    }

    fn next(self: *Queue) ?Entry {
        if (self.head >= self.items.items.len) return null;
        const e = self.items.items[self.head];
        self.head += 1;
        return e;
    }
};

/// `values_to_splice_text`
/// ([`inner.rs:1391-1405`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)):
/// a splice of values into a text object is a splice of the strings, and
/// anything that is not a string is `error.InvalidValueType`.
fn joinTextValues(gpa: Allocator, values: []const hydmod.Value) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (values) |v| {
        switch (v) {
            .str => |s| try out.appendSlice(gpa, s),
            else => return error.InvalidValueType,
        }
    }
    return out.toOwnedSlice(gpa);
}
/// The batch: operations appended to `pending` and written in **one** splice
/// ([`BatchInsertion`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1435-1520).
///
/// **`nextPos` assumes every operation lands contiguously at `insert_pos`**
/// (`inner.rs:1460-1462`), and that assumption is only true because [`finish`]
/// is the only thing that writes: nothing else touches the op set while a batch
/// is open. The test that reads a ten-character splice back walks every
/// consecutive pair of rows through [`Op.step`](opset/op.zig), which is what
/// would fail if it stopped being true.
const Batch = struct {
    /// The transaction whose `pending` this appends to.
    tx: *Transaction,
    /// Where this batch started in `pending`, so `nextPos` can count only its
    /// own operations.
    start: usize,
    /// The row the whole batch is spliced at.
    insert_pos: usize,

    /// A batch over the whole document, writing at `insert_pos`.
    fn init(tx: *Transaction, insert_pos: usize) Batch {
        return .{ .tx = tx, .start = tx.pending.items.len, .insert_pos = insert_pos };
    }

    /// The row the next operation of this batch will take
    /// ([`next_pos`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1460-1462).
    fn nextPos(self: Batch) usize {
        return self.tx.pending.items.len - self.start + self.insert_pos;
    }

    /// Queues `op` without writing it
    /// ([`BatchInsertion::append`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1464-1471).
    fn append(self: *Batch, op: TxOp) WriteError!OpId {
        errdefer if (self.tx.pending.items.len > self.start) {
            self.tx.rolling_back = true;
        };
        var tx_op = op;
        var transferred = false;
        errdefer if (!transferred) tx_op.deinit(self.tx.gpa);
        try self.tx.requireOpen();
        try self.tx.ownBuilderPayload(&tx_op.bld);
        const id = tx_op.id();
        var change = changeOpOf(&tx_op);
        errdefer if (!transferred) change.deinit(self.tx.gpa);
        try self.tx.pending.append(self.tx.gpa, .{ .tx = tx_op, .op = change, .published = false });
        transferred = true;
        if (tx_op.obj_type != .text) {
            try self.tx.finalizeOp(&self.tx.pending.items[self.tx.pending.items.len - 1].tx, null, null);
        }
        return id;
    }

    /// Queues one map operation with no predecessors, the shape every root of a
    /// batch has ([`batch_bfs`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1553-1562).
    /// Requires a fresh map run contiguous at the batch's insertion point.
    /// Retained document roots use `Transaction.insertHydratedRoot` instead;
    /// sorting only the input cannot join existing physical registers.
    ///
    /// **An object is `make` and a scalar is `put`.** A hydrated register holds
    /// either, and upstream's `value_to_op_type`
    /// ([`inner.rs`:1526-1533`](../transaction/inner.rs)) is what says which;
    /// refusing a scalar here would make a mirror of an ordinary map —
    /// which is mostly scalars — impossible to replay into a document.
    fn appendRoot(self: *Batch, container: ObjMeta, key: []const u8, action: OpType) WriteError!OpId {
        return self.append(try TxOp.map(
            self.tx.gpa,
            self.tx.nextId(),
            container,
            self.nextPos(),
            .{ .visible_update = action },
            key,
            &.{},
        ));
    }

    /// Writes `text` as one operation per unit, chained by element
    /// ([`BatchInsertion::splice_text`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1473-1512).
    ///
    /// **The chain is the point**: each unit hangs by the operation before it,
    /// which is what makes them one run of text rather than `n` inserts at the
    /// same index.
    ///
    /// **`text` is borrowed and every unit is copied**, which is what upstream
    /// does by construction rather than by hand: its `splice_text` collects an
    /// **owned** `Vec<ScalarValue>` before the loop
    /// ([`inner.rs:1481-1501`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    /// because `TxOp` holds an `OpBuilder<'static>`
    /// ([`op.rs:164-170`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
    /// and a borrow of a local cannot be put in a `pending` vector. The port
    /// has no lifetime to enforce that with, so [`Transaction.ownText`]
    /// (`transact.zig`) is where the copy lands — and it has to: every
    /// `textdiff` hook frees the buffer it splices from before this
    /// transaction commits, and the value column reads these units again at
    /// that point.
    fn spliceText(self: *Batch, container: ObjMeta, after: ElemId, text_input: []const u8, index: usize, marks_set: ?*const MarkSet) WriteError!usize {
        errdefer if (self.tx.pending.items.len > self.start) {
            self.tx.rolling_back = true;
        };
        const graphemes: ?[][]const u8 = if (self.tx.doc.textEncoding() == .grapheme_cluster)
            if (text_input.len == 0)
                try self.tx.gpa.alloc([]const u8, 0)
            else
                try textdiff.graphemes(self.tx.gpa, text_input)
        else
            null;
        defer if (graphemes) |units| self.tx.gpa.free(units);
        if (graphemes == null) try CodepointIterator.preflight(text_input);
        var codepoints: CodepointIterator = .{ .bytes = text_input };
        var unit_index: usize = 0;
        var inserted_width: usize = 0;
        var elem = after;
        while (true) {
            const unit = if (graphemes) |units| blk: {
                if (unit_index == units.len) break;
                const cluster = units[unit_index];
                unit_index += 1;
                break :blk cluster;
            } else (try codepoints.next()) orelse break;
            const id = self.tx.nextId();
            const op = try TxOp.insertVal(
                self.tx.gpa,
                id,
                container,
                self.nextPos(),
                .{ .str = unit },
                elem,
            );
            inserted_width += @intCast(op.width(.text, self.tx.doc.textEncoding()));
            elem = ElemId.fromOpId(id);
            _ = try self.append(op);
        }
        if (self.tx.patch_log.recording) {
            self.tx.patch_log.splice(container.id, index, text_input, marks_set);
            try self.tx.checkPatchLog();
        }
        return inserted_width;
    }

    /// The breadth-first walk over nested values
    /// ([`batch_bfs`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1539-1603).
    fn bfs(self: *Batch, queue: *Queue) WriteError!void {
        errdefer if (self.tx.pending.items.len > self.start) {
            self.tx.rolling_back = true;
        };
        while (queue.next()) |entry| {
            const container = entry.container;
            switch (entry.value.*) {
                .object => |o| switch (o) {
                    .map => |m| {
                        var keys: std.ArrayList([]const u8) = .empty;
                        defer keys.deinit(self.tx.gpa);
                        var it = m.entries.iterator();
                        while (it.next()) |kv| try keys.append(self.tx.gpa, kv.key_ptr.*);
                        std.mem.sort([]const u8, keys.items, {}, strLessThan);
                        for (keys.items) |key| {
                            const child = Transaction.entryValue(&m, key) orelse continue;
                            const made = valueObjectType(child.*);
                            const action: OpType = if (made) |t|
                                .{ .make = t }
                            else
                                .{ .put = child.toScalar() orelse return error.NotAnObject };
                            const id = try self.appendRoot(container, key, action);
                            if (made) |t| try queue.push(
                                ObjMeta{ .id = self.tx.doc.idToExid(id), .typ = t },
                                child,
                            );
                        }
                    },
                    .list => |l| {
                        var elem = ElemId.head();
                        for (0..l.count()) |i| {
                            // `List.get` answers the element's `Value` itself,
                            // not a `ListValue` (`hydrate.zig:933-936`).
                            const item = l.get(i) orelse continue;
                            const made = valueObjectType(item.*);
                            const action: OpType = if (made) |t|
                                .{ .make = t }
                            else
                                .{ .put = item.toScalar() orelse return error.NotAnObject };
                            const id = try self.append(try TxOp.insertOp(
                                self.tx.gpa,
                                self.tx.nextId(),
                                container,
                                self.nextPos(),
                                i,
                                action,
                                elem,
                            ));
                            elem = ElemId.fromOpId(id);
                            if (made) |t| try queue.push(
                                ObjMeta{ .id = self.tx.doc.idToExid(id), .typ = t },
                                item,
                            );
                        }
                    },
                    .text => |t| {
                        const rendered = try t.makeString(self.tx.gpa);
                        defer self.tx.gpa.free(rendered);
                        _ = try self.spliceText(container, ElemId.head(), rendered, 0, null);
                    },
                },
                // `inner.rs:1597-1599` — a container that is not the kind its
                // value says it is.
                else => return error.InvalidOp,
            }
        }
    }

    /// **The one write.** Everything this batch queued goes in with a single
    /// [`OpSet.splice`](opset/op_set.zig), which is
    /// [`BatchInsertion::finish`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1514-1519.
    fn finish(self: Batch) WriteError!void {
        errdefer if (self.tx.pending.items.len > self.start) {
            self.tx.rolling_back = true;
        };
        const queued = self.tx.pending.items[self.start..];
        if (queued.len == 0) return;
        if (queued.len == 1) {
            const one = [1]ChangeOp{queued[0].op};
            _ = try self.tx.doc.ops.splice(self.insert_pos, one[0..]);
        } else {
            const ops = try self.tx.gpa.alloc(ChangeOp, queued.len);
            defer self.tx.gpa.free(ops);
            for (queued, ops) |*item, *slot| slot.* = item.op;
            _ = try self.tx.doc.ops.splice(self.insert_pos, ops);
        }
        self.tx.doc.invalidateHistoricalScopes();
        for (queued) |*item| item.published = true;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

/// A raw document with the deterministic actor used by transaction fixtures.
fn freshDoc(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, std.testing.io);
    doc.setActorId(.{ .bytes = "0123456789abcdef" });
    return doc;
}

/// The visible rows of one map key, which is the register a reader sees.
///
/// **A register with more than one visible row is conflicted, and that is the
/// definition rather than an approximation**: upstream's `map_range` flags a
/// register exactly when `num_new > 1` where `num_new` counts the visible rows
/// of the group ([`map_range.rs:262-263`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)),
/// and `get_all` is the same rows ([`automerge.rs:1901-1906`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
fn register(gpa: Allocator, doc: *Document, key: []const u8) !opsetmod.OpsFound {
    return registerIn(gpa, doc, .root, key);
}

/// [`register`], for a register of some **other** object — a nested map the
/// test reached through its parent's row, which is the only way a reader
/// gets one.
///
/// **The object is an argument and not an assumption.** Every key a test asks
/// about belongs to *some* object, and a helper that hardcoded the root would
/// answer "no rows" for a nested key — a true statement about the root and a
/// false one about the document.
fn registerIn(
    gpa: Allocator,
    doc: *Document,
    obj: ExId,
    key: []const u8,
) !opsetmod.OpsFound {
    return doc.ops.seekOpsByMapKey(gpa, obj, key, null);
}

test "put stays pending until commit then the document has one more change" {
    const gpa = testing.allocator;
    var owner = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer owner.deinit();
    try owner.setActorId(.{ .bytes = "0123456789abcdef" });

    const id = try owner.put(.root, .{ .key = "name" }, .{ .str = "ada" });
    try testing.expect(!(id orelse return error.TestUnexpectedResult).eql(OpId.root));
    try testing.expectEqual(@as(usize, 0), owner.doc.graph.len());
    try testing.expectEqual(@as(usize, 1), owner.pendingOps());
    var found = try register(gpa, &owner.doc, "name");
    defer found.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), found.ops.items.len);
    try testing.expectEqualStrings("ada", found.ops.items[0].value().str);
    try testing.expectEqual(Action.set, found.ops.items[0].action());
    try testing.expect((try owner.commit()) != null);
    try testing.expectEqual(@as(usize, 1), owner.doc.graph.len());
    try testing.expectEqual(@as(usize, 0), owner.pendingOps());
}

test "a redundant put writes no operation and adds no change" {
    const gpa = testing.allocator;
    var owner = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer owner.deinit();
    try owner.setActorId(.{ .bytes = "0123456789abcdef" });

    _ = try owner.put(.root, .{ .key = "k" }, .{ .int = 1 });
    const second = try owner.put(.root, .{ .key = "k" }, .{ .int = 1 });
    try testing.expect(second == null);
    try testing.expectEqual(@as(usize, 1), owner.pendingOps());
    try testing.expectEqual(@as(usize, 0), owner.doc.graph.len());
    try testing.expect((try owner.commit()) != null);
    const third = try owner.put(.root, .{ .key = "k" }, .{ .int = 1 });
    try testing.expect(third == null);
    try testing.expectEqual(@as(usize, 0), owner.pendingOps());
    try testing.expect((try owner.commit()) == null);
    try testing.expectEqual(@as(usize, 1), owner.doc.graph.len());
}

test "two puts inside one isolation share a journal and resolve one register" {
    // Rust autocommit.rs:445-457 holds one transaction across both writes.
    const gpa = testing.allocator;
    var owner = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer owner.deinit();
    try owner.setActorId(.{ .bytes = "0123456789abcdef" });
    _ = try owner.put(.root, .{ .key = "warm" }, .{ .int = 1 });
    const before = try owner.getHeads(gpa);
    defer gpa.free(before);
    const warm_changes = owner.doc.graph.len();

    try owner.isolate(gpa, before);
    _ = try owner.put(.root, .{ .key = "k" }, .{ .int = 1 });
    _ = try owner.put(.root, .{ .key = "k" }, .{ .int = 2 });
    try testing.expectEqual(warm_changes, owner.doc.graph.len());
    try testing.expectEqual(@as(usize, 2), owner.pendingOps());
    try owner.integrate();

    var found = try register(gpa, &owner.doc, "k");
    defer found.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), found.ops.items.len);
    try testing.expect(found.ops.items[0].visible());
    try testing.expectEqual(@as(i64, 2), found.ops.items[0].value().int);
    try testing.expect((try owner.doc.ops.validateTopIndex()) == null);
    try testing.expectEqual(warm_changes + 1, owner.doc.graph.len());

    var control = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer control.deinit();
    _ = try control.put(.root, .{ .key = "k" }, .{ .int = 1 });
    _ = try control.put(.root, .{ .key = "k" }, .{ .int = 2 });
    var over = try register(gpa, &control.doc, "k");
    defer over.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), over.ops.items.len);
    try testing.expectEqual(@as(i64, 2), over.ops.items[0].value().int);
    try testing.expectEqual(@as(usize, 0), control.doc.graph.len());
    try testing.expect((try control.commit()) != null);
    try testing.expectEqual(@as(usize, 1), control.doc.graph.len());
}

test "isolated object creation and text splice share one actor and one change" {
    // Rust tests/test.rs:4179-4208: each object-and-text pair is one change.
    const gpa = testing.allocator;
    var owner = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer owner.deinit();
    try owner.setActorId(.{ .bytes = "0123456789abcdef" });
    const list = try owner.putObject(.root, .{ .key = "list" }, .list);
    _ = try owner.insert(list, 0, .{ .str = "base" });
    const beginning = try owner.getHeads(gpa);
    defer gpa.free(beginning);
    try testing.expectEqual(@as(usize, 1), owner.doc.graph.len());

    const first = try owner.putObject(list, .{ .index = 0 }, .text);
    try owner.spliceText(first, 0, 0, "first");
    try testing.expectEqual(@as(usize, 1), owner.doc.graph.len());
    try owner.isolate(gpa, beginning);
    try testing.expectEqual(@as(usize, 2), owner.doc.graph.len());
    const second = try owner.putObject(list, .{ .index = 0 }, .text);
    try owner.spliceText(second, 0, 0, "second");
    try owner.integrate();
    try testing.expectEqual(@as(usize, 3), owner.doc.graph.len());
    try testing.expectEqual(@as(usize, 2), owner.doc.numActors());
    const got = try owner.text(second, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("second", got);

    const base = types.ActorId{ .bytes = "0123456789abcdef" };
    const fork1 = try types.ActorId.withConcurrency(gpa, base, 1);
    defer gpa.free(fork1.bytes);
    const fork2 = try types.ActorId.withConcurrency(gpa, base, 2);
    defer gpa.free(fork2.bytes);
    const fork_of_fork = try types.ActorId.withConcurrency(gpa, fork1, 1);
    defer gpa.free(fork_of_fork.bytes);
    var has_fork1 = false;
    var has_fork2 = false;
    var has_fork_of_fork = false;
    var ai: ActorIdx = 0;
    while (ai < owner.doc.numActors()) : (ai += 1) {
        const bytes = owner.doc.getActor(ai).?.bytes;
        if (std.mem.eql(u8, bytes, fork1.bytes)) has_fork1 = true;
        if (std.mem.eql(u8, bytes, fork2.bytes)) has_fork2 = true;
        if (std.mem.eql(u8, bytes, fork_of_fork.bytes)) has_fork_of_fork = true;
    }
    try testing.expect(has_fork1);
    try testing.expect(!has_fork2);
    try testing.expect(!has_fork_of_fork);
}

test "a history barrier advances isolated heads without splitting a later held pair" {
    // Explicit getHeads is a close barrier; ordinary writes remain one journal.
    const gpa = testing.allocator;
    var owner = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer owner.deinit();
    try owner.setActorId(.{ .bytes = "0123456789abcdef" });
    const list = try owner.putObject(.root, .{ .key = "list" }, .list);
    _ = try owner.insert(list, 0, .{ .str = "base" });
    const beginning = try owner.getHeads(gpa);
    defer gpa.free(beginning);
    const first = try owner.putObject(list, .{ .index = 0 }, .text);
    try owner.spliceText(first, 0, 0, "first");
    try owner.isolate(gpa, beginning);
    const second = try owner.putObject(list, .{ .index = 0 }, .text);
    const after_object = try owner.getHeads(gpa);
    defer gpa.free(after_object);
    try testing.expectEqual(@as(usize, 3), owner.doc.graph.len());
    try owner.spliceText(second, 0, 0, "second");
    try owner.spliceText(second, 6, 0, "!");
    try testing.expectEqual(@as(usize, 3), owner.doc.graph.len());
    try owner.integrate();
    try testing.expectEqual(@as(usize, 4), owner.doc.graph.len());
    try testing.expectEqual(@as(usize, 2), owner.doc.numActors());
    const got = try owner.text(second, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("second!", got);
}

test "a read through a scoped transaction is scoped, and a read through the document is not" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    const text = blk: {
        var setup = try Transaction.open(gpa, &doc);
        defer setup.deinit() catch @panic("testing allocator cleanup cannot inject failure");
        const t = try setup.putObject(.root, .{ .key = "text" }, .text);
        _ = try setup.put(.root, .{ .key = "size" }, .{ .int = 100 });
        try setup.spliceText(t, 0, 0, "abc");
        try setup.mark(t, 0, 3, "bold", .after, .{ .bool_value = true });
        var committed_1 = try setup.commit();
        defer committed_1.deinit(gpa);
        break :blk t;
    };
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);

    // **The document moves on from those heads**, and the move is a mark set to
    // `Null` — a tombstone, so the present has no mark there at all.
    {
        var moved = try Transaction.open(gpa, &doc);
        defer moved.deinit() catch @panic("testing allocator cleanup cannot inject failure");
        _ = try moved.put(.root, .{ .key = "size" }, .{ .int = 200 });
        try moved.unmark(text, 0, 3, .none, "bold", null);
        var committed_2 = try moved.commit();
        defer committed_2.deinit(gpa);
    }

    // **Through the document: the present, and no isolation is what says so.**
    // `readmod.get` resolves its scope through [`Document.readScope`](doc.zig),
    // which is null here — upstream's `get_scope(None)` second arm
    // ([`autocommit.rs:806-813`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
    // **and `Transaction.openAt` does not set it**: the scope goes into the
    // transaction (`Document.transactionArgs`, doc.zig) and nowhere else.
    {
        const got = (try readmod.get(&doc, .root, .{ .key = "size" })).?;
        try testing.expectEqual(@as(i64, 200), got.value.scalar.int);
    }
    {
        var present = try readmod.markSetAtIndex(&doc, text, 1, null, gpa);
        defer present.deinit();
        try testing.expectEqual(@as(usize, 0), present.len());
    }

    var tx = try Transaction.openAt(gpa, &doc, heads);
    defer tx.deinit() catch @panic("testing allocator cleanup cannot inject failure");

    // **Through the transaction, with no heads named, and it is still
    // scoped.** `get_scope(None)` is `self.inner.get_scope()` and not "the
    // document's scope" ([`manual_transaction.rs:113-122`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)),
    // so the transaction's own clock is what a read with no argument runs at.
    // Upstream's own case is [`test.rs:2524-2526`](../../github-automerge-automerge/rust/automerge/tests/test.rs).
    {
        const got = (try tx.get(.root, .{ .key = "size" })).?;
        try testing.expectEqual(@as(i64, 100), got.value.scalar.int);
    }

    // **The two readers disagree, and that is the whole difference between
    // them.** [`readmod.get`](read.zig) on the same document at the same moment
    // answers 200; asserting it again here makes the pair a statement rather
    // than a fact about the document.
    {
        const got = (try readmod.get(&doc, .root, .{ .key = "size" })).?;
        try testing.expectEqual(@as(i64, 200), got.value.scalar.int);
    }

    // **The pending operation is a row, so the transaction sees its own write**
    // ([`inner.rs:308-328`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    // which is [`test.rs:2529-2530`](../../github-automerge-automerge/rust/automerge/tests/test.rs):
    // `put` then `get` answers the new value, not the scoped one.
    _ = try tx.put(.root, .{ .key = "size" }, .{ .int = 300 });
    {
        const got = (try tx.get(.root, .{ .key = "size" })).?;
        try testing.expectEqual(@as(i64, 300), got.value.scalar.int);
    }

    // **The unmark is pending in *this* transaction**, which is upstream's
    // shape: `get_marks_at_heads` makes the operation that changes the answer
    // and then asks for the answer at the heads from before it
    // ([`test.rs:2693-2700`](../../github-automerge-automerge/rust/automerge/tests/test.rs)).
    // An unmark made and committed by an *earlier* transaction would be in the
    // op set under no clock here as well, so both spellings reach the same
    // place — but only this one also shows up in the transaction's own scope,
    // which is the arm below.
    try tx.unmark(text, 0, 3, .none, "bold", null);

    // **`markSetAtIndex` at those heads cannot see the pending unmark**: the
    // operation is in the op set but in no clock at `heads`. This is upstream's
    // `get_marks_at_heads`
    // ([`test.rs:2693-2704`](../../github-automerge-automerge/rust/automerge/tests/test.rs)),
    // read through a transaction rather than through the document.
    {
        var at_heads = try tx.markSetAtIndex(text, 1, heads, gpa);
        defer at_heads.deinit();
        try testing.expectEqual(@as(usize, 1), at_heads.len());
        var entries = at_heads.iter();
        const entry = entries.next().?;
        try testing.expectEqualStrings("bold", entry.name);
        try testing.expect(entry.value == .bool_value);
        try testing.expectEqual(@as(bool, true), entry.value.bool_value);
    }

    // **And at the transaction's own scope the pending unmark is what answers**,
    // because [`scopeClock`](transact.zig) marks its clock with this
    // transaction's actor (`automerge.rs:1266`) — so `null` heads here is not
    // "no scope" and not "the document's scope" either.
    {
        var own = try tx.markSetAtIndex(text, 1, null, gpa);
        defer own.deinit();
        try testing.expectEqual(@as(usize, 0), own.len());
    }
    var committed_3 = try tx.commit();
    defer committed_3.deinit(gpa);

    // **After the commit the document reads 300 and the heads still read the
    // mark** ([`test.rs:2706-2712`](../../github-automerge-automerge/rust/automerge/tests/test.rs)),
    // which is the same divergence the document-side read shows and the reason
    // [`readmod.markSetAtIndex`](read.zig) takes heads at all.
    {
        const got = (try readmod.get(&doc, .root, .{ .key = "size" })).?;
        try testing.expectEqual(@as(i64, 300), got.value.scalar.int);
    }
    {
        var still = try readmod.markSetAtIndex(&doc, text, 1, heads, gpa);
        defer still.deinit();
        try testing.expectEqual(@as(usize, 1), still.len());
        var entries = still.iter();
        const entry = entries.next().?;
        try testing.expectEqualStrings("bold", entry.name);
        try testing.expectEqual(@as(bool, true), entry.value.bool_value);
    }
}

test "an unscoped transaction reads the present, and its own write is in the present" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit() catch @panic("testing allocator cleanup cannot inject failure");
    _ = try tx.put(.root, .{ .key = "size" }, .{ .int = 7 });

    // **`scopeClock` is null, so this is the indexed path** — upstream's
    // `get_scope(None)` third arm (`self.inner.as_ref().and_then(..)` returns
    // `None` for a transaction opened without heads) and the
    // `clock.is_none() && typ == Text` test at
    // [`automerge.rs:1937`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)
    // that sends [`readmod.markSetAtScope`](read.zig) to the mark index.
    try testing.expectEqual(@as(?Clock, null), try tx.scopeClock());

    // **The write is visible, because it is a row in the document's op set.**
    // This is the case [`test.rs:2517-2521`](../../github-automerge-automerge/rust/automerge/tests/test.rs)
    // states and the one a test that read through the document instead would
    // pass for the wrong reason: both readers see it, so the pending row is not
    // what separates them.
    {
        const got = (try tx.get(.root, .{ .key = "size" })).?;
        try testing.expectEqual(@as(i64, 7), got.value.scalar.int);
    }
    {
        const got = (try readmod.get(&doc, .root, .{ .key = "size" })).?;
        try testing.expectEqual(@as(i64, 7), got.value.scalar.int);
    }

    // **An object that does not exist is `NotAnObject` through either door**, and
    // a property the object does not have is `InvalidOp`
    // ([`automerge.rs:1866-1887`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
    // the dispatch is one function and this is where that shows.
    // **An id whose actor this document has never heard of** — the actor bytes
    // are what [`Document.resolve`](doc.zig) looks the index up by, so an actor
    // the table cannot name names nothing, exactly as an out-of-range counter
    // would (`ExId::fromParts`).
    const nowhere = ExId.withActor(OpId.init(99, 0), .{ .bytes = "nobody-here" });
    try testing.expectError(error.NotAnObject, tx.get(nowhere, .{ .key = "k" }));
    try testing.expectError(error.InvalidOp, tx.get(.root, .{ .index = 0 }));

    // **A key that was never written is `null` and not a null value.**
    try testing.expect((try tx.get(.root, .{ .key = "absent" })) == null);
}

test "delete makes the key absent, not present with a null" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();

    _ = try doc.put(.root, .{ .key = "k" }, .{ .int = 1 });
    var present = try register(gpa, &doc.doc, "k");
    try testing.expectEqual(@as(usize, 1), present.ops.items.len);
    present.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), try doc.delete(.root, .{ .key = "k" }));

    // **Absent.** A delete is a successor edge on the row it removes, never a
    // row of its own (`columns.rs:423`), so the register has nothing left in
    // it and a reader that answered "a null value" would be inventing one.
    var gone = try register(gpa, &doc.doc, "k");
    defer gone.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), gone.ops.items.len);
    try testing.expectEqual(@as(usize, 0), doc.doc.ops.seqLength(.root, doc.textEncoding(), null));
    // The row is still there, as a tombstone, and that is a different fact.
    var walk = try doc.doc.ops.iter();
    var rows: usize = 0;
    while (try walk.next()) |row| {
        rows += 1;
        try testing.expectEqual(Action.set, row.action());
        try testing.expect(!row.visible());
    }
    try testing.expectEqual(@as(usize, 1), rows);
}

test "increment on a plain value is MissingCounter and on a counter the count rises" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();

    _ = try doc.put(.root, .{ .key = "plain" }, .{ .int = 5 });
    // **`error.MissingCounter`, before anything is written** (`inner.rs:466-468`).
    try testing.expectError(
        error.MissingCounter,
        doc.increment(.root, .{ .key = "plain" }, 1),
    );
    var plain = try register(gpa, &doc.doc, "plain");
    defer plain.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), plain.ops.items.len);
    try testing.expectEqual(@as(i64, 5), plain.ops.items[0].value().int);

    _ = try doc.put(.root, .{ .key = "n" }, .{ .counter = .init(10) });
    try doc.increment(.root, .{ .key = "n" }, 7);
    var count = try register(gpa, &doc.doc, "n");
    defer count.deinit(gpa);
    // **The value rises.** A reader that accepted the increment and left the
    // counter alone would answer this with one row and the wrong number; the
    // successor edge carrying the amount is a separate operation, and folding
    // it in is the reader's job.
    //
    // **The reader has already done it, and this does not do it again.** Every
    // op a query hands out has been through `Op.fixCounter`
    // ([`OpQuery.next`, `op_query.zig:284-286`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_query.rs)
    // over upstream's `FixCounters::next`, `:103-107`), which is upstream's
    // `fix_counter` ([`op.rs:979-995`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)):
    // it adds each covered increment into the stored value. Upstream's
    // `fix_counter` is just as non-idempotent — it reads `n` and writes `n +
    // inc` — so calling it a second time on the same op is a mistake in the
    // caller, and it is this test's caller. A second fold would read 17 and
    // answer 24, and 24 is what the test used to see.
    try testing.expectEqual(@as(usize, 1), count.ops.items.len);
    try testing.expectEqual(@as(i64, 17), count.ops.items[0].value().counter.current);
}

test "pendingOps counts the queued operations and drops to zero after commit, and baseHeads is the heads from before" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    // Empty: nothing is queued and there are no heads.
    try testing.expectEqual(@as(usize, 0), doc.ops.len());
    try testing.expectEqual(@as(usize, 0), doc.graph.getHeads().len);

    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit() catch @panic("testing allocator cleanup cannot inject failure");
    const base = tx.baseHeads();
    try testing.expectEqual(@as(usize, 0), base.len);

    _ = try tx.put(.root, .{ .key = "a" }, .{ .int = 1 });
    _ = try tx.put(.root, .{ .key = "b" }, .{ .int = 2 });
    _ = try tx.put(.root, .{ .key = "c" }, .{ .int = 3 });

    // **The count is the real one, not a constant and not zero.**
    try testing.expectEqual(@as(usize, 3), tx.count());
    try testing.expectEqual(@as(usize, 3), doc.ops.len());

    // The base has not moved: it is the heads from before the transaction.
    try testing.expectEqual(@as(usize, 0), base.len);
    try testing.expectEqualSlices(ChangeHash, base, tx.baseHeads());

    var committed_4 = try tx.commit();
    defer committed_4.deinit(gpa);
    const hash = committed_4.hash.?;
    try testing.expectEqual(@as(usize, 0), tx.count());
    try testing.expectEqual(@as(usize, 1), doc.graph.len());

    // And the heads are now exactly what the next transaction is based on, so
    // `baseHeads` names what it says it names.
    const now = try doc.getHeads(gpa);
    defer gpa.free(now);
    try testing.expectEqual(@as(usize, 1), now.len);
    try testing.expect(now[0].eql(hash));
    try testing.expectEqual(@as(usize, 1), doc.graph.getHeads().len);
    try testing.expect(doc.graph.getHeads()[0].eql(hash));

    // A second transaction's base is that head, and the change it commits
    // depends on it.
    var second = try Transaction.open(gpa, &doc);
    defer second.deinit() catch @panic("testing allocator cleanup cannot inject failure");
    try testing.expectEqual(@as(usize, 1), second.baseHeads().len);
    try testing.expect(second.baseHeads()[0].eql(hash));
    _ = try second.put(.root, .{ .key = "d" }, .{ .int = 4 });
    var committed_5 = try second.commit();
    defer committed_5.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), doc.graph.len());
}

test "a rollback restores the document exactly" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    // A document with something in it, and a byte-for-byte copy of it. **Every
    // write goes through the raw document's explicit transaction owner.
    {
        var setup = try Transaction.open(gpa, &doc);
        defer setup.deinit() catch @panic("testing allocator cleanup cannot inject failure");
        _ = try setup.put(.root, .{ .key = "keep" }, .{ .str = "before" });
        const list = try setup.putObject(.root, .{ .key = "l" }, .list);
        _ = try setup.insert(list, 0, .{ .int = 1 });
        _ = try setup.insert(list, 1, .{ .int = 2 });
        const text = try setup.putObject(.root, .{ .key = "t" }, .text);
        try setup.spliceText(text, 0, 0, "hello");
        try setup.mark(text, 1, 3, "em", .both, .{ .bool_value = true });
        var committed_6 = try setup.commit();
        defer committed_6.deinit(gpa);
    }
    // The objects the setup made, found through the document rather than
    // through a variable that would not outlive the block above.
    var list_row = try register(gpa, &doc, "l");
    const list = doc.ops.idToExid(list_row.ops.items[0].id());
    list_row.deinit(gpa);
    var text_row = try register(gpa, &doc, "t");
    const text = doc.ops.idToExid(text_row.ops.items[0].id());
    text_row.deinit(gpa);
    _ = list;
    var before = try doc.clone(gpa);
    defer before.deinit();
    const before_rows = before.ops.len();
    const before_graph = before.graph.len();
    const before_heads = before.graph.getHeads();

    // A transaction that writes, and then gives all of it back.
    var tx = try Transaction.open(gpa, &doc);
    _ = try tx.put(.root, .{ .key = "gone" }, .{ .int = 1 });
    _ = try tx.delete(.root, .{ .key = "keep" });
    const list2 = try tx.putObject(.root, .{ .key = "m2" }, .map);
    _ = try tx.put(list2, .{ .key = "inner" }, .{ .str = "x" });
    try testing.expectEqual(@as(usize, 4), tx.count());
    try testing.expectEqual(@as(usize, 4), tx.count());
    try testing.expectEqual(@as(usize, 4), try tx.rollback());
    tx.deinitClosed();

    // **`OpSet.debugCmp` and not the heads or the row count**: the comparison
    // is over values, so a slab that was repartitioned on the way out does not
    // read as a different document, and a row that was left behind cannot hide.
    try doc.ops.debugCmp(&before.ops);
    try testing.expectEqual(before_rows, doc.ops.len());
    try testing.expectEqual(before_graph, doc.graph.len());
    try testing.expectEqual(before_heads.len, doc.graph.getHeads().len);
    for (before_heads, doc.graph.getHeads()) |want, have| {
        try testing.expect(want.eql(have));
    }
    try testing.expectEqual(before_rows, doc.ops.len());

    // And the text and the mark are still what they were, read through the
    // document rather than through a row comparison.
    const text_again = try doc.text(gpa, text);
    defer gpa.free(text_again);
    try testing.expectEqualStrings("hello", text_again);
    const marks = try doc.marks(gpa, text);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqual(@as(usize, 1), marks[0].start);
    try testing.expectEqual(@as(usize, 3), marks[0].end);
}

test "expand is observable at the mark's own two anchors" {
    const gpa = testing.allocator;

    // **The flag is about the anchors, not about the span.** An insert *inside*
    // a mark's span is inside it whether or not either anchor expands, so a
    // test that inserts in the middle reads the same answer for all four flags
    // and proves nothing. The two anchors are where the flag lives: a begin
    // that expands backwards pulls text inserted at `start` inside, and an end
    // that does not expand forwards leaves text inserted at `end` outside
    // (`marks.rs:367-377`, the rule itself at `op_set2/op_set.rs:529-534`).
    //
    // **And the ranges are in the text's own coordinates**, which is where the
    // answer lives. Splicing a character *before* a mark does not change which
    // characters the mark covers, and it shifts the mark's indices right; a
    // mark that reads `[1, 3)` again after a splice at its start has covered
    // something else, not stayed put. Every expectation below is the
    // reference's own answer, produced by `zautomerge-oracle marks` over the
    // same six fixtures, so the table is a comparison and not a derivation.
    //
    // The fixture: `"abcd"`, one mark `em` over `[1, 3)` — the `b` and the `c` —
    // then a single `X` spliced in at the mark's own `start` (1) or its own
    // `end` (3).

    // **At the mark's start, index 1.** `before` pulls `X` inside and `after`
    // and `none` leave it outside; the two that leave it outside differ from
    // the untouched mark only in that the mark's indices moved right.
    {
        var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
        try doc.setActorId(.{ .bytes = "0123456789abcdef" });
        defer doc.deinit();
        const text = try doc.putObject(.root, .{ .key = "t" }, .text);
        try doc.spliceText(text, 0, 0, "abcd");
        try doc.mark(text, 1, 3, "em", .none, .{ .bool_value = true });
        try doc.spliceText(text, 1, 0, "X");

        const got = try doc.text(text, gpa);
        defer gpa.free(got);
        try testing.expectEqualStrings("aXbcd", got);
        const marks = try doc.marks(text, gpa);
        defer gpa.free(marks);
        // **The mark did not expand backwards**, so `X` is before its begin
        // and outside it. The mark still covers `b` and `c`, and those now sit
        // at 2 and 3.
        try testing.expectEqual(@as(usize, 1), marks.len);
        try testing.expectEqualStrings("em", marks[0].name);
        try testing.expectEqual(@as(usize, 2), marks[0].start);
        try testing.expectEqual(@as(usize, 4), marks[0].end);
    }
    {
        var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
        try doc.setActorId(.{ .bytes = "0123456789abcdef" });
        defer doc.deinit();
        const text = try doc.putObject(.root, .{ .key = "t" }, .text);
        try doc.spliceText(text, 0, 0, "abcd");
        try doc.mark(text, 1, 3, "em", .before, .{ .bool_value = true });
        try doc.spliceText(text, 1, 0, "X");

        const got = try doc.text(text, gpa);
        defer gpa.free(got);
        try testing.expectEqualStrings("aXbcd", got);
        const marks = try doc.marks(text, gpa);
        defer gpa.free(marks);
        // **The mark grew to `[1, 4)`**: the same three characters, the same
        // boolean, one more unit under it. That is what makes the flag a flag,
        // and it is the *length* that moved — `3` became `4` — rather than the
        // start, which was `1` either way.
        try testing.expectEqual(@as(usize, 1), marks.len);
        try testing.expectEqualStrings("em", marks[0].name);
        try testing.expectEqual(@as(usize, 1), marks[0].start);
        try testing.expectEqual(@as(usize, 4), marks[0].end);
    }
    {
        // `after` is `(before = false, after = true)`
        // (`marks.rs:385-393`), so the begin does not expand and this is the
        // same document as `none` above. **It is here because the two are the
        // same answer for opposite reasons** — one flags the start anchor, the
        // other the end — and a reader that got the rule backwards would make
        // them differ.
        var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
        try doc.setActorId(.{ .bytes = "0123456789abcdef" });
        defer doc.deinit();
        const text = try doc.putObject(.root, .{ .key = "t" }, .text);
        try doc.spliceText(text, 0, 0, "abcd");
        try doc.mark(text, 1, 3, "em", .after, .{ .bool_value = true });
        try doc.spliceText(text, 1, 0, "X");

        const marks = try doc.marks(text, gpa);
        defer gpa.free(marks);
        try testing.expectEqual(@as(usize, 1), marks.len);
        try testing.expectEqual(@as(usize, 2), marks[0].start);
        try testing.expectEqual(@as(usize, 4), marks[0].end);
    }

    // **At the mark's end, index 3.** Here the flag that decides is the end's,
    // and the two that leave `X` outside are the two whose end does not expand.
    {
        var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
        try doc.setActorId(.{ .bytes = "0123456789abcdef" });
        defer doc.deinit();
        const text = try doc.putObject(.root, .{ .key = "t" }, .text);
        try doc.spliceText(text, 0, 0, "abcd");
        try doc.mark(text, 1, 3, "em", .both, .{ .bool_value = true });
        try doc.spliceText(text, 3, 0, "X");

        const got = try doc.text(text, gpa);
        defer gpa.free(got);
        try testing.expectEqualStrings("abcXd", got);
        const marks = try doc.marks(text, gpa);
        defer gpa.free(marks);
        // **The mark grew to `[1, 4)`**: the end expanded forwards, so `X` is
        // inside the mark.
        try testing.expectEqual(@as(usize, 1), marks.len);
        try testing.expectEqualStrings("em", marks[0].name);
        try testing.expectEqual(@as(usize, 1), marks[0].start);
        try testing.expectEqual(@as(usize, 4), marks[0].end);
    }
    {
        // `before` is `(before = true, after = false)`, so the **end** does not
        // expand even though the begin does. `X` is outside and the mark is
        // back to exactly two units — the same `[1, 3)` it had before the
        // splice, which is the point: at this anchor a non-expanding end leaves
        // the range alone, and at the other anchor a non-expanding begin does
        // not.
        var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
        try doc.setActorId(.{ .bytes = "0123456789abcdef" });
        defer doc.deinit();
        const text = try doc.putObject(.root, .{ .key = "t" }, .text);
        try doc.spliceText(text, 0, 0, "abcd");
        try doc.mark(text, 1, 3, "em", .before, .{ .bool_value = true });
        try doc.spliceText(text, 3, 0, "X");

        const got = try doc.text(text, gpa);
        defer gpa.free(got);
        try testing.expectEqualStrings("abcXd", got);
        const marks = try doc.marks(text, gpa);
        defer gpa.free(marks);
        try testing.expectEqual(@as(usize, 1), marks.len);
        try testing.expectEqualStrings("em", marks[0].name);
        try testing.expectEqual(@as(usize, 1), marks[0].start);
        try testing.expectEqual(@as(usize, 3), marks[0].end);
    }
    {
        var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
        try doc.setActorId(.{ .bytes = "0123456789abcdef" });
        defer doc.deinit();
        const text = try doc.putObject(.root, .{ .key = "t" }, .text);
        try doc.spliceText(text, 0, 0, "abcd");
        try doc.mark(text, 1, 3, "em", .none, .{ .bool_value = true });
        try doc.spliceText(text, 3, 0, "X");

        const marks = try doc.marks(text, gpa);
        defer gpa.free(marks);
        // **Same answer as `before` at this anchor**, and for the same reason:
        // what decides is the end, and neither of these expands forwards.
        try testing.expectEqual(@as(usize, 1), marks.len);
        try testing.expectEqual(@as(usize, 1), marks[0].start);
        try testing.expectEqual(@as(usize, 3), marks[0].end);
    }
}

test "spliceText of ten characters is one change, ten rows, and a contiguous row order" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();
    const text = try doc.putObject(.root, .{ .key = "t" }, .text);
    _ = try doc.commit();
    const changes_before = doc.doc.graph.len();

    try doc.spliceText(text, 0, 0, "0123456789");
    _ = try doc.commit();

    // **One change.** Ten operations, one `OpSet.splice` (`Batch.finish`).
    try testing.expectEqual(changes_before + 1, doc.doc.graph.len());
    // The text object itself is a row, so eleven rows and ten characters.
    try testing.expectEqual(@as(usize, 11), doc.doc.ops.len());

    const got = try doc.text(text, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("0123456789", got);

    // **Ten rows, contiguous, and in the order the batch built them.** The
    // object owns every row after the one that created it: no gap, and nothing
    // from another object in between. That is the property
    // `BatchInsertion::next_pos` assumes when it predicts where each queued
    // operation will land (`inner.rs:1460-1462`).
    const rows = try doc.doc.ops.scopeToObj(text);
    try testing.expectEqual(@as(usize, 1), rows.start);
    try testing.expectEqual(@as(usize, 11), rows.end);
    try testing.expectEqual(doc.doc.ops.len(), rows.end);

    // **`Op.step` is the row-order rule itself** (`op.rs:1048-1071`): the
    // object may not go backwards, the register may not go backwards inside it,
    // and the id may not go backwards or repeat inside one register. Walking
    // every row through it is what says the batch landed where it was asked to
    // rather than somewhere the reader happens to accept.
    var stepper = opmod.OpStepper.initial();
    var previous: ?Op = null;
    var in_object: usize = 0;
    for (0..doc.doc.ops.len()) |pos| {
        const at = (try doc.doc.ops.get(pos)).?;
        try testing.expect(at.step(&stepper));
        if (previous) |prev| {
            // The rows ascend by id because one batch from one actor minted
            // them in order (`Transaction.nextId`,
            // `inner.rs:295-297`), and each hangs by the row in front of it.
            try testing.expect(prev.id().order(at.id()) == .lt);
        }
        previous = at;
        if (pos >= rows.start) in_object += 1;
    }
    // Ten character rows, and they are the ten the reader saw.
    try testing.expectEqual(@as(usize, 10), in_object);
    // And the whole op set, walked by the gate that exists for it
    // (`OpSet::validateOpOrder`, `op_set.rs:177-180`).
    try testing.expect(try doc.doc.ops.validateOpOrder());
}

test "an empty document and a non-object target are refusals, not traps" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();

    // **A non-object target.** `error.NotAnObject`, not a trap: the document
    // has no such object, and every reader in the tree answers this the same
    // way.
    try testing.expectError(
        error.NotAnObject,
        doc.put(.{ .id = OpId.init(99, 0) }, .{ .key = "k" }, .{ .int = 1 }),
    );
    try testing.expectEqual(@as(usize, 0), doc.doc.graph.len());
    try testing.expectEqual(@as(usize, 0), doc.doc.ops.len());

    // **The wrong kind of object for the method**, which is `error.InvalidOp`
    // and the same refusal upstream gives (`inner.rs:616-618`).
    try testing.expectError(
        error.InvalidOp,
        doc.spliceText(.root, 0, 0, "x"),
    );
    const list = try doc.putObject(.root, .{ .key = "l" }, .list);
    try testing.expectError(
        error.InvalidOp,
        doc.spliceText(list, 0, 0, "x"),
    );

    // **An index past the end of a sequence** is `error.InvalidIndex`
    // (`insert.zig:136-137`), again not a trap.
    try testing.expectError(
        error.InvalidIndex,
        doc.insert(list, 5, .{ .int = 1 }),
    );

    // **A map key on a sequence is a no-op, not a refusal** — and this is the
    // half the test used to get backwards. `delete` dispatches on the
    // *property*, not on the object's type (`inner.rs:594-595`), so a map key
    // on a list asks the list for the register `"k"`, finds none, and
    // `resolve_action` answers `None`: a delete of a key that is not there
    // writes no operation (`op_set.rs:1489-1492`). A reader that refused here
    // would reject a call upstream accepts, and one that *wrote* the operation
    // would add a change and a row to the document for nothing — so both the
    // refusal and the write are checked, and the count is the answer.
    _ = try doc.commit();
    const changes = doc.doc.graph.len();
    const rows = doc.doc.ops.len();
    try testing.expectEqual(@as(usize, 0), try doc.delete(list, .{ .key = "k" }));
    try testing.expectEqual(changes, doc.doc.graph.len());
    try testing.expectEqual(rows, doc.doc.ops.len());
}

test "a transaction commits nothing when it wrote nothing, and a second commit is refused" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    var first = try Transaction.open(gpa, &doc);
    _ = try first.put(.root, .{ .key = "k" }, .{ .int = 1 });
    var committed_7 = try first.commit();
    defer committed_7.deinit(gpa);
    first.deinitClosed();
    try testing.expectEqual(@as(usize, 1), doc.graph.len());

    var again = try Transaction.open(gpa, &doc);
    _ = try again.put(.root, .{ .key = "k" }, .{ .int = 1 });
    // A redundant `put` writes no operation (`op_set.rs:1489-1492`), so there
    // is nothing to commit and no change to add.
    try testing.expectEqual(@as(usize, 0), again.count());
    var committed_8 = try again.commit();
    defer committed_8.deinit(gpa);
    try testing.expect(committed_8.hash == null);
    again.deinitClosed();
    try testing.expectEqual(@as(usize, 1), doc.graph.len());

    // **A second commit is refused**, because upstream takes the inner out of
    // its `Option` before the first one (`manual_transaction.rs:135-145`) and
    // an application twice is a bug rather than a no-op.
    var empty = try Transaction.open(gpa, &doc);
    defer empty.deinit() catch @panic("testing allocator cleanup cannot inject failure");
    var committed_9 = try empty.commit();
    defer committed_9.deinit(gpa);
    try testing.expect(committed_9.hash == null);
    try testing.expectError(error.InvalidOp, empty.commit());
    try testing.expectError(error.InvalidOp, empty.rollback());
    try testing.expectEqual(@as(usize, 1), doc.graph.len());
}

test "putObject creates an object the document then reports as one" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();

    const map = try doc.putObject(.root, .{ .key = "m" }, .map);
    const list = try doc.putObject(.root, .{ .key = "l" }, .list);
    const text = try doc.putObject(.root, .{ .key = "t" }, .text);
    try testing.expectEqual(ObjType.map, try doc.objectType(map));
    try testing.expectEqual(ObjType.list, try doc.objectType(list));
    try testing.expectEqual(ObjType.text, try doc.objectType(text));
    // **`.root`, because that is where all three were put.** A reader that
    // answered `map` here would be reporting the wrong parent for every object
    // in the document; the parent is the object the creating row hangs by, and
    // these three hang by the root.
    try testing.expectEqual(ExId.root, doc.objectParent(list));
    try testing.expectEqual(ExId.root, doc.objectParent(text));

    // A `put_object` on a text object is `error.InvalidOp` (`inner.rs:285-289`)
    // — the one place `put`'s three-arm check differs.
    try testing.expectError(
        error.InvalidOp,
        doc.putObject(text, .{ .index = 0 }, .map),
    );
}

test "insert and delete on a list move the element ids" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();
    const list = try doc.putObject(.root, .{ .key = "l" }, .list);

    const a = try doc.insert(list, 0, .{ .int = 1 });
    const b = try doc.insert(list, 1, .{ .int = 2 });
    try testing.expectEqual(@as(usize, 2), doc.doc.ops.seqLength(list, doc.textEncoding(), null));

    // An insert's id is also its element id (`op.rs:1140-1146`), so the
    // elements are addressable by the ids `insert` returned — and `index` is
    // the position a reader would put them at, which is what makes the two
    // seeks a statement about where the elements are rather than about the
    // ids resolving.
    {
        const at = (try doc.doc.ops.seekListOpid(list, a, .list, null)).?;
        try testing.expectEqual(@as(usize, 0), at.index);
        try testing.expect(at.visible);
    }
    {
        const at = (try doc.doc.ops.seekListOpid(list, b, .list, null)).?;
        try testing.expectEqual(@as(usize, 1), at.index);
        try testing.expect(at.visible);
    }

    try testing.expectEqual(@as(usize, 1), try doc.delete(list, .{ .index = 0 }));
    try testing.expectEqual(@as(usize, 1), doc.doc.ops.seqLength(list, doc.textEncoding(), null));

    // **The element after the deleted one moved down.** `index` counts the
    // winners in front of the row (`op_set.rs:866-868`), so a delete that
    // stopped contributing took `b` from 1 to 0. This is the half of the test
    // that a reader which merely stopped returning `a` would also pass, which
    // is why it is here.
    {
        const at = (try doc.doc.ops.seekListOpid(list, b, .list, null)).?;
        try testing.expectEqual(@as(usize, 0), at.index);
        try testing.expect(at.visible);
    }
    // **The deleted element is still in the object, and it is still found.**
    // Upstream's `seek_list_opid_fast` returns `Some` for a tombstone and puts
    // the answer in `visible` (`op_set.rs:860-875`); only an id the object does
    // not hold at all is a null. A delete is a successor edge on the row
    // (`columns.rs:423`), so the row is still there and now reads as not
    // visible — which is a different fact from "gone", and the one this port
    // was conflating.
    {
        const at = (try doc.doc.ops.seekListOpid(list, a, .list, null)).?;
        try testing.expect(!at.visible);
        try testing.expect(!at.op.visible());
    }
    // And an id from another object is a null, which is the answer that was
    // being expected of a deleted one.
    try testing.expectEqual(
        @as(?opsetmod.FoundOpId, null),
        try doc.doc.ops.seekListOpid(list, OpId.root, .list, null),
    );
}

test "mark, unmark and the block methods on a text object" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();
    const text = try doc.putObject(.root, .{ .key = "t" }, .text);
    try doc.spliceText(text, 0, 0, "abcdef");

    const block = try doc.splitBlock(text, 3);
    try testing.expectEqual(ObjType.map, try doc.objectType(block));
    // **A block is one position wide, and a split only inserts**
    // (`split_block` splices one `Make(Map)` row and removes nothing,
    // `inner.rs:905-916`), so six characters and one block are seven
    // positions. The block's own width is one whatever it holds — `Op.width`'s
    // `.list` arm, and a block row is the "anything else" case in
    // `seq_length`, which measures it as one U+FFFC (`op_set.rs:443-447`).
    try testing.expectEqual(@as(usize, 7), doc.doc.ops.seqLength(text, doc.textEncoding(), null));

    _ = try doc.put(block, .{ .key = "kind" }, .{ .str = "para" });
    try doc.joinBlock(text, 3);
    // **And a join only deletes** (`join_block`, `inner.rs:931-937`), so the
    // six characters are all that is left and the block is gone.
    try testing.expectEqual(@as(usize, 6), doc.doc.ops.seqLength(text, doc.textEncoding(), null));
    const joined = try doc.text(text, gpa);
    defer gpa.free(joined);
    try testing.expectEqualStrings("abcdef", joined);

    const again = try doc.replaceBlock(text, 1);
    try testing.expectEqual(ObjType.map, try doc.objectType(again));
    // **Six, and the reference says so — run, not reasoned.** `replace_block`
    // is `join_block` then `split_block` (`inner.rs:991-992`), and
    // `join_block` does **not** check that what it deletes is a block: its own
    // FIXME says so (`inner.rs:944-947`, "it doesn't seem to validate that
    // what its deleting is a block??"). The join above already removed the one
    // block, so the object is plain `"abcdef"` again and index 1 names the
    // character `b` — the join deletes that character, and the split puts a
    // block in its place. Five characters and one block is six, and the six
    // is `width(\u{fffc})` for the block (`op_set.rs:443-447`).
    //
    // The reference's own answer, from `tools/oracle`'s block probe, for
    // exactly this sequence: `after join at 3: length=6 text="abcdef"`, then
    // `after replace at 1: length=6 text="a\u{fffc}cdef"` with spans
    // `["Text(\"a\")", "Block", "Text(\"cdef\")"]`. **The previous expectation
    // of 7 was this test's own arithmetic being wrong**, not the port: it
    // assumed the join would delete a block, and there was no block left at
    // index 1 to delete. A second `replace_block` at the same index then
    // finds a block there, deletes it and inserts one, and the length stays 6
    // — the reference agrees on that too.
    try testing.expectEqual(@as(usize, 6), doc.doc.ops.seqLength(text, doc.textEncoding(), null));
    const replaced = try doc.text(text, gpa);
    defer gpa.free(replaced);
    try testing.expectEqualStrings("a\u{fffc}cdef", replaced);

    // **An unmark leaves no mark behind**, which is the tombstone rule
    // (`op_set.rs:1023`): a mark whose value is null is dropped on the way out.
    try doc.mark(text, 0, 2, "em", .after, .{ .bool_value = true });
    const before = try doc.marks(text, gpa);
    try testing.expectEqual(@as(usize, 1), before.len);
    gpa.free(before);
    try doc.unmark(text, 0, 2, .after, "em", null);
    const after = try doc.marks(text, gpa);
    defer gpa.free(after);
    try testing.expectEqual(@as(usize, 0), after.len);
}

test "a zero-width mark with no expansion writes nothing" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();
    const text = try doc.putObject(.root, .{ .key = "t" }, .text);
    try doc.spliceText(text, 0, 0, "abc");
    _ = try doc.commit();
    const changes = doc.doc.graph.len();
    const rows = doc.doc.ops.len();

    // `inner.rs:813-825` — a mark from 1 to 1 with `ExpandMark::None` is a
    // begin and an end at the same anchor, and upstream writes nothing.
    try doc.mark(text, 1, 1, "em", .none, .{ .bool_value = true });
    try testing.expectEqual(changes, doc.doc.graph.len());
    try testing.expectEqual(rows, doc.doc.ops.len());
    try testing.expectEqual(@as(usize, 0), doc.pendingOps());
}

test "a spliced list of hydrated values is written in two batches" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();
    const list = try doc.putObject(.root, .{ .key = "l" }, .list);

    var nested = hydmod.List.init(gpa, .root);
    defer nested.deinit();
    try nested.push(hydmod.Value.scalar(.{ .int = 7 }), false);

    var values = [_]hydmod.Value{
        hydmod.Value.scalar(.{ .int = 1 }),
        .{ .object = .{ .list = nested } },
        hydmod.Value.scalar(.{ .str = "three" }),
    };
    _ = try doc.commit();
    const changes = doc.doc.graph.len();
    try doc.splice(list, 0, 0, &values);
    _ = try doc.commit();
    // **One change for the whole splice**, however many objects it made.
    try testing.expectEqual(changes + 1, doc.doc.graph.len());
    try testing.expectEqual(@as(usize, 3), doc.doc.ops.seqLength(list, doc.textEncoding(), null));

    // The nested list is there and holds what it was given.
    var found = try doc.doc.ops.seekOpsByIndex(gpa, list, 1, .list, null);
    defer found.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), found.ops.items.len);
    const inner = doc.doc.ops.idToExid(found.ops.items[0].id());
    try testing.expectEqual(ObjType.list, try doc.objectType(inner));
    try testing.expectEqual(@as(usize, 1), doc.doc.ops.seqLength(inner, doc.textEncoding(), null));

    // And a scalar spliced into a text object is the strings joined, or a
    // refusal (`inner.rs:1391-1405`).
    const text = try doc.putObject(.root, .{ .key = "t" }, .text);
    var words = [_]hydmod.Value{
        hydmod.Value.scalar(.{ .str = "ab" }),
        hydmod.Value.scalar(.{ .str = "cd" }),
    };
    try doc.splice(text, 0, 0, &words);
    const got = try doc.text(text, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("abcd", got);
    var not_a_string = [_]hydmod.Value{hydmod.Value.scalar(.{ .int = 1 })};
    try testing.expectError(
        error.InvalidValueType,
        doc.splice(text, 0, 0, &not_a_string),
    );
}

test "initRootFromHydrate fills the root, and updateObject brings a map in line" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();

    var child = hydmod.Map.init(gpa, .root);
    errdefer child.deinit();
    try child.putOwned("b", hydmod.MapValue.init(hydmod.Value.scalar(.{ .int = 2 }), false));
    try child.putOwned("a", hydmod.MapValue.init(hydmod.Value.scalar(.{ .int = 1 }), false));

    var root = hydmod.Map.init(gpa, .root);
    defer root.deinit();
    try root.putOwned("z", hydmod.MapValue.init(.{ .object = .{ .map = child } }, false));
    // **The move, made explicit.** `hydrate.Map` holds its hash table by value
    // and has no `Drop`, so `hydmod.Map.deinit` is the one free and **the local
    // name must not be deinit'd once `root` holds the table** — doing both
    // frees the same table twice, which is the segfault this line used to be,
    // and only on the error path. Zig has no move-only type, so a move is
    // spelled by disarming the source: an empty map frees an empty table.
    child = hydmod.Map.init(gpa, .root);
    try root.putOwned("y", hydmod.MapValue.init(hydmod.Value.scalar(.{ .str = "why" }), false));

    try doc.initRootFromHydrate(&root);
    // **The keys were sorted, so the child map's ids are `a` then `b`** — a
    // hash map's own order would have given something else, and the same value
    // would then have produced a different change hash on another run.
    //
    // **`a` and `b` are the *child's* registers, not the root's.** They were
    // read through [`register`], which asks the root, which answered zero rows
    // — a true statement about the root and a false one about the document,
    // and the shape of a reader that looks in the wrong place. `inner` is the
    // object `z`'s row names, and that is the object the batch wrote into
    // (`inner.rs:1334-1380`, `batch_init_root_map`).
    var zed = try register(gpa, &doc.doc, "z");
    defer zed.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), zed.ops.items.len);
    const inner = doc.doc.ops.idToExid(zed.ops.items[0].id());
    var a = try registerIn(gpa, &doc.doc, inner, "a");
    defer a.deinit(gpa);
    var b = try registerIn(gpa, &doc.doc, inner, "b");
    defer b.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), a.ops.items.len);
    try testing.expectEqual(@as(usize, 1), b.ops.items.len);
    try testing.expect(a.ops.items[0].id().order(b.ops.items[0].id()) == .lt);
    try testing.expectEqual(@as(i64, 1), a.ops.items[0].value().int);
    try testing.expectEqual(@as(i64, 2), b.ops.items[0].value().int);

    var why = try register(gpa, &doc.doc, "y");
    defer why.deinit(gpa);
    try testing.expectEqualStrings("why", why.ops.items[0].value().str);

    // `updateObject` writes what is new and deletes what is gone.
    var replacement = hydmod.Map.init(gpa, .root);
    defer replacement.deinit();
    try replacement.putOwned("a", hydmod.MapValue.init(hydmod.Value.scalar(.{ .int = 10 }), false));
    const replacement_value: hydmod.Value = .{ .object = .{ .map = replacement } };
    try doc.updateObject(inner, &replacement_value);

    var a2 = try registerIn(gpa, &doc.doc, inner, "a");
    defer a2.deinit(gpa);
    try testing.expectEqual(@as(i64, 10), a2.ops.items[0].value().int);
    var b2 = try registerIn(gpa, &doc.doc, inner, "b");
    defer b2.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), b2.ops.items.len);
}

fn hydratedRootOrderFixture(gpa: Allocator) !hydmod.Map {
    var root = hydmod.Map.init(gpa, .root);
    errdefer root.deinit();
    var child = hydmod.Map.init(gpa, .root);
    defer child.deinit();
    var list = hydmod.List.init(gpa, .root);
    defer list.deinit();
    try list.push(.{ .int = 7 }, false);
    try child.putOwned("b", .init(.{ .object = .{ .list = list } }, false));
    list = hydmod.List.init(gpa, .root);
    try child.putOwned("c", .init(.{ .int = 3 }, false));
    try root.putOwned("a", .init(.{ .object = .{ .map = child } }, false));
    child = hydmod.Map.init(gpa, .root);
    try root.putOwned("\x00k", .init(.{ .int = 2 }, false));
    try root.putOwned("m", .init(.{ .int = 20 }, false));
    try root.putOwned("z\x00", .init(.{ .int = 40 }, false));
    try root.putOwned("é", .init(.{ .int = 50 }, false));
    return root;
}

test "hydrated root joins existing lexical registers and objects with unchanged BFS change bytes" {
    // The expected stream is built independently of the producer: sorted
    // root keys, then the child's keys, then its list element
    // (transaction/inner.rs:1334-1380,1539-1603). Existing root registers
    // must not be separated or moved behind previously populated children.
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |occupied| {
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        var old_child: ?ExId = null;
        if (occupied) {
            var initial = try Transaction.open(gpa, &doc);
            defer initial.deinit() catch unreachable;
            _ = try initial.put(.root, .{ .key = "keep" }, .{ .int = 1 });
            _ = try initial.put(.root, .{ .key = "m" }, .{ .int = 10 });
            _ = try initial.put(.root, .{ .key = "z" }, .{ .int = 30 });
            old_child = try initial.putObject(.root, .{ .key = "a" }, .map);
            _ = try initial.put(old_child.?, .{ .key = "old" }, .{ .int = 99 });
            _ = try initial.put(.root, .{ .key = "gone" }, .{ .int = 5 });
            _ = try initial.delete(.root, .{ .key = "gone" });
            var committed = try initial.commit();
            defer committed.deinit(gpa);
        }
        var replay = try freshDoc(gpa);
        defer replay.deinit();
        try applyAll(gpa, &replay, &doc);
        var root = try hydratedRootOrderFixture(gpa);
        defer root.deinit();
        var tx = try Transaction.open(gpa, &doc);
        defer tx.deinit() catch unreachable;
        const first = tx.nextId();
        try tx.initRootFromHydrate(&root);
        try testing.expectEqual(@as(usize, 8), tx.count());

        const Spec = struct {
            object: ExId = .root,
            action: Action = .set,
            key: @import("opset/types.zig").KeyRef,
            scalar: ScalarValue = .null_value,
            insert: bool = false,
        };
        const new_map = OpId.init(first.counter + 1, first.actor);
        const new_list = OpId.init(first.counter + 5, first.actor);
        const specs = [_]Spec{
            .{ .key = .fromStr("\x00k"), .scalar = .{ .int = 2 } },
            .{ .key = .fromStr("a"), .action = .make_map },
            .{ .key = .fromStr("m"), .scalar = .{ .int = 20 } },
            .{ .key = .fromStr("z\x00"), .scalar = .{ .int = 40 } },
            .{ .key = .fromStr("é"), .scalar = .{ .int = 50 } },
            .{ .object = .{ .id = new_map }, .key = .fromStr("b"), .action = .make_list },
            .{ .object = .{ .id = new_map }, .key = .fromStr("c"), .scalar = .{ .int = 3 } },
            .{ .object = .{ .id = new_list }, .key = .{ .seq = .head() }, .scalar = .{ .int = 7 }, .insert = true },
        };
        var expected: std.ArrayList(ChangeOp) = .empty;
        defer {
            for (expected.items) |*op| op.deinit(gpa);
            expected.deinit(gpa);
        }
        try expected.ensureTotalCapacity(gpa, specs.len);
        for (specs, 0..) |spec, i| expected.appendAssumeCapacity(try ChangeOp.init(
            gpa,
            OpId.init(first.counter + @as(u32, @intCast(i)), first.actor),
            spec.object,
            spec.action,
            spec.key,
            spec.scalar,
            spec.insert,
            false,
            null,
            &.{},
        ));
        var reference_change = try docmod.encodeOneChange(gpa, doc.ops.actors.items, .{
            .actor = tx.actor,
            .seq = tx.seq,
            .start_op = tx.start_op,
            .max_op = tx.start_op + specs.len - 1,
            .time = 0,
            .message = "",
            .deps = tx.deps,
            .footer = &.{},
        }, expected.items);
        defer reference_change.deinit(gpa);
        var committed = try tx.commit();
        defer committed.deinit(gpa);
        try testing.expect(committed.hash != null);
        try testing.expect(committed.hash.?.eql(reference_change.change.hash));
        try testing.expectEqual(@as(usize, 1), try replay.applyChanges(gpa, &.{reference_change.change}));
        try testing.expect(try doc.ops.validateOpOrder());
        try testing.expect((try doc.ops.validateTopIndex()) == null);
        try testing.expect(try replay.ops.validateOpOrder());
        try doc.debugCmp(&replay);
        const keys = try rootKeys(gpa, &doc);
        defer gpa.free(keys);
        const wanted: []const []const u8 = if (occupied)
            &.{ "\x00k", "a", "keep", "m", "z", "z\x00", "é" }
        else
            &.{ "\x00k", "a", "m", "z\x00", "é" };
        try testing.expectEqual(wanted.len, keys.len);
        for (wanted, keys) |want, actual| try testing.expectEqualStrings(want, actual);
        for ([_]struct { key: []const u8, value: i64 }{
            .{ .key = "\x00k", .value = 2 },
            .{ .key = "m", .value = 20 },
            .{ .key = "z\x00", .value = 40 },
            .{ .key = "é", .value = 50 },
        }) |want| {
            const item = (try readmod.get(&doc, .root, .{ .key = want.key })) orelse
                return error.TestUnexpectedResult;
            try testing.expectEqual(want.value, item.value.scalar.int);
        }
        const child = doc.idToExid(new_map);
        const list = (try readmod.get(&doc, child, .{ .key = "b" })) orelse
            return error.TestUnexpectedResult;
        const element = (try readmod.get(&doc, list.id, .{ .index = 0 })) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i64, 7), element.value.scalar.int);
        if (old_child) |old| {
            const kept = (try readmod.get(&doc, old, .{ .key = "old" })) orelse
                return error.TestUnexpectedResult;
            try testing.expectEqual(@as(i64, 99), kept.value.scalar.int);
        }

        // Repeat the same root, including identical scalar values, then use
        // ordinary put/delete on those complete contiguous retained registers.
        var again = try Transaction.open(gpa, &doc);
        defer again.deinit() catch unreachable;
        try again.initRootFromHydrate(&root);
        try testing.expectEqual(@as(usize, 8), again.count());
        _ = try again.put(.root, .{ .key = "m" }, .{ .int = 60 });
        const overwrite = &again.pending.items[8].tx;
        try testing.expectEqual(@as(usize, if (occupied) 3 else 2), overwrite.pred().len);
        _ = try again.delete(.root, .{ .key = "a" });
        var done = try again.commit();
        defer done.deinit(gpa);
        var winner = try register(gpa, &doc, "m");
        defer winner.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), winner.ops.items.len);
        try testing.expectEqual(@as(i64, 60), winner.ops.items[0].value().int);
        try testing.expect((try readmod.get(&doc, .root, .{ .key = "a" })) == null);
        try testing.expect(try doc.ops.validateOpOrder());
        try testing.expect((try doc.ops.validateTopIndex()) == null);
        try applyAll(gpa, &replay, &doc);
        try doc.debugCmp(&replay);
    }
}

test "hydrated existing root allocation refusal retains complete published and queued undo" {
    const observer = testing.allocator;
    var root = try hydratedRootOrderFixture(observer);
    defer root.deinit();
    var reached_success = false;
    var reached_published_refusal = false;
    for (0..4096) |offset| {
        var failing = testing.FailingAllocator.init(observer, .{
            .fail_index = std.math.maxInt(usize),
        });
        const gpa = failing.allocator();
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        {
            var base = try Transaction.open(gpa, &doc);
            defer base.deinit() catch unreachable;
            _ = try base.put(.root, .{ .key = "keep" }, .{ .int = 1 });
            _ = try base.put(.root, .{ .key = "m" }, .{ .int = 10 });
            const old = try base.putObject(.root, .{ .key = "a" }, .map);
            _ = try base.put(old, .{ .key = "old" }, .{ .int = 99 });
            var committed = try base.commit();
            defer committed.deinit(gpa);
        }
        var baseline = try freshDoc(observer);
        defer baseline.deinit();
        try applyAll(observer, &baseline, &doc);
        var tx = try Transaction.open(gpa, &doc);
        defer {
            failing.fail_index = std.math.maxInt(usize);
            tx.deinit() catch unreachable;
        }
        // Earlier operations in the same journal also own their row positions.
        // Removing the hydrate prefix must restore them before undoing them.
        _ = try tx.put(.root, .{ .key = "pending" }, .{ .int = 88 });
        const before = tx.count();
        failing.fail_index = failing.alloc_index + offset;
        if (tx.initRootFromHydrate(&root)) |_| {
            failing.fail_index = std.math.maxInt(usize);
            try testing.expectEqual(before + 8, tx.count());
            try testing.expect(try doc.ops.validateOpOrder());
            try testing.expect((try doc.ops.validateTopIndex()) == null);
            reached_success = true;
        } else |primary| {
            try testing.expectEqual(error.OutOfMemory, primary);
            failing.fail_index = std.math.maxInt(usize);
            reached_published_refusal = reached_published_refusal or doc.ops.len() > baseline.ops.len() + 1;
            if (tx.rolling_back) {
                try testing.expectError(error.InvalidOp, tx.put(.root, .{ .key = "refused" }, .{ .int = 0 }));
                try testing.expectError(error.InvalidOp, tx.commit());
            }
        }
        // This is explicit recovery, not an assumption of whole-batch atomicity.
        const cancelled = tx.count();
        try testing.expectEqual(cancelled, try tx.rollback());
        try testing.expect(try doc.ops.validateOpOrder());
        try testing.expect((try doc.ops.validateTopIndex()) == null);
        try doc.debugCmp(&baseline);
        try testing.expectEqual(@as(usize, 1), doc.graph.len());
        try testing.expectEqual(doc.graph.len(), doc.node_info.items.len);
        const kept = (try readmod.get(&doc, .root, .{ .key = "keep" })) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i64, 1), kept.value.scalar.int);
        if (reached_success) break;
    }
    try testing.expect(reached_published_refusal);
    try testing.expect(reached_success);
}

test "hydrated historical root placement uses full raw registers and preserves scoped conflicts" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    {
        var initial = try Transaction.open(gpa, &doc);
        defer initial.deinit() catch unreachable;
        _ = try initial.put(.root, .{ .key = "m" }, .{ .int = 1 });
        _ = try initial.put(.root, .{ .key = "keep" }, .{ .int = 9 });
        var result = try initial.commit();
        defer result.deinit(gpa);
    }
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    {
        var current = try Transaction.open(gpa, &doc);
        defer current.deinit() catch unreachable;
        _ = try current.put(.root, .{ .key = "m" }, .{ .int = 2 });
        const child = try current.putObject(.root, .{ .key = "future" }, .map);
        _ = try current.put(child, .{ .key = "x" }, .{ .int = 8 });
        var result = try current.commit();
        defer result.deinit(gpa);
    }
    var root = try hydratedRootOrderFixture(gpa);
    defer root.deinit();
    var tx = try Transaction.openAt(gpa, &doc, heads);
    defer tx.deinit() catch unreachable;
    try tx.initRootFromHydrate(&root);
    try testing.expectEqual(@as(usize, 8), tx.count());
    for (tx.pending.items) |item| try testing.expectEqual(@as(usize, 0), item.tx.pred().len);
    const scoped = try tx.getAll(.root, .{ .key = "m" }, gpa);
    defer gpa.free(scoped);
    try testing.expectEqual(@as(usize, 2), scoped.len);
    try testing.expectEqual(@as(i64, 1), scoped[0].value.scalar.int);
    try testing.expectEqual(@as(i64, 20), scoped[1].value.scalar.int);
    const raw = try readmod.getAll(&doc, .root, .{ .key = "m" }, gpa);
    defer gpa.free(raw);
    try testing.expectEqual(@as(usize, 2), raw.len);
    try testing.expectEqual(@as(i64, 2), raw[0].value.scalar.int);
    try testing.expectEqual(@as(i64, 20), raw[1].value.scalar.int);
    try testing.expect(try doc.ops.validateOpOrder());
    try testing.expect((try doc.ops.validateTopIndex()) == null);
    _ = try tx.put(.root, .{ .key = "m" }, .{ .int = 30 });
    try testing.expectEqual(@as(usize, 2), tx.pending.items[8].tx.pred().len);
    var result = try tx.commit();
    defer result.deinit(gpa);
    var replay = try freshDoc(gpa);
    defer replay.deinit();
    try applyAll(gpa, &replay, &doc);
    try testing.expect(try doc.ops.validateOpOrder());
    try testing.expect((try doc.ops.validateTopIndex()) == null);
    try doc.debugCmp(&replay);
    const retained = (try readmod.get(&doc, .root, .{ .key = "keep" })) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 9), retained.value.scalar.int);
}

test "held automatic hydrated root preserves existing child scope and repeated registers" {
    const gpa = testing.allocator;
    var owner = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer owner.deinit();
    try owner.setActorId(.{ .bytes = "0123456789abcdef" });
    _ = try owner.put(.root, .{ .key = "keep" }, .{ .int = 1 });
    const older = try owner.putObject(.root, .{ .key = "a" }, .map);
    _ = try owner.put(older, .{ .key = "old" }, .{ .int = 99 });
    _ = try owner.commit();
    var root = try hydratedRootOrderFixture(gpa);
    defer root.deinit();
    try owner.initRootFromHydrate(&root);
    try owner.initRootFromHydrate(&root);
    try testing.expectEqual(@as(usize, 16), owner.pendingOps());
    _ = try owner.commit();
    const kept = (try owner.get(.root, .{ .key = "keep" })) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 1), kept.value.scalar.int);
    const history = (try owner.get(older, .{ .key = "old" })) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 99), history.value.scalar.int);
    var conflict = try register(gpa, &owner.doc, "a");
    defer conflict.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), conflict.ops.items.len);
    try testing.expect(try owner.doc.ops.validateOpOrder());
    try testing.expect((try owner.doc.ops.validateTopIndex()) == null);
    var replay = try freshDoc(gpa);
    defer replay.deinit();
    try applyAll(gpa, &replay, &owner.doc);
    try owner.doc.debugCmp(&replay);
}

test "hydrated retained root changes match pinned Rust canonical replay hashes" {
    // Recorded from the pinned Rust init_from_hydrate, with identical actor,
    // initial operation order and scalar types. Replaying its encoded changes
    // into a fresh Rust document preserves absent keys and exposes all repeated
    // no-predecessor values (inner.rs:1334-1380; automerge.rs:296-304).
    const gpa = testing.allocator;
    const Case = enum { absent, overlap, child };
    for ([_]Case{ .absent, .overlap, .child }) |case| {
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        {
            var initial = try Transaction.open(gpa, &doc);
            defer initial.deinit() catch unreachable;
            _ = try initial.put(.root, .{ .key = "keep" }, .{ .int = 1 });
            switch (case) {
                .absent => {},
                .overlap => {
                    _ = try initial.put(.root, .{ .key = "a" }, .{ .int = 1 });
                    _ = try initial.put(.root, .{ .key = "z" }, .{ .int = 9 });
                },
                .child => {
                    const child = try initial.putObject(.root, .{ .key = "c" }, .map);
                    _ = try initial.put(child, .{ .key = "x" }, .{ .int = 7 });
                },
            }
            var initial_result = try initial.commit();
            defer initial_result.deinit(gpa);
        }
        var map = hydmod.Map.init(gpa, .root);
        defer map.deinit();
        if (case == .overlap) {
            try map.putOwned("a", .init(.{ .int = 2 }, false));
        } else {
            try map.putOwned("first", .init(.{ .int = 2 }, false));
            try map.putOwned("second", .init(.{ .int = 3 }, false));
        }
        const expected = try ChangeHash.parse(gpa, switch (case) {
            .absent => "c3c5e4e8f8c2bdf01965a2e64e827c4e357d7a10868455ea83298ff12e02aabe",
            .overlap => "eb57a2cd327f4fae65c273459d894dfba721b9414851dd3d2d7e6daff34a0e28",
            .child => "e3b70c0eb957818ada50bd1792a590115ae43c6756b97c16f9ca1e20b8f16ed3",
        });
        {
            var tx = try Transaction.open(gpa, &doc);
            defer tx.deinit() catch unreachable;
            try tx.initRootFromHydrate(&map);
            var result = try tx.commit();
            defer result.deinit(gpa);
            try testing.expect((result.hash orelse return error.TestUnexpectedResult).eql(expected));
        }
        if (case == .overlap) {
            var tx = try Transaction.open(gpa, &doc);
            defer tx.deinit() catch unreachable;
            try tx.initRootFromHydrate(&map);
            try testing.expectEqual(@as(usize, 1), tx.count());
            var result = try tx.commit();
            defer result.deinit(gpa);
            const repeated = try ChangeHash.parse(gpa, "6ee78ae04f8723bf17b1d8af72dcdaf2110116455ecd0c9b94416e52b1765448");
            try testing.expect((result.hash orelse return error.TestUnexpectedResult).eql(repeated));
            var conflict = try register(gpa, &doc, "a");
            defer conflict.deinit(gpa);
            try testing.expectEqual(@as(usize, 3), conflict.ops.items.len);
            try testing.expectEqual(@as(i64, 1), conflict.ops.items[0].value().int);
            try testing.expectEqual(@as(i64, 2), conflict.ops.items[1].value().int);
            try testing.expectEqual(@as(i64, 2), conflict.ops.items[2].value().int);
        } else {
            const first = (try readmod.get(&doc, .root, .{ .key = "first" })) orelse
                return error.TestUnexpectedResult;
            const second = (try readmod.get(&doc, .root, .{ .key = "second" })) orelse
                return error.TestUnexpectedResult;
            try testing.expectEqual(@as(i64, 2), first.value.scalar.int);
            try testing.expectEqual(@as(i64, 3), second.value.scalar.int);
        }
        const keep = (try readmod.get(&doc, .root, .{ .key = "keep" })) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i64, 1), keep.value.scalar.int);
        var replay = try freshDoc(gpa);
        defer replay.deinit();
        try applyAll(gpa, &replay, &doc);
        try testing.expect(try doc.ops.validateOpOrder());
        try testing.expect((try doc.ops.validateTopIndex()) == null);
        try doc.debugCmp(&replay);
    }
}

test "updateMapValue numbers its operations depth first, and the row order is not that order" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    // **A value shaped to separate the two orders.** `a` is a map, `b` a list
    // and `z` a scalar, so the root's sorted keys are `a`, `b`, `z` and a
    // breadth-first walk would take the three root rows first and only then
    // descend. The nested map has `x` and `y` and the list two scalars, so
    // every descent is a real one and no key is a leaf before its siblings.
    var inner = hydmod.Map.init(gpa, .root);
    errdefer inner.deinit();
    try inner.putOwned("y", hydmod.MapValue.init(hydmod.Value.scalar(.{ .int = 2 }), false));
    try inner.putOwned("x", hydmod.MapValue.init(hydmod.Value.scalar(.{ .int = 1 }), false));

    var list = hydmod.List.init(gpa, .root);
    errdefer list.deinit();
    try list.push(hydmod.Value.scalar(.{ .int = 20 }), false);
    try list.push(hydmod.Value.scalar(.{ .int = 10 }), false);

    var root = hydmod.Map.init(gpa, .root);
    defer root.deinit();
    try root.putOwned("z", hydmod.MapValue.init(hydmod.Value.scalar(.{ .int = 30 }), false));
    try root.putOwned("b", hydmod.MapValue.init(.{ .object = .{ .list = list } }, false));
    try root.putOwned("a", hydmod.MapValue.init(.{ .object = .{ .map = inner } }, false));
    // **The move, made explicit**, as the test above spells it: `root` holds
    // both tables now, so the local names must not free them a second time.
    list = hydmod.List.init(gpa, .root);
    inner = hydmod.Map.init(gpa, .root);

    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit() catch @panic("testing allocator cleanup cannot inject failure");
    const start_op = tx.start_op;
    try tx.updateMapValue(.root, &root);

    // **Seven operations, in the order `updateValue` writes them.**
    // [`updateValue`](inner.rs:1203-1256) makes the child and then recurses
    // into it before the next key, so the counters run
    // `a, x, y, b, [0], [1], z`. A queue would have given
    // `a, b, z, x, y, [0], [1]` — and with it every change hash, because
    // [`nextId`] is `start_op + pending.len` (`:515-518`) and [`Batch.append`]
    // reads that same length (`:2518`) *after* the caller has taken the id.
    // **Append order into `pending` is id order**, which is why a batch is
    // free to be one splice and is not free to be a queue.
    try testing.expectEqual(@as(usize, 7), tx.pending.items.len);
    const want = [_]struct { key: []const u8, action: Action, insert: bool }{
        .{ .key = "a", .action = .make_map, .insert = false },
        .{ .key = "x", .action = .set, .insert = false },
        .{ .key = "y", .action = .set, .insert = false },
        .{ .key = "b", .action = .make_list, .insert = false },
        .{ .key = "", .action = .set, .insert = true },
        .{ .key = "", .action = .set, .insert = true },
        .{ .key = "z", .action = .set, .insert = false },
    };
    for (tx.pending.items, want, 0..) |item, w, i| {
        try testing.expectEqual(start_op + @as(u64, @intCast(i)), @as(u64, item.tx.id().counter));
        try testing.expectEqual(w.action, item.tx.action());
        try testing.expectEqual(w.insert, item.tx.insert());
        if (w.insert) {
            // A sequence row is anchored to an element and not to a property
            // name, and the key column is the one that says so.
            try testing.expect(item.tx.keyStr() == null);
        } else {
            try testing.expectEqualStrings(w.key, item.tx.keyStr().?);
        }
    }

    var committed_10 = try tx.commit();
    defer committed_10.deinit(gpa);

    // **And the rows are not in the order the operations were written in.**
    // On an empty document the root's three rows were spliced at 0, then 1 and
    // 2 were taken by the nested map's block, and the root's second and third
    // rows were then spliced *back into* 1 and 2. **So consecutive writes do
    // not share an insertion point**, and each position is read off the live
    // op set by the write that follows it — [`seekOpsByMapKey`](opset/op_set.zig)
    // at `:677` and [`mapKeyRow`] at `:696`. That is the whole of why the
    // `update_*` family cannot be written the way [`Batch`] writes a BFS walk,
    // and the row order below is what pins it.
    try testing.expectEqual(@as(usize, 7), doc.ops.len());
    const root_rows = try doc.ops.scopeToObj(.root);
    try testing.expectEqual(@as(usize, 0), root_rows.start);
    try testing.expectEqual(@as(usize, 3), root_rows.end);
}

test "a made object resolves the same on every write, and a spent transaction refuses anyway" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit() catch @panic("testing allocator cleanup cannot inject failure");
    const child = try tx.putObject(.root, .{ .key = "c" }, .map);
    // **The escape hatch, three times.** An object this transaction made is
    // in no clock, so [`exidToObj`] answers it from `made_here` alone
    // (`:586-589`) — and each of these has to resolve `child` to the same
    // object, or the three registers land in three different places. This is
    // the property a memo of `exidToObj` would rest on, so it is worth
    // pinning as a fact about the transaction and not about a cache.
    _ = try tx.put(child, .{ .key = "one" }, .{ .int = 1 });
    _ = try tx.put(child, .{ .key = "two" }, .{ .int = 2 });
    _ = try tx.put(child, .{ .key = "three" }, .{ .int = 3 });
    var committed_11 = try tx.commit();
    defer committed_11.deinit(gpa);

    var one = try registerIn(gpa, &doc, child, "one");
    defer one.deinit(gpa);
    var two = try registerIn(gpa, &doc, child, "two");
    defer two.deinit(gpa);
    var three = try registerIn(gpa, &doc, child, "three");
    defer three.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), one.ops.items.len);
    try testing.expectEqual(@as(usize, 1), two.ops.items.len);
    try testing.expectEqual(@as(usize, 1), three.ops.items.len);
    // All three wrote the same parent object, so all three rows name it.
    // **The column is the parent and not the row's own id**: `Op.id` is
    // `OpLike::id` (`op.zig:2056-2059`), the operation's own identity, and
    // each of these three rows is a *different* operation — `nextId` minted
    // one per write — so comparing it against `child` compares two
    // operations that are never the same one. `Op.obj` is the parent the
    // object columns hold (`op.zig:2063-2066`), and *that* is what
    // `exidToObj` resolved: the same value three times is the property, and
    // one row's own id landing on another's counter is not.
    const parent = child.opId().?;
    try testing.expect(parent.eql(one.ops.items[0].obj().?));
    try testing.expect(parent.eql(two.ops.items[0].obj().?));
    try testing.expect(parent.eql(three.ops.items[0].obj().?));

    // **And the refusal still fires, on an id this transaction has already
    // resolved.** `requireOpen` runs ahead of the lookup on every call
    // (`:581`), and that is the one thing a memo must not skip: a spent
    // transaction answers `start_op` from `nextId` (`:515-518`), so a write
    // that got past it would land on an op id the document already holds.
    try testing.expectError(error.InvalidOp, tx.put(child, .{ .key = "four" }, .{ .int = 4 }));
    try testing.expectError(error.InvalidOp, tx.putObject(child, .{ .key = "d" }, .map));

    // The same through the other door onto `requireOpen`, which is a
    // rollback rather than a commit.
    var tx2 = try Transaction.open(gpa, &doc);
    defer tx2.deinit() catch @panic("testing allocator cleanup cannot inject failure");
    const again = try tx2.putObject(.root, .{ .key = "c2" }, .map);
    _ = try tx2.put(again, .{ .key = "x" }, .{ .int = 1 });
    _ = try tx2.rollback();
    try testing.expectError(error.InvalidOp, tx2.put(again, .{ .key = "y" }, .{ .int = 2 }));
}

test "updateText is a diff: an unchanged text writes no operation" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();
    const text = try doc.putObject(.root, .{ .key = "t" }, .text);
    try doc.spliceText(text, 0, 0, "hello world");

    _ = try doc.commit();
    const changes = doc.doc.graph.len();
    const rows = doc.doc.ops.len();
    try doc.updateText(text, "hello world");
    // **No change at all**, which is the property a write and a diff share and
    // only a diff has.
    try testing.expectEqual(changes, doc.doc.graph.len());
    try testing.expectEqual(rows, doc.doc.ops.len());

    try doc.updateText(text, "hello there");
    _ = try doc.commit();
    const got = try doc.text(text, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("hello there", got);
    try testing.expect(doc.doc.graph.len() > changes);
}

test "a spliced character does not follow the caller's buffer into the change" {
    const gpa = testing.allocator;
    // **This is the defect the value column's copy used to read.** The op set
    // interns a string when the row is spliced in
    // ([`opset/columns.zig:45`](opset/columns.zig)), so the *document* reads
    // the right characters whether the operation borrowed the caller's buffer
    // or copied it; what the borrow decides is the bytes `commit` encodes, and
    // the change's hash is taken over exactly those
    // ([`Document.commit`](doc.zig)). So the assertion is a hash, against a
    // control run of the same operations in a document with the same actor —
    // `freshDoc` gives both the same one, and the actor, the clock, the
    // operation ids and the dependencies are then all equal, so the two
    // hashes differ in nothing but the payload bytes.
    var clean = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try clean.setActorId(.{ .bytes = "0123456789abcdef" });
    defer clean.deinit();
    const clean_text = try clean.putObject(.root, .{ .key = "t" }, .text);
    try clean.spliceText(clean_text, 0, 0, "hello world");
    _ = try clean.commit();
    const want = clean.doc.graph.getHeads();
    try testing.expectEqual(@as(usize, 1), want.len);

    var dirty = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try dirty.setActorId(.{ .bytes = "0123456789abcdef" });
    defer dirty.deinit();
    const dirty_text = try dirty.putObject(.root, .{ .key = "t" }, .text);

    var buf: [11]u8 = "hello world".*;
    try dirty.spliceText(dirty_text, 0, 0, &buf);
    // **The caller takes its buffer back before the commit.** That is the
    // whole shape of the bug and not a corner case: every `textdiff` hook
    // splices from a local it frees when the call returns —
    // [`TxHook.insert`](textdiff.zig) and [`TxHook.replace`](textdiff.zig) on
    // a `concat`, [`BlockDiffHook.insert`](textdiff.zig) on a `run` — and the
    // operations it queues are not encoded until the commit. Upstream cannot
    // be caught by this, because its `TxOp` holds an `OpBuilder<'static>`
    // ([`op.rs:164-170`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
    // and a `pending` vector cannot hold a borrow of a local; the port's
    // cannot enforce that, so [`Transaction.ownText`] takes the copy instead.
    @memset(&buf, 'Z');
    const got = (try dirty.commit()).?;

    try testing.expect(want[0].eql(got));
}

test "batchCreateObject makes an empty object, and batchCreateValue fills it" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();

    const empty = try doc.batchCreateObject(.root, .{ .key = "e" }, .map);
    try testing.expectEqual(ObjType.map, try doc.objectType(empty));
    try testing.expectEqual(@as(usize, 0), doc.doc.ops.seqLength(empty, doc.textEncoding(), null));

    var inner = hydmod.Map.init(gpa, .root);
    defer inner.deinit();
    try inner.putOwned("n", hydmod.MapValue.init(hydmod.Value.scalar(.{ .int = 4 }), false));
    const full = try doc.batchCreateValue(.root, .{ .key = "f" }, .{ .object = .{ .map = inner } }, false);
    try testing.expectEqual(ObjType.map, try doc.objectType(full));
    // **The child key is in the child object, not in the root.** `full` is the
    // object row 1 made and the batch wrote `"n"` under it
    // (`inner.rs:1269-1331`), so looking the key up at the root finds nothing
    // — and it used to find something, because the child's `ExId` came back
    // as the root and the batch wrote into the root by mistake. Both halves
    // are asserted: the value is where it belongs **and** it is not where it
    // used to land by accident.
    var n = try doc.doc.ops.seekOpsByMapKey(gpa, full, "n", null);
    defer n.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), n.ops.items.len);
    try testing.expectEqual(@as(i64, 4), n.ops.items[0].value().int);
    var stray = try register(gpa, &doc.doc, "n");
    defer stray.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), stray.ops.items.len);

    // A list position and an object value: the `insert` form.
    const list = try doc.putObject(.root, .{ .key = "l" }, .list);
    const nested = try doc.batchCreateValue(list, .{ .index = 0 }, .{ .object = .{ .map = inner } }, true);
    try testing.expectEqual(ObjType.map, try doc.objectType(nested));
    try testing.expectEqual(@as(usize, 1), doc.doc.ops.seqLength(list, doc.textEncoding(), null));

    // A scalar is not an object (`inner.rs:1288-1293`).
    try testing.expectError(
        error.NotAnObject,
        doc.batchCreateValue(.root, .{ .key = "s" }, hydmod.Value.scalar(.{ .int = 1 }), false),
    );
}

test "updateSpans brings a text object's spans and marks in line" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    defer doc.deinit();
    const text = try doc.putObject(.root, .{ .key = "t" }, .text);
    try doc.spliceText(text, 0, 0, "hello");

    // One span of text carrying one mark, which the document does not have.
    var marks = MarkSet.init(gpa);
    defer marks.deinit();
    try marks.put("em", .{ .bool_value = true });

    const spans = [_]@import("iter/spans.zig").SpanInput{.{ .text = .{ .text = "hello", .marks = &marks } }};
    try doc.updateSpans(text, &spans);

    const got = try doc.text(text, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("hello", got);
    const found = try doc.marks(text, gpa);
    defer gpa.free(found);
    // **The mark the spans asked for exists.** The text diff cannot see a mark
    // — it compares grapheme clusters — so the second pass is the only thing
    // that can have written it.
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("em", found[0].name);
    try testing.expectEqual(@as(usize, 0), found[0].start);
    try testing.expectEqual(@as(usize, 5), found[0].end);

    // Running it again writes nothing: the mark is already there.
    const rows = doc.doc.ops.len();
    try doc.updateSpans(text, &spans);
    try testing.expectEqual(rows, doc.doc.ops.len());

    // Borrowed rich blocks must be captured before the caller releases their maps.
    {
        var source_block = hydmod.Map.init(gpa, .root);
        defer source_block.deinit();
        try source_block.putOwned("kind", hydmod.MapValue.init(.{ .str = "paragraph" }, false));
        const rich = [_]@import("iter/spans.zig").SpanInput{
            .{ .block = &source_block },
            .{ .text = .{ .text = "hello", .marks = &marks } },
        };
        try doc.updateSpans(text, &rich);
        try source_block.putOwned("kind", hydmod.MapValue.init(.{ .str = "mutated" }, false));
    }
    _ = try doc.commit();
    var rich_spans = try readmod.spans(&doc.doc, text, gpa);
    defer rich_spans.deinit();
    var block_span = (try rich_spans.next()).?;
    defer block_span.deinit(gpa);
    try testing.expect(block_span == .block);
    try testing.expectEqualStrings("paragraph", block_span.block.get("kind").?.str);
    var text_span = (try rich_spans.next()).?;
    defer text_span.deinit(gpa);
    try testing.expect(text_span == .text);
    try testing.expectEqualStrings("hello", text_span.text.text);
    try testing.expect((try rich_spans.next()) == null);
}

// ── The row order a local write leaves behind ─────────────────────────────────
//
// **A local write and an applied change reach the same state by two doors, and
// only one of them was checked.** Upstream asserts `validate_op_order` at
// exactly one place in the crate — the `debug_assert!` at the end of every
// apply ([`batch.rs:949`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs))
// — and the load path asserts `validate_top_index` instead
// ([`storage/document.rs:351`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs)),
// so **the local write path has no equivalent check upstream and never had
// one.** The three tests below are that check.

/// A raw document under `actor`. Replays use a different actor so applying
/// the same state does not answer "already have it".
fn docWithActor(gpa: Allocator, actor: []const u8) !Document {
    var doc = try Document.init(gpa, std.testing.io);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = actor });
    return doc;
}

/// `dst` gets every change `src` holds, in dependency order, through
/// [`Document.applyChanges`] — **the apply path**, the one upstream asserts row
/// order on.
fn applyAll(gpa: Allocator, dst: *Document, src: *Document) !void {
    var built = try src.getChanges(gpa, &.{});
    defer built.deinit(gpa);
    if (built.len() == 0) return;
    // `Built.change` borrows `Built.body`, so the list has to outlive the
    // slice; that is `Changes`' own rule ([doc.zig](doc.zig)).
    const incoming = try gpa.alloc(changerec.Change, built.len());
    defer gpa.free(incoming);
    for (built.slice(), incoming) |*b, *slot| slot.* = b.change;
    _ = try dst.applyChanges(gpa, incoming);
}

/// The root map's keys, **in the order a reader reads them**. The caller owns
/// the slice and not the keys: each is borrowed from the document's string
/// table, and a map key is not the walk's own buffer, so the list is stable
/// until the document is mutated ([iter/keys.zig:170-173](iter/keys.zig)).
fn rootKeys(gpa: Allocator, doc: *Document) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var keys = try readmod.keys(doc, .root);
    defer keys.deinit(gpa);
    while (try keys.next()) |key| try out.append(gpa, key);
    return out.toOwnedSlice(gpa);
}

/// The op ids of **every row** of the root register under `key`, in row order.
/// The caller owns the slice.
///
/// Not [`register`], which is the *visible* rows: a `put` that overwrites a
/// peer's value leaves one visible row and two rows, and **rule R3** — ids
/// ascending within a register ([`Op.step`](opset/op.zig),
/// [`op.rs:1056-1057`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
/// — is a statement about all of them.
fn registerIds(gpa: Allocator, doc: *Document, key: []const u8) ![]OpId {
    var out: std.ArrayList(OpId) = .empty;
    errdefer out.deinit(gpa);
    const rows = try doc.ops.propRange(.root, key);
    var walk = try doc.ops.iterRange(rows);
    while (try walk.next()) |row| try out.append(gpa, row.id());
    return out.toOwnedSlice(gpa);
}

/// Names the row and the side when two op sets are **not** the same document,
/// and says nothing when they are.
///
/// [`OpSet.debugDiff`](opset/op_set.zig) answers `null` for "the same
/// document" and a [`DebugCmpFault`](opset/op_set.zig) for anything else, and
/// its `.row_order` arm carries the row the order first breaks at and **which
/// of the two op sets is the broken one**. That is the whole reason the fault
/// carries them: a `validateOpOrder` that answers `false` says a document is
/// out of order and nothing about where or on which side, and on a pair of
/// documents that hold the same rows it is the difference that decides which
/// one is wrong.
fn reportRowOrder(left: *const Document, right: *const Document) !void {
    if (try left.ops.debugDiff(&right.ops)) |fault| {
        switch (fault) {
            .row_order => |r| std.debug.print(
                "row order breaks at row {d}, and the {s} document is the broken one\n",
                .{ r.at, @tagName(r.side) },
            ),
            else => std.debug.print("the two op sets differ: {s}\n", .{@tagName(fault)}),
        }
    }
}

test "a map key written after another key lands in key order, and a reader reads that order" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "aaaaaaaaaaaaaaaa" });
    defer doc.deinit();

    // **The write order is not the key order, and `"k"` sorts before
    // `"list"`.** This is the two-row document the defect was reported on.
    _ = try doc.put(.root, .{ .key = "list" }, .{ .int = 1 });
    _ = try doc.put(.root, .{ .key = "k" }, .{ .int = 2 });
    _ = try doc.commit();

    // The same two changes through the other door: the apply path, which is
    // where upstream asserts the order.
    var replay = try docWithActor(gpa, "bbbbbbbbbbbbbbbb");
    defer replay.deinit();
    try applyAll(gpa, &replay, &doc.doc);

    // **The diagnostic runs first**, so that a document out of row order
    // fails with the row and the side on the line above the assertion rather
    // than with `expected true, found false`.
    try reportRowOrder(&doc.doc, &replay);

    // **The checker.** Rules R1–R4 of [`Op.step`](opset/op.zig)
    // ([`op.rs:1048-1073`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    // over every row. This answers `false` on the document as it was written.
    try testing.expect(try doc.doc.ops.validateOpOrder());
    try testing.expect(try replay.ops.validateOpOrder());

    // **The read, which is what makes this a correctness defect and not a
    // tidiness one.** A map reader does not sort — "the reader does not sort,
    // so this order is the answer order"
    // ([`map_range.zig:1486-1490`](iter/map_range.zig)) — so a document whose
    // registers are in the wrong row order **reads back as a different map**.
    // **This is the assertion a by-value comparison cannot make**: the two
    // documents below hold the same rows and the same values, so they compare
    // equal while reading back in opposite orders.
    const keys = try rootKeys(gpa, &doc.doc);
    defer gpa.free(keys);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqualStrings("k", keys[0]);
    try testing.expectEqualStrings("list", keys[1]);

    // **And the two doors agree**, which is what the apply path's own
    // `debug_assert!` is asking.
    try testing.expect((try doc.doc.ops.debugDiff(&replay.ops)) == null);
}

test "map placement compares key bytes inside each object across retained and deleted registers" {
    // Intern order deliberately differs from byte order, including prefix,
    // NUL and multibyte UTF-8 keys. A deleted register still occupies rows.
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer doc.deinit();
    try doc.setActorId(.{ .bytes = "bbbbbbbbbbbbbbbb" });
    const child = try doc.putObject(.root, .{ .key = "child" }, .map);
    const ordered = [_][]const u8{ "", "\x00", "a", "a\x00", "a\x00z", "z", "é", "🦀" };
    const write_order = [_]usize{ 7, 3, 5, 0, 6, 2, 4, 1 };
    for (write_order) |i| {
        _ = try doc.put(child, .{ .key = ordered[i] }, .{ .int = @intCast(i) });
    }
    _ = try doc.put(child, .{ .key = "" }, .{ .int = 99 });
    _ = try doc.delete(child, .{ .key = "a\x00" });
    _ = try doc.commit();
    // Renumber the resident actor indices before asking for the same object.
    try doc.setActorId(.{ .bytes = "aaaaaaaaaaaaaaaa" });
    _ = try doc.put(child, .{ .key = "b" }, .{ .int = 8 });
    _ = try doc.commit();

    const object_rows = try doc.doc.ops.scopeToObj(child);
    const expected = [_]struct { key: []const u8, start: usize, end: usize }{
        .{ .key = "", .start = 0, .end = 2 },
        .{ .key = "\x00", .start = 2, .end = 3 },
        .{ .key = "a", .start = 3, .end = 4 },
        .{ .key = "a\x00", .start = 4, .end = 5 },
        .{ .key = "a\x00z", .start = 5, .end = 6 },
        .{ .key = "b", .start = 6, .end = 7 },
        .{ .key = "z", .start = 7, .end = 8 },
        .{ .key = "é", .start = 8, .end = 9 },
        .{ .key = "🦀", .start = 9, .end = 10 },
        .{ .key = "\x00x", .start = 3, .end = 3 },
        .{ .key = "a\x00y", .start = 5, .end = 5 },
        .{ .key = "zz", .start = 8, .end = 8 },
        .{ .key = "🦀z", .start = 10, .end = 10 },
    };
    for (expected) |case| {
        const rows = try doc.doc.ops.propRange(child, case.key);
        try testing.expectEqual(object_rows.start + case.start, rows.start);
        try testing.expectEqual(object_rows.start + case.end, rows.end);
        var found = try doc.doc.ops.seekOpsByMapKey(gpa, child, case.key, null);
        defer found.deinit(gpa);
        try testing.expectEqual(rows.end, found.end_pos);
        if (std.mem.eql(u8, case.key, "a\x00")) {
            try testing.expectEqual(@as(usize, 0), found.ops.items.len);
        }
    }
    var keys = try readmod.keys(&doc.doc, child);
    defer keys.deinit(gpa);
    const visible = [_][]const u8{ "", "\x00", "a", "a\x00z", "b", "z", "é", "🦀" };
    for (visible) |key| {
        try testing.expectEqualStrings(key, (try keys.next()) orelse return error.TestUnexpectedResult);
    }
    try testing.expect((try keys.next()) == null);
    try testing.expect(try doc.doc.ops.validateOpOrder());
    var replay = try docWithActor(gpa, "cccccccccccccccc");
    defer replay.deinit();
    try applyAll(gpa, &replay, &doc.doc);
    try testing.expect((try doc.doc.ops.debugDiff(&replay.ops)) == null);
}

test "a register's rows ascend in id, because a local id is above every counter in the document" {
    const gpa = testing.allocator;

    // A peer that reaches counter 6 before it writes the register under test,
    // so the row it leaves in `"k"` carries the greater id. `"junk"` sorts
    // before `"k"`, so the two registers are in key order and only **R3** is
    // under test here.
    var peer = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try peer.setActorId(.{ .bytes = "bbbbbbbbbbbbbbbb" });
    defer peer.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try peer.put(.root, .{ .key = "junk" }, .{ .int = @intCast(i) });
    }
    _ = try peer.put(.root, .{ .key = "k" }, .{ .int = 99 });
    _ = try peer.commit();

    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "aaaaaaaaaaaaaaaa" });
    defer doc.deinit();
    try applyAll(gpa, &doc.doc, &peer.doc);

    // **This actor has written nothing**, so its own next counter is 1, and
    // `1` sorts *below* the peer's `6`. `start_op` is
    // `change_graph.max_op() + 1`
    // ([`automerge.rs:567`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // — **the whole document's maximum, not this actor's own next counter** —
    // and [`TransactionInner::next_id`] adds the pending count
    // ([`inner.rs:294-296`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    // so the row about to be written is `7` and appending at the register's
    // end keeps R3. The query supplies that end for both present and absent
    // keys. A `start_op` that were per-actor would put `1` after `6` here,
    // and `validateOpOrder` would answer `false`.
    const id = try doc.put(.root, .{ .key = "k" }, .{ .int = 100 });
    try testing.expectEqual(@as(u32, 7), (id orelse return error.TestUnexpectedResult).counter);

    const ids = try registerIds(gpa, &doc.doc, "k");
    defer gpa.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expect(ids[0].order(ids[1]) == .lt);
    try testing.expect(try doc.doc.ops.validateOpOrder());

    // The `top` index still agrees with the rows, which a register with two
    // rows and one visible winner is the easy way to break.
    try testing.expect((try doc.doc.ops.validateTopIndex()) == null);
}

test "a list insert lands where the sequence order says, not where the write happened" {
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    try doc.setActorId(.{ .bytes = "aaaaaaaaaaaaaaaa" });
    defer doc.deinit();

    const list = try doc.putObject(.root, .{ .key = "l" }, .list);
    _ = try doc.insert(list, 0, .{ .str = "a" });
    _ = try doc.insert(list, 1, .{ .str = "b" });
    _ = try doc.insert(list, 2, .{ .str = "c" });
    // Insert at positions rather than at the end.
    _ = try doc.insert(list, 0, .{ .str = "z" });
    _ = try doc.insert(list, 2, .{ .str = "y" });
    _ = try doc.commit();

    var replay = try docWithActor(gpa, "bbbbbbbbbbbbbbbb");
    defer replay.deinit();
    try applyAll(gpa, &replay, &doc.doc);
    try reportRowOrder(&doc.doc, &replay);

    // **A sequence register's key is the element it hangs by, so R2's sequence
    // arm is a different rule from a map key's** — the previous key may equal
    // this one, or the row's own id must sort below that element's
    // ([`op.rs:1061-1063`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
    // — **and the list path never went through `propRange`**, so it is
    // checked here rather than assumed. The same answer from the apply path
    // is the control: the two were already equal before the map fix and are
    // equal now.
    try testing.expect(try doc.doc.ops.validateOpOrder());
    try testing.expect((try doc.doc.ops.validateTopIndex()) == null);
    try testing.expect((try doc.doc.ops.debugDiff(&replay.ops)) == null);

    // **The read.** The five values, in the order the sequence walks them, is
    // what says the two insertions went where they were asked to go rather
    // than merely that the rows are in some legal order.
    var term: readmod.ValueTerm = undefined;
    var it = try readmod.values(&doc.doc, list, &term);
    // `Values` owns nothing: the term is the out-slot the caller frees
    // ([read.zig:697-708](read.zig)).
    defer term.deinit(gpa);
    const want = [_][]const u8{ "z", "a", "y", "b", "c" };
    var seen: usize = 0;
    while (try it.next()) |item| {
        switch (item.value) {
            .scalar => |scalar| {
                try testing.expect(seen < want.len);
                try testing.expectEqualStrings(want[seen], scalar.str);
                seen += 1;
            },
            .object => {},
        }
    }
    try testing.expectEqual(want.len, seen);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **A queued text operation owns its characters here, where upstream's type
//   makes it own them.** `BatchInsertion::splice_text` collects an **owned**
//   `Vec<ScalarValue>` and moves one value into each operation
//   ([`inner.rs:1481-1501`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs));
//   it can, because `TxOp` holds an `OpBuilder<'static>`
//   ([`op.rs:164-170`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
//   and a `pending` vector will not compile with a `Cow::Borrowed` in it. This
//   port's [`OpBuilder`] has no lifetime parameter, so it borrows whatever it
//   is handed ([`OpBuilder.deinit`](opset/op.zig) frees the predecessor list
//   "and nothing else"), and the copy that upstream's type performs is done
//   here by hand: [`Transaction.ownText`] keeps a copy of every unit until
//   [`deinit`], next to the `text_cache` that does the same for the *old*
//   side of a diff.
//
//   **It has to be done, and doing it only at the hook would be a half fix.**
//   Every `textdiff` hook splices from a buffer it frees when the call
//   returns — [`TxHook.insert`](textdiff.zig) and [`TxHook.replace`](textdiff.zig)
//   on a `concat`, [`BlockDiffHook.insert`](textdiff.zig) on a `run` — and
//   upstream does exactly the same (`text_diff.rs:80`, `:128`, `:326`,
//   `:343`), so the borrow is upstream's shape too. What upstream's lifetime
//   stops is a `pending` that outlives the local. The operations are queued
//   here and are not encoded until [`commit`], and the value column reads
//   their payloads then: before this, `updateSpans` over a document with a
//   pre-existing mark committed a change whose payload was a `memcpy` of freed
//   memory, and the suite died in
//   [`columnar/encoding.zig`](columnar/encoding.zig)'s `appendPayload`. The
//   copy is therefore in the one place every text insert goes through, not in
//   the three hooks that can produce a temporary.
//
// * **`textFor` and `spliceText` are the two halves of one contract**, and both
//   say so now: the hook is given no way to signal that the call is over, so
//   the bytes on both sides of a diff belong to the transaction. Before, only
//   the read side did, and the write side was the hole.
//
// * **A block's map belongs to the transaction as well, and it is one
//   allocation per map rather than a slot in a list.** [`Block`] hands the
//   diff a `*const hydmod.Map`, and the operations `update_map` writes borrow
//   that map's keys and values, so the map has to outlive [`updateSpans`] — and
//   it used not to: it was a local with a `defer`, freed when `updateSpans`
//   returned and *before* the commit that reads it. That is the same
//   use-after-free as the text above, on the other side of the same diff, and
//   it stayed quiet only because a freed-but-unreused allocation still holds
//   its old bytes. The `ensureTotalCapacity(spans.len + 1)` that stood behind
//   it was a guess rather than a bound: the *old* side of the diff walks every
//   block the document already holds, and nothing there knows how many that
//   is. A pointer per map is stable by construction, so the reservation went
//   with it.
//
// * **No test for the block half, and that is a decision, not an omission.**
//   The text half has one that fails without the fix because a caller can be
//   made to overwrite its own buffer between the splice and the commit. There
//   is no analogue for the block half: the map is built from the document, and
//   nothing between `updateSpans` and `commit` writes over it on demand, which
//   is the same reason it never faulted. What the change is verified by is
//   the five `diff_marks` block cases, `testing.allocator`, and the lifetime
//   now being unconditional instead of resting on a capacity guess.
//
// * Map writes use the full physical register end from `OpSet.propRange`,
//   matching `inner.rs:473` and `op_set.rs:611-628,1268-1271`. Native bounds
//   compare resolved key bytes, not first-seen intern IDs. An absent key
//   receives its sorted insertion slot; existing conflicts and deleted rows
//   remain in the register. Map range reads use the same bounds.
//
// * **R3 holds on this path by construction.**
//   `start_op` is `change_graph.max_op() + 1`
//   ([`automerge.rs:567`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)) —
//   **the whole document's maximum, not this actor's own next counter** — and
//   [`TransactionInner::next_id`] adds the pending count
//   ([`inner.rs:294-296`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
//   So a local op's id is above every counter the document holds, whichever
//   actor wrote the register's last row, and appending at the register's end
//   keeps ids ascending (`op.rs:1056-1057`). Upstream relies on exactly this,
//   which is why its `query.end_pos` needs no check. **The test
//   "a register's rows ascend in id" asserts it** rather than reasoning about
//   it: it pulls a peer's `6@1` into a register this actor has never written
//   and asserts the next local row is `7`, which a per-actor `start_op` would
//   have made `1`.
//
// * **The list and text paths are unchanged, and they are checked rather than
//   assumed.** A sequence register's key is the element it hangs by, so R2's
//   sequence arm is a different rule from a map key's
//   ([`op.rs:1061-1063`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
//   and those positions come from the list index and
//   [`OpSet.queryInsertAt`](opset/op_set.zig) rather than from `propRange`.
//   The test inserts at the head and in the middle, asserts
//   [`OpSet.validateOpOrder`] and [`OpSet.validateTopIndex`], compares against
//   the same changes applied through the apply path, **and reads the five
//   values back in the order they were asked for** — the row order alone would
//   not say where the two insertions went.

test "commit allocation refusals preserve rollback and recorded history" {
    var reached_success = false;
    for (0..256) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try Document.init(gpa, testing.io);
        defer doc.deinit();
        doc.setActorId(types.ActorId.init("rollback-regression"));
        {
            var first = try Transaction.open(gpa, &doc);
            defer first.deinit() catch @panic("allocator is not injecting during cleanup");
            _ = try first.put(.root, .{ .key = "baseline" }, .{ .int = 7 });
            var result = try first.commit();
            defer result.deinit(gpa);
        }
        var tx = try Transaction.open(gpa, &doc);
        defer {
            failing.fail_index = std.math.maxInt(usize);
            tx.deinit() catch @panic("allocation restored before cleanup");
        }
        _ = try tx.put(.root, .{ .key = "uncommitted" }, .{ .int = 42 });
        failing.fail_index = failing.alloc_index + offset;
        var result = tx.commitWith(.{ .message = "refused", .time = 9 }) catch |commit_error| {
            failing.fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, commit_error);
            try testing.expect(!tx.closed);
            try testing.expectEqual(@as(usize, 1), doc.graph.len());
            try testing.expectEqual(@as(usize, 1), try tx.rollback());
            try testing.expect((try readmod.get(&doc, .root, .{ .key = "uncommitted" })) == null);
            try testing.expectEqual(@as(i64, 7), (try readmod.get(&doc, .root, .{ .key = "baseline" })).?.value.scalar.int);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        defer result.deinit(gpa);
        try testing.expect(result.hash != null);
        try testing.expectEqual(@as(usize, 2), doc.graph.len());
        reached_success = true;
        break;
    }
    try testing.expect(reached_success);
}

test "textFor refusal preserves the previous borrowed buffer" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var doc = try Document.init(gpa, testing.io);
    defer doc.deinit();
    var tx = try Transaction.open(gpa, &doc);
    defer {
        failing.fail_index = std.math.maxInt(usize);
        tx.deinit() catch @panic("allocation restored before cleanup");
    }
    const obj = try tx.putObject(.root, .{ .key = "text" }, .text);
    try tx.spliceText(obj, 0, 0, "hello");
    const before = try tx.textFor(obj);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, tx.textFor(obj));
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqualStrings("hello", before);
    _ = try tx.rollback();
}

test "native validation refusal without recovery work leaves reads and writes available" {
    // Validation before publication leaves the held journal writable.
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer doc.deinit();
    const text = try doc.putObject(.root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "original");
    _ = try doc.commit();
    const rows = doc.doc.ops.len();
    const changes = doc.doc.graph.len();
    const max_op = doc.doc.graph.maxOp();
    try testing.expectError(error.InvalidOp, doc.put(text, .{ .key = "scalar" }, .{ .int = 7 }));
    const unchanged = try doc.text(text, gpa);
    defer gpa.free(unchanged);
    try testing.expectEqualStrings("original", unchanged);
    try testing.expectEqual(@as(usize, 0), doc.pendingOps());
    try testing.expectEqual(rows, doc.doc.ops.len());
    try testing.expectEqual(changes, doc.doc.graph.len());
    try testing.expectEqual(max_op, doc.doc.graph.maxOp());
    try doc.spliceText(text, 8, 0, "!");
    const following = try doc.text(text, gpa);
    defer gpa.free(following);
    try testing.expectEqualStrings("original!", following);
    try testing.expectEqual(@as(usize, 1), doc.pendingOps());
}

test "native fresh-document validation refusal leaves unused actor metadata readable" {
    // A refused write can intern an actor without publishing any operation.
    const gpa = testing.allocator;
    var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
    defer doc.deinit();
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    try testing.expectError(error.InvalidOp, doc.put(.root, .{ .index = 0 }, .{ .int = 7 }));
    try testing.expect((try doc.get(.root, .{ .key = "text" })) == null);
    try testing.expectEqual(@as(usize, 0), doc.pendingOps());
    try testing.expectEqual(@as(usize, 0), doc.doc.ops.len());
    try testing.expectEqual(@as(usize, 0), doc.doc.graph.len());
    try testing.expectEqual(@as(u64, 0), doc.doc.graph.maxOp());
    try testing.expectEqual(doc.doc.ops.actors.items.len, doc.doc.graph.numActors());
    try testing.expectEqual(doc.doc.ops.actors.items.len, doc.doc.authors.count());
    try testing.expectEqualStrings("0123456789abcdef", doc.getActorId().bytes);
    const text = try doc.putObject(.root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "fresh");
    const following = try doc.text(text, gpa);
    defer gpa.free(following);
    try testing.expectEqualStrings("fresh", following);
}

test "isolated held auto rollback refusal retries without operation id collisions" {
    // Fresh fixtures exercise late publication and a second refused rollback.
    var reached_success = false;
    var reached_published_refusal = false;
    var reached_second_refusal = false;
    for (0..512) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
        defer doc.deinit();
        try doc.setActorId(.{ .bytes = "0123456789abcdef" });
        try doc.isolate(gpa, &.{});
        failing.fail_index = failing.alloc_index + offset;
        const refused = doc.put(.root, .{ .key = "a" }, .{ .int = 41 });
        if (refused) |_| {
            failing.fail_index = std.math.maxInt(usize);
            reached_success = true;
            break;
        } else |primary| {
            try testing.expectEqual(error.OutOfMemory, primary);
        }
        const published = doc.doc.ops.len() != 0;
        if (published) {
            reached_published_refusal = true;
            failing.fail_index = failing.alloc_index;
            try testing.expectError(error.OutOfMemory, doc.rollback());
            try testing.expectError(error.InvalidOp, doc.put(.root, .{ .key = "blocked" }, .{ .int = 99 }));
            try testing.expectEqual(@as(u64, 0), doc.doc.graph.maxOp());
            reached_second_refusal = true;
        }
        failing.fail_index = std.math.maxInt(usize);
        _ = try doc.rollback();
        const following = try doc.put(.root, .{ .key = "b" }, .{ .int = 42 });
        try testing.expect((try doc.get(.root, .{ .key = "a" })) == null);
        try testing.expect((try doc.get(.root, .{ .key = "blocked" })) == null);
        try testing.expectEqual(@as(i64, 42), (try doc.get(.root, .{ .key = "b" })).?.value.scalar.int);
        try testing.expectEqual(@as(usize, 1), doc.doc.ops.len());
        try testing.expectEqual(@as(u32, 1), (following orelse return error.TestUnexpectedResult).counter);
        try testing.expectEqual(@as(u64, 0), doc.doc.graph.maxOp());
        try testing.expect(try doc.doc.ops.validateOpOrder());
        try testing.expect((try doc.doc.ops.validateTopIndex()) == null);
        const bytes = try doc.save(gpa);
        defer gpa.free(bytes);
        var loaded = try Document.load(gpa, testing.io, bytes, doc.textEncoding());
        defer loaded.deinit();
        try testing.expectEqual(@as(usize, 1), loaded.ops.len());
        try testing.expect((try readmod.get(&loaded, .root, .{ .key = "a" })) == null);
        try testing.expectEqual(@as(i64, 42), (try readmod.get(&loaded, .root, .{ .key = "b" })).?.value.scalar.int);
    }
    try testing.expect(reached_success);
    try testing.expect(reached_published_refusal);
    try testing.expect(reached_second_refusal);
}

test "native hydrated held auto refusal retains published and queued producer undo" {
    // A nested producer crosses publication before failure; explicit rollback
    // must preserve the previously committed parent list.
    var reached_success = false;
    var reached_published_refusal = false;
    for (0..1024) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
        defer doc.deinit();
        const list = try doc.putObject(.root, .{ .key = "list" }, .list);
        _ = try doc.commit();
        var nested = hydmod.List.init(gpa, .root);
        defer nested.deinit();
        try nested.push(.{ .int = 7 }, false);
        const values = [_]hydmod.Value{
            .{ .int = 1 }, .{ .object = .{ .list = nested } }, .{ .int = 3 },
        };
        failing.fail_index = failing.alloc_index + offset;
        if (doc.splice(list, 0, 0, &values)) |_| {
            failing.fail_index = std.math.maxInt(usize);
            reached_success = true;
            try testing.expectEqual(@as(usize, 3), try doc.length(list));
            break;
        } else |primary| {
            try testing.expectEqual(error.OutOfMemory, primary);
        }
        reached_published_refusal = reached_published_refusal or doc.doc.ops.len() > 1;
        failing.fail_index = std.math.maxInt(usize);
        _ = try doc.rollback();
        _ = try doc.insert(list, 0, .{ .int = 42 });
        try testing.expectEqual(@as(usize, 1), try doc.length(list));
        try testing.expectEqual(@as(i64, 42), (try doc.get(list, .{ .index = 0 })).?.value.scalar.int);
        try testing.expectEqual(@as(usize, 2), doc.doc.ops.len());
        try testing.expectEqual(@as(usize, 1), doc.doc.graph.len());
        _ = try doc.commit();
        try testing.expectEqual(@as(usize, 2), doc.doc.graph.len());
        try testing.expect(try doc.doc.ops.validateOpOrder());
        try testing.expect((try doc.doc.ops.validateTopIndex()) == null);
    }
    try testing.expect(reached_success);
    try testing.expect(reached_published_refusal);
}

test "retained held auto rollback refuses overlapping mutation and survives caller release" {
    // Release caller storage after producer refusal, then retry the real held
    // journal's rollback while close barriers and writers remain refused.
    var reached = false;
    for (0..512) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try @import("autocommit.zig").AutoCommit.init(gpa, testing.io);
        defer doc.deinit();
        try doc.isolate(gpa, &.{});
        const transient = try gpa.dupe(u8, "refused");
        failing.fail_index = failing.alloc_index + offset;
        const attempted = doc.put(.root, .{ .key = "a" }, .{ .str = transient });
        gpa.free(transient);
        if (attempted) |_| {
            failing.fail_index = std.math.maxInt(usize);
            break;
        } else |primary| {
            try testing.expectEqual(error.OutOfMemory, primary);
        }
        failing.fail_index = std.math.maxInt(usize);
        if (doc.doc.ops.len() == 0) {
            _ = try doc.rollback();
            continue;
        }
        reached = true;
        try testing.expectEqual(@as(usize, 1), doc.pendingOps());
        try testing.expectError(error.InvalidOp, doc.put(.root, .{ .key = "blocked" }, .{ .int = 99 }));
        try testing.expectError(error.InvalidOp, doc.commit());
        try testing.expectError(error.InvalidOp, doc.isolate(gpa, &.{}));
        try testing.expectError(error.InvalidOp, doc.integrate());
        try testing.expectError(error.InvalidOp, doc.setActorId(types.ActorId.init("overlap")));
        try testing.expectError(error.InvalidOp, doc.applyChanges(gpa, &.{}));
        try testing.expectError(error.InvalidOp, doc.save(gpa));
        failing.fail_index = failing.alloc_index;
        try testing.expectError(error.OutOfMemory, doc.rollback());
        try testing.expectEqual(@as(usize, 1), doc.pendingOps());
        failing.fail_index = std.math.maxInt(usize);
        try testing.expectEqual(@as(usize, 1), try doc.rollback());
        try testing.expectEqual(@as(usize, 0), try doc.rollback());
        try doc.integrate();
        try doc.setActorId(types.ActorId.init("following"));
        _ = try doc.put(.root, .{ .key = "b" }, .{ .int = 42 });
        try testing.expect((try doc.get(.root, .{ .key = "a" })) == null);
        try testing.expectEqual(@as(i64, 42), (try doc.get(.root, .{ .key = "b" })).?.value.scalar.int);
        const heads = try doc.getHeads(gpa);
        defer gpa.free(heads);
        try testing.expectEqual(@as(usize, 1), heads.len);
        var meta = (try doc.doc.getChangeMetaByHash(gpa, heads[0])) orelse
            return error.TestUnexpectedResult;
        defer meta.deinit(gpa);
        try testing.expectEqualSlices(u8, &heads[0].bytes, &meta.hash.bytes);
        try testing.expectEqualStrings("following", meta.actor.bytes);
        try testing.expectEqual(@as(u64, 1), meta.seq);
        try testing.expectEqual(@as(u64, 1), meta.start_op);
        try testing.expectEqual(@as(u64, 1), meta.max_op);
        break;
    }
    try testing.expect(reached);
}

test "manual published producer refusal retains resumable undo and baseline" {
    // Overwriting a committed register exercises successor and scoped-reset
    // publication as well as the inserted row's ownership.
    const allocation_count = blk: {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        {
            var baseline = try Transaction.open(gpa, &doc);
            defer baseline.deinit() catch @panic("allocator is not injecting during cleanup");
            _ = try baseline.put(.root, .{ .key = "k" }, .{ .int = 7 });
            var result = try baseline.commit();
            defer result.deinit(gpa);
        }
        var tx = try Transaction.openAt(gpa, &doc, doc.graph.getHeads());
        defer tx.deinit() catch @panic("allocator is not injecting during cleanup");
        const before = failing.alloc_index;
        _ = try tx.put(.root, .{ .key = "k" }, .{ .int = 42 });
        const count = failing.alloc_index - before;
        _ = try tx.rollback();
        break :blk count;
    };
    var reached_success = false;
    var reached_partial = false;
    for (0..allocation_count + 1) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        {
            var baseline = try Transaction.open(gpa, &doc);
            defer baseline.deinit() catch @panic("allocator is not injecting during cleanup");
            _ = try baseline.put(.root, .{ .key = "k" }, .{ .int = 7 });
            var result = try baseline.commit();
            defer result.deinit(gpa);
        }
        var tx = try Transaction.openAt(gpa, &doc, doc.graph.getHeads());
        defer {
            failing.fail_index = std.math.maxInt(usize);
            tx.deinit() catch @panic("allocation restored before cleanup");
        }
        failing.fail_index = failing.alloc_index + offset;
        if (tx.put(.root, .{ .key = "k" }, .{ .int = 42 })) |_| {
            failing.fail_index = std.math.maxInt(usize);
            _ = try tx.rollback();
            reached_success = true;
            break;
        } else |primary| {
            try testing.expectEqual(error.OutOfMemory, primary);
        }
        failing.fail_index = std.math.maxInt(usize);
        const queued = tx.count();
        if (queued != 0) {
            reached_partial = true;
            try testing.expect(tx.rolling_back);
            try testing.expectError(error.InvalidOp, tx.commit());
            failing.fail_index = failing.alloc_index;
            try testing.expectError(error.OutOfMemory, tx.rollback());
            failing.fail_index = std.math.maxInt(usize);
        } else {
            try testing.expect(!tx.rolling_back);
        }
        try testing.expectEqual(queued, try tx.rollback());
        try testing.expectEqual(@as(usize, 1), doc.ops.len());
        try testing.expectEqual(@as(usize, 1), doc.graph.len());
        try testing.expectEqual(@as(i64, 7), (try readmod.get(&doc, .root, .{ .key = "k" })).?.value.scalar.int);
        try testing.expect((try doc.ops.validateTopIndex()) == null);
    }
    try testing.expect(reached_success);
    try testing.expect(reached_partial);
}

test "manual validation refusal before batch publication remains writable" {
    // An invalid lead byte after valid units must not poison an otherwise
    // valid transaction or queue/publish any part of the refused splice.
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit() catch @panic("testing allocator has no injected failure");
    const text = try tx.putObject(.root, .{ .key = "text" }, .text);
    const pending = tx.count();
    try testing.expectError(error.InvalidUtf8, tx.spliceText(text, 0, 0, "valid \xc3\xa9\xff"));
    try testing.expectEqual(pending, tx.count());
    try testing.expect(!tx.rolling_back);
    try tx.spliceText(text, 0, 0, "okay");
    var result = try tx.commit();
    defer result.deinit(gpa);
    const got = try doc.text(gpa, text);
    defer gpa.free(got);
    try testing.expectEqualStrings("okay", got);
}

test "pending transaction clone owns independent journal and patch log" {
    // Rolling back a clone cannot consume the source's rows, text or log.
    const gpa = testing.allocator;
    var source = try docWithActor(gpa, "journal-source");
    defer source.deinit();
    var log = patchesmod.PatchLog.active(gpa);
    defer log.deinit();
    var tx = try Transaction.openWithPatchLog(gpa, &source, &log, null);
    defer tx.deinit() catch @panic("testing allocator has no injected failure");
    const text = try tx.putObject(.root, .{ .key = "text" }, .text);
    try tx.spliceText(text, 0, 0, "owned pending text");
    const pending = tx.count();
    var target = try source.clonePending(gpa);
    defer target.deinit();
    var copy = try tx.cloneInto(gpa, &target);
    defer copy.deinit() catch @panic("testing allocator has no injected failure");
    try testing.expectEqual(pending, copy.count());
    try testing.expectEqual(pending, try copy.rollback());
    var discarded = copy.takePatchLog();
    defer discarded.deinit();
    try testing.expectEqual(@as(usize, 0), discarded.events.items.len);
    try testing.expect((try readmod.get(&target, .root, .{ .key = "text" })) == null);
    try testing.expectEqual(pending, tx.count());
    const visible = try tx.text(text, gpa);
    defer gpa.free(visible);
    try testing.expectEqualStrings("owned pending text", visible);
    var result = try tx.commit();
    defer result.deinit(gpa);
    try testing.expect(result.hash != null);
    try testing.expect(result.patch_log.events.items.len != 0);
    try testing.expectEqual(@as(usize, 1), source.graph.len());
    try testing.expectEqual(@as(usize, 0), target.graph.len());
}

test "pending map overwrite clone commits independently with the same hash" {
    // Commit the source first so its nonempty predecessor storage is released
    // before the cloned journal encodes the same overwrite.
    const gpa = testing.allocator;
    var source = try docWithActor(gpa, "clone-map-overwrite");
    defer source.deinit();
    {
        var initial = try Transaction.open(gpa, &source);
        defer initial.deinit() catch @panic("testing allocator has no injected failure");
        _ = try initial.put(.root, .{ .key = "k" }, .{ .int = 7 });
        var result = try initial.commit();
        defer result.deinit(gpa);
    }
    var tx = try Transaction.open(gpa, &source);
    defer tx.deinit() catch @panic("testing allocator has no injected failure");
    _ = try tx.put(.root, .{ .key = "k" }, .{ .int = 42 });
    var target = try source.clonePending(gpa);
    defer target.deinit();
    var copy = try tx.cloneInto(gpa, &target);
    defer copy.deinit() catch @panic("testing allocator has no injected failure");

    var source_result = try tx.commit();
    defer source_result.deinit(gpa);
    var clone_result = try copy.commit();
    defer clone_result.deinit(gpa);
    try testing.expect(source_result.hash != null);
    try testing.expect(clone_result.hash != null);
    try testing.expectEqualSlices(u8, &source_result.hash.?.bytes, &clone_result.hash.?.bytes);
    try testing.expectEqual(
        @as(i64, 42),
        (try readmod.get(&source, .root, .{ .key = "k" })).?.value.scalar.int,
    );
    try testing.expectEqual(
        @as(i64, 42),
        (try readmod.get(&target, .root, .{ .key = "k" })).?.value.scalar.int,
    );
}

test "pending transaction clone allocation refusal preserves the source owner" {
    // Sweep both raw pending-row duplication and owned journal duplication.
    const gpa = testing.allocator;
    var source = try docWithActor(gpa, "clone-refusal");
    defer source.deinit();
    var log = patchesmod.PatchLog.active(gpa);
    defer log.deinit();
    var tx = try Transaction.openWithPatchLog(gpa, &source, &log, null);
    defer tx.deinit() catch @panic("testing allocator has no injected failure");
    const text = try tx.putObject(.root, .{ .key = "text" }, .text);
    try tx.spliceText(text, 0, 0, "preserved");
    const pending = tx.count();
    var reached_success = false;
    var saw_raw_refusal = false;
    var saw_journal_refusal = false;
    for (0..4096) |offset| {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = offset });
        const clone_gpa = failing.allocator();
        var target = source.clonePending(clone_gpa) catch |clone_error| {
            try testing.expectEqual(error.OutOfMemory, clone_error);
            saw_raw_refusal = true;
            try testing.expectEqual(pending, tx.count());
            try testing.expectEqual(@as(usize, 0), source.graph.len());
            continue;
        };
        defer target.deinit();
        var copy = tx.cloneInto(clone_gpa, &target) catch |journal_error| {
            try testing.expectEqual(error.OutOfMemory, journal_error);
            saw_journal_refusal = true;
            failing.fail_index = std.math.maxInt(usize);
            try testing.expectEqual(pending, tx.count());
            const visible = try tx.text(text, gpa);
            defer gpa.free(visible);
            try testing.expectEqualStrings("preserved", visible);
            try testing.expectEqual(@as(usize, 0), source.graph.len());
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        try copy.deinit();
        reached_success = true;
        break;
    }
    try testing.expect(saw_raw_refusal);
    try testing.expect(saw_journal_refusal);
    try testing.expect(reached_success);
    try testing.expectEqual(pending, tx.count());
    var result = try tx.commit();
    defer result.deinit(gpa);
    try testing.expect(result.hash != null);
    try testing.expect(result.patch_log.events.items.len != 0);
}

test "logged transaction rollback preserves the consumed caller log prefix" {
    // A committed prefix remains owned after a later transaction is undone.
    const gpa = testing.allocator;
    var doc = try docWithActor(gpa, "log-prefix");
    defer doc.deinit();
    var log = patchesmod.PatchLog.active(gpa);
    defer log.deinit();
    {
        var first = try Transaction.openWithPatchLog(gpa, &doc, &log, null);
        defer first.deinit() catch @panic("testing allocator has no injected failure");
        _ = try first.put(.root, .{ .key = "prefix" }, .{ .str = "kept" });
        var result = try first.commit();
        defer result.deinit(gpa);
        log.deinit();
        log = result.patch_log.take();
    }
    const prefix_len = log.events.items.len;
    try testing.expect(prefix_len != 0);
    var next = try Transaction.openWithPatchLog(gpa, &doc, &log, null);
    defer next.deinit() catch @panic("testing allocator has no injected failure");
    _ = try next.put(.root, .{ .key = "discard" }, .{ .str = "removed" });
    try testing.expectEqual(@as(usize, 1), try next.rollback());
    var retained = next.takePatchLog();
    defer retained.deinit();
    try testing.expectEqual(prefix_len, retained.events.items.len);
    try testing.expectEqualStrings("prefix", retained.events.items[0].event.put_map.key);
    try testing.expectEqualStrings("kept", retained.events.items[0].event.put_map.value.scalar.str);
    try testing.expect((try readmod.get(&doc, .root, .{ .key = "discard" })) == null);
    try testing.expectEqualStrings("kept", (try readmod.get(&doc, .root, .{ .key = "prefix" })).?.value.scalar.str);
}

test "logged fork constructor allocation refusal retains document and caller log" {
    // Exercise every allocating preflight while reusing another document's
    // nonempty log; metadata rebinding and ownership transfer wait for success.
    var saw_refusal = false;
    var reached_success = false;
    for (0..512) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try docWithActor(gpa, "constructor-prefix");
        defer doc.deinit();
        var log = patchesmod.PatchLog.active(gpa);
        defer log.deinit();
        {
            var first = try Transaction.openWithPatchLog(gpa, &doc, &log, null);
            defer first.deinit() catch @panic("allocator is not injecting during cleanup");
            _ = try first.put(.root, .{ .key = "prefix" }, .{ .str = "kept" });
            var result = try first.commit();
            defer result.deinit(gpa);
            log.deinit();
            log = result.patch_log.take();
        }
        var fork = try doc.fork(gpa);
        defer fork.deinit();
        fork.setActorId(doc.getActorId());
        const before = try fork.saveWithOptions(testing.allocator, .{ .deflate = false, .retain_orphans = true });
        defer testing.allocator.free(before);
        const actor_before = fork.actor;
        const identity_before = fork.patchIdentity();
        const log_identity = log.identity;
        const events = log.events.items;
        const actors = log.actors.items;
        const prefix_len = log.events.items.len;
        failing.fail_index = failing.alloc_index + offset;
        var next = Transaction.openWithPatchLog(gpa, &fork, &log, null) catch |open_error| {
            failing.fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, open_error);
            saw_refusal = true;
            try testing.expectEqual(prefix_len, log.events.items.len);
            try testing.expectEqualStrings("prefix", log.events.items[0].event.put_map.key);
            try testing.expectEqualStrings("kept", log.events.items[0].event.put_map.value.scalar.str);
            try testing.expectEqual(@as(usize, 1), doc.graph.len());
            try testing.expectEqual(@as(usize, 1), fork.graph.len());
            try testing.expectEqual(@as(usize, 1), fork.numActors());
            try testing.expectEqualDeep(actor_before, fork.actor);
            try testing.expectEqual(identity_before, fork.patchIdentity());
            const after = try fork.saveWithOptions(testing.allocator, .{ .deflate = false, .retain_orphans = true });
            defer testing.allocator.free(after);
            try testing.expectEqualSlices(u8, before, after);
            try testing.expect(log.recording);
            try testing.expectEqual(log_identity, log.identity);
            try testing.expectEqual(events.ptr, log.events.items.ptr);
            try testing.expectEqual(actors.ptr, log.actors.items.ptr);
            try testing.expectEqualStrings("constructor-prefix", log.actors.items[0].bytes);
            try testing.expect(log.checkpoint == null);
            try testing.expect(log.speculative_actor == null);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        defer next.deinit() catch @panic("allocation restored before cleanup");
        try testing.expect(!log.recording);
        try testing.expectEqual(identity_before, next.patch_log.identity.?);
        try testing.expectEqual(@as(usize, 0), try next.rollback());
        var retained = next.takePatchLog();
        defer retained.deinit();
        try testing.expectEqual(prefix_len, retained.events.items.len);
        reached_success = true;
        break;
    }
    try testing.expect(saw_refusal);
    try testing.expect(reached_success);
}

test "logged historical construction accepts the projected concurrency actor on a fork" {
    // A fork lacks the scoped actor until preparation selects it. Opening must
    // migrate against that projected table, before publishing the new actor.
    const gpa = testing.allocator;
    var owner = try docWithActor(gpa, "scoped-compatible");
    defer owner.deinit();
    var first_head: ChangeHash = undefined;
    for ([_][]const u8{ "first", "second" }, 0..) |key, index| {
        var seed = try Transaction.open(gpa, &owner);
        defer seed.deinit() catch unreachable;
        _ = try seed.put(.root, .{ .key = key }, .{ .int = @intCast(index) });
        var result = try seed.commit();
        defer result.deinit(gpa);
        if (index == 0) first_head = result.hash.?;
    }
    var fork = try owner.fork(gpa);
    defer fork.deinit();
    fork.setActorId(owner.getActorId());
    var log = patchesmod.PatchLog.active(gpa);
    defer log.deinit();
    {
        var first = try Transaction.openWithPatchLog(gpa, &owner, &log, &.{first_head});
        defer first.deinit() catch unreachable;
        _ = try first.put(.root, .{ .key = "prefix" }, .{ .int = 7 });
        var result = try first.commit();
        defer result.deinit(gpa);
        log.deinit();
        log = result.patch_log.take();
    }
    try testing.expectEqual(@as(usize, 1), fork.numActors());
    try testing.expectEqual(@as(usize, 2), log.actors.items.len);
    const expected_actor = try types.ActorId.withConcurrency(gpa, fork.getActorId(), 1);
    defer gpa.free(expected_actor.bytes);
    var scoped = try Transaction.openWithPatchLog(gpa, &fork, &log, &.{first_head});
    defer scoped.deinit() catch unreachable;
    try testing.expect(!log.recording);
    try testing.expectEqualStrings(expected_actor.bytes, fork.getActor(scoped.actor).?.bytes);
    try testing.expectEqual(@as(usize, 2), fork.numActors());
    try testing.expectEqual(@as(usize, 1), scoped.patch_log.events.items.len);
    _ = try scoped.put(.root, .{ .key = "local" }, .{ .int = 8 });
    var result = try scoped.commit();
    defer result.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), result.patch_log.events.items.len);
    try testing.expectEqualStrings("prefix", result.patch_log.events.items[0].event.put_map.key);
    try testing.expectEqualStrings("local", result.patch_log.events.items[1].event.put_map.key);
    try testing.expectEqual(@as(i64, 7), result.patch_log.events.items[0].event.put_map.value.scalar.int);
    try testing.expectEqual(@as(i64, 8), result.patch_log.events.items[1].event.put_map.value.scalar.int);
}
