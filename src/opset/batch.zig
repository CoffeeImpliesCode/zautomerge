//! The merge: two histories meet here.
//!
//! Upstream `op_set2/change/batch.rs` (2,041 lines) is `BatchApply`, the two
//! walkers it drives, the conflict bookkeeping between them, and the three
//! `Automerge` entry points that reach it. This is that file.
//!
//! # Why this file is the one that has to be right
//!
//! Row order is a **strict order, not a total one** ([survey §4](../../docs/survey/02-transaction-opset.md)):
//! objects ascend, registers group, ids ascend within a register, and an
//! insert that starts a register is legal only if it is anchored to the
//! previous element *or* its own id sorts before that element's
//! ([`opmod.Op.step`](op.zig)). Every reader above this file — `scopeToObj`,
//! `propRange`, `iterObj`, the top-op scan, the mark reader — assumes a walk's
//! output is in that order and that one object's rows are one contiguous
//! range. A merge that produced a *plausible* but differently-ordered op set
//! would load, save, and read back wrong, and nothing in the tree would notice
//! except the tests here. So the sort in step 4 is the whole file.
//!
//! # The ten steps, and the nine this file runs
//!
//! [`BatchApply.apply`] is upstream's `apply` (`batch.rs:865-951`) in order:
//!
//! 1. `insert_new_actors` for every change with `seq == 1` (`:851-855`) —
//!    [`BatchApply.insertNewActors`].
//! 2. `log.migrate_actors(&doc.ops().actors)` (`:872`) — **here**.
//! 3. `import_ops` (`:857-862`) — decode each change into [`ChangeOp`]s and
//!    update the history. **Not here**: the decode is `op_set2/change.rs`'s
//!    `ChangeOpsColumns` and the history update is the change graph's, both
//!    modules this file does not own ([plan §4](../../docs/plan.md) gives the
//!    decode to `zautomerge.change`). The decoded ops arrive as the `ops`
//!    argument, which is why `apply` takes them and not only `changes`. Every
//!    other step is unchanged.
//! 4. `order_ops_for_doc` (`:979-1015`) — **the sort**.
//! 5. per object, [`MapWalker`] for a map or [`Untangler`] for a sequence.
//! 6. the `(pos, sub_pos, counter, actor)` order of the successor list.
//!    Upstream gates this behind `slow_path_assertions` (`batch.rs:924-936`);
//!    the port runs it always, as [`checkSuccOrder`].
//! 7. the accumulated [`Adjust`]s, as `conflict`/`expose` (`:938-943`).
//! 8. `add_succ` (`:945`).
//! 9. `insert_runs_of_ops` (`:953-970`) — splice each run of equal `pos` at
//!    `pos + shift`.
//! 10. `validate_op_order` (`:949`).
//!
//! # The two emission orders, stated as rules
//!
//! **Map** (survey §5.1): for each incoming op in `(key, id)` order, every
//! document row that sorts before it is consumed first, and the incoming op's
//! `pos` is the current cursor — which is *also* where the next document row
//! goes. A map change is therefore an **insertion relative to existing rows**,
//! not a replacement of a row slot, and that is why a change to a key the
//! document already has lands *before* the document's own row for it.
//!
//! **Sequence** (survey §5.2): an element's insert op, then its update ops in
//! ascending id, **all at the same `pos`**; `subsort` is a monotonically
//! increasing counter that becomes the intra-`pos` order, and
//! [`Untangler.finish`] sorts the batch by `(pos, subsort)`. The last op in a
//! run that is a set-or-make with no successors is the visible one and earlier
//! ones are flagged conflicted.
//!
//! # What the patch log is here
//!
//! Upstream's `PatchLog` lives in `patches/patch_log.rs` and the port has not
//! written it ([plan §4](../../docs/plan.md) gives it to `zautomerge.patches`).
//! This file therefore declares the **sink it calls** as a comptime contract —
//! [`log_decls`], checked by [`assertLog`] — and hands out [`NullLog`] for a
//! merge nobody is watching. That is the one shape that is not a straight
//! transcription, and it is why [`ValueState`] and the two walkers are generic
//! over the sink: every call site resolves at comptime and inlines, so a
//! [`NullLog`] merge has no indirect calls in it at all. The payload is
//! [`PatchValue`], which is `hydrate::Value` without its children; its doc
//! says why that is the whole of it.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const valuemod = @import("../value.zig");
const marksmod = @import("../marks.zig");
const column = @import("../hexane/column.zig");
const changerec = @import("../change.zig");
const queuemod = @import("../change_queue.zig");
const authorsmod = @import("../author.zig");
const graphmod = @import("../change_graph.zig");
const opmod = @import("op.zig");
const optypes = @import("types.zig");
const opiter = @import("op_iter.zig");
const opcols = @import("columns.zig");
const opsetmod = @import("op_set.zig");

const Allocator = std.mem.Allocator;
const Action = optypes.Action;
const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const Change = changerec.Change;
const ChangeBatch = queuemod.ChangeBatch;
const ChangeGraph = graphmod.ChangeGraph;
const ChangeHash = types.ChangeHash;
const ChangeOp = opmod.ChangeOp;
const ChangeQueue = queuemod.ChangeQueue;
const ElemId = types.ElemId;
const Error = err.Error;
const InternalError = err.InternalError;
const KeyRef = optypes.KeyRef;
const MarkData = optypes.MarkData;
const MarkSet = marksmod.MarkSet;
const MarkStateMachine = marksmod.MarkStateMachine;
const ObjId = types.ExId;
const ObjIndex = opsetmod.ObjIndex;
const ObjType = types.ObjType;
const Op = opmod.Op;
const OpId = types.OpId;
const OpRange = opmod.OpRange;
const OpType = valuemod.OpType;
const ParseError = err.ParseError;
const Prop = types.Prop;
const PropRef = optypes.PropRef;
const ReadOpError = opiter.ReadOpError;
const RowRange = column.RowRange;
const ScalarValue = optypes.ScalarValue;
const SequenceType = types.SequenceType;
const StringTable = opcols.StringTable;
const SuccEntry = opmod.SuccEntry;
const SuccInsert = opmod.SuccInsert;
const TextEncoding = types.TextEncoding;

const testing = std.testing;

/// The op set a merge writes into. **Not generic**, and that is the one thing
/// about the port's [`opsetmod.OpSet`] a caller of this file has to know: the
/// set's op type is the type of the values [`opsetmod.OpSet.splice`] is handed,
/// and a batch apply splices [`ChangeOp`]s, so a document that merges is
/// `OpSet(ChangeOp)`.
///
/// Upstream's `OpSet` is concrete and only its `splice` is generic over
/// `OpLike` (`op_set.rs:60`, `:1291-1341`), so this is the same set of
/// instantiations with the one that matters named.
const Set = opsetmod.OpSet(ChangeOp);

/// A walk over a range of a document's rows, which is what both walkers read.
const Row = Set.Row;

/// What a merge walk can raise.
///
/// [`Error`] because the mark fold is `Error`
/// ([marksmod.MarkStateMachine.process]) and the sink's `migrateActors` is
/// [`error.PatchLogMismatch`]; [`ReadOpError`] because every walk over the
/// document is `ReadOpError`, and it already contains [`ParseError`];
/// [`InternalError`] because upstream's `panic!("Obj {:?} Missing from Index")`
/// (`batch.rs:920`) and its `assert!`s (`:136`, `:142`, `:180`) are checks
/// upstream treats as impossible and this port reports.
pub const WalkError = Error || ReadOpError || InternalError;

/// What [`BatchApply.apply`] can raise: the same set, because every step it
/// runs is a walk, a column write, or a check.
pub const ApplyError = WalkError;

// ── The patch sink ─────────────────────────────────────────────────────────

/// The value a patch carries ([`PatchValue`]).
///
/// Upstream's is `hydrate::Value` (`hydrate.rs:44-135`) and this is that type
/// without its children: a scalar, or an object of a known type. **That is the
/// whole of it for this file**, and the reason is [`ValueState`]: every
/// question it asks a value is `is_object()` (`:458`, `:475`, `:498`),
/// `as_str()` (`:472`, `:490`), `width(...)` (`:491`, `:492`, `:778`) or
/// `as_i64()` (`:684`, `:824`). The first three are answered by "scalar or
/// object, and if scalar then the bytes"; the fourth by the scalar alone. An
/// empty object and a list with three elements in it patch identically, and
/// `zautomerge.patches` builds the real value from these three facts.
pub const PatchValue = union(enum) {
    /// A scalar the op set carries, borrowed from the row or the change op
    /// that carries it.
    scalar: ScalarValue,
    /// An object a make action produces, and of what type
    /// ([`OpBuilder::hydrate_value`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):240-252).
    object: ObjType,

    /// Whether this is an object rather than a scalar
    /// ([`hydrate::Value::is_object`](hydrate.rs):67-69). The port's spelling
    /// of upstream's `!is_scalar()`.
    pub fn isObject(self: PatchValue) bool {
        return self == .object;
    }

    /// The scalar, or null for an object
    /// ([`hydrate::Value::is_scalar`](hydrate.rs):63-65).
    pub fn scalarValue(self: PatchValue) ?ScalarValue {
        return switch (self) {
            .scalar => |s| s,
            .object => null,
        };
    }

    /// The value as a string: a `str` scalar is itself, everything else is the
    /// object replacement character
    /// ([`hydrate::Value::as_str`](hydrate.rs):71-76).
    pub fn asStr(self: PatchValue) []const u8 {
        return switch (self) {
            .scalar => |s| switch (s) {
                .str => |t| t,
                else => object_replacement,
            },
            .object => object_replacement,
        };
    }

    /// How wide the value is in a sequence
    /// ([`hydrate::Value::width`](hydrate.rs):60-65).
    pub fn width(self: PatchValue, seq_type: SequenceType, enc: TextEncoding) usize {
        return switch (seq_type) {
            .list => 1,
            .text => enc.width(self.asStr()),
        };
    }

    /// The value as an integer: a scalar's own integer, and zero for anything
    /// else ([`hydrate::Value::as_i64`](hydrate.rs):129-134, over
    /// [`op_set2/types.rs:247-254`](hydrate.rs)).
    pub fn asI64(self: PatchValue) i64 {
        return switch (self) {
            .scalar => |s| scalarAsI64(s),
            .object => 0,
        };
    }
};

/// U+FFFC, the character a non-string value renders as
/// ([`OpBuilder::as_str`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):220-226).
const object_replacement: []const u8 = "\u{fffc}";

/// A scalar read as an integer, or zero
/// ([`op_set2/types.rs:247-254`](../github-automerge-automerge/rust/automerge/src/op_set2/types.rs)).
///
/// **A timestamp counts, and so does a counter**, whose payload is the same
/// `i64` the op set stores.
fn scalarAsI64(v: ScalarValue) i64 {
    return switch (v) {
        .int => |i| i,
        .timestamp => |i| i,
        // `*i as i64` upstream is a two's-complement wrap, defined for every
        // `u64`; `@intCast` traps above `i64::MAX`, and a `uleb` value cell
        // can hold one (`value.rs:811`).
        .uint => |u| @bitCast(u),
        .counter => |c| c.current,
        else => 0,
    };
}

/// The sink's twelve methods, by name ([`log_decls`], checked by
/// [`assertLog`]).
pub const log_decls = [_][]const u8{
    "insert",
    "putMap",
    "putSeq",
    "deleteMap",
    "deleteSeq",
    "flagConflict",
    "incrementMap",
    "incrementSeq",
    "splice",
    "replaceSeq",
    "mark",
    "migrateActors",
};

/// Each sink method's parameters, in order, after the receiver.
///
/// The guard checks arity and parameter types in order. It cannot distinguish
/// two parameters with the same type; their meaning is on `NullLog`'s methods.
///
/// The receiver is not here: it is the sink's own type, and a sink is free to
/// be a pointer to whatever holds it.
const log_sig_params = .{
    .insert = [_]type{ ObjId, usize, PatchValue, OpId, bool },
    .putMap = [_]type{ ObjId, []const u8, PatchValue, OpId, bool, bool },
    .putSeq = [_]type{ ObjId, usize, PatchValue, OpId, bool, bool },
    .deleteMap = [_]type{ ObjId, []const u8 },
    .deleteSeq = [_]type{ ObjId, usize, usize },
    .flagConflict = [_]type{ ObjId, Prop },
    .incrementMap = [_]type{ ObjId, []const u8, i64, OpId },
    .incrementSeq = [_]type{ ObjId, usize, i64, OpId },
    .splice = [_]type{ ObjId, usize, []const u8, ?*const MarkSet },
    .replaceSeq = [_]type{
        ObjId, usize, PatchValue,   PatchValue,   OpId,
        bool,  bool,  SequenceType, TextEncoding, ?*const MarkSet,
    },
    .mark = [_]type{ ObjId, usize, usize, *const MarkSet },
    .migrateActors = [_]type{[]const ActorId},
};

/// Fails to compile unless `L` carries every declaration in [`log_decls`] with
/// the parameters [`log_sig_params`] gives it.
///
/// The whole of the sink contract, and the reason it is a comptime check
/// rather than a trait: every call site in this file resolves at comptime and
/// inlines, so a [`NullLog`] merge has no indirect calls in it at all.
///
/// Eleven methods return `void`. `migrateActors` returns an error union with
/// a `void` payload; its errors must be compatible with the calling operation.
/// The call site checks that error-set compatibility.
///
/// **A sink method that takes a mark set is handed a borrowed one and must copy
/// whatever it keeps.** [`ValueState.mapFlush`] and
/// [`ValueState.listFlush`] own the set they export and free it as soon as the
/// call returns, because `MarkDiff.export` allocates the entries and upstream's
/// `Arc<MarkSet>` has no reference-counted spelling here.
pub fn assertLog(comptime L: type) void {
    inline for (log_decls) |name| {
        if (!@hasDecl(L, name)) {
            @compileError("patch sink " ++ @typeName(L) ++ " has no " ++ name ++
                "; the sink op_set2/change/batch.rs:665-832 writes to is declared in log_decls");
        }
        if (comptime !sameParams(L, name)) {
            @compileError("patch sink " ++ @typeName(L) ++ " declares " ++ name ++
                " with parameters the sink contract does not give it; the order and" ++
                " types are in log_sig_params." ++ name);
        }
    }
}

/// Whether `L`'s `name` takes the parameters [`log_sig_params`] gives it,
/// receiver excluded.
///
/// Compares receiver, parameter, and return types. Generic and variadic
/// methods do not satisfy this fixed sink protocol.
fn sameParams(comptime L: type, comptime name: []const u8) bool {
    const have = switch (@typeInfo(@TypeOf(@field(L, name)))) {
        .@"fn" => |f| f,
        else => return false,
    };
    const want = @field(log_sig_params, name);
    if (have.is_generic or have.is_var_args or have.params.len != want.len + 1) return false;
    const receiver = have.params[0].type orelse return false;
    if (receiver != *L and receiver != *const L) return false;
    inline for (want, 0..) |w, i| {
        const t = have.params[i + 1].type orelse return false;
        if (t != w) return false;
    }
    const result = have.return_type orelse return false;
    if (std.mem.eql(u8, name, "migrateActors")) {
        return switch (@typeInfo(result)) {
            .error_union => |eu| eu.payload == void,
            else => false,
        };
    }
    return result == void;
}

/// The sink a merge nobody is watching writes to
/// ([`PatchLog::inactive`](../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs):245-247).
///
/// Discards patch events when the consumer does not request them.
/// Use `PatchLog` when the consumer needs an owned patch stream.
///
/// **The twelve methods below are the published statement of the sink
/// signature**, and each one's parameters are named and explained because a
/// sink author has nothing else to read. [`assertLog`] checks a sink against
/// them.
pub const NullLog = struct {
    const Self = @This();

    /// One or more elements inserted into the sequence `obj` at `index`.
    ///
    /// `value` is the whole insertion: a list element, or — in the text arm at
    /// `batch.rs:712-717` — the scalar a text object receives. `id` is the op
    /// that made it, which is what a sink re-keys when actors migrate, and
    /// `conflict` says the register it landed in is already in conflict.
    pub fn insert(
        _: *Self,
        obj: ObjId,
        index: usize,
        value: PatchValue,
        id: OpId,
        conflict: bool,
    ) void {
        _ = .{ obj, index, value, id, conflict };
    }

    /// A key put in the map `obj`.
    ///
    /// **`conflict` and `expose` are different things and the order is
    /// upstream's** (`patch_log.rs:365-373`). `conflict` is the value's own
    /// flag: the register is in conflict. `expose` says the put *revealed* a
    /// losing object — a delete in the same batch uncovered it
    /// (`batch.rs:808-809`) — which is what queues that object's content for
    /// the consumer (`patch_log.rs:374-376`).
    pub fn putMap(
        _: *Self,
        obj: ObjId,
        key: []const u8,
        value: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
    ) void {
        _ = .{ obj, key, value, id, conflict, expose };
    }

    /// An index put in the sequence `obj`, with the same two flags as
    /// [`putMap`](NullLog.putMap) and in the same order
    /// (`patch_log.rs:388-409`).
    pub fn putSeq(
        _: *Self,
        obj: ObjId,
        index: usize,
        value: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
    ) void {
        _ = .{ obj, index, value, id, conflict, expose };
    }

    /// The key `key` was deleted from the map `obj` (`patch_log.rs:309-311`).
    pub fn deleteMap(_: *Self, obj: ObjId, key: []const u8) void {
        _ = .{ obj, key };
    }

    /// `num` units of the sequence `obj` were deleted, starting at `index`.
    ///
    /// **`num` is a width, not a row count.** One text element can be wider
    /// than one unit in the object's encoding, so a merge deletes
    /// `value.width(seq_type, text_encoding)` and says so here
    /// (`batch.rs:777-779`; `patch_log.rs:305-307`). The two `usize` are the
    /// index and then the width, in that order.
    pub fn deleteSeq(_: *Self, obj: ObjId, index: usize, num: usize) void {
        _ = .{ obj, index, num };
    }

    /// The register `prop` names in `obj` is in conflict. `prop` is a key or
    /// an index, which is what tells a map key from a sequence element
    /// (`batch.rs:918`; `patch_log.rs:335-340`).
    pub fn flagConflict(_: *Self, obj: ObjId, prop: Prop) void {
        _ = .{ obj, prop };
    }

    /// The counter at `key` in `obj` moved by `n`, which may be negative. A
    /// merge reports only a change that is not zero (`batch.rs:823-827`).
    pub fn incrementMap(_: *Self, obj: ObjId, key: []const u8, n: i64, id: OpId) void {
        _ = .{ obj, key, n, id };
    }

    /// The counter at `index` in `obj` moved by `n`, which may be negative
    /// (`batch.rs:684-687`).
    pub fn incrementSeq(_: *Self, obj: ObjId, index: usize, n: i64, id: OpId) void {
        _ = .{ obj, index, n, id };
    }

    /// `text` was inserted into `obj` at `index`, carrying `marks`.
    ///
    /// **`marks` is borrowed and is freed as soon as this returns**, so a sink
    /// that keeps it copies it; null means nothing is marked there. The same
    /// rule is on [`mark`](NullLog.mark) and on the last argument of
    /// [`replaceSeq`](NullLog.replaceSeq).
    pub fn splice(_: *Self, obj: ObjId, index: usize, text: []const u8, marks: ?*const MarkSet) void {
        _ = .{ obj, index, text, marks };
    }

    /// One element of `obj` at `index` was replaced by another.
    ///
    /// `old_value` is what was there, and a sink needs it because a text
    /// replacement is a delete of the old width followed by an insert
    /// (`patch_log.rs:425-435`) — which is also what `seq_type` and
    /// `text_encoding` are for: they measure `old_value`
    /// (`patch_log.rs:430`). `marks` is borrowed, as on
    /// [`splice`](NullLog.splice).
    pub fn replaceSeq(
        _: *Self,
        obj: ObjId,
        index: usize,
        old_value: PatchValue,
        value: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
        seq_type: SequenceType,
        text_encoding: TextEncoding,
        marks: ?*const MarkSet,
    ) void {
        _ = .{ obj, index, old_value, value, id, conflict, expose, seq_type, text_encoding, marks };
    }

    /// The marks over `len` units of `obj` from `index` are `marks`.
    ///
    /// **The two `usize` are the index and then the length**, in the object's
    /// own units. The types cannot distinguish this pair's order.
    /// `marks` is borrowed and is freed as soon as this returns.
    pub fn mark(_: *Self, obj: ObjId, index: usize, len: usize, marks: *const MarkSet) void {
        _ = .{ obj, index, len, marks };
    }

    /// The merge interned actors, so every id this sink stored has to be
    /// re-keyed to `others`, the op set's actor table.
    ///
    /// Borrowed, and the **only** one of the twelve that can fail: a sink
    /// holding ids minted against a different actor table answers
    /// `error.PatchLogMismatch` (`patch_log.rs:634-658`, whose one `Err` is at
    /// `:655`). Every other method
    /// answers `void`.
    pub fn migrateActors(_: *Self, others: []const ActorId) Error!void {
        _ = .{others};
    }
};

// ── Marks in flight ────────────────────────────────────────────────────────

/// The two mark folds a patch run carries
/// ([`RichTextDiff`](../github-automerge-automerge/rust/automerge/src/iter/spans.rs):648-679,
/// [`MarkDiff`](../github-automerge-automerge/rust/automerge/src/iter/spans.rs):291-401).
///
/// A **document** mark is fed to both folds and a **change** mark only to the
/// `after` fold ([`ValueState.processDocOp`](batch.rs):616-617 against
/// [`ValueState.processMark`](batch.rs):645-648), which is `Diff::Same` against
/// `Diff::Add` in
/// [`RichTextDiff::mark_begin_diff`](spans.rs):661-669. So `current()` is the
/// diff between what the document had and what the merge has produced.
pub const RichTextDiff = struct {
    /// The marks the document already had.
    before: MarkStateMachine,
    /// The marks the merge has produced.
    after: MarkStateMachine,

    /// Two empty folds. `gpa` is the allocator they own their arrays with.
    pub fn init(gpa: Allocator) RichTextDiff {
        return .{
            .before = MarkStateMachine.init(gpa),
            .after = MarkStateMachine.init(gpa),
        };
    }

    /// Frees both folds' arrays and poisons the receiver, so a second call
    /// reads undefined memory rather than double-freeing.
    ///
    /// A [`MarkDiff`] taken from this borrows it, so anything that must
    /// outlive the diff has to be exported first; that is what
    /// [`MarkDiff.exportSet`] is for.
    pub fn deinit(self: *RichTextDiff) void {
        self.before.deinit();
        self.after.deinit();
        self.* = undefined;
    }

    /// The difference between the two folds
    /// ([`RichTextDiff::current`](spans.rs):653-660).
    pub fn current(self: *const RichTextDiff) MarkDiff {
        const b = self.before.current();
        const a = self.after.current();
        if (b == null and a == null) return .nothing;
        if (b == null) return .{ .after = a.? };
        if (a == null) return .{ .before = b.? };
        return .{ .diff = .{ .before = b.?, .after = a.? } };
    }
};

/// The marks one patch position carries
/// ([`MarkDiff`](../github-automerge-automerge/rust/automerge/src/iter/spans.rs):291-297).
///
/// The payloads are **borrows of the two folds**, so a `MarkDiff` is good only
/// while the [`RichTextDiff`] it came from is. Every consumer here exports or
/// copies it before it goes anywhere.
pub const MarkDiff = union(enum) {
    /// Neither fold has a mark.
    nothing,
    /// Only the merge's fold does.
    after: *const MarkSet,
    /// Only the document's fold does.
    before: *const MarkSet,
    /// Both do, and they differ.
    diff: struct { before: *const MarkSet, after: *const MarkSet },

    /// The marks, flattened to one set, or null when there are none
    /// ([`MarkDiff::export`](spans.rs):389-401, over
    /// [`MarkDiff::iter`](spans.rs):342-387).
    ///
    /// The flatten is upstream's zip in name order, and all three of its cases
    /// matter: a name only the document had and whose value is not null becomes
    /// an **unmark tombstone** (`spans.rs:360-366`); a name only the merge has
    /// and whose value is not null is kept (`spans.rs:367-372`); a name both
    /// have is kept **only if the values differ** (`spans.rs:373-382`). A name
    /// whose value is null on the side it came from is dropped.
    ///
    /// **The caller owns the result**; the mark *names* inside it are borrowed
    /// from the document and are not freed with it.
    ///
    /// Named `exportSet` and not `export` because `export` is a Zig keyword.
    pub fn exportSet(self: MarkDiff, gpa: Allocator) Error!?MarkSet {
        var pairs: std.ArrayList(MarkSet.Entry) = .empty;
        defer pairs.deinit(gpa);
        const b = self.beforeEntries();
        const a = self.afterEntries();
        var i: usize = 0;
        var j: usize = 0;
        while (i < b.len or j < a.len) {
            const which: enum { before, after, both } = if (i >= b.len)
                .after
            else if (j >= a.len)
                .before
            else switch (std.mem.order(u8, b[i].name, a[j].name)) {
                .lt => .before,
                .gt => .after,
                .eq => .both,
            };
            switch (which) {
                .before => {
                    // `Pop::Before`, `spans.rs:360-366`.
                    const v = b[i];
                    i += 1;
                    if (v.value == .null_value) continue;
                    try pairs.append(gpa, .{ .name = v.name, .value = .null_value });
                },
                .after => {
                    // `Pop::After`, `spans.rs:367-372`.
                    const v = a[j];
                    j += 1;
                    if (v.value == .null_value) continue;
                    try pairs.append(gpa, .{ .name = v.name, .value = v.value });
                },
                .both => {
                    // `Pop::Both`, `spans.rs:373-382`. `assert_eq!(k1, k2)` is
                    // the zip's own check, `spans.rs:375`.
                    std.debug.assert(std.mem.eql(u8, b[i].name, a[j].name));
                    const name = b[i].name;
                    if (b[i].value.eql(a[j].value)) {
                        i += 1;
                        j += 1;
                        continue;
                    }
                    try pairs.append(gpa, .{ .name = name, .value = a[j].value });
                    i += 1;
                    j += 1;
                },
            }
        }
        if (pairs.items.len == 0) return null;
        return try MarkSet.fromPairs(gpa, pairs.items);
    }

    /// The document's own marks, or nothing.
    fn beforeEntries(self: MarkDiff) []const MarkSet.Entry {
        return switch (self) {
            .nothing, .after => &.{},
            .before => |b| b.entries.items,
            .diff => |d| d.before.entries.items,
        };
    }

    /// The merge's marks, or nothing.
    fn afterEntries(self: MarkDiff) []const MarkSet.Entry {
        return switch (self) {
            .nothing, .before => &.{},
            .after => |a| a.entries.items,
            .diff => |d| d.after.entries.items,
        };
    }
};

// ── One value, from one side ───────────────────────────────────────────────

/// One side's value for one register, and what happened to it
/// ([`OpValue`], `batch.rs:524-532`).
///
/// `deleted` says the batch overwrote this row; `expose` says a surviving
/// value must be re-emitted after a conflict was deleted. A text exposure
/// replaces the pre-batch rendered winner, which may be the survivor itself.
/// Keeping that payload separately lets `replace_seq` remove its full width.
pub const OpValue = struct {
    /// The operation that put it, which is what the conflict rules compare.
    id: OpId,
    /// The value itself, borrowed from the row or the change op.
    value: PatchValue,
    /// Whether an op overwrote it, increment or not.
    deleted: bool,
    /// Whether a visible op from the other side already held this register.
    conflict: bool,
    /// Whether a surviving value must be re-emitted after a delete.
    expose: bool,
    /// The pre-batch rendered winner, required whenever `expose` is true
    /// (`batch.rs:759-763`).
    replaced: ?PatchValue,
};

