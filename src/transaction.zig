//! Manual transactions, owned commit logs, closure outcomes and in-place ownership.
//!
//! `Transaction` is the existing operation journal from `transact.zig`; this
//! module does not implement a second write engine. Commit results own their
//! patch log. Closure failures preserve the primary callback or commit error
//! separately from rollback failure and transfer the journal only when recovery
//! is required. `OwnedTransaction` must stay at its initialized address until
//! commit, rollback or disposal returns successfully.

const std = @import("std");

const err = @import("error.zig");
const types = @import("types.zig");
const valuemod = @import("value.zig");
const graphmod = @import("change_graph.zig");
const chunkmod = @import("storage/chunk.zig");
const docmod = @import("doc.zig");
const readmod = @import("read.zig");
const hydmod = @import("hydrate.zig");
const transact = @import("transact.zig");

const Allocator = std.mem.Allocator;
const ActorId = types.ActorId;
const ChangeHash = types.ChangeHash;
const Document = docmod.Document;
const Error = err.Error;
const ExId = types.ExId;
const NodeIdx = graphmod.NodeIdx;
const ObjType = types.ObjType;
const Prop = types.Prop;
const ScalarValue = valuemod.ScalarValue;

const testing = std.testing;

// ── The vocabulary `transaction.rs` owns ─────────────────────────────────────

/// The borrowed-document journal. Open it, write through it, then commit or
/// roll back. Fallible disposal rolls back an unfinished journal.
pub const Transaction = transact.Transaction;

/// Everything a write through this file can raise.
///
/// [`transact.WriteError`](transact.zig) under a name of its own, so a caller
/// of this module does not have to reach into the file that owns the bodies.
/// It is the wide set — the op set's own refusals, a load or commit refusal,
/// and the checks upstream treats as impossible — and
/// [`transact.asError`](transact.zig) is the one place the narrow [`Error`] is
/// produced from it.
pub const TransactionError = transact.WriteError;

/// Optional metadata for a commit
/// ([`CommitOptions`](../../github-automerge-automerge/rust/automerge/src/transaction/commit.rs):3-8).
///
/// **`message` is borrowed, not owned.** Upstream holds an `Option<String>`
/// and the change builder copies out of it
/// ([`inner.rs:184`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs));
/// here the caller's bytes go straight into the encoded change, so they must
/// outlive the call and no longer.
///
/// **This is a value and not two arguments** because upstream has two methods
/// ([`manual_transaction.rs:67`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs),
/// [`:91`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)),
/// [`commit.rs:1-34`](../../github-automerge-automerge/rust/automerge/src/transaction/commit.rs)),
/// and a caller with neither a message nor a time should not have to remember
/// which order two nulls go in.
pub const CommitOptions = struct {
    /// The commit message, or null for none.
    message: ?[]const u8 = null,
    /// The commit time in seconds since the epoch, or null for the
    /// transaction's own — which is **zero, not "now"**
    /// ([`inner.rs:68-91`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    time: ?i64 = null,

    /// Options with neither a message nor a time, which is what upstream's
    /// `CommitOptions::default` is
    /// ([`commit.rs:4`](../../github-automerge-automerge/rust/automerge/src/transaction/commit.rs)).
    pub const none: CommitOptions = .{};

    /// This with `message` set
    /// ([`:12-16`](../../github-automerge-automerge/rust/automerge/src/transaction/commit.rs)).
    pub fn withMessage(self: CommitOptions, message: []const u8) CommitOptions {
        var next = self;
        next.message = message;
        return next;
    }

    /// This with `time` set
    /// ([`:27-30`](../../github-automerge-automerge/rust/automerge/src/transaction/commit.rs)).
    pub fn withTime(self: CommitOptions, time: i64) CommitOptions {
        var next = self;
        next.time = time;
        return next;
    }

    /// Upstream's `set_message`
    /// ([`:18-24`](../../github-automerge-automerge/rust/automerge/src/transaction/commit.rs)),
    /// which takes `&mut self` because Rust's builder is a value it mutates.
    /// A Zig struct literal is the mutation, so these return nothing.
    pub fn setMessage(self: *CommitOptions, message: []const u8) void {
        self.message = message;
    }

    /// Upstream's `set_time`
    /// ([`:30-33`](../../github-automerge-automerge/rust/automerge/src/transaction/commit.rs)).
    pub fn setTime(self: *CommitOptions, time: i64) void {
        self.time = time;
    }
};

/// A terminal commit transfers its log even when no operations were written.
/// This is one owner: copying it does not clone the log.
pub const CommitResult = struct {
    hash: ?ChangeHash,
    patch_log: @import("patches.zig").PatchLog,

    /// Releases the owned log; `gpa` is retained for uniform result disposal.
    pub fn deinit(self: *CommitResult, gpa: Allocator) void {
        _ = gpa;
        self.patch_log.deinit();
        self.* = undefined;
    }
};

/// Owns the callback result and committed log, including a no-write success.
/// The caller disposes `result` according to O and `patch_log` exactly once.
pub fn Success(comptime O: type) type {
    return struct {
        result: O,
        hash: ?ChangeHash,
        patch_log: @import("patches.zig").PatchLog,
    };
}

/// Primary refusal and its recovery resources. On failed rollback, only
/// `transaction` owns the log; otherwise `patch_log` owns the returned log.
/// A successful callback result survives a subsequent commit refusal.
pub fn Failure(comptime O: type, comptime E: type) type {
    return struct {
        err: (E || TransactionError),
        cancelled: usize,
        rollback_error: ?TransactionError = null,
        transaction: ?Transaction = null,
        result: ?O = null,
        patch_log: @import("patches.zig").PatchLog,
    };
}

/// Callback success or refusal with independently owned recovery resources.
pub fn Outcome(comptime O: type, comptime E: type) type {
    return union(enum) {
        success: Success(O),
        failure: Failure(O, E),
    };
}

/// Owns a raw document and the same transaction journal used by borrowed
/// transactions. Initialize at the final address and do not copy or move while
/// open. All ReadDoc and Transactable operations are exposed by `transaction`.
pub const OwnedTransaction = struct {
    transaction: Transaction,
    document: Document,
    owns_document: bool,

    pub const Committed = struct { document: Document, result: CommitResult };
    pub const RolledBack = struct {
        document: Document,
        cancelled: usize,
        patch_log: @import("patches.zig").PatchLog,
    };

    /// Consumes `doc` only after open succeeds. Refusal leaves `doc` untouched
    /// and `self` uninitialized. `heads == null` selects the current scope.
    pub fn init(self: *OwnedTransaction, gpa: Allocator, doc: *Document, at: ?[]const ChangeHash) TransactionError!void {
        const tx = try Transaction.openAt(gpa, doc, at);
        self.adoptOpened(doc, tx);
    }

    /// Consumes both `doc` and `log` only after logged opening succeeds.
    /// Refusal preserves both source owners and leaves `self` uninitialized.
    /// `at == null` selects the current scope; initialize at the final address.
    pub fn initWithPatchLog(
        self: *OwnedTransaction,
        gpa: Allocator,
        doc: *Document,
        log: *@import("patches.zig").PatchLog,
        at: ?[]const ChangeHash,
    ) TransactionError!void {
        const tx = try Transaction.openWithPatchLog(gpa, doc, log, at);
        self.adoptOpened(doc, tx);
    }

    fn adoptOpened(self: *OwnedTransaction, doc: *Document, tx: Transaction) void {
        self.* = .{ .transaction = tx, .document = doc.*, .owns_document = true };
        self.transaction.doc = &self.document;
        doc.* = undefined;
    }

    /// Transfers the document and log on success; refusal retains this owner.
    pub fn commit(self: *OwnedTransaction, options: CommitOptions) TransactionError!Committed {
        if (!self.owns_document) return error.InvalidOp;
        const result = try self.transaction.commitWith(options);
        self.transaction.deinitClosed();
        self.owns_document = false;
        return .{ .document = self.document, .result = result };
    }

    /// Transfers the restored document and log. Failed rollback retains this
    /// owner, including partial progress, for retry.
    pub fn rollback(self: *OwnedTransaction) TransactionError!RolledBack {
        if (!self.owns_document) return error.InvalidOp;
        const cancelled = try self.transaction.rollback();
        const log = self.transaction.takePatchLog();
        self.transaction.deinitClosed();
        self.owns_document = false;
        return .{ .document = self.document, .cancelled = cancelled, .patch_log = log };
    }

    /// Rolls back before destroying the document. Refusal retains all ownership.
    pub fn deinit(self: *OwnedTransaction) TransactionError!void {
        if (!self.owns_document) return;
        try self.transaction.deinit();
        self.document.deinit();
        self.owns_document = false;
    }

    /// Destroys the entire owned raw document, so no unfinished journal survives.
    /// After a terminal transfer this is a no-op.
    pub fn deinitClosed(self: *OwnedTransaction) void {
        if (!self.owns_document) return;
        self.transaction.deinitClosed();
        self.document.deinit();
        self.owns_document = false;
    }
};

// ── The accessors ────────────────────────────────────────────────────────────

/// The actor this transaction's operations belong to, **as bytes**.
///
/// Upstream's `TransactionInner.actor`
/// ([`inner.rs:24`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
/// is the *index* into `OpSet::actors` and upstream has no accessor for the
/// id; [`Change::actor_id`](../../github-automerge-automerge/rust/automerge/src/change.rs):52
/// is the same question asked of a change. The index is still readable as
/// [`Transaction.actor`](transact.zig) — it has to be, because
/// [`changeMeta`] needs it — and what a caller wants is the id.
///
/// **Null for an index the document's table does not hold.** That cannot
/// happen while the transaction is open, and can after a
/// [`rollback`](transact.zig) removed the actor it had created
/// ([`inner.rs:220-222`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
pub fn actorId(tx: *const Transaction) ?ActorId {
    return tx.doc.getActor(tx.actor);
}

/// The counter of the last operation **this transaction has queued**, which is
/// the `max_op` of the change it is about to write: upstream's
/// [`change_meta`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):182
/// spelled `start_op + pending.len() - 1`.
///
/// # It answers about the transaction, not about the document
///
/// **Three numbers in the reference are called `max_op` and they are three
/// different questions.** They are kept apart here on purpose, because the
/// whole of the confusion this function is prone to comes from reading one for
/// another:
///
/// | question | upstream | this port |
/// |---|---|---|
/// | what will this transaction's change claim as its last counter | [`inner.rs:182`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs) | this function |
/// | what did that change claim | [`change.rs:74-76`](../../github-automerge-automerge/rust/automerge/src/change.rs) | `change.max_op` |
/// | what does the whole document claim | [`change_graph.rs:204-206`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs) | [`ChangeGraph.maxOp`](change_graph.zig) |
///
/// The first is the only one a caller can ask **before the change exists**,
/// and it is the only one that moves while a transaction is open: the second
/// and the third only ever change at a commit. An empty document has a third
/// of `0`, which is a different number from this function's `start_op - 1` on
/// a document that has operations, and the two agree only on a document that
/// has none.
///
/// **`start_op - 1` when nothing has been written**, which is upstream's own
/// value for a change with no operations — [`inner.rs:182`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)
/// over an empty `pending` — and the one the encoder accepts
/// ([`change.rs:74-76`](../../github-automerge-automerge/rust/automerge/src/change.rs),
/// [`doc.zig:3438`](doc.zig)).
///
/// # `error.InvalidOp` once the transaction is closed
///
/// **This is the port's own decision, and it is made here rather than matched
/// because upstream has no such question to be right about.**
///
/// Upstream's `Transaction` exposes **no `max_op` at all**. Its public surface
/// is `hash_for_opid`
/// ([`manual_transaction.rs:44-46`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)),
/// `get_heads` (`:61-63`), `commit` (`:67`), `commit_with` (`:91`) and
/// `rollback` (`:100`), plus
/// [`Transactable::pending_ops`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):11-12
/// — and that is a **count**, not a counter. `change_meta` is `pub(crate)`
/// ([`inner.rs:174`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
/// so this function is a port-visible rendering of a private field, and
/// nothing above it constrains the signature.
///
/// **The post-commit read is not expressible upstream, so the reference
/// cannot answer it.** `commit` and `commit_with` take `self` **by value**
/// ([`manual_transaction.rs:67`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs),
/// `:91`) and each moves the inner out with `self.inner.take().unwrap()`
/// (`:68`, `:92`); `TransactionInner::commit` and `::rollback` take `self` by
/// value as well
/// ([`inner.rs:129-130`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
/// `:211-212`). A spent transaction does not exist, so no upstream program
/// can hold one and ask it for a counter.
///
/// Here the transaction outlives the call and [`commit`](transact.zig) drains
/// its pending list ([`transact.zig:1344-1346`](transact.zig)), which is what
/// turns a spent transaction's arithmetic into the empty-state sentinel: on a
/// document whose last change claimed `16`, a read after the commit answers
/// `0`. **That is a number shaped like a counter and not one**, so a closed
/// transaction **refuses instead of answering** — with the same
/// `error.InvalidOp` [`requireOpen`](transact.zig) gives a write to a spent
/// transaction and the same one [`rollback`](transact.zig) gives a second
/// application, because a spent transaction is a programming state and not a
/// missing value. A silent `0` is worse than a refusal: it compares unequal
/// against every real counter and equal against nothing.
///
/// **`closed` is the flag the refusal keys on, and not `pending.len()`**, for a
/// second reason that is worse than the drain: [`rollback`](transact.zig)
/// undoes its operations and **leaves them in the list**
/// ([`transact.zig:1356-1368`](transact.zig)) — `deinit` is what frees them —
/// so after a rollback the arithmetic still claims `start_op + n - 1` for `n`
/// counters the document has withdrawn and will never hand out again. An
/// empty pending list cannot tell that state from a live one, and
/// `closed` is true in all three spent states and false in every live one.
///
/// **A caller who wants the other two rows reads them.** After a commit the
/// hash `Transaction.commitWith` returned names the change, and `change.max_op` is its
/// answer; [`ChangeGraph.maxOp`](change_graph.zig) is the document's.
///
/// **Not everything on this door refuses when it is closed, and
/// [`Transaction.count`](transact.zig) is the contrast rather than an
/// inconsistency.** `count` answers `pending.len`, and `0` pending operations
/// is a true answer after a commit and after a rollback both — a count cannot
/// be mistaken for a counter, because there is no counter it could be. The two
/// are linked by `maxOp == start_op + count - 1` while the transaction is open,
/// and the refusal above is what keeps that identity from being read as
/// arithmetic on a spent transaction, where the right-hand side collapses onto
/// the sentinel.
pub fn maxOp(tx: *const Transaction) TransactionError!u64 {
    if (tx.closed) return error.InvalidOp;
    const n = tx.pending.items.len;
    if (n == 0) return tx.start_op -| 1;
    return tx.start_op + n - 1;
}

