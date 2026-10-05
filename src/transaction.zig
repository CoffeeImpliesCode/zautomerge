//! The manual door: a transaction the caller opens, writes through, and
//! finishes.
//!
//! Upstream is four files, and this is the two of them that are about
//! *finishing* a transaction rather than about making the operations in it:
//!
//! | what | upstream |
//! |------|----------|
//! | `Transaction<'a>`, `commit`, `commit_with`, `rollback`, `Drop` | [`transaction/manual_transaction.rs:20-145`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs) |
//! | `commit_transaction`, `Result<O, E>` | [`transaction.rs:18-31`](../../github-automerge-automerge/rust/automerge/src/transaction.rs), [`:16`](../../github-automerge-automerge/rust/automerge/src/transaction.rs) |
//! | `CommitOptions` and its four builders | [`transaction/commit.rs:1-34`](../../github-automerge-automerge/rust/automerge/src/transaction/commit.rs) |
//! | `Success<O>`, `Failure<E>` | [`transaction/result.rs:4-21`](../../github-automerge-automerge/rust/automerge/src/transaction/result.rs) |
//! | `Automerge::transact`, `transact_with`, `transact_with_impl` | [`automerge.rs:584-629`](../../github-automerge-automerge/rust/automerge/src/automerge.rs) |
//!
//! The bodies of the operations are [`transact.zig`](transact.zig)'s. This
//! file reimplements none of them, and its last section says which method of
//! `API.md`'s `## Write` cannot be reached from here and why.
//!
//! # `transaction.rs` declares no trait, and neither does this file
//!
//! Upstream's `transaction.rs` is a **module root**: seven `mod` lines, four
//! re-exports, a `Result` alias, one private function and two `macro_rules!`
//! ([`transaction.rs:1-31`](../../github-automerge-automerge/rust/automerge/src/transaction.rs),
//! [`:36-528`](../../github-automerge-automerge/rust/automerge/src/transaction.rs)).
//! There is no `Transaction` trait. The two macros — which *are* the `ReadDoc`
//! and `Transactable` implementations for two types, and so are public API —
//! are the only thing `transaction.rs` "declares". Upstream therefore reaches
//! one write surface through two types and two macro expansions; this port
//! reaches one through one type and a [`Mode`](doc.zig) flag, and the flavour
//! is checked where the caller walks through the door.
//!
//! # `transact.Transaction` *is* the manual transaction, and is not wrapped
//!
//! Upstream has two types here.
//! [`TransactionInner`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):22-33
//! is the state and every write body; [`Transaction<'a>`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs):21-27
//! is `Option<TransactionInner>` plus `&'a mut Automerge`, and it exists for
//! two reasons: the borrow has to be held somewhere, and the `Option` is what
//! lets `commit`, `rollback` and `Drop` each apply exactly once.
//!
//! **This port's [`transact.Transaction`](transact.zig) is both of those at
//! once** — it holds the `*Document`, and its `closed` flag
//! ([`transact.zig:315-319`](transact.zig)) stands in for the `Option`. A
//! wrapper here would be twenty forwarding methods and a second name for each,
//! which is the defect [`docs/STATUS.md`](../docs/STATUS.md) records as the
//! port's most transferable lesson. So this file **re-exports** the type and
//! adds what `transact.zig` deliberately does not own:
//!
//! * [`CommitOptions`], [`Success`], [`Failure`] and [`Outcome`], which are
//!   [`transaction.rs`](../../github-automerge-automerge/rust/automerge/src/transaction.rs)'s
//!   own vocabulary and appear nowhere else in the port;
//! * [`enclose`] and [`encloseWith`], the closure form, which is the one way
//!   upstream reaches a manual transaction through a function rather than
//!   through a value;
//! * [`abort`], the `Drop` rule made explicit, because Zig has no `Drop`;
//! * [`commitWith`], the commit path, and the one place where this port and
//!   upstream part company — see its own doc comment;
//! * the accessors [`actorId`], [`maxOp`], [`heads`], [`hashForOpid`],
//!   [`changeMeta`], [`depIndices`] and [`authorFooter`].
//!
//! # The two decisions this file inherits
//!
//! **A pending operation is [`opmod.TxOp`](opset/op.zig) and nothing else**,
//! because a rollback needs the row, the successor edges and the register
//! range, and a `ChangeOp` carries none of the three
//! ([`inner.rs:22-33`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
//! [`op_set.rs:246-257`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
//! **The transaction writes rows as it goes; `commit` only encodes and links**
//! ([`inner.rs:308-328`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
//! so every operation [`enclose`] produces is already a row in the document
//! before [`commitWith`] is reached — and the test
//! `test "the commit path on a manual document: the change's bytes hash to the
//! hash commit returned, and the transaction's operations are the document's"`
//! is the one that would catch a re-introduced duplicate splice.
//!
//! # The commit path, and the one place the port is visibly different
//!
//! Upstream's `commit_impl` exports **this transaction's** pending operations
//! and links the change built from them
//! ([`inner.rs:157-170`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
//! and `export` resolves **this transaction's** `deps`
//! ([`inner.rs:197-207`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
//! `Document.commit` uses the transaction's original actor, sequence, start
//! counter and dependencies. `commitWith` temporarily installs its read scope
//! for patch generation; it does not re-derive change metadata.
//!
//! # Ownership
//!
//! * [`enclose`], [`encloseWith`] and [`heads`] take the allocator the caller
//!   funds. [`commitWith`] takes **none**, because
//!   [`Document.integrate`](doc.zig) frees the isolation with
//!   [`Document.gpa`](doc.zig) and a caller cannot fund a buffer this
//!   document will free.
//! * [`heads`], [`depIndices`] and [`authorFooter`] return **caller-owned**
//!   arrays; the caller frees them with the allocator it was given.
//! * [`changeMeta`] **allocates nothing**. Its `message` borrows the
//!   transaction's own borrowed message and is valid until
//!   [`Transaction.deinit`](transact.zig); its `footer` is empty and
//!   [`authorFooter`] is the separate upstream function that fills it.
//! * The lifecycle — [`commitWith`], [`abort`] — makes no allocation.
//!   [`Transaction.deinit`](transact.zig) is still the one free, and it still
//!   does **not** roll back
//!   ([`transact.zig:349-353`](transact.zig)): upstream's `Drop` does
//!   ([`manual_transaction.rs:135-145`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)),
//!   and [`abort`] is how a Zig caller says which.

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