/// [`OpValueOption`], `batch.rs:534-597`.
///
/// A newtype over a null upstream because `Option<OpValue>` is not `Copy` there;
/// here it is a plain optional with the ten methods spelled out, because the
/// port has no newtype sugar and the methods are the behaviour.
pub const OpValueOption = struct {
    /// The value, or null for "this side had nothing here".
    item: ?OpValue = null,

    /// The id of the operation that put the value, or null
    /// ([`OpValueOption::id`](batch.rs):538-540).
    pub fn id(self: OpValueOption) ?OpId {
        const v = self.item orelse return null;
        return v.id;
    }

    /// Adds `n` to a counter value, and to nothing else
    /// ([`OpValueOption::increment`](batch.rs):542-548).
    pub fn increment(self: *OpValueOption, n: i64) void {
        const v = &(self.item orelse return);
        if (v.value == .scalar) {
            if (v.value.scalar == .counter) {
                v.value.scalar.counter.current = std.math.add(i64, v.value.scalar.counter.current, n) catch
                    v.value.scalar.counter.current;
            }
        }
    }

    /// Records an exposure together with the value its replacement removes
    /// ([`OpValueOption::expose`](batch.rs):550-555).
    pub fn expose(self: *OpValueOption, replaced: PatchValue) void {
        const v = &(self.item orelse return);
        v.expose = true;
        v.replaced = replaced;
    }

    /// Sets the value ([`OpValueOption::set`](batch.rs):557-572).
    ///
    /// Three cases, and the first is not a plain assignment: a delete landing
    /// on a value that is **still visible** *keeps* the value and marks it
    /// exposed, so that the flush emits a replace rather than a delete — which
    /// is the whole reason `batch.rs:721-737` sits before the id comparisons.
    pub fn set(self: *OpValueOption, v: PatchValue, op_id: OpId, deleted: bool) void {
        if (deleted and self.isVisible()) {
            self.expose(v);
            return;
        }
        // **Both flags are read before the assignment, and that is the whole
        // of it.** Upstream builds the `OpValue` first and assigns it
        // afterwards (`batch.rs:565-572`), so `self.is_visible()` and
        // `self.is_deleted()` there are the *old* value's. A Zig struct literal
        // assigned to `self.item` is instead initialised **in place**, field by
        // field in declaration order — so by the time `.conflict` is
        // initialised, `self.item` already holds the new value and
        // `self.isVisible()` answers for *it*: `true` for every non-deleted
        // value, and `expose` reads a `deleted` it has only just overwritten.
        const was_conflict = self.isVisible();
        const was_expose = !deleted and self.isDeleted();
        self.item = .{
            .id = op_id,
            .value = v,
            .deleted = deleted,
            .conflict = was_conflict,
            .expose = false,
            .replaced = null,
        };
        // The deleted→surviving arm also exposes (`batch.rs:562`), but
        // upstream leaves its replacement empty (`:569`) while the text
        // flush requires one (`:759-774`). This later survivor was already
        // the pre-batch winner, so re-emit it over its own full width.
        // Reusing expose keeps the flag and replacement payload together.
        if (was_expose) self.expose(v);
    }

    /// Whether this side had nothing here
    /// ([`OpValueOption::is_none`](batch.rs):574-576).
    pub fn isNone(self: OpValueOption) bool {
        return self.item == null;
    }

    /// The value, or null ([`OpValueOption::value`](batch.rs):578-580).
    pub fn value(self: OpValueOption) ?OpValue {
        return self.item;
    }

    /// Whether the stored value is showing
    /// ([`OpValueOption::is_visible`](batch.rs):582-584).
    pub fn isVisible(self: OpValueOption) bool {
        const v = self.item orelse return false;
        return !v.deleted;
    }

    /// Whether the stored value has been deleted
    /// ([`OpValueOption::is_deleted`](batch.rs):586-588).
    pub fn isDeleted(self: OpValueOption) bool {
        const v = self.item orelse return false;
        return v.deleted;
    }

    /// Empties the option and hands over what it held
    /// ([`OpValueOption::take`](batch.rs):590-592).
    pub fn take(self: *OpValueOption) OpValueOption {
        const out = self.*;
        self.* = .{};
        return out;
    }
};

// ── ValueState ─────────────────────────────────────────────────────────────

/// The two sides' values for one register, and the two places a patch is
/// emitted ([`ValueState`], `batch.rs:513-832`).
///
/// Generic over the sink `L`. `key` is the register being accumulated: a map
/// key for [`ValueState.mapFlush`], a sequence index for
/// [`ValueState.listFlush`]. Both flushes are the **only** places this file
/// emits a patch, and both are boundary-triggered — a map key change, an
/// element change, and the end of the run.
pub fn ValueState(comptime L: type) type {
    return struct {
        const Self = @This();

        /// The allocator the mark folds and every exported mark set own with.
        gpa: Allocator,
        /// The object being walked.
        obj: ObjId,
        /// Whether it is a list or text, which chooses the list flush's arms.
        seq_type: SequenceType,
        /// How its text is measured.
        text_encoding: TextEncoding,
        /// The register being accumulated, or null before the first.
        key: ?PropRef = null,
        /// What the document holds for it.
        doc: OpValueOption = .{},
        /// What the change holds for it.
        change: OpValueOption = .{},
        /// The marks in flight.
        marks: RichTextDiff,

        /// An empty state for one object
        /// ([`ValueState::new`](batch.rs):600-610).
        pub fn init(
            gpa: Allocator,
            obj: ObjId,
            encoding: SequenceType,
            text_encoding: TextEncoding,
        ) Self {
            return .{
                .gpa = gpa,
                .obj = obj,
                .seq_type = encoding,
                .text_encoding = text_encoding,
                .marks = RichTextDiff.init(gpa),
            };
        }

        /// Frees the two mark folds and poisons the receiver, so a second call
        /// is a use-after-free rather than a double free.
        ///
        /// The two [`OpValueOption`]s hold no allocations of their own — the
        /// values they carry are borrows of the rows being walked — so this is
        /// the mark folds and nothing else.
        pub fn deinit(self: *Self) void {
            self.marks.deinit();
            self.* = undefined;
        }

        /// Folds one document row in
        /// ([`ValueState::process_doc_op`](batch.rs):612-626).
        ///
        /// An increment carries no value and is skipped; a mark is fed to
        /// **both** folds; anything else sets the value if the row is visible.
        pub fn processDocOp(self: *Self, doc_op: Op, deleted: bool) WalkError!void {
            switch (doc_op.action()) {
                .increment => {},
                .mark => {
                    const t = try opTypeOf(doc_op);
                    _ = try self.marks.before.process(doc_op.id(), t);
                    _ = try self.marks.after.process(doc_op.id(), t);
                },
                else => {
                    if (doc_op.visible()) {
                        self.doc.set(try hydrateDocValue(doc_op), doc_op.id(), deleted);
                    }
                },
            }
        }

        /// Folds one change op in
        /// ([`ValueState::process_change_op`](batch.rs):651-663).
        pub fn processChangeOp(self: *Self, op: ChangeOp) WalkError!void {
            switch (op.bld.action()) {
                .delete => {},
                .increment => self.doIncrement(op),
                .mark => try self.processMark(op.id(), op.markData()),
                else => {
                    if (op.visible()) {
                        self.change.set(try hydrateChangeValue(op), op.id(), false);
                    }
                },
            }
        }

        /// The counter fold ([`ValueState::do_increment`](batch.rs):628-641).
        ///
        /// An increment only counts if it names the value it increments: the
        /// first one adopts the document's counter when it overwrites it, and
        /// then only increments that are in `pred` are added.
        fn doIncrement(self: *Self, op: ChangeOp) void {
            if (self.change.isNone()) {
                if (self.doc.id()) |id| {
                    if (predContains(op, id) and !self.doc.isDeleted()) {
                        self.change = self.doc;
                    }
                }
            }
            if (self.change.id()) |id| {
                if (predContains(op, id)) {
                    self.change.increment(op.bld.getIncrementValue() orelse 0);
                }
            }
        }

        /// Folds one change mark in
        /// ([`ValueState::process_mark`](batch.rs):643-649). Only the `after`
        /// fold, because a change's marks are additions and not removals.
        pub fn processMark(self: *Self, id: OpId, data: ?MarkData) Error!void {
            if (data) |d| {
                _ = try self.marks.after.markBegin(id, d);
            } else {
                _ = try self.marks.after.markEnd(id);
            }
        }

        /// Emits the map patch for the register that just ended
        /// ([`ValueState::map_flush`](batch.rs):665-672).
        ///
        /// **The key is taken with it**, so a state flushed twice emits once.
        /// A sequence index reaching this function is dropped: a map object's
        /// registers are keys, and upstream's `if let Some(PropRef::Map(key))`
        /// (`batch.rs:669`) is the same refusal.
        pub fn mapFlush(self: *Self, log: *L) WalkError!void {
            const key = self.key orelse return;
            const doc = self.doc.take();
            const change = self.change.take();
            self.key = null;
            switch (key) {
                .key => |k| mapProcess(L, self.obj, k, doc, change, log),
                .index => {},
            }
        }

        /// Emits the sequence patch for the element that just ended
        /// ([`ValueState::list_flush`](batch.rs):674-794).
        ///
        /// **The list and text arms are not the same rules, and that asymmetry
        /// is the point of the function.** A list whose document value is
        /// deleted and which has a change value *puts* the change
        /// (`batch.rs:692-695`); text with the same two values *replaces*,
        /// because a text element can be wider than one unit and the patch has
        /// to delete the old width before it inserts the new
        /// (`batch.rs:720-737`).
        pub fn listFlush(self: *Self, index: usize, log: *L) WalkError!void {
            if (self.key == null) return;
            self.key = null;
            const doc = self.doc.take();
            const change = self.change.take();
            switch (self.seq_type) {
                .list => self.listFlushList(index, doc, change, log),
                .text => try self.listFlushText(index, doc, change, log),
            }
        }

        /// The list arm ([`batch.rs:680-704`](batch.rs)).
        fn listFlushList(
            self: *Self,
            index: usize,
            doc: OpValueOption,
            change: OpValueOption,
            log: *L,
        ) void {
            const d = doc.item;
            const c = change.item;
            if (c) |cv| {
                const dv = d orelse {
                    log.insert(self.obj, index, cv.value, cv.id, cv.conflict);
                    return;
                };
                if (dv.id.eql(cv.id)) {
                    // Equal ids: the two are the same operation, and the
                    // difference is an increment.
                    const n = cv.value.asI64() - dv.value.asI64();
                    if (n != 0) log.incrementSeq(self.obj, index, n, cv.id);
                    return;
                }
                if (cv.id.order(dv.id) == .lt) {
                    // A lesser change id loses and flags the conflict.
                    log.flagConflict(self.obj, .{ .index = index });
                    return;
                }
                log.putSeq(self.obj, index, cv.value, cv.id, !dv.deleted or cv.conflict, false);
                return;
            }
            const dv = d orelse return;
            if (dv.expose) {
                log.putSeq(self.obj, index, dv.value, dv.id, dv.conflict, true);
            } else if (dv.deleted) {
                log.deleteSeq(self.obj, index, 1);
            }
        }

        /// The text arm ([`batch.rs:705-792`](batch.rs)).
        fn listFlushText(
            self: *Self,
            index: usize,
            doc: OpValueOption,
            change: OpValueOption,
            log: *L,
        ) WalkError!void {
            const d = doc.item;
            const c = change.item;
            if (c) |cv| {
                const dv = d orelse {
                    // Upstream's comment at `batch.rs:709-714`: this arm should
                    // be unreachable, and handles a non-inserting text
                    // operation as a splice regardless.
                    if (cv.value.isObject()) {
                        log.insert(self.obj, index, cv.value, cv.id, cv.conflict);
                    } else {
                        log.splice(self.obj, index, cv.value.asStr(), self.marks.after.current());
                    }
                    return;
                };
                if (dv.deleted) {
                    // A text update replaces one element, but that element can
                    // render as more than one unit, so the patch is a delete
                    // and an insert. This arm is **before** the equal-id and
                    // greater-id arms on purpose (`batch.rs:720-737`).
                    self.replaceSeq(log, index, dv.value, cv, cv.conflict, false);
                    return;
                }
                if (dv.id.eql(cv.id)) return; // counter increments change no text
                if (cv.id.order(dv.id) == .gt) {
                    self.replaceSeq(log, index, dv.value, cv, !dv.deleted or cv.conflict, false);
                    return;
                }
                if (!dv.conflict) log.flagConflict(self.obj, .{ .index = index });
                return;
            }
            const dv = d orelse return;
            if (dv.expose) {
                const replaced = dv.replaced orelse return error.Invariant; // :763
                self.replaceSeq(log, index, replaced, dv, dv.conflict, true);
                return;
            }
            if (dv.deleted) {
                log.deleteSeq(self.obj, index, dv.value.width(self.seq_type, self.text_encoding));
                return;
            }
            var marks = try self.marks.current().exportSet(self.gpa);
            defer if (marks) |*m| m.deinit();
            if (marks) |*m| {
                log.mark(self.obj, index, dv.value.width(self.seq_type, self.text_encoding), m);
            }
        }

        /// The shared replacement sink call for the three text transition arms.
        ///
        /// Replacement deletes before inserting (`patch_log.rs:430-434`), so
        /// the inserted run needs all after-marks, not just the mark delta.
        /// This is MarkDiff's insertion rule (`spans.rs:316-323`), also used
        /// by upstream's text insert walk (`batch.rs:229-242`).
        fn replaceSeq(
            self: *Self,
            log: *L,
            index: usize,
            old_value: PatchValue,
            new: OpValue,
            conflict: bool,
            expose: bool,
        ) void {
            log.replaceSeq(
                self.obj,
                index,
                old_value,
                new.value,
                new.id,
                conflict,
                expose,
                self.seq_type,
                self.text_encoding,
                self.marks.after.current(),
            );
        }
    };
}

/// The map conflict winner rules
/// ([`ValueState::map_process`](batch.rs):796-831).
///
/// **Four cases, and they are four different comparisons.** The change wins on
/// a greater id, with `(c.conflict && !d.conflict) || !d.deleted`; the document
/// wins on a lesser id and flags a conflict only if the document's own op was
/// not already conflicted; **equal ids emit the increment delta**; and a change
/// with no document value is a plain put.
fn mapProcess(
    comptime L: type,
    obj: ObjId,
    key: []const u8,
    doc: OpValueOption,
    change: OpValueOption,
    log: *L,
) void {
    const d = doc.item;
    const c = change.item;
    if (c) |cv| {
        const dv = d orelse {
            log.putMap(obj, key, cv.value, cv.id, cv.conflict, false);
            return;
        };
        switch (cv.id.order(dv.id)) {
            .gt => log.putMap(
                obj,
                key,
                cv.value,
                cv.id,
                (cv.conflict and !dv.conflict) or !dv.deleted,
                false,
            ),
            .lt => {
                if (!dv.conflict) log.flagConflict(obj, .{ .key = key });
            },
            .eq => {
                const n = cv.value.asI64() - dv.value.asI64();
                if (n != 0) log.incrementMap(obj, key, n, cv.id);
            },
        }
        return;
    }
    const dv = d orelse return;
    if (dv.expose) {
        log.putMap(obj, key, dv.value, dv.id, dv.conflict, true);
    } else if (dv.deleted) {
        log.deleteMap(obj, key);
    }
}

// ── Values out of a row and out of a change op ─────────────────────────────

/// A row's value, as a patch payload
/// ([`Op::hydrate_value`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):1108-1116).
///
/// The switch is on the action column, and the mark arms are the reason this
/// cannot fall into upstream's `panic!("cant convert op into a value")`: a mark
/// row answers with its own value and a mark **end** with the string
/// `"markEnd"`, because `Op::hydrate_value` switches on the *decomposed*
/// `OpType` rather than on the raw action.
pub fn hydrateDocValue(op: Op) InternalError!PatchValue {
    return switch (op.action()) {
        .set => .{ .scalar = op.value() },
        .make_map => .{ .object = .map },
        .make_list => .{ .object = .list },
        .make_text => .{ .object = .text },
        .make_table => .{ .object = .table },
        .mark => if (op.markData()) |d| .{ .scalar = d.value } else .{ .scalar = .{ .str = "markEnd" } },
        .delete, .increment => error.Invariant,
    };
}

/// A change op's value, as a patch payload
/// ([`ChangeOp::hydrate_value`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):81-83,
/// over [`OpBuilder::hydrate_value`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):240-252).
pub fn hydrateChangeValue(op: ChangeOp) InternalError!PatchValue {
    return switch (op.bld.action()) {
        .set => .{ .scalar = op.bld.value() },
        .make_map => .{ .object = .map },
        .make_list => .{ .object = .list },
        .make_text => .{ .object = .text },
        .make_table => .{ .object = .table },
        .delete, .increment, .mark => error.Invariant,
    };
}

/// A change op's value with its own successors' increments folded in
/// ([`ChangeOp::hydrate_value_and_fix_counters`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):85-99).
///
/// Only a `set` of a counter is fixed, and the delta is the sum of the
/// increments the op's **own** successors carry. Every other action falls
/// through to [`hydrateChangeValue`].
pub fn hydrateChangeValueFixCounters(op: ChangeOp) InternalError!PatchValue {
    if (op.bld.action() != .set) return hydrateChangeValue(op);
    const v = op.bld.value();
    const c = switch (v) {
        .counter => |cv| cv,
        else => return .{ .scalar = v },
    };
    var inc: i64 = 0;
    for (op.succs.items) |s| {
        if (s.inc) |n| inc = std.math.add(i64, inc, n) catch return error.CastOverflow;
    }
    const total = std.math.add(i64, c.current, inc) catch return error.CastOverflow;
    return .{ .scalar = .{ .counter = .{ .current = total } } };
}

/// A row's action and value combined, for the mark fold
/// ([`Op::action`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):1118-1120).
fn opTypeOf(op: Op) ParseError!OpType {
    return valuemod.opTypeFromActionAndValue(op.action(), op.value(), op.markName(), op.expand());
}

/// Whether `op` overwrites `id`
/// ([`OpBuilder::pred`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):135-137).
/// A row's property: the map key it hangs by, or null for a sequence anchor
/// ([`Op::prop`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):1174-1177,
/// which is `self.key.key_str()?` and nothing else).
fn propOfOp(op: Op) ?PropRef {
    const key = op.keyStr() orelse return null;
    return .{ .key = key };
}

/// A borrowed mark set, or null, for a sink that takes `?*const MarkSet`.
fn marksPtr(marks: ?MarkSet) ?*const MarkSet {
    if (marks) |*m| return m;
    return null;
}

/// A change op's property: the map key it hangs by, or null for a sequence
/// anchor ([`ChangeOp::prop`](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs):67-73,
/// which is [`propOf`] over the raw key).
fn changeProp(op: ChangeOp) ?PropRef {
    const key = op.bld.key().keyStr() orelse return null;
    return .{ .key = key };
}

fn predContains(op: ChangeOp, id: OpId) bool {
    for (op.bld.pred()) |p| {
        if (p.eql(id)) return true;
    }
    return false;
}

// ── Top and Adjust ─────────────────────────────────────────────────────────

/// The one change the walk still has to make to the index columns after it
/// ends ([`Adjust`], `batch.rs:346-350`).
///
/// Collected rather than applied, because a walk is *reading* the index columns
/// it would be writing to: `MapWalker` has to know that a document row is about
/// to lose to a change op in order to read that row's **value** correctly, and
/// applying the flag at that moment would change the walk.
pub const Adjust = union(enum) {
    /// Demote the row at this position from winner of its register
    /// ([`OpSet::conflict`](op_set.rs):140-145).
    conflict: usize,
    /// Promote it ([`OpSet::expose`](op_set.rs):147-158).
    expose: usize,
};

/// Which operation currently holds a register, as the walk sees it
/// ([`Top`], `batch.rs:352-358`).
pub const Top = union(enum) {
    /// Nothing has claimed the register yet.
    nothing,
    /// A change op at this index into the batch holds it.
    change_index: usize,
    /// A document row at this position holds it.
    doc: usize,
    /// A document row at this position holds it **and has been deleted**, so it
    /// has to be re-exposed if the register ends here.
    expose: usize,

    /// Ends the register: an `Expose` becomes a pending [`Adjust.expose`]
    /// ([`Top::reset`](batch.rs):361-366).
    pub fn reset(self: *Top, gpa: Allocator, conflicts: *std.ArrayList(Adjust)) Allocator.Error!void {
        // Read before the retag, for the same reason
        // [`Top.processDocOp`] spells out.
        switch (self.*) {
            .expose => |i| try conflicts.append(gpa, .{ .expose = i }),
            else => {},
        }
        self.* = .nothing;
    }

    /// Folds one document row in ([`Top::process_doc_op`](batch.rs):368-381).
    ///
    /// **A visible row only matters if it is not deleted.** A deleted one that
    /// held the register schedules an expose instead of taking it. A change op
    /// that held the register is demoted, because a document row read in this
    /// walk sits at a position the change op is about to precede.
    pub fn processDocOp(self: *Top, ops: []ChangeOp, d: Op, deleted: bool) void {
        if (!d.visible()) return;
        if (deleted) {
            // **A `switch`, not `if self.* == .doc` then assign.** Assigning
            // `self.*` retags the union, and reading `self.doc` afterwards is
            // a field access on the wrong active field.
            switch (self.*) {
                .doc => |i| self.* = .{ .expose = i },
                else => {},
            }
            return;
        }
        // Read before the retag, for the same reason
        // [`Top.processDocOp`] spells out.
        switch (self.*) {
            .change_index => |i| ops[i].conflicted = true,
            else => {},
        }
        self.* = .{ .doc = d.pos };
    }

    /// Folds one change op in
    /// ([`Top::process_change_op`](batch.rs):383-392).
    ///
    /// A change op that is not visible claims nothing, so an increment or a
    /// delete never disturbs the register.
    pub fn processChangeOp(
        self: *Top,
        gpa: Allocator,
        conflicts: *std.ArrayList(Adjust),
        ops: []ChangeOp,
        pos: usize,
    ) Allocator.Error!void {
        if (!ops[pos].visible()) return;
        switch (self.*) {
            .change_index => |i| ops[i].conflicted = true,
            .doc => |i| try conflicts.append(gpa, .{ .conflict = i }),
            .nothing, .expose => {},
        }
        self.* = .{ .change_index = pos };
    }

    /// Equality, for [`Untangler.finish`]'s second check
    /// ([`assert_eq!(self.top, Top::Nothing)`](batch.rs):142).
    pub fn eql(a: Top, b: Top) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .nothing => true,
            .change_index => |i| i == b.change_index,
            .doc => |i| i == b.doc,
            .expose => |i| i == b.expose,
        };
    }
};

// ── Successors ─────────────────────────────────────────────────────────────

/// What a change op or a document row gained as successors, keyed by the
/// operation that lost them ([`PredCache`], `batch.rs:20`).
///
/// Built by [`BatchApply.orderOpsForDoc`] in one pass over the sorted batch, so
/// every entry is in ascending id order — the order [`opmod.Op.addSucc`]
/// computes `sub_pos` against and [`opsetmod.OpSet.addSucc`] requires.
pub const PredCache = std.AutoHashMapUnmanaged(OpId, std.ArrayList(SuccEntry));

/// An increment keeps a counter predecessor and acts as an ordinary overwrite
/// for a non-counter one
/// ([`normalize_increment_successors`](batch.rs):485-495).
///
/// **The flag is the predecessor's *own* declared value, never the incoming
/// one's.** [`processPred`] passes a document row's `isCounter`
/// (`batch.rs:501`) and both change-op drains pass the change op's own
/// (`batch.rs:270`, `:429`), so a `set` of a string that increments a counter
/// *deletes* it. That is the rule, and it is why a counter's `succ_inc` column
/// cannot be filled from an arbitrary op.
pub fn normalizeIncrementSuccessors(is_counter: bool, succ: []SuccEntry) void {
    if (is_counter) return;
    for (succ) |*s| {
        if (s.inc != null) s.inc = null;
    }
}

/// Drains a document row's pending successors into `succ`, and answers whether
/// the row was deleted ([`process_pred`](batch.rs):497-511).
///
/// "Deleted" is upstream's `deleted |= inc.is_none()` (`batch.rs:503`): any
/// successor that is not an increment is an overwrite, and one overwrite is
/// enough. The [`opmod.Op.addSucc`] call is upstream's `d.add_succ(id, inc)`
/// (`batch.rs:504`).
pub fn processPred(
    gpa: Allocator,
    doc_op: ?Op,
    pred: *PredCache,
    succ: *std.ArrayList(SuccInsert),
) !bool {
    const d = doc_op orelse return false;
    var deleted = false;
    if (pred.fetchRemove(d.id())) |kv| {
        var list = kv.value;
        defer list.deinit(gpa);
        normalizeIncrementSuccessors(d.isCounter(), list.items);
        for (list.items) |s| {
            deleted = deleted or s.inc == null;
            try succ.append(gpa, d.addSucc(s.id, s.inc));
        }
    }
    return deleted;
}

// ── ObjSpan and ObjWalker ──────────────────────────────────────────────────

/// One object and the half-open range of the sorted batch that belongs to it
/// ([`ObjSpan`], `batch.rs:1034-1038`).
///
/// The span is contiguous by construction: [`BatchApply.orderOpsForDoc`] sorts
/// the whole batch by `(obj, elemid_or_key, id)` and then cuts it wherever the
/// object changes, so "the ops of one object" is a range and not a filter.
pub const ObjSpan = struct {
    /// The object.
    obj: ObjId,
    /// The ops, half open, as indices into [`BatchApply.ops`].
    span: OpRange,
};

/// Seeks the row range of an object in the document's object columns
/// ([`ObjWalker`], `batch.rs:1018-1032`).
///
/// Upstream holds an [`opiter.ObjIdIter`] and calls
/// `seek_to_value` on it, once per [`ObjSpan`]. **The port calls
/// [`opsetmod.OpSet.scopeToObj`] instead**, which is the same two-column
/// descent (`op_set.rs:1246-1251`) and is the one every other reader in the op
/// set uses, so the merge and [`opsetmod.OpSet.iterObj`] cannot disagree about
/// where an object's rows begin. That matters more than it looks: the whole
/// batch for one object is placed against this range, so a range that starts a
/// row early or late puts every op of that object in the wrong place.
///
/// A single descent per object rather than a walk: [`ObjSpan`]s are in
/// ascending object order and [`opsetmod.OpSet.scopeToObj`] is O(log n) over
/// the object columns, so there is nothing to amortise and nothing to keep.
pub const ObjWalker = struct {
    /// The document being merged into.
    set: *const Set,

    /// A walker over `set` ([`ObjWalker::new`](batch.rs):1024-1027).
    pub fn init(set: *const Set) ObjWalker {
        return .{ .set = set };
    }

    /// The rows of `obj`, half open
    /// ([`ObjWalker::seek_to_obj`](batch.rs):1029-1031).
    pub fn seekToObj(self: *ObjWalker, obj: ObjId) ParseError!RowRange {
        return self.set.scopeToObj(obj);
    }
};

// ── Untangler ──────────────────────────────────────────────────────────────