/// The document's heads right now, **caller-owned** and freeable with `gpa`
/// ([`Transaction::get_heads`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs):61-63).
///
/// **This is not [`baseHeads`](transact.zig), and the two differ.** Upstream's
/// own doc comment calls this "the heads of the document before this
/// transaction was started", but its body is `self.doc.get_heads()` — the
/// *current* heads — and it is the pre-transaction heads only because nothing
/// can commit while a transaction is open.
/// [`get_deps`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1386-1388,
/// which is what [`baseHeads`](transact.zig) returns, is the question that
/// comment was asking. For an **isolated** transaction the two are different
/// sets: the dependencies are the isolation heads, and this is the document's.
pub fn heads(gpa: Allocator, tx: *const Transaction) Error![]ChangeHash {
    return tx.doc.getHeads(gpa);
}

/// The hash of the change that carries the operation `id`
/// ([`Transaction::hash_for_opid`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs):44-46,
/// over [`Automerge::hash_for_opid`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1554-1567).
///
/// Null for the root, an unknown id, or an operation written but not committed.
/// Delegates to the document's indexed historical lookup. Compact actor indices
/// are document-local; named ids repair cached slots through their actor bytes.
pub fn hashForOpid(tx: *const Transaction, id: ExId) ?ChangeHash {
    return tx.doc.hashForOpid(id);
}

/// This transaction's dependencies as **node indices**, **caller-owned** and
/// freeable with `gpa`
/// ([`export`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):197-207,
/// `deps.iter().filter_map(|hash| change_graph.hash_to_index(hash))`).
///
/// **A dependency the graph does not hold is dropped, with no error.** That is
/// upstream's `filter_map`. A dependency that disappears from a header is a
/// change whose hash no longer matches what its producer computed. The port
/// reproduces it because the header is a compatibility boundary and a change
/// naming a dependency its reader does not have would be worse.
///
/// **The sort is upstream's and it is not here:** upstream sorts inside
/// `export` ([`inner.rs:198`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs));
/// this port sorts once, at the source, in
/// [`Document.transactionArgs`](doc.zig) ([`:2574`](doc.zig)).
pub fn depIndices(gpa: Allocator, tx: *const Transaction) TransactionError![]NodeIdx {
    const graph = &tx.doc.graph;
    const out = try gpa.alloc(NodeIdx, tx.deps.len);
    errdefer gpa.free(out);
    var n: usize = 0;
    for (tx.deps) |hash| {
        if (graph.hashToIndex(hash)) |idx| {
            out[n] = idx;
            n += 1;
        }
    }
    if (n == out.len) return out;
    const shrunk = gpa.realloc(out, n) catch {
        gpa.free(out);
        return error.OutOfMemory;
    };
    return shrunk;
}

/// The change header this transaction would commit, as upstream's
/// [`change_meta`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):174-189
/// spells it and this port's [`BuildMeta`](doc.zig) holds.
///
/// **`deps` is the caller's** — pass [`depIndices`] — because upstream's
/// `change_meta` takes already-resolved indices as a `Vec<u64>` and
/// `export` is what resolves them
/// ([`inner.rs:198-204`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
///
/// **Allocates nothing.** `message` borrows the transaction's own borrowed
/// message; `footer` is empty, because upstream folds that in through
/// `extra_bytes` ([`inner.rs:193-195`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
/// reading a field the engine does not retain — see [`authorFooter`].
///
/// **`error.InvalidOp` once the transaction is closed**, because [`maxOp`] is
/// and because the whole of this is a question about a change that does not
/// exist yet: a spent transaction's `start_op`, `seq` and `deps` are the ones
/// it was opened with and no longer describe anything, so this is the same
/// refusal [`maxOp`] makes rather than a second way round it.
pub fn changeMeta(
    tx: *const Transaction,
    deps: []const NodeIdx,
) TransactionError!docmod.BuildMeta {
    return .{
        .actor = tx.actor,
        .seq = tx.seq,
        .start_op = tx.start_op,
        .max_op = try maxOp(tx),
        .time = tx.time,
        .message = tx.message orelse "",
        .deps = deps,
        .footer = &.{},
    };
}

/// The author footer this transaction's change will carry, **caller-owned** and
/// freeable with `gpa`
/// ([`extra_bytes`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):193-195).
///
/// **Nothing unless this is the actor's first change.** Upstream's
/// `transaction_args` sets the author only when `seq == 1`
/// ([`automerge.rs:568`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// because one actor has one author, and [`Document.commit`](doc.zig)
/// re-derives it from the same rule ([`:2438`](doc.zig),
/// [`:3430-3432`](doc.zig)). An isolated transaction opens a **concurrency**
/// actor, so it is always a first change and always carries the author
/// ([`automerge.rs:1259-1281`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
pub fn authorFooter(gpa: Allocator, tx: *const Transaction) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try docmod.encodeAuthorFooter(
        gpa,
        &out,
        if (tx.seq == 1) tx.doc.author else null,
    );
    return out.toOwnedSlice(gpa);
}

// ── Finishing ────────────────────────────────────────────────────────────────

/// Idempotent explicit rollback; refusal retains the journal for retry.
pub fn abort(tx: *Transaction) TransactionError!void {
    if (tx.closed) return;
    _ = try tx.rollback();
}

fn BodyError(comptime B: type) type {
    const F = switch (@typeInfo(B)) {
        .pointer => |p| p.child,
        .@"fn" => B,
        else => @compileError("body must be fn(ctx, *Transaction) E!O"),
    };
    const R = @typeInfo(F).@"fn".return_type.?;
    return @typeInfo(R).error_union.error_set;
}

/// Runs `body(ctx, tx)` synchronously without reentrancy. The callback pointer
/// and context are borrowed for the call, and any callback error is preserved.
/// Opening errors return directly without invoking the callback.
pub fn enclose(comptime O: type, gpa: Allocator, doc: *Document, ctx: anytype, body: anytype) TransactionError!Outcome(O, BodyError(@TypeOf(body))) {
    return encloseWith(O, gpa, doc, ctx, body, null);
}

/// Derives options from a borrowed result on the calling thread; null selects
/// no metadata. Neither callback may retain the transaction/result pointer or
/// reenter the document. Message bytes must stay live until commit returns.
pub fn encloseWith(
    comptime O: type,
    gpa: Allocator,
    doc: *Document,
    ctx: anytype,
    body: anytype,
    options: ?*const fn (@TypeOf(ctx), *const O) CommitOptions,
) TransactionError!Outcome(O, BodyError(@TypeOf(body))) {
    var tx = try Transaction.open(gpa, doc);
    return closeOpened(O, &tx, ctx, body, options);
}

/// Logged closure form; `log` transfers only after opening succeeds.
/// Callback lifetime, error and recovery rules are identical to `encloseWith`.
pub fn encloseWithPatchLog(
    comptime O: type,
    gpa: Allocator,
    doc: *Document,
    log: *@import("patches.zig").PatchLog,
    ctx: anytype,
    body: anytype,
    options: ?*const fn (@TypeOf(ctx), *const O) CommitOptions,
) TransactionError!Outcome(O, BodyError(@TypeOf(body))) {
    var tx = try Transaction.openWithPatchLog(gpa, doc, log, null);
    return closeOpened(O, &tx, ctx, body, options);
}

fn closeOpened(
    comptime O: type,
    tx: *Transaction,
    ctx: anytype,
    body: anytype,
    options: ?*const fn (@TypeOf(ctx), *const O) CommitOptions,
) Outcome(O, BodyError(@TypeOf(body))) {
    const result: O = body(ctx, tx) catch |primary| {
        return rollbackFailure(O, BodyError(@TypeOf(body)), tx, primary, null);
    };
    const opts = if (options) |derive| derive(ctx, &result) else CommitOptions.none;
    const committed = tx.commitWith(opts) catch |primary| {
        return rollbackFailure(O, BodyError(@TypeOf(body)), tx, primary, result);
    };
    tx.deinitClosed();
    return .{ .success = .{
        .result = result,
        .hash = committed.hash,
        .patch_log = committed.patch_log,
    } };
}

fn rollbackFailure(comptime O: type, comptime E: type, tx: *Transaction, primary: (E || TransactionError), result: ?O) Outcome(O, E) {
    const cancelled = tx.rollback() catch |secondary| {
        return .{ .failure = .{
            .err = primary,
            .cancelled = tx.cancelled,
            .rollback_error = secondary,
            .transaction = tx.*,
            .result = result,
            .patch_log = @import("patches.zig").PatchLog.inactive(tx.gpa),
        } };
    };
    const log = tx.takePatchLog();
    tx.deinitClosed();
    return .{ .failure = .{
        .err = primary,
        .cancelled = cancelled,
        .result = result,
        .patch_log = log,
    } };
}

// ── tests ────────────────────────────────────────────────────────────────────

/// A raw document with a deterministic actor for transaction tests.
fn manual(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, std.testing.io);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = "0123456789abcdef" });
    return doc;
}

/// One committed change, for a test that needs history before it opens its own
/// transaction.
fn commitPut(
    gpa: Allocator,
    doc: *Document,
    key: []const u8,
    value: ScalarValue,
) !ChangeHash {
    var tx = try Transaction.open(gpa, doc);
    // Helpers require their caller to destroy the raw document on error.
    defer tx.deinitClosed();
    _ = try tx.put(.root, .{ .key = key }, value);
    var committed = try tx.commitWith(CommitOptions.none);
    defer committed.deinit(gpa);
    return committed.hash.?;
}

/// Every one of this transaction's queued operations, read back out of the
/// document's op set, field for field.
///
/// **This is the check `inner.rs:308-328` exists so that it can be made.** A
/// transaction writes its rows as it goes, so a commit that re-spliced them
/// would leave two rows for one operation and one that failed to write them
/// would leave a null. Comparing the fields and not the count is deliberate: a
/// count cannot tell "the same row twice" from "one row".
///
/// **The operations are found by id, not by the position they were spliced
/// at**, for two reasons that are both upstream's. A position is only good
/// until the next splice, and a transaction that writes into a list splices
/// ahead of rows it has already placed. And a **delete is not a row at all**:
/// [`OpSet.splice`](opset/op_set.zig) filters it out
/// (`columns.rs:423` upstream) and stores it on the row it removes, as a
/// successor.
fn expectPendingOpsAreDocumentRows(tx: *const Transaction) !void {
    try testing.expect(tx.pending.items.len > 0);
    for (tx.pending.items) |item| {
        const id = item.tx.id();
        for (item.tx.pred()) |p| {
            // **The predecessor relation is read from where it is stored**,
            // which is the successor list of the row this operation replaced:
            // a stored row has no predecessors of its own
            // ([`op.rs:1319-1321`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)).
            const at = (try tx.doc.ops.getOpIdPos(p)) orelse return error.RowMissing;
            const prev = (try tx.doc.ops.get(at)) orelse return error.RowMissing;
            var named = false;
            for (0..prev.succCount()) |i| {
                if (prev.succAt(i).eql(id)) named = true;
            }
            try testing.expect(named);
        }
        if (item.tx.isDelete()) continue; // found on the row it removes
        const at = (try tx.doc.ops.getOpIdPos(id)) orelse return error.RowMissing;
        const row = (try tx.doc.ops.get(at)) orelse return error.RowMissing;
        try testing.expect(row.id().eql(id));
        try testing.expect(row.objId().eql(item.tx.objId()));
        try testing.expectEqual(item.tx.action(), row.action());
        try testing.expect(item.tx.key().eql(row.key()));
        try testing.expect(item.tx.value().eql(row.value()));
        try testing.expectEqual(item.tx.insert(), row.insert());
        try testing.expectEqual(item.tx.expand(), row.expand());
        try testing.expect(sliceEql(item.tx.markName(), row.markName()));
    }
}

/// How many of this transaction's operations are deletes, and so are not rows.
fn countDeletes(tx: *const Transaction) usize {
    var n: usize = 0;
    for (tx.pending.items) |item| {
        if (item.tx.isDelete()) n += 1;
    }
    return n;
}

fn sliceEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

