//! The write surface: the bodies behind every method in `API.md`'s
//! [`## Write`](../API.md) section, and the pending-operation machinery they
//! all share.
//!
//! Upstream has no file like this. The twenty methods are
//! [`Transactable`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs)'s
//! declarations (`transaction/transactable.rs:9-181`) and the bodies live in
//! [`TransactionInner`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
//! which
//! `impl_read_doc_for_tx!` (`transaction.rs:37-315`) and
//! `impl_transactable_for_tx!` (`:317-526`) generate for
//! [`Transaction<'a>`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)
//! and [`OwnedTransaction`](../../github-automerge-automerge/rust/automerge/src/transaction/owned_transaction.rs).
//! **That macro output is public API and this port has no equivalent**, so
//! [plan §3.2](../../docs/plan.md) answers it the way this file implements: one
//! concrete [`Document`](doc.zig) plus a [`Mode`](doc.zig) flag, and a vtable
//! only where a caller genuinely holds either flavour polymorphically. This
//! file is where the **bodies** live, taking `*Document` and applying the
//! pending operations. It is not where a trait is declared, and it declares
//! none.
//!
//! # The two decisions this file had to make
//!
//! **1. A pending operation is [`opmod.TxOp`] and nothing else.**
//! [`TransactionInner.pending`] is a `Vec<TxOp>`
//! ([`inner.rs:22-33`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
//! and so is this file's, because a rollback needs three things a `ChangeOp`
//! does not carry: the row the operation landed at (`TxOp.pos`), the successor
//! edges to take back (`TxOp.undo`) and the register range a scoped
//! transaction captured (`TxOp.reset_range`,
//! [`inner.rs:246-257`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
//! `src/opset/op.zig` already has the type and its six constructors
//! ([`op.rs:261-449`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
//! and this file uses those; there is no second representation of an operation
//! here.
//!
//! **2. Commit means "hand [`Document.commit`] the change's own operations",
//! and the transaction's `TxOp`s are converted at that moment.**
//! [`Document.commit`](doc.zig) takes `ops: []const opmod.ChangeOp`, so the
//! other two answers were available: carry `ChangeOp`s from the start, or
//! convert. **This file converts, and it carries both.** Every operation is
//! built as a `TxOp` (decision 1) and *at once* as the `ChangeOp` that the op
//! set and the change encoder are both typed to, and the pair is what
//! [`Pending`] holds. The reason is in the op set: a document holds
//! `OpSet(ChangeOp)` and is not generic over the op type
//! ([`batchmod.BatchApply`](opset/batch.zig) splices `ChangeOp`s and
//! [`Columns.splice`](opset/columns.zig) is typed to `O`), so
//! [`OpSet.splice`](opset/op_set.zig) cannot be handed a `TxOp` at all. The
//! duplication is one predecessor-list copy per operation, and it is paid once
//! rather than at every splice *and* every commit.
//!
//! The consequence worth writing down: **an operation's `TxOp` and its
//! `ChangeOp` are built from the same nine fields, so they cannot disagree**,
//! and [`Pending`] frees both. Upstream reaches the same place from the other
//! side — `export` calls `build_change(&self.pending, ...)`
//! ([`inner.rs:197-207`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
//! which encodes the `TxOp`s it has been carrying.
//!
//! # The two flavours, and what the wrong door costs
//!
//! Upstream's `Transactable` is implemented for two *types*, and reaching the
//! wrong one does not compile. Here the two are one type and a flag, so the
//! door has to be checked at runtime: **every module-level function in this
//! file refuses a document that is not in [`Mode.auto`], and
//! [`Transaction.open`] refuses one that is, both with
//! `error.InvalidOp`.** That is the whole of the substitution, and it is a
//! refusal rather than a trap because Rust's answer was a compile error and the
//! closest honest runtime answer is an error, not a silent success.
//!
//! Native automatic refusal retains published or queued work in
//! `Document.auto_recovery` without allocating. A validation refusal with no
//! pending producer or rollback work disposes only the empty transaction;
//! valid unused actor metadata remains owned by the document. The primary error
//! is returned unchanged. Retained rollback is explicit through
//! `Document.recoverAuto` or retried before the next native automatic write.
//! Until recovery succeeds, held/manual entry is refused and retained operations
//! cannot be committed.
//!
//! [`Mode.auto`]: doc.zig
//! [`Mode.manual`]: doc.zig
//!
//! # The transaction's lifetime, and the one contract this file breaks
//!
//! **Every module-level function here opens a transaction, writes, and commits
//! it, so two calls are two transactions and two changes.** Upstream's
//! `AutoCommit` does not work that way: it opens a transaction lazily
//! (`ensure_transaction_open`,
//! [`autocommit.rs:445-457`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs))
//! and leaves it open **across calls**, closing it only on `commit_with`
//! (`:728-739`), `rollback` (`:742-750`) or one of the methods that needs the
//! change history to be current — `ensure_transaction_closed` (`:459-468`),
//! which `get_heads` (`:695`), `get_changes` (`:621`), `save` (`:530-533`),
//! `apply_changes`, `merge`, `load_incremental` and `dump` all call. **The
//! plain `ReadDoc` accessors do not close it**, so a write is visible to a read
//! before it is in any change.
//!
//! **Executed against the reference, this is one change and not two.**
//! `put_object(ROOT, "first", Text)` then `splice_text(&first, 0, 0, "hello")`
//! with no `commit()` between them leaves **one** change of six operations in
//! `get_changes()`, and `text(&first)` already answers `"hello"` before
//! anything commits. The same two calls with a `commit()` between them are two
//! changes.
//!
//! **The consequence is not a change count, and it is not a preference.**
//! Upstream's `incremental_list_conflict_survives_isolate_integrate_roundtrip`
//! (`tests/test.rs:4179-4208`) puts `put_object` and then `splice_text` inside
//! one isolation with no commit between, so `isolate_actor`
//! ([`automerge.rs:1259-1281`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
//! is chosen **once** and the pair is one change on the level-1 concurrency
//! actor. Here the pair is two transactions: the second opens at the same
//! isolation heads, finds `max_op_for_actor(fork) != 0`, forks **again** to the
//! next concurrency level — and the object the first transaction created is
//! outside the second transaction's scope clock, so [`Transaction.exidToObj`]
//! refuses it. **The reference's own test does not merely answer differently
//! here; the second call is `error.InvalidObjId`.** The two tests at the
//! bottom of this file pin both halves: the refusal, and the fact that
//! advancing the isolation heads by hand does not restore one change.
//!
//! **The two doors therefore disagree today.** `AMdoc` *is* a held transaction
//! ([`src/c/doc.zig`](c/doc.zig)): it opens through [`openAutoHeld`] and
//! commits only on `AMcommit` or a closing read. **The decision recorded here
//! is that this surface must hold one too**, because the alternative is a
//! document that depends on which door edited it. That is a wrapper type and
//! not a flag — a [`Transaction`] borrows its `Document`, so a `Document`
//! cannot own one — and the diff block at the bottom of this file carries the
//! blast radius and the sequencing.
//!
//! # Where the bulk paths go
//!
//! [`splice`] and [`spliceText`] are the two methods that write many
//! operations, and both go through [`Batch`], upstream's `BatchInsertion`
//! ([`inner.rs:1435-1520`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)):
//! the operations are appended to `pending` **without being spliced**, and
//! [`Batch.finish`] performs **one** [`OpSet.splice`] for the whole batch. That
//! one call is where the batch's cost is paid — one partition, one byte splice
//! and one index update per column, which is the whole reason
//! [`hexane/edit.zig`](hexane/edit.zig) exists. A bulk insert written any other
//! way would be a second implementation of a thing that is already here.
//!
//! `BatchInsertion::next_pos` assumes every queued operation lands contiguously
//! at the insert position
//! ([`inner.rs:1460-1462`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
//! and that assumption is *checked* by the test that reads a ten-character
//! splice back and walks every consecutive pair of rows through
//! [`Op.step`](opset/op.zig).
//!
//! # Ownership
//!
//! * Every entry point that allocates takes a `std.mem.Allocator`; the
//!   module-level functions take it from the document
//!   ([`Document.allocator`](doc.zig)) because `API.md`'s signatures name no
//!   allocator for them, and pass the document's own.
//! * A **borrowed slice is valid only while its owner is**
//!   ([plan §5.4](../../docs/plan.md)). [`put`]'s `value` and [`mark`]'s
//!   `name` and `value` are borrowed from the caller and are copied into the
//!   op set's own columns by the splice; the caller keeps them alive across the
//!   call and no longer.
//! * [`baseHeads`] returns a **borrow** from the document's change graph and
//!   [`Transaction.baseHeads`] a borrow from the transaction. Neither is owned
//!   by the caller and neither is freed by one.
//! * [`Transaction.deinit`] frees the pending list, the transaction's
//!   dependencies and the scope clock, and nothing else. The operations'
//!   borrowed payloads belong to the caller.

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
    opitermod.ReadOpError || opsetmod.SearchError || docmod.LoadError;

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
/// and `reset_range` off it. One operation, two views, built once from the same
/// nine fields and freed together.
pub const Pending = struct {
    /// The operation, as a transaction carries it.
    tx: TxOp,
    /// The same operation, as the op set and the change encoder take it.
    op: ChangeOp,

    /// Frees both views. The borrowed payloads — a string value, a map key, a
    /// mark name — belong to the caller and are not touched
    /// ([op.zig](opset/op.zig), `OpBuilder.deinit`).
    pub fn deinit(self: *Pending, gpa: Allocator) void {
        self.tx.deinit(gpa);
        self.op.deinit(gpa);
        self.* = undefined;
    }
};