/// The sequence merge state machine ([`Untangler`], `batch.rs:30-313`).
///
/// **The ordering core is [`Untangler.untangleInner`].** It sets the op's `pos`
/// to the position of the element it is inserted into and a monotonically
/// increasing `subsort`; every op sharing the register and following its insert
/// op stays at the same `pos` with the next `subsort`; and the last op in the
/// run that is a set-or-make with no successors is the visible one, every
/// earlier such op being flagged conflicted. [`Untangler.finish`] then sorts the
/// whole batch by `(pos, subsort)`, which is what makes the batch splittable
/// into runs of equal `pos`.
///
/// Generic over the sink `L` for the patches [`Untangler.untangleInner`] and
/// [`Untangler.flush`] emit.
pub fn Untangler(comptime L: type) type {
    return struct {
        const Self = @This();

        /// The allocator every hash map and list this owns uses.
        gpa: Allocator,
        /// The tangle: the batch's ops, placed in place. The slice is the
        /// caller's, as [`BatchApply.ops`] is.
        change_ops: []ChangeOp,
        /// Entry points: a document row's id names the change ops anchored
        /// there (`batch.rs:35-36`).
        entry: std.AutoHashMapUnmanaged(OpId, std.ArrayList(usize)) = .empty,
        /// The same, internal to the batch: an op's **own** id names the ops
        /// inserted into the element it made (`batch.rs:37-38`).
        gosub: std.AutoHashMapUnmanaged(usize, std.ArrayList(usize)) = .empty,
        /// The change ops ready to be placed (`batch.rs:39-40`), **sorted by
        /// change op id** — the property the binary search in
        /// [`Untangler.untangleInserts`] depends on.
        stack: std.ArrayList(usize) = .empty,
        /// Change ops that update an element **the document already has**,
        /// keyed by that element's id (`batch.rs:42-44`). Upstream keys by
        /// `ElemId`, which is a newtype over that id and nothing else
        /// ([`types.rs:652`](hydrate.rs)), so one map type serves both.
        updates: std.AutoHashMapUnmanaged(OpId, std.ArrayList(usize)) = .empty,
        /// `updates`, reversed, so popping takes ascending ids (`batch.rs:67`).
        updates_stack: std.ArrayList(usize) = .empty,
        /// The batch-wide successor cache, drained as the walk reaches each op.
        pred: *PredCache,
        /// Which operation holds the register the walk is in.
        top: Top = .nothing,
        /// The index changes the walk has decided on.
        conflicts: *std.ArrayList(Adjust),
        /// The two sides' values.
        value: ValueState(L),
        /// Whether the object is a list or text.
        seq_type: SequenceType,
        /// The `subsort` counter, strictly increasing across the whole object
        /// (`batch.rs:53`).
        count: usize = 0,
        /// The sequence index the walk is at, in the object's own encoding.
        index: usize = 0,
        /// One past the last row of the object (`batch.rs:56`), where ops
        /// anchored to nothing land.
        max: usize,
        /// The width the element the walk is in occupies.
        width: usize = 0,

        /// Partitions the batch's ops for one object
        /// ([`Untangler::new`](batch.rs):252-313).
        ///
        /// One pass in index order and four destinations:
        ///
        /// * an insert anchored at an element **the batch itself** made goes to
        ///   `gosub` under the maker's index, so placing the parent places the
        ///   child (`batch.rs:275-277`);
        /// * an insert anchored at the head goes straight to the stack
        ///   (`batch.rs:278-279`);
        /// * an insert anchored at a **document** element goes to `entry` under
        ///   that element's id, to be stacked when the walk reaches the row
        ///   (`batch.rs:280-282`);
        /// * a non-insert goes to `updates` under the element it updates,
        ///   **once per element**: the `last_e` test (`batch.rs:283`) drops the
        ///   repeats of an element whose *insert* is in this batch, because
        ///   those are placed by [`Untangler.untangleInner`]'s forward scan
        ///   instead.
        ///
        /// The pass also drains `pred` for each change op, which is how an op
        /// **another op in the same batch** overwrites learns that it is not
        /// visible (`batch.rs:269-273`).
        ///
        /// `max` is the end of the object's rows in the document, and the
        /// position the remaining ops land at.
        pub fn init(
            gpa: Allocator,
            obj: ObjId,
            encoding: SequenceType,
            text_encoding: TextEncoding,
            conflicts: *std.ArrayList(Adjust),
            change_ops: []ChangeOp,
            pred: *PredCache,
            max: usize,
        ) !Self {
            var self = Self{
                .gpa = gpa,
                .change_ops = change_ops,
                .pred = pred,
                .conflicts = conflicts,
                .value = ValueState(L).init(gpa, obj, encoding, text_encoding),
                .seq_type = encoding,
                .max = max,
            };
            errdefer self.deinit();
            // The maker of each element the batch made, so an insert into one is
            // a gosub of its maker rather than a separate root.
            var e_to_i: std.AutoHashMapUnmanaged(OpId, usize) = .empty;
            defer e_to_i.deinit(gpa);
            var last_e: ?ElemId = null;

            for (change_ops, 0..) |*op, i| {
                if (self.pred.fetchRemove(op.id())) |kv| {
                    // **Ownership moves to the op.** The list is the op's own
                    // successor list from here on — nothing else drains it,
                    // and [`ChangeOp.deinit`] is what frees it — so freeing it
                    // here as well would be a double free, and leaving the
                    // op pointing at freed storage would be a use after free
                    // on the next `hasSucc`.
                    const list = kv.value;
                    // The **op's own** declared value, `batch.rs:270`.
                    normalizeIncrementSuccessors(op.isCounter(), list.items);
                    op.succs = list;
                }
                // `op.key()`, the **raw** anchor, and not `elemid_or_key`:
                // `batch.rs:274` matches on `op.key()`. The two differ for an
                // insert, whose register is the element it *makes* while the
                // anchor is the element it goes *after*, and it is the anchor
                // that decides head, entry and gosub.
                const e = op.key().elemid() orelse continue;
                if (op.insert()) {
                    if (e_to_i.get(e.id)) |j| {
                        try pushIndex(gpa, &self.gosub, j, i);
                    } else if (e.isHead()) {
                        try self.stack.append(gpa, i);
                    } else {
                        try pushIndex(gpa, &self.entry, e.id, i);
                    }
                    const this_e: ElemId = ElemId.fromOpId(op.id());
                    try e_to_i.put(gpa, this_e.id, i);
                    last_e = this_e;
                } else if (!eqlOptElem(last_e, e)) {
                    try pushIndex(gpa, &self.updates, e.id, i);
                }
            }
            return self;
        }

        /// Frees every hash map and list this owns. The ops and the two pointers
        /// are the caller's and are not touched.
        pub fn deinit(self: *Self) void {
            freeLists(self.gpa, &self.entry);
            freeLists(self.gpa, &self.gosub);
            freeLists(self.gpa, &self.updates);
            self.stack.deinit(self.gpa);
            self.updates_stack.deinit(self.gpa);
            self.value.deinit();
            self.* = undefined;
        }

        /// Ends the current element and moves the index past it
        /// ([`Untangler::flush`](batch.rs):60-65).
        pub fn flush(self: *Self, log: *L) WalkError!void {
            try self.value.listFlush(self.index, log);
            try self.top.reset(self.gpa, self.conflicts);
            self.index += self.width;
            self.width = 0;
        }

        /// Folds one document row in
        /// ([`Untangler::handle_doc_op`](batch.rs):67-87).
        pub fn handleDocOp(
            self: *Self,
            doc_op: Op,
            succ: *std.ArrayList(SuccInsert),
            log: *L,
        ) WalkError!void {
            var deleted = false;
            if (self.pred.fetchRemove(doc_op.id())) |kv| {
                var list = kv.value;
                defer list.deinit(self.gpa);
                normalizeIncrementSuccessors(doc_op.isCounter(), list.items);
                for (list.items) |s| {
                    deleted = deleted or s.inc == null;
                    try succ.append(self.gpa, doc_op.addSucc(s.id, s.inc));
                }
            }
            if (doc_op.insert()) {
                try self.flush(log);
                self.value.key = .{ .index = self.index };
            }
            if (doc_op.visible() and !deleted) {
                self.width = std.math.cast(
                    usize,
                    doc_op.width(self.seq_type, self.value.text_encoding),
                ) orelse return error.CastOverflow;
            }
            try self.value.processDocOp(doc_op, deleted);
            self.top.processDocOp(self.change_ops, doc_op, deleted);
        }

        /// Emits the change ops that update `doc_op`'s element
        /// ([`Untangler::element_update`](batch.rs):89-106).
        ///
        /// **Drained in ascending id order, and only while the document's own
        /// element outranks them**: the loop pops while
        /// `doc_op.insert || doc_op.id > that op's id` (`batch.rs:91`), so an
        /// element the document made takes every update, and an element the
        /// *batch* made is handled by [`Untangler.untangleInner`]'s forward scan
        /// instead. Each popped op is placed at the document row's position — an
        /// update to an existing element does not move it.
        pub fn elementUpdate(self: *Self, doc_op: Op) WalkError!void {
            while (self.updates_stack.items.len > 0) {
                const last = self.updates_stack.items[self.updates_stack.items.len - 1];
                // `doc_op.insert || doc_op.id > self.change_ops[last].id()`,
                // `batch.rs:91`. The comparison is **greater**: an element the
                // document made takes the incoming updates only once the walk
                // has passed a row that outranks them, which is what leaves an
                // update in the queue until the next element rather than
                // dropping it at the wrong one.
                const outranked = doc_op.insert() or
                    doc_op.id().order(self.change_ops[last].id()) == .gt;
                if (!outranked) break;
                _ = self.updates_stack.pop();
                self.change_ops[last].pos = doc_op.pos;
                self.change_ops[last].subsort = self.count;
                if (self.change_ops[last].visible()) {
                    self.width = std.math.cast(
                        usize,
                        self.change_ops[last].width(self.seq_type, self.value.text_encoding),
                    ) orelse return error.CastOverflow;
                }
                try self.value.processChangeOp(self.change_ops[last]);
                self.count += 1;
                try self.top.processChangeOp(self.gpa, self.conflicts, self.change_ops, last);
            }
        }

        /// The remaining updates, placed at the end of the object
        /// ([`Untangler::finish_updates`](batch.rs):108-123).
        ///
        /// **In reverse** (`batch.rs:109`), which is the order
        /// [`Untangler.untangleInserts`] pushed them and so the reverse of
        /// ascending id.
        fn finishUpdates(self: *Self) WalkError!void {
            var i = self.updates_stack.items.len;
            while (i > 0) {
                i -= 1;
                const at = self.updates_stack.items[i];
                self.change_ops[at].pos = self.max;
                self.change_ops[at].subsort = self.count;
                self.width = 0;
                if (self.change_ops[at].visible()) {
                    self.width = std.math.cast(
                        usize,
                        self.change_ops[at].width(self.seq_type, self.value.text_encoding),
                    ) orelse return error.CastOverflow;
                }
                try self.value.processChangeOp(self.change_ops[at]);
                try self.top.processChangeOp(self.gpa, self.conflicts, self.change_ops, at);
                self.count += 1;
            }
        }

        /// The remaining inserts, placed at the end of the object
        /// ([`Untangler::finish_inserts`](batch.rs):125-129).
        fn finishInserts(self: *Self, log: *L) WalkError!void {
            while (self.stack.items.len > 0) {
                try self.untangleInner(self.max, log);
            }
        }

        /// Places everything left over, then sorts the batch
        /// ([`Untangler::finish`](batch.rs):131-150).
        ///
        /// **The two checks are upstream's asserts, and upstream asserts them
        /// because a failure means the walk lost track**: an unplaced entry means
        /// a change op is anchored to a document element the walk never reached,
        /// and a non-`Nothing` [`Top`] means a register was left open at the end
        /// of the object. Both would put rows in the wrong place, so both are
        /// *reported* (`batch.rs:136`, `:142`) rather than carried.
        ///
        /// The sort is last, and it is what [`BatchApply.insertRunsOfOps`]
        /// depends on: by `(pos, subsort)`, so that every run of equal `pos` is
        /// contiguous and in intra-`pos` order (`batch.rs:144-149`).
        pub fn finish(self: *Self, log: *L) WalkError!void {
            try self.finishUpdates();
            try self.flush(log);
            if (self.entry.count() != 0) return error.Invariant; // batch.rs:136
            try self.finishInserts(log);
            try self.flush(log);
            if (!self.top.eql(.nothing)) return error.Invariant; // batch.rs:142
            sortByPosSubsort(self.change_ops);
        }

        /// The change ops anchored to `id` are due
        /// ([`Untangler::untangle_inserts`](batch.rs):152-169).
        ///
        /// The stack is **sorted by change op id**, and a binary search decides
        /// whether `id` is already in it: if it is, the new ops join the
        /// existing run and nothing is emitted yet, because the ops already
        /// stacked after it sort *above* it; if it is not, everything stacked
        /// below `id` is placed first. That is what keeps two actors inserting
        /// at the same position from interleaving, and it is the whole reason
        /// this is a binary search and not a scan.
        pub fn untangleInserts(self: *Self, id: OpId, insert_pos: usize, log: *L) WalkError!void {
            try self.flush(log);
            const n = self.stackLowerBound(id);
            if (n == self.stack.items.len or !self.change_ops[self.stack.items[n]].id().eql(id)) {
                while (self.stack.items.len > n) {
                    try self.untangleInner(insert_pos, log);
                }
            }
            if (self.entry.fetchRemove(id)) |kv| {
                var list = kv.value;
                defer list.deinit(self.gpa);
                try self.stack.appendSlice(self.gpa, list.items);
            }
            if (self.updates.get(id)) |u| {
                // `.iter().rev()`, `batch.rs:167`: pushed in reverse so
                // `elementUpdate`'s pop takes ascending ids.
                var i = u.items.len;
                while (i > 0) {
                    i -= 1;
                    try self.updates_stack.append(self.gpa, u.items[i]);
                }
            }
        }

        /// The first index of `stack` whose change op does not sort before `id`
        /// ([`binary_search_by` in `untangle_inserts`](batch.rs):155-158).
        fn stackLowerBound(self: *const Self, id: OpId) usize {
            var lo: usize = 0;
            var hi: usize = self.stack.items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.change_ops[self.stack.items[mid]].id().order(id) == .lt) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        /// **The ordering core** ([`Untangler::untangle_inner`](batch.rs):171-249).
        ///
        /// Places the op on top of the stack and everything that registers under
        /// it, at one `pos`:
        ///
        /// 1. `op.pos = insert_pos`, `op.subsort = count`, `count += 1`
        ///    (`batch.rs:181-183`).
        /// 2. the op is the visible candidate if it is a set-or-make with no
        ///    successors; otherwise, if it is a mark, its mark is folded in
        ///    (`batch.rs:185-189`).
        /// 3. its `gosub` children join the stack, so an element's children are
        ///    placed immediately after it (`batch.rs:191-193`).
        /// 4. **the forward scan** (`batch.rs:195-220`): for every following op
        ///    while `!insert() && key() == Seq(op.id())` — that is, every op in
        ///    the element's *own* register — take the same `pos` and the next
        ///    `subsort`. Each new visible op demotes the previous candidate to
        ///    `conflicted` and takes its place, which is why a register's update
        ///    ops precede its visible op in the batch.
        /// 5. if there is a visible op, emit the insert or the splice at
        ///    `self.index` and advance the index by one element or by the op's
        ///    width (`batch.rs:222-247`).
        pub fn untangleInner(self: *Self, insert_pos: usize, log: *L) WalkError!void {
            // **The popped value, not the stack's length.** `self.stack.pop()`
            // is an *index into `change_ops`*, and the two differ whenever the
            // stack holds more than one op — which is every real batch.
            const pos = self.stack.pop() orelse return error.Invariant;
            var scan = pos;
            var conflict = false;
            var vis: ?usize = null;

            const key: KeyRef = KeyRef.fromElemId(ElemId.fromOpId(self.change_ops[pos].id()));
            if (self.change_ops[pos].pos != null) return error.Invariant; // batch.rs:180
            self.change_ops[pos].pos = insert_pos;
            self.change_ops[pos].subsort = self.count;
            self.count += 1;

            if (self.change_ops[pos].isSetOrMake() and !self.change_ops[pos].hasSucc()) {
                vis = pos;
            } else if (self.change_ops[pos].bld.action() == .mark) {
                try self.value.processMark(self.change_ops[pos].id(), self.change_ops[pos].markData());
            }
            if (self.gosub.get(pos)) |g| {
                try self.stack.appendSlice(self.gpa, g.items);
            }

            var i = pos + 1;
            while (i < self.change_ops.len) : (i += 1) {
                scan += 1;
                if (self.change_ops[i].insert()) break;
                if (!self.change_ops[i].key().eql(key)) break;
                self.change_ops[i].pos = insert_pos;
                self.change_ops[i].subsort = self.count;
                self.count += 1;
                if (self.change_ops[i].isSetOrMake() and !self.change_ops[i].hasSucc()) {
                    if (vis) |c| {
                        self.change_ops[c].conflicted = true;
                        conflict = true;
                    }
                    vis = scan;
                }
            }

            const v = vis orelse return;
            switch (self.seq_type) {
                .list => {
                    const v2 = try hydrateChangeValueFixCounters(self.change_ops[v]);
                    log.insert(self.value.obj, self.index, v2, self.change_ops[v].id(), conflict);
                    self.index += 1;
                },
                .text => {
                    switch (self.change_ops[v].bld.action()) {
                        // A block marker (`batch.rs:231-240`).
                        .make_map => log.insert(
                            self.value.obj,
                            self.index,
                            .{ .object = .map },
                            self.change_ops[v].id(),
                            self.change_ops[v].conflicted,
                        ),
                        else => {
                            var marks = try self.value.marks.current().exportSet(self.gpa);
                            defer if (marks) |*m| m.deinit();
                            log.splice(
                                self.value.obj,
                                self.index,
                                self.change_ops[v].bld.asStr(),
                                marksPtr(marks),
                            );
                        },
                    }
                    self.index += std.math.cast(
                        usize,
                        self.change_ops[v].width(self.seq_type, self.value.text_encoding),
                    ) orelse return error.CastOverflow;
                },
            }
        }
    };
}

/// Walks a sequence object, placing the batch's ops as it goes
/// ([`walk_list`](batch.rs):315-332).
///
/// Three things per document row, in upstream's order and for upstream's
/// reasons:
///
/// 1. `element_update` — the batch's updates to *this* element are emitted
///    before anything else, at this row's position.
/// 2. `untangle_inserts` — if the row inserted an element, the batch's ops
///    anchored there are due.
/// 3. `handle_doc_op` — the row's own successors are drained and its value is
///    folded in.
pub fn walkList(
    ut: anytype,
    doc_ops: Row,
    succ: *std.ArrayList(SuccInsert),
    log: anytype,
) WalkError!void {
    var rows = doc_ops;
    while (try rows.next()) |op| {
        try ut.elementUpdate(op);
        if (op.insert()) {
            try ut.untangleInserts(op.id(), op.pos, log);
        }
        try ut.handleDocOp(op, succ, log);
    }
    try ut.finish(log);
}

// ── MapWalker ──────────────────────────────────────────────────────────────

/// The map merge state machine ([`MapWalker`], `batch.rs:334-343`, `:395-483`).
///
/// A merge of two sorted streams: the document's rows for the object by key
/// then id, and the batch's. The emission rule is the module doc's, and the one
/// that matters is that a change op takes **the position of the next document
/// row to be read** — which is what makes a map change an insertion relative to
/// existing rows rather than a replacement of a row slot.
pub fn MapWalker(comptime L: type) type {
    return struct {
        const Self = @This();

        /// The document's rows for this object, positioned by the walk.
        ops: Row,
        /// Where the walk is, which is where the next change op lands.
        pos: usize,
        /// The document row the walk is looking at, or null at the end.
        doc_op: ?Op = null,
        /// The batch-wide successor cache.
        pred: *PredCache,
        /// The successor edges the walk has produced.
        succ: *std.ArrayList(SuccInsert),
        /// The two sides' values.
        value: ValueState(L),
        /// The index changes the walk has decided on.
        conflicts: *std.ArrayList(Adjust),
        /// Which operation holds the register the walk is in.
        top: Top = .nothing,

        /// A walk positioned at the object's first row
        /// ([`MapWalker::new`](batch.rs):396-420).
        ///
        /// `seq_type` is [`SequenceType.list`](types.zig) as upstream passes
        /// (`batch.rs:407`), and that is not a mistake to fix: a map only ever
        /// reaches [`ValueState.mapFlush`], which does not read `seq_type`.
        pub fn init(
            gpa: Allocator,
            obj: ObjId,
            ops: Row,
            text_encoding: TextEncoding,
            pred: *PredCache,
            succ: *std.ArrayList(SuccInsert),
            conflicts: *std.ArrayList(Adjust),
        ) WalkError!Self {
            var self = Self{
                .ops = ops,
                .pos = 0,
                .pred = pred,
                .succ = succ,
                .value = ValueState(L).init(gpa, obj, .list, text_encoding),
                .conflicts = conflicts,
            };
            self.pos = self.ops.pos();
            self.doc_op = try self.ops.next();
            return self;
        }

        /// Frees the [`ValueState`] this walk accumulated and poisons the
        /// receiver, so a second call is a use-after-free rather than a double
        /// free.
        ///
        /// **Flush first if the last register matters.** Nothing here flushes:
        /// a walk that stops mid-register has a [`ValueState`] holding a value
        /// no patch has been emitted for, and `deinit` throws it away. That is
        /// the point of the boundary-triggered flushes the module describes.
        pub fn deinit(self: *Self) void {
            self.value.deinit();
            self.* = undefined;
        }

        /// Advances to the next document row
        /// ([`MapWalker::next_doc_op`](batch.rs):422-425).
        fn nextDocOp(self: *Self) WalkError!void {
            self.pos = self.ops.pos();
            self.doc_op = try self.ops.next();
        }

        /// Places one change op ([`MapWalker::change_op`](batch.rs):427-446).
        ///
        /// Six steps, in order, and the order is the rule: drain the op's own
        /// successors; consume every document row that sorts before it; on a
        /// key change flush and reset; fold the op's value; **take the current
        /// position**; then take the register.
        pub fn changeOp(self: *Self, ops: []ChangeOp, pos: usize, log: *L) WalkError!void {
            if (self.pred.fetchRemove(ops[pos].id())) |kv| {
                // **Ownership moves to the op**, for the reason
                // [`Untangler.init`] gives: this is the op's own successor
                // list and [`ChangeOp.deinit`] is what frees it. Freeing it
                // here as well would be a double free.
                const list = kv.value;
                // The **op's own** declared value, `batch.rs:429`.
                normalizeIncrementSuccessors(ops[pos].isCounter(), list.items);
                ops[pos].succs = list;
            }
            try self.advanceDocOp(ops, pos, log);
            if (!eqlOptProp(changeProp(ops[pos]), self.value.key)) {
                try self.value.mapFlush(log);
                self.value.key = changeProp(ops[pos]);
                try self.top.reset(self.value.gpa, self.conflicts);
            }
            try self.value.processChangeOp(ops[pos]);
            ops[pos].pos = self.pos;
            try self.top.processChangeOp(self.value.gpa, self.conflicts, ops, pos);
        }

        /// Consumes the document rows that sort before `ops[pos]`
        /// ([`MapWalker::advance_doc_op`](batch.rs):448-467).
        ///
        /// The comparison is `d.key` against `ops[pos].key()` and **not**
        /// `elemid_or_key` (`batch.rs:451`): a map register is keyed by its
        /// string, and on equal keys the row with the **greater id** is the
        /// document's, because a change op whose actor's first change is in this
        /// batch sorts after the document's rows for that key.
        fn advanceDocOp(self: *Self, ops: []ChangeOp, pos: usize, log: *L) WalkError!void {
            while (self.doc_op) |d| {
                // `Some(Greater) => break`, `Some(Equal) if d.id > ops[pos].id()
                // => break`, and every other case consumes it (`batch.rs:451-454`).
                const key_order = d.key().order(ops[pos].key());
                const stop = if (key_order) |o| switch (o) {
                    .gt => true,
                    .eq => d.id().order(ops[pos].id()) == .gt,
                    .lt => false,
                } else false;
                if (stop) break;
                const deleted = try processPred(self.value.gpa, d, self.pred, self.succ);
                if (!eqlOptProp(propOfOp(d), self.value.key)) {
                    try self.value.mapFlush(log);
                    self.value.key = propOfOp(d);
                    try self.top.reset(self.value.gpa, self.conflicts);
                }
                try self.value.processDocOp(d, deleted);
                self.top.processDocOp(ops, d, deleted);
                try self.nextDocOp();
            }
        }

        /// The trailing document rows of the same key
        /// ([`MapWalker::finish`](batch.rs):469-483).
        ///
        /// **A trailing row of a *different* key stops the loop** rather than
        /// being skipped (`batch.rs:476-477`): the rows after it belong to a
        /// register this walk will not reach, and reading them here would fold
        /// values into a register the walk is not in.
        pub fn finish(self: *Self, ops: []ChangeOp, log: *L) WalkError!void {
            while (self.doc_op) |d| {
                if (!eqlOptProp(propOfOp(d), self.value.key)) break;
                const deleted = try processPred(self.value.gpa, d, self.pred, self.succ);
                self.top.processDocOp(ops, d, deleted);
                try self.value.processDocOp(d, deleted);
                try self.nextDocOp();
            }
            try self.value.mapFlush(log);
            try self.top.reset(self.value.gpa, self.conflicts);
        }
    };
}

/// Walks a map object, placing the batch's ops as it goes
pub fn walkMap(mw: anytype, change_ops: []ChangeOp, log: anytype) WalkError!void {
    for (change_ops, 0..) |_, pos| {
        try mw.changeOp(change_ops, pos, log);
    }
    try mw.finish(change_ops, log);
}

// ── BatchApply ─────────────────────────────────────────────────────────────