test "the commit path on a manual document: the change's bytes hash to the hash commit returned, and the transaction's operations are the document's" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    const rows_at_open = doc.ops.len();

    _ = try tx.put(.root, .{ .key = "name" }, .{ .str = "ada" });
    _ = try tx.put(.root, .{ .key = "hits" }, .{ .counter = .init(0) });
    try tx.increment(.root, .{ .key = "hits" }, 3);
    const list = try tx.putObject(.root, .{ .key = "l" }, .list);
    _ = try tx.insert(list, 0, .{ .int = 1 });
    const inner = try tx.insertObject(list, 1, .map);
    _ = try tx.put(inner, .{ .key = "deep" }, .{ .bool_value = true });
    const text = try tx.putObject(.root, .{ .key = "t" }, .text);
    try tx.spliceText(text, 0, 0, "hello");
    try tx.mark(text, 1, 3, "em", .both, .{ .bool_value = true });
    const gone = try tx.delete(.root, .{ .key = "name" });

    // Sixteen operations: four makes, two puts, one insert, one increment,
    // five characters, a mark's two anchors and one delete.
    try testing.expectEqual(@as(usize, 16), tx.pending.items.len);
    try testing.expectEqual(@as(usize, 1), gone);

    // **Before the commit**: every queued operation is already in the
    // document's op set, and the row count grew by exactly the operations
    // that are rows — a delete is stored on the row it removes
    // ([`OpSet.splice`](opset/op_set.zig), `columns.rs:423` upstream).
    try expectPendingOpsAreDocumentRows(&tx);
    const deletes = countDeletes(&tx);
    try testing.expectEqual(@as(usize, 1), deletes);
    // **Sixteen operations, one of them a delete, and fifteen rows** — so the
    // transaction wrote each of its operations once and no operation twice.
    try testing.expectEqual(@as(usize, 0), rows_at_open);
    try testing.expectEqual(tx.pending.items.len - deletes, doc.ops.len());
    const rows_before = doc.ops.len();

    // **The counter is read before the commit, and the placement is the
    // point.** `commitWith` drains `pending`
    // ([`transact.zig:1344-1346`](transact.zig)), so the same call afterwards
    // is a read of a spent transaction and refuses
    // ([`maxOp`](transaction.zig)). Sixteen operations and `start_op == 1`
    // make the two answers `16` and `0`, and only the first of them is a
    // counter.
    const max_op = try maxOp(&tx);
    try testing.expectEqual(@as(u64, 16), max_op);

    var committed_result = try tx.commitWith(CommitOptions.none.withMessage("m").withTime(7));
    defer committed_result.deinit(gpa);
    const hash = committed_result.hash.?;
    try testing.expectEqual(@as(usize, 0), tx.pending.items.len);

    // **The commit linked a change and spliced nothing.** A re-introduced
    // duplicate splice would have doubled the rows; a commit that forgot to
    // write them would leave the document holding a hash for a change whose
    // rows it does not have, and every reader that rebuilds a change from the
    // op set would answer with bytes that hash to something else.
    try testing.expectEqual(rows_before, doc.ops.len());
    try testing.expectEqual(@as(usize, 1), doc.graph.len());

    // **The bytes are checked, not the count.** The hash is SHA-256 over the
    // change chunk body ([`chunk.rs:300-312`](../../github-automerge-automerge/rust/automerge/src/storage/chunk.rs)),
    // so re-hashing the body the document hands back says the bytes and the
    // returned hash are the same thing.
    var built = (try doc.getChangeByHash(gpa, hash)).?;
    defer built.deinit(gpa);
    try testing.expect(chunkmod.changeHashOf(.change, built.body).eql(hash));
    try testing.expectEqualStrings("m", built.change.message);
    try testing.expectEqual(@as(i64, 7), built.change.time);
    try testing.expectEqual(tx.start_op, built.change.start_op);
    try testing.expectEqual(max_op, built.change.max_op);
    try testing.expectEqual(tx.seq, built.change.seq);
    // **The change carries op data, and the document still holds exactly the
    // rows those operations name.**
    try testing.expect(built.change.opsBytes().len > 0);

    // And the document reads back as what the transaction wrote, which is the
    // half a byte check cannot see.
    if (try readmod.get(&doc, .root, .{ .key = "name" })) |_| {
        return error.ExpectedAbsent;
    }
    const hits = try readmod.get(&doc, .root, .{ .key = "hits" });
    try testing.expectEqual(@as(i64, 3), hits.?.value.scalar.counter.current);
    try testing.expectEqual(@as(usize, 2), doc.ops.seqLength(list, doc.textEncoding(), null));
    try testing.expectEqual(ObjType.map, try doc.objectType(inner));
    const got = try doc.text(gpa, text);
    defer gpa.free(got);
    try testing.expectEqualStrings("hello", got);
    const marks = try doc.marks(gpa, text);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqualStrings("em", marks[0].name);
    try testing.expectEqual(@as(usize, 1), marks[0].start);
    try testing.expectEqual(@as(usize, 3), marks[0].end);
}

test "the committed change survives a save and a load with the same bytes" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    _ = try tx.put(.root, .{ .key = "k" }, .{ .str = "v" });
    const list = try tx.putObject(.root, .{ .key = "l" }, .list);
    _ = try tx.insert(list, 0, .{ .int = 7 });
    const text = try tx.putObject(.root, .{ .key = "t" }, .text);
    try tx.spliceText(text, 0, 0, "hi");
    var committed_result = try tx.commitWith(CommitOptions.none.withMessage("m"));
    defer committed_result.deinit(gpa);
    const hash = committed_result.hash.?;

    var before = (try doc.getChangeByHash(gpa, hash)).?;
    defer before.deinit(gpa);

    // **The document's own bytes carry the change, and a load rebuilds it
    // byte for byte.** A change whose bytes the document cannot reproduce is a
    // change whose hash a peer cannot check, so the round trip is the strongest
    // thing a commit can be held to that does not need the reference.
    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, std.testing.io, saved, doc.textEncoding());
    defer reloaded.deinit();

    try reloaded.ops.debugCmp(&doc.ops);
    try testing.expectEqual(doc.graph.len(), reloaded.graph.len());
    const reloaded_heads = try reloaded.getHeads(gpa);
    defer gpa.free(reloaded_heads);
    try testing.expectEqual(@as(usize, 1), reloaded_heads.len);

    var after = (try reloaded.getChangeByHash(gpa, hash)).?;
    defer after.deinit(gpa);
    try testing.expectEqualSlices(u8, before.body, after.body);
    try testing.expect(after.change.hash.eql(hash));
    try testing.expect(chunkmod.changeHashOf(.change, after.body).eql(hash));
}

test "a rollback on a manual document is checked against OpSet.debugCmp, not against a count" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    // A list, a text object, a mark and a counter, so the rollback has
    // registers, sequence rows, a mark index and a winner index to put back.
    const list = try commitFixture(gpa, &doc);
    var text_row = try doc.ops.seekOpsByMapKey(gpa, .root, "t", null);
    defer text_row.deinit(gpa);
    const text = doc.ops.idToExid(text_row.ops.items[0].id());
    var before = try doc.clone(gpa);
    defer before.deinit();
    const before_rows = before.ops.len();
    const before_nodes = before.graph.len();
    const before_heads = before.graph.getHeads();

    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    _ = try tx.put(.root, .{ .key = "gone" }, .{ .int = 1 });
    try tx.increment(.root, .{ .key = "hits" }, 1);
    _ = try tx.insert(list, 0, .{ .int = 99 });
    try tx.spliceText(text, 0, 0, "Z");
    try tx.mark(text, 0, 1, "bold", .after, .{ .bool_value = true });
    const made = try tx.putObject(.root, .{ .key = "m2" }, .map);
    _ = try tx.put(made, .{ .key = "inner" }, .{ .str = "x" });
    _ = try tx.delete(list, .{ .index = 0 });
    // Nine operations: a put, an increment, an insert, one spliced character,
    // a mark's two anchors, a make, a put and a delete.
    try testing.expectEqual(@as(usize, 9), tx.pending.items.len);

    // **The rollback, and the number it reports.** That number is upstream's
    // `self.pending.len()`
    // ([`inner.rs:212`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
    // and it is the same number as the count, so on its own it proves nothing.
    try testing.expectEqual(@as(usize, 9), try tx.rollback());

    // **`OpSet.debugCmp` and not the heads or the row count**: the comparison
    // is over values, so a slab that was repartitioned on the way out does not
    // read as a different document, and a row that was left behind cannot hide.
    try doc.ops.debugCmp(&before.ops);
    try testing.expectEqual(before_rows, doc.ops.len());
    try testing.expectEqual(before_nodes, doc.graph.len());
    try testing.expectEqual(before_heads.len, doc.graph.getHeads().len);
    for (before_heads, doc.graph.getHeads()) |want, have| try testing.expect(want.eql(have));

    // **The mark is still there, because a mark's rows and its index are two
    // things and a rollback has to put both back.** Read through the document
    // rather than through a row comparison.
    const still = try doc.marks(gpa, text);
    defer gpa.free(still);
    try testing.expectEqual(@as(usize, 1), still.len);
    try testing.expectEqualStrings("em", still[0].name);
    const text_again = try doc.text(gpa, text);
    defer gpa.free(text_again);
    try testing.expectEqualStrings("hello", text_again);
    try testing.expectEqual(@as(usize, 2), doc.ops.seqLength(list, doc.textEncoding(), null));
    const hits = try readmod.get(&doc, .root, .{ .key = "hits" });
    try testing.expectEqual(@as(i64, 5), hits.?.value.scalar.counter.current);
}

/// Commits a list, a text object with a mark, and a counter, and returns the
/// list. The objects the test needs after this are read out of the document.
fn commitFixture(gpa: Allocator, doc: *Document) !ExId {
    var tx = try Transaction.open(gpa, doc);
    // Helpers require their caller to destroy the raw document on error.
    defer tx.deinitClosed();
    const list = try tx.putObject(.root, .{ .key = "l" }, .list);
    _ = try tx.insert(list, 0, .{ .int = 1 });
    _ = try tx.insert(list, 1, .{ .int = 2 });
    const text = try tx.putObject(.root, .{ .key = "t" }, .text);
    try tx.spliceText(text, 0, 0, "hello");
    try tx.mark(text, 1, 3, "em", .both, .{ .bool_value = true });
    _ = try tx.put(.root, .{ .key = "hits" }, .{ .counter = .init(5) });
    var committed_result = try tx.commitWith(CommitOptions.none);
    defer committed_result.deinit(gpa);
    return list;
}

test "an isolated transaction commits with its own dependencies and its own actor" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    const first = try commitPut(gpa, &doc, "a", .{ .int = 1 });
    _ = try commitPut(gpa, &doc, "b", .{ .int = 2 });

    var tx = try Transaction.openAt(gpa, &doc, &.{first});
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;

    // **The heads moved on from the first change, so the two sets are different
    // sets.** That is the whole point of the case: an isolated transaction's
    // dependencies are the heads it was isolated at, and the document's heads
    // are the present ones. Upstream's `get_heads`
    // ([`manual_transaction.rs:61-63`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs))
    // and its `get_deps`
    // ([`inner.rs:1386-1388`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
    // are different questions, and this is where the answers differ.
    const now = try heads(gpa, &tx);
    defer gpa.free(now);
    try testing.expectEqual(@as(usize, 1), now.len);
    try testing.expect(!now[0].eql(first));
    try testing.expectEqual(@as(usize, 1), tx.baseHeads().len);
    try testing.expect(tx.baseHeads()[0].eql(first));

    _ = try tx.put(.root, .{ .key = "iso" }, .{ .int = 3 });

    // **A concurrency actor, and a first change**, because the clock at the
    // first change does not cover this actor's second operation
    // ([`automerge.rs:1259-1281`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    const author = actorId(&tx) orelse return error.MissingActor;
    try testing.expect(!std.mem.eql(u8, author.bytes, "0123456789abcdef"));
    try testing.expectEqual(@as(u64, 1), tx.seq);
    // **A concurrency actor's first change carries the author**, because
    // `automerge.rs:568` sets the author when `seq == 1` and this transaction
    // is one. Nothing is asserted about the bytes here: this document has no
    // author set, and the footer claim is the `changeMeta` test's.
    const footer = try authorFooter(gpa, &tx);
    defer gpa.free(footer);
    try testing.expectEqual(@as(usize, 0), footer.len);

    var committed_result = try tx.commitWith(CommitOptions.none);
    defer committed_result.deinit(gpa);
    const hash = committed_result.hash.?;
    try testing.expect(!hash.eql(first));

    // **The change names the isolation heads, not the document's**, and is
    // authored by the concurrency actor. That is the contract
    // [`inner.rs:197-207`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)
    // states: `export` resolves the transaction's own `deps`.
    var built = (try doc.getChangeByHash(gpa, hash)).?;
    defer built.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), built.change.deps.len);
    try testing.expect(built.change.deps[0].eql(first));
    try testing.expect(built.change.actor.eql(author));

    // And the write is in the document.
    const iso = try readmod.get(&doc, .root, .{ .key = "iso" });
    try testing.expectEqual(@as(i64, 3), iso.?.value.scalar.int);
}