/// The same operation as a [`ChangeOp`] ([`change_op_from`], one call).
fn changeOpOf(gpa: Allocator, op: *const TxOp) Allocator.Error!ChangeOp {
    return ChangeOp.init(
        gpa,
        op.id(),
        op.objId(),
        op.action(),
        op.key(),
        op.value(),
        op.insert(),
        op.expand(),
        op.markName(),
        op.pred(),
    );
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
    /// The hydrated maps [`hydrateBlock`] built, freed by [`deinit`].
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
        };
    }

    /// Frees the pending operations, the dependencies, the scope clock, the
    /// cached text, the bytes the operations borrowed (`owned`) and the block
    /// maps the diff borrowed (`blocks`), and nothing else. It does **not**
    /// roll back: upstream's `Transaction` does that in `Drop`
    /// ([`manual_transaction.rs:135-145`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs))
    /// and this port puts the same rule on the caller, who must say which.
    pub fn deinit(self: *Transaction) void {
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
        self.* = undefined;
    }

    /// Opens a transaction on a document in [`Mode.manual`]
    /// ([`Automerge::transaction`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    ///
    /// `error.InvalidOp` for a document in autocommit mode: upstream's
    /// `Transaction::new` takes an `Automerge`, so the two flavours cannot be
    /// confused, and here they can.
    /// Pending native automatic recovery also refuses entry with `error.InvalidOp`.
    pub fn open(gpa: Allocator, doc: *Document) WriteError!Transaction {
        if (doc.documentMode() != .manual) return error.InvalidOp;
        const args = try doc.transactionArgs(gpa, null);
        return Transaction.init(gpa, doc, args);
    }

    /// Opens a transaction scoped to `heads`
    /// ([`Automerge::transaction_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    ///
    /// **`heads` is borrowed** and must outlive the transaction: the scope
    /// clock is built from it on first use, which may be after this returns.
    /// Pending native automatic recovery refuses entry with `error.InvalidOp`.
    pub fn openAt(gpa: Allocator, doc: *Document, heads: ?[]const ChangeHash) WriteError!Transaction {
        if (doc.documentMode() != .manual) return error.InvalidOp;
        const args = try doc.transactionArgs(gpa, heads);
        return Transaction.init(gpa, doc, args);
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
    pub fn scopeClock(self: *Transaction) WriteError!?Clock {
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
        const live = self.doc.resolve(id) orelse return error.NotAnObject;
        const obj = ObjMeta{ .id = live, .typ = try self.doc.objectType(live) };
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
        if (self.closed or self.rolling_back or self.doc.auto_recovery != null)
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

        var change = try changeOpOf(self.gpa, &op);
        errdefer if (!transferred) change.deinit(self.gpa);
        try self.pending.ensureUnusedCapacity(self.gpa, 1);
        const added = try self.doc.ops.splice(op.pos, &.{change});
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

        const pred = try self.gpa.alloc(OpId, query.ops.items.len);
        defer self.gpa.free(pred);
        for (query.ops.items, pred) |row, *slot| slot.* = row.id();

        const pos = try mapKeyRow(
            &self.doc.ops,
            obj.id,
            key,
            query.range,
            query.end_pos,
        );
        const succ = try self.gpa.alloc(SuccInsert, query.ops.items.len);
        defer self.gpa.free(succ);
        const tx = try TxOp.map(self.gpa, id, obj, pos, resolved, key, pred);
        const inc = tx.getIncrementValue();
        for (query.ops.items, succ) |row, *slot| slot.* = row.addSucc(id, inc);

        try self.insertLocalOp(tx, succ, query.range);
        return id;
    }

    /// The row a new operation on the map key `key` of `obj` takes
    /// ([`inner.rs:473`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
    /// `TxOp::map(id, *obj, query.end_pos, ..)`).
    ///
    /// **There are two answers and the register's own rows pick between them.**
    ///
    /// A register with rows takes the row **one past its last**. Rule **R3** makes
    /// ids ascend within a register ([`Op.step`](opset/op.zig),
    /// `op.rs:1056-1057`), and a local operation's id is above every counter in
    /// the document: `start_op` is `change_graph.max_op() + 1`
    /// ([`automerge.rs:567`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// not this actor's own next counter, and [`TransactionInner::next_id`] adds
    /// the pending count ([`inner.rs:294-296`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    /// So the new id is greater than the register's last one whichever actor
    /// wrote that one, and appending at `end_pos` keeps **R3**. That is why
    /// upstream writes `query.end_pos` with no check at all.
    ///
    /// A register with **no** rows takes the row its key *sorts at*, and not the
    /// object's end. Upstream's `query.end_pos` is `prop_range(obj, prop).end`
    /// ([`op_set.rs:611-628`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
    /// `prop_range` is `key_str.scope_to_value(Some(prop), obj_range)`
    /// ([`op_set.rs:1268-1271`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
    /// and **hexane's `scope_to_value` answers the sorted insertion point for a
    /// value the column does not hold**: over `aaa aaa bbb bbb bbb ccc` it answers
    /// `2..2` for `"aab"` — which sorts between `"aaa"` and `"bbb"` — and `6..6`
    /// for `"ddd"`
    /// ([`hexane/src/tests.rs:3464-3476`](../../github-automerge-automerge/rust/hexane/src/tests.rs)).
    /// That is rule **R2** (`op.rs:1059-1060`) and the only order a map can be read
    /// in, because the reader does not sort
    /// ([`map_range.zig:1486-1490`](iter/map_range.zig)).
    ///
    /// **So the position supplied here is the one `propRange` cannot answer.** The
    /// port's `propRange` walks the key column rather than descending it — the
    /// column holds interned ids, which are in insertion order and not key order
    /// ([op_set.zig:2056-2064](opset/op_set.zig)) — and a walk that finds nothing
    /// has no sorted place to stop at, so it answers the object's end
    /// ([op_set.zig:2069-2091](opset/op_set.zig)). **That answer is right only for
    /// a key greater than every key the object holds**, which is the one case that
    /// needs no answer at all: a document whose rows are in order can be read
    /// back differently by a map reader, and this is where it goes wrong.
    ///
    /// The walk is over the object's own rows, and the row order is what makes it
    /// short: the first key that sorts above `key` ends it, because **R2** puts
    /// every register's rows together and in key order.
    fn mapKeyRow(
        ops: *Set,
        obj: ExId,
        key: []const u8,
        register_rows: RowRange,
        end_pos: usize,
    ) WriteError!usize {
        if (register_rows.start < register_rows.end) return end_pos;
        const rows = try ops.scopeToObj(obj);
        var walk = try ops.iterRange(rows);
        var at = rows.start;
        while (try walk.next()) |row| {
            switch (row.elemidOrKey()) {
                // `Op::step`'s map arm compares two `KeyRef::Map` and requires the
                // *previous* key to be the greater one (`op.rs:1059-1060`), so the
                // row the new register takes is the **first row whose key sorts
                // above `key`** — the register goes in front of it.
                .map => |text| if (std.mem.order(u8, key, text) == .lt) return at,
                // **A sequence anchor cannot be in a map object**: an object is
                // made a map or a sequence and never both, and a row carries
                // exactly one of the two or the walk refuses it
                // ([`tryLoadKeyRef`](opset/op_iter.zig), `op_iter.rs:251-265`).
                // It sorts above every string, which is the one answer that cannot
                // put the new register behind a row it does not belong behind.
                .seq => return at,
            }
            at += 1;
        }
        // Every key in the object sorts below `key`, so the register goes last.
        return end_pos;
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
        return self.doc.idToExid(id);
    }

    /// Removes the block at `index`, joining its text back together
    /// ([`join_block`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):931-982).
    pub fn joinBlock(self: *Transaction, text: ExId, index: usize) WriteError!void {
        try self.requireOpen();
        const meta = try self.exidToObj(text);
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
        var change = try changeOpOf(self.gpa, &op);
        errdefer if (!transferred) change.deinit(self.gpa);
        try self.pending.append(self.gpa, .{ .tx = op, .op = change });
        transferred = true;
        errdefer self.rolling_back = true;
        try self.doc.ops.addSuccWithUndo(
            &succ,
            &self.pending.items[self.pending.items.len - 1].tx.undo,
        );
    }

    /// Replaces the block at `index` with a fresh empty one
    /// ([`replace_block`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):984-993).
    pub fn replaceBlock(self: *Transaction, text: ExId, index: usize) WriteError!ExId {
        try self.joinBlock(text, index);
        return self.splitBlock(text, index);
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
        var index = pos;
        var del = del_in;
        if (del < 0) {
            const back: usize = std.math.cast(usize, -del) orelse
                return error.InvalidIndex;
            if (back > index) return error.InvalidIndex;
            index -= back;
            del = @intCast(back);
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
                    const w = try batch.spliceText(obj, query.elemid, t);
                    try batch.finish();
                    break :blk w;
                },
                .list => |values| try self.spliceListValues(obj, query.pos, query.elemid, values),
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
        var change = try changeOpOf(self.gpa, &op);
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
        values: []const hydmod.Value,
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
            for (values, 0..) |_, i| {
                // **The queue borrows `values`, not the loop's copy.**
                // Upstream walks `values.iter().enumerate()`
                // ([`inner.rs:719`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
                // so `value` there is a borrow into the `Vec` and outlives the
                // loop; a `for` capture is a copy in a stack slot the next
                // iteration overwrites, so `&value` was a pointer to whatever
                // the *last* element happened to be — which is why a splice
                // of `[1, [7], "three"]` walked the scalar `"three"` as if it
                // were the nested list and answered `error.InvalidOp`.
                const value = &values[i];
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
                    i,
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
        return values.len;
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
    pub fn commit(
        self: *Transaction,
        message: ?[]const u8,
        time: ?i64,
    ) WriteError!?ChangeHash {
        try self.requireOpen();
        if (self.pending.items.len == 0) {
            try self.doc.removeUnusedActors(self.gpa);
            self.closed = true;
            return null;
        }
        const commit_message = message orelse self.message;
        const commit_time = time orelse self.time;
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
        return hash;
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
            try self.doc.ops.undoOp(&self.pending.items[last].tx);
            var item = self.pending.pop().?;
            item.deinit(self.gpa);
            self.cancelled += 1;
        }
        try self.doc.removeUnusedActors(self.gpa);
        self.closed = true;
        return self.cancelled;
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
    /// **This is upstream's `ReadDoc::get` on a transaction.** The macro at
    /// `transaction.rs:36-311` hands the whole of `ReadDoc` to
    /// [`Transaction`](../../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs):21-27
    /// — every reader, not this one alone — and this is the **one** read the
    /// port gives a transaction, because it is the one whose scope the caller
    /// cannot reach any other way.
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
    pub fn get(self: *Transaction, obj: ExId, prop: Prop) WriteError!?readmod.DocItem {
        return readmod.getAtScope(self.doc, obj, prop, try self.scopeClock());
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
    ) WriteError!marksmod.MarkSet {
        if (heads) |h| {
            // `Some(h) => self.doc.change_graph.clock_at(h)`
            // (`manual_transaction.rs:113-118`). **And not `clock.isolate(..)`**,
            // which [`scopeClock`](transact.zig) does apply: upstream builds the
            // marked clock once in `isolate_actor` and hands it over marked
            // (`automerge.rs:1276-1280`), so the two arms differ in the
            // *source* of the clock and not in what is done to it. Marking this
            // one would make a heads-taking read see this transaction's own
            // pending operations, which is exactly what upstream's does not.
            var clock = try self.doc.graph.clockAt(self.gpa, h);
            defer clock.deinit();
            return readmod.markSetAtScope(self.doc, obj, index, clock, gpa);
        }
        return readmod.markSetAtScope(self.doc, obj, index, try self.scopeClock(), gpa);
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
    fn ownText(self: *Transaction, text: []const u8) WriteError![]const u8 {
        const copy = try self.gpa.dupe(u8, text);
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
        text: []const u8,
    ) WriteError!void {
        const meta = try self.exidToObj(obj);
        try requireType(meta, .text);
        try self.innerSplice(meta, index, del, .{ .text = text });
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
    pub fn updateTextValue(self: *Transaction, id: ExId, value: *const hydmod.Text) WriteError!void {
        return self.updateText(id, value.asStr());
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
                    return self.spliceText(id, 0, 0, t.asStr());
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
    pub fn initRootFromHydrate(self: *Transaction, value: *const hydmod.Map) WriteError!void {
        try self.requireOpen();
        const pending_start = self.pending.items.len;
        errdefer if (self.pending.items.len > pending_start) {
            self.rolling_back = true;
        };
        const root = ObjMeta.root();
        var batch = Batch.init(self, self.doc.ops.len());
        var queue: Queue = .init(self.gpa);
        defer queue.deinit();

        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.gpa);
        var it = value.entries.iterator();
        while (it.next()) |entry| try keys.append(self.gpa, entry.key_ptr.*);
        std.mem.sort([]const u8, keys.items, {}, strLessThan);

        for (keys.items) |key| {
            const child = Transaction.entryValue(value, key) orelse continue;
            const made = valueObjectType(child.*);
            const action: OpType = if (made) |t|
                .{ .make = t }
            else
                .{ .put = child.toScalar() orelse return error.NotAnObject };
            const id = try batch.appendRoot(root, key, action);
            if (made) |t| {
                try queue.push(ObjMeta{ .id = self.doc.idToExid(id), .typ = t }, child);
            }
        }
        try batch.bfs(&queue);
        try batch.finish();
    }

    /// Brings a text object in line with `spans`, marks and all
    /// ([`myers_block_diff`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):136-163
    /// and [`apply_marks_diff`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):165-248).
    ///
    /// **Two passes, and the second one is why this is not a splice.** The
    /// first brings the text and the block structure in line; the second
    /// re-derives every mark from the spans, because a mark is not part of the
    /// text's bytes and a diff over graphemes cannot see one.
    pub fn updateSpans(self: *Transaction, obj: ExId, spans: []const Span) WriteError!void {
        var config = UpdateSpansConfig.init(self.gpa);
        defer config.deinit();
        return self.updateSpansWithConfig(obj, &config, spans);
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
        spans: []const Span,
    ) WriteError!void {
        const meta = try self.exidToObj(obj);
        try requireType(meta, .text);

        var owned: std.ArrayList(Span) = .empty;
        defer {
            for (owned.items) |*s| s.deinit(self.gpa);
            owned.deinit(self.gpa);
        }
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
                            try old.append(self.gpa, .{ .grapheme = try self.gpa.dupe(u8, g) });
                        }
                    },
                    .block => |id| {
                        try old.append(self.gpa, .{ .block = try self.hydrateBlock(id) });
                    },
                }
            }
        }

        const new_spans = try self.gpa.alloc(textdiff.BlockOrText(Block), spans.len);
        defer self.gpa.free(new_spans);
        for (spans, new_spans) |span, *slot| {
            slot.* = switch (span) {
                .text => |t| .{ .text = t.text },
                .block => |id| .{ .block = try self.hydrateBlock(id) },
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
        try self.applyMarkDiff(meta.id, config, spans);
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
        spans: []const Span,
    ) WriteError!void {
        var wanted: std.ArrayList(Mark) = .empty;
        defer wanted.deinit(self.gpa);
        var idx: usize = 0;
        const enc = self.doc.textEncoding();
        for (spans) |span| switch (span) {
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

        const current = try self.doc.ops.calculateMarks(self.gpa, obj);
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

    /// The hydrated map for a block, owned by [`Transaction.blocks`] and at a
    /// fixed address for as long as the transaction lives.
    fn hydrateBlock(self: *Transaction, id: ExId) WriteError!Block {
        const value = try hydmod.hydrateMap(
            Set,
            &self.doc.ops,
            self.gpa,
            id,
            try self.scopeClock(),
        );
        const map = switch (value) {
            .object => |o| switch (o) {
                .map => |m| m,
                // `text_diff.rs:452-457` — a non-map object in a text is a
                // block marker with no contents, and upstream warns and uses an
                // empty map rather than refusing.
                else => hydmod.Map.init(self.gpa, id),
            },
            else => hydmod.Map.init(self.gpa, id),
        };
        // **The map is its own allocation.** A `Block` carries a
        // `*const hydmod.Map` into this list, and a diff holds those pointers
        // for its whole run while the operations it writes borrow the map's
        // keys and values, so nothing here may move: not when the list grows,
        // and not when the transaction is deinitialised.
        const slot = try self.gpa.create(hydmod.Map);
        errdefer self.gpa.destroy(slot);
        slot.* = map;
        errdefer slot.deinit();
        try self.blocks.append(self.gpa, slot);
        return .{ .id = id, .map = slot };
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

/// One unit of text as the document's encoding splits it
/// ([`inner.rs:1481-1491`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)):
/// a grapheme cluster under `grapheme_cluster`, a code point otherwise.
///
/// **The other three encodings split by code point, not by cluster**, and that
/// is upstream's own comment rather than an accident
/// (`inner.rs:1482-1486`): the grapheme encoding arrived after the others and
/// they were not changed.
fn textUnits(gpa: Allocator, s: []const u8, enc: TextEncoding) WriteError![][]const u8 {
    if (s.len == 0) return gpa.alloc([]const u8, 0);
    if (enc == .grapheme_cluster) return textdiff.graphemes(gpa, s);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return error.InvalidUtf8;
        const end = @min(i + n, s.len);
        try out.append(gpa, s[i..end]);
        i = end;
    }
    return out.toOwnedSlice(gpa);
}

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
        errdefer tx_op.deinit(self.tx.gpa);
        try self.tx.requireOpen();
        const id = tx_op.id();
        var change = try changeOpOf(self.tx.gpa, &tx_op);
        errdefer change.deinit(self.tx.gpa);
        try self.tx.pending.append(self.tx.gpa, .{ .tx = tx_op, .op = change });
        return id;
    }

    /// Queues one map operation with no predecessors, the shape every root of a
    /// batch has ([`batch_bfs`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1553-1562).
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
    fn spliceText(self: *Batch, container: ObjMeta, after: ElemId, text: []const u8) WriteError!usize {
        errdefer if (self.tx.pending.items.len > self.start) {
            self.tx.rolling_back = true;
        };
        const units = try textUnits(self.tx.gpa, text, self.tx.doc.textEncoding());
        defer self.tx.gpa.free(units);
        var inserted_width: usize = 0;
        var elem = after;
        for (units) |unit| {
            const id = self.tx.nextId();
            const op = try TxOp.insertVal(
                self.tx.gpa,
                id,
                container,
                self.nextPos(),
                .{ .str = try self.tx.ownText(unit) },
                elem,
            );
            inserted_width += @intCast(op.width(.text, self.tx.doc.textEncoding()));
            elem = ElemId.fromOpId(id);
            _ = try self.append(op);
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
                        _ = try self.spliceText(container, ElemId.head(), t.asStr());
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
        const ops = try self.tx.gpa.alloc(ChangeOp, queued.len);
        defer self.tx.gpa.free(ops);
        for (queued, ops) |*item, *slot| slot.* = item.op;
        _ = try self.tx.doc.ops.splice(self.insert_pos, ops);
    }
};

// ── The document-level surface ──────────────────────────────────────────────

/// Refuses a document that is not in autocommit mode.
///
/// **This is the whole of the two-flavours check.** Upstream's `Transactable`
/// is implemented for two types, so calling the wrong one does not compile; here
/// the two are one type and a [`Mode`](doc.zig) flag, so the door has to be
/// checked where the caller walks through it. `error.InvalidOp` is
/// [`Error`]'s word for "this operation does not belong here", and it is the
/// closest honest runtime answer to a compile error.
fn requireAuto(doc: *Document) Error!void {
    if (doc.documentMode() != .auto) return error.InvalidOp;
    _ = doc.recoverAuto() catch |e| return asError(e);
}

// An automatic wrapper has no caller-held transaction to return on refusal.
// Retain unresolved producer work without fallible rollback at this boundary.
// Valid unused actor metadata belongs to the document, not the empty journal.
fn finishAuto(tx: *Transaction) void {
    if (tx.closed or (tx.pending.items.len == 0 and !tx.rolling_back)) {
        tx.deinit();
        return;
    }
    std.debug.assert(tx.doc.auto_recovery == null);
    tx.rolling_back = true;
    if (tx.scope_heads != null) tx.scope_heads = tx.deps;
    tx.doc.auto_recovery = tx.*;
    tx.* = undefined;
}

/// Opens the transaction an autocommit call works in
/// ([`AutoCommit::ensure_transaction_open`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):445-457).
///
/// **The isolation heads are the scope**, which is the only difference from
/// [`Transaction.open`] and the whole of `AutoCommit`'s extra state
/// ([`autocommit.rs:433-441`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)).
/// The heads are the document's own, and the document outlives the
/// transaction, so the borrow holds.
fn openAuto(gpa: Allocator, doc: *Document) WriteError!Transaction {
    const args = try doc.transactionArgs(gpa, doc.isolationHeads());
    return Transaction.init(gpa, doc, args);
}

/// [`openAuto`], for a caller that owns the transaction's lifetime.
///
/// **This is not the autocommit door.** Every module function above opens a
/// transaction, writes one operation and commits it, because that is what
/// `AutoCommit` looks like to a Zig caller using the crate's own
/// `Transactable` impl. The C ABI is a different type — `AMdoc` *is*
/// `am::AutoCommit` (`rust/automerge-c/src/doc.rs:35-36`) — and
/// `AutoCommit`'s defining property is that it holds its transaction **open
/// across calls**, opening it lazily ([`ensure_transaction_open`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):445-457)
/// and closing it only on `commit_with` (`:728-739`), `rollback` (`:742-751`)
/// or a read that needs it (`:459-468`). A caller of this function owns the
/// returned transaction and makes that choice itself.
/// Pending native automatic recovery is refused with `error.InvalidOp`; call
/// `Document.recoverAuto` before taking held ownership.
pub fn openAutoHeld(gpa: Allocator, doc: *Document) WriteError!Transaction {
    return openAuto(gpa, doc);
}

/// Writes `value` at `prop`, and commits
/// ([`Transactable::put`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):20-31).
///
/// **`value` is borrowed** from the caller; the splice copies it into the op
/// set's own columns, so it has to outlive this call and no longer.
///
/// **The returned id is the operation's, and the operation may not exist.**
/// A `put` that repeats a register's only value writes nothing
/// ([`op_set.rs:1489-1492`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)) and
/// the answer is [`OpId.root`] — the head sentinel, which names no operation
/// anywhere — rather than an id that would send a caller looking for a row
/// that was never written.
pub fn put(doc: *Document, obj: ExId, prop: Prop, value: ScalarValue) Error!OpId {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    const made = tx.put(obj, prop, value) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
    return made orelse OpId.root;
}

/// Creates an object at `prop`, and commits
/// ([`Transactable::put_object`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):33-39).
pub fn putObject(doc: *Document, obj: ExId, prop: Prop, t: ObjType) Error!ExId {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    const id = tx.putObject(obj, prop, t) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
    return id;
}

/// Inserts `value` at `index`, and commits
/// ([`Transactable::insert`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):41-46).
pub fn insert(doc: *Document, obj: ExId, index: usize, value: ScalarValue) Error!OpId {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    const id = tx.insert(obj, index, value) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
    return id;
}

/// Creates an object at `index` in a sequence, and commits
/// ([`Transactable::insert_object`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):48-51).
pub fn insertObject(doc: *Document, obj: ExId, index: usize, t: ObjType) Error!ExId {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    const id = tx.insertObject(obj, index, t) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
    return id;
}

/// Adds `by` to the counter at `prop`, and commits
/// ([`Transactable::increment`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):53-57).
///
/// **`error.MissingCounter` for anything that is not a counter**, and that is
/// upstream's check before anything is written
/// ([`inner.rs:466-468`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)) — an
/// increment on a plain value changes nothing in the document and says so.
pub fn increment(doc: *Document, obj: ExId, prop: Prop, by: i64) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.increment(obj, prop, by) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// Removes the value at `prop`, and commits
/// ([`Transactable::delete`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):59-67).
///
/// The count is how many delete operations were written; see
/// [`Transaction.delete`].
pub fn delete(doc: *Document, obj: ExId, prop: Prop) Error!usize {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    const n = tx.delete(obj, prop) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
    return n;
}

/// Inserts `values` and removes `del` units at `pos`, and commits
/// ([`Transactable::splice`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):69-75).
///
/// **`values` is borrowed.** The whole batch is written with one
/// [`OpSet.splice`](opset/op_set.zig); see the module doc.
pub fn splice(
    doc: *Document,
    obj: ExId,
    pos: usize,
    del: isize,
    gpa: Allocator,
    values: []const hydmod.Value,
) Error!void {
    try requireAuto(doc);
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    try spliceHeld(&tx, obj, pos, del, gpa, values);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// The body of [`splice`], for a caller that owns the transaction — the C
/// ABI's `AMdoc`, which keeps its transaction open across calls
/// ([`autocommit.rs:445-457`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)).
/// **One implementation, two doors**: the autocommit one above opens, calls
/// this and commits; the held one calls this and does not.
///
/// **A list splices `values`; a text splices their strings joined**
/// ([`inner.rs:619-643`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
/// and both reach [`Transaction.innerSplice`] with the kind that says which.
/// The list arm was empty once, which is why a `splice` of hydrated values
/// into a **list** reported success and wrote nothing at all: no operation,
/// no change, an untouched document. `inner.rs:610` says the values may be
/// scalars or nested objects, and `inner.rs:633-642` is the branch that
/// takes them.
pub fn spliceHeld(
    tx: *Transaction,
    obj: ExId,
    pos: usize,
    del: isize,
    gpa: Allocator,
    values: []const hydmod.Value,
) Error!void {
    const meta = tx.exidToObj(obj) catch |e| return asError(e);
    // `inner.rs:616-618` — a map is neither of the two things a splice writes.
    switch (meta.typ) {
        .list => tx.innerSplice(meta, pos, del, .{ .list = values }) catch |e| return asError(e),
        .text => {
            const joined = joinTextValues(gpa, values) catch |e| return asError(e);
            defer gpa.free(joined);
            tx.innerSplice(meta, pos, del, .{ .text = joined }) catch |e| return asError(e);
        },
        else => return error.InvalidOp,
    }
}

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

/// Writes `text` at `pos` and removes `del` units, and commits
/// ([`Transactable::splice_text`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):77-82).
///
/// **`text` is borrowed** and the whole run is written with one
/// [`OpSet.splice`](opset/op_set.zig), one operation per code point (or grapheme
/// cluster, under that encoding).
pub fn spliceText(doc: *Document, obj: ExId, pos: usize, del: isize, text: []const u8) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.spliceText(obj, pos, del, text) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// Writes a mark over `[from, to)`, and commits
/// ([`Transactable::mark`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):84-89).
///
/// **`name` and `value` are borrowed.** `expand` decides whether the mark grows
/// past text inserted at either end later, and it is observable: a begin with
/// `expand = false` does not extend over an insert made after it.
pub fn mark(
    doc: *Document,
    obj: ExId,
    from: usize,
    to: usize,
    name: []const u8,
    expand: ExpandMark,
    value: ?ScalarValue,
) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.mark(obj, from, to, name, expand, value) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// Removes a mark over `[from, to)`, and commits
/// ([`Transactable::unmark`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):91-101).
/// Null removes the mark; a non-null value applies it, as `Transaction.unmark`.
pub fn unmark(
    doc: *Document,
    obj: ExId,
    from: usize,
    to: usize,
    expand: ExpandMark,
    name: []const u8,
    value: ?ScalarValue,
) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.unmark(obj, from, to, expand, name, value) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// Cuts a text block out at `index`, and commits
/// ([`Transactable::split_block`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):103-105).
pub fn splitBlock(doc: *Document, obj: ExId, index: usize) Error!ExId {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    const id = tx.splitBlock(obj, index) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
    return id;
}

/// Joins the block at `index` back into the text, and commits
/// ([`Transactable::join_block`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):107-110).
pub fn joinBlock(doc: *Document, text: ExId, index: usize) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.joinBlock(text, index) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// Replaces the block at `index` with a fresh empty one, and commits
/// ([`Transactable::replace_block`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):112-120).
pub fn replaceBlock(doc: *Document, text: ExId, index: usize) Error!ExId {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    const id = tx.replaceBlock(text, index) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
    return id;
}

/// Makes a text object hold `new_text`, and commits
/// ([`Transactable::update_text`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):144-146).
///
/// **This is a diff, not a write.** `textdiff.myersDiff` compares grapheme
/// clusters and turns the differences into splices, so an unchanged text costs
/// no operation at all.
pub fn updateText(doc: *Document, obj: ExId, new_text: []const u8) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.updateText(obj, new_text) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// Brings a map object in line with `value`, and commits
/// ([`Transactable::update_object`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):148-159).
///
/// `API.md` narrows this to a map, so this is upstream's `update_map` and not
/// its three-way dispatch; a list or a text object is `error.NotAnObject`.
pub fn updateObject(doc: *Document, obj: ExId, value: hydmod.Map) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.updateMapValue(obj, &value) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// Brings a text object in line with `spans`, marks and all, and commits
/// ([`Transactable::update_spans`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):126-130).
///
/// **`spans` is borrowed and the marks inside it are the caller's.** A block
/// span names an object the document already holds — `iter::Span`'s payload is
/// an `ExId` here where upstream's is a hydrated map — so a caller creates the
/// block with [`putObject`] first and names it here. **This is upstream's
/// `update_spans` with `UpdateSpansConfig::default()`**, which writes every
/// mark with [`ExpandMark.after`] ([`marks.rs`:379-383](../../github-automerge-automerge/rust/automerge/src/marks.rs));
/// [`updateSpansWithConfig`] is the same call with a config that names its own
/// flags.
pub fn updateSpans(doc: *Document, obj: ExId, spans: []const Span) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.updateSpans(obj, spans) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// [`updateSpans`] with the expand flags in `config`, and commits
/// ([`Transactable::update_spans`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):126-130,
/// whose second argument upstream takes and this takes here).
///
/// **Not in `API.md`, and not optional.** Two upstream cases set the flags
/// rather than take upstream's default —
/// `multiple_marks_different_expand_behaviors` ([`diff_marks.rs`:864-903](../../github-automerge-automerge/rust/automerge/tests/diff_marks.rs))
/// names three mark names and grows them in three directions, and
/// `marks_with_expand_none_at_boundaries` ([`:906-944`](../../github-automerge-automerge/rust/automerge/tests/diff_marks.rs))
/// takes the default to `None` for every name — and driving [`mark`] three
/// times instead would test `mark`, not `update_spans`. `config` is borrowed
/// and is not freed here; the caller owns it.
pub fn updateSpansWithConfig(
    doc: *Document,
    obj: ExId,
    config: *const UpdateSpansConfig,
    spans: []const Span,
) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.updateSpansWithConfig(obj, config, spans) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// Creates an object of type `t` at `prop`, and commits
/// ([`Transactable::batch_create_object`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):161-171).
///
/// **The narrowing from upstream is in the report:** upstream's takes the whole
/// `hydrate::Value` and fills it, and `API.md` names a type. This makes the
/// object; [`batchCreateValue`] is the same method with the value.
pub fn batchCreateObject(doc: *Document, obj: ExId, prop: Prop, t: ObjType) Error!ExId {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    const id = tx.batchCreateObject(obj, prop, t) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
    return id;
}

/// Creates an object of the kind `value` is at `prop` and fills it, and commits.
///
/// **Not in `API.md`, and not optional.** [`batchCreateObject`] cannot fill an
/// object because its signature carries no value, and [`updateObject`] needs
/// the object to exist first, so the one operation that puts a whole subtree
/// into the document in a single batch is this
/// ([`batch_create_object`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):1269-1331).
pub fn batchCreateValue(
    doc: *Document,
    obj: ExId,
    prop: Prop,
    value: hydmod.Value,
    as_insert: bool,
) Error!ExId {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    const id = tx.batchCreateValue(obj, prop, value, as_insert) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
    return id;
}

/// Fills the document root from `value`, and commits
/// ([`Transactable::init_root_from_hydrate`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):173-175)).
///
/// **Keys are sorted before anything is written**, so the same value produces
/// the same operation ids and so the same change hash on every run.
pub fn initRootFromHydrate(doc: *Document, value: hydmod.Map) Error!void {
    try requireAuto(doc);
    const gpa = doc.allocator();
    var tx = openAuto(gpa, doc) catch |e| return asError(e);
    defer finishAuto(&tx);
    tx.initRootFromHydrate(&value) catch |e| return asError(e);
    _ = tx.commit(null, null) catch |e| return asError(e);
}

/// How many operations the document holds that no change accounts for
/// ([`Transactable::pending_ops`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):11-12).
///
/// **This is the document's answer, and it is upstream's definition read from
/// what a document can answer.** Upstream counts `TransactionInner.pending`
/// (`inner.rs:103-105`), which is exactly "the operations this transaction
/// created, which are in the op set and not yet in a change". A local
/// transaction is the only thing that splices operations in without a change, so
/// that count *is* the number of operations in the op set whose id is above
/// [`ChangeGraph.maxOp`](change_graph.zig) — the highest op counter any change
/// in the graph claims. After a commit it is zero; after a rollback it is zero
/// for the same reason and by a different route.
///
/// **Two walks and not one, because an operation is a row *or* a successor
/// edge.** A `delete` writes no row: it is a successor edge on the register's
/// winner ([`next_delete`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):298-306,
/// and this file's own `delete makes the key absent, not present with a null`
/// test says the same thing from the other side). A row-only walk therefore
/// answers one short for every pending delete, which is not a rounding
/// difference but the wrong number: a transaction that put a key, deleted a
/// key and made two nested objects has four operations queued and three rows.
/// The successor walk is the other half of the same count and not a second
/// source of truth for it — an edge's id is an operation's id, read from the
/// same columns the row walk reads.
///
/// With refused native automatic work, this returns the retained journal's
/// count without reading partially undone columns. Otherwise it walks rows
/// and successor edges as described above.
///
/// For the *transaction's own* count, which is O(1), see
/// [`Transaction.count`].
pub fn pendingOps(doc: *const Document) usize {
    if (doc.auto_recovery) |*tx| return tx.count();
    const highest = doc.graph.maxOp();
    const rows: usize = doc.ops.len();
    var n: usize = 0;
    {
        var ids = doc.ops.idIterRange(.{ .start = 0, .end = rows }) catch return 0;
        while (ids.maybeTryNext() catch null) |id| {
            if (@as(u64, id.counter) > highest) n += 1;
        }
    }
    var succ = doc.ops.succIterRange(.{ .start = 0, .end = rows }) catch return 0;
    while (succ.tryNext() catch null) |cursors| {
        var edges = cursors.withInc();
        while (edges.next()) |e| {
            if (@as(u64, e.id.counter) > highest) n += 1;
        }
    }
    return n;
}

/// The document's heads, **borrowed** from its change graph and valid until the
/// next change is added
/// ([`Transactable::base_heads`](../../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):132-142).
///
/// **A borrow, not a copy, and that is the deviation.** Upstream returns
/// `Vec<ChangeHash>` — the transaction's own `deps` cloned out of it
/// ([`inner.rs:1386-1388`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)) —
/// and `API.md` names no allocator, which a `Vec` cannot be built without in
/// this port's shape. So this is the answer to the question the document-level
/// caller actually has: *what would the next change depend on?* The next
/// commit's dependencies are the current heads, because that is what
/// [`Document.transactionArgs`](doc.zig) derives them from.
///
/// For the *transaction's own* base — the heads it started from, which is a
/// different number once anything has been committed since — see
/// [`Transaction.baseHeads`].
pub fn baseHeads(doc: *const Document) []const ChangeHash {
    return doc.graph.getHeads();
}

// ── tests ───────────────────────────────────────────────────────────────────

/// A document with a random actor, because every operation needs one and an
/// empty actor index is not one (`Document.init`'s own note).
fn freshDoc(gpa: Allocator) !Document {
    return freshDocIn(gpa, .auto);
}

/// The same, in the mode the caller asked for. **The mode is not a detail
/// here:** every module function refuses a `.manual` document and
/// [`Transaction.open`] refuses a `.auto` one, so a fixture has to name it.
fn freshDocIn(gpa: Allocator, mode: docmod.Mode) !Document {
    var doc = try Document.init(gpa, std.testing.io, mode);
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

test "put then commit then read back, and the document has one more change" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 0), doc.graph.len());
    const id = try put(&doc, .root, .{ .key = "name" }, .{ .str = "ada" });
    try testing.expect(!id.eql(OpId.root));

    try testing.expectEqual(@as(usize, 1), doc.graph.len());
    var found = try register(gpa, &doc, "name");
    defer found.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), found.ops.items.len);
    try testing.expectEqualStrings("ada", found.ops.items[0].value().str);
    try testing.expectEqual(Action.set, found.ops.items[0].action());
}