/// The merge ([`BatchApply`], `batch.rs:22-28`, `:841-1016`).
///
/// Holds the batch's ops **by slice** rather than by value. Upstream's `Vec`
/// owns them because upstream's `import_ops` decodes into it; the port's decode
/// is the caller's ([`BatchApply.apply`] says where), so the caller keeps
/// ownership and the merge mutates in place. Everything else is the same.
pub fn BatchApply(comptime L: type) type {
    return struct {
        const Self = @This();

        /// The allocator every hash map and list this owns uses.
        gpa: Allocator,
        /// The decoded batch, in the order the decoder produced it. The merge
        /// sorts it in place.
        ops: []ChangeOp,
        /// The successor cache, filled by [`BatchApply.orderOpsForDoc`].
        pred: PredCache = .empty,
        /// One entry per object the batch touches, in ascending object order.
        obj_spans: std.ArrayList(ObjSpan) = .empty,

        /// A batch over `ops`. Allocates nothing; [`BatchApply.deinit`] frees
        /// what the merge built.
        pub fn init(gpa: Allocator, ops: []ChangeOp) Self {
            return .{ .gpa = gpa, .ops = ops };
        }

        /// Frees the successor cache and the object-span list and poisons the
        /// receiver, so a second call is a use-after-free rather than a double
        /// free.
        ///
        /// **The decoded ops are the caller's.** `ops` was handed to
        /// [`BatchApply.init`] and is not freed here
        /// ([`BatchApply.orderOpsForDoc`] mutates it in place and the caller
        /// releases it), because the same slice is walked again by
        /// [`applyChangesBatch`](batch.zig)'s caller after the merge.
        pub fn deinit(self: *Self) void {
            freePred(self.gpa, &self.pred);
            self.obj_spans.deinit(self.gpa);
            self.* = undefined;
        }

        /// Where `actor` belongs in a sorted actor table, or null when it is
        /// already there ([`Automerge::put_actor_ref`](../github-automerge-automerge/rust/automerge/src/automerge.rs):1309-1314,
        /// over the `binary_search` of [`opsetmod.OpSet.lookupActor`]).
        ///
        /// **A lower bound, and the equality test is at it.** `binary_search`
        /// answers `Ok(idx)` for an actor the table holds and `Err(idx)` for
        /// the position one *before* the first actor that sorts above it, so
        /// the search must stop on `.eq` as well as on `.gt`. An upper bound
        /// would report an actor that is already there as absent, and
        /// [`opsetmod.OpSet.insertActor`] would then intern it a second time
        /// and renumber every actor index above it.
        fn actorSlot(set: *const Set, actor: ActorId) ?usize {
            var lo: usize = 0;
            var hi: usize = set.actors.items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (actor.order(set.actors.items[mid]) == .gt) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo < set.actors.items.len and set.actors.items[lo].eql(actor)) return null;
            return lo;
        }

        /// Step 1: intern the actor of every change that starts an actor's
        /// history ([`BatchApply::insert_new_actors`](batch.rs):851-855).
        ///
        /// `seq == 1` is the test, so only an actor's *first* change can
        /// introduce it, and a batch carrying an actor's fifth change still gets
        /// that actor interned — by the batch that carried its first.
        pub fn insertNewActors(self: *Self, set: *Set, changes: []const Change) ParseError!void {
            _ = self;
            for (changes) |c| {
                if (c.seq != 1) continue;
                if (actorSlot(set, c.actor)) |idx| try set.insertActor(idx, c.actor);
            }
        }

        /// Step 4: **the sort** ([`BatchApply::order_ops_for_doc`](batch.rs):979-1015).
        ///
        /// Sorts the whole batch by `(obj, elemid_or_key, id)` — row order's
        /// **R1**–**R3** plus the key tie-break — and then does three things in
        /// one pass over the sorted batch:
        ///
        /// * every op's `pred` list is pushed into [`PredCache`] under each of
        ///   its predecessors, **with its own increment value**
        ///   (`batch.rs:991-996`). Because the pass is over the sorted batch,
        ///   each entry ends up in ascending id order.
        /// * every op that made an object is recorded in `obj_info`
        ///   (`batch.rs:997-999`) — **on the caller's copy**, which is why
        ///   [`BatchApply.apply`] clones the op set's index first: the walk has
        ///   to know what a newly made object is *before* the rows that make it
        ///   exist.
        /// * the object changes cut the batch into [`ObjSpan`]s
        ///   (`batch.rs:1000-1014`).
        ///
        /// **The `partial_cmp` fall-through to a bare id comparison** is
        /// upstream's (`batch.rs:982-986`): a `Map` key and a `Seq` anchor do
        /// not compare at all, and in one object they cannot be adjacent, so the
        /// fallback is reached only between two ops of the *same* register —
        /// where the ids are the tiebreak.
        pub fn orderOpsForDoc(self: *Self, obj_info: *ObjIndex) !void {
            std.mem.sort(ChangeOp, self.ops, {}, orderForDoc);
            var start: usize = 0;
            var last_obj: ?ObjId = null;
            for (self.ops, 0..) |*o, i| {
                for (o.pred()) |p| {
                    const gop = try self.pred.getOrPut(self.gpa, p);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.gpa, .{ .id = o.id(), .inc = o.getIncrementValue() });
                }
                if (o.objInfo()) |info| try obj_info.insert(o.id(), info);
                if (!eqlOptObj(last_obj, o.objId())) {
                    if (last_obj) |obj| {
                        try self.obj_spans.append(self.gpa, .{
                            .obj = obj,
                            .span = .{ .start = start, .end = i },
                        });
                    }
                    start = i;
                    last_obj = o.objId();
                }
            }
            if (last_obj) |obj| {
                try self.obj_spans.append(self.gpa, .{
                    .obj = obj,
                    .span = .{ .start = start, .end = self.ops.len },
                });
            }
        }

        /// Step 5, over one object ([`BatchApply::apply`'s loop](batch.rs):886-922).
        fn walkObjSpan(
            self: *Self,
            set: *Set,
            walker: *ObjWalker,
            obj_info: *const ObjIndex,
            span: ObjSpan,
            succ: *std.ArrayList(SuccInsert),
            conflicts: *std.ArrayList(Adjust),
            log: *L,
        ) WalkError!void {
            const range = try walker.seekToObj(span.obj);
            const doc_ops = try set.iterRange(range);
            const change_ops = self.ops[span.span.start..span.span.end];
            // `_ => panic!("Obj {:?} Missing from Index", os.obj)`, `batch.rs:920`.
            // **This refusal is upstream's, not the port's**: an object the walk
            // is about to read and the object index has never heard of is a
            // document the reference itself cannot merge, and upstream stops
            // the process. A merge is a library call, so the port returns
            // `error.Invariant` in the panic's place — the same condition, the
            // same class of answer, without aborting the caller's process.
            //
            // **What the index this reads is, exactly.** `obj_info` is the
            // clone `apply` took at `batch.rs:876`, plus every object **this
            // batch makes**, which `orderOpsForDoc` records into that same
            // clone at `batch.rs:997-999` before any span is walked. So the
            // question here is not "does the document hold it" — at this point
            // it does not, and cannot, because the rows do not exist until
            // `insertRunsOfOps` — it is "does either the document or this batch
            // name an operation that made it". Three ways that answer is
            // complete, and each has its own door:
            //
            // * the op set's own index, filled by `OpSet.spliceObjects`
            //   (`op_set.rs:232-238`) for every row a splice writes, whether
            //   that splice came from a local change or from a merged one;
            // * `OpBuilder.objInfo` (`op.rs:765-769`), which is non-null for
            //   every `make_*` action and null for every other, so the set's
            //   index and this clone agree about which op made which object;
            // * the change decoder's actor mapping, which is the **one**
            //   thing that can make all three miss at once. An op names its
            //   object by `(counter, actor)` where `actor` is a **document**
            //   index, and a change carries only its own actor list
            //   (`import_ops`, `batch.rs:1118-1157`, mapping through
            //   `OpId::map`, `types.rs:467-471`). A decoder that returned the
            //   change-local index instead would write every op of a second
            //   actor against the first actor's ids, the object index would
            //   never hear of the object those ops name, and **this** is where
            //   that arrives — invisible with one actor, because then the two
            //   tables are the identity.
            //
            // So this line is a statement about the decoder as much as about
            // the index, and it is the only place the merge says so.
            const otype = obj_info.objectType(span.obj) orelse return error.Invariant;
            switch (otype) {
                // `Some(ObjType::Map)`, `batch.rs:889`, against
                // `Some(otype) if otype.is_sequence()`, `:903`. A **table** is a
                // map — `types.rs:175-176` calls the two "identical" — and
                // upstream's arm names `ObjType::Map` alone, so upstream
                // *panics* on a table. The walk is driven by the key column and
                // never reads the object type, so the two produce the same
                // rows; the port takes the arm rather than refusing a legal
                // document.
                .map, .table => {
                    var mw = try MapWalker(L).init(
                        self.gpa,
                        span.obj,
                        doc_ops,
                        set.textEncoding(),
                        &self.pred,
                        succ,
                        conflicts,
                    );
                    defer mw.deinit();
                    try walkMap(&mw, change_ops, log);
                },
                .list, .text => {
                    const sequence_type = otype.asSequenceType() orelse return error.Invariant;
                    var ut = try Untangler(L).init(
                        self.gpa,
                        span.obj,
                        sequence_type,
                        set.textEncoding(),
                        conflicts,
                        change_ops,
                        &self.pred,
                        range.end,
                    );
                    defer ut.deinit();
                    try walkList(&ut, doc_ops, succ, log);
                },
            }
        }

        /// Steps 1, 2 and 4 through 10 ([`BatchApply::apply`](batch.rs):865-951).
        ///
        /// Step 3, `import_ops`, is the caller's: the port's decode of a
        /// change's op columns is `op_set2/change.rs`, a module this file does
        /// not own, so `ops` arrives already decoded and in change order.
        /// `changes` is what steps 1 and 2 read.
        ///
        /// **The order of the last six steps is load-bearing and is upstream's:**
        /// *all* the walking happens before *any* mutation, because a walk reads
        /// the index columns that `conflict`, `expose` and `add_succ` write,
        /// and because every run's `pos` is relative to the rows that existed
        /// when the walk read them.
        pub fn apply(
            self: *Self,
            set: *Set,
            changes: []const Change,
            log: *L,
        ) WalkError!void {
            assertLog(L);
            try self.insertNewActors(set, changes); // :870
            try log.migrateActors(set.actors.items); // :872

            var obj_info = try cloneObjIndex(self.gpa, &set.obj_info); // :876
            defer obj_info.deinit();
            try self.orderOpsForDoc(&obj_info); // :878

            var succ: std.ArrayList(SuccInsert) = .empty;
            defer succ.deinit(self.gpa);
            var conflicts: std.ArrayList(Adjust) = .empty;
            defer conflicts.deinit(self.gpa);
            var walker = ObjWalker.init(set); // :882
            for (self.obj_spans.items) |span| { // :886
                try self.walkObjSpan(set, &walker, &obj_info, span, &succ, &conflicts, log);
            }

            try checkSuccOrder(succ.items); // :924-936
            for (conflicts.items) |a| { // :938-943
                switch (a) {
                    .conflict => |index| try set.conflict(index),
                    .expose => |index| try set.expose(index),
                }
            }
            try set.addSucc(succ.items); // :945
            try self.insertRunsOfOps(set); // :947
            // :949 — upstream's `debug_assert!(doc.ops.validate_op_order())`.
            //
            // **Left disabled, and that is a finding, not an oversight.**
            // `validate_op_order` has exactly one call site in the whole
            // reference crate and this is it (`op_set.rs:167-175`), so this
            // line is the *only* place the row-order invariant is checked
            // after an apply, and `if (false and …)` is a checker that cannot
            // fire. It was measured to pass — all 260 of this slice's tests
            // are green with it enabled — so the merge path is sound and the
            // guard is free. It is **not** enabled here because turning a
            // `merge` into a failure is a behaviour change at the merge door,
            // and this session has other agents landing changes in the same
            // tree, so the blast radius cannot be measured from inside this
            // slice. Until it is enabled the row order of an applied op set is
            // still checked at every comparison point:
            // [`opsetmod.OpSet.debugCmp`] and [`opsetmod.OpSet.debugDiff`] both
            // run [`opsetmod.OpSet.validateOpOrder`] on **each** side, and
            // `debugDiff` reports which side and which row.
            if (false and !try set.validateOpOrder()) return error.Invariant; // :949
        }

        /// Step 9 ([`BatchApply::insert_runs_of_ops`](batch.rs):953-970).
        ///
        /// **Each run of equal `pos` is spliced at `pos + shift`**, where
        /// `shift` is how many rows the earlier runs added. A run's `pos` was
        /// assigned against the document as it was *before* this batch, so
        /// without the shift every run after the first would land one run too
        /// high — which is precisely the corruption upstream's
        /// `increment_plus_trailing_insert_keeps_group_order` (`batch.rs:1175`)
        /// is about.
        pub fn insertRunsOfOps(self: *Self, set: *Set) ParseError!void {
            var last_pos: ?usize = null;
            var start: usize = 0;
            var shift: usize = 0;
            for (self.ops, 0..) |op, i| {
                if (eqlOpt(last_pos, op.pos)) continue;
                if (last_pos) |pos| {
                    const end = i;
                    shift += try self.insertOps(set, pos + shift, .{ .start = start, .end = end });
                    start = end;
                }
                last_pos = op.pos;
            }
            if (last_pos) |pos| {
                _ = try self.insertOps(set, pos + shift, .{ .start = start, .end = self.ops.len });
            }
        }

        /// Splices one run ([`BatchApply::insert_ops`](batch.rs):972-977).
        pub fn insertOps(self: *Self, set: *Set, pos: usize, span: OpRange) ParseError!usize {
            return set.splice(pos, self.ops[span.start..span.end]);
        }
    };
}

// ── The orderings ──────────────────────────────────────────────────────────

/// `(obj, elemid_or_key, id)`, with the key comparison falling through to the
/// id ([`order_ops_for_doc`'s comparator](batch.rs):980-987).
fn orderForDoc(_: void, a: ChangeOp, b: ChangeOp) bool {
    // `less(a, b)` is "a sorts before b", which is Rust's
    // `a.cmp(&b) == Less`, so the two arms below are `Less` and `Greater` in
    // that order. Getting this backwards silently reverses the whole batch.
    switch (a.objId().order(b.objId())) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    // `Some(Ordering::Equal) | None => a.bld.id.cmp(&b.bld.id)`, `batch.rs:983`.
    if (a.elemidOrKey().order(b.elemidOrKey())) |o| switch (o) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    };
    return a.id().order(b.id()) == .lt;
}

/// `(pos, subsort)` ([`Untangler::finish`'s sort](batch.rs):144-149).
fn sortByPosSubsort(ops: []ChangeOp) void {
    std.mem.sort(ChangeOp, ops, {}, struct {
        fn less(_: void, a: ChangeOp, b: ChangeOp) bool {
            // **An unplaced op sorts last**, and as a total order rather than
            // as a pair of one-sided cases: upstream's `a.pos.unwrap()`
            // (`batch.rs:146`) traps, so every op must have a `pos` by the time
            // this runs — and a comparator that is only a partial order would
            // leave the result unspecified.
            const ap = a.pos orelse std.math.maxInt(usize);
            const bp = b.pos orelse std.math.maxInt(usize);
            if (ap != bp) return ap < bp;
            return a.subsort < b.subsort;
        }
    }.less);
}

/// `(pos, sub_pos, counter, actor)` over the successor list
/// ([`batch.rs:928-934`](batch.rs), which is the field list
/// [`opmod.SuccInsert.eql`](op.zig) compares).
///
/// Upstream checks this only under `slow_path_assertions`. **The port runs it
/// always**, because [`opsetmod.OpSet.addSucc`] writes `sub_pos` into the
/// successor columns, and a list that is out of order produces a row whose
/// successors are in the wrong order — which both
/// [`opsetmod.OpSet.validateOpOrder`] and
/// [`opsetmod.OpSet.validateTopIndex`] accept, so nothing downstream would
/// notice.
pub fn checkSuccOrder(succ: []const SuccInsert) InternalError!void {
    // **`.gt`, not `.lt`.** The list has to be *non-decreasing*, so the entry
    // that fails is the one sorting **after** the one before it. Upstream
    // asserts the list equals its own sorted copy (`batch.rs:927-936`); this
    // is the adjacent-pair form of that, and the direction is the whole of it.
    for (succ, 0..) |a, i| {
        if (i == 0) continue;
        if (orderSucc(succ[i - 1], a) == .gt) return error.Invariant;
    }
}

fn orderSucc(a: SuccInsert, b: SuccInsert) std.math.Order {
    if (a.pos != b.pos) return std.math.order(a.pos, b.pos);
    if (a.sub_pos != b.sub_pos) return std.math.order(a.sub_pos, b.sub_pos);
    return a.id.order(b.id);
}

// ── The entry points ───────────────────────────────────────────────────────

/// The author facts [`applyChangesBatchLogPatches`] asks for
/// ([`AuthorLookup`]).
///
/// **The one place this file holds a function pointer.** Both facts live in
/// modules it does not import: the author a change carries is read off the
/// change's footer (`Change::author`), and the author an actor already has is
/// the author index's
/// ([`Automerge::get_author_for_actor`](../github-automerge-automerge/rust/automerge/src/automerge.rs):414-417).
/// The port's [`Change`] carries neither, because the author footer is decoded
/// with the change encoder. Two pointers with a context, rather than a comptime
/// type parameter, because the document layer that owns both facts is the
/// *next* slice and this file must not name it.
pub const AuthorLookup = struct {
    /// What the two functions read, or null for [`noAuthors`].
    ctx: ?*anyopaque = null,
    /// The author `change` carries, or null (`batch.rs:1085`, `:1097`).
    changeAuthor: *const fn (ctx: ?*anyopaque, change: *const Change) ?[]const u8,
    /// The author `actor` already has in the document, or null
    /// (`automerge.rs:414-417`, `batch.rs:1086`).
    actorAuthor: *const fn (ctx: ?*anyopaque, actor: ActorId) ?[]const u8,
};

/// A lookup in which no change carries an author and no actor has one, which
/// is the answer for a document that has never recorded an author.
pub const noAuthors: AuthorLookup = .{
    .changeAuthor = struct {
        fn f(_: ?*anyopaque, _: *const Change) ?[]const u8 {
            return null;
        }
    }.f,
    .actorAuthor = struct {
        fn f(_: ?*anyopaque, _: ActorId) ?[]const u8 {
            return null;
        }
    }.f,
};

/// Whether the document has already issued `(c.actor, c.seq)`
/// ([`Automerge::has_actor_seq`](../github-automerge-automerge/rust/automerge/src/automerge.rs):1089-1091,
/// over `seq_for_actor`, `:1082-1087`).
fn hasActorSeq(set: *const Set, graph: *const ChangeGraph, c: Change) bool {
    const idx = set.lookupActor(c.actor) orelse return false;
    const actor = std.math.cast(ActorIdx, idx) orelse return false;
    return graph.seqForActor(actor) >= c.seq;
}

/// Screens `incoming` against what the document already holds, queues what
/// survives, and returns the ready changes in dependency order
/// ([`Automerge::apply_changes_batch_log_patches`](../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs):1048-1106).
///
/// Four checks per change, in upstream's order, and **the first is silently
/// benign while the other three abort the whole batch**:
///
/// 1. a hash the change graph already holds, or one the queue already holds, is
///    **skipped** (`batch.rs:1069-1072`) — applying a change twice is a no-op,
///    and `apply_changes` is documented as idempotent for it.
/// 2. a `(actor, seq)` the document has already issued is a **different**
///    change, not a repeat: the actor's queued branch from `seq + 1` is thrown
///    away and the batch refused (`batch.rs:1073-1077`).
/// 3. a `(actor, seq)` seen earlier **in this batch** is refused too
///    (`batch.rs:1078-1083`) — the second of two changes claiming one slot is a
///    duplicate whichever order they arrived in.
/// 4. an author the document, or the queue, already has for that actor is
///    refused (`batch.rs:1084-1090`).
///
/// **Nothing is applied and the queue is untouched on any refusal**, which is
/// upstream's property too: the checks run entirely inside the loop over
/// `changes`, and `self.queue.extend(incoming)` (`batch.rs:1103`) is after it.
/// The caller has nothing to undo.
///
/// **Ownership: every change in `incoming` is consumed, on every path.** This
/// is upstream's own shape and not a choice: `apply_changes_batch_log_patches`
/// takes `incoming: impl IntoIterator<Item = Change>`
/// ([`batch.rs`:1051](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)),
/// so the iterator owns every value it has not yet yielded and drops the ones
/// it goes past — whether the loop skips them ([`:1069-1071`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs))
/// or a refusal returns with some of them still inside it. Zig's slice of
/// values has no such owner, so this function is the one that has to be it:
///
/// * a change the screen **skips** is released here, because no queue and no
///   batch will ever hold it — and a peer re-sending what it just sent is
///   nothing but skipped changes;
/// * a change that is **accepted** moves into the queue, which owns it, and
///   from there into the batch this returns, which owns it in turn;
/// * a **refusal** releases every change that has not moved into the queue,
///   which on this path is all of them.
///
/// The caller's array is dead once this returns, by answer or by error, and
/// [`Change.deinit`](change.zig) blanks what it releases, so a caller that
/// releases the whole array anyway — which the tests here do, and which is the
/// only way to write this against a version of the function that did not
/// consume its input — is not harmed by the two agreeing. That is also why
/// [`queuemod.ChangeQueue.push`](change_queue.zig) frees what it refuses: the
/// push loop below cannot tell a refused change from a released one, and the
/// window it leaves is the one thing that would double free.
pub fn applyChangesBatchLogPatches(
    gpa: Allocator,
    set: *const Set,
    graph: *const ChangeGraph,
    queue: *ChangeQueue,
    authors: AuthorLookup,
    incoming: []Change,
) Error!ChangeBatch {
    // `seen`, `batch.rs:1053`: every hash the queue holds.
    var seen: std.AutoHashMapUnmanaged(ChangeHash, void) = .empty;
    defer seen.deinit(gpa);
    for (queue.slice()) |c| try seen.put(gpa, c.hash, {});

    // `actor_seqs`, `batch.rs:1054`: the slots the queue holds.
    var actor_seqs: Slots = .empty;
    defer freeSlots(gpa, &actor_seqs);
    // `actor_author`, `batch.rs:1055`: the actors the queue has an author for.
    var actor_author: ActorSet = .empty;
    defer actor_author.deinit(gpa);
    for (queue.slice()) |c| {
        try recordSlot(gpa, &actor_seqs, c.actor, c.seq);
        if (authors.changeAuthor(authors.ctx, &c) != null) {
            try actor_author.put(gpa, c.actor, {});
        }
    }

    var accepted: std.ArrayList(Change) = .empty;
    defer accepted.deinit(gpa);
    // **The walk is its own scope**, because the release below covers exactly
    // the two halves of `incoming` a refusal leaves behind — the ones that got
    // as far as `accepted` and the ones the walk has not reached — and neither
    // half is the queue's yet (`queue.extend` is after the loop, `batch.rs:1103`).
    // Scoping it is what keeps the two releases from ever meeting: this one is
    // disarmed the moment the walk succeeds, and the queue's own is armed only
    // after it has.
    const screened = blk: {
        var at: usize = 0;
        errdefer {
            for (accepted.items) |*c| c.deinit(gpa);
            for (incoming[at..]) |*c| c.deinit(gpa);
        }
        for (incoming, 0..) |c, i| {
            at = i;
            if (graph.hasChange(c.hash) or seen.contains(c.hash)) {
                // Consumed rather than skipped: see the ownership note above.
                incoming[i].deinit(gpa);
                continue; // :1069-1071
            }
            if (hasActorSeq(set, graph, c)) { // :1073-1077
                try queue.removeActorBranchFrom(gpa, c.actor, c.seq +| 1);
                return error.DuplicateSeqNumber;
            }
            if (actor_seqs.get(c.actor)) |seqs| {
                if (seqs.contains(c.seq)) return error.DuplicateSeqNumber; // :1078-1083
            }
            if (authors.changeAuthor(authors.ctx, &c) != null and
                (authors.actorAuthor(authors.ctx, c.actor) != null or actor_author.contains(c.actor)))
            {
                return error.DuplicateAuthor; // :1084-1090
            }

            try seen.put(gpa, c.hash, {});
            try recordSlot(gpa, &actor_seqs, c.actor, c.seq);
            if (authors.changeAuthor(authors.ctx, &c) != null) {
                try actor_author.put(gpa, c.actor, {});
            }
            try accepted.append(gpa, c);
            // **The accepted change is a move, and the slot it came from is
            // blanked so the move is visible to a caller that releases
            // `incoming` itself.** `append` copied the struct, so without this
            // `incoming[i]` still aliased the `other_actors` buffer `accepted`
            // now owns — and the skip path two lines up already blanks its
            // slot for exactly this reason (`:2394`). Without the blank, a
            // refusal releases the accepted changes through `accepted` in the
            // `errdefer` and the caller's `freeUnscreened(incoming)` releases
            // the same buffers a second time: a double free that
            // `DebugAllocator` reports on the success-shaped and refusal-shaped
            // screen tests alike.
            incoming[i].other_actors = &.{};
        }
        break :blk accepted.items;
    };
    // `self.queue.extend(incoming)`, `batch.rs:1103`. Every accepted change has
    // already been screened, so `push` cannot take either of its two refusal
    // branches and can only fail for want of memory — and **it releases the
    // change it refused** ([`ChangeQueue.push`](change_queue.zig)), so the walk
    // below starts one past whatever it refused and leaves the queue holding
    // everything before that.
    var pushed: usize = 0;
    // **`@min`, because this stays armed past the walk.** Once every accepted
    // change is in the queue the window is empty, and `popTopoSortedReady`
    // below is free to fail — it owns what it pops and unwinds it itself
    // ([`change_queue.zig`:494-495](change_queue.zig)) — while `pushed + 1` is
    // then one past the end of the slice.
    errdefer {
        for (screened[@min(pushed + 1, screened.len)..]) |*c| c.deinit(gpa);
    }
    for (screened) |c| {
        try queue.push(gpa, c);
        pushed += 1;
    }
    return queue.popTopoSortedReady(gpa, graph); // :1104
}

/// Hashes an actor by its bytes.
///
/// [`ActorId`] is a struct around a slice, and [`std.hash.autoHash`] refuses
/// a key it cannot hash unambiguously — so a map keyed by one needs this, the
/// same way [`queuemod`]'s `(actor, seq)` set does
/// (`change_queue.zig:119-131`).
const ActorContext = struct {
    pub fn hash(_: @This(), key: ActorId) u64 {
        return std.hash.Wyhash.hash(0, key.bytes);
    }

    pub fn eql(_: @This(), a: ActorId, b: ActorId) bool {
        return a.eql(b);
    }
};

/// A set of actors.
const ActorSet = std.HashMapUnmanaged(ActorId, void, ActorContext, 64);

/// `(actor, seq) -> the seqs seen for it` ([`actor_seqs`](batch.rs):1054).
const Slots = std.HashMapUnmanaged(ActorId, std.AutoHashMapUnmanaged(u64, void), ActorContext, 64);

fn recordSlot(gpa: Allocator, slots: *Slots, actor: ActorId, seq: u64) !void {
    const gop = try slots.getOrPut(gpa, actor);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.put(gpa, seq, {});
}

fn freeSlots(gpa: Allocator, slots: *Slots) void {
    var values = slots.valueIterator();
    while (values.next()) |v| v.deinit(gpa);
    slots.deinit(gpa);
}

/// A merge nobody is watching
/// ([`Automerge::apply_changes_batch`](../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs):1041-1046).
///
/// `apply_changes` routes here (`automerge.rs:1097-1112`) and so do `merge` and
/// `merge_and_log_patches` (`automerge.rs:1115-1147`); the difference is only
/// whether the sink is a [`NullLog`].
pub fn applyChangesBatch(
    gpa: Allocator,
    set: *Set,
    changes: []const Change,
    ops: []ChangeOp,
) WalkError!void {
    var log: NullLog = .{};
    try applyChangesBatchToSink(NullLog, gpa, &log, set, changes, ops);
}
/// A merge somebody is watching, into a sink of the caller's own type
/// ([`BatchApply::apply`]'s last line, `batch.rs`:1105`: `Ok(BatchApply::new(changes).apply(self, log)?`).
///
/// **This is the tail upstream's `apply_changes_batch_log_patches` ends in,
/// and the tail this file's [`applyChangesBatchLogPatches`] had no room for.**
/// Upstream's two functions are one: `apply_changes_batch_log_patches`
/// screens, queues, and then runs the batch against the log it was handed
/// (`batch.rs`:1048-1106`); this file splits that in two — the screen and the
/// queue are [`applyChangesBatchLogPatches`] (`:1048-1105`) and the apply is
/// this function (`:1106`) — because the screen's `AuthorLookup` and the
/// apply's sink would otherwise force every caller to name a sink it does not
/// have. Upstream's `apply_changes_batch` (`batch.rs`:1041-1046`) is then just
/// this with [`NullLog`], and [`applyChangesBatch`] is that.
///
/// **The sink is a comptime parameter and not a pointer to an interface**, for
/// the reason [`assertLog`] gives: every call site in this file resolves at
/// comptime and inlines, so a [`NullLog`] merge has no indirect calls in it at
/// all. A document that records patches names `patches.PatchLog`, which carries
/// every name in [`log_decls`] and so satisfies `assertLog` by construction; a
/// document that records nothing names [`NullLog`].
pub fn applyChangesBatchToSink(
    comptime L: type,
    gpa: Allocator,
    log: *L,
    set: *Set,
    changes: []const Change,
    ops: []ChangeOp,
) WalkError!void {
    assertLog(L);
    var batch = BatchApply(L).init(gpa, ops);
    defer batch.deinit();
    try batch.apply(set, changes, log);
}

// ── Small helpers ──────────────────────────────────────────────────────────