test "a scoped transaction committed through the engine alone produces a change the document can read, and commitWith produces one it can" {
    const gpa = testing.allocator;

    // **The engine's `commit` is handed this transaction's own `actor`, `seq`
    // and `start_op`**, which is upstream's `TransactionInner::commit_impl`
    // reading them out of itself in `change_meta`
    // ([`inner.rs`:146-189](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    // and `AutoCommit` builds the isolation once at
    // `ensure_transaction_open`
    // ([`autocommit.rs`:445-457](../../github-automerge-automerge/rust/automerge/src/autocommit.rs))
    // rather than at commit. So a scoped transaction committed through the
    // engine alone produces a change whose header and rows name the same
    // actor, and the document reads it back.
    //
    // **This block asserted the opposite and was pinning a defect.**
    // [`Document.commit`](doc.zig) re-derived the metadata from
    // `self.isolation`, which is null for a transaction opened with
    // [`Transaction.openAt`](transact.zig), so the change named the
    // document's own actor while its rows named the concurrency fork's —
    // and the collector, which is the only thing that compares the two,
    // refused it with `error.Fail`. The fix is in
    // [`Transaction.commit`](transact.zig): the arguments are handed over
    // rather than re-derived. **The property pinned here is now the
    // agreement**, and it is the one that was missing: a committed change is
    // readable, and it carries the transaction's own actor and the isolation
    // heads as its dependencies.
    {
        var doc = try manual(gpa);
        defer doc.deinit();
        const first = try commitPut(gpa, &doc, "a", .{ .int = 1 });
        _ = try commitPut(gpa, &doc, "b", .{ .int = 2 });

        var tx = try Transaction.openAt(gpa, &doc, &.{first});
        // The testing allocator does not inject allocation failure during cleanup.
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "iso" }, .{ .int = 3 });

        var committed_result = try tx.commit();
        defer committed_result.deinit(gpa);
        const claimed = committed_result.hash.?;
        // **Readable, and it names the transaction's own actor and the
        // isolation heads as its dependencies** — the two facts that used to
        // disagree with the rows the change carried.
        try testing.expect(doc.hasChange(claimed));
        const author = actorId(&tx) orelse return error.MissingActor;
        var built = (try doc.getChangeByHash(gpa, claimed)).?;
        defer built.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), built.change.deps.len);
        try testing.expect(built.change.deps[0].eql(first));
        try testing.expect(built.change.actor.eql(author));
    }

    // Explicit commit options preserve the document's existing isolation and
    // encode the journal's original actor and dependency heads.

    {
        var doc = try manual(gpa);
        defer doc.deinit();
        const first = try commitPut(gpa, &doc, "a", .{ .int = 1 });
        _ = try commitPut(gpa, &doc, "b", .{ .int = 2 });
        try doc.isolate(gpa, &.{first});

        var tx = try Transaction.openAt(gpa, &doc, &.{first});
        // The testing allocator does not inject allocation failure during cleanup.
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "iso" }, .{ .int = 3 });
        var committed_result = try tx.commitWith(CommitOptions.none);
        defer committed_result.deinit(gpa);
        const hash = committed_result.hash.?;

        // **The document's isolation is what it was**, not the transaction's and
        // not nothing.
        const kept = doc.isolationHeads() orelse return error.ExpectedIsolation;
        try testing.expectEqual(@as(usize, 1), kept.len);
        try testing.expect(kept[0].eql(first));

        var built = (try doc.getChangeByHash(gpa, hash)).?;
        defer built.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), built.change.deps.len);
        try testing.expect(built.change.deps[0].eql(first));
    }
}

test "enclose commits on a returned value and rolls back on a raised one" {
    const gpa = testing.allocator;

    // The closure's context is a value the caller owns, and the commit message
    // is derived from what the closure returned.
    const Ctx = struct { key: []const u8, value: i64, fail: bool };

    const body = struct {
        fn run(ctx: Ctx, tx: *Transaction) TransactionError!i64 {
            _ = try tx.put(.root, .{ .key = ctx.key }, .{ .int = ctx.value });
            _ = try tx.putObject(.root, .{ .key = "made" }, .map);
            if (ctx.fail) return error.InvalidValueType;
            return ctx.value * 2;
        }
    }.run;

    const derive = struct {
        fn options(_: Ctx, result: *const i64) CommitOptions {
            var opts = CommitOptions{};
            opts.setMessage("from result");
            opts.setTime(result.*);
            return opts;
        }
    }.options;

    {
        var doc = try manual(gpa);
        defer doc.deinit();

        var ok = try encloseWith(i64, gpa, &doc, Ctx{ .key = "k", .value = 21, .fail = false }, body, derive);
        switch (ok) {
            .success => |*s| {
                defer s.patch_log.deinit();
                try testing.expectEqual(@as(i64, 42), s.result);
                // **A hash, and the message and the time the options derived
                // from the result.**
                const hash = s.hash orelse return error.ExpectedHash;
                var built = (try doc.getChangeByHash(gpa, hash)).?;
                defer built.deinit(gpa);
                try testing.expectEqualStrings("from result", built.change.message);
                try testing.expectEqual(@as(i64, 42), built.change.time);
            },
            .failure => return error.ExpectedSuccess,
        }
        // **One change, and the two operations the closure wrote are in it.**
        try testing.expectEqual(@as(usize, 1), doc.graph.len());
        try testing.expectEqual(@as(usize, 2), doc.ops.len());
        // A fresh journal is empty and the document remains writable.
        var reopened = try Transaction.open(gpa, &doc);
        // The testing allocator does not inject allocation failure during cleanup.
        defer reopened.deinit() catch unreachable;
        try testing.expectEqual(@as(usize, 0), reopened.count());
        _ = try reopened.rollback();
    }

    {
        var doc = try manual(gpa);
        defer doc.deinit();
        var before = try doc.clone(gpa);
        defer before.deinit();

        var bad = try enclose(i64, gpa, &doc, Ctx{ .key = "k", .value = 1, .fail = true }, body);
        switch (bad) {
            .success => return error.ExpectedFailure,
            .failure => |*f| {
                defer f.patch_log.deinit();
                try testing.expectEqual(error.InvalidValueType, f.err);
                // **Both operations the closure wrote are cancelled.**
                try testing.expectEqual(@as(usize, 2), f.cancelled);
            },
        }
        // **And the document is the one it was**, checked the way the rollback
        // test checks it.
        try doc.ops.debugCmp(&before.ops);
        try testing.expectEqual(@as(usize, 0), doc.graph.len());
    }
}

test "abort is idempotent, and it is what a scope that can fail defers" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    _ = try commitPut(gpa, &doc, "a", .{ .int = 1 });
    var before = try doc.clone(gpa);
    defer before.deinit();

    {
        var tx = try Transaction.open(gpa, &doc);
        // The testing allocator does not inject allocation failure during cleanup.
        defer tx.deinit() catch unreachable;
        // **`abort` is deferred *after* `deinit`, so it runs first.** The order
        // of these two lines is the whole of the difference between a
        // transaction that gives its work back and one that leaks it into the
        // op set.
        defer abort(&tx) catch unreachable;
        _ = try tx.put(.root, .{ .key = "gone" }, .{ .int = 1 });
        _ = try tx.delete(.root, .{ .key = "a" });
        try testing.expectEqual(@as(usize, 2), tx.pending.items.len);
    }
    try doc.ops.debugCmp(&before.ops);
    try testing.expectEqual(@as(usize, 1), doc.graph.len());

    {
        // **Abort on a committed transaction is a no-op, and so is a second
        // abort.** That is the whole difference from `rollback`, which refuses.
        var tx = try Transaction.open(gpa, &doc);
        // The testing allocator does not inject allocation failure during cleanup.
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "b" }, .{ .int = 2 });
        var committed_result = try tx.commitWith(CommitOptions.none);
        defer committed_result.deinit(gpa);
        try abort(&tx);
        try abort(&tx);
    }
    // **The second transaction's change is a real change**, so the document is
    // one commit ahead of the clone and `debugCmp` is not the comparison here.
    try testing.expectEqual(@as(usize, 2), doc.graph.len());
    const final_heads = try doc.getHeads(gpa);
    defer gpa.free(final_heads);
    try testing.expectEqual(@as(usize, 1), final_heads.len);
}

test "maxOp is this transaction's last counter, one below its start when it has written nothing, and a refusal once it is closed" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    try testing.expectEqual(@as(u64, 1), tx.start_op);
    // **An empty transaction's max op is one below its start**, which is the
    // value upstream's `change_meta` computes over an empty `pending`
    // ([`inner.rs:182`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
    // and the one the encoder accepts.
    try testing.expectEqual(tx.start_op - 1, try maxOp(&tx));

    _ = try tx.put(.root, .{ .key = "a" }, .{ .int = 1 });
    try testing.expectEqual(tx.start_op, try maxOp(&tx));
    _ = try tx.put(.root, .{ .key = "b" }, .{ .int = 2 });
    try testing.expectEqual(tx.start_op + 1, try maxOp(&tx));
    const text = try tx.putObject(.root, .{ .key = "t" }, .text);
    try tx.spliceText(text, 0, 0, "abc");
    try testing.expectEqual(@as(usize, 6), tx.pending.items.len);
    try testing.expectEqual(tx.start_op + 5, try maxOp(&tx));

    // **The counter is read on the open side of the commit, and the change
    // carries the same number** — the two derivations of "the last counter
    // this transaction wrote", the transaction's own and the change header's,
    // agree to the digit. Read after the commit the first of them is a read of
    // a spent transaction and refuses.
    const max_op = try maxOp(&tx);
    var committed_result = try tx.commitWith(CommitOptions.none);
    defer committed_result.deinit(gpa);
    const hash = committed_result.hash.?;
    var built = (try doc.getChangeByHash(gpa, hash)).?;
    defer built.deinit(gpa);
    try testing.expectEqual(max_op, built.change.max_op);
    try testing.expectEqual(tx.start_op, built.change.start_op);

    // **And the document's own answer is the same number, from the third
    // derivation** ([`change_graph.rs:557`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)
    // folds a change's `max_op` into the graph's running maximum). It is a
    // different question from `maxOp` and a different function, and here they
    // coincide because the transaction just wrote the document's last
    // counter — which is the only reason to believe they are two questions
    // rather than one.
    try testing.expectEqual(max_op, doc.graph.maxOp());

    // **The post-commit read refuses rather than answering `start_op - 1`.**
    // The commit drained `pending`
    // ([`transact.zig:1344-1346`](transact.zig)), so the arithmetic would say
    // `0` on this document, and `0` is not a counter anybody wrote.
    try testing.expectError(error.InvalidOp, maxOp(&tx));
    // **So does the header prediction**, which is the same question asked of
    // the whole change: a spent transaction's `start_op`, `seq` and `deps`
    // are the ones it was opened with and describe nothing.
    try testing.expectError(error.InvalidOp, changeMeta(&tx, &.{}));
}

test "maxOp refuses a closed transaction however it was closed, and a rollback is the case that would otherwise lie" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    // **A commit that wrote nothing is a close.** Upstream returns before
    // `commit_impl` ([`inner.rs:135-142`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
    // and takes `self` by value on the way there
    // ([`:129-130`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    // so the transaction is spent either way; here `commit` sets `closed`
    // before it looks at `pending`
    // ([`transact.zig:1327-1332`](transact.zig)), which is the half that makes
    // this state a refusal rather than the `start_op - 1` an open empty
    // transaction answers.
    {
        var tx = try Transaction.open(gpa, &doc);
        // The testing allocator does not inject allocation failure during cleanup.
        defer tx.deinit() catch unreachable;
        try testing.expectEqual(tx.start_op - 1, try maxOp(&tx));
        var committed_result = try tx.commitWith(CommitOptions.none);
        defer committed_result.deinit(gpa);
        try testing.expect(committed_result.hash == null);
        try testing.expectError(error.InvalidOp, maxOp(&tx));
        try testing.expectEqual(@as(usize, 0), doc.graph.len());
    }

    // **A rollback is worse than a commit, and this is why `closed` rather
    // than `pending.len` is what the refusal keys on.** `rollback` undoes the
    // operations and leaves them in the list
    // ([`transact.zig:1356-1368`](transact.zig)) — `deinit` is what frees
    // them — so `pending` still holds one and the arithmetic would answer
    // `start_op` for a counter the document has just taken back and will
    // never hand out again. An empty pending list cannot tell the two states
    // apart, and this is the one that is not.
    {
        var tx = try Transaction.open(gpa, &doc);
        // The testing allocator does not inject allocation failure during cleanup.
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "a" }, .{ .int = 1 });
        try testing.expectEqual(tx.start_op, try maxOp(&tx));
        try testing.expectEqual(@as(usize, 1), try tx.rollback());
        try testing.expectError(error.InvalidOp, maxOp(&tx));
        // **And the document is back where it was**: the operation the
        // refused read would have claimed is gone, rows and graph alike.
        try testing.expectEqual(@as(usize, 0), doc.ops.len());
        try testing.expectEqual(@as(usize, 0), doc.graph.len());
        try testing.expectEqual(@as(u64, 0), doc.graph.maxOp());
    }
}