/// The manual transaction: upstream's `Transaction<'a>`
/// ([`manual_transaction.rs:21-27`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs))
/// and its [`TransactionInner`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):22-33
/// in one type, which is what [`transact.zig`](transact.zig) already has.
///
/// **The door is [`Transaction.open`](transact.zig)**, and it refuses a
/// document in [`Mode.auto`](doc.zig) with `error.InvalidOp`. An isolated
/// transaction is [`Transaction.openAt`](transact.zig), which is upstream's
/// `Automerge::transaction_at`
/// ([`automerge.rs:501-509`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and, through it, `isolate_actor`
/// ([`:1259-1281`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// which this port is [`Document.isolatedActorIndex`](doc.zig).
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

/// A committed transaction's result
/// ([`Success<O>`](../../github-automerge-automerge/rust/automerge/src/transaction/result.rs):6-12).
///
/// The document retains its patch log; this result owns only `result`.
/// Disposal of `result` follows `O`'s contract.
pub fn Success(comptime O: type) type {
    return struct {
        /// Whatever the closure returned.
        result: O,
        /// The hash of the change this transaction committed, or null when it
        /// wrote no operations
        /// ([`result.rs:9-10`](../../github-automerge-automerge/rust/automerge/src/transaction/result.rs)).
        hash: ?ChangeHash,
    };
}

/// Body or commit refusal, with rollback progress and recovery ownership.
/// `err` always names the primary refusal; `rollback_error` never replaces it.
/// If rollback fails, this value owns `transaction`. Retry its rollback and
/// dispose it exactly once before disposing or mutating the borrowed document.
/// `result` is the body's owned result when only commit failed, otherwise null.
pub fn Failure(comptime O: type) type {
    return struct {
        /// Primary body or commit error.
        err: TransactionError,
        /// Operations successfully undone, including partial rollback progress.
        cancelled: usize,
        /// Secondary rollback refusal, or null after complete rollback.
        rollback_error: ?TransactionError = null,
        /// Recovery owner after rollback refusal; null on complete rollback.
        transaction: ?Transaction = null,
        /// Body result retained after a refused commit; dispose as required by O.
        result: ?O = null,
    };
}

/// What [`enclose`] answers: upstream's
/// `Result<O, E> = Result<Success<O>, Failure<E>>`
/// ([`transaction.rs:16`](../../github-automerge-automerge/rust/automerge/src/transaction.rs)),
/// as a tagged union, because an error union cannot carry a value and the whole
/// point of this form is that it does.
pub fn Outcome(comptime O: type) type {
    return union(enum) {
        /// The closure returned; the transaction committed.
        success: Success(O),
        /// Body or commit refused; inspect rollback progress and recovery owner.
        failure: Failure(O),
    };
}

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
/// hash [`commitWith`] returned names the change, and `change.max_op` is its
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
/// Null for the three cases upstream lists
/// ([`manual_transaction.rs:41-43`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)):
/// the root object id, an id the document does not hold, and **an operation
/// this transaction has written and not yet committed** — which is the third
/// of the three and the one only the manual door reaches.
///
/// **This is upstream's own call, and it is a delegation.**
/// [`Automerge::hash_for_opid`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1559-1567
/// is the `ExId::Root` arm and then `self.change_graph.opid_to_hash(opid)`
/// (`:1563-1564`), and [`ChangeGraph::opid_to_hash`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):300-318
/// binary-searches `seq_index[actor]` for the change whose
/// `[start_op, max_op]` holds the counter. This port's
/// [`ChangeGraph.opidToHash`](change_graph.zig) **is** that function, already
/// `pub` and already the port of `change_graph.rs:300-320`, so this is the same
/// answer the reference gives at the same cost: **`O(log` changes by that
/// actor)`, not `O(changes in the document)`.**
///
/// **It used to walk the node table**, and the reason is worth keeping: this
/// file was written before `opidToHash` had a `pub` door, so it reimplemented
/// the interval test over `nodes` — `O(C)` in the whole graph, where `C` is
/// every change the document has ever seen rather than the ones this actor
/// wrote. The two agree on every counter because both reduce to "the node whose
/// `[start_op, max_op]` contains the counter, and there is at most one", which
/// is why the rewiring changes no answer. The test
/// `test "hashForOpid answers a many-change document as the graph's own
/// interval query does, and answers every null upstream lists"` is the witness
/// that they still agree, over two hundred changes and two alternating actors.
pub fn hashForOpid(tx: *const Transaction, id: ExId) ?ChangeHash {
    const op = id.opId() orelse return null; // ExId::Root
    return tx.doc.graph.opidToHash(op);
}