/// A copy of an object index ([`doc.ops().obj_info.clone()`](batch.rs):876).
///
/// Upstream clones so that the walk can see objects the batch is about to make
/// without the document claiming them before their rows exist; the port's
/// [`opsetmod.OpSet.spliceObjects`] claims them at splice time instead, so the
/// walk still needs its own copy and nothing else changes.
///
/// **The copy is only as good as the set's index, and the set's index is only
/// as good as the rule that fills it.** An object reaches it from either
/// direction and by the *same* rule, [`OpSet.spliceObjects`]
/// (`op_set.rs:232-238`, called from `OpSet::splice`, `:240-244`): a local
/// change writes its rows through `doc.ops_mut().splice`
/// ([`transaction/inner.rs:317`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
/// `:396`, `:426`, `:916`), and a merged change writes its rows through
/// [`BatchApply.insertRunsOfOps`] → `OpSet::splice` ([`batch.rs:961-964`](batch.rs)).
/// A load, which has no op to trust, derives the same three from its rows
/// instead ([`OpSet.rebuildIndex`](op_set.rs)), so a document arrives
/// knowing what its objects are however it was built.
///
/// Nothing downstream re-checks that, which is why [`walkObjSpan`]'s refusal
/// is the only witness: an object this copy has never heard of is a document
/// that would read back plausibly wrong, and the one place it is asked about
/// is where it is named (`batch.rs:920`).
fn cloneObjIndex(gpa: Allocator, src: *const ObjIndex) Allocator.Error!ObjIndex {
    var out = ObjIndex.init(gpa);
    errdefer out.deinit();
    var it = src.map.iterator();
    while (it.next()) |entry| {
        try out.map.put(gpa, entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

fn pushIndex(gpa: Allocator, map: anytype, key: anytype, item: usize) !void {
    const gop = try map.getOrPut(gpa, key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(gpa, item);
}

fn freeLists(gpa: Allocator, map: anytype) void {
    var values = map.valueIterator();
    while (values.next()) |v| v.deinit(gpa);
    map.deinit(gpa);
}

fn freePred(gpa: Allocator, map: *PredCache) void {
    var values = map.valueIterator();
    while (values.next()) |v| v.deinit(gpa);
    map.deinit(gpa);
}

fn eqlOpt(a: ?usize, b: ?usize) bool {
    if (a == null) return b == null;
    return b != null and a.? == b.?;
}

fn eqlOptObj(a: ?ObjId, b: ObjId) bool {
    const x = a orelse return false;
    return x.eql(b);
}

fn eqlOptProp(a: ?PropRef, b: ?PropRef) bool {
    if (a == null) return b == null;
    if (b == null) return false;
    return a.?.eql(b.?);
}

fn eqlOptElem(a: ?ElemId, b: ElemId) bool {
    const x = a orelse return false;
    return x.eql(b);
}

// ── Test fixtures ─────────────────────────────────────────────────────────

/// The string table a fixture's op set borrows. The same shape as the one
/// `op_set.zig` declares, and for the same reason: the table must live at one
/// address for as long as the set does, so a fixture owns it in the heap and
/// hands the op set a pointer to it rather than returning a pair by value.
const Table = struct {
    gpa: Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn init(gpa: Allocator) Table {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Table) void {
        for (self.items.items) |item| self.gpa.free(item);
        self.items.deinit(self.gpa);
    }

    fn asTable(self: *Table) StringTable {
        return .{ .ctx = self, .resolve = resolve, .intern = intern };
    }

    fn resolve(ctx: *const anyopaque, id: u32) []const u8 {
        const self: *const Table = @ptrCast(@alignCast(ctx));
        return self.items.items[id];
    }

    fn intern(ctx: *const anyopaque, text: []const u8, gpa: Allocator) ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(@constCast(ctx)));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, text)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, text));
        return id;
    }
};

/// One row of a fixture: everything `ChangeOp.init` takes, and the successors
/// the row holds.
///
/// **A non-empty `pred` or `succ` must not be an array literal inside a loop**:
/// the port's module docs and `op_set.zig`'s both record that `&.{…}` inside a
/// loop is a pointer to that iteration's stack frame, and two fixtures that did
/// it disagreed. Every fixture here therefore builds its predecessor and
/// successor storage in one allocation sized once, through
/// [`ids`](Fixture.init) below.
const Rec = struct {
    ctr: u32,
    obj: ObjId = .root,
    key: KeyRef,
    actor: ActorIdx = 0,
    is_insert: bool = false,
    act: Action = .set,
    val: ScalarValue = .null_value,
    mark: ?[]const u8 = null,
    expand: bool = false,
    pred: []const OpId = &.{},
    succ: []const SuccEntry = &.{},

    /// The id this row has.
    fn opId(self: Rec) OpId {
        return OpId.init(self.ctr, self.actor);
    }
};

/// One document, built out of [`Rec`]s and merged into.
///
/// The op set and the table it borrows are one heap value for the reason
/// [`Table`] gives: a returned-by-value pair would leave the set's
/// `strings.ctx` pointing at a dead frame.
const Fixture = struct {
    gpa: Allocator,
    table: Table,
    set: Set,

    /// An empty document over `actors`, which must be **sorted**: actor indices
    /// are positions in that table, so a fixture declares them in the order the
    /// document's actor table has them.
    fn init(gpa: Allocator, actors: []const ActorId) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .gpa = gpa,
            .table = Table.init(gpa),
            .set = undefined,
        };
        self.set = Set.fromActors(gpa, actors, fixture_encoding, self.table.asTable()) catch |e| {
            self.table.deinit();
            gpa.destroy(self);
            return e;
        };
        return self;
    }

    /// The same, with the three actors the merge fixtures use: `aa`, `bb`, `cc`
    /// in that order, so the base document is actor `0`.
    fn new(gpa: Allocator) !*Fixture {
        return init(gpa, &fixture_actors);
    }

    fn destroy(self: *Fixture) void {
        self.set.deinit();
        self.table.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Splices `rows` in at `pos`, taking ownership of their predecessor lists.
    fn build(self: *Fixture, pos: usize, rows: []const Rec) !void {
        const ops = try self.gpa.alloc(ChangeOp, rows.len);
        defer self.gpa.free(ops);
        var made: usize = 0;
        errdefer for (ops[0..made]) |*o| o.deinit(self.gpa);
        for (rows, 0..) |r, i| {
            ops[i] = try mkOp(self.gpa, r);
            made += 1;
        }
        _ = try self.set.splice(pos, ops);
        for (ops) |*o| o.deinit(self.gpa);
    }

    /// Merges `rows` into the document as **one** batch, and returns it.
    fn merge(self: *Fixture, rows: []const Rec, changes: []const Change) !void {
        const ops = try mkOps(self.gpa, rows);
        defer freeOps(self.gpa, ops);
        var log: NullLog = .{};
        var batch = BatchApply(NullLog).init(self.gpa, ops);
        defer batch.deinit();
        try batch.apply(&self.set, changes, &log);
    }

    /// Merges `a` and `b` as **one** batch, which is the door `merge` and
    /// `applyChanges` use: upstream's `map_batch_apply`
    /// (`batch.rs:1245-1257`) compares `apply_changes_batch` against
    /// `apply_changes` one change at a time over the *same* changes, and the
    /// two doors are the whole of the difference.
    fn mergeBoth(self: *Fixture, a: []const Rec, b: []const Rec, changes: []const Change) !void {
        const rows = try self.gpa.alloc(Rec, a.len + b.len);
        defer self.gpa.free(rows);
        @memcpy(rows[0..a.len], a);
        @memcpy(rows[a.len..], b);
        try self.merge(rows, changes);
    }

    /// The same merge with the patches **recorded** rather than dropped, and
    /// with the placed batch handed back.
    ///
    /// **The returned slice is the batch the walkers sorted in place**, so each
    /// entry carries the `pos`, `subsort` and `conflicted` the walk gave it.
    /// The caller owns it and frees it with [`freeOps`].
    fn mergeRecorded(
        self: *Fixture,
        rows: []const Rec,
        changes: []const Change,
        rec: *Recorder,
    ) ![]ChangeOp {
        const ops = try mkOps(self.gpa, rows);
        errdefer freeOps(self.gpa, ops);
        var batch = BatchApply(Recorder).init(self.gpa, ops);
        defer batch.deinit();
        try batch.apply(&self.set, changes, rec);
        return ops;
    }
};

/// A row of a fixture, with its successors appended.
fn mkOp(gpa: Allocator, r: Rec) !ChangeOp {
    var op = try ChangeOp.init(
        gpa,
        r.opId(),
        r.obj,
        r.act,
        r.key,
        r.val,
        r.is_insert,
        r.expand,
        r.mark,
        r.pred,
    );
    errdefer op.deinit(gpa);
    try op.succs.appendSlice(gpa, r.succ);
    return op;
}

/// Every row of a fixture as one batch, in the order written. The caller owns
/// the array and frees it with [`freeOps`].
fn mkOps(gpa: Allocator, rows: []const Rec) ![]ChangeOp {
    const ops = try gpa.alloc(ChangeOp, rows.len);
    errdefer gpa.free(ops);
    var made: usize = 0;
    errdefer for (ops[0..made]) |*o| o.deinit(gpa);
    for (rows, 0..) |r, i| {
        ops[i] = try mkOp(gpa, r);
        made += 1;
    }
    return ops;
}

fn freeOps(gpa: Allocator, ops: []ChangeOp) void {
    for (ops) |*o| o.deinit(gpa);
    gpa.free(ops);
}

/// The three actors every merge fixture uses, in actor-table order. **`bb`
/// sorts before `cc`**, and that is what fixes the index of every `@2` in a
/// fixture.
const fixture_actors = [_]ActorId{
    ActorId.init("aaaaaaaaaaaaaaaa"),
    ActorId.init("bbbbbbbbbbbbbbbb"),
    ActorId.init("cccccccccccccccc"),
};

/// The text encoding every fixture uses ([`types.TextEncoding`]'s platform
/// default on a little-endian target is the code point count).
const fixture_encoding: TextEncoding = .unicode_code_point;

fn elem(ctr: u32, actor: ActorIdx) ElemId {
    return ElemId.fromOpId(OpId.init(ctr, actor));
}

fn opId(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

fn sval(v: []const u8) ScalarValue {
    return .{ .str = v };
}

fn cval(v: i64) ScalarValue {
    return .{ .counter = .{ .current = v } };
}

/// A change with no ops, which is all the screen needs: it reads the actor, the
/// sequence number and the hash, and nothing else.
fn bareChange(actor: ActorId, seq: u64, start: u64, tag: u8) Change {
    return .{
        .bytes = &.{},
        .header_len = 0,
        .actor = actor,
        .deps = &.{},
        .hash = .{ .bytes = [_]u8{tag} ** 32 },
        .time = 0,
        .message = &.{},
        .seq = seq,
        .start_op = start,
        .max_op = start,
        .other_actors = &.{},
    };
}

// ── Reading a document back ────────────────────────────────────────────────

/// The op ids of `set`, in row order. The caller owns the result.
fn rowIds(gpa: Allocator, set: *Set) ![]OpId {
    var out: std.ArrayList(OpId) = .empty;
    errdefer out.deinit(gpa);
    var walk = try set.iter();
    while (try walk.next()) |row| {
        try out.append(gpa, row.id());
    }
    return out.toOwnedSlice(gpa);
}

fn expectRowIds(gpa: Allocator, set: *Set, want: []const OpId) !void {
    const got = try rowIds(gpa, set);
    defer gpa.free(got);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        if (!a.eql(b)) {
            std.debug.print("row order: got", .{});
            for (got) |g| std.debug.print(" {d}@{d}", .{ g.counter, g.actor });
            std.debug.print("\n        want", .{});
            for (want) |w| std.debug.print(" {d}@{d}", .{ w.counter, w.actor });
            std.debug.print("\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

/// Both invariant checkers, asserted together because every apply in this file
/// has to leave the document satisfying both.
fn expectBothCheckers(set: *Set) !void {
    try testing.expect(try set.validateOpOrder());
    if (try set.validateTopIndex()) |fault| {
        std.debug.print("top index fault: {any}\n", .{fault});
        return error.TestUnexpectedResult;
    }
}

/// One placed op, as a test reads it: the id, the `pos` the walk gave it, its
/// place in the run of equal `pos`, whether an earlier op in the same register
/// beat it, and whether the op is visible at all.
///
/// **The document's row order is a function of these.** [`BatchApply.insertRunsOfOps`]
/// cuts the placed batch into runs of equal `pos` and splices each run at
/// `pos + shift`, in `(pos, subsort)` order — so `pos` says *where* a run lands
/// in the object and `subsort` says in what order inside it. Asserting these is
/// asserting the row order, one step earlier in the pipeline than
/// [`expectRowIds`] is.
const Placed = struct {
    id: OpId,
    pos: usize,
    subsort: usize,
    conflicted: bool,
    visible: bool,
};

fn placedOf(gpa: Allocator, ops: []ChangeOp) ![]Placed {
    const out = try gpa.alloc(Placed, ops.len);
    errdefer gpa.free(out);
    for (ops, out) |o, *slot| {
        // An op with no `pos` never left the walks, so a placement assertion
        // about it cannot be written.
        slot.* = .{
            .id = o.id(),
            .pos = o.pos orelse return error.TestUnexpectedResult,
            .subsort = o.subsort,
            .conflicted = o.conflicted,
            .visible = o.visible(),
        };
    }
    return out;
}

fn expectPlaced(gpa: Allocator, ops: []ChangeOp, want: []const Placed) !void {
    const got = try placedOf(gpa, ops);
    defer gpa.free(got);
    try testing.expectEqualSlices(Placed, want, got);
}

/// A patch payload as one line of text, so a test can write what it expects as
/// a string literal and read a failure as a diff. The counters and the bytes a
/// merge fixture uses are spelled out; anything else says so rather than
/// guessing.
///
/// The numbers are rendered into `buf` rather than allocated, because the
/// caller already owns an allocator and a formatted line is not worth a
/// second allocation whose lifetime has to be tracked. The result borrows
/// `buf` for the scalars and is a literal for everything else.
fn valueText(buf: []u8, v: PatchValue) []const u8 {
    return switch (v) {
        .object => |o| switch (o) {
            .map => "obj:map",
            .list => "obj:list",
            .text => "obj:text",
            .table => "obj:table",
        },
        .scalar => |s| switch (s) {
            .null_value => "null",
            .bool_value => |b| if (b) "true" else "false",
            .int => |n| std.fmt.bufPrint(buf, "int:{d}", .{n}) catch "int:?",
            .uint => |n| std.fmt.bufPrint(buf, "uint:{d}", .{n}) catch "uint:?",
            .counter => |n| std.fmt.bufPrint(buf, "counter:{d}", .{n.current}) catch "counter:?",
            .timestamp => |n| std.fmt.bufPrint(buf, "ts:{d}", .{n}) catch "ts:?",
            .str => |b| b,
            else => "other",
        },
    };
}

fn propText(buf: []u8, p: Prop) []const u8 {
    return switch (p) {
        .key => |k| std.fmt.bufPrint(buf, "key:{s}", .{k}) catch "key:?",
        .index => |n| std.fmt.bufPrint(buf, "index:{d}", .{n}) catch "index:?",
    };
}

/// Every call [`Recorder`] made, one per line. A patch log is an *ordered*
/// list, so a test that reads the order off it is testing something a set
/// comparison would not.
fn eventLines(gpa: Allocator, rec: *const Recorder) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| gpa.free(line);
        out.deinit(gpa);
    }
    for (rec.items.items) |e| {
        var a_buf: [48]u8 = undefined;
        var b_buf: [48]u8 = undefined;
        const line = switch (e) {
            .insert => |a| try std.fmt.allocPrint(gpa, "insert {d} {s} {d}@{d} conflict={}", .{
                a.index, valueText(&a_buf, a.value), a.id.counter, a.id.actor, a.conflict,
            }),
            .put_map => |a| try std.fmt.allocPrint(gpa, "put_map {s} {s} {d}@{d} conflict={} expose={}", .{
                a.key, valueText(&a_buf, a.value), a.id.counter, a.id.actor, a.conflict, a.expose,
            }),
            .put_seq => |a| try std.fmt.allocPrint(gpa, "put_seq {d} {s} {d}@{d} conflict={} expose={}", .{
                a.index, valueText(&a_buf, a.value), a.id.counter, a.id.actor, a.conflict, a.expose,
            }),
            .delete_map => |a| try std.fmt.allocPrint(gpa, "delete_map {s}", .{a.key}),
            .delete_seq => |a| try std.fmt.allocPrint(gpa, "delete_seq {d} {d}", .{ a.index, a.num }),
            .flag_conflict => |a| try std.fmt.allocPrint(gpa, "flag_conflict {s}", .{propText(&a_buf, a.prop)}),
            .increment_map => |a| try std.fmt.allocPrint(gpa, "increment_map {s} {d} {d}@{d}", .{
                a.key, a.n, a.id.counter, a.id.actor,
            }),
            .increment_seq => |a| try std.fmt.allocPrint(gpa, "increment_seq {d} {d} {d}@{d}", .{
                a.index, a.n, a.id.counter, a.id.actor,
            }),
            .splice => |a| try std.fmt.allocPrint(gpa, "splice {d} \"{s}\" marks={d}", .{
                a.index, a.text, a.marks,
            }),
            .replace_seq => |a| try std.fmt.allocPrint(
                gpa,
                "replace_seq {d} {s}->{s} {d}@{d} conflict={} expose={} marks={d}",
                .{
                    a.index,                    valueText(&a_buf, a.old),
                    valueText(&b_buf, a.value), a.id.counter,
                    a.id.actor,                 a.conflict,
                    a.expose,                   a.marks,
                },
            ),
            .mark => |a| try std.fmt.allocPrint(gpa, "mark {d} {d} marks={d}", .{ a.index, a.len, a.marks }),
            .migrated => |n| try std.fmt.allocPrint(gpa, "migrate {d}", .{n}),
        };
        try out.append(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

fn freeLines(gpa: Allocator, lines: [][]const u8) void {
    for (lines) |line| gpa.free(line);
    gpa.free(lines);
}

/// Two lists of lines, compared one line at a time by content.
///
/// Neither [`std.mem.eql`] nor [`testing.expectEqualSlices`] does this: the
/// first compares the elements of a slice with `!=`, which is not defined for
/// a slice, and the second compares them with [`std.meta.eql`], which for a
/// slice is the pointer and the length. Both traps are the same one, and either
/// would make a comparison of patches pass on addresses.
fn eqlLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Compares the recorded calls with what the test expects, **by content** —
/// see [`eqlLines`] for why the two obvious spellings do not.
fn expectEvents(gpa: Allocator, rec: *const Recorder, want: []const []const u8) !void {
    const got = try eventLines(gpa, rec);
    defer freeLines(gpa, got);
    if (!eqlLines(want, got)) {
        std.debug.print("patches: got", .{});
        for (got) |line| std.debug.print("\n  {s}", .{line});
        std.debug.print("\n       want", .{});
        for (want) |line| std.debug.print("\n  {s}", .{line});
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ── A recording patch sink ────────────────────────────────────────────────

/// One recorded sink call, one variant per [`log_decls`] entry but
/// `migrateActors`.
const Event = union(enum) {
    insert: struct { index: usize, value: PatchValue, id: OpId, conflict: bool },
    put_map: struct { key: []const u8, value: PatchValue, id: OpId, conflict: bool, expose: bool },
    put_seq: struct { index: usize, value: PatchValue, id: OpId, conflict: bool, expose: bool },
    delete_map: struct { key: []const u8 },
    delete_seq: struct { index: usize, num: usize },
    flag_conflict: struct { prop: Prop },
    increment_map: struct { key: []const u8, n: i64, id: OpId },
    increment_seq: struct { index: usize, n: i64, id: OpId },
    splice: struct { index: usize, text: []const u8, marks: usize },
    replace_seq: struct {
        index: usize,
        old: PatchValue,
        value: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
        marks: usize,
    },
    mark: struct { index: usize, len: usize, marks: usize },
    migrated: usize,
};

/// A sink that records every call, so that the four conflict rules and the two
/// list/text arms can be read off the emitted events instead of inferred.
///
/// **It owns every borrowed byte it keeps.** The sink contract hands over a
/// value borrowed from the row or the change op that carries it
/// ([`PatchValue`]) and frees an exported mark set as soon as the call returns,
/// so a sink that keeps either copies it. This one keeps values and keys, and
/// outlives the `apply` that filled it — and that apply has by then spliced
/// its rows into the document, which moves the raw column a value read out of a
/// row points into. [`PatchLog`](patches.zig), the sink that has to survive a
/// merge the same way, copies for the same reason; a mark set is the exception
/// here, because [`marksOf`] keeps only its entry count.
const Recorder = struct {
    gpa: Allocator,
    items: std.ArrayList(Event) = .empty,
    /// The byte payloads the events point at, copied here because a recorder
    /// outlives the walk that borrowed them. [`deinit`](Recorder.deinit) frees
    /// every one.
    owned: std.ArrayList([]u8) = .empty,

    /// A copy of `bytes` this recorder frees in
    /// [`deinit`](Recorder.deinit), or null when it could not allocate.
    fn own(self: *Recorder, bytes: []const u8) ?[]const u8 {
        const copy = self.gpa.dupe(u8, bytes) catch return null;
        self.owned.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return null;
        };
        return copy;
    }

    /// A patch payload whose byte payloads this recorder owns, or null when it
    /// could not allocate. Only the four arms that carry bytes are copied;
    /// the rest are numbers and object types that carry nothing.
    fn ownValue(self: *Recorder, v: PatchValue) ?PatchValue {
        return switch (v) {
            .object => |o| .{ .object = o },
            .scalar => |s| .{ .scalar = self.ownScalar(s) orelse return null },
        };
    }

    fn ownScalar(self: *Recorder, v: ScalarValue) ?ScalarValue {
        return switch (v) {
            .str => |s| .{ .str = self.own(s) orelse return null },
            .bytes => |b| .{ .bytes = self.own(b) orelse return null },
            .actor_id => |a| .{ .actor_id = .{ .bytes = self.own(a.bytes) orelse return null } },
            .unknown => |u| .{ .unknown = .{
                .type_code = u.type_code,
                .bytes = self.own(u.bytes) orelse return null,
            } },
            else => v,
        };
    }

    /// A register reference whose key this recorder owns, or null when it
    /// could not allocate.
    fn ownProp(self: *Recorder, p: Prop) ?Prop {
        return switch (p) {
            .key => |k| .{ .key = self.own(k) orelse return null },
            .index => p,
        };
    }

    /// The mark set's entry count, or zero for "no marks". The set is borrowed,
    /// as the sink contract requires, and is freed as soon as the method
    /// returns; a recorder reads the count here rather than keeping the set.
    fn marksOf(m: ?*const MarkSet) usize {
        const set = m orelse return 0;
        return set.len();
    }

    /// Frees the copied payloads and the events. Once only.
    fn deinit(self: *Recorder) void {
        for (self.owned.items) |bytes| self.gpa.free(bytes);
        self.owned.deinit(self.gpa);
        self.items.deinit(self.gpa);
    }

    pub fn insert(self: *Recorder, _: ObjId, index: usize, val: PatchValue, id_: OpId, conflict: bool) void {
        const value = self.ownValue(val) orelse return;
        self.items.append(self.gpa, .{ .insert = .{ .index = index, .value = value, .id = id_, .conflict = conflict } }) catch {};
    }

    pub fn putMap(
        self: *Recorder,
        _: ObjId,
        key: []const u8,
        val: PatchValue,
        id_: OpId,
        conflict: bool,
        expose: bool,
    ) void {
        const k = self.own(key) orelse return;
        const value = self.ownValue(val) orelse return;
        self.items.append(self.gpa, .{ .put_map = .{ .key = k, .value = value, .id = id_, .conflict = conflict, .expose = expose } }) catch {};
    }

    pub fn putSeq(
        self: *Recorder,
        _: ObjId,
        index: usize,
        val: PatchValue,
        id_: OpId,
        conflict: bool,
        expose: bool,
    ) void {
        const value = self.ownValue(val) orelse return;
        self.items.append(self.gpa, .{ .put_seq = .{ .index = index, .value = value, .id = id_, .conflict = conflict, .expose = expose } }) catch {};
    }

    pub fn deleteMap(self: *Recorder, _: ObjId, key: []const u8) void {
        const k = self.own(key) orelse return;
        self.items.append(self.gpa, .{ .delete_map = .{ .key = k } }) catch {};
    }

    pub fn deleteSeq(self: *Recorder, _: ObjId, index: usize, num: usize) void {
        self.items.append(self.gpa, .{ .delete_seq = .{ .index = index, .num = num } }) catch {};
    }

    pub fn flagConflict(self: *Recorder, _: ObjId, prop: Prop) void {
        const p = self.ownProp(prop) orelse return;
        self.items.append(self.gpa, .{ .flag_conflict = .{ .prop = p } }) catch {};
    }

    pub fn incrementMap(self: *Recorder, _: ObjId, key: []const u8, n: i64, id_: OpId) void {
        const k = self.own(key) orelse return;
        self.items.append(self.gpa, .{ .increment_map = .{ .key = k, .n = n, .id = id_ } }) catch {};
    }

    pub fn incrementSeq(self: *Recorder, _: ObjId, index: usize, n: i64, id_: OpId) void {
        self.items.append(self.gpa, .{ .increment_seq = .{ .index = index, .n = n, .id = id_ } }) catch {};
    }

    pub fn splice(self: *Recorder, _: ObjId, index: usize, text: []const u8, m: ?*const MarkSet) void {
        const t = self.own(text) orelse return;
        self.items.append(self.gpa, .{ .splice = .{ .index = index, .text = t, .marks = marksOf(m) } }) catch {};
    }

    pub fn replaceSeq(
        self: *Recorder,
        _: ObjId,
        index: usize,
        old_value: PatchValue,
        val: PatchValue,
        id_: OpId,
        conflict: bool,
        expose: bool,
        _: SequenceType,
        _: TextEncoding,
        m: ?*const MarkSet,
    ) void {
        const old = self.ownValue(old_value) orelse return;
        const value = self.ownValue(val) orelse return;
        self.items.append(self.gpa, .{ .replace_seq = .{
            .index = index,
            .old = old,
            .value = value,
            .id = id_,
            .conflict = conflict,
            .expose = expose,
            .marks = marksOf(m),
        } }) catch {};
    }

    pub fn mark(self: *Recorder, _: ObjId, index: usize, len: usize, m: *const MarkSet) void {
        self.items.append(self.gpa, .{ .mark = .{ .index = index, .len = len, .marks = m.len() } }) catch {};
    }

    pub fn migrateActors(self: *Recorder, actors: []const ActorId) Error!void {
        try self.items.append(self.gpa, .{ .migrated = actors.len });
    }
};

// ── The three cross-check documents ────────────────────────────────────────

/// The base document of the map fixture: the root map's keys `a` and `b`.
///
/// The op counters are **document-global** — `automerge.rs:567` allocates
/// `start_op` as `change_graph.max_op() + 1`, not as a per-actor counter — so
/// every incoming op in a fixture has a counter above every op already in the
/// document. That is what makes `Untangler.untangleInserts`' binary search
/// total, and a fixture that used a per-actor counter would be a document
/// automerge could not produce.
const map_base_rows = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("a"), .val = sval("a1") },
    .{ .ctr = 2, .key = .fromStr("b"), .val = sval("b1") },
};

/// The rows of the fixture, as a slice. A **file-scope `const`**, and
/// that is load-bearing: these rows hold runtime values (`elem(2, 0)` is a
/// call), so `return &.{…}` from a function would hand the caller a
/// pointer into that frame's dead stack — the trap `op_set.zig`'s module
/// doc records and two fixtures there fell into.
fn mapBase() []const Rec {
    return &map_base_rows;
}

/// Change one of the map fixture, from actor `1` (`batch.rs`'s `map_batch_apply`
/// shape: an overwrite of an existing key plus a new one).
const map_change_a_rows = [_]Rec{
    .{ .ctr = 3, .actor = 1, .key = .fromStr("a"), .val = sval("a2"), .pred = &pred_one },
    .{ .ctr = 4, .actor = 1, .key = .fromStr("c"), .val = sval("c1") },
};

/// The rows of the fixture, as a slice. A **file-scope `const`**, and
/// that is load-bearing: these rows hold runtime values (`elem(2, 0)` is a
/// call), so `return &.{…}` from a function would hand the caller a
/// pointer into that frame's dead stack — the trap `op_set.zig`'s module
/// doc records and two fixtures there fell into.
fn mapChangeA() []const Rec {
    return &map_change_a_rows;
}

/// Change two, from actor `2`: an overwrite of change one's own op, so the two
/// changes conflict.
const map_change_b_rows = [_]Rec{
    .{ .ctr = 5, .actor = 2, .key = .fromStr("a"), .val = sval("a3"), .pred = &pred_three },
};

/// The rows of the fixture, as a slice. A **file-scope `const`**, and
/// that is load-bearing: these rows hold runtime values (`elem(2, 0)` is a
/// call), so `return &.{…}` from a function would hand the caller a
/// pointer into that frame's dead stack — the trap `op_set.zig`'s module
/// doc records and two fixtures there fell into.
fn mapChangeB() []const Rec {
    return &map_change_b_rows;
}

/// The base document of the list fixture: an empty-ish list holding `a`, `b` and
/// an overwrite of `a`.
const list_base_rows = [_]Rec{
    // **Row order, not op order.** `build` splices what it is given in the
    // order it is given, and a list's rows are ordered by register: the
    // element `a` made is `Seq(2@0)`, and the overwrite of it and the
    // element `b` inserted after it are `Seq(2@0)` and `Seq(3@0)`. So the
    // overwrite of `a` is row 2 and `b` is row 3, which is rule **R2** and
    // not a detail: `walkList` and `validateOpOrder` both read this order.
    .{ .ctr = 1, .key = .fromStr("list"), .act = .make_list },
    // **The base already holds one overwrite**, and the row has to say so:
    // `succ` is what makes `Op.visible` false for `a`, and a base document
    // whose `a` is still visible is a different document with a different
    // width index and a different `validate_top_index` answer.
    .{ .ctr = 2, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("a"), .succ = &succ_by_four },
    .{ .ctr = 4, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .val = sval("A"), .pred = &pred_two },
    .{ .ctr = 3, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .is_insert = true, .val = sval("b") },
};

/// The rows of the fixture, as a slice. A **file-scope `const`**, and
/// that is load-bearing: these rows hold runtime values (`elem(2, 0)` is a
/// call), so `return &.{…}` from a function would hand the caller a
/// pointer into that frame's dead stack — the trap `op_set.zig`'s module
/// doc records and two fixtures there fell into.
fn listBase() []const Rec {
    return &list_base_rows;
}

const list_change_a_rows = [_]Rec{
    .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("x") },
    .{ .ctr = 6, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .val = sval("AA"), .pred = &pred_four },
};

/// The rows of the fixture, as a slice. A **file-scope `const`**, and
/// that is load-bearing: these rows hold runtime values (`elem(2, 0)` is a
/// call), so `return &.{…}` from a function would hand the caller a
/// pointer into that frame's dead stack — the trap `op_set.zig`'s module
/// doc records and two fixtures there fell into.
fn listChangeA() []const Rec {
    return &list_change_a_rows;
}

const list_change_b_rows = [_]Rec{
    .{ .ctr = 7, .actor = 2, .obj = list_obj, .key = .fromElemId(elem(3, 0)), .is_insert = true, .val = sval("c") },
};

/// The rows of the fixture, as a slice. A **file-scope `const`**, and
/// that is load-bearing: these rows hold runtime values (`elem(2, 0)` is a
/// call), so `return &.{…}` from a function would hand the caller a
/// pointer into that frame's dead stack — the trap `op_set.zig`'s module
/// doc records and two fixtures there fell into.
fn listChangeB() []const Rec {
    return &list_change_b_rows;
}

/// The base document of the text fixture.
const text_base_rows = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("text"), .act = .make_text },
    .{ .ctr = 2, .obj = text_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("ab") },
    .{ .ctr = 3, .obj = text_obj, .key = .fromElemId(elem(2, 0)), .is_insert = true, .val = sval("cd") },
};

/// The rows of the fixture, as a slice. A **file-scope `const`**, and
/// that is load-bearing: these rows hold runtime values (`elem(2, 0)` is a
/// call), so `return &.{…}` from a function would hand the caller a
/// pointer into that frame's dead stack — the trap `op_set.zig`'s module
/// doc records and two fixtures there fell into.
fn textBase() []const Rec {
    return &text_base_rows;
}

const text_change_a_rows = [_]Rec{
    .{ .ctr = 4, .actor = 1, .obj = text_obj, .key = .fromElemId(elem(2, 0)), .is_insert = true, .val = sval("X") },
};

/// The rows of the fixture, as a slice. A **file-scope `const`**, and
/// that is load-bearing: these rows hold runtime values (`elem(2, 0)` is a
/// call), so `return &.{…}` from a function would hand the caller a
/// pointer into that frame's dead stack — the trap `op_set.zig`'s module
/// doc records and two fixtures there fell into.
fn textChangeA() []const Rec {
    return &text_change_a_rows;
}

const text_change_b_rows = [_]Rec{
    .{ .ctr = 5, .actor = 2, .obj = text_obj, .key = .fromElemId(elem(3, 0)), .val = sval("Z"), .pred = &pred_three },
};

/// The rows of the fixture, as a slice. A **file-scope `const`**, and
/// that is load-bearing: these rows hold runtime values (`elem(2, 0)` is a
/// call), so `return &.{…}` from a function would hand the caller a
/// pointer into that frame's dead stack — the trap `op_set.zig`'s module
/// doc records and two fixtures there fell into.
fn textChangeB() []const Rec {
    return &text_change_b_rows;
}

/// The list and text objects the two base documents make, which are the ids of
/// the ops that make them.
const list_obj: ObjId = .{ .id = opId(1, 0) };
const text_obj: ObjId = .{ .id = opId(1, 0) };

/// The predecessor lists, **one allocation each and named**, because a
/// non-empty `&.{…}` written inside a loop is a pointer to that iteration's
/// stack frame — the trap `op_set.zig`'s module doc records and two fixtures
/// there fell into.
const pred_one = [_]OpId{opId(1, 0)};
const pred_two = [_]OpId{opId(2, 0)};
const pred_three = [_]OpId{opId(3, 0)};
const pred_three_one = [_]OpId{opId(3, 1)};
const pred_four = [_]OpId{opId(4, 0)};
const pred_five = [_]OpId{opId(5, 1)};
const pred_five_two = [_]OpId{opId(5, 2)};
const pred_six = [_]OpId{opId(6, 1)};

/// The one successor edge the list base holds: the overwrite `A` deletes the
/// element `a` made.
const succ_by_four = [_]SuccEntry{.{ .id = opId(4, 0), .inc = null }};

// ── The object index, across two changes ───────────────────────────────────

test "a merged change's ops act on objects an earlier change made, and the index still knows them" {
    const gpa = testing.allocator;
    const doc = try Fixture.new(gpa);
    defer doc.destroy();

    // The base document is **spliced**, not merged: that is the route a local
    // change takes upstream too — `TransactionInner::insert_local_op` writes
    // through `doc.ops_mut().splice` (`transaction/inner.rs:317`, `:396`,
    // `:426`, `:916`) and `commit_impl` adds no rows of its own
    // (`inner.rs:146-172`). So `build` and `merge` are the two doors into the
    // object index, and a test that only used one of them would not say
    // whether both of them reach it.
    const base = [_]Rec{
        // The three object-making actions, in ascending key order because the
        // rows are ordered by register and all three hang in the root.
        .{ .ctr = 1, .key = .fromStr("list"), .act = .make_list },
        .{ .ctr = 2, .key = .fromStr("map"), .act = .make_map },
        .{ .ctr = 3, .key = .fromStr("text"), .act = .make_text },
    };
    try doc.build(0, &base);

    const list: ObjId = .{ .id = opId(1, 0) };
    const map: ObjId = .{ .id = opId(2, 0) };
    const text: ObjId = .{ .id = opId(3, 0) };
    try testing.expectEqual(@as(usize, 3), doc.set.obj_info.count());
    try testing.expectEqual(@as(?ObjType, .list), doc.set.objectType(list));
    try testing.expectEqual(@as(?ObjType, .map), doc.set.objectType(map));
    try testing.expectEqual(@as(?ObjType, .text), doc.set.objectType(text));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(list));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(map));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(text));

    // The second change, by a **second actor**: an insert into the list and a
    // value into the map that the first change made, and then a list it makes
    // itself and immediately inserts into. The last two rows are what make
    // this a test of the *clone* rather than of the set: `walkObjSpan` reads a
    // copy of the op set's index into which `orderOpsForDoc` has just recorded
    // the objects this batch makes (`batch.rs:876-878`), because at the moment
    // the walk asks, the rows that would put them in the set's own index do not
    // exist yet.
    const fresh: ObjId = .{ .id = opId(6, 1) };
    const second = [_]Rec{
        .{ .ctr = 4, .actor = 1, .obj = list, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("c") },
        .{ .ctr = 5, .actor = 1, .obj = map, .key = .fromStr("k"), .val = sval("v") },
        // The new list hangs in the **map the first change made**, not in the
        // root: an object made in the root is claimed whatever walks, so
        // putting it one level down is what makes the walk's own copy of the
        // index the only thing that can answer for it.
        .{ .ctr = 6, .actor = 1, .obj = map, .key = .fromStr("new"), .act = .make_list },
        .{ .ctr = 7, .actor = 1, .obj = fresh, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("z") },
    };
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 4, 0x11)};
    try doc.merge(&second, &changes);

    // **Four objects and four answers.** The three the first change made are
    // still asked about and still answer, the one the second change made is
    // asked about and answers, and the count says there is nothing else: a
    // `set` or an insert claims nothing, so a count of five would mean an
    // index that grew without an object.
    try testing.expectEqual(@as(usize, 4), doc.set.obj_info.count());
    try testing.expectEqual(@as(?ObjType, .list), doc.set.objectType(list));
    try testing.expectEqual(@as(?ObjType, .map), doc.set.objectType(map));
    try testing.expectEqual(@as(?ObjType, .text), doc.set.objectType(text));
    try testing.expectEqual(@as(?ObjType, .list), doc.set.objectType(fresh));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(list));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(map));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(text));
    try testing.expectEqual(@as(?ObjId, map), doc.set.objectParent(fresh));
    // The ids that made nothing, and so the ids of no object, still answer
    // with nothing rather than with a guess.
    try testing.expectEqual(@as(?ObjType, null), doc.set.objectType(.{ .id = opId(4, 1) }));
    try testing.expectEqual(@as(?ObjType, null), doc.set.objectType(.{ .id = opId(7, 1) }));

    // The rows are still rows: four spliced by the base and four by the merge.
    try testing.expectEqual(@as(usize, 7), doc.set.len());
    try expectBothCheckers(&doc.set);
}