test "changeMeta and authorFooter predict the header and the footer the commit wrote" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    try doc.setAuthor(gpa, "ada@example.com");

    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    try testing.expectEqual(@as(u64, 1), tx.seq);
    _ = try tx.put(.root, .{ .key = "a" }, .{ .int = 1 });
    _ = try tx.put(.root, .{ .key = "b" }, .{ .int = 2 });

    const deps = try depIndices(gpa, &tx);
    defer gpa.free(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
    const meta = try changeMeta(&tx, deps);
    const footer = try authorFooter(gpa, &tx);
    defer gpa.free(footer);
    // **The first change of an actor carries the author, and it is not empty.**
    try testing.expect(footer.len > 0);

    var committed_result = try tx.commitWith(CommitOptions.none.withMessage("hello"));
    defer committed_result.deinit(gpa);
    const hash = committed_result.hash.?;
    var built = (try doc.getChangeByHash(gpa, hash)).?;
    defer built.deinit(gpa);

    // **The header the transaction predicted is the header the change carries.**
    try testing.expectEqual(meta.seq, built.change.seq);
    try testing.expectEqual(meta.start_op, built.change.start_op);
    // **`max_op` is asserted against the change.** A change rebuilt by the
    // collector used to leave this at zero until `withOpCount` filled it
    // ([`change.zig:126-127`](change.zig)), and the assertion was dropped for
    // that; the collector fills it now, so the header's `max_op` and the
    // [`maxOp`] `meta` was built from are compared rather than assumed. **The
    // comparison is against `meta`, not against a fresh `maxOp`: `meta` was
    // taken while the transaction was open and a read now is a read of a
    // spent one.**
    try testing.expectEqual(meta.max_op, built.change.max_op);
    try testing.expectEqual(tx.start_op + 1, meta.max_op);
    try testing.expectEqual(meta.time, built.change.time);
    // **The message the transaction carries is the empty one, and the commit
    // carried the message the options named**: `commit_impl` overrides the
    // transaction's own when the argument is `Some`
    // ([`inner.rs:152-154`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    // so a `changeMeta` taken before the commit cannot know it.
    try testing.expectEqualStrings("", meta.message);
    try testing.expectEqualStrings("hello", built.change.message);
    try testing.expectEqual(deps.len, built.change.deps.len);
    // **The change is authored by the actor this transaction wrote for**, and
    // `setAuthor` minted a fresh one, so it is not the document's earlier id.
    try testing.expect(actorId(&tx).?.eql(built.change.actor));
    try testing.expect(!std.mem.eql(u8, built.change.actor.bytes, "0123456789abcdef"));

    // **And the footer it predicted is the one the document stored**, which is
    // the part `changeMeta` cannot carry.
    try testing.expectEqual(@as(usize, 1), doc.node_info.items.len);
    try testing.expectEqualSlices(u8, footer, doc.node_info.items[0].extra);
    const decoded = try docmod.decodeAuthorFooter(doc.node_info.items[0].extra);
    try testing.expectEqualStrings("ada@example.com", decoded.?);
}

test "an actor's second change carries no author, because one actor has one author" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    try doc.setAuthor(gpa, "ada@example.com");

    {
        var tx = try Transaction.open(gpa, &doc);
        // The testing allocator does not inject allocation failure during cleanup.
        defer tx.deinit() catch unreachable;
        try testing.expectEqual(@as(u64, 1), tx.seq);
        const footer = try authorFooter(gpa, &tx);
        defer gpa.free(footer);
        try testing.expect(footer.len > 0);
        _ = try tx.put(.root, .{ .key = "a" }, .{ .int = 1 });
        var committed_result = try tx.commitWith(CommitOptions.none);
        defer committed_result.deinit(gpa);
    }
    {
        var tx = try Transaction.open(gpa, &doc);
        // The testing allocator does not inject allocation failure during cleanup.
        defer tx.deinit() catch unreachable;
        try testing.expectEqual(@as(u64, 2), tx.seq);
        // **`automerge.rs:568` — the author is set only when `seq == 1`,**
        // so the second change of an actor has no footer at all.
        const footer = try authorFooter(gpa, &tx);
        defer gpa.free(footer);
        try testing.expectEqual(@as(usize, 0), footer.len);
        _ = try tx.put(.root, .{ .key = "b" }, .{ .int = 2 });
        var committed_result = try tx.commitWith(CommitOptions.none);
        defer committed_result.deinit(gpa);
        const hash = committed_result.hash.?;
        var built = (try doc.getChangeByHash(gpa, hash)).?;
        defer built.deinit(gpa);
        // **The second change's op columns are its own and carry no footer**,
        // so `opsBytes` is shorter than the first change's by exactly the
        // footer's absence — checked through the stored `node_info` below.
        try testing.expect(built.change.opsBytes().len > 0);
        try testing.expectEqual(@as(usize, 2), doc.node_info.items.len);
        try testing.expectEqual(@as(usize, 0), doc.node_info.items[1].extra.len);
    }
}

test "depIndices resolves this transaction's dependencies, and drops one the graph does not hold" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    const first = try commitPut(gpa, &doc, "a", .{ .int = 1 });
    const second = try commitPut(gpa, &doc, "b", .{ .int = 2 });

    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    // **The actor's own last change is already a head, so it is the only
    // dependency** ([`automerge.rs:551-556`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)
    // adds it only when it is not already there).
    try testing.expectEqual(@as(usize, 1), tx.baseHeads().len);
    try testing.expect(tx.baseHeads()[0].eql(second));
    _ = first;
    const deps = try depIndices(gpa, &tx);
    defer gpa.free(deps);
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqual(doc.graph.hashToIndex(second).?, deps[0]);

    // **A dependency the graph does not hold is dropped rather than refused**,
    // which is upstream's `filter_map`
    // ([`inner.rs:200-204`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    // `Transaction.deps` only ever holds hashes the document has, so the drop
    // is unreachable from a transaction the document opened; forging one is the
    // only way to see it, and it is worth seeing, because the alternative is a
    // commit that names a dependency its reader does not have.
    tx.deps[0] = ChangeHash.fromChecksum(.{ 1, 2, 3, 4 });
    const forged = try depIndices(gpa, &tx);
    defer gpa.free(forged);
    try testing.expectEqual(@as(usize, 0), forged.len);
}

test "hashForOpid names the change that carries an operation, and nothing for a pending one" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    const id = (try tx.put(.root, .{ .key = "k" }, .{ .int = 1 })).?;
    const made = try tx.putObject(.root, .{ .key = "m" }, .map);
    const exid = doc.ops.idToExid(id);
    const made_exid = made;

    // **The root names no operation, and an operation this transaction has
    // written is in the op set but not under any head**
    // ([`manual_transaction.rs:41-43`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)).
    try testing.expect(hashForOpid(&tx, .root) == null);
    try testing.expect(hashForOpid(&tx, exid) == null);
    try testing.expect(hashForOpid(&tx, made_exid) == null);

    var committed_result = try tx.commitWith(CommitOptions.none);
    defer committed_result.deinit(gpa);
    const hash = committed_result.hash.?;
    // **After the commit both name it.**
    try testing.expect(hashForOpid(&tx, exid).?.eql(hash));
    try testing.expect(hashForOpid(&tx, made_exid).?.eql(hash));
    // And a counter the document's graph does not carry is still null.
    const absent = ExId.fromParts(9999, tx.actor) orelse return error.BadExId;
    try testing.expect(hashForOpid(&tx, absent) == null);
}

test "hashForOpid answers a many-change document as the graph's own interval query does, and answers every null upstream lists" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    const first: ActorId = .{ .bytes = "0123456789abcdef" };
    const second: ActorId = .{ .bytes = "fedcba9876543210" };
    var key_buf: [16]u8 = undefined;
    var last_hash: ChangeHash = undefined;
    var last_exid: ExId = undefined;
    for (0..200) |i| {
        // **Alternate the actor**, so `seq_index` has two lists of a hundred
        // each rather than one list of two hundred. The counter space is
        // shared — `start_op = graph.maxOp() + 1` ([`doc.zig:3398`](doc.zig),
        // upstream's `automerge.rs:567`) — so the two lists interleave, and a
        // binary search over one of them has to step over counters the other
        // actor owns. That is the shape where a search and a scan could
        // disagree, and a single actor could not produce it.
        doc.setActorId(if (i % 2 == 0) first else second);
        var tx = try Transaction.open(gpa, &doc);
        // The testing allocator does not inject allocation failure during cleanup.
        defer tx.deinit() catch unreachable;
        const key = try std.fmt.bufPrint(&key_buf, "k{d}", .{i});
        const id = (try tx.put(.root, .{ .key = key }, .{ .int = @intCast(i) })).?;
        var committed_result = try tx.commitWith(CommitOptions.none);
        defer committed_result.deinit(gpa);
        last_hash = committed_result.hash.?;
        last_exid = doc.ops.idToExid(id);
    }
    // **Two actors and two hundred changes**, so the answer for the last
    // change is two hundred nodes into the table rather than one. The scan this
    // replaced cost that walk per call, and a fixture of one change would not
    // tell the two apart: both answers would be the first node.
    try testing.expectEqual(@as(usize, 200), doc.graph.len());
    try testing.expectEqual(@as(usize, 2), doc.numActors());

    // A transaction to ask through. `hashForOpid` reads `tx.doc.graph` and
    // nothing else on the transaction, so an open one is all the call needs.
    var probe = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer probe.deinit() catch unreachable;

    // **The last change's operation, which is the one the old scan had to walk
    // the whole table to reach.** The head of the graph is that change, so this
    // is also the answer a peer asking for the newest operation gets.
    // `head`, not `heads`: this file has a `heads` function
    // ([`:398`](transaction.zig)) and a local may not shadow it.
    const head = probe.baseHeads();
    try testing.expectEqual(@as(usize, 1), head.len);
    try testing.expect(hashForOpid(&probe, last_exid).?.eql(last_hash));
    try testing.expect(hashForOpid(&probe, last_exid).?.eql(head[0]));

    // **Every counter of every actor, against the graph's own interval query.**
    // This is the equivalence that makes the delegation a rewiring and not a
    // new answer: `opidToHash` is what `hashForOpid` now calls, and it is what
    // upstream calls (`change_graph.rs:300-318`). Walking every counter rather
    // than a sample is deliberate — a search that is off by one agrees with a
    // scan everywhere except the counter it lands on.
    var named: usize = 0;
    for (0..doc.numActors()) |slot| {
        // `types.ActorIdx` rather than a module alias: nothing outside this
        // test names the type, and a top-level `const` only tests read is a
        // name the file's own surface does not have.
        const actor: types.ActorIdx = @intCast(slot);
        // `0` is the head sentinel, and `maxOp() + 1` is past the last change.
        var counter: u64 = 0;
        while (counter <= doc.graph.maxOp() + 1) : (counter += 1) {
            const id = ExId.fromParts(counter, actor) orelse continue;
            const through_door = hashForOpid(&probe, id);
            const through_graph = doc.graph.opidToHash(id.opId().?);
            if (through_graph) |hash| {
                named += 1;
                try testing.expectEqual(hash, through_door.?);
            } else {
                // A counter no change owns belongs to no change: that is the
                // root's counter zero and the counter past the last change.
                try testing.expect(through_door == null);
            }
        }
    }
    // **The comparison is not vacuous.** `named` counts the `(actor, counter)`
    // pairs some change owns, and every operation in the fixture is owned by
    // exactly one change of exactly one actor — so it is the fixture's op
    // count. A door that answered null for everything would fail here rather
    // than pass having compared nothing.
    try testing.expectEqual(@as(usize, 200), named);

    // **The three nulls upstream lists**
    // ([`manual_transaction.rs:41-43`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)).
    // The root names no operation.
    try testing.expect(hashForOpid(&probe, .root) == null);
    // An id the document does not hold: a real actor slot and a counter above
    // every change's `max_op`.
    const last_slot: types.ActorIdx = @intCast(doc.graph.numActors() - 1);
    const absent = ExId.fromParts(1_000_000, last_slot) orelse return error.BadExId;
    try testing.expect(hashForOpid(&probe, absent) == null);
    // And an operation this transaction has written and not yet committed,
    // which is the third of the three and the one only the manual door
    // reaches: its counter is above every change the graph holds, so it is
    // past the last `max_op` whichever way the interval is searched.
    const pending = (try probe.put(.root, .{ .key = "pending" }, .{ .int = 0 })).?;
    try testing.expect(hashForOpid(&probe, doc.ops.idToExid(pending)) == null);
    // **And it names the change once that transaction commits**, which is the
    // whole of the pending/committed distinction.
    var committed_result = try probe.commitWith(CommitOptions.none);
    defer committed_result.deinit(gpa);
    const committed = committed_result.hash.?;
    try testing.expect(hashForOpid(&probe, doc.ops.idToExid(pending)).?.eql(committed));
}