test "a redundant put writes no operation and adds no change" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    _ = try put(&doc, .root, .{ .key = "k" }, .{ .int = 1 });
    try testing.expectEqual(@as(usize, 1), doc.graph.len());
    // `op_set.rs:1489-1492` — the register's only value, repeated, is a no-op.
    const second = try put(&doc, .root, .{ .key = "k" }, .{ .int = 1 });
    try testing.expect(second.eql(OpId.root));
    try testing.expectEqual(@as(usize, 1), doc.graph.len());
    try testing.expectEqual(@as(usize, 0), pendingOps(&doc));
}

// **This test was about a conflict that upstream does not have, and it is
// the third place the same bug showed up.** It is the port of the
// register half of `incremental_list_conflict_survives_isolate_integrate_roundtrip`
// (`tests/test.rs:4179-4208`), driven through the module-level write surface.
//
// It used to isolate at `before`, write `k = 1` then `k = 2` as two module
// calls, and assert **two visible rows** — a conflicted register. The second
// call could not see the first because
// [`Document.commit`](../src/doc.zig) did not advance the isolation heads, so
// its scope clock stopped at `before`
// ([`autocommit.rs:464-466`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)).
// With the heads advanced, the second write **sees** the first and overwrites
// it, which is what upstream does: `AutoCommit` holds one transaction across
// both writes ([`autocommit.rs:445-457`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)), and
// a `put` inside a transaction resolves its register against that
// transaction's own scope.
//
// **So there is no conflict here, upstream or here, and the assertion that
// said there was was pinning the missing advance.** The property that replaces
// it is the visibility itself: a write under an isolation sees the previous
// write under the same isolation, so it *overwrites* rather than forking a
// second row.
test "two puts on one key inside one isolation: the second sees the first, so the register is not conflicted" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    _ = try put(&doc, .root, .{ .key = "warm" }, .{ .int = 1 });
    const before = try doc.getHeads(gpa);
    defer gpa.free(before);
    const warm_changes = doc.graph.len();

    try doc.isolate(gpa, before);
    _ = try put(&doc, .root, .{ .key = "k" }, .{ .int = 1 });
    _ = try put(&doc, .root, .{ .key = "k" }, .{ .int = 2 });
    try doc.integrate();

    var found = try register(gpa, &doc, "k");
    defer found.deinit(gpa);
    // **One row, not two, and the number is the property.** Two visible rows
    // is what makes a register conflicted
    // ([`map_range.rs`:262-263](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)),
    // and a second row here is a write that could not see its predecessor —
    // the exact symptom of stale isolation heads. A reader that reported one
    // row for a register that holds two is the failure this port used to
    // produce in the other direction, so both numbers are worth pinning.
    try testing.expectEqual(@as(usize, 1), found.ops.items.len);
    // **And the row carries the *second* value**, because the overwrite
    // happened: the survivor of a register that was written twice under one
    // scope is the later write, and a row still carrying `1` would mean the
    // successor edge the second `put` wrote never reached the register.
    try testing.expect(found.ops.items[0].visible());
    try testing.expectEqual(@as(i64, 2), found.ops.items[0].value().int);
    // Upstream's own index checker: a group's first winner must be its last
    // visible row ([`op_set.rs`:196-212](../src/opset/op_set.zig)), and a
    // `reset_top` that resolved the register against the wrong scope would
    // leave a visible row past the winner.
    try testing.expect((try doc.ops.validateTopIndex()) == null);

    // **Two changes, where upstream makes one, and this is the lifetime
    // divergence and nothing else.** The register above matches the
    // reference; the change count does not, and asserting `warm_changes + 1`
    // here would be asserting the port's write surface rather than the CRDT.
    try testing.expectEqual(warm_changes + 2, doc.graph.len());

    // Outside any isolation the same pair behaves identically, which is the
    // control: the advance makes an isolated write behave like an
    // un-isolated one, it does not change what a `put` means.
    var single = try freshDoc(gpa);
    defer single.deinit();
    _ = try put(&single, .root, .{ .key = "k" }, .{ .int = 1 });
    _ = try put(&single, .root, .{ .key = "k" }, .{ .int = 2 });
    var over = try register(gpa, &single, "k");
    defer over.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), over.ops.items.len);
    try testing.expectEqual(@as(i64, 2), over.ops.items[0].value().int);
}