/// This transaction's dependencies as **node indices**, **caller-owned** and
/// freeable with `gpa`
/// ([`export`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):197-207,
/// `deps.iter().filter_map(|hash| change_graph.hash_to_index(hash))`).
///
/// **A dependency the graph does not hold is dropped, with no error.** That is
/// upstream's `filter_map` and it is a real hazard rather than an oversight —
/// [`docs/survey/02-transaction-opset.md`](../docs/survey/02-transaction-opset.md)
/// §risks records it, and a dependency that disappears from a header is a
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

/// Commits what this transaction has done, with `options`
/// ([`Transaction::commit_with`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs):91-96).
///
/// **This was where the port and upstream parted company, and the parting is
/// over.** Upstream exports *this transaction's* pending operations under
/// *this transaction's* metadata
/// ([`inner.rs:157-170`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
/// [`:197-207`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
/// and [`Transaction.commit`](transact.zig) now hands those four facts to
/// [`Document.commit`](doc.zig) rather than having the document re-derive
/// them from `Document.isolation`.
///
/// **So the scope swap below is no longer what makes a scoped commit
/// correct, and it is not what it was for.** It used to be the only thing
/// standing between a scoped transaction and a change that named the wrong
/// actor and the document refused to read back — and it was here because
/// [`Document.commit`](doc.zig) could not be edited from this file. What
/// remains is the part that is genuinely this function's: **it leaves the
/// document's isolation exactly as it found it**, which
/// [`Document.dropIsolation`](doc.zig) alone cannot promise.
///
/// **The document's own allocator, and no parameter for one**:
/// [`Document.integrate`](doc.zig) frees the isolation with
/// [`Document.gpa`](doc.zig), so a caller cannot fund those buffers.
///
/// **Null for a transaction that wrote nothing**, which is upstream's answer
/// ([`inner.rs:135-142`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
/// and not a degenerate case: an empty `put` writes no operation
/// ([`op_set.rs:1489-1492`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
/// Such a transaction never reaches the scope handling at all, because there
/// is nothing for the scope to be applied to and upstream returns before
/// `commit_impl` too.
pub fn commitWith(tx: *Transaction, options: CommitOptions) TransactionError!?ChangeHash {
    if (tx.scope_heads == null and tx.doc.isolationHeads() == null) {
        return tx.commit(options.message, options.time);
    }
    if (tx.pending.items.len == 0) {
        return tx.commit(options.message, options.time);
    }

    const doc = tx.doc;
    const gpa = doc.gpa;
    const saved: ?[]ChangeHash = blk: {
        const at = doc.isolationHeads() orelse break :blk null;
        break :blk try gpa.dupe(ChangeHash, at);
    };
    // **`dropIsolation`, not `integrate`, on both sides of the swap** — this is
    // a scope swap and not a caller's isolate/integrate round trip. Upstream
    // has no such dance (`AutoCommit` scopes a transaction when it opens it,
    // `autocommit.rs:447`, rather than rewinding the document to do it), so
    // there is no upstream `patch_to` here to mirror and routing it through
    // [`Document.integrate`](doc.zig) would put a spurious view transition
    // into the log of every isolated commit. The `try doc.isolate` below is
    // still [`Document.isolate`](doc.zig) and still replays a transition: that
    // one *is* a caller-visible scope change.
    doc.dropIsolation();
    defer {
        doc.dropIsolation();
        if (saved) |back| doc.isolation = back;
    }
    if (tx.scope_heads) |at| try doc.isolate(gpa, at);
    return tx.commit(options.message, options.time);
}

/// Idempotent rollback: closed transactions are unchanged.
/// On refusal, retry before disposal. Unlike Rust's `Drop`, disposal does not
/// imply rollback (`manual_transaction.rs:135-145`). Dispose after abort:
/// `defer tx.deinit();` then an explicit fallible `abort(&tx)` before return.
pub fn abort(tx: *Transaction) TransactionError!void {
    if (tx.closed) return;
    _ = try tx.rollback();
}

/// Runs `body` synchronously on the calling thread. The context and document
/// remain borrowed through return. `body` may use the supplied transaction;
/// it must not reenter the document through another write entry point or retain
/// the transaction pointer. A manual-mode document is required.
///
/// Success commits. Body or commit refusal returns `Outcome.failure` without
/// losing the primary error. Complete rollback disposes the transaction;
/// rollback refusal transfers it to the failure result for caller recovery.
/// Opening the transaction can itself return an error without invoking `body`.
/// Pending native automatic recovery is refused with `error.InvalidOp` before
/// `body` runs; finish it through `Document.recoverAuto` first.
/// Upstream closure contract: `automerge.rs:603-629`.
pub fn enclose(
    comptime O: type,
    gpa: Allocator,
    doc: *Document,
    ctx: anytype,
    body: *const fn (@TypeOf(ctx), *Transaction) TransactionError!O,
) TransactionError!Outcome(O) {
    return encloseWith(O, gpa, doc, ctx, body, null);
}