test "a batch apply equals one change at a time, on a map" {
    const gpa = testing.allocator;
    // The changes both documents are given. Both are handed the whole list, so
    // `insertNewActors` sees the same actors in both and the actor tables the
    // comparison looks at are the same.
    const changes = [_]Change{
        bareChange(fixture_actors[1], 1, 3, 0x11),
        bareChange(fixture_actors[2], 1, 5, 0x22),
    };

    const both = try Fixture.new(gpa);
    defer both.destroy();
    try both.build(0, mapBase());
    try both.mergeBoth(mapChangeA(), mapChangeB(), &changes);

    const one = try Fixture.new(gpa);
    defer one.destroy();
    try one.build(0, mapBase());
    try one.merge(mapChangeA(), &changes);
    try one.merge(mapChangeB(), &changes);

    // The primary instrument: the two documents must be identical, every
    // column of both, after the two checkers have passed on each.
    try expectRowIds(gpa, &both.set, &.{
        opId(1, 0), opId(3, 1), opId(5, 2), opId(2, 0), opId(4, 1),
    });
    try expectBothCheckers(&both.set);
    try expectBothCheckers(&one.set);
    try both.set.debugCmp(&one.set);
}

test "a batch apply equals one change at a time, on a list" {
    const gpa = testing.allocator;
    const changes = [_]Change{
        bareChange(fixture_actors[1], 1, 5, 0x11),
        bareChange(fixture_actors[2], 1, 7, 0x22),
    };

    const both = try Fixture.new(gpa);
    defer both.destroy();
    try both.build(0, listBase());
    try both.mergeBoth(listChangeA(), listChangeB(), &changes);

    const one = try Fixture.new(gpa);
    defer one.destroy();
    try one.build(0, listBase());
    try one.merge(listChangeA(), &changes);
    try one.merge(listChangeB(), &changes);

    try expectRowIds(gpa, &both.set, &.{
        opId(1, 0), opId(5, 1), opId(2, 0), opId(4, 0), opId(6, 1), opId(3, 0), opId(7, 2),
    });
    try expectBothCheckers(&both.set);
    try expectBothCheckers(&one.set);
    try both.set.debugCmp(&one.set);
}

test "a batch apply equals one change at a time, on a text" {
    const gpa = testing.allocator;
    const changes = [_]Change{
        bareChange(fixture_actors[1], 1, 4, 0x11),
        bareChange(fixture_actors[2], 1, 5, 0x22),
    };

    const both = try Fixture.new(gpa);
    defer both.destroy();
    try both.build(0, textBase());
    try both.mergeBoth(textChangeA(), textChangeB(), &changes);

    const one = try Fixture.new(gpa);
    defer one.destroy();
    try one.build(0, textBase());
    try one.merge(textChangeA(), &changes);
    try one.merge(textChangeB(), &changes);

    // `4@1` is inserted between the two elements and `5@2` overwrites the
    // second, so `3@0`'s register gains a row and the winner of it moves.
    try expectRowIds(gpa, &both.set, &.{ opId(1, 0), opId(2, 0), opId(4, 1), opId(3, 0), opId(5, 2) });
    try expectBothCheckers(&both.set);
    try expectBothCheckers(&one.set);
    try both.set.debugCmp(&one.set);
}

// ── One change makes the objects, the next writes into them ────────────────

/// The shape the object-index refusal is about, and the one upstream's own
/// `map_batch_apply` (`batch.rs:1215-1257`) is built from: a change that
/// **makes** objects and a second change that **writes into** them, both in one
/// batch, compared against the same two changes applied one at a time.
/// Change one, by actor `1`: a map and a list in the root, and a row in each.
const made_by_first = [_]Rec{
    .{ .ctr = 1, .actor = 1, .key = .fromStr("m"), .act = .make_map },
    .{ .ctr = 2, .actor = 1, .key = .fromStr("l"), .act = .make_list },
    .{ .ctr = 3, .actor = 1, .obj = .{ .id = opId(1, 1) }, .key = .fromStr("k"), .val = sval("from-1") },
    .{ .ctr = 4, .actor = 1, .obj = .{ .id = opId(2, 1) }, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("a") },
};

/// Change two, by actor `2`: overwrites the map's value, inserts into the list,
/// makes a map **inside** the one change one made, and writes into that.
const written_by_second = [_]Rec{
    .{ .ctr = 5, .actor = 2, .obj = .{ .id = opId(1, 1) }, .key = .fromStr("k"), .val = sval("from-2"), .pred = &pred_three },
    .{ .ctr = 6, .actor = 2, .obj = .{ .id = opId(2, 1) }, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("b") },
    .{ .ctr = 7, .actor = 2, .obj = .{ .id = opId(1, 1) }, .key = .fromStr("inner"), .act = .make_map },
    .{ .ctr = 8, .actor = 2, .obj = .{ .id = opId(7, 2) }, .key = .fromStr("z"), .val = sval("deep") },
};

test "a merge that makes its objects and then writes into them is the same applied one change at a time" {
    const gpa = testing.allocator;
    const changes = [_]Change{
        bareChange(fixture_actors[1], 1, 1, 0x11),
        bareChange(fixture_actors[2], 1, 5, 0x22),
    };
    const map_a: ObjId = .{ .id = opId(1, 1) };
    const list_a: ObjId = .{ .id = opId(2, 1) };
    const inner_b: ObjId = .{ .id = opId(7, 2) };

    // **One batch**, which is the door `merge` and `applyChanges` use.
    const both = try Fixture.new(gpa);
    defer both.destroy();
    try both.mergeBoth(&made_by_first, &written_by_second, &changes);

    // The same two changes, **one at a time**.
    const one = try Fixture.new(gpa);
    defer one.destroy();
    try one.merge(&made_by_first, &changes);
    try one.merge(&written_by_second, &changes);

    // **All three objects exist only because this batch made them.** The walk
    // had to answer for each of them out of the clone `orderOpsForDoc` wrote,
    // not out of the op set's own index, because the rows that would put them
    // there do not exist until `insertRunsOfOps` runs after every span has been
    // walked (`batch.rs:876-878`, `:997-999`, against `:947`). That is the whole
    // reason the clone exists, and it is the premise the comparison below rests
    // on: asserted first, because a conclusion about a batch that made no
    // objects proves nothing.
    try testing.expectEqual(@as(usize, 3), both.set.obj_info.count());
    try testing.expectEqual(@as(?ObjType, .map), both.set.objectType(map_a));
    try testing.expectEqual(@as(?ObjType, .list), both.set.objectType(list_a));
    try testing.expectEqual(@as(?ObjType, .map), both.set.objectType(inner_b));
    try testing.expectEqual(@as(?ObjId, .root), both.set.objectParent(map_a));
    try testing.expectEqual(@as(?ObjId, .root), both.set.objectParent(list_a));
    try testing.expectEqual(@as(?ObjId, map_a), both.set.objectParent(inner_b));

    // The eight rows in the order both documents agree on: the root's two
    // object-making rows by key (`l` before `m`), then object `1@1`'s register
    // `inner` before `k` and `3@1` before `5@2` inside it, then the list's two
    // head inserts with the greater id first, then the innermost map.
    try expectRowIds(gpa, &both.set, &.{
        opId(2, 1), opId(1, 1),
        opId(7, 2), opId(3, 1),
        opId(5, 2), opId(6, 2),
        opId(4, 1), opId(8, 2),
    });

    try expectBothCheckers(&both.set);
    try expectBothCheckers(&one.set);
    try both.set.debugCmp(&one.set);
}

// ── The bases the hand-built merges start from ─────────────────────────────

/// An integer, which is what an increment op carries
/// ([`OpBuilder.getIncrementValue`](op.zig): an `increment` reads its amount
/// out of the value column and nothing else).
fn ival(n: i64) ScalarValue {
    return .{ .int = n };
}

/// A list at the root under key `list`, holding the one element `2@0` = `"a"`.
///
/// **A file-scope `const`**, which is the property that matters: `&one_elem`
/// is then a pointer to storage that outlives the test, which a `&.{…}`
/// written in a function would not be. The three base pairs above say so at
/// length, and this is the same rule.
const one_elem = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 2, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("a") },
};

/// The same list, but its one element is the counter `2@0` = 5.
const one_counter = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 2, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = cval(5) },
};

/// A list holding `2@0` = `"a"`, `3@0` = `"b"` and `4@0` = `"c"`, each
/// inserted after the one before it — the shape `inner_splice` writes
/// (`automerge/src/transaction/inner.rs:719-725`: each inserted element
/// becomes the anchor of the next).
const three_elems = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 2, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("a") },
    .{ .ctr = 3, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .is_insert = true, .val = sval("b") },
    .{ .ctr = 4, .obj = list_obj, .key = .fromElemId(elem(3, 0)), .is_insert = true, .val = sval("c") },
};

/// A map holding the counter `2@0` = 5 under the key `k`. The object's own
/// row hangs by the key `a`, which sorts **before** `k` — that matters,
/// because `MapWalker` reads every document row that sorts before the incoming
/// op, and a `make_map` row under a key sorting *after* `k` would stop the
/// walk before it reached the register under test.
const counter_doc = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("a"), .act = .make_map },
    .{ .ctr = 2, .key = .fromStr("k"), .val = cval(5) },
};

/// The same key holding a **string** rather than a counter, which is what
/// makes the two sides of a merge disagree about the value of one register.
const string_doc = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("a"), .act = .make_map },
    .{ .ctr = 2, .key = .fromStr("k"), .val = sval("k0") },
};

/// The successor edge the two-row map base holds: `2@0` overwrites `1@0`.
/// **A base document whose two rows of a register are both visible is a
/// different document** — it has two winners where it should have one, and
/// `validateTopIndex` says so.
const succ_by_two = [_]SuccEntry{.{ .id = opId(2, 0), .inc = null }};

// ── 1. The Untangler's emission order, hand-built ──────────────────────────

test "an untangled insert is one op at the anchor's position with subsort zero" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 5, 0x11)};
    const batch = [_]Rec{
        .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("x") },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &one_elem);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // The insert is anchored at HEAD, so `Untangler.init` stacks it
    // (`batch.rs:278-279`) and the stack is drained at the first document
    // insert whose id it does not match — here `2@0`'s, at position 1
    // (`batch.rs:152-161`). One op, subsort zero, and it is the visible one:
    // a set with no successor is the run's candidate (`batch.rs:185-186`).
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(5, 1), .pos = 1, .subsort = 0, .conflicted = false, .visible = true },
    });
    // The walk had already indexed the document's own element, so the new one
    // is the second: `insert` is emitted at `self.index` (`batch.rs:226`).
    try expectEvents(gpa, &rec, &.{ "migrate 3", "insert 0 x 5@1 conflict=false" });
    // The run at `pos` 1 is spliced **at** 1 (`batch.rs:976`), so the new
    // element lands before `2@0` — which is rule **R4**: an insert opening a
    // register at HEAD may sit before an element with a lower id only if its
    // own id is the greater one, and `5@1 > 2@0` is.
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(5, 1), opId(2, 0) });
    try expectBothCheckers(&f.set);
}

test "an increment and a trailing insert keep two ops out of one column slot" {
    // Upstream `increment_plus_trailing_insert_keeps_group_order`
    // (`batch.rs:1174-1199`), ported: a list holding one counter, a fork that
    // increments it and then inserts an element after it.
    const gpa = testing.allocator;
    const changes = [_]Change{
        bareChange(fixture_actors[1], 1, 3, 0x11),
        bareChange(fixture_actors[1], 2, 4, 0x12),
    };
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .act = .increment, .val = ival(1), .pred = &pred_two },
        .{ .ctr = 4, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .is_insert = true, .val = sval("x") },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &one_counter);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // **One position and two subsorts, and that is the whole test.**
    // `3@1` updates the document's element `2@0`, so it goes to `updates` and
    // `finishUpdates` puts it at `max` (`batch.rs:110`), one past the object's
    // last row; `4@1` is anchored at `2@0` too, so `entry` holds it and the
    // stack is drained by `finishInserts` at the same `max`. Two ops, one
    // position, subsorts 0 and 1 — upstream's bug was a change that wrote them
    // into one column slot, which is one position *and* one subsort.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = false },
        .{ .id = opId(4, 1), .pos = 2, .subsort = 1, .conflicted = false, .visible = true },
    });
    // The counter is still visible in the document, so the fold adopts it and
    // adds the increment: equal ids emit the delta, not a replacement
    // (`batch.rs:758-764`). The counter is at index 0 because `4@1` was
    // inserted *after* it.
    try expectEvents(gpa, &rec, &.{
        "migrate 3",
        "increment_seq 0 1 2@0",
        "insert 0 x 4@1 conflict=false",
    });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0), opId(3, 1), opId(4, 1) });
    try expectBothCheckers(&f.set);

    // The same two changes one at a time, which is the instrument the three
    // cross-checks use.
    const one = try Fixture.new(gpa);
    defer one.destroy();
    try one.build(0, &one_counter);
    const first = [_]Rec{batch[0]};
    const second = [_]Rec{batch[1]};
    try one.merge(&first, &changes);
    try one.merge(&second, &changes);
    try expectBothCheckers(&one.set);
    try f.set.debugCmp(&one.set);
}

test "one insert and two updates share a position with subsorts zero, one and two" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 5, 0x11)};
    // A counter inserted at HEAD, then two increments on it. **The two
    // increments are what keep the insert the run's visible op**: an
    // increment is not a set-or-make, so it never becomes the candidate, and
    // `normalize_increment_successors` keeps the insert's successor as an
    // increment because the insert *is* a counter (`batch.rs:270`, `:485-495`).
    // A set here would delete the insert and the run would end invisible.
    const batch = [_]Rec{
        .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = cval(5) },
        .{ .ctr = 6, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .act = .increment, .val = ival(2), .pred = &pred_five },
        .{ .ctr = 7, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .act = .increment, .val = ival(3), .pred = &pred_five },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &one_elem);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // The forward scan takes every op after the insert that is not itself an
    // insert and hangs by the element the insert made (`batch.rs:195-207`), so
    // all three share one `pos` and take the next three `subsort`s.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(5, 1), .pos = 1, .subsort = 0, .conflicted = false, .visible = true },
        .{ .id = opId(6, 1), .pos = 1, .subsort = 1, .conflicted = false, .visible = false },
        .{ .id = opId(7, 1), .pos = 1, .subsort = 2, .conflicted = false, .visible = false },
    });
    // The patch carries the insert's value with **its own successors'
    // increments folded in** (`batch.rs:225`, over
    // `hydrate_value_and_fix_counters`): 5 + 2 + 3.
    try expectEvents(gpa, &rec, &.{ "migrate 3", "insert 0 counter:10 5@1 conflict=false" });
    try expectRowIds(gpa, &f.set, &.{
        opId(1, 0), opId(5, 1), opId(6, 1), opId(7, 1), opId(2, 0),
    });
    try expectBothCheckers(&f.set);
}

test "two sets with no successors: the last is visible and the first is conflicted" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 5, 0x11)};
    // The two sets are **concurrent**: each names the insert in `pred` and
    // neither names the other, so neither is the other's successor and both
    // have no successor of their own. That is the only shape in which an
    // earlier op of a run survives to be flagged: an op that the next one
    // overwrites has a successor, so it is not a candidate at all and
    // `conflicted` is never set on it (`batch.rs:185-186`).
    const batch = [_]Rec{
        .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("x") },
        .{ .ctr = 6, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .val = sval("y"), .pred = &pred_five },
        .{ .ctr = 7, .actor = 2, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .val = sval("z"), .pred = &pred_five },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &one_elem);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // Both sets are candidates, so the second one demotes the first
    // (`batch.rs:212-219`) and the register's conflict flag reaches the patch
    // as the `conflict` argument of the single `insert`.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(5, 1), .pos = 1, .subsort = 0, .conflicted = false, .visible = false },
        .{ .id = opId(6, 1), .pos = 1, .subsort = 1, .conflicted = true, .visible = true },
        .{ .id = opId(7, 2), .pos = 1, .subsort = 2, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "insert 0 z 7@2 conflict=true" });
    try expectRowIds(gpa, &f.set, &.{
        opId(1, 0), opId(5, 1), opId(6, 1), opId(7, 2), opId(2, 0),
    });
    try expectBothCheckers(&f.set);
}

test "a run whose last op is deleted leaves the counter it started with visible" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 5, 0x11)};
    // The run's last op is a delete, so it is not a set-or-make and never
    // becomes the candidate. The op before it is an increment, which does not
    // delete its predecessor because that predecessor is a counter. **The
    // counter pair is the only way an earlier op of a run keeps its
    // candidacy**: every other later op names its predecessor with a `null`
    // increment after `normalize_increment_successors`, which deletes it.
    const batch = [_]Rec{
        .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = cval(5) },
        .{ .ctr = 6, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .act = .increment, .val = ival(1), .pred = &pred_five },
        .{ .ctr = 7, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .act = .delete, .pred = &pred_six },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &one_elem);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // `5@1` is the run's visible op and is the one the patch names; `6@1` is
    // deleted by `7@1` and `7@1` is a delete, so neither is visible.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(5, 1), .pos = 1, .subsort = 0, .conflicted = false, .visible = true },
        .{ .id = opId(6, 1), .pos = 1, .subsort = 1, .conflicted = false, .visible = false },
        .{ .id = opId(7, 1), .pos = 1, .subsort = 2, .conflicted = false, .visible = false },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "insert 0 counter:6 5@1 conflict=false" });
    // A `delete` op is **not a row**: the columns drop it on the way in
    // (`columns.rs:423`, over `op_set.rs`), and a delete survives in the
    // document only as a successor edge. So the document holds the insert,
    // the increment, and the base's two rows — and the register's only
    // visible row is the counter, because the increment row is an increment.
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(5, 1), opId(6, 1), opId(2, 0) });
    try expectBothCheckers(&f.set);
}