// **This pins what is left of a divergence, and it used to be worse.** It is
// the port of upstream's `incremental_list_conflict_survives_isolate_integrate_roundtrip`
// (`tests/test.rs:4179-4208`) driven through the module-level write surface,
// which is the one surface here that does **not** hold a transaction open.
//
// It was written to go red when the divergence is fixed, and it went red, and
// the reason it went red was a *bug* rather than the divergence:
// [`Document.commit`](../src/doc.zig) did not advance the isolation heads to
// the hash it had just committed, so the second isolated write forked a
// **second** concurrency actor and could not see the object the first had
// made. Both halves are gone —
// [`autocommit.rs:464-466`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs) on the heads,
// [`automerge.rs:1263-1272`](../../github-automerge-automerge/rust/automerge/src/automerge.rs) on the walk that no longer runs.
//
// **What this pins now is the property that fix restored**: two module-level
// writes inside one isolation both land, the second sees the first's object,
// and the concurrency walk stops at level 1. The counts below are still two
// changes per pair where `AutoCommit` makes one
// ([`autocommit.rs:445-457`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)); **that** is the
// lifetime divergence, it is a different document rather than a failure, and
// the module doc's "The transaction's lifetime" section has the citations.
//
// **A plain comment and not `///`.** Zig 0.16 refuses a doc comment on a
// `test` — "documentation comments cannot be attached to tests" — and the
// refusal is a compile error for the whole module, so it takes every other
// file's tests down with it rather than only this one.
test "two module writes inside one isolation both land, and the second sees the first's object" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    // `tests/test.rs:4180-4186`: a list, one element, and the heads taken
    // after that and before anything else.
    const list = try putObject(&doc, .root, .{ .key = "list" }, .list);
    _ = try insert(&doc, list, 0, .{ .str = "base" });
    const beginning = try doc.getHeads(gpa);
    defer gpa.free(beginning);

    // `tests/test.rs:4188-4191`. **Upstream makes this pair one change**:
    // `put_object` opens a transaction and `splice_text` reuses it, because
    // `AutoCommit` holds it open (`autocommit.rs:445-457`). Here it is two,
    // because each module-level call opens and commits its own.
    const first = try putObject(&doc, list, .{ .index = 0 }, .text);
    try spliceText(&doc, first, 0, 0, "first");
    try testing.expectEqual(@as(usize, 4), doc.graph.len());

    // `tests/test.rs:4194-4196`. **This used to be a refusal**, and the
    // refusal is what this test was written to explain: the second call opens
    // a *second* transaction, and at stale isolation heads
    // [`Document.isolatedActorIndex`](../src/doc.zig) finds `maxOpForActor`
    // non-zero for the fork the first call used, forks again to the next
    // concurrency level, and the object `second` — which belongs to the
    // previous fork — falls out of the new transaction's scope clock, so
    // [`Transaction.exidToObj`] answered `error.InvalidObjId`.
    //
    // **It does not any more, and both halves of the cause are gone.**
    // [`Document.commit`](../src/doc.zig) now advances the isolation to the
    // hash it just committed, which is upstream's
    // `if self.isolation.is_some() && hash.is_some() { self.isolation =
    // vec![hash] }`
    // ([`autocommit.rs:464-466`, `:735-736`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)); and
    // with the heads advanced the clock at them **covers** the level-1 fork's
    // own last op, so `isolate_actor` takes its `break` rather than walking
    // ([`automerge.rs:1263-1272`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    //
    // What is left is the **lifetime** divergence and only that: two module
    // calls are still two changes where `AutoCommit` makes one
    // ([`autocommit.rs:445-457`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)), so the
    // change and actor counts below are still the port's and not the
    // reference's.
    try doc.isolate(gpa, beginning);
    const second = try putObject(&doc, list, .{ .index = 0 }, .text);
    // **The property, not the absence of an error**: the object made by the
    // first isolated write is *visible to the second*, which is the whole of
    // what the stale heads broke. `spliceText` returning `void` is the
    // evidence; nothing here asserts that nothing threw.
    try spliceText(&doc, second, 0, 0, "second");
    try doc.integrate();

    // The concurrency walk did not run away: **one** level-1 fork, where the
    // old version had two. `withConcurrency` is applied to the document's own
    // actor ([`types.rs:78-85`](../../github-automerge-automerge/rust/automerge/src/types.rs)),
    // so a third would be `fork1.withConcurrency(1)`.
    try testing.expectEqual(@as(usize, 2), doc.numActors());
    try testing.expectEqual(@as(usize, 6), doc.graph.len());

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
    while (ai < doc.numActors()) : (ai += 1) {
        const bytes = doc.getActor(ai).?.bytes;
        if (std.mem.eql(u8, bytes, fork1.bytes)) has_fork1 = true;
        if (std.mem.eql(u8, bytes, fork2.bytes)) has_fork2 = true;
        if (std.mem.eql(u8, bytes, fork_of_fork.bytes)) has_fork_of_fork = true;
    }
    try testing.expect(has_fork1);
    try testing.expect(!has_fork2);
    try testing.expect(!has_fork_of_fork);
}