/// `enclose`, with options derived synchronously after body success and before
/// commit, on the calling thread. Null selects `CommitOptions.none`.
/// The callback borrows `ctx` and `result` only during the call; it must not
/// mutate/reenter the document. Message bytes must remain live through commit.
pub fn encloseWith(
    comptime O: type,
    gpa: Allocator,
    doc: *Document,
    ctx: anytype,
    body: *const fn (@TypeOf(ctx), *Transaction) TransactionError!O,
    options: ?*const fn (@TypeOf(ctx), O) CommitOptions,
) TransactionError!Outcome(O) {
    var tx = try Transaction.open(gpa, doc);
    var transferred = false;
    defer if (!transferred) tx.deinit();
    const result = body(ctx, &tx) catch |primary| {
        const cancelled = tx.rollback() catch |secondary| {
            transferred = true;
            return .{ .failure = .{
                .err = primary,
                .cancelled = tx.cancelled,
                .rollback_error = secondary,
                .transaction = tx,
            } };
        };
        return .{ .failure = .{ .err = primary, .cancelled = cancelled } };
    };
    const opts = if (options) |derive| derive(ctx, result) else CommitOptions.none;
    const hash = commitWith(&tx, opts) catch |primary| {
        const cancelled = tx.rollback() catch |secondary| {
            transferred = true;
            return .{ .failure = .{
                .err = primary,
                .cancelled = tx.cancelled,
                .rollback_error = secondary,
                .transaction = tx,
                .result = result,
            } };
        };
        return .{ .failure = .{ .err = primary, .cancelled = cancelled, .result = result } };
    };
    return .{ .success = .{ .result = result, .hash = hash } };
}

// ── tests ────────────────────────────────────────────────────────────────────

/// A document in [`Mode.manual`] with a fixed actor, which is the only flavour
/// [`Transaction.open`](transact.zig) accepts.
fn manual(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, std.testing.io, .manual);
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
    defer tx.deinit();
    _ = try tx.put(.root, .{ .key = key }, value);
    return (try commitWith(&tx, CommitOptions.none)).?;
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
    defer tx.deinit();
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

    const hash = (try commitWith(&tx, CommitOptions.none.withMessage("m").withTime(7))).?;
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
    defer tx.deinit();
    _ = try tx.put(.root, .{ .key = "k" }, .{ .str = "v" });
    const list = try tx.putObject(.root, .{ .key = "l" }, .list);
    _ = try tx.insert(list, 0, .{ .int = 7 });
    const text = try tx.putObject(.root, .{ .key = "t" }, .text);
    try tx.spliceText(text, 0, 0, "hi");
    const hash = (try commitWith(&tx, CommitOptions.none.withMessage("m"))).?;

    var before = (try doc.getChangeByHash(gpa, hash)).?;
    defer before.deinit(gpa);

    // **The document's own bytes carry the change, and a load rebuilds it
    // byte for byte.** A change whose bytes the document cannot reproduce is a
    // change whose hash a peer cannot check, so the round trip is the strongest
    // thing a commit can be held to that does not need the reference.
    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, std.testing.io, saved, doc.textEncoding(), .manual);
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
    var before = try doc.clone(gpa, .manual);
    defer before.deinit();
    const before_rows = before.ops.len();
    const before_nodes = before.graph.len();
    const before_heads = before.graph.getHeads();

    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit();
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
    defer tx.deinit();
    const list = try tx.putObject(.root, .{ .key = "l" }, .list);
    _ = try tx.insert(list, 0, .{ .int = 1 });
    _ = try tx.insert(list, 1, .{ .int = 2 });
    const text = try tx.putObject(.root, .{ .key = "t" }, .text);
    try tx.spliceText(text, 0, 0, "hello");
    try tx.mark(text, 1, 3, "em", .both, .{ .bool_value = true });
    _ = try tx.put(.root, .{ .key = "hits" }, .{ .counter = .init(5) });
    _ = try commitWith(&tx, CommitOptions.none);
    return list;
}