test "the whole write surface of API.md's ## Write, driven from manual transactions" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;

    // Drive writes through the same journal and check their materialized effects.
    _ = try tx.put(.root, .{ .key = "name" }, .{ .str = "ada" });
    _ = try tx.put(.root, .{ .key = "hits" }, .{ .counter = .init(0) });
    try tx.increment(.root, .{ .key = "hits" }, 2);
    const list = try tx.putObject(.root, .{ .key = "l" }, .list);
    _ = try tx.insert(list, 0, .{ .int = 1 });
    const nested_list = try tx.insertObject(list, 1, .list);
    const text = try tx.putObject(.root, .{ .key = "t" }, .text);
    try tx.spliceText(text, 0, 0, "hello world");
    try tx.mark(text, 0, 5, "em", .after, .{ .bool_value = true });
    try tx.unmark(text, 0, 5, .after, "em", null);
    const block = try tx.splitBlock(text, 5);
    _ = try tx.put(block, .{ .key = "kind" }, .{ .str = "para" });
    try tx.joinBlock(text, 5);
    _ = try tx.replaceBlock(text, 0);
    const plain = try tx.putObject(.root, .{ .key = "u" }, .text);
    try tx.spliceText(plain, 0, 0, "hello");
    try tx.mark(plain, 0, 2, "em", .after, .{ .bool_value = true });
    const batched = try tx.batchCreateObject(.root, .{ .key = "batched" }, .map);
    _ = try tx.put(batched, .{ .key = "x" }, .{ .float = 0.5 });
    const hydrated = try tx.putObject(.root, .{ .key = "hydrated" }, .map);
    // Hydrated inputs remain caller-owned; the journal copies their payloads.
    const map = try hydratedMap(gpa);
    defer {
        map.deinit();
        gpa.destroy(map);
    }
    try tx.updateMapValue(hydrated, map);
    try testing.expectEqual(@as(usize, 1), try tx.delete(.root, .{ .key = "name" }));
    try testing.expectEqual(@as(usize, 1), try tx.delete(list, .{ .index = 0 }));

    // **`base_heads` and `pending_ops` are `Transactable` methods on this door
    // too** ([`transaction.rs:319-321`](../../github-automerge-automerge/rust/automerge/src/transaction.rs),
    // [`:455-460`](../../github-automerge-automerge/rust/automerge/src/transaction.rs)),
    // and the counts are the numbers they promise.
    try testing.expectEqual(@as(usize, 0), tx.baseHeads().len);
    try testing.expectEqual(tx.pending.items.len, tx.count());
    try testing.expectEqual(tx.pending.items.len, (try maxOp(&tx)) - tx.start_op + 1);

    const rows_before = doc.ops.len();
    var committed_result = try tx.commitWith(CommitOptions.none);
    defer committed_result.deinit(gpa);
    try testing.expectEqual(rows_before, doc.ops.len());
    try testing.expectEqual(@as(usize, 1), doc.graph.len());

    // **The document reads back as what the transaction wrote.** Every method
    // above has an effect a reader can see, so a method that wrote nothing
    // would be caught here rather than being assumed to have worked.
    if (try readmod.get(&doc, .root, .{ .key = "name" })) |_| return error.ExpectedAbsent;
    const hits = try readmod.get(&doc, .root, .{ .key = "hits" });
    try testing.expectEqual(@as(i64, 2), hits.?.value.scalar.counter.current);
    try testing.expectEqual(@as(usize, 1), doc.ops.seqLength(list, doc.textEncoding(), null));
    try testing.expectEqual(ObjType.list, try doc.objectType(nested_list));
    try testing.expectEqual(@as(usize, 11), doc.ops.seqLength(text, doc.textEncoding(), null));
    // **A mark and then an unmark leave no mark** ([`op_set.rs:1023`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
    const text_marks = try doc.marks(gpa, text);
    defer gpa.free(text_marks);
    try testing.expectEqual(@as(usize, 0), text_marks.len);
    const plain_text = try doc.text(gpa, plain);
    defer gpa.free(plain_text);
    try testing.expectEqualStrings("hello", plain_text);
    const plain_marks = try doc.marks(gpa, plain);
    defer gpa.free(plain_marks);
    try testing.expectEqual(@as(usize, 1), plain_marks.len);
    try testing.expectEqualStrings("em", plain_marks[0].name);
    try testing.expectEqual(@as(usize, 0), plain_marks[0].start);
    try testing.expectEqual(@as(usize, 2), plain_marks[0].end);
    const x = try readmod.get(&doc, batched, .{ .key = "x" });
    try testing.expectEqual(@as(f64, 0.5), x.?.value.scalar.float);
    const kind = try readmod.get(&doc, block, .{ .key = "kind" });
    try testing.expectEqualStrings("para", kind.?.value.scalar.str);
    // **`update_object` recursed**: the nested map under "hydrated" is there
    // with its own scalar in it.
    const tag = try readmod.get(&doc, hydrated, .{ .key = "inner" });
    try testing.expectEqual(ObjType.map, tag.?.value.object);
    const nested = tag.?.id;
    const count = try readmod.get(&doc, hydrated, .{ .key = "count" });
    try testing.expectEqual(@as(i64, 4), count.?.value.scalar.int);
    const inner_tag = try readmod.get(&doc, nested, .{ .key = "tag" });
    try testing.expectEqualStrings("x", inner_tag.?.value.scalar.str);
}

/// The map `update_object` is given: one scalar and one nested map, so the
/// recursive arm and the scalar arm are both taken. The caller owns the box.
fn hydratedMap(gpa: Allocator) !*hydmod.Map {
    const box = try gpa.create(hydmod.Map);
    errdefer gpa.destroy(box);
    box.* = hydmod.Map.init(gpa, .root);
    try box.putOwned("count", .init(hydmod.Value.scalar(.{ .int = 4 }), false));
    var inner = hydmod.Map.init(gpa, .root);
    try inner.putOwned("tag", .init(hydmod.Value.scalar(.{ .str = "x" }), false));
    try box.putOwned("inner", .init(.{ .object = .{ .map = inner } }, false));
    return box;
}

test "a transaction opening refusal does not invoke the closure or mutate the document" {
    const gpa = testing.allocator;
    var failing = testing.FailingAllocator.init(gpa, .{});
    var doc = try manual(failing.allocator());
    defer doc.deinit();
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, enclose(void, failing.allocator(), &doc, {}, struct {
        fn run(_: void, _: *Transaction) error{Invoked}!void {
            return error.Invoked;
        }
    }.run));
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(@as(usize, 0), doc.graph.len());
    try testing.expectEqual(@as(usize, 0), doc.ops.len());
}

test "enclose preserves primary error and transfers failed rollback ownership" {
    const Context = struct {
        failing: *testing.FailingAllocator,
        body_fails: bool,

        fn body(ctx: *@This(), tx: *Transaction) (TransactionError || error{Rejected})!usize {
            _ = try tx.put(.root, .{ .key = "one" }, .{ .int = 1 });
            _ = try tx.put(.root, .{ .key = "two" }, .{ .int = 2 });
            ctx.failing.fail_index = ctx.failing.alloc_index;
            if (ctx.body_fails) return error.Rejected;
            return 77;
        }
    };
    for ([_]bool{ true, false }) |body_fails| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try Document.init(gpa, testing.io);
        defer doc.deinit();
        var ctx = Context{ .failing = &failing, .body_fails = body_fails };
        var log = @import("patches.zig").PatchLog.active(gpa);
        defer log.deinit();
        var outcome = try encloseWithPatchLog(usize, gpa, &doc, &log, &ctx, Context.body, null);
        failing.fail_index = std.math.maxInt(usize);
        switch (outcome) {
            .success => return error.ExpectedFailure,
            .failure => |*failure| {
                try testing.expectEqual(if (body_fails) error.Rejected else error.OutOfMemory, failure.err);
                try testing.expectEqual(@as(?TransactionError, error.OutOfMemory), failure.rollback_error);
                try testing.expectEqual(if (body_fails) @as(?usize, null) else @as(?usize, 77), failure.result);
                const tx = &failure.transaction.?;
                // Failure injection was disabled before retrying recovery.
                defer tx.deinit() catch unreachable;
                defer failure.patch_log.deinit();
                try testing.expectEqual(@as(usize, 2), try tx.rollback());
                var recovered_log = tx.takePatchLog();
                defer recovered_log.deinit();
                try testing.expect(recovered_log.recording);
                try testing.expect(!failure.patch_log.recording);
                try testing.expectEqual(@as(usize, 0), doc.graph.len());
                try testing.expect((try @import("read.zig").get(&doc, .root, .{ .key = "one" })) == null);
                try testing.expect((try @import("read.zig").get(&doc, .root, .{ .key = "two" })) == null);
            },
        }
    }
}

test "parity transaction explicit heads exclude pending writes and walks retain their clock" {
    // Historical reads must not take the current-head shortcut while a journal is open.
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    const first = try commitPut(gpa, &doc, "old", .{ .int = 1 });
    var tx = try Transaction.openAt(gpa, &doc, &.{first});
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    _ = try tx.put(.root, .{ .key = "pending" }, .{ .int = 2 });
    try testing.expect((try tx.get(.root, .{ .key = "pending" })) != null);
    try testing.expect((try tx.getAt(.root, .{ .key = "pending" }, &.{first})) == null);
    var keys = try tx.keysAt(.root, &.{first});
    defer keys.deinit(gpa);
    _ = try tx.getAt(.root, .{ .key = "old" }, &.{});
    try testing.expectEqualStrings("old", (try keys.next()).?);
    try testing.expect((try keys.next()) == null);
    _ = try tx.rollback();
}

test "parity transaction updateObject dispatches list text and rejects mismatched input" {
    // Public hydrated updates select their target by object kind, not a map-only door.
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    const list = try tx.putObject(.root, .{ .key = "list" }, .list);
    _ = try tx.insert(list, 0, .{ .int = 3 });
    var empty = hydmod.Value.list(gpa);
    defer empty.deinit();
    try tx.updateObject(list, &empty);
    try testing.expectEqual(@as(usize, 0), try tx.length(list));
    const text = try tx.putObject(.root, .{ .key = "text" }, .text);
    var replacement = try hydmod.Value.text(gpa, tx.textEncoding(), "new");
    defer replacement.deinit();
    try tx.updateObject(text, &replacement);
    const rendered = try tx.text(text, gpa);
    defer gpa.free(rendered);
    try testing.expectEqualStrings("new", rendered);
    try testing.expectError(error.ChangeType, tx.updateObject(list, &replacement));
    _ = try tx.rollback();
}

test "parity transaction external log moves only on successful open and returns on commit" {
    // A caller can keep an externally funded log after a refused constructor.
    const patches = @import("patches.zig");
    const gpa = testing.allocator;
    var failing = testing.FailingAllocator.init(gpa, .{});
    var doc = try manual(failing.allocator());
    defer doc.deinit();
    var log = patches.PatchLog.active(gpa);
    defer log.deinit();
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, Transaction.openWithPatchLog(failing.allocator(), &doc, &log, null));
    try testing.expect(log.recording);
    failing.fail_index = std.math.maxInt(usize);
    var tx = try Transaction.openWithPatchLog(failing.allocator(), &doc, &log, null);
    // Failure injection was disabled before this successful open.
    defer tx.deinit() catch unreachable;
    _ = try tx.put(.root, .{ .key = "logged" }, .{ .int = 4 });
    var result = try tx.commit();
    defer result.deinit(gpa);
    try testing.expect(result.hash != null);
    var published = try doc.makePatches(&result.patch_log);
    defer published.deinit();
    try testing.expectEqual(@as(usize, 1), published.len());
}

test "parity transaction close rolls back pending rows before releasing its journal" {
    // Closing a borrowed owner must leave the document usable, with no abandoned row.
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    var tx = try Transaction.open(gpa, &doc);
    _ = try tx.put(.root, .{ .key = "abandoned" }, .{ .int = 8 });
    try tx.deinit();
    try testing.expect((try readmod.get(&doc, .root, .{ .key = "abandoned" })) == null);
    _ = try commitPut(gpa, &doc, "later", .{ .int = 9 });
    try testing.expect((try readmod.get(&doc, .root, .{ .key = "later" })) != null);
}

test "parity transaction closure preserves arbitrary user errors" {
    // Application errors are not restricted to the CRDT write error vocabulary.
    const Body = struct {
        fn run(_: void, tx: *Transaction) (TransactionError || error{Rejected})!usize {
            _ = try tx.put(.root, .{ .key = "temporary" }, .{ .int = 1 });
            return error.Rejected;
        }
    };
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    var log = @import("patches.zig").PatchLog.active(gpa);
    defer log.deinit();
    var outcome = try encloseWithPatchLog(usize, gpa, &doc, &log, {}, Body.run, null);
    switch (outcome) {
        .success => return error.ExpectedFailure,
        .failure => |*failure| {
            defer failure.patch_log.deinit();
            try testing.expectEqual(error.Rejected, failure.err);
            try testing.expect(failure.transaction == null);
            try testing.expect(failure.patch_log.recording);
            try testing.expectEqual(@as(usize, 1), failure.cancelled);
        },
    }
    try testing.expect((try readmod.get(&doc, .root, .{ .key = "temporary" })) == null);
}

test "parity owned transaction returns its document and committed log owner" {
    // In-place construction keeps the journal's raw-document pointer stable.
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    var owned: @import("transaction.zig").OwnedTransaction = undefined;
    try owned.init(gpa, &doc, null);
    // The testing allocator does not inject allocation failure during cleanup.
    defer owned.deinit() catch unreachable;
    _ = try owned.transaction.put(.root, .{ .key = "owned" }, .{ .int = 6 });
    var completed = try owned.commit(CommitOptions.none);
    defer completed.document.deinit();
    defer completed.result.deinit(gpa);
    try testing.expect(completed.result.hash != null);
    const item = (try readmod.get(&completed.document, .root, .{ .key = "owned" })).?;
    try testing.expectEqual(@as(i64, 6), item.value.scalar.int);
    _ = try commitPut(gpa, &completed.document, "after transfer", .{ .int = 7 });
    try testing.expect((try readmod.get(&completed.document, .root, .{ .key = "after transfer" })) != null);
}