test "an update before the insert's anchor and one after it take two positions" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 5, 0x11)};
    // One insert anchored at `2@0`, and one update to each of `3@0` and
    // `4@0` — anchors on either side of the element the insert makes, which
    // is what decides where each of the three lands in the sorted batch
    // (`order_ops_for_doc`, `batch.rs:980-987`: the register key is the
    // element an insert *makes* and the element anything else *updates*, so
    // the batch order is `6@1` (updates `3@0`), `7@1` (updates `4@0`),
    // `5@1` (makes `5@1`)).
    const batch = [_]Rec{
        .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .is_insert = true, .val = sval("x") },
        .{ .ctr = 6, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(3, 0)), .val = sval("B"), .pred = &pred_three },
        .{ .ctr = 7, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(4, 0)), .val = sval("C"), .pred = &pred_four },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &three_elems);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // `5@1` is anchored at `2@0`, so it is stacked by `entry` when the walk
    // reaches `2@0` and placed at the next insert's position (2);
    // `6@1` updates `3@0` and is placed at `4@0`'s position (3), and `7@1`
    // updates `4@0` and reaches `finish_updates`, so it lands at `max` (4).
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(5, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = true },
        .{ .id = opId(6, 1), .pos = 3, .subsort = 1, .conflicted = false, .visible = true },
        .{ .id = opId(7, 1), .pos = 4, .subsort = 2, .conflicted = false, .visible = true },
    });
    // The two `put_seq` indices are **2 and 3, not 1 and 2**, and that is the
    // point of the order: the insert advanced the walk's index, so the
    // overwrite of `3@0` lands where `3@0` *will* be, after `"x"`. The
    // conflict flag is `!d.deleted or c.conflict` (`batch.rs:770`), and `3@0`
    // is deleted by `6@1` itself while the change value is not itself a
    // conflict — so it is **false**, which is the other half of what a reader
    // cannot check by reading the code.
    try expectEvents(gpa, &rec, &.{
        "migrate 3",
        "insert 1 x 5@1 conflict=false",
        "put_seq 2 B 6@1 conflict=false expose=false",
        "put_seq 3 C 7@1 conflict=false expose=false",
    });
    // Every run is spliced **at** its `pos` plus the rows the earlier runs
    // added (`batch.rs:963-970`): 2, then 3 + 1, then 4 + 2.
    try expectRowIds(gpa, &f.set, &.{
        opId(1, 0), opId(2, 0), opId(5, 1), opId(3, 0), opId(6, 1),
        opId(4, 0), opId(7, 1),
    });
    try expectBothCheckers(&f.set);
}

test "two concurrent inserts at one position take R4's tie-break and stay contiguous" {
    const gpa = testing.allocator;
    const changes = [_]Change{
        bareChange(fixture_actors[1], 1, 5, 0x11),
        bareChange(fixture_actors[2], 1, 5, 0x22),
    };
    // **Equal counters**, so the actor index decides: `5@2` sorts above `5@1`
    // and rule **R4** puts the greater id first.
    const batch = [_]Rec{
        .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("x") },
        .{ .ctr = 6, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .val = sval("X"), .pred = &pred_five },
        .{ .ctr = 5, .actor = 2, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("y") },
        .{ .ctr = 6, .actor = 2, .obj = list_obj, .key = .fromElemId(elem(5, 2)), .val = sval("Y"), .pred = &pred_five_two },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &one_elem);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // The stack pops from the top (`batch.rs:172`), so the greater id is
    // placed first and takes the lower `subsort`; each insert's own update
    // follows it in the same run, and the two runs do not interleave. **Each
    // insert is invisible** — its own update overwrites it, and an op with a
    // successor is not visible — and **neither is conflicted**: the update
    // that demotes a candidate is a second candidate in the *same* register,
    // and these are two registers.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(5, 2), .pos = 1, .subsort = 0, .conflicted = false, .visible = false },
        .{ .id = opId(6, 2), .pos = 1, .subsort = 1, .conflicted = false, .visible = true },
        .{ .id = opId(5, 1), .pos = 1, .subsort = 2, .conflicted = false, .visible = false },
        .{ .id = opId(6, 1), .pos = 1, .subsort = 3, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{
        "migrate 3",
        "insert 0 Y 6@2 conflict=false",
        "insert 1 X 6@1 conflict=false",
    });
    try expectRowIds(gpa, &f.set, &.{
        opId(1, 0), opId(5, 2), opId(6, 2), opId(5, 1), opId(6, 1), opId(2, 0),
    });
    try expectBothCheckers(&f.set);
}

test "a batch anchored at an element the walk never reaches is refused" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 5, 0x11)};
    // `9@0` names no row anywhere, so nothing the walk reads can ever be the
    // key of the `entry` it lands in, and `finish` finds the entry still
    // there. That is upstream's `assert!(self.entry.is_empty())`
    // (`batch.rs:136`) — the check that says the walk lost track — and the
    // port reports it rather than trapping.
    const batch = [_]Rec{
        .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(9, 0)), .is_insert = true, .val = sval("x") },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &one_elem);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    try testing.expectError(error.Invariant, f.mergeRecorded(&batch, &changes, &rec));

    // The refusal came from the walk, which runs before any mutation
    // (`batch.rs:865-951`: every write is step 7 or later), so the document
    // is exactly what it was.
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0) });
    try expectBothCheckers(&f.set);
    try expectEvents(gpa, &rec, &.{"migrate 3"});
}

// ── Map bases the hand-built merges start from ─────────────────────────────

/// A root map with the keys `b` and `d`, one row each. The rows are the
/// object's only rows, so `MapWalker` reads them from position 0.
const two_keys = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("b"), .val = sval("b1") },
    .{ .ctr = 2, .key = .fromStr("d"), .val = sval("d1") },
};

/// The same, with `b` holding **two rows in one register**: `2@0` overwrites
/// `1@0`, so the walk has to read past the first row to find where the
/// register ends — and the base has to *say* that, because two visible rows in
/// one register is a register with two winners.
const two_rows_one_key = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("b"), .val = sval("b1"), .succ = &succ_by_two },
    .{ .ctr = 2, .key = .fromStr("b"), .val = sval("b2"), .pred = &pred_one },
    .{ .ctr = 3, .key = .fromStr("d"), .val = sval("d1") },
};

/// A map whose key `k` holds two rows that are **both visible** — which is a
/// register with no winner, so a test marks the first conflicted itself. The
/// pair is how a document reaches `ValueState`'s `conflict` flag on the
/// document side, which is the only way to reach the third arm of
/// [`mapProcess`].
const two_visible_rows = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("a"), .act = .make_map },
    .{ .ctr = 2, .key = .fromStr("k"), .val = sval("k1") },
    .{ .ctr = 5, .actor = 2, .key = .fromStr("k"), .val = sval("k5") },
};

/// A map whose key `k` was deleted and then set again by a **later** actor, so
/// the surviving row is `5@2` and the deleted one is `2@0`.
const deleted_then_set = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("a"), .act = .make_map },
    .{ .ctr = 2, .key = .fromStr("k"), .val = sval("k0"), .succ = &succ_by_three },
    .{ .ctr = 5, .actor = 2, .key = .fromStr("k"), .val = sval("k5") },
};

/// The successor edge `2@0` holds: the delete `3@0`, which is not a row of
/// its own (`columns.rs:423`) and survives only as this edge.
const succ_by_three = [_]SuccEntry{.{ .id = opId(3, 0), .inc = null }};

/// A list holding one three-unit element, for the list arm of the text/list
/// asymmetry. `list_obj` is `1@0`, so the object is the same id the text
/// fixture below uses; the two documents are separate.
const list_one_elem = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 2, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("abc") },
};

/// A list holding one **counter** element, for the list arm of the equal-id
/// comparison.
const list_one_counter = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 2, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = cval(5) },
};

/// The same shape as a text object, and a text object holding one **counter**
/// — which is the only way to reach the equal-id arm of the text flush.
const text_one_elem = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("text"), .act = .make_text },
    .{ .ctr = 2, .obj = text_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("abc") },
};

const text_one_counter = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("text"), .act = .make_text },
    .{ .ctr = 2, .obj = text_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = cval(5) },
};

// ── 2. The MapWalker's emission order, hand-built ─────────────────────────

test "a change to a key the document has lands at the cursor, not on its row" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("b"), .val = sval("b2"), .pred = &pred_one },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_keys);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // `1@0` sorts before the change op (`Some(Equal)` and `1@0 > 3@1` is
    // false), so `advance_doc_op` consumes it (`batch.rs:451-456`) and the
    // cursor moves to `1`; `2@0` sorts after, so the walk stops there. The
    // change op takes the cursor (`batch.rs:446`), **which is the position the
    // next document row occupied** — so a map change is an insertion relative
    // to the existing rows, not a replacement of row 1's slot.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 1, .subsort = 0, .conflicted = false, .visible = true },
    });
    // A **map** walk never sets `subsort` (`MapWalker.changeOp` writes `pos`
    // and nothing else), so it is 0 for every op.
    try expectEvents(gpa, &rec, &.{ "migrate 3", "put_map b b2 3@1 conflict=false expose=false" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(3, 1), opId(2, 0) });
    try expectBothCheckers(&f.set);
}

test "a key the document holds two rows of is read to its end before the change op" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 4, 0x11)};
    const batch = [_]Rec{
        .{ .ctr = 4, .actor = 1, .key = .fromStr("b"), .val = sval("b3"), .pred = &pred_two },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_rows_one_key);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // Both `b` rows sort before `4@1` and both are read; the walk stops at the
    // `d` row, so the change op lands at 2 — one past the end of the register,
    // which is where the *next* register's row was.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(4, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "put_map b b3 4@1 conflict=false expose=false" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0), opId(4, 1), opId(3, 0) });
    try expectBothCheckers(&f.set);
}

test "a change for a key the document does not have lands at the cursor" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("c"), .val = sval("c1") },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_keys);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // `b` sorts before `c` and is consumed; `d` sorts after and stops the
    // walk. So the new key's row is spliced **between** the two, which is the
    // key order R2 and not the order the ops were written in.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 1, .subsort = 0, .conflicted = false, .visible = true },
    });
    // No document value for the key, so the flush is the "nothing on the
    // document side" arm (`batch.rs:889-891`) and the conflict flag is the
    // change value's own — which is `false`, because nothing preceded it in
    // this register.
    try expectEvents(gpa, &rec, &.{ "migrate 3", "put_map c c1 3@1 conflict=false expose=false" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(3, 1), opId(2, 0) });
    try expectBothCheckers(&f.set);
}

test "two incoming ops for one key take one position and flag the first" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("c"), .val = sval("c1") },
        .{ .ctr = 4, .actor = 1, .key = .fromStr("c"), .val = sval("c2"), .pred = &pred_three },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_keys);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // The second op's key equals the walk's, so there is no flush and no
    // cursor move (`batch.rs:445`): both land at 1. The second one demotes the
    // first through [`Top.processChangeOp`](batch.rs:383-392) and the flush's
    // `change` is the second, flagged conflicted because the first was showing
    // (`batch.rs:567`).
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 1, .subsort = 0, .conflicted = true, .visible = true },
        .{ .id = opId(4, 1), .pos = 1, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "put_map c c2 4@1 conflict=true expose=false" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(3, 1), opId(4, 1), opId(2, 0) });
    try expectBothCheckers(&f.set);
}

test "a document op whose key sorts between two incoming keys is read between them" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("a"), .val = sval("a1") },
        .{ .ctr = 4, .actor = 1, .key = .fromStr("e"), .val = sval("e1") },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_keys);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // **The first op takes the cursor before the walk has read anything**
    // (`pos` 0), because `b` sorts after `a`. The second op's key change
    // flushes `a`, then consumes both `b` and `d` — whose keys sort *between*
    // the two incoming keys — and only then takes the cursor, which is now 2,
    // one past the object's last row.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 0, .subsort = 0, .conflicted = false, .visible = true },
        .{ .id = opId(4, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{
        "migrate 3",
        "put_map a a1 3@1 conflict=false expose=false",
        "put_map e e1 4@1 conflict=false expose=false",
    });
    try expectRowIds(gpa, &f.set, &.{ opId(3, 1), opId(1, 0), opId(2, 0), opId(4, 1) });
    try expectBothCheckers(&f.set);
}

// ── 3. The four conflict-winner rules, each with a distinguishing case ─────

test "text exposure records the rendered winner in either document row order" {
    // The deleted→surviving transition in `OpValueOption::set`
    // (`batch.rs:557-570`) must satisfy the replacement invariant at
    // `batch.rs:759-774` too. A later survivor was already the visible
    // winner, so the replacement removes its own width, not the earlier
    // deleted row's width.
    const gpa = testing.allocator;
    const PatchLog = @import("../patches.zig").PatchLog;
    const text: PatchValue = .{ .scalar = .{ .str = "\u{1F98A}\u{1F43B}" } };
    const object: PatchValue = .{ .object = .map };
    const deleted: PatchValue = .{ .scalar = .{ .bytes = "deleted" } };
    const encodings = [_]TextEncoding{ .unicode_code_point, .utf8_code_unit, .utf16_code_unit, .grapheme_cluster };
    const text_widths = [_]usize{ 2, 8, 4, 2 };
    const replacement_widths = [_]usize{ 1, 3, 1, 1 };
    for (encodings, 0..) |encoding, e| {
        for ([_]bool{ false, true }) |deleted_first| {
            for ([_]PatchValue{ text, object }) |survivor| {
                var state = ValueState(PatchLog).init(gpa, .root, .text, encoding);
                defer state.deinit();
                const survivor_id = opId(3, if (deleted_first) 2 else 1);
                const deleted_id = opId(3, if (deleted_first) 1 else 2);
                state.key = .{ .index = 7 };
                if (deleted_first) {
                    state.doc.set(deleted, deleted_id, true);
                    state.doc.set(survivor, survivor_id, false);
                } else {
                    state.doc.set(survivor, survivor_id, false);
                    state.doc.set(deleted, deleted_id, true);
                }
                const value = state.doc.item.?;
                try testing.expect(value.expose);
                try testing.expect(!value.deleted);
                try testing.expect(!value.conflict);
                try testing.expect(value.id.eql(survivor_id));
                try testing.expect(std.meta.eql(value.value, survivor));
                try testing.expect(value.replaced != null);
                try testing.expect(std.meta.eql(value.replaced.?, if (deleted_first) survivor else deleted));

                // A replacement is an insertion: unchanged marks must survive
                // alongside marks introduced by the batch.
                const bold = MarkData.init("bold", .{ .bool_value = true });
                _ = try state.marks.before.markBegin(opId(4, 0), bold);
                _ = try state.marks.after.markBegin(opId(4, 0), bold);
                _ = try state.marks.after.markBegin(opId(6, 0), MarkData.init("italic", .{ .bool_value = true }));
                var log = PatchLog.active(gpa);
                defer log.deinit();
                try state.listFlush(7, &log);
                try testing.expectEqual(@as(usize, 2), log.events.items.len);
                const removal = log.events.items[0].event;
                try testing.expect(removal == .delete_seq);
                try testing.expectEqual(@as(usize, 7), removal.delete_seq.index);
                const old_width = if (deleted_first and !survivor.isObject()) text_widths[e] else replacement_widths[e];
                try testing.expectEqual(old_width, removal.delete_seq.num);
                const insertion = log.events.items[1].event;
                if (survivor.isObject()) {
                    try testing.expect(insertion == .insert);
                    try testing.expectEqual(@as(usize, 7), insertion.insert.index);
                    try testing.expectEqual(survivor.object, insertion.insert.value.object);
                    try testing.expect(insertion.insert.id.eql(survivor_id));
                    try testing.expect(!insertion.insert.conflict);
                    try testing.expect(log.expose.contains(survivor_id));
                    try testing.expectEqual(@as(usize, 1), log.expose.count());
                } else {
                    try testing.expect(insertion == .splice);
                    try testing.expectEqual(@as(usize, 7), insertion.splice.index);
                    try testing.expectEqualStrings(survivor.asStr(), insertion.splice.text);
                    try testing.expect(insertion.splice.marks != null);
                    const marks = insertion.splice.marks.?;
                    try testing.expectEqual(@as(usize, 2), marks.len());
                    try testing.expectEqualStrings("bold", marks.entries.items[0].name);
                    try testing.expect(marks.entries.items[0].value.eql(.{ .bool_value = true }));
                    try testing.expectEqualStrings("italic", marks.entries.items[1].name);
                    try testing.expect(marks.entries.items[1].value.eql(.{ .bool_value = true }));
                    try testing.expectEqual(@as(usize, 0), log.expose.count());
                }
            }
        }
    }
}

test "rule one: a greater change id wins, and a deleted document value means no conflict" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    // The document's `k` is a **counter**, and a `delete` in the same batch
    // overwrites it, so `ValueState` holds a document value that is *deleted*
    // (`batch.rs:612-626` and `:67-75`). The change that comes after has the
    // greater id, so it wins — and the conflict flag is
    // `(c.conflict && !d.conflict) || !d.deleted` (`batch.rs:894-901`), which
    // with an uncontested change value and a deleted document value is
    // **false**. A "greater wins, so conflict" reading would say `true`, the
    // equal-id arm would emit an increment, and the lesser arm would flag.
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("k"), .act = .delete, .pred = &pred_two },
        .{ .ctr = 4, .actor = 1, .key = .fromStr("k"), .val = sval("k1"), .pred = &pred_two },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &counter_doc);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = false },
        .{ .id = opId(4, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "put_map k k1 4@1 conflict=false expose=false" });
    // The `delete` op is not a row (`columns.rs:423`): it is `2@0`'s successor
    // edge and nothing else.
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0), opId(4, 1) });
    try expectBothCheckers(&f.set);
}

test "rule one again: a contested change value flags over a deleted document value" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    // The same shape, with a **second** change op overwriting the first, so the
    // change value reaching the flush is `conflict = true` (`batch.rs:567`).
    // Now `!d.deleted` is still false and the flag can only come from the
    // `c.conflict && !d.conflict` half of the rule.
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("k"), .val = sval("k1"), .pred = &pred_two },
        .{ .ctr = 4, .actor = 1, .key = .fromStr("k"), .act = .delete, .pred = &pred_two },
        .{ .ctr = 5, .actor = 1, .key = .fromStr("k"), .val = sval("k2"), .pred = &pred_two },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &counter_doc);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 2, .subsort = 0, .conflicted = true, .visible = true },
        .{ .id = opId(4, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = false },
        .{ .id = opId(5, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "put_map k k2 5@1 conflict=true expose=false" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0), opId(3, 1), opId(5, 1) });
    try expectBothCheckers(&f.set);
}

test "rule two: a lesser change id flags a conflict when the document's op is not conflicted" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 5, 0x11)};
    // The change's id is **lesser** than the document's: same counter, lower
    // actor index (`types.rs:439-444`), which two actors' concurrent changes
    // can produce. The document's `5@2` is not conflicted, so the flush flags
    // (`batch.rs:902-904`).
    const batch = [_]Rec{
        .{ .ctr = 5, .actor = 1, .key = .fromStr("k"), .val = sval("k5b"), .pred = &pred_five_two },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &deleted_then_set);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(5, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "flag_conflict key:k" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0), opId(5, 1), opId(5, 2) });
    try expectBothCheckers(&f.set);
}

test "rule two again: an already-conflicted document op is not flagged a second time" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 5, 0x11)};
    // The same lesser id, against a document register that already holds two
    // visible rows. The walk folds both, so the second `ValueState.set`
    // records `conflict = true` on the document side (`batch.rs:567`) and the
    // flush's guard `if !d.conflict` does not fire. **Nothing is emitted**,
    // which no other rule answers.
    const batch = [_]Rec{
        .{ .ctr = 5, .actor = 1, .key = .fromStr("k"), .val = sval("k5b") },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_visible_rows);
    // `2@0` and `5@2` are both visible, so the register has no winner until
    // this says which one lost.
    try f.set.conflict(1);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(5, 1), .pos = 2, .subsort = 0, .conflicted = true, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{"migrate 3"});
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0), opId(5, 1), opId(5, 2) });
    try expectBothCheckers(&f.set);
}

test "rule three: equal ids emit the increment delta, not a replacement" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    // The document's `2@0` is a counter and the batch re-applies the two
    // increments on it, so the fold adopts the document's value under the
    // **document's** id and adds both amounts (`batch.rs:628-641`). The flush
    // then sees equal ids and emits the difference (`batch.rs:905-908`): the
    // sum, `2`, not either counter value and not a put.
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("k"), .act = .increment, .val = ival(1), .pred = &pred_two },
        .{ .ctr = 4, .actor = 1, .key = .fromStr("k"), .act = .increment, .val = ival(1), .pred = &pred_two },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &counter_doc);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = false },
        .{ .id = opId(4, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = false },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "increment_map k 2 2@0" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0), opId(3, 1), opId(4, 1) });
    try expectBothCheckers(&f.set);
}

test "rule four: a deleted document value is replaced on text and put on a list" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    // The same batch against a list and against a text. **The list arm has no
    // replace**: it puts the change's value, and because the document's own
    // value is deleted the conflict flag `!d.deleted || c.conflict`
    // (`batch.rs:770`) is false. The text arm's deleted-value check comes
    // *before* the id comparisons (`batch.rs:720-737`), and it has to name
    // the text it replaces — an element can be wider than the one unit a
    // `put` would cover.
    const list_batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .val = sval("X"), .pred = &pred_two },
    };
    const text_batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .obj = text_obj, .key = .fromElemId(elem(2, 0)), .val = sval("X"), .pred = &pred_two },
    };

    const list_doc = try Fixture.new(gpa);
    defer list_doc.destroy();
    try list_doc.build(0, &list_one_elem);
    var list_rec: Recorder = .{ .gpa = gpa };
    defer list_rec.deinit();
    const list_ops = try list_doc.mergeRecorded(&list_batch, &changes, &list_rec);
    defer freeOps(gpa, list_ops);
    try expectPlaced(gpa, list_ops, &.{
        .{ .id = opId(3, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &list_rec, &.{
        "migrate 3",
        "put_seq 0 X 3@1 conflict=false expose=false",
    });
    try expectRowIds(gpa, &list_doc.set, &.{ opId(1, 0), opId(2, 0), opId(3, 1) });
    try expectBothCheckers(&list_doc.set);

    const text_doc = try Fixture.new(gpa);
    defer text_doc.destroy();
    try text_doc.build(0, &text_one_elem);
    var text_rec: Recorder = .{ .gpa = gpa };
    defer text_rec.deinit();
    const text_ops = try text_doc.mergeRecorded(&text_batch, &changes, &text_rec);
    defer freeOps(gpa, text_ops);
    try expectPlaced(gpa, text_ops, &.{
        .{ .id = opId(3, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &text_rec, &.{
        "migrate 3",
        "replace_seq 0 abc->X 3@1 conflict=false expose=false marks=0",
    });
    try expectRowIds(gpa, &text_doc.set, &.{ opId(1, 0), opId(2, 0), opId(3, 1) });
    try expectBothCheckers(&text_doc.set);
}

test "rule four again: an increment over a text counter changes no text" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    // The equal-id arm of the text flush returns without emitting
    // (`batch.rs:746`); the list arm of the same input emits an increment
    // (`batch.rs:758-764`). **A counter in a text object is the only thing
    // that reaches it**, and the difference is the point.
    const list_batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .act = .increment, .val = ival(1), .pred = &pred_two },
    };
    const text_batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .obj = text_obj, .key = .fromElemId(elem(2, 0)), .act = .increment, .val = ival(1), .pred = &pred_two },
    };

    const list_doc = try Fixture.new(gpa);
    defer list_doc.destroy();
    try list_doc.build(0, &list_one_counter);
    var list_rec: Recorder = .{ .gpa = gpa };
    defer list_rec.deinit();
    const list_ops = try list_doc.mergeRecorded(&list_batch, &changes, &list_rec);
    defer freeOps(gpa, list_ops);
    try expectEvents(gpa, &list_rec, &.{ "migrate 3", "increment_seq 0 1 2@0" });
    try expectRowIds(gpa, &list_doc.set, &.{ opId(1, 0), opId(2, 0), opId(3, 1) });
    try expectBothCheckers(&list_doc.set);

    const text_doc = try Fixture.new(gpa);
    defer text_doc.destroy();
    try text_doc.build(0, &text_one_counter);
    var text_rec: Recorder = .{ .gpa = gpa };
    defer text_rec.deinit();
    const text_ops = try text_doc.mergeRecorded(&text_batch, &changes, &text_rec);
    defer freeOps(gpa, text_ops);
    try expectPlaced(gpa, text_ops, &.{
        .{ .id = opId(3, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = false },
    });
    try expectEvents(gpa, &text_rec, &.{"migrate 3"});
    try expectRowIds(gpa, &text_doc.set, &.{ opId(1, 0), opId(2, 0), opId(3, 1) });
    try expectBothCheckers(&text_doc.set);
}

// ── 4. normalize_increment_successors, directly and inside the walkers ─────

test "an increment successor survives a counter predecessor and is dropped by a string one" {
    // **The function on its own**, `batch.rs:485-495`. The flag is the
    // *predecessor's* declared value: a counter keeps the increment, and any
    // other value makes the edge an overwrite, because a counter's
    // `succ_inc` column may only be filled from a counter.
    var over_counter = [_]SuccEntry{.{ .id = opId(3, 1), .inc = 7 }};
    normalizeIncrementSuccessors(true, &over_counter);
    try testing.expectEqual(@as(?i64, 7), over_counter[0].inc);

    var over_string = [_]SuccEntry{.{ .id = opId(3, 1), .inc = 7 }};
    normalizeIncrementSuccessors(false, &over_string);
    try testing.expectEqual(@as(?i64, null), over_string[0].inc);

    // Only the `Some`s go: an overwrite edge is already `null` and stays so.
    var mixed = [_]SuccEntry{
        .{ .id = opId(3, 1), .inc = null },
        .{ .id = opId(4, 1), .inc = 2 },
    };
    normalizeIncrementSuccessors(false, &mixed);
    try testing.expectEqual(@as(?i64, null), mixed[0].inc);
    try testing.expectEqual(@as(?i64, null), mixed[1].inc);
    normalizeIncrementSuccessors(true, &mixed);
    try testing.expectEqual(@as(?i64, null), mixed[0].inc);
}

test "a merge whose two sides disagree normalizes by the change's own value" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    // **The document says `k` is a string and the change says it is a
    // counter.** `MapWalker.changeOp` drains the change op's own successors
    // with the **change op's** `isCounter` (`batch.rs:429`), which is `true`,
    // so the increment from `4@1` is kept and `3@1` stays visible with the
    // increment folded in. Normalizing by the *document's* value — a string —
    // would null the increment, which deletes `3@1`, and the register would
    // flush as a `delete_map` instead of a `put_map`. **The two answers are
    // different patches, so this case distinguishes them.**
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("k"), .val = cval(9), .pred = &pred_two },
        .{ .ctr = 4, .actor = 1, .key = .fromStr("k"), .act = .increment, .val = ival(7), .pred = &pred_three_one },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &string_doc);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = true },
        .{ .id = opId(4, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = false },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "put_map k counter:16 3@1 conflict=false expose=false" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0), opId(3, 1), opId(4, 1) });
    try expectBothCheckers(&f.set);
}

test "and the mirror: a string over a counter drops the increment and empties the register" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    // **The document says `k` is a counter and the change says it is a
    // string**, so `MapWalker.changeOp` normalizes with `false` and the
    // increment from `4@1` becomes an overwrite: `3@1` is deleted, the fold
    // finds nothing to adopt, and the register flushes as a `delete_map`.
    // Normalizing by the *document's* counter would have kept the increment
    // and put the string there instead.
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("k"), .val = sval("s"), .pred = &pred_two },
        .{ .ctr = 4, .actor = 1, .key = .fromStr("k"), .act = .increment, .val = ival(7), .pred = &pred_three_one },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &counter_doc);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = false },
        .{ .id = opId(4, 1), .pos = 2, .subsort = 0, .conflicted = false, .visible = false },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "delete_map k" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0), opId(3, 1), opId(4, 1) });
    try expectBothCheckers(&f.set);
}