// The second half of the same divergence, isolated from the first.
//
// The refusal above has two causes and this separates them: the isolation
// heads do not advance on commit, and the transaction is not held open.
// Upstream advances them — `ensure_transaction_closed` and `commit_with` both
// run `if self.isolation.is_some() && hash.is_some() { self.isolation =
// hash.map(|h| vec![h]) }` (`autocommit.rs:464-466`, `:736-738`) — and
// [`Document.commit`](doc.zig) does not, so the second isolated transaction
// opens at stale heads and forks to the next level.
//
// **Moving them here by hand removes the refusal and leaves the count.**
// That is the statement this test makes: the heads are the small, separate
// defect, and holding the transaction open is the contract. The reference's
// one transaction answers **three** changes for the whole test; this answers
// six, on three actors.
//
// A plain comment and not `///`, for the same reason as the test above:
// Zig 0.16 refuses a doc comment on a `test`, and the refusal is a compile
// error for the whole module rather than for this file alone.
test "advancing the isolation heads by hand removes the refusal and leaves the extra changes and actors" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    const list = try putObject(&doc, .root, .{ .key = "list" }, .list);
    _ = try insert(&doc, list, 0, .{ .str = "base" });
    const beginning = try doc.getHeads(gpa);
    defer gpa.free(beginning);

    const first = try putObject(&doc, list, .{ .index = 0 }, .text);
    try spliceText(&doc, first, 0, 0, "first");

    try doc.isolate(gpa, beginning);
    const second = try putObject(&doc, list, .{ .index = 0 }, .text);

    // What upstream's commit does and this port's does not
    // ([`Document.commit`](doc.zig), `autocommit.rs:464-466`).
    const after_first = try doc.getHeads(gpa);
    defer gpa.free(after_first);
    try doc.isolate(gpa, after_first);

    // The write lands now. **It is not the same document**: it is a third
    // change, and it is written by the document's own actor rather than by the
    // isolated one, because the heads it opened at already cover everything
    // that actor has done.
    try spliceText(&doc, second, 0, 0, "second");
    try doc.integrate();

    // Three changes upstream (`tests/test.rs:4179-4208`): the base, the
    // `"first"` pair as one, and the `"second"` pair as one — and the isolated
    // pair is **one actor and one change**. Six here, and the isolated region
    // alone is two changes on **two** actors: the fork the first call made,
    // and the document's own actor for the second.
    //
    // Two actors and not three, and that is the point of the test: the advance
    // is what turns the level-2 fork of the test above back into the
    // document's own actor, so the *refusal* is the heads and the *count* is
    // the lifetime. Fixing the heads alone gets `"second"` written and still
    // does not make upstream's document.
    try testing.expectEqual(@as(usize, 6), doc.graph.len());
    try testing.expectEqual(@as(usize, 2), doc.numActors());

    // **The value agreeing is exactly why the count has to be asserted**:
    // `"second"` wins the register either way, so the hydrate cannot tell the
    // two documents apart.
    //
    // Read the **text object**, not `list[0]`: `list`'s element at index 0 is
    // the text object itself, so `get` there answers a `.object` and reading
    // `.value.scalar` off it is a union-field panic rather than a wrong
    // value. `spliceText` above wrote `"second"` into `second`, so that is
    // what answers here.
    const got = try readmod.text(&doc, second, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("second", got);
}

test "a read through a scoped transaction is scoped, and a read through the document is not" {
    const gpa = testing.allocator;
    var doc = try freshDocIn(gpa, .manual);
    defer doc.deinit();

    const text = blk: {
        var setup = try Transaction.open(gpa, &doc);
        defer setup.deinit();
        const t = try setup.putObject(.root, .{ .key = "text" }, .text);
        _ = try setup.put(.root, .{ .key = "size" }, .{ .int = 100 });
        try setup.spliceText(t, 0, 0, "abc");
        try setup.mark(t, 0, 3, "bold", .after, .{ .bool_value = true });
        _ = try setup.commit(null, null);
        break :blk t;
    };
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);

    // **The document moves on from those heads**, and the move is a mark set to
    // `Null` — a tombstone, so the present has no mark there at all.
    {
        var moved = try Transaction.open(gpa, &doc);
        defer moved.deinit();
        _ = try moved.put(.root, .{ .key = "size" }, .{ .int = 200 });
        try moved.unmark(text, 0, 3, .none, "bold", null);
        _ = try moved.commit(null, null);
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
    defer tx.deinit();

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
    _ = try tx.commit(null, null);

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
    var doc = try freshDocIn(gpa, .manual);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit();
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
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    _ = try put(&doc, .root, .{ .key = "k" }, .{ .int = 1 });
    var present = try register(gpa, &doc, "k");
    try testing.expectEqual(@as(usize, 1), present.ops.items.len);
    present.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), try delete(&doc, .root, .{ .key = "k" }));

    // **Absent.** A delete is a successor edge on the row it removes, never a
    // row of its own (`columns.rs:423`), so the register has nothing left in
    // it and a reader that answered "a null value" would be inventing one.
    var gone = try register(gpa, &doc, "k");
    defer gone.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), gone.ops.items.len);
    try testing.expectEqual(@as(usize, 0), doc.ops.seqLength(.root, doc.textEncoding(), null));
    // The row is still there, as a tombstone, and that is a different fact.
    var walk = try doc.ops.iter();
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
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    _ = try put(&doc, .root, .{ .key = "plain" }, .{ .int = 5 });
    // **`error.MissingCounter`, before anything is written** (`inner.rs:466-468`).
    try testing.expectError(
        error.MissingCounter,
        increment(&doc, .root, .{ .key = "plain" }, 1),
    );
    var plain = try register(gpa, &doc, "plain");
    defer plain.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), plain.ops.items.len);
    try testing.expectEqual(@as(i64, 5), plain.ops.items[0].value().int);

    _ = try put(&doc, .root, .{ .key = "n" }, .{ .counter = .init(10) });
    try increment(&doc, .root, .{ .key = "n" }, 7);
    var count = try register(gpa, &doc, "n");
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
    var doc = try freshDocIn(gpa, .manual);
    defer doc.deinit();

    // Empty: nothing is queued and there are no heads.
    try testing.expectEqual(@as(usize, 0), pendingOps(&doc));
    try testing.expectEqual(@as(usize, 0), baseHeads(&doc).len);

    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit();
    const base = tx.baseHeads();
    try testing.expectEqual(@as(usize, 0), base.len);

    _ = try tx.put(.root, .{ .key = "a" }, .{ .int = 1 });
    _ = try tx.put(.root, .{ .key = "b" }, .{ .int = 2 });
    _ = try tx.put(.root, .{ .key = "c" }, .{ .int = 3 });

    // **The count is the real one, not a constant and not zero.**
    try testing.expectEqual(@as(usize, 3), tx.count());
    try testing.expectEqual(@as(usize, 3), pendingOps(&doc));

    // The base has not moved: it is the heads from before the transaction.
    try testing.expectEqual(@as(usize, 0), base.len);
    try testing.expectEqualSlices(ChangeHash, base, tx.baseHeads());

    const hash = (try tx.commit(null, null)).?;
    try testing.expectEqual(@as(usize, 0), tx.count());
    try testing.expectEqual(@as(usize, 0), pendingOps(&doc));
    try testing.expectEqual(@as(usize, 1), doc.graph.len());

    // And the heads are now exactly what the next transaction is based on, so
    // `baseHeads` names what it says it names.
    const now = try doc.getHeads(gpa);
    defer gpa.free(now);
    try testing.expectEqual(@as(usize, 1), now.len);
    try testing.expect(now[0].eql(hash));
    try testing.expectEqual(@as(usize, 1), baseHeads(&doc).len);
    try testing.expect(baseHeads(&doc)[0].eql(hash));

    // A second transaction's base is that head, and the change it commits
    // depends on it.
    var second = try Transaction.open(gpa, &doc);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.baseHeads().len);
    try testing.expect(second.baseHeads()[0].eql(hash));
    _ = try second.put(.root, .{ .key = "d" }, .{ .int = 4 });
    _ = try second.commit(null, null);
    try testing.expectEqual(@as(usize, 2), doc.graph.len());
}

test "a rollback restores the document exactly" {
    const gpa = testing.allocator;
    var doc = try freshDocIn(gpa, .manual);
    defer doc.deinit();

    // A document with something in it, and a byte-for-byte copy of it. **Every
    // write goes through a `Transaction`,** because this document is in
    // [`Mode.manual`] and the module functions are the autocommit door.
    {
        var setup = try Transaction.open(gpa, &doc);
        defer setup.deinit();
        _ = try setup.put(.root, .{ .key = "keep" }, .{ .str = "before" });
        const list = try setup.putObject(.root, .{ .key = "l" }, .list);
        _ = try setup.insert(list, 0, .{ .int = 1 });
        _ = try setup.insert(list, 1, .{ .int = 2 });
        const text = try setup.putObject(.root, .{ .key = "t" }, .text);
        try setup.spliceText(text, 0, 0, "hello");
        try setup.mark(text, 1, 3, "em", .both, .{ .bool_value = true });
        _ = try setup.commit(null, null);
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
    var before = try doc.clone(gpa, .auto);
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
    try testing.expectEqual(@as(usize, 4), pendingOps(&doc));
    try testing.expectEqual(@as(usize, 4), try tx.rollback());
    tx.deinit();

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
    try testing.expectEqual(@as(usize, 0), pendingOps(&doc));

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
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
        _ = try spliceText(&doc, text, 0, 0, "abcd");
        try mark(&doc, text, 1, 3, "em", .none, .{ .bool_value = true });
        _ = try spliceText(&doc, text, 1, 0, "X");

        const got = try doc.text(gpa, text);
        defer gpa.free(got);
        try testing.expectEqualStrings("aXbcd", got);
        const marks = try doc.marks(gpa, text);
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
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
        _ = try spliceText(&doc, text, 0, 0, "abcd");
        try mark(&doc, text, 1, 3, "em", .before, .{ .bool_value = true });
        _ = try spliceText(&doc, text, 1, 0, "X");

        const got = try doc.text(gpa, text);
        defer gpa.free(got);
        try testing.expectEqualStrings("aXbcd", got);
        const marks = try doc.marks(gpa, text);
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
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
        _ = try spliceText(&doc, text, 0, 0, "abcd");
        try mark(&doc, text, 1, 3, "em", .after, .{ .bool_value = true });
        _ = try spliceText(&doc, text, 1, 0, "X");

        const marks = try doc.marks(gpa, text);
        defer gpa.free(marks);
        try testing.expectEqual(@as(usize, 1), marks.len);
        try testing.expectEqual(@as(usize, 2), marks[0].start);
        try testing.expectEqual(@as(usize, 4), marks[0].end);
    }

    // **At the mark's end, index 3.** Here the flag that decides is the end's,
    // and the two that leave `X` outside are the two whose end does not expand.
    {
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
        _ = try spliceText(&doc, text, 0, 0, "abcd");
        try mark(&doc, text, 1, 3, "em", .both, .{ .bool_value = true });
        _ = try spliceText(&doc, text, 3, 0, "X");

        const got = try doc.text(gpa, text);
        defer gpa.free(got);
        try testing.expectEqualStrings("abcXd", got);
        const marks = try doc.marks(gpa, text);
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
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
        _ = try spliceText(&doc, text, 0, 0, "abcd");
        try mark(&doc, text, 1, 3, "em", .before, .{ .bool_value = true });
        _ = try spliceText(&doc, text, 3, 0, "X");

        const got = try doc.text(gpa, text);
        defer gpa.free(got);
        try testing.expectEqualStrings("abcXd", got);
        const marks = try doc.marks(gpa, text);
        defer gpa.free(marks);
        try testing.expectEqual(@as(usize, 1), marks.len);
        try testing.expectEqualStrings("em", marks[0].name);
        try testing.expectEqual(@as(usize, 1), marks[0].start);
        try testing.expectEqual(@as(usize, 3), marks[0].end);
    }
    {
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
        _ = try spliceText(&doc, text, 0, 0, "abcd");
        try mark(&doc, text, 1, 3, "em", .none, .{ .bool_value = true });
        _ = try spliceText(&doc, text, 3, 0, "X");

        const marks = try doc.marks(gpa, text);
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
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
    const changes_before = doc.graph.len();

    _ = try spliceText(&doc, text, 0, 0, "0123456789");

    // **One change.** Ten operations, one `OpSet.splice` (`Batch.finish`).
    try testing.expectEqual(changes_before + 1, doc.graph.len());
    // The text object itself is a row, so eleven rows and ten characters.
    try testing.expectEqual(@as(usize, 11), doc.ops.len());

    const got = try doc.text(gpa, text);
    defer gpa.free(got);
    try testing.expectEqualStrings("0123456789", got);

    // **Ten rows, contiguous, and in the order the batch built them.** The
    // object owns every row after the one that created it: no gap, and nothing
    // from another object in between. That is the property
    // `BatchInsertion::next_pos` assumes when it predicts where each queued
    // operation will land (`inner.rs:1460-1462`).
    const rows = try doc.ops.scopeToObj(text);
    try testing.expectEqual(@as(usize, 1), rows.start);
    try testing.expectEqual(@as(usize, 11), rows.end);
    try testing.expectEqual(doc.ops.len(), rows.end);

    // **`Op.step` is the row-order rule itself** (`op.rs:1048-1071`): the
    // object may not go backwards, the register may not go backwards inside it,
    // and the id may not go backwards or repeat inside one register. Walking
    // every row through it is what says the batch landed where it was asked to
    // rather than somewhere the reader happens to accept.
    var stepper = opmod.OpStepper.initial();
    var previous: ?Op = null;
    var in_object: usize = 0;
    for (0..doc.ops.len()) |pos| {
        const at = (try doc.ops.get(pos)).?;
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
    try testing.expect(try doc.ops.validateOpOrder());
}

test "an empty document and a non-object target are refusals, not traps" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    // **A non-object target.** `error.NotAnObject`, not a trap: the document
    // has no such object, and every reader in the tree answers this the same
    // way.
    try testing.expectError(
        error.NotAnObject,
        put(&doc, .{ .id = OpId.init(99, 0) }, .{ .key = "k" }, .{ .int = 1 }),
    );
    try testing.expectEqual(@as(usize, 0), doc.graph.len());
    try testing.expectEqual(@as(usize, 0), doc.ops.len());

    // **The wrong kind of object for the method**, which is `error.InvalidOp`
    // and the same refusal upstream gives (`inner.rs:616-618`).
    try testing.expectError(
        error.InvalidOp,
        spliceText(&doc, .root, 0, 0, "x"),
    );
    const list = try putObject(&doc, .root, .{ .key = "l" }, .list);
    try testing.expectError(
        error.InvalidOp,
        spliceText(&doc, list, 0, 0, "x"),
    );

    // **An index past the end of a sequence** is `error.InvalidIndex`
    // (`insert.zig:136-137`), again not a trap.
    try testing.expectError(
        error.InvalidIndex,
        insert(&doc, list, 5, .{ .int = 1 }),
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
    const changes = doc.graph.len();
    const rows = doc.ops.len();
    try testing.expectEqual(@as(usize, 0), try delete(&doc, list, .{ .key = "k" }));
    try testing.expectEqual(changes, doc.graph.len());
    try testing.expectEqual(rows, doc.ops.len());
}

test "the wrong door is an error: the module functions want autocommit and a transaction wants manual" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io, .manual);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "0123456789abcdef" });

    // The module functions are `AutoCommit`, and this document is `Automerge`.
    try testing.expectError(error.InvalidOp, put(&doc, .root, .{ .key = "k" }, .{ .int = 1 }));
    try testing.expectError(error.InvalidOp, delete(&doc, .root, .{ .key = "k" }));
    try testing.expectEqual(@as(usize, 0), doc.graph.len());

    // And the other way round. **Nothing was written on either refusal**, which
    // is the half that matters: an error that leaves a document half-changed is
    // worse than a trap in a file that has already been read.
    var auto = try freshDoc(gpa);
    defer auto.deinit();
    try testing.expectError(error.InvalidOp, Transaction.open(gpa, &auto));
    try testing.expectError(error.InvalidOp, Transaction.openAt(gpa, &auto, null));
    try testing.expectEqual(@as(usize, 0), auto.graph.len());
    try testing.expectEqual(@as(usize, 0), auto.ops.len());
}