test "parity transaction pending clone rolls back independently without closing source" {
    // The cloned raw rows and journal form one independent recovery owner.
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    var source = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer source.deinit() catch unreachable;
    _ = try source.put(.root, .{ .key = "pending" }, .{ .str = "copied" });
    var copied_doc = try doc.clonePending(gpa);
    defer copied_doc.deinit();
    var copied = try source.cloneInto(gpa, &copied_doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer copied.deinit() catch unreachable;
    _ = try copied.rollback();
    try testing.expect((try readmod.get(&copied_doc, .root, .{ .key = "pending" })) == null);
    const item = (try source.get(.root, .{ .key = "pending" })).?;
    try testing.expectEqualStrings("copied", item.value.scalar.str);
    try testing.expect(!source.closed);
    _ = try source.rollback();
}

test "parity transaction hydrate null bypasses write scope but explicit heads do not" {
    // Rust delegates hydrate to the raw reader rather than selecting transaction scope.
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    const first = try commitPut(gpa, &doc, "version", .{ .int = 1 });
    _ = try commitPut(gpa, &doc, "version", .{ .int = 2 });
    var tx = try Transaction.openAt(gpa, &doc, &.{first});
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    try testing.expectEqual(@as(i64, 1), (try tx.get(.root, .{ .key = "version" })).?.value.scalar.int);
    var current = try tx.hydrate(.root, null, gpa);
    defer current.deinit();
    var old = try tx.hydrate(.root, &.{first}, gpa);
    defer old.deinit();
    try testing.expectEqual(@as(i64, 2), current.object.map.get("version").?.int);
    try testing.expectEqual(@as(i64, 1), old.object.map.get("version").?.int);
    _ = try tx.rollback();
}

test "parity transaction refused cleanup retains journal for rollback retry" {
    // OOM during undo must keep one live recovery owner, not discard undo records.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var doc = try manual(gpa);
    defer doc.deinit();
    var tx = try Transaction.open(gpa, &doc);
    _ = try tx.put(.root, .{ .key = "one" }, .{ .int = 1 });
    _ = try tx.put(.root, .{ .key = "two" }, .{ .int = 2 });
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, tx.deinit());
    try testing.expect(!tx.closed);
    try testing.expect(tx.count() != 0);
    failing.fail_index = std.math.maxInt(usize);
    try tx.deinit();
    try testing.expect((try readmod.get(&doc, .root, .{ .key = "one" })) == null);
    try testing.expect((try readmod.get(&doc, .root, .{ .key = "two" })) == null);
    _ = try commitPut(gpa, &doc, "usable", .{ .int = 3 });
}

test "parity transaction journal owns caller string payload until commit" {
    // A put borrows input only for its call; later caller reuse cannot change the encoded change.
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    var input = [_]u8{ 'o', 'l', 'd' };
    _ = try tx.put(.root, .{ .key = "value" }, .{ .str = &input });
    @memset(&input, 'x');
    var result = try tx.commit();
    defer result.deinit(gpa);
    var change = (try doc.getChangeByHash(gpa, result.hash.?)).?;
    defer change.deinit(gpa);
    var loaded = try manual(gpa);
    defer loaded.deinit();
    _ = try loaded.applyChanges(gpa, &.{change.change});
    const item = (try readmod.get(&loaded, .root, .{ .key = "value" })).?;
    try testing.expectEqualStrings("old", item.value.scalar.str);
}

test "parity transaction log preserves insert then overwrite instead of final state diff" {
    // Local event order is observable even when a later put shadows an earlier insert.
    const patches = @import("patches.zig");
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    var seed = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer seed.deinit() catch unreachable;
    const list = try seed.putObject(.root, .{ .key = "list" }, .list);
    var seeded = try seed.commit();
    defer seeded.deinit(gpa);
    var log = patches.PatchLog.active(gpa);
    defer log.deinit();
    var tx = try Transaction.openWithPatchLog(gpa, &doc, &log, null);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    _ = try tx.insert(list, 0, .{ .int = 1 });
    _ = try tx.put(list, .{ .index = 0 }, .{ .int = 2 });
    var result = try tx.commit();
    defer result.deinit(gpa);
    var published = try doc.makePatches(&result.patch_log);
    defer published.deinit();
    try testing.expectEqual(@as(usize, 2), published.len());
    try testing.expect(published.items.items[0].action == .insert);
    try testing.expect(published.items.items[1].action == .put_seq);
    try testing.expectEqual(@as(i64, 1), published.items.items[0].action.insert.values.get(0).?.value.scalar.int);
    try testing.expectEqual(@as(i64, 2), published.items.items[1].action.put_seq.value.scalar.int);
}

test "borrowed options observe an owned callback result and no-write success owns its log" {
    const Output = struct { message: [5]u8 };
    const Context = struct {
        observed: bool = false,
        fn body(_: *@This(), _: *Transaction) error{Rejected}!Output {
            return .{ .message = "owned".* };
        }
        fn options(ctx: *@This(), result: *const Output) CommitOptions {
            ctx.observed = std.mem.eql(u8, &result.message, "owned");
            return .{ .message = &result.message, .time = 17 };
        }
    };
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    var log = @import("patches.zig").PatchLog.active(gpa);
    defer log.deinit();
    var ctx = Context{};
    var outcome = try encloseWithPatchLog(Output, gpa, &doc, &log, &ctx, Context.body, Context.options);
    switch (outcome) {
        .failure => return error.ExpectedSuccess,
        .success => |*success| {
            defer success.patch_log.deinit();
            try testing.expect(success.hash == null);
            try testing.expect(success.patch_log.recording);
            try testing.expectEqualStrings("owned", &success.result.message);
        },
    }
    try testing.expect(ctx.observed);
    try testing.expect(!log.recording);
}

test "owned rollback returns a movable restored document and independent log" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    _ = try commitPut(gpa, &doc, "kept", .{ .int = 1 });
    var owned: @import("transaction.zig").OwnedTransaction = undefined;
    try owned.init(gpa, &doc, null);
    // The testing allocator does not inject allocation failure during cleanup.
    defer owned.deinit() catch unreachable;
    try testing.expect(owned.transaction.doc == &owned.document);
    _ = try owned.transaction.put(.root, .{ .key = "undone" }, .{ .int = 2 });
    var restored = try owned.rollback();
    defer restored.document.deinit();
    defer restored.patch_log.deinit();
    try testing.expectEqual(@as(usize, 1), restored.cancelled);
    try testing.expect((try readmod.get(&restored.document, .root, .{ .key = "undone" })) == null);
    _ = try commitPut(gpa, &restored.document, "new journal", .{ .int = 3 });
    try testing.expect((try readmod.get(&restored.document, .root, .{ .key = "kept" })) != null);
}

test "refused owned initialization retains the exact source owner for retry" {
    const gpa = testing.allocator;
    var failing = testing.FailingAllocator.init(gpa, .{});
    var source = try manual(failing.allocator());
    const before = try source.save(gpa);
    defer gpa.free(before);
    var owned: @import("transaction.zig").OwnedTransaction = undefined;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, owned.init(failing.allocator(), &source, null));
    failing.fail_index = std.math.maxInt(usize);
    const after = try source.save(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
    try testing.expectEqual(@as(usize, 0), source.ops.len());
    try owned.init(failing.allocator(), &source, null);
    // Failure injection is disabled for terminal cleanup.
    defer owned.deinit() catch unreachable;
    var restored = try owned.rollback();
    defer restored.document.deinit();
    defer restored.patch_log.deinit();
    _ = try commitPut(failing.allocator(), &restored.document, "usable", .{ .int = 4 });
}

test "owned terminal refusals retain one journal until retry succeeds" {
    for ([_]enum { commit, rollback, deinit }{ .commit, .rollback, .deinit }) |action| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var source = try manual(gpa);
        var owned: @import("transaction.zig").OwnedTransaction = undefined;
        try owned.init(gpa, &source, null);
        _ = try owned.transaction.put(.root, .{ .key = "one" }, .{ .int = 1 });
        _ = try owned.transaction.put(.root, .{ .key = "two" }, .{ .int = 2 });
        failing.fail_index = failing.alloc_index;
        switch (action) {
            .commit => try testing.expectError(error.OutOfMemory, owned.commit(.none)),
            .rollback => try testing.expectError(error.OutOfMemory, owned.rollback()),
            .deinit => try testing.expectError(error.OutOfMemory, owned.deinit()),
        }
        try testing.expect(owned.owns_document);
        try testing.expect(!owned.transaction.closed);
        try testing.expect(owned.transaction.doc == &owned.document);
        failing.fail_index = std.math.maxInt(usize);
        switch (action) {
            .commit => {
                var completed = try owned.commit(.none);
                defer completed.document.deinit();
                defer completed.result.deinit(gpa);
                try testing.expect(completed.result.hash != null);
                _ = try commitPut(gpa, &completed.document, "later", .{ .int = 3 });
            },
            .rollback => {
                var restored = try owned.rollback();
                defer restored.document.deinit();
                defer restored.patch_log.deinit();
                try testing.expectEqual(@as(usize, 2), restored.cancelled);
                try testing.expect((try readmod.get(&restored.document, .root, .{ .key = "one" })) == null);
                _ = try commitPut(gpa, &restored.document, "later", .{ .int = 3 });
            },
            .deinit => try owned.deinit(),
        }
        try testing.expect(!owned.owns_document);
    }
}

test "borrowed owned result options encode metadata before the result moves" {
    const Output = struct { message: []u8 };
    const Context = struct {
        gpa: Allocator,
        fn body(ctx: @This(), tx: *Transaction) !Output {
            _ = try tx.put(.root, .{ .key = "written" }, .{ .int = 1 });
            return .{ .message = try ctx.gpa.dupe(u8, "owned result metadata") };
        }
        fn options(_: @This(), result: *const Output) CommitOptions {
            return .{ .message = result.message, .time = 23 };
        }
    };
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    var outcome = try encloseWith(Output, gpa, &doc, Context{ .gpa = gpa }, Context.body, Context.options);
    switch (outcome) {
        .failure => |*failure| {
            defer failure.patch_log.deinit();
            if (failure.result) |result| gpa.free(result.message);
            if (failure.transaction) |*tx| {
                // The testing allocator does not inject failure in recovery.
                defer tx.deinit() catch unreachable;
                _ = try tx.rollback();
            }
            return error.ExpectedSuccess;
        },
        .success => |*success| {
            defer success.patch_log.deinit();
            defer gpa.free(success.result.message);
            var change = (try doc.getChangeByHash(gpa, success.hash.?)).?;
            defer change.deinit(gpa);
            try testing.expectEqualStrings(success.result.message, change.change.message);
            try testing.expectEqual(@as(i64, 23), change.change.time);
        },
    }
}

test "owned logged construction accepts a separately allocated same actor document" {
    // Rust compares actor tables, not the identity of the document allocation.
    const gpa = testing.allocator;
    var foreign = try manual(gpa);
    defer foreign.deinit();
    var foreign_log = @import("patches.zig").PatchLog.active(gpa);
    defer foreign_log.deinit();
    var tx = try Transaction.openWithPatchLog(gpa, &foreign, &foreign_log, null);
    defer tx.deinit() catch unreachable;
    _ = try tx.put(.root, .{ .key = "foreign" }, .{ .int = 1 });
    var committed = try tx.commit();
    defer committed.deinit(gpa);
    var source = try manual(gpa);
    var source_owned = true;
    defer if (source_owned) source.deinit();
    const identity_before = source.patchIdentity();
    const log_allocator = committed.patch_log.gpa;
    var owned: OwnedTransaction = undefined;
    try owned.initWithPatchLog(gpa, &source, &committed.patch_log, null);
    source_owned = false;
    defer owned.deinit() catch unreachable;
    try testing.expect(!committed.patch_log.recording);
    try testing.expectEqual(identity_before, owned.document.patchIdentity());
    try testing.expectEqual(log_allocator.ptr, owned.transaction.patch_log.gpa.ptr);
    try testing.expectEqual(@as(usize, 1), owned.transaction.patch_log.events.items.len);
    try testing.expectEqualStrings("foreign", owned.transaction.patch_log.events.items[0].event.put_map.key);
    _ = try owned.transaction.put(.root, .{ .key = "local" }, .{ .int = 2 });
    var completed = try owned.commit(.none);
    defer completed.document.deinit();
    defer completed.result.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), completed.result.patch_log.events.items.len);
    try testing.expectEqualStrings("foreign", completed.result.patch_log.events.items[0].event.put_map.key);
    try testing.expectEqualStrings("local", completed.result.patch_log.events.items[1].event.put_map.key);
    var published = try completed.document.makePatches(&completed.result.patch_log);
    defer published.deinit();
    try testing.expectEqual(@as(usize, 2), published.len());
    try testing.expectEqual(@as(i64, 2), (try readmod.get(&completed.document, .root, .{ .key = "local" })).?.value.scalar.int);
}