test "an isolated transaction commits with its own dependencies and its own actor" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    const first = try commitPut(gpa, &doc, "a", .{ .int = 1 });
    _ = try commitPut(gpa, &doc, "b", .{ .int = 2 });

    var tx = try Transaction.openAt(gpa, &doc, &.{first});
    defer tx.deinit();

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

    const hash = (try commitWith(&tx, CommitOptions.none)).?;
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
        defer tx.deinit();
        _ = try tx.put(.root, .{ .key = "iso" }, .{ .int = 3 });

        const claimed = (try tx.commit(null, null)).?;
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

    // **And `commitWith` still produces a readable change with the
    // transaction's own dependencies — and restores the document's isolation
    // to what it was**, which is the part of it that is still its own and not
    // a workaround. The readability used to be the reason the function
    // existed; it is now a property of every commit
    // ([`Transaction.commit`](transact.zig)), and this block is here to say
    // the two paths still agree.

    {
        var doc = try manual(gpa);
        defer doc.deinit();
        const first = try commitPut(gpa, &doc, "a", .{ .int = 1 });
        _ = try commitPut(gpa, &doc, "b", .{ .int = 2 });
        try doc.isolate(gpa, &.{first});

        var tx = try Transaction.openAt(gpa, &doc, &.{first});
        defer tx.deinit();
        _ = try tx.put(.root, .{ .key = "iso" }, .{ .int = 3 });
        const hash = (try commitWith(&tx, CommitOptions.none)).?;

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
        fn options(_: Ctx, result: i64) CommitOptions {
            var opts = CommitOptions{};
            opts.setMessage("from result");
            opts.setTime(result);
            return opts;
        }
    }.options;

    {
        var doc = try manual(gpa);
        defer doc.deinit();

        const ok = try encloseWith(i64, gpa, &doc, Ctx{ .key = "k", .value = 21, .fail = false }, body, derive);
        switch (ok) {
            .success => |s| {
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
        // **And the document is left with no transaction in it**, which is
        // what upstream gets by moving the inner into `commit`.
        try testing.expectEqual(@as(usize, 0), transact.pendingOps(&doc));
    }

    {
        var doc = try manual(gpa);
        defer doc.deinit();
        var before = try doc.clone(gpa, .manual);
        defer before.deinit();

        const bad = try enclose(i64, gpa, &doc, Ctx{ .key = "k", .value = 1, .fail = true }, body);
        switch (bad) {
            .success => return error.ExpectedFailure,
            .failure => |f| {
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
    var before = try doc.clone(gpa, .manual);
    defer before.deinit();

    {
        var tx = try Transaction.open(gpa, &doc);
        defer tx.deinit();
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
        defer tx.deinit();
        _ = try tx.put(.root, .{ .key = "b" }, .{ .int = 2 });
        _ = try commitWith(&tx, CommitOptions.none);
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
    defer tx.deinit();
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
    const hash = (try commitWith(&tx, CommitOptions.none)).?;
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
        defer tx.deinit();
        try testing.expectEqual(tx.start_op - 1, try maxOp(&tx));
        try testing.expect((try commitWith(&tx, CommitOptions.none)) == null);
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
        defer tx.deinit();
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
    defer tx.deinit();
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

    const hash = (try commitWith(&tx, CommitOptions.none.withMessage("hello"))).?;
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
        defer tx.deinit();
        try testing.expectEqual(@as(u64, 1), tx.seq);
        const footer = try authorFooter(gpa, &tx);
        defer gpa.free(footer);
        try testing.expect(footer.len > 0);
        _ = try tx.put(.root, .{ .key = "a" }, .{ .int = 1 });
        _ = try commitWith(&tx, CommitOptions.none);
    }
    {
        var tx = try Transaction.open(gpa, &doc);
        defer tx.deinit();
        try testing.expectEqual(@as(u64, 2), tx.seq);
        // **`automerge.rs:568` — the author is set only when `seq == 1`,**
        // so the second change of an actor has no footer at all.
        const footer = try authorFooter(gpa, &tx);
        defer gpa.free(footer);
        try testing.expectEqual(@as(usize, 0), footer.len);
        _ = try tx.put(.root, .{ .key = "b" }, .{ .int = 2 });
        const hash = (try commitWith(&tx, CommitOptions.none)).?;
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
    defer tx.deinit();
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
    defer tx.deinit();
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

    const hash = (try commitWith(&tx, CommitOptions.none)).?;
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
        defer tx.deinit();
        const key = try std.fmt.bufPrint(&key_buf, "k{d}", .{i});
        const id = (try tx.put(.root, .{ .key = key }, .{ .int = @intCast(i) })).?;
        last_hash = (try commitWith(&tx, CommitOptions.none)).?;
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
    defer probe.deinit();

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
    const committed = (try commitWith(&probe, CommitOptions.none)).?;
    try testing.expect(hashForOpid(&probe, doc.ops.idToExid(pending)).?.eql(committed));
}

test "the whole write surface of API.md's ## Write, driven from manual transactions" {
    const gpa = testing.allocator;
    var doc = try manual(gpa);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit();

    // **Every method of `API.md`'s `## Write` that the manual door can reach,
    // through the manual door**, so the assertions at the end are about the
    // surface and not about one method. `splice` and `init_root_from_hydrate`
    // are named in the diff block below: the first cannot be reached from this
    // module, and the second needs a root nothing has been written to.
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
    // **The map outlives the commit**, and that is a rule rather than a habit:
    // `updateMapValue` puts the caller's own key slices into the pending
    // operations, and the commit encodes the pending operations. Upstream
    // copies them ([`op.rs:187`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)
    // owns a `PropRef::Map(String)`); this port's op set borrows.
    const map = try hydratedMap(gpa);
    defer {
        map.deinit();
        gpa.destroy(map);
    }
    try tx.updateMapValue(hydrated, map);
    try testing.expectEqual(@as(usize, 1), tx.delete(.root, .{ .key = "name" }));
    try testing.expectEqual(@as(usize, 1), tx.delete(list, .{ .index = 0 }));

    // **`base_heads` and `pending_ops` are `Transactable` methods on this door
    // too** ([`transaction.rs:319-321`](../../github-automerge-automerge/rust/automerge/src/transaction.rs),
    // [`:455-460`](../../github-automerge-automerge/rust/automerge/src/transaction.rs)),
    // and the counts are the numbers they promise.
    try testing.expectEqual(@as(usize, 0), tx.baseHeads().len);
    try testing.expectEqual(tx.pending.items.len, tx.count());
    try testing.expectEqual(tx.pending.items.len, (try maxOp(&tx)) - tx.start_op + 1);

    const rows_before = doc.ops.len();
    _ = try commitWith(&tx, CommitOptions.none);
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

test "the wrong door is an error: a manual document is the only one a transaction opens on" {
    const gpa = testing.allocator;
    var auto = try Document.init(gpa, std.testing.io, .auto);
    defer auto.deinit();
    auto.setActorId(.{ .bytes = "0123456789abcdef" });

    // **`Transaction.open` refuses an autocommit document**, and this module's
    // entry points reach it, so `enclose` refuses one too.
    try testing.expectError(error.InvalidOp, Transaction.open(gpa, &auto));
    try testing.expectError(error.InvalidOp, Transaction.openAt(gpa, &auto, null));
    try testing.expectError(
        error.InvalidOp,
        enclose(void, gpa, &auto, {}, struct {
            fn run(_: void, _: *Transaction) TransactionError!void {
                return error.Fail;
            }
        }.run),
    );

    // **And nothing was written on the refusal**, which is the half that
    // matters: an error that leaves a document half-changed is worse than a
    // trap in a file that has already been read.
    try testing.expectEqual(@as(usize, 0), auto.graph.len());
    try testing.expectEqual(@as(usize, 0), auto.ops.len());
}

// ── Port differences ─────────────────────────────────────────────────────────
//
// What this file does differently from upstream's `transaction.rs`,
// `manual_transaction.rs`, `commit.rs` and `result.rs`, and why.
//
// 1. **The names in the slice brief are not upstream's, and this file follows
//    upstream's.** The brief describes a `Transaction` *trait* carrying
//    `enclose`, `isolate`, `commit`, `rollback`, `abort`, `actorId`,
//    `startOp`, `maxOp`, `heads` and `changeMeta`. Upstream `transaction.rs`
//    declares no trait at all — it is a module root with two `macro_rules!`
//    (`:1-31`, `:36-528`) — and of those ten names upstream has `commit`
//    (`manual_transaction.rs:67`), `rollback` (`:100`) and `change_meta`
//    (`inner.rs:174`). The other seven are nowhere in the reference. What this
//    file does, name by name:
//      * `enclose` is upstream's `Automerge::transact` / `transact_with`
//        (`automerge.rs:584-629`). The brief's name is a good one and is kept;
//        the behaviour is upstream's.
//      * `abort` is upstream's `impl Drop for Transaction`
//        (`manual_transaction.rs:135-145`). Zig has no `Drop`, so the rule is a
//        method, and idempotence is what makes it a `Drop`.
//      * `actorId` is upstream's `TransactionInner.actor` (`inner.rs:24`),
//        which is an actor *index*; the id is the same question
//        `Change::actor_id` (`change.rs:52`) asks. The index is still readable
//        as `Transaction.actor`.
//      * `startOp` is upstream's `start_op` field (`inner.rs:26`), already a
//        public field on the engine, so this file adds no function for it.
//      * `maxOp` is upstream's `max_op` as `change_meta` computes it
//        (`inner.rs:182`).
//      * `heads` is upstream's `Transaction::get_heads`
//        (`manual_transaction.rs:61-63`), which is **not** `base_heads`
//        (`transaction.rs:455-460`); the two are documented apart.
//      * `isolate` is upstream's `AutoCommit::isolate` (`autocommit.rs:433-437`),
//        already `Document.isolate` (`doc.zig:2646-2649`). For the *manual*
//        door it is `Transaction.openAt` — upstream's
//        `Automerge::transaction_at` (`automerge.rs:501-509`) over
//        `isolate_actor` (`:1259-1281`), which this port is
//        `Document.isolatedActorIndex` (`doc.zig:2596-2617`). **This file
//        declares no `isolate`**: a second door onto `Document.isolation`
//        would be a second source of truth for it, and `doc.zig` already owns
//        the state.
//
// 2. **`API.md`'s `## Write` names twenty methods, all of them
//    `doc: *Document`, and not one of them is a manual-transaction method.**
//    It says in a sentence that "a manual `Transaction` is a separate type that
//    borrows the document and commits or rolls back explicitly" and then lists
//    the autocommit door, which `transact.zig` has. Every one of the twenty is
//    a `Transactable` method, so every one is reachable on the manual door
//    through the engine's own methods — the port has no `Transactable` trait
//    and one type serves both flavours, which is [plan §3.2](../docs/plan.md)'s
//    answer to the macro question. The test `test "the whole write surface of
//    API.md's ## Write, driven from one manual transaction"` drives them
//    through the manual door so that the claim is checked rather than asserted.
//
// 3. **`splice` reaches the manual door through `transact.spliceHeld`, and it
//    took a fix to get there.** Upstream's `Transactable::splice` for a
//    `Transaction` is `TransactionInner::splice` (`inner.rs:606-645`) over a
//    batched `BatchInsertion` (`:1435-1520`). The engine has that body —
//    `Transaction.spliceListValues` — and the module-level
//    `transact.spliceHeld` now calls it — **but the `.list` arm was empty**, so
//    a splice of hydrated values into a *list* reported success and wrote no
//    operation and no change at all. Two tests said so: this tree's
//    `transact.test."a spliced list of hydrated values is written in two
//    batches"` failed on `expected 2, found 1` at its `doc.graph.len()`
//    assertion, and `upstream_doc_test."concurrent insertions at different list
//    positions"` was missing the element it had spliced. `inner.rs:633-642` is
//    the branch that takes them, and it is the engine's to take: a second
//    implementation of the splice walk in this file would be a second source
//    of truth for it. Every other method of `## Write` is exercised by the
//    test named in (2).
//
// 4. **`update_text` is not in that walk, because committing after it reads
//    freed memory — a defect in [`textdiff.zig`](textdiff.zig), not here.**
//    `TxHook::insert` and `TxHook::replace`
//    ([`textdiff.zig:771-783`](textdiff.zig)) join the new graphemes into a
//    freshly allocated buffer, hand it to `spliceText` — which records the
//    queued operations with slices **into** it, because
//    [`textUnits`](transact.zig) hands out sub-slices of its argument — and
//    free the buffer when the call returns (`defer self.gpa.free(new_chars)`).
//    The operations are encoded by the **commit**, so every operation
//    `update_text` writes points at freed memory from the moment the hook
//    returns. Reproduced: a transaction that calls `updateText` and then does
//    other work before committing **segfaults** in
//    `columnar/encoding.zig:1395` (`appendPayload`, `.str`) while encoding the
//    change; with the diff as the transaction's last write before the commit it
//    survives, which is why [`transact.zig`'s own `updateText` test]
//    (transact.zig:3255) does. **The fix is to stop freeing the joined buffer
//    there** — upstream's `TxHook::insert` builds a `String` and passes it
//    down by value, so there is no shared buffer to free
//    ([`text_diff.rs:122-133`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)).
//    Until that is fixed this file cannot test `update_text` on the manual
//    door without taking the whole test binary down with it, which is why the
//    walk in (2) stops short of it and the engine's own test stands in.
//
// 5. **`init_root_from_hydrate` is not in that walk either.** Upstream's
//    `batch_init_root_map` (`inner.rs:1334-1380`) writes the *root* map, so it
//    needs a root nothing has been written to, and the walk in (2) has already
//    written to it. The engine's `initRootFromHydrate` (`transact.zig:1405`)
//    carries upstream's test for it (`transact.zig:3208`).
//
// 6. `Success` contains the body result and change hash; the document retains
//    its patch log. `Failure(O)` preserves the primary error, a successful
//    body's result after commit refusal, and an owning recovery transaction
//    if rollback refuses.
//
// 7. **`CommitOptions.message` is borrowed, not owned.** Upstream holds an
//    `Option<String>` (`commit.rs:5`); the port's rule is that a borrow is valid
//    until the next mutation, and the caller's bytes go straight into the
//    encoded change, so they must outlive the call. `setMessage` and `setTime`
//    return `void` rather than a builder, because a Zig struct literal is the
//    mutation.
//
// 8. **The commit path takes the transaction's scope from the document and puts
//    it back.** Upstream's `export` resolves *the transaction's* `deps`
//    (`inner.rs:197-207`) and `commit_impl` exports *the transaction's* ops
//    (`:157-170`). This port's `Document.commit` (`doc.zig:3419-3477`) is handed
//    the operations and re-derives the metadata from a fresh
//    `transactionArgs` call scoped by `Document.isolation`, so a scoped
//    transaction committed through the engine alone produces a change that
//    claims another actor's operations and the document refuses it
//    (`error.Fail`). `commitWith` works around that by moving the scope for the
//    duration of the commit. **The fix belongs in `Document.commit`**, which
//    this file may not edit; the test `test "a scoped transaction's own commit
//    path: the engine's commit is refused, and commitWith restores the
//    isolation"` pins both halves so the workaround cannot be dropped silently.
//
// 9. **`hashForOpid` used to walk the node table; it is upstream's binary
//    search now.** Upstream's `ChangeGraph::opid_to_hash`
//    (`change_graph.rs:300-318`) binary-searches `seq_index[actor]`, and
//    `change_graph.zig` has carried that as the `pub` `opidToHash` since it
//    was written — the round-3 audit's "no public entry point" was wrong, and
//    so was the note here that `seq_index` is private. This file scanned
//    `nodes` instead, which is `O(C)` in the whole graph where upstream is
//    `O(log` changes by that actor `)`, and answered the same question. It now
//    delegates (`transaction.zig:433-436`), so **this is no longer a
//    divergence**; the note stays because the scan is the shape a reader
//    comparing the two files will still expect to find.
//
// 10. **`changeMeta` cannot carry the author footer, so `authorFooter` is
//    separate.** Upstream folds it in through `extra_bytes`
//    (`inner.rs:193-195`), which reads `TransactionInner.author` — a field
//    `TransactionArgs` computes at `seq == 1` (`automerge.rs:568`) and the
//    engine does not retain (`transact.zig:334-347` takes the other six fields
//    and lets the seventh go). `Document.commit` re-derives it from the same
//    rule (`doc.zig:2438`, `:3430-3432`), so `authorFooter` reproduces the same
//    bytes and the test asserts they are the ones the document stored.
//
// 11. **`enclose` takes a function and a context, not a closure.** Upstream
//     takes `F: FnOnce(&mut Transaction<'_>) -> Result<O, E>`
//     (`automerge.rs:588`). A Zig closure captures by value, and `encloseWith`'s
//     options function runs on the *result* while the transaction is still
//     open, so a capturing body would hand a context whose lifetime the caller
//     cannot see. The caller owns the context and must keep it alive across the
//     call.
//
// 12. **`OwnedTransaction` is not here.** Upstream's (`owned_transaction.rs:17-116`)
//     takes the document by value, and it has **no `Drop` impl** — the survey
//     records that an abandoned one leaks its pending operations into the op
//     set (`docs/survey/02-transaction-opset.md`, §1 *Drop*). Reproducing that
//     is a defect to copy, and the type needs the engine to point at a
//     `Document` the same struct owns, which the engine's `doc: *Document`
//     field cannot express. It is named here so it is not lost.
//
// 13. **`maxOp` is fallible, and the refusal is a decision rather than a
//     match.** Upstream's `Transaction` has **no `max_op` accessor at all**:
//     its public surface is `hash_for_opid` (`manual_transaction.rs:44-46`),
//     `get_heads` (`:61-63`), `commit` (`:67`), `commit_with` (`:91`) and
//     `rollback` (`:100`), plus `Transactable::pending_ops`
//     (`transactable.rs:11-12`) — a count. `change_meta` (`inner.rs:174`) is
//     `pub(crate)`, so this function renders a private field and the
//     signature is the port's to pick.
//
//     **The post-commit read cannot be asked upstream at all.** `commit`,
//     `commit_with` and `rollback` take `self` by value
//     (`manual_transaction.rs:67`, `:91`, `:100`; `inner.rs:129-130`,
//     `:211-212`) and each moves the inner out of its `Option`
//     (`manual_transaction.rs:68`, `:92`, `:102`), so a spent transaction does
//     not exist. Here it does, and the arithmetic has an answer to give that
//     is not one: `commit` drains `pending` (`transact.zig:1344-1346`) and
//     `start_op + pending.len() - 1` then reads `start_op - 1`.
//
//     **So a closed transaction refuses with `error.InvalidOp`**, the same
//     answer `requireOpen` (`transact.zig:545-547`) gives a write and
//     `rollback` (`transact.zig:1357-1358`) gives a second application.
//     `pending.len()` is the wrong key to refuse on and not only because a
//     commit empties it: **a rollback does not**, and leaves the list full of
//     operations it has just taken back
//     ([`transact.zig:1356-1368`](transact.zig)) — so the arithmetic after a
//     rollback claims a counter the document has withdrawn and will never
//     hand out again. `closed` is the one flag that is true in all three
//     spent states and false in every live one.
//
//     **This is not the "one concept, two derivations" shape** the other
//     defects in this port have, and that is worth saying. The three
//     `max_op`s — the transaction's (`inner.rs:182`), the change's
//     (`change.rs:74-76`) and the graph's (`change_graph.rs:204-206`) — are
//     three questions upstream already names separately, and this port has
//     all three, derived once each. What the two failing tests had was a
//     **read at a time the question is not asked**: the transaction's answer
//     taken after the transaction was spent, and compared against the change's
//     answer, which is a different question with a real number. The two
//     numbers drifted apart by exactly the drained `pending` because one of
//     them was read in a state where it did not mean anything.

test "enclose preserves primary error and transfers failed rollback ownership" {
    const Context = struct {
        failing: *testing.FailingAllocator,
        body_fails: bool,

        fn body(ctx: *@This(), tx: *Transaction) TransactionError!usize {
            _ = try tx.put(.root, .{ .key = "one" }, .{ .int = 1 });
            _ = try tx.put(.root, .{ .key = "two" }, .{ .int = 2 });
            ctx.failing.fail_index = ctx.failing.alloc_index;
            if (ctx.body_fails) return error.InvalidValueType;
            return 77;
        }
    };
    for ([_]bool{ true, false }) |body_fails| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try Document.init(gpa, testing.io, .manual);
        defer doc.deinit();
        var ctx = Context{ .failing = &failing, .body_fails = body_fails };
        var outcome = try enclose(usize, gpa, &doc, &ctx, Context.body);
        failing.fail_index = std.math.maxInt(usize);
        switch (outcome) {
            .success => return error.ExpectedFailure,
            .failure => |*failure| {
                try testing.expectEqual(if (body_fails) error.InvalidValueType else error.OutOfMemory, failure.err);
                try testing.expectEqual(@as(?TransactionError, error.OutOfMemory), failure.rollback_error);
                try testing.expectEqual(if (body_fails) @as(?usize, null) else @as(?usize, 77), failure.result);
                const tx = &failure.transaction.?;
                defer tx.deinit();
                try testing.expectEqual(@as(usize, 2), try tx.rollback());
                try testing.expectEqual(@as(usize, 0), doc.graph.len());
                try testing.expect((try @import("read.zig").get(&doc, .root, .{ .key = "one" })) == null);
                try testing.expect((try @import("read.zig").get(&doc, .root, .{ .key = "two" })) == null);
            },
        }
    }
}