test "a transaction commits nothing when it wrote nothing, and a second commit is refused" {
    const gpa = testing.allocator;
    var doc = try freshDocIn(gpa, .manual);
    defer doc.deinit();

    var first = try Transaction.open(gpa, &doc);
    _ = try first.put(.root, .{ .key = "k" }, .{ .int = 1 });
    _ = try first.commit(null, null);
    first.deinit();
    try testing.expectEqual(@as(usize, 1), doc.graph.len());

    var again = try Transaction.open(gpa, &doc);
    _ = try again.put(.root, .{ .key = "k" }, .{ .int = 1 });
    // A redundant `put` writes no operation (`op_set.rs:1489-1492`), so there
    // is nothing to commit and no change to add.
    try testing.expectEqual(@as(usize, 0), again.count());
    try testing.expect((try again.commit(null, null)) == null);
    again.deinit();
    try testing.expectEqual(@as(usize, 1), doc.graph.len());

    // **A second commit is refused**, because upstream takes the inner out of
    // its `Option` before the first one (`manual_transaction.rs:135-145`) and
    // an application twice is a bug rather than a no-op.
    var empty = try Transaction.open(gpa, &doc);
    defer empty.deinit();
    try testing.expect((try empty.commit(null, null)) == null);
    try testing.expectError(error.InvalidOp, empty.commit(null, null));
    try testing.expectError(error.InvalidOp, empty.rollback());
    try testing.expectEqual(@as(usize, 1), doc.graph.len());
}

test "putObject creates an object the document then reports as one" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    const map = try putObject(&doc, .root, .{ .key = "m" }, .map);
    const list = try putObject(&doc, .root, .{ .key = "l" }, .list);
    const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
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
        putObject(&doc, text, .{ .index = 0 }, .map),
    );
}

test "insert and delete on a list move the element ids" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    const list = try putObject(&doc, .root, .{ .key = "l" }, .list);

    const a = try insert(&doc, list, 0, .{ .int = 1 });
    const b = try insert(&doc, list, 1, .{ .int = 2 });
    try testing.expectEqual(@as(usize, 2), doc.ops.seqLength(list, doc.textEncoding(), null));

    // An insert's id is also its element id (`op.rs:1140-1146`), so the
    // elements are addressable by the ids `insert` returned — and `index` is
    // the position a reader would put them at, which is what makes the two
    // seeks a statement about where the elements are rather than about the
    // ids resolving.
    {
        const at = (try doc.ops.seekListOpid(list, a, .list, null)).?;
        try testing.expectEqual(@as(usize, 0), at.index);
        try testing.expect(at.visible);
    }
    {
        const at = (try doc.ops.seekListOpid(list, b, .list, null)).?;
        try testing.expectEqual(@as(usize, 1), at.index);
        try testing.expect(at.visible);
    }

    try testing.expectEqual(@as(usize, 1), try delete(&doc, list, .{ .index = 0 }));
    try testing.expectEqual(@as(usize, 1), doc.ops.seqLength(list, doc.textEncoding(), null));

    // **The element after the deleted one moved down.** `index` counts the
    // winners in front of the row (`op_set.rs:866-868`), so a delete that
    // stopped contributing took `b` from 1 to 0. This is the half of the test
    // that a reader which merely stopped returning `a` would also pass, which
    // is why it is here.
    {
        const at = (try doc.ops.seekListOpid(list, b, .list, null)).?;
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
        const at = (try doc.ops.seekListOpid(list, a, .list, null)).?;
        try testing.expect(!at.visible);
        try testing.expect(!at.op.visible());
    }
    // And an id from another object is a null, which is the answer that was
    // being expected of a deleted one.
    try testing.expectEqual(
        @as(?opsetmod.FoundOpId, null),
        try doc.ops.seekListOpid(list, OpId.root, .list, null),
    );
}

test "mark, unmark and the block methods on a text object" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
    _ = try spliceText(&doc, text, 0, 0, "abcdef");

    const block = try splitBlock(&doc, text, 3);
    try testing.expectEqual(ObjType.map, try doc.objectType(block));
    // **A block is one position wide, and a split only inserts**
    // (`split_block` splices one `Make(Map)` row and removes nothing,
    // `inner.rs:905-916`), so six characters and one block are seven
    // positions. The block's own width is one whatever it holds — `Op.width`'s
    // `.list` arm, and a block row is the "anything else" case in
    // `seq_length`, which measures it as one U+FFFC (`op_set.rs:443-447`).
    try testing.expectEqual(@as(usize, 7), doc.ops.seqLength(text, doc.textEncoding(), null));

    _ = try put(&doc, block, .{ .key = "kind" }, .{ .str = "para" });
    try joinBlock(&doc, text, 3);
    // **And a join only deletes** (`join_block`, `inner.rs:931-937`), so the
    // six characters are all that is left and the block is gone.
    try testing.expectEqual(@as(usize, 6), doc.ops.seqLength(text, doc.textEncoding(), null));
    const joined = try doc.text(gpa, text);
    defer gpa.free(joined);
    try testing.expectEqualStrings("abcdef", joined);

    const again = try replaceBlock(&doc, text, 1);
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
    try testing.expectEqual(@as(usize, 6), doc.ops.seqLength(text, doc.textEncoding(), null));
    const replaced = try doc.text(gpa, text);
    defer gpa.free(replaced);
    try testing.expectEqualStrings("a\u{fffc}cdef", replaced);

    // **An unmark leaves no mark behind**, which is the tombstone rule
    // (`op_set.rs:1023`): a mark whose value is null is dropped on the way out.
    try mark(&doc, text, 0, 2, "em", .after, .{ .bool_value = true });
    const before = try doc.marks(gpa, text);
    try testing.expectEqual(@as(usize, 1), before.len);
    gpa.free(before);
    try unmark(&doc, text, 0, 2, .after, "em", null);
    const after = try doc.marks(gpa, text);
    defer gpa.free(after);
    try testing.expectEqual(@as(usize, 0), after.len);
}

test "a zero-width mark with no expansion writes nothing" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
    _ = try spliceText(&doc, text, 0, 0, "abc");
    const changes = doc.graph.len();
    const rows = doc.ops.len();

    // `inner.rs:813-825` — a mark from 1 to 1 with `ExpandMark::None` is a
    // begin and an end at the same anchor, and upstream writes nothing.
    try mark(&doc, text, 1, 1, "em", .none, .{ .bool_value = true });
    try testing.expectEqual(changes, doc.graph.len());
    try testing.expectEqual(rows, doc.ops.len());
    try testing.expectEqual(@as(usize, 0), pendingOps(&doc));
}

test "a spliced list of hydrated values is written in two batches" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    const list = try putObject(&doc, .root, .{ .key = "l" }, .list);

    var nested = hydmod.List.init(gpa, .root);
    defer nested.deinit();
    try nested.push(hydmod.Value.scalar(.{ .int = 7 }), false);

    var values = [_]hydmod.Value{
        hydmod.Value.scalar(.{ .int = 1 }),
        .{ .object = .{ .list = nested } },
        hydmod.Value.scalar(.{ .str = "three" }),
    };
    const changes = doc.graph.len();
    try splice(&doc, list, 0, 0, gpa, &values);
    // **One change for the whole splice**, however many objects it made.
    try testing.expectEqual(changes + 1, doc.graph.len());
    try testing.expectEqual(@as(usize, 3), doc.ops.seqLength(list, doc.textEncoding(), null));

    // The nested list is there and holds what it was given.
    var found = try doc.ops.seekOpsByIndex(gpa, list, 1, .list, null);
    defer found.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), found.ops.items.len);
    const inner = doc.ops.idToExid(found.ops.items[0].id());
    try testing.expectEqual(ObjType.list, try doc.objectType(inner));
    try testing.expectEqual(@as(usize, 1), doc.ops.seqLength(inner, doc.textEncoding(), null));

    // And a scalar spliced into a text object is the strings joined, or a
    // refusal (`inner.rs:1391-1405`).
    const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
    var words = [_]hydmod.Value{
        hydmod.Value.scalar(.{ .str = "ab" }),
        hydmod.Value.scalar(.{ .str = "cd" }),
    };
    try splice(&doc, text, 0, 0, gpa, &words);
    const got = try doc.text(gpa, text);
    defer gpa.free(got);
    try testing.expectEqualStrings("abcd", got);
    var not_a_string = [_]hydmod.Value{hydmod.Value.scalar(.{ .int = 1 })};
    try testing.expectError(
        error.InvalidValueType,
        splice(&doc, text, 0, 0, gpa, &not_a_string),
    );
}

test "initRootFromHydrate fills the root, and updateObject brings a map in line" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
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

    try initRootFromHydrate(&doc, root);
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
    var zed = try register(gpa, &doc, "z");
    defer zed.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), zed.ops.items.len);
    const inner = doc.ops.idToExid(zed.ops.items[0].id());
    var a = try registerIn(gpa, &doc, inner, "a");
    defer a.deinit(gpa);
    var b = try registerIn(gpa, &doc, inner, "b");
    defer b.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), a.ops.items.len);
    try testing.expectEqual(@as(usize, 1), b.ops.items.len);
    try testing.expect(a.ops.items[0].id().order(b.ops.items[0].id()) == .lt);
    try testing.expectEqual(@as(i64, 1), a.ops.items[0].value().int);
    try testing.expectEqual(@as(i64, 2), b.ops.items[0].value().int);

    var why = try register(gpa, &doc, "y");
    defer why.deinit(gpa);
    try testing.expectEqualStrings("why", why.ops.items[0].value().str);

    // `updateObject` writes what is new and deletes what is gone.
    var replacement = hydmod.Map.init(gpa, .root);
    defer replacement.deinit();
    try replacement.putOwned("a", hydmod.MapValue.init(hydmod.Value.scalar(.{ .int = 10 }), false));
    try updateObject(&doc, inner, replacement);

    var a2 = try registerIn(gpa, &doc, inner, "a");
    defer a2.deinit(gpa);
    try testing.expectEqual(@as(i64, 10), a2.ops.items[0].value().int);
    var b2 = try registerIn(gpa, &doc, inner, "b");
    defer b2.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), b2.ops.items.len);
}