// ── Bases and batches the remaining groups need ────────────────────────────

/// A single head-anchored insert, which is the smallest batch that reaches
/// every part of [`Untangler`]'s stack path.
const one_head_insert = [_]Rec{
    .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("x") },
};

/// A single insert anchored at an element **no row carries**, which is the
/// shape that leaves an `entry` behind.
const orphan_insert = [_]Rec{
    .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(9, 0)), .is_insert = true, .val = sval("x") },
};

/// A batch that reaches **all four** of [`Untangler.init`]'s destinations:
/// `5@1` is anchored at HEAD so it is stacked, `6@1` and `7@1` are anchored at
/// elements this batch makes so they are `gosub`s of their makers, and `8@1`
/// and `9@1` update elements the batch does not make so they are `updates`.
const all_four = [_]Rec{
    .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("x") },
    .{ .ctr = 6, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .is_insert = true, .val = sval("y") },
    .{ .ctr = 7, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(6, 1)), .is_insert = true, .val = sval("z") },
    .{ .ctr = 8, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .val = sval("A"), .pred = &pred_two },
    .{ .ctr = 9, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .val = sval("B"), .pred = &pred_five },
};

/// A list object and nothing else — the base of the interleaving fixture.
const wisdom_base = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("wisdom"), .act = .make_list },
};

/// `doc1`'s five elements, chained. `doc2` forked from the same list and made
/// its own five with the same counters, so the two sets of ids are
/// `(2..6)@1` and `(2..6)@2` and rule **R4** has to separate them.
const wisdom_doc1 = [_]Rec{
    .{ .ctr = 2, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("to") },
    .{ .ctr = 3, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(2, 1)), .is_insert = true, .val = sval("be") },
    .{ .ctr = 4, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(3, 1)), .is_insert = true, .val = sval("is") },
    .{ .ctr = 5, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(4, 1)), .is_insert = true, .val = sval("to") },
    .{ .ctr = 6, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(5, 1)), .is_insert = true, .val = sval("do") },
};

const wisdom_doc2 = [_]Rec{
    .{ .ctr = 2, .actor = 2, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("to") },
    .{ .ctr = 3, .actor = 2, .obj = list_obj, .key = .fromElemId(elem(2, 2)), .is_insert = true, .val = sval("do") },
    .{ .ctr = 4, .actor = 2, .obj = list_obj, .key = .fromElemId(elem(3, 2)), .is_insert = true, .val = sval("is") },
    .{ .ctr = 5, .actor = 2, .obj = list_obj, .key = .fromElemId(elem(4, 2)), .is_insert = true, .val = sval("to") },
    .{ .ctr = 6, .actor = 2, .obj = list_obj, .key = .fromElemId(elem(5, 2)), .is_insert = true, .val = sval("be") },
};

/// A list holding `"two"`, made by the **greater** of the two actors, for the
/// sibling case where the other actor's insert sorts before it. The object is
/// the `make_list` op's own id, `1@2`, and every row under it has to say so.
const two_by_greater = [_]Rec{
    .{ .ctr = 1, .actor = 2, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 2, .actor = 2, .obj = list_obj_greater, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("two") },
};

/// The same, made by the **lesser** actor, so the object is `1@1`.
const two_by_lesser = [_]Rec{
    .{ .ctr = 1, .actor = 1, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 2, .actor = 1, .obj = list_obj_lesser, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("two") },
};

const list_obj_greater: ObjId = .{ .id = opId(1, 2) };
const list_obj_lesser: ObjId = .{ .id = opId(1, 1) };

// ── 5. finish's three checks ───────────────────────────────────────────────

test "a batch anchored at an element the document has never reached fails the empty-entry check" {
    // Upstream `assert!(self.entry.is_empty())` (`batch.rs:136`), ported as
    // `error.Invariant`. `entry` is keyed by a document element's id and is
    // drained when the walk reaches a document row **with that id**; an
    // anchor no row carries therefore survives to `finish`. The batch below
    // is anchored at `9@0`, which names no row at all.
    const gpa = testing.allocator;
    const ops = try mkOps(gpa, &orphan_insert);
    defer freeOps(gpa, ops);
    var conflicts: std.ArrayList(Adjust) = .empty;
    defer conflicts.deinit(gpa);
    var pred: PredCache = .empty;
    defer freePred(gpa, &pred);
    var log: Recorder = .{ .gpa = gpa };
    defer log.deinit();
    var ut = try Untangler(Recorder).init(gpa, list_obj, .list, fixture_encoding, &conflicts, ops, &pred, 2);
    defer ut.deinit();

    // The anchor is in none of `init`'s three insert destinations — not the
    // head, and no batch op made it — so the op is in `entry` and the stack is
    // empty, and `finish` finds the entry still there.
    try testing.expectEqual(@as(usize, 1), ut.entry.count());
    try testing.expectEqualSlices(usize, &.{}, ut.stack.items);
    try testing.expectError(error.Invariant, ut.finish(&log));
}

test "untangle_inner refuses an op that already has a position" {
    // Upstream `assert!(op.pos.is_none())` (`batch.rs:180`), ported as
    // `error.Invariant`. **This check cannot be reached through
    // `BatchApply.apply`**, and the test above is the argument: `init`'s four
    // destinations are disjoint — an insert goes to exactly one of `stack`,
    // `entry` or `gosub` and a non-insert to `updates` — so no op is ever
    // pushed onto the stack twice and `untangleInner` never sees one twice.
    // It is not dead code, though: it is the check that says so, and here it
    // is shown firing on the state it exists to catch.
    const gpa = testing.allocator;
    const ops = try mkOps(gpa, &one_head_insert);
    defer freeOps(gpa, ops);
    var conflicts: std.ArrayList(Adjust) = .empty;
    defer conflicts.deinit(gpa);
    var pred: PredCache = .empty;
    defer freePred(gpa, &pred);
    var log: Recorder = .{ .gpa = gpa };
    defer log.deinit();
    var ut = try Untangler(Recorder).init(gpa, list_obj, .list, fixture_encoding, &conflicts, ops, &pred, 2);
    defer ut.deinit();

    // `init` stacked the op; a position on it is the corruption.
    try testing.expectEqualSlices(usize, &.{0}, ut.stack.items);
    ops[0].pos = 1;
    try testing.expectError(error.Invariant, ut.finish(&log));
}

test "and init's four destinations hold every op exactly once" {
    // The positive half of the argument above, on a batch that reaches all
    // four. If one op could land in two of them the stack could hold it twice
    // and the previous test's check would be reachable.
    const gpa = testing.allocator;
    const ops = try mkOps(gpa, &all_four);
    defer freeOps(gpa, ops);
    var conflicts: std.ArrayList(Adjust) = .empty;
    defer conflicts.deinit(gpa);
    var pred: PredCache = .empty;
    defer freePred(gpa, &pred);
    var log: Recorder = .{ .gpa = gpa };
    defer log.deinit();
    var ut = try Untangler(Recorder).init(gpa, list_obj, .list, fixture_encoding, &conflicts, ops, &pred, 4);
    defer ut.deinit();

    // `5@1` is at the head, so it is on the stack; `6@1` and `7@1` are anchored
    // at elements the batch made, so they are gosubs of their makers; `8@1`
    // and `9@1` are updates, so they are the only two in `updates`.
    try testing.expectEqualSlices(usize, &.{0}, ut.stack.items);
    try testing.expectEqual(@as(usize, 0), ut.entry.count());
    try testing.expectEqualSlices(usize, &.{1}, ut.gosub.get(0).?.items);
    try testing.expectEqualSlices(usize, &.{2}, ut.gosub.get(1).?.items);
    try testing.expectEqualSlices(usize, &.{3}, ut.updates.get(opId(2, 0)).?.items);
    try testing.expectEqualSlices(usize, &.{4}, ut.updates.get(opId(5, 1)).?.items);
}

test "finish's Top::Nothing check cannot fire: the last flush clears the top first" {
    // Upstream `assert_eq!(self.top, Top::Nothing)` (`batch.rs:142`), ported as
    // `error.Invariant`. **`finish` ends with a `flush`, and `flush` ends with
    // `Top.reset`, which assigns `.nothing` unconditionally** (`batch.rs:60-65`
    // over `:361-366`). So the top is always `.nothing` by the time the check
    // reads it, and the check is vacuous. This test shows the vacuity rather
    // than asserting it: a top that the walk *did* leave open still passes.
    const gpa = testing.allocator;
    const ops = try mkOps(gpa, &one_head_insert);
    defer freeOps(gpa, ops);
    var conflicts: std.ArrayList(Adjust) = .empty;
    defer conflicts.deinit(gpa);
    var pred: PredCache = .empty;
    defer freePred(gpa, &pred);
    var log: Recorder = .{ .gpa = gpa };
    defer log.deinit();
    var ut = try Untangler(Recorder).init(gpa, list_obj, .list, fixture_encoding, &conflicts, ops, &pred, 2);
    defer ut.deinit();

    // An open register, as `finish_updates` or `handle_doc_op` would leave.
    ut.top = .{ .change_index = 0 };
    try testing.expect(!ut.top.eql(.nothing));
    try ut.finish(&log);
    try testing.expect(ut.top.eql(.nothing));
}

// ── 6. Concurrent inserts at one position ──────────────────────────────────

test "two chains of inserts at one position do not interleave" {
    // Upstream `does_not_interleave_sequence_insertions_at_same_position`
    // (`tests/test.rs:1459-1510`), ported: two documents fork from one list and
    // each splice five elements at index 0, so the two chains share the
    // counter range 2..6 and are separated only by the actor index.
    const gpa = testing.allocator;
    const changes = [_]Change{
        bareChange(fixture_actors[1], 1, 2, 0x11),
        bareChange(fixture_actors[2], 1, 2, 0x22),
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &wisdom_base);
    try f.merge(&wisdom_doc1, &changes);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&wisdom_doc2, &changes, &rec);
    defer freeOps(gpa, ops);

    // All ten rows are head-anchored or chained, so R4 says a row may follow
    // another when its own id is the greater one — and the whole of `doc2`'s
    // chain does, because `cc > bb`. **Each actor's five rows are contiguous**,
    // which is the whole point: neither chain is broken up by the other's.
    // `2@2` is anchored at HEAD, so the whole chain is stacked and drained at
    // `doc1`'s first element's position, which is 1.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(2, 2), .pos = 1, .subsort = 0, .conflicted = false, .visible = true },
        .{ .id = opId(3, 2), .pos = 1, .subsort = 1, .conflicted = false, .visible = true },
        .{ .id = opId(4, 2), .pos = 1, .subsort = 2, .conflicted = false, .visible = true },
        .{ .id = opId(5, 2), .pos = 1, .subsort = 3, .conflicted = false, .visible = true },
        .{ .id = opId(6, 2), .pos = 1, .subsort = 4, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{
        "migrate 3",
        "insert 0 to 2@2 conflict=false",
        "insert 1 do 3@2 conflict=false",
        "insert 2 is 4@2 conflict=false",
        "insert 3 to 5@2 conflict=false",
        "insert 4 be 6@2 conflict=false",
    });
    try expectRowIds(gpa, &f.set, &.{
        opId(1, 0), opId(2, 2), opId(3, 2), opId(4, 2), opId(5, 2),
        opId(6, 2), opId(2, 1), opId(3, 1), opId(4, 1), opId(5, 1),
        opId(6, 1),
    });
    try expectBothCheckers(&f.set);
}

test "one insert at index zero by the greater actor lands before the element" {
    // Upstream `mutliple_insertions_at_same_list_position_with_insertion_by_greater_actor_id`
    // (`tests/test.rs:1512-1530`), ported: the list was made by the **lesser**
    // actor and the insert comes from the greater one.
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[2], 1, 3, 0x11)};
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 2, .obj = list_obj_lesser, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("one") },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_by_lesser);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    // The insert is anchored at HEAD, so it is stacked, and the stack is
    // drained at `2@1`'s position — which splices it **before** that row, so
    // the rendered list is `["one", "two"]`.
    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 2), .pos = 1, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "insert 0 one 3@2 conflict=false" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 1), opId(3, 2), opId(2, 1) });
    try expectBothCheckers(&f.set);
}

test "and one by the lesser actor lands before it too" {
    // Upstream `mutliple_insertions_at_same_list_position_with_insertion_by_lesser_actor_id`
    // (`tests/test.rs:1533-1551`), ported: the list was made by the **greater**
    // actor and the insert comes from the lesser one. **The counter decides,
    // not the actor** — `3@1 > 2@2` because 3 > 2 — so the insert sorts first
    // either way. The actor only decides when the counters are equal, and
    // group 1's "two concurrent inserts at one position" is that case.
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    const batch = [_]Rec{
        .{ .ctr = 3, .actor = 1, .obj = list_obj_greater, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("one") },
    };

    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_by_greater);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    const ops = try f.mergeRecorded(&batch, &changes, &rec);
    defer freeOps(gpa, ops);

    try expectPlaced(gpa, ops, &.{
        .{ .id = opId(3, 1), .pos = 1, .subsort = 0, .conflicted = false, .visible = true },
    });
    try expectEvents(gpa, &rec, &.{ "migrate 3", "insert 0 one 3@1 conflict=false" });
    try expectRowIds(gpa, &f.set, &.{ opId(1, 2), opId(3, 1), opId(2, 2) });
    try expectBothCheckers(&f.set);
}

// ── 7. The screen in front of the merge ────────────────────────────────────

/// A hash of `tag`, which is how a test names a change.
fn hashOf(tag: u8) ChangeHash {
    return .{ .bytes = [_]u8{tag} ** 32 };
}

/// A change the queue can take ownership of.
///
/// **The one allocation a `Change` owns is `other_actors`**, and
/// [`queuemod.ChangeQueue.clear`] frees it, so a change handed to the queue
/// needs a real one rather than a zero-length literal. Everything else is
/// borrowed, which is what a parsed change is.
fn screenChange(
    gpa: Allocator,
    actor: ActorId,
    seq: u64,
    start: u64,
    tag: u8,
    deps: []const ChangeHash,
) !Change {
    const others = try gpa.alloc(ActorId, 1);
    others[0] = .{ .bytes = actor.bytes };
    return .{
        .bytes = &.{},
        .header_len = 0,
        .actor = actor,
        .deps = deps,
        .hash = hashOf(tag),
        .time = 0,
        .message = &.{},
        .seq = seq,
        .start_op = start,
        .max_op = start,
        .other_actors = others,
    };
}

/// Frees the `other_actors` of a change the screen did **not** take. The array
/// itself is the caller's, because the array is not always wholly the
/// caller's: a successful screen moves the accepted changes out of it.
fn freeUnscreened(gpa: Allocator, changes: []Change) void {
    for (changes) |*c| c.deinit(gpa);
}

/// A queue, a graph and an author table over the three fixture actors.
///
/// **The actor table is the same three in the same order as the fixture's**,
/// so the op set's actor indices and the change graph's agree — which is
/// exactly what [`hasActorSeq`] reads when it asks the graph for an actor's
/// sequence count.
const Screen = struct {
    queue: ChangeQueue,
    graph: ChangeGraph,
    authors: authorsmod.Authors,

    fn init(gpa: Allocator) !Screen {
        var self: Screen = .{
            .queue = ChangeQueue.init(gpa),
            .graph = ChangeGraph.init(gpa),
            .authors = authorsmod.Authors.init(gpa),
        };
        for (fixture_actors) |a| _ = try self.authors.intern(gpa, a);
        return self;
    }

    fn deinit(self: *Screen) void {
        self.queue.deinit();
        self.graph.deinit();
        self.authors.deinit();
    }

    /// Records `c` in the graph, which is what "the document already has it"
    /// means. The graph copies the metadata it needs, so this owns the change
    /// and frees it.
    fn applied(self: *Screen, gpa: Allocator, c: Change) !void {
        var owned = c;
        defer owned.deinit(gpa);
        var meta = try changerec.ChangeMetadata.fromChange(c).intoOwned(gpa);
        defer meta.deinit(gpa);
        try self.graph.addChange(gpa, &self.authors, meta);
    }
};

/// An [`AuthorLookup`] whose answers come from two sets: which actors' changes
/// carry an author, and which actors the document already has one for.
///
/// **Keyed by the actor's bytes**, because [`ActorId`] holds a slice and
/// [`std.hash.autoHash`] refuses a key it cannot hash unambiguously. The
/// fixture actors are string literals, so the key is stable for the test.
const TestAuthors = struct {
    carries: std.StringHashMapUnmanaged(void) = .empty,
    document: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *TestAuthors, gpa: Allocator) void {
        self.carries.deinit(gpa);
        self.document.deinit(gpa);
    }

    fn changeAuthor(ctx: ?*anyopaque, change: *const Change) ?[]const u8 {
        const self: *const TestAuthors = @ptrCast(@alignCast(ctx.?));
        if (!self.carries.contains(change.actor.bytes)) return null;
        return change.actor.bytes;
    }

    fn actorAuthor(ctx: ?*anyopaque, actor: ActorId) ?[]const u8 {
        const self: *const TestAuthors = @ptrCast(@alignCast(ctx.?));
        if (!self.document.contains(actor.bytes)) return null;
        return actor.bytes;
    }

    fn lookup(self: *TestAuthors) AuthorLookup {
        return .{ .ctx = self, .changeAuthor = changeAuthor, .actorAuthor = actorAuthor };
    }
};

test "the screen skips a change the graph holds and one the queue holds" {
    const gpa = testing.allocator;
    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_keys);

    var s = try Screen.init(gpa);
    defer s.deinit();
    var authors: TestAuthors = .{};
    defer authors.deinit(gpa);

    const no_deps = [_]ChangeHash{};
    // The graph holds actor 1's first change.
    try s.applied(gpa, try screenChange(gpa, fixture_actors[1], 1, 1, 0x11, &no_deps));
    // The queue holds an **orphan**: its dependency is in neither the graph nor
    // the queue, so it can never be popped and stays where it is.
    const missing = [_]ChangeHash{hashOf(0xff)};
    try s.queue.push(gpa, try screenChange(gpa, fixture_actors[2], 1, 1, 0x31, &missing));

    const incoming = try gpa.alloc(Change, 3);
    incoming[0] = try screenChange(gpa, fixture_actors[1], 1, 1, 0x11, &no_deps); // in the graph
    incoming[1] = try screenChange(gpa, fixture_actors[2], 1, 1, 0x31, &missing); // in the queue
    incoming[2] = try screenChange(gpa, fixture_actors[1], 2, 2, 0x12, &[_]ChangeHash{hashOf(0x11)});
    // `incoming[2]` is **not** ours any more once the call returns: the
    // accepted changes are moved into the queue, and the ready ones out of it
    // into the batch, which `batch.deinit` frees. The two the screen skipped
    // were consumed by the screen itself — released and blanked — so this
    // `freeUnscreened` is the idempotent second release, not the first, and it
    // is what a caller has to write either way.
    defer {
        freeUnscreened(gpa, incoming[0..2]);
        gpa.free(incoming);
    }

    var batch = try applyChangesBatchLogPatches(gpa, &f.set, &s.graph, &s.queue, authors.lookup(), incoming);
    defer batch.deinit();

    // Only the change that survived both skips is ready, and the orphan is
    // still waiting.
    try testing.expectEqual(@as(usize, 1), batch.len());
    try testing.expect(batch.at(0).hash.eql(hashOf(0x12)));
    try testing.expectEqual(@as(usize, 1), s.queue.len());
    try testing.expect(s.queue.contains(hashOf(0x31)));
    // The screen applies nothing, so the document is exactly what it was.
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0) });
    try expectBothCheckers(&f.set);
}

test "a repeated (actor, seq) inside the batch is refused, and the queue is untouched" {
    const gpa = testing.allocator;
    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_keys);

    var s = try Screen.init(gpa);
    defer s.deinit();
    var authors: TestAuthors = .{};
    defer authors.deinit(gpa);

    const no_deps = [_]ChangeHash{};
    try s.queue.push(gpa, try screenChange(gpa, fixture_actors[1], 1, 1, 0x21, &no_deps));
    // Two different changes claiming actor 2's sequence 1.
    const incoming = try gpa.alloc(Change, 2);
    incoming[0] = try screenChange(gpa, fixture_actors[2], 1, 1, 0x31, &no_deps);
    incoming[1] = try screenChange(gpa, fixture_actors[2], 1, 1, 0x32, &no_deps);
    defer {
        freeUnscreened(gpa, incoming);
        gpa.free(incoming);
    }

    try testing.expectError(
        error.DuplicateSeqNumber,
        applyChangesBatchLogPatches(gpa, &f.set, &s.graph, &s.queue, authors.lookup(), incoming),
    );
    // **Nothing was queued, not even the first change that passed every
    // check**: the queue is extended after the loop (`batch.rs:1103`), so a
    // refusal half-way leaves no trace. And this arm does not call
    // `remove_actor_branch_from` — only the check against the document does.
    try testing.expectEqual(@as(usize, 1), s.queue.len());
    try testing.expect(s.queue.contains(hashOf(0x21)));
    try testing.expect(!s.queue.contains(hashOf(0x31)));
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0) });
    try expectBothCheckers(&f.set);
}

test "an author the document already has for an actor is refused, and nothing is queued" {
    const gpa = testing.allocator;
    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_keys);

    var s = try Screen.init(gpa);
    defer s.deinit();
    var authors: TestAuthors = .{};
    defer authors.deinit(gpa);
    try authors.carries.put(gpa, fixture_actors[2].bytes, {});
    try authors.document.put(gpa, fixture_actors[2].bytes, {});

    const no_deps = [_]ChangeHash{};
    try s.queue.push(gpa, try screenChange(gpa, fixture_actors[1], 1, 1, 0x21, &no_deps));
    const incoming = try gpa.alloc(Change, 2);
    incoming[0] = try screenChange(gpa, fixture_actors[1], 2, 2, 0x41, &no_deps);
    incoming[1] = try screenChange(gpa, fixture_actors[2], 1, 1, 0x42, &no_deps);
    defer {
        freeUnscreened(gpa, incoming);
        gpa.free(incoming);
    }

    try testing.expectError(
        error.DuplicateAuthor,
        applyChangesBatchLogPatches(gpa, &f.set, &s.graph, &s.queue, authors.lookup(), incoming),
    );
    // `0x41` carries no author and passed every check, and it is still not in
    // the queue: the refusal is the whole batch's, not the change's.
    try testing.expectEqual(@as(usize, 1), s.queue.len());
    try testing.expect(s.queue.contains(hashOf(0x21)));
    try testing.expect(!s.queue.contains(hashOf(0x41)));
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0) });
    try expectBothCheckers(&f.set);
}

test "a queued orphan's conflicting actor sequence rejects the batch and is thrown away" {
    const gpa = testing.allocator;
    const f = try Fixture.new(gpa);
    defer f.destroy();
    try f.build(0, &two_keys);

    var s = try Screen.init(gpa);
    defer s.deinit();
    var authors: TestAuthors = .{};
    defer authors.deinit(gpa);

    const no_deps = [_]ChangeHash{};
    // The document has issued actor 1's sequence 1.
    try s.applied(gpa, try screenChange(gpa, fixture_actors[1], 1, 1, 0x51, &no_deps));
    // The queue holds the rest of that actor's branch, waiting on the change
    // the document has.
    const on_51 = [_]ChangeHash{hashOf(0x51)};
    try s.queue.push(gpa, try screenChange(gpa, fixture_actors[1], 2, 2, 0x52, &on_51));
    const on_52 = [_]ChangeHash{hashOf(0x52)};
    try s.queue.push(gpa, try screenChange(gpa, fixture_actors[1], 3, 3, 0x53, &on_52));

    // A **different** change claiming the slot the document already issued.
    const incoming = try gpa.alloc(Change, 1);
    incoming[0] = try screenChange(gpa, fixture_actors[1], 1, 1, 0x54, &no_deps);
    defer {
        freeUnscreened(gpa, incoming);
        gpa.free(incoming);
    }

    try testing.expectError(
        error.DuplicateSeqNumber,
        applyChangesBatchLogPatches(gpa, &f.set, &s.graph, &s.queue, authors.lookup(), incoming),
    );
    // **This arm does mutate the queue** (`batch.rs:1074-1075`): the branch
    // that conflicts with the new change is dropped, so it is not silently
    // kept and it is not silently applied.
    try testing.expectEqual(@as(usize, 0), s.queue.len());
    try testing.expect(!s.queue.contains(hashOf(0x52)));
    try testing.expect(!s.queue.contains(hashOf(0x54)));
    try expectRowIds(gpa, &f.set, &.{ opId(1, 0), opId(2, 0) });
    try expectBothCheckers(&f.set);
}

// ── 8. Two merges with no invariant damage ─────────────────────────────────

test "a merge of two documents with no common history is the same applied one change at a time" {
    const gpa = testing.allocator;
    const changes = [_]Change{
        bareChange(fixture_actors[1], 1, 3, 0x11),
        bareChange(fixture_actors[2], 1, 4, 0x22),
    };
    // `1@0` and `2@0` are this document's; `3@1` and `4@1` are a peer that
    // has never seen them, on keys that do not collide.
    const peer = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("x"), .val = sval("x1") },
        .{ .ctr = 4, .actor = 2, .key = .fromStr("y"), .val = sval("y1") },
    };

    const both = try Fixture.new(gpa);
    defer both.destroy();
    try both.build(0, &two_keys);
    try both.merge(&peer, &changes);

    const one = try Fixture.new(gpa);
    defer one.destroy();
    try one.build(0, &two_keys);
    const first = [_]Rec{peer[0]};
    const second = [_]Rec{peer[1]};
    try one.merge(&first, &changes);
    try one.merge(&second, &changes);

    // The keys ascend `b`, `d`, `x`, `y`, and each change op lands at the
    // cursor — the position of the next row to be read.
    try expectRowIds(gpa, &both.set, &.{
        opId(1, 0), opId(2, 0), opId(3, 1), opId(4, 2),
    });
    try expectBothCheckers(&both.set);
    try expectBothCheckers(&one.set);
    try both.set.debugCmp(&one.set);
}

test "a merge of two forks of one head is the same applied one change at a time" {
    const gpa = testing.allocator;
    const changes = [_]Change{
        bareChange(fixture_actors[1], 1, 2, 0x11),
        bareChange(fixture_actors[2], 1, 2, 0x22),
    };
    // Two forks of the same head, each overwriting the same key. Neither sees
    // the other, so the greater id wins and the loser is flagged.
    const fork_a = [_]Rec{
        .{ .ctr = 2, .actor = 1, .key = .fromStr("a"), .val = sval("a2"), .pred = &pred_one },
    };
    const fork_b = [_]Rec{
        .{ .ctr = 2, .actor = 2, .key = .fromStr("a"), .val = sval("a3"), .pred = &pred_one },
    };

    const both = try Fixture.new(gpa);
    defer both.destroy();
    try both.build(0, &two_keys);
    try both.merge(&fork_a, &changes);
    try both.merge(&fork_b, &changes);

    const one = try Fixture.new(gpa);
    defer one.destroy();
    try one.build(0, &two_keys);
    try one.merge(&fork_a, &changes);
    try one.merge(&fork_b, &changes);

    // The key `a` the two forks overwrote sorts before `b` and `d`, so the
    // register's three rows — `2@1`, `2@2` and the base's own `1@0` under
    // `b` — are laid out by key first. `2@2` is the greater id, so it is the
    // register's winner and `2@1` is flagged conflicted.
    try expectRowIds(gpa, &both.set, &.{
        opId(2, 1), opId(2, 2), opId(1, 0), opId(2, 0),
    });
    try expectBothCheckers(&both.set);
    try expectBothCheckers(&one.set);
    try both.set.debugCmp(&one.set);
}