test "logged constructor actor mismatch preserves both owners for every wrapper" {
    // The real Rust mismatch is b < c, including when c is not interned yet.
    const Context = struct {
        fn body(called: *bool, _: *Transaction) !void {
            called.* = true;
        }
    };
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |nonempty| {
        for ([_]enum { current, scoped, owned, closure }{
            .current, .scoped, .owned, .closure,
        }) |route| {
            var owner = try manual(gpa);
            defer owner.deinit();
            owner.setActorId(.{ .bytes = "bbbbbb" });
            var log = @import("patches.zig").PatchLog.active(gpa);
            defer log.deinit();
            {
                var tx = try Transaction.openWithPatchLog(gpa, &owner, &log, null);
                defer tx.deinit() catch unreachable;
                _ = try tx.put(.root, .{ .key = "owner" }, .{ .int = 1 });
                var committed = try tx.commit();
                defer committed.deinit(gpa);
                log.deinit();
                log = committed.patch_log.take();
            }
            var target = try manual(gpa);
            defer target.deinit();
            target.setActorId(.{ .bytes = "cccccc" });
            if (nonempty) _ = try commitPut(gpa, &target, "base", .{ .int = 3 });
            const before = try target.saveWithOptions(gpa, .{ .deflate = false, .retain_orphans = true });
            defer gpa.free(before);
            const before_heads = try target.getHeads(gpa);
            defer gpa.free(before_heads);
            const actor = target.actor;
            const actor_count = target.numActors();
            const rows = target.ops.len();
            const identity = target.patchIdentity();
            const log_identity = log.identity;
            const events = log.events.items;
            const actors = log.actors.items;
            var called = false;
            switch (route) {
                .current => try testing.expectError(error.PatchLogMismatch, Transaction.openWithPatchLog(gpa, &target, &log, null)),
                .scoped => try testing.expectError(error.PatchLogMismatch, Transaction.openWithPatchLog(gpa, &target, &log, before_heads)),
                .owned => {
                    var owned: OwnedTransaction = undefined;
                    try testing.expectError(error.PatchLogMismatch, owned.initWithPatchLog(gpa, &target, &log, null));
                },
                .closure => try testing.expectError(error.PatchLogMismatch, encloseWithPatchLog(void, gpa, &target, &log, &called, Context.body, null)),
            }
            try testing.expect(!called);
            try testing.expectEqualDeep(actor, target.actor);
            try testing.expectEqual(identity, target.patchIdentity());
            try testing.expectEqual(actor_count, target.numActors());
            try testing.expectEqual(rows, target.ops.len());
            try testing.expectEqualSlices(ChangeHash, before_heads, target.graph.getHeads());
            const after = try target.saveWithOptions(gpa, .{ .deflate = false, .retain_orphans = true });
            defer gpa.free(after);
            try testing.expectEqualSlices(u8, before, after);
            try testing.expect(log.recording);
            try testing.expectEqual(log_identity, log.identity);
            try testing.expectEqual(events.ptr, log.events.items.ptr);
            try testing.expectEqual(actors.ptr, log.actors.items.ptr);
            try testing.expectEqual(@as(usize, 1), log.events.items.len);
            try testing.expectEqual(@as(usize, 1), log.actors.items.len);
            try testing.expectEqualStrings("bbbbbb", log.actors.items[0].bytes);
            try testing.expectEqualStrings("owner", log.events.items[0].event.put_map.key);
            try testing.expectEqual(@as(i64, 1), log.events.items[0].event.put_map.value.scalar.int);
            try testing.expectEqual(@as(usize, 0), log.completed.len());
            try testing.expect(log.checkpoint == null);
            try testing.expect(log.speculative_actor == null);
            _ = try commitPut(gpa, &target, "still owned", .{ .int = 2 });
            var published = try owner.makePatches(&log);
            defer published.deinit();
            try testing.expectEqual(@as(usize, 1), published.len());
        }
    }
}

test "owned logged commit and rollback return their active log owner" {
    for ([_]bool{ true, false }) |do_commit| {
        const gpa = testing.allocator;
        var source = try manual(gpa);
        var log = @import("patches.zig").PatchLog.active(gpa);
        defer log.deinit();
        var owned: @import("transaction.zig").OwnedTransaction = undefined;
        try owned.initWithPatchLog(gpa, &source, &log, null);
        // The testing allocator does not inject allocation failure during cleanup.
        defer owned.deinit() catch unreachable;
        try testing.expect(!log.recording);
        _ = try owned.transaction.put(.root, .{ .key = "logged" }, .{ .int = 3 });
        if (do_commit) {
            var completed = try owned.commit(.none);
            defer completed.document.deinit();
            defer completed.result.deinit(gpa);
            try testing.expect(completed.result.patch_log.recording);
            var published = try completed.document.makePatches(&completed.result.patch_log);
            defer published.deinit();
            try testing.expectEqual(@as(usize, 1), published.len());
            _ = try commitPut(gpa, &completed.document, "new journal", .{ .int = 4 });
        } else {
            var restored = try owned.rollback();
            defer restored.document.deinit();
            defer restored.patch_log.deinit();
            try testing.expect(restored.patch_log.recording);
            try testing.expectEqual(@as(usize, 1), restored.cancelled);
            try testing.expect((try readmod.get(&restored.document, .root, .{ .key = "logged" })) == null);
            _ = try commitPut(gpa, &restored.document, "new journal", .{ .int = 4 });
        }
    }
}

test "owned logged allocation refusal leaves document and active log for retry" {
    const gpa = testing.allocator;
    var failing = testing.FailingAllocator.init(gpa, .{});
    var source = try manual(failing.allocator());
    const identity_before = source.patchIdentity();
    var log = @import("patches.zig").PatchLog.active(gpa);
    defer log.deinit();
    var owned: @import("transaction.zig").OwnedTransaction = undefined;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, owned.initWithPatchLog(failing.allocator(), &source, &log, null));
    try testing.expectEqual(identity_before, source.patchIdentity());
    try testing.expectEqual(@as(usize, 0), source.ops.len());
    try testing.expect(log.recording);
    failing.fail_index = std.math.maxInt(usize);
    try owned.initWithPatchLog(failing.allocator(), &source, &log, null);
    // Failure injection is disabled for terminal cleanup.
    defer owned.deinit() catch unreachable;
    var completed = try owned.commit(.none);
    defer completed.document.deinit();
    defer completed.result.deinit(gpa);
    try testing.expect(completed.result.hash == null);
    try testing.expect(completed.result.patch_log.recording);
}

test "retained historical map walk and clock survive more than sixty four other scopes" {
    // Build all history and pending rows before borrowing either historical
    // resource. The query storm changes only the scope cache, never raw ops.
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    var history: [70][1]ChangeHash = undefined;
    for (&history, 0..) |*at, version| {
        var seed = try Transaction.open(gpa, &doc);
        // The testing allocator does not inject allocation failure during cleanup.
        defer seed.deinit() catch unreachable;
        _ = try seed.put(.root, .{ .key = "version" }, .{ .int = @intCast(version) });
        if (version == 0) {
            _ = try seed.put(.root, .{ .key = "oldonly" }, .{ .int = 10 });
        } else if (version == 1) {
            _ = try seed.delete(.root, .{ .key = "oldonly" });
            _ = try seed.put(.root, .{ .key = "newonly" }, .{ .int = 20 });
        }
        var committed = try seed.commit();
        defer committed.deinit(gpa);
        at.* = .{committed.hash.?};
    }
    var tx = try Transaction.openAt(gpa, &doc, &history[0]);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    _ = try tx.put(.root, .{ .key = "pending" }, .{ .int = 30 });
    const old_item = (try tx.getAt(.root, .{ .key = "version" }, &history[0])).?;
    const later_item = (try tx.getAt(.root, .{ .key = "version" }, &history[69])).?;
    const old_op = old_item.id.opId().?;
    const later_op = later_item.id.opId().?;
    const borrowed_clock = try doc.clockAtScope(gpa, &history[0]);
    var retained = try tx.mapRangeAt(.root, .{}, &history[0]);
    for (history[1..], 1..) |*at, version| {
        const item = (try tx.getAt(.root, .{ .key = "version" }, at)).?;
        try testing.expectEqual(@as(i64, @intCast(version)), item.value.scalar.int);
        try testing.expect((try tx.getAt(.root, .{ .key = "pending" }, at)) == null);
    }
    try testing.expect(borrowed_clock.contains(old_op));
    try testing.expect(!borrowed_clock.contains(later_op));
    const old_only = (try retained.next()).?;
    try testing.expectEqualStrings("oldonly", old_only.key);
    try testing.expectEqual(@as(i64, 10), old_only.value.scalar.int);
    const old_version = (try retained.next()).?;
    try testing.expectEqualStrings("version", old_version.key);
    try testing.expectEqual(@as(i64, 0), old_version.value.scalar.int);
    try testing.expect((try retained.next()) == null);
    _ = try tx.rollback();
}

test "hydrate at current committed heads includes pending rows while getAt excludes them" {
    // The Rust raw hydration shortcut is intentionally distinct from ordinary
    // explicit historical reads, even when both receive the same committed head.
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();
    const committed_head = try commitPut(gpa, &doc, "old", .{ .int = 1 });
    var tx = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer tx.deinit() catch unreachable;
    _ = try tx.put(.root, .{ .key = "pending" }, .{ .int = 2 });
    try testing.expect((try tx.getAt(.root, .{ .key = "pending" }, &.{committed_head})) == null);
    var explicit = try tx.hydrate(.root, &.{committed_head}, gpa);
    defer explicit.deinit();
    var current = try tx.hydrate(.root, null, gpa);
    defer current.deinit();
    try testing.expectEqual(@as(i64, 1), explicit.object.map.get("old").?.int);
    try testing.expectEqual(@as(i64, 2), explicit.object.map.get("pending").?.int);
    try testing.expectEqual(@as(i64, 1), current.object.map.get("old").?.int);
    try testing.expectEqual(@as(i64, 2), current.object.map.get("pending").?.int);
    _ = try tx.rollback();
}

test "scoped pending text insertion is resident before ordinary reads" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    var seed = try Transaction.open(gpa, &doc);
    // The testing allocator does not inject allocation failure during cleanup.
    defer seed.deinit() catch unreachable;
    const text = try seed.putObject(.root, .{ .key = "text" }, .text);
    try seed.spliceText(text, 0, 0, "old");
    var first = try seed.commit();
    defer first.deinit(gpa);
    const h1 = first.hash.?;

    var update = try Transaction.open(gpa, &doc);
    defer update.deinit() catch unreachable;
    try update.updateText(text, "new");
    var second = try update.commit();
    defer second.deinit(gpa);
    const current_before = try readmod.text(&doc, text, gpa);
    defer gpa.free(current_before);
    try testing.expectEqualStrings("new", current_before);

    var scoped = try Transaction.openAt(gpa, &doc, &.{h1});
    defer scoped.deinit() catch unreachable;
    try scoped.spliceText(text, 3, 0, "!");

    // Observe the producer boundary before any reader can materialize or
    // repair the pending insertion, and before any later write or commit.
    try testing.expectEqual(@as(usize, 1), scoped.pending.items.len);
    const pending = &scoped.pending.items[0].tx;
    const pending_id = pending.id();
    const position = (try doc.ops.getOpIdPos(pending_id)) orelse return error.RowMissing;
    const row = (try doc.ops.get(position)) orelse return error.RowMissing;
    try testing.expect(row.id().eql(pending_id));
    try testing.expect(row.objId().eql(doc.ops.resolveObjId(text).?));
    try testing.expect(row.objId().eql(pending.objId()));
    try testing.expect(row.value().eql(.{ .str = "!" }));
    try testing.expect(row.value().eql(pending.value()));
    try testing.expect(row.insert());
    try testing.expectEqual(pending.insert(), row.insert());
    try testing.expectEqual(pending.action(), row.action());
    try testing.expect(row.key().eql(pending.key()));
    try testing.expectEqual(scoped.actor, pending_id.actor);
    try testing.expectEqual(pending_id.actor, row.id().actor);

    const scoped_text = try scoped.text(text, gpa);
    defer gpa.free(scoped_text);
    try testing.expectEqualStrings("old!", scoped_text);
    try testing.expectEqual(@as(usize, 4), try scoped.length(text));
    const historical_text = try scoped.textAt(text, &.{h1}, gpa);
    defer gpa.free(historical_text);
    try testing.expectEqualStrings("old", historical_text);
    const current_text = try readmod.text(&doc, text, gpa);
    defer gpa.free(current_text);
    // H2 remains present in the raw current view; concurrent insertion order
    // is not part of this scoped-reader regression.
    try testing.expect(std.mem.indexOf(u8, current_text, current_before) != null);
}

test "logged closure reuses a compatible fork log and returns its ordered prefix" {
    // Wrappers inherit actor compatibility and transfer the original allocator.
    const Context = struct {
        fn body(_: void, tx: *Transaction) !void {
            _ = try tx.put(.root, .{ .key = "local" }, .{ .int = 2 });
        }
    };
    const gpa = testing.allocator;
    var owner = try manual(gpa);
    defer owner.deinit();
    var log = @import("patches.zig").PatchLog.active(gpa);
    defer log.deinit();
    {
        var tx = try Transaction.openWithPatchLog(gpa, &owner, &log, null);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "prefix" }, .{ .int = 1 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
        log.deinit();
        log = committed.patch_log.take();
    }
    var fork = try owner.fork(gpa);
    defer fork.deinit();
    fork.setActorId(owner.getActorId());
    const allocator = log.gpa;
    var outcome = try encloseWithPatchLog(void, gpa, &fork, &log, {}, Context.body, null);
    try testing.expect(!log.recording);
    switch (outcome) {
        .success => |*success| {
            defer success.patch_log.deinit();
            try testing.expect(success.hash != null);
            try testing.expectEqual(allocator.ptr, success.patch_log.gpa.ptr);
            try testing.expectEqual(@as(usize, 2), success.patch_log.events.items.len);
            try testing.expectEqualStrings("prefix", success.patch_log.events.items[0].event.put_map.key);
            try testing.expectEqualStrings("local", success.patch_log.events.items[1].event.put_map.key);
            var published = try fork.makePatches(&success.patch_log);
            defer published.deinit();
            try testing.expectEqual(@as(usize, 2), published.len());
        },
        .failure => |*failure| {
            defer failure.patch_log.deinit();
            if (failure.transaction) |*tx| {
                defer tx.deinit() catch unreachable;
                _ = try tx.rollback();
            }
            return error.ExpectedSuccess;
        },
    }
}