test "updateMapValue numbers its operations depth first, and the row order is not that order" {
    const gpa = testing.allocator;
    var doc = try freshDocIn(gpa, .manual);
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
    defer tx.deinit();
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

    _ = try tx.commit(null, null);

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
    var doc = try freshDocIn(gpa, .manual);
    defer doc.deinit();

    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit();
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
    _ = try tx.commit(null, null);

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
    defer tx2.deinit();
    const again = try tx2.putObject(.root, .{ .key = "c2" }, .map);
    _ = try tx2.put(again, .{ .key = "x" }, .{ .int = 1 });
    _ = try tx2.rollback();
    try testing.expectError(error.InvalidOp, tx2.put(again, .{ .key = "y" }, .{ .int = 2 }));
}

test "updateText is a diff: an unchanged text writes no operation" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
    _ = try spliceText(&doc, text, 0, 0, "hello world");

    const changes = doc.graph.len();
    const rows = doc.ops.len();
    try updateText(&doc, text, "hello world");
    // **No change at all**, which is the property a write and a diff share and
    // only a diff has.
    try testing.expectEqual(changes, doc.graph.len());
    try testing.expectEqual(rows, doc.ops.len());

    try updateText(&doc, text, "hello there");
    const got = try doc.text(gpa, text);
    defer gpa.free(got);
    try testing.expectEqualStrings("hello there", got);
    try testing.expect(doc.graph.len() > changes);
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
    var clean = try freshDoc(gpa);
    defer clean.deinit();
    const clean_text = try putObject(&clean, .root, .{ .key = "t" }, .text);
    _ = try spliceText(&clean, clean_text, 0, 0, "hello world");
    const want = clean.graph.getHeads();
    try testing.expectEqual(@as(usize, 1), want.len);

    var dirty = try freshDoc(gpa);
    defer dirty.deinit();
    const dirty_text = try putObject(&dirty, .root, .{ .key = "t" }, .text);

    var buf: [11]u8 = "hello world".*;
    var tx = try openAuto(gpa, &dirty);
    defer tx.deinit();
    try tx.spliceText(dirty_text, 0, 0, &buf);
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
    const got = (try tx.commit(null, null)).?;

    try testing.expect(want[0].eql(got));
}

test "batchCreateObject makes an empty object, and batchCreateValue fills it" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();

    const empty = try batchCreateObject(&doc, .root, .{ .key = "e" }, .map);
    try testing.expectEqual(ObjType.map, try doc.objectType(empty));
    try testing.expectEqual(@as(usize, 0), doc.ops.seqLength(empty, doc.textEncoding(), null));

    var inner = hydmod.Map.init(gpa, .root);
    defer inner.deinit();
    try inner.putOwned("n", hydmod.MapValue.init(hydmod.Value.scalar(.{ .int = 4 }), false));
    const full = try batchCreateValue(&doc, .root, .{ .key = "f" }, .{ .object = .{ .map = inner } }, false);
    try testing.expectEqual(ObjType.map, try doc.objectType(full));
    // **The child key is in the child object, not in the root.** `full` is the
    // object row 1 made and the batch wrote `"n"` under it
    // (`inner.rs:1269-1331`), so looking the key up at the root finds nothing
    // — and it used to find something, because the child's `ExId` came back
    // as the root and the batch wrote into the root by mistake. Both halves
    // are asserted: the value is where it belongs **and** it is not where it
    // used to land by accident.
    var n = try doc.ops.seekOpsByMapKey(gpa, full, "n", null);
    defer n.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), n.ops.items.len);
    try testing.expectEqual(@as(i64, 4), n.ops.items[0].value().int);
    var stray = try register(gpa, &doc, "n");
    defer stray.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), stray.ops.items.len);

    // A list position and an object value: the `insert` form.
    const list = try putObject(&doc, .root, .{ .key = "l" }, .list);
    const nested = try batchCreateValue(&doc, list, .{ .index = 0 }, .{ .object = .{ .map = inner } }, true);
    try testing.expectEqual(ObjType.map, try doc.objectType(nested));
    try testing.expectEqual(@as(usize, 1), doc.ops.seqLength(list, doc.textEncoding(), null));

    // A scalar is not an object (`inner.rs:1288-1293`).
    try testing.expectError(
        error.NotAnObject,
        batchCreateValue(&doc, .root, .{ .key = "s" }, hydmod.Value.scalar(.{ .int = 1 }), false),
    );
}

test "updateSpans brings a text object's spans and marks in line" {
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    const text = try putObject(&doc, .root, .{ .key = "t" }, .text);
    _ = try spliceText(&doc, text, 0, 0, "hello");

    // One span of text carrying one mark, which the document does not have.
    var marks = MarkSet.init(gpa);
    defer marks.deinit();
    try marks.put("em", .{ .bool_value = true });

    var spans = [_]Span{.{ .text = .{ .text = try gpa.dupe(u8, "hello"), .marks = marks } }};
    defer gpa.free(spans[0].text.text);
    try updateSpans(&doc, text, &spans);

    const got = try doc.text(gpa, text);
    defer gpa.free(got);
    try testing.expectEqualStrings("hello", got);
    const found = try doc.marks(gpa, text);
    defer gpa.free(found);
    // **The mark the spans asked for exists.** The text diff cannot see a mark
    // — it compares grapheme clusters — so the second pass is the only thing
    // that can have written it.
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("em", found[0].name);
    try testing.expectEqual(@as(usize, 0), found[0].start);
    try testing.expectEqual(@as(usize, 5), found[0].end);

    // Running it again writes nothing: the mark is already there.
    const rows = doc.ops.len();
    try updateSpans(&doc, text, &spans);
    try testing.expectEqual(rows, doc.ops.len());
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

/// A document in [`Mode.auto`] under `actor`. Two documents that reach the
/// same state by different doors have to be different actors, or the second
/// one would answer "already have it".
fn docWithActor(gpa: Allocator, actor: []const u8) !Document {
    var doc = try Document.init(gpa, std.testing.io, .auto);
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
    var doc = try docWithActor(gpa, "aaaaaaaaaaaaaaaa");
    defer doc.deinit();

    // **The write order is not the key order, and `"k"` sorts before
    // `"list"`.** This is the two-row document the defect was reported on.
    _ = try put(&doc, .root, .{ .key = "list" }, .{ .int = 1 });
    _ = try put(&doc, .root, .{ .key = "k" }, .{ .int = 2 });

    // The same two changes through the other door: the apply path, which is
    // where upstream asserts the order.
    var replay = try docWithActor(gpa, "bbbbbbbbbbbbbbbb");
    defer replay.deinit();
    try applyAll(gpa, &replay, &doc);

    // **The diagnostic runs first**, so that a document out of row order
    // fails with the row and the side on the line above the assertion rather
    // than with `expected true, found false`.
    try reportRowOrder(&doc, &replay);

    // **The checker.** Rules R1–R4 of [`Op.step`](opset/op.zig)
    // ([`op.rs:1048-1073`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    // over every row. This answers `false` on the document as it was written.
    try testing.expect(try doc.ops.validateOpOrder());
    try testing.expect(try replay.ops.validateOpOrder());

    // **The read, which is what makes this a correctness defect and not a
    // tidiness one.** A map reader does not sort — "the reader does not sort,
    // so this order is the answer order"
    // ([`map_range.zig:1486-1490`](iter/map_range.zig)) — so a document whose
    // registers are in the wrong row order **reads back as a different map**.
    // **This is the assertion a by-value comparison cannot make**: the two
    // documents below hold the same rows and the same values, so they compare
    // equal while reading back in opposite orders.
    const keys = try rootKeys(gpa, &doc);
    defer gpa.free(keys);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqualStrings("k", keys[0]);
    try testing.expectEqualStrings("list", keys[1]);

    // **And the two doors agree**, which is what the apply path's own
    // `debug_assert!` is asking.
    try testing.expect((try doc.ops.debugDiff(&replay.ops)) == null);
}

test "a register's rows ascend in id, because a local id is above every counter in the document" {
    const gpa = testing.allocator;

    // A peer that reaches counter 6 before it writes the register under test,
    // so the row it leaves in `"k"` carries the greater id. `"junk"` sorts
    // before `"k"`, so the two registers are in key order and only **R3** is
    // under test here.
    var peer = try docWithActor(gpa, "bbbbbbbbbbbbbbbb");
    defer peer.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try put(&peer, .root, .{ .key = "junk" }, .{ .int = @intCast(i) });
    }
    _ = try put(&peer, .root, .{ .key = "k" }, .{ .int = 99 });

    var doc = try docWithActor(gpa, "aaaaaaaaaaaaaaaa");
    defer doc.deinit();
    try applyAll(gpa, &doc, &peer);

    // **This actor has written nothing**, so its own next counter is 1, and
    // `1` sorts *below* the peer's `6`. `start_op` is
    // `change_graph.max_op() + 1`
    // ([`automerge.rs:567`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // — **the whole document's maximum, not this actor's own next counter** —
    // and [`TransactionInner::next_id`] adds the pending count
    // ([`inner.rs:294-296`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    // so the row about to be written is `7` and appending at the register's
    // end keeps R3. **This is why the register path can append unconditionally
    // and only the absent-key path has to search, and it is asserted rather
    // than reasoned about: a `start_op` that were per-actor would put `1` after
    // `6` here and `validateOpOrder` would answer `false`.**
    const id = try put(&doc, .root, .{ .key = "k" }, .{ .int = 100 });
    try testing.expectEqual(@as(u32, 7), id.counter);

    const ids = try registerIds(gpa, &doc, "k");
    defer gpa.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expect(ids[0].order(ids[1]) == .lt);
    try testing.expect(try doc.ops.validateOpOrder());

    // The `top` index still agrees with the rows, which a register with two
    // rows and one visible winner is the easy way to break.
    try testing.expect((try doc.ops.validateTopIndex()) == null);
}

test "a list insert lands where the sequence order says, not where the write happened" {
    const gpa = testing.allocator;
    var doc = try docWithActor(gpa, "aaaaaaaaaaaaaaaa");
    defer doc.deinit();

    const list = try putObject(&doc, .root, .{ .key = "l" }, .list);
    _ = try insert(&doc, list, 0, .{ .str = "a" });
    _ = try insert(&doc, list, 1, .{ .str = "b" });
    _ = try insert(&doc, list, 2, .{ .str = "c" });
    // Two more, both at a **position** rather than at the end.
    _ = try insert(&doc, list, 0, .{ .str = "z" });
    _ = try insert(&doc, list, 2, .{ .str = "y" });

    var replay = try docWithActor(gpa, "bbbbbbbbbbbbbbbb");
    defer replay.deinit();
    try applyAll(gpa, &replay, &doc);
    try reportRowOrder(&doc, &replay);

    // **A sequence register's key is the element it hangs by, so R2's sequence
    // arm is a different rule from a map key's** — the previous key may equal
    // this one, or the row's own id must sort below that element's
    // ([`op.rs:1061-1063`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
    // — **and the list path never went through `propRange`**, so it is
    // checked here rather than assumed. The same answer from the apply path
    // is the control: the two were already equal before the map fix and are
    // equal now.
    try testing.expect(try doc.ops.validateOpOrder());
    try testing.expect((try doc.ops.validateTopIndex()) == null);
    try testing.expect((try doc.ops.debugDiff(&replay.ops)) == null);

    // **The read.** The five values, in the order the sequence walks them, is
    // what says the two insertions went where they were asked to go rather
    // than merely that the rows are in some legal order.
    var term: readmod.ValueTerm = undefined;
    var it = try readmod.values(&doc, list, &term);
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
// * **The row a map write lands on is computed here, not by `propRange`, and
//   that is a deviation with a cause.** Upstream's `local_map_op` writes
//   `query.end_pos` and stops there
//   ([`inner.rs:473`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
//   because upstream's `end_pos` is `prop_range(obj, prop).end`
//   ([`op_set.rs:611-628`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs))
//   and `prop_range` is `key_str.scope_to_value(Some(prop), obj_range)`
//   ([`op_set.rs:1268-1271`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
//   which is **a descent into a sorted column**: hexane answers the sorted
//   insertion point for a value the column does not hold — over
//   `aaa aaa bbb bbb bbb ccc`, `"aab"` answers `2..2` and `"ddd"` answers `6..6`
//   ([`hexane/src/tests.rs:3464-3476`](../../github-automerge-automerge/rust/hexane/src/tests.rs)).
//   The port's `key_str` holds **interned ids**, which are in first-seen order
//   and not key order, so a descent is not available and `propRange` walks
//   instead ([op_set.zig:2056-2071](opset/op_set.zig)). **A walk that finds
//   nothing has no sorted place to stop at, so it answers the object's end** —
//   which is the answer for a key greater than every key the object holds,
//   and the wrong answer for every other absent key. The new register then
//   landed behind registers it sorts before, **rule R2** (`op.rs:1059-1060`)
//   was broken, and because a map reader does not sort
//   ([`map_range.zig:1486-1490`](iter/map_range.zig)) the document read back
//   as a **different map**. So [`mapKeyRow`] supplies the one position
//   `propRange` cannot: the first row of the object whose key sorts above the
//   new one.
//
//   **The same gap is still open in `OpSet.mapRange`**
//   ([op_set.zig:2584-2600](opset/op_set.zig)), which takes its two key bounds
//   from `propRange` as well: a key-span read whose bounds are absent from the
//   object still starts and ends in the wrong place. That is a reader, and
//   `op_set.zig` was read-only for this change — **it is reported, not fixed.**
//
// * **R3 holds on this path by construction, and that is why only the
//   absent-key case searches.** `start_op` is `change_graph.max_op() + 1`
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
        var doc = try Document.init(gpa, testing.io, .manual);
        defer doc.deinit();
        doc.setActorId(types.ActorId.init("rollback-regression"));
        {
            var first = try Transaction.open(gpa, &doc);
            defer first.deinit();
            _ = try first.put(.root, .{ .key = "baseline" }, .{ .int = 7 });
            _ = try first.commit(null, null);
        }
        try doc.updateDiffCursor();
        var tx = try Transaction.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(.root, .{ .key = "uncommitted" }, .{ .int = 42 });
        failing.fail_index = failing.alloc_index + offset;
        const hash = tx.commit("refused", 9) catch |commit_error| {
            failing.fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, commit_error);
            try testing.expect(!tx.closed);
            try testing.expectEqual(@as(usize, 1), doc.graph.len());
            try testing.expectEqual(@as(usize, 1), try tx.rollback());
            try testing.expect((try readmod.get(&doc, .root, .{ .key = "uncommitted" })) == null);
            try testing.expectEqual(@as(i64, 7), (try readmod.get(&doc, .root, .{ .key = "baseline" })).?.value.scalar.int);
            var patches = try doc.diffIncremental(gpa);
            defer patches.deinit();
            try testing.expectEqual(@as(usize, 0), patches.len());
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        try testing.expect(hash != null);
        try testing.expectEqual(@as(usize, 2), doc.graph.len());
        reached_success = true;
        break;
    }
    try testing.expect(reached_success);
}

test "textFor refusal preserves the previous borrowed buffer" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var doc = try Document.init(gpa, testing.io, .manual);
    defer doc.deinit();
    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit();
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
    // Reject a scalar write into committed text before producer publication.
    // The refusal must not turn an unchanged document into recovery-only state.
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    const text = try putObject(&doc, .root, .{ .key = "text" }, .text);
    try spliceText(&doc, text, 0, 0, "original");
    const rows = doc.ops.len();
    const changes = doc.graph.len();
    const max_op = doc.graph.maxOp();

    try testing.expectError(error.InvalidOp, put(&doc, text, .{ .key = "scalar" }, .{ .int = 7 }));
    const unchanged = try readmod.text(&doc, text, gpa);
    defer gpa.free(unchanged);
    try testing.expectEqualStrings("original", unchanged);
    try testing.expect(doc.auto_recovery == null);
    try testing.expectEqual(@as(usize, 0), pendingOps(&doc));
    try testing.expectEqual(rows, doc.ops.len());
    try testing.expectEqual(changes, doc.graph.len());
    try testing.expectEqual(max_op, doc.graph.maxOp());
    try testing.expectEqual(@as(usize, 0), try doc.recoverAuto());

    try spliceText(&doc, text, 8, 0, "!");
    const following = try readmod.text(&doc, text, gpa);
    defer gpa.free(following);
    try testing.expectEqualStrings("original!", following);
    try testing.expect(doc.auto_recovery == null);
}

test "native fresh-document validation refusal leaves unused actor metadata readable" {
    // Opening the refused write interns an actor, but publishes no operation.
    // Document-owned metadata must not keep an empty transaction in recovery.
    const gpa = testing.allocator;
    var doc = try freshDoc(gpa);
    defer doc.deinit();
    try testing.expectError(error.InvalidOp, put(&doc, .root, .{ .index = 0 }, .{ .int = 7 }));
    try testing.expect((try readmod.get(&doc, .root, .{ .key = "text" })) == null);
    try testing.expect(doc.auto_recovery == null);
    try testing.expectEqual(@as(usize, 0), pendingOps(&doc));
    try testing.expectEqual(@as(usize, 0), doc.ops.len());
    try testing.expectEqual(@as(usize, 0), doc.graph.len());
    try testing.expectEqual(@as(u64, 0), doc.graph.maxOp());
    try testing.expectEqual(doc.ops.actors.items.len, doc.graph.numActors());
    try testing.expectEqual(doc.ops.actors.items.len, doc.authors.count());
    try testing.expectEqualStrings("0123456789abcdef", doc.getActorId().bytes);
    try testing.expectEqual(@as(usize, 0), try doc.recoverAuto());

    const text = try putObject(&doc, .root, .{ .key = "text" }, .text);
    try spliceText(&doc, text, 0, 0, "fresh");
    const following = try readmod.text(&doc, text, gpa);
    defer gpa.free(following);
    try testing.expectEqualStrings("fresh", following);
    try testing.expect(doc.auto_recovery == null);
}

test "isolated native auto refusal recovers before another write without id collisions" {
    // Each offset starts with a fresh fixture: a late refusal must exercise
    // published rows, not capacities warmed by an earlier failed attempt.
    var reached_success = false;
    var reached_published_refusal = false;
    var reached_second_refusal = false;
    for (0..512) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        try doc.isolate(gpa, &.{});
        failing.fail_index = failing.alloc_index + offset;
        const refused = put(&doc, .root, .{ .key = "a" }, .{ .int = 41 });
        if (refused) |_| {
            failing.fail_index = std.math.maxInt(usize);
            reached_success = true;
            break;
        } else |primary| {
            try testing.expectEqual(error.OutOfMemory, primary);
            const published = doc.ops.len() != 0;
            if (published) {
                reached_published_refusal = true;
                // Refuse the recovery attempt as well, then restore allocation.
                // The second call must not allocate another operation id.
                failing.fail_index = failing.alloc_index;
                try testing.expectError(error.OutOfMemory, put(&doc, .root, .{ .key = "blocked" }, .{ .int = 99 }));
                try testing.expect(doc.auto_recovery != null);
                try testing.expectEqual(@as(u64, 0), doc.graph.maxOp());
                reached_second_refusal = true;
            }
            failing.fail_index = std.math.maxInt(usize);
            const following = try put(&doc, .root, .{ .key = "b" }, .{ .int = 42 });
            try testing.expect((try readmod.get(&doc, .root, .{ .key = "a" })) == null);
            try testing.expect((try readmod.get(&doc, .root, .{ .key = "blocked" })) == null);
            try testing.expectEqual(@as(i64, 42), (try readmod.get(&doc, .root, .{ .key = "b" })).?.value.scalar.int);
            try testing.expectEqual(@as(usize, 1), doc.ops.len());
            try testing.expectEqual(@as(u32, 1), following.counter);
            try testing.expectEqual(@as(u64, 1), doc.graph.maxOp());
            try testing.expect(try doc.ops.validateOpOrder());
            try testing.expect((try doc.ops.validateTopIndex()) == null);
            const bytes = try doc.save(gpa);
            defer gpa.free(bytes);
            var loaded = try Document.load(gpa, testing.io, bytes, doc.textEncoding(), .auto);
            defer loaded.deinit();
            try testing.expectEqual(@as(usize, 1), loaded.ops.len());
            try testing.expect((try readmod.get(&loaded, .root, .{ .key = "a" })) == null);
            try testing.expectEqual(@as(i64, 42), (try readmod.get(&loaded, .root, .{ .key = "b" })).?.value.scalar.int);
        }
    }
    try testing.expect(reached_success);
    try testing.expect(reached_published_refusal);
    try testing.expect(reached_second_refusal);
}

test "native hydrated auto refusal retains published and queued producer undo" {
    // A child is queued before the parent batch is published, then written in
    // a second batch. Sweep both sides of that ownership handover.
    var reached_success = false;
    var reached_published_refusal = false;
    for (0..1024) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        const list = try putObject(&doc, .root, .{ .key = "list" }, .list);
        var nested = hydmod.List.init(gpa, .root);
        defer nested.deinit();
        try nested.push(.{ .int = 7 }, false);
        const values = [_]hydmod.Value{
            .{ .int = 1 },
            .{ .object = .{ .list = nested } },
            .{ .int = 3 },
        };
        failing.fail_index = failing.alloc_index + offset;
        if (splice(&doc, list, 0, 0, gpa, &values)) |_| {
            failing.fail_index = std.math.maxInt(usize);
            reached_success = true;
            try testing.expectEqual(@as(usize, 3), doc.ops.seqLength(list, doc.textEncoding(), null));
            break;
        } else |primary| {
            try testing.expectEqual(error.OutOfMemory, primary);
            reached_published_refusal = reached_published_refusal or doc.ops.len() > 1;
            failing.fail_index = std.math.maxInt(usize);
            _ = try insert(&doc, list, 0, .{ .int = 42 });
            try testing.expectEqual(@as(usize, 1), doc.ops.seqLength(list, doc.textEncoding(), null));
            try testing.expectEqual(@as(i64, 42), (try readmod.get(&doc, list, .{ .index = 0 })).?.value.scalar.int);
            try testing.expectEqual(@as(usize, 2), doc.ops.len());
            try testing.expectEqual(@as(usize, 2), doc.graph.len());
            try testing.expect(try doc.ops.validateOpOrder());
            try testing.expect((try doc.ops.validateTopIndex()) == null);
        }
    }
    try testing.expect(reached_success);
    try testing.expect(reached_published_refusal);
}

test "retained native recovery refuses overlapping mutation and survives scope release" {
    // Find a fresh-fixture refusal after a row was published, then exercise
    // the explicit recovery door with another allocation refusal.
    var reached = false;
    for (0..512) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var doc = try freshDoc(gpa);
        defer doc.deinit();
        try doc.isolate(gpa, &.{});
        const transient = try gpa.dupe(u8, "refused");
        failing.fail_index = failing.alloc_index + offset;
        const attempted = put(&doc, .root, .{ .key = "a" }, .{ .str = transient });
        // A retained undo may keep a slice descriptor, but must not read bytes
        // the caller was promised it could release when the wrapper returned.
        gpa.free(transient);
        if (attempted) |_| {
            failing.fail_index = std.math.maxInt(usize);
            break;
        } else |primary| {
            try testing.expectEqual(error.OutOfMemory, primary);
        }
        failing.fail_index = std.math.maxInt(usize);
        if (doc.ops.len() == 0) continue;
        reached = true;
        try testing.expect(doc.auto_recovery != null);
        try testing.expectEqual(@as(usize, 1), pendingOps(&doc));
        try testing.expectError(error.InvalidOp, openAutoHeld(gpa, &doc));
        try testing.expectError(error.InvalidOp, doc.isolate(gpa, &.{}));
        try testing.expectError(error.InvalidOp, doc.integrate());
        try testing.expectError(error.InvalidOp, doc.putActorRef(gpa, types.ActorId.init("overlap")));
        try testing.expectError(error.InvalidOp, doc.applyChanges(gpa, &.{}));
        try testing.expectError(error.InvalidOp, doc.save(gpa));
        doc.setMode(.manual);
        try testing.expectError(error.InvalidOp, Transaction.open(gpa, &doc));
        try testing.expectError(error.InvalidOp, Transaction.openAt(gpa, &doc, &.{}));
        // These configuration changes do not mutate rows or renumber IDs.
        // Releasing the document's heads must not release recovery's scope.
        doc.dropIsolation();
        doc.setActorId(types.ActorId.init("following"));
        doc.resetDiffCursor();
        failing.fail_index = failing.alloc_index;
        try testing.expectError(error.OutOfMemory, doc.recoverAuto());
        try testing.expect(doc.auto_recovery != null);
        failing.fail_index = std.math.maxInt(usize);
        try testing.expectEqual(@as(usize, 1), try doc.recoverAuto());
        try testing.expectEqual(@as(usize, 0), try doc.recoverAuto());
        try testing.expect(doc.auto_recovery == null);
        doc.setMode(.auto);
        _ = try put(&doc, .root, .{ .key = "b" }, .{ .int = 42 });
        try testing.expect((try readmod.get(&doc, .root, .{ .key = "a" })) == null);
        try testing.expectEqual(@as(i64, 42), (try readmod.get(&doc, .root, .{ .key = "b" })).?.value.scalar.int);
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
        var doc = try freshDocIn(gpa, .manual);
        defer doc.deinit();
        {
            var baseline = try Transaction.open(gpa, &doc);
            defer baseline.deinit();
            _ = try baseline.put(.root, .{ .key = "k" }, .{ .int = 7 });
            _ = try baseline.commit(null, null);
        }
        var tx = try Transaction.openAt(gpa, &doc, doc.graph.getHeads());
        defer tx.deinit();
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
        var doc = try freshDocIn(gpa, .manual);
        defer doc.deinit();
        {
            var baseline = try Transaction.open(gpa, &doc);
            defer baseline.deinit();
            _ = try baseline.put(.root, .{ .key = "k" }, .{ .int = 7 });
            _ = try baseline.commit(null, null);
        }
        var tx = try Transaction.openAt(gpa, &doc, doc.graph.getHeads());
        defer tx.deinit();
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
            try testing.expectError(error.InvalidOp, tx.commit(null, null));
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
    // Invalid text must not poison an otherwise valid manual transaction:
    // no operation from the refused splice was queued or published.
    const gpa = testing.allocator;
    var doc = try freshDocIn(gpa, .manual);
    defer doc.deinit();
    var tx = try Transaction.open(gpa, &doc);
    defer tx.deinit();
    const text = try tx.putObject(.root, .{ .key = "text" }, .text);
    try testing.expectError(error.InvalidUtf8, tx.spliceText(text, 0, 0, "\xff"));
    try testing.expect(!tx.rolling_back);
    try tx.spliceText(text, 0, 0, "okay");
    _ = try tx.commit(null, null);
    const got = try doc.text(gpa, text);
    defer gpa.free(got);
    try testing.expectEqualStrings("okay", got);
}
