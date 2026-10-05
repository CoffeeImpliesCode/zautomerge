//! One row of the op set: the borrowed view, the builders a transaction and
//! a change produce, and the row-order invariant.
//!
//! Upstream `op_set2/op.rs`, 1378 lines, holds four op shapes and the check
//! that keeps them in order:
//!
//! | shape | what it is | upstream |
//! |-------|------------|----------|
//! | [`Op`] | a row already in the document, borrowed out of the columns | `:831-844` |
//! | [`OpBuilder`] | the columns of one operation, owned | `:177-188` |
//! | [`TxOp`] | what a transaction builds around a builder | `:163-175` |
//! | [`ChangeOp`] | what a change decodes into, plus its merge bookkeeping | `:50-57` |
//!
//! and [`OpStepper`] with [`Op.step`], which is the row-order invariant in
//! executable form (`:1048-1073`, `:1363-1378`).
//!
//! # `Op` borrows, and the caller keeps the storage alive
//!
//! `Op` holds a map key, a scalar value and a mark name as borrowed slices
//! (`op_set2/op.rs:838-842`). Those bytes live either in a column of the
//! document or in the change a row was decoded out of. Rust says so with the
//! lifetime `'a`; Zig erases it, so **the storage behind an `Op` must outlive
//! it**, and the type says so here because that is the whole of its safety:
//! there is no borrow checker here to say it again. The same holds for
//! [`SuccCursors.entries`], which is the reader's storage for one row's
//! successors.
//!
//! Nothing in this file allocates behind a caller that did not ask: the
//! builders own their `pred` lists and are freed with [`OpBuilder.deinit`],
//! and every borrowed slice a public function hands out points into storage
//! the caller already holds. No public function returns memory the caller
//! must not free, because none of them returns freshly allocated memory.
//!
//! # `OpLike`, split
//!
//! Upstream writes the row accessors once, as the `OpLike` trait
//! (`op_set2/op.rs:1324-1361`), and implements it four times. The trait's
//! successor half is a generic associated type
//! (`type SuccIter<'b>: ExactSizeIterator<Item = OpId> + 'b`, `:1325-1327`),
//! which Zig cannot spell — it is the one blocker
//! [survey §Zig mapping notes](../../docs/survey/02-transaction-opset.md)
//! calls out. The port splits it into static-arity functions: every op type
//! carries `succCount`, `succAt`, `succIncCount` and `succIncAt`, and a
//! caller that needs them for several op types is generic over
//! `comptime O: type` — which is what [`columns.zig`](columns.zig) is
//! (`:503`) — so the choice is resolved at comptime and inlined, with no
//! vtable and no allocation. The vtable of `docs/plan.md` §3.2 is reserved
//! for `ReadDoc`/`Transactable`, where a caller really does hold either
//! document flavour at runtime.
//!
//! [`assertOpLike`] checks at compile time that a type carries the whole
//! set.
//!
//! # What is not here
//!
//! `hydrate::Value` (`op.rs:1084-1116`) lives in `hydrate.zig`. `ExId`
//! promotion (`op.rs:1027-1038`) and `OpSet::id_to_exid` belong to the
//! document/op-set layer rather than this borrowed-row module.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clock = @import("../clock.zig");
const column = @import("../hexane/column.zig");
const opset_types = @import("types.zig");
// The mark index, for the one definition of the `MarkIdx` word this file's
// rows are marked with. It is an edge in the module graph that did not exist
// before: `mark_index.zig` imports nothing from this file, so the dependency
// runs row → index and not back.
const markidx = @import("mark_index.zig");
const value = @import("../value.zig");

// The types an op set row is assembled from. `types.zig` is the slice's own
// module: `KeyRef` and its partial order (`op_set2/types.rs:584-592`), the
// action and scalar codecs (`op_set2/types.rs:99-112`, `:314-398`) and the
// actor and action column glue (`op_set2/columns.rs:18-29`).
const Action = opset_types.Action;
const ActorIdx = opset_types.ActorIdx;
const KeyRef = opset_types.KeyRef;
const MarkData = opset_types.MarkData;
const OpType = opset_types.OpType;
const PropRef = opset_types.PropRef;
const ScalarValue = opset_types.ScalarValue;
const ValueMeta = opset_types.ValueMeta;

const ObjId = types.ExId;
const ObjMeta = types.ObjMeta;
const ObjType = types.ObjType;
const OpId = types.OpId;
const ElemId = types.ElemId;
const SequenceType = types.SequenceType;
const TextEncoding = types.TextEncoding;

const Allocator = std.mem.Allocator;
const Error = err.Error;
const ParseError = err.ParseError;

const Clock = clock.Clock;

// ── Shared shapes ──────────────────────────────────────────────────────────

/// An object id and the type of object it names
/// (`op_set2/op_set/index.rs:107-110`).
///
/// Upstream declares it in the index builder and produces it from
/// `Op::obj_info` (`op_set2/op.rs:498-502`, `:664-668`); a port that wants
/// one declaration puts it here, next to the op that makes it, because
/// `columns.zig` reads it through `objInfo()` and the index slice reads it
/// through `obj_info`.
pub const ObjInfo = struct {
    /// The id of the operation that made this object.
    parent: ObjId,
    /// What kind of object it is.
    obj_type: ObjType,
};

/// A half-open range of row positions
/// (`std::ops::Range<usize>`, `op_set2/op.rs:174`).
pub const OpRange = struct {
    /// The first row in the range.
    start: usize,
    /// One past the last row in the range.
    end: usize,
};

/// What an operation is, once its action, value and mark columns have been
/// combined, split back apart into the four columns that spell it
/// (`crate::types::OpType::decompose`, `op_set2/types.rs:405-430`).
///
/// The inverse of [`opset_types.opTypeFromActionAndValue`]
/// (`op_set2/types.rs:148-189`). `OpBuilder` is built from one of these by
/// every [`TxOp`] constructor, which is why it lives here rather than in the
/// constructors.
pub const Decomposed = struct {
    /// What the op does: the action column's value.
    action: Action,
    /// The scalar it carries: the value column's metadata and payload.
    value: ScalarValue,
    /// Whether a mark expands before its span: the expand column.
    expand: bool,
    /// The name a mark puts on its span, or null: the mark-name column.
    /// Null is a mark *end* (`op_set2/types.rs:428`).
    mark_name: ?[]const u8,
};

/// Splits `t` into the four columns an op is stored as
/// (`op_set2/types.rs:405-430`).
///
/// A `make` carries no value and no mark, a `delete` carries `Null`, an
/// `increment` carries its amount as a signed integer, a `put` carries the
/// scalar, a mark *begin* carries the mark's own value and name, and a mark
/// *end* carries `Null` and no name. Nothing here allocates and nothing is
/// copied: the borrowed payloads come straight through.
pub fn decompose(t: OpType) Decomposed {
    return switch (t) {
        .make => |o| .{
            .action = switch (o) {
                .map => .make_map,
                .list => .make_list,
                .text => .make_text,
                .table => .make_table,
            },
            .value = .null_value,
            .expand = false,
            .mark_name = null,
        },
        .delete => .{
            .action = .delete,
            .value = .null_value,
            .expand = false,
            .mark_name = null,
        },
        .increment => |i| .{
            .action = .increment,
            .value = .{ .int = i },
            .expand = false,
            .mark_name = null,
        },
        .put => |v| .{ .action = .set, .value = v, .expand = false, .mark_name = null },
        .mark_begin => |b| .{
            .action = .mark,
            .value = b.value,
            .expand = b.expand,
            .mark_name = b.name,
        },
        .mark_end => |e| .{
            .action = .mark,
            .value = .null_value,
            .expand = e.expand,
            .mark_name = null,
        },
    };
}

/// An operation's type together with whether it changes what a reader sees
/// (`ResolvedAction`, `op_set2/op_set.rs:1525-1531`).
///
/// A conflict resolution records that a change put something in a register
/// without disturbing the document's current value, so the merge walks emit
/// no patch for it (`op_set.rs:1522-1524`); a visible update is an ordinary
/// operation. Upstream declares this in the op set root; the `TxOp`
/// constructors are its only producers in this file, so it is declared here
/// and the op-set root re-exports it.
pub const ResolvedAction = union(enum) {
    /// An operation which resolves a conflict but does not change the
    /// observed state, that is, it is invisible to the materialized view
    /// (`op_set.rs:1526-1528`).
    conflict_resolution: OpType,
    /// A normal operation which is visible in the document
    /// (`op_set.rs:1529-1530`).
    visible_update: OpType,

    /// Whether the operation is an increment (`op_set.rs:1534-1540`).
    pub fn isIncrement(self: ResolvedAction) bool {
        const t = switch (self) {
            .conflict_resolution => |t| t,
            .visible_update => |t| t,
        };
        return t == .increment;
    }
};

/// What a `MarkIndexBuilder` marks the column with: the `MarkIdx` word
/// (`MarkIdx::as_i64`, `op_set2/op_set/mark_index.rs:25-34`), and its
/// negation for a mark's end.
///
/// The word itself is [`markidx.markIdxWord`]'s, and this is a forwarder
/// rather than a second expression: the column a mark's word is stored in is
/// the one `mark_index.zig` owns (`columns.zig:298-311`), so the op row and
/// the column have to agree on the encoding bit for bit, and the cheapest
/// way to say they do is to have one definition. The previous copy was
/// written in `i64` and rested on a rule about signed shifts discarding bits
/// that the pinned language reference does not state; that copy is gone.
///
/// A row's word is `markIdxWord` of the mark's **begin** id: a begin row
/// names its own id, and an end row is the operation immediately after its
/// begin and names it at `id.prev()` (`op_set2/op.rs:951`, `:199`), which is
/// why [`prevSaturating`] is where the end arm goes through.
fn markIdxWord(id: OpId) i64 {
    return markidx.markIdxWord(id);
}

/// `id.prev()` that does not trap at counter zero (`OpId::prev`,
/// `types.rs:497-499`, port `types.zig:172-174`).
///
/// A mark end names its begin at `id.prev()` (`op_set2/op.rs:951`), so a
/// mark end at counter zero is a corrupt document. Saturating keeps the
/// read total and hands the document to `MarkOrderValidator`
/// (`op_set2/op_set/index.rs:52-75`), which reports an end with no begin,
/// rather than trapping out of the recovery path.
fn prevSaturating(id: OpId) OpId {
    return .{ .counter = id.counter -| 1, .actor = id.actor };
}

// ── Successors ─────────────────────────────────────────────────────────────

/// The increment index: the delta a counter successor carries, and null for
/// every other successor (`op_set2/columns.rs:42`, `index.rs:236`).
pub const IncColumn = column.Column(?i64, column.RleOption(i64));
/// A prefix column of `u32`: how many successors each row has
/// (`op_set2/columns.rs:25`).
pub const SuccCountColumn = column.Column(u32, column.Prefix(u32));
/// The actor half of the flattened successor list (`op_set2/columns.rs:26`).
pub const SuccActorColumn = opset_types.ActorColumn;
/// The counter half, delta coded (`op_set2/columns.rs:27`).
pub const SuccCounterColumn = column.Column(u32, column.Delta(u32));

/// The four columns one row's successors are read from
/// (`op_set2/columns.rs:25-27` and the `inc` index at `:42`).
///
/// Held as borrowed pointers, and outlived by every [`SuccCursors`] built
/// from it: a cursor does not own the columns, and reading a successor is a
/// read of the column, not of a copy.
pub const SuccColumns = struct {
    /// `succ_count`: one count per row, and the running sum that gives a
    /// row's first successor its position in the flattened columns
    /// (`op_set2/op_set/op_iter.rs:1030-1048`).
    count: *const SuccCountColumn,
    /// `succ_actor`: the actor half, flattened across rows.
    actor: *const SuccActorColumn,
    /// `succ_ctr`: the counter half, flattened across rows.
    counter: *const SuccCounterColumn,
    /// `index.inc`: the increment each successor carries, or null for one
    /// that deletes its predecessor.
    increment: *const IncColumn,
};

/// One successor edge: the id of the operation that overwrote or deleted the
/// row's value, and the increment it carries (`op_set2/op.rs:52`).
pub const SuccEntry = struct {
    /// The successor's own id.
    id: OpId,
    /// The increment this successor adds to a counter predecessor, or null
    /// for one that deletes it (`op_set2/op.rs:52`).
    inc: ?i64,
};

/// A row's successors, borrowed (`SuccCursors`, `op_set2/op.rs:847-852`).
///
/// Upstream holds three column cursors positioned at the row's range; the
/// port holds the row's range itself, so every read is infallible and a
/// reader decides how the entries were obtained — straight out of the
/// columns through [`loadSuccWindow`], or already materialised.
///
/// `entries` is borrowed storage the caller keeps alive, exactly as `Op`'s
/// key, value and mark name are (`op_set2/op.rs:838-842`).
///
/// **Build one with [`fromSpan`] or [`none`], not with a struct literal.**
/// Every field is reachable and there is no private one to hang the obligation
/// on, so the one obligation `has_delete` carries is written here instead:
///
/// > `has_delete` must equal "some entry of `entries` has `inc == null`",
/// > and `read` must be a count of how many of them have been read.
///
/// [`Op.visible`] reads `has_delete` as the answer for a counter row's
/// visibility (`op_set2/op.rs:1151-1153`), and that arm is the reason the flag
/// exists rather than a scan: a counter can have many successors and every
/// visibility read would otherwise walk them all. `fromSpan` computes the
/// flag once, at the point the entries are known, and a cursor that satisfies
/// the invariant cannot answer wrongly there. A literal that sets it to
/// `false` over entries that delete makes a counter row with a deleting
/// successor report itself visible; `read` past `entries.len` is worse still,
/// because `remaining` and `next` both subtract from it.
///
/// The three in-package constructors — [`fromSpan`], [`none`] and
/// [`loadSuccWindow`], which goes through the first — are the supported ones.
pub const SuccCursors = struct {
    /// The row's successors, in ascending id order — the order
    /// `OpSet::add_succ` keeps them in (`op_set2/op_set.rs:262-276`).
    entries: []const SuccEntry,
    /// The row's first successor's position in the flattened successor
    /// columns (`SuccCursors::pos`, `op_set2/op.rs:855-857`). This is the
    /// coordinate [`SuccInsert.sub_pos`] is in.
    at: usize,
    /// How many of `entries` the cursor has read. `at + read` is the
    /// flattened position of the next one, which is what upstream's three
    /// column iterators advance (`op_set2/op.rs:882-886`).
    read: usize,
    /// Whether any successor **of this span** deletes rather than increments —
    /// the one thing [`Op.visible`] needs from the increment column for a
    /// counter row (`op_set2/op.rs:1151-1153`), computed once at construction
    /// so that accessor stays infallible and O(1).
    ///
    /// It is derived state, not an input: it must equal "some entry of
    /// `entries` has `inc == null`", and the type doc states that as an
    /// obligation because Zig has no way to enforce it. It is deliberately
    /// *not* derived where it is read — the counter arm of `Op.visible` is on
    /// the query path, where a counter with many successors would pay a walk
    /// per row.
    has_delete: bool,

    /// A cursor over `entries`, whose first entry sits at flattened position
    /// `at`, with `has_delete` derived from `entries`.
    ///
    /// This is the constructor the type doc asks for. It walks `entries` once,
    /// which is the whole of the work `has_delete` ever costs, and it is why a
    /// counter row's visibility is O(1) afterwards.
    pub fn fromSpan(entries: []const SuccEntry, at: usize) SuccCursors {
        var has_delete = false;
        for (entries) |e| {
            if (e.inc == null) {
                has_delete = true;
                break;
            }
        }
        return .{ .entries = entries, .at = at, .read = 0, .has_delete = has_delete };
    }

    /// A cursor with no successors (`SuccCursors::default`, `op_set2/op.rs:1170`).
    ///
    /// A delete op has no row and so no successors: `Columns::splice` drops
    /// every op whose action is `Delete` (`op_set2/columns.rs:423-427`), and
    /// a delete exists only as a successor edge. Its op set is a whole
    /// object, so a delete op's cursor is only ever asked for its length.
    pub fn none() SuccCursors {
        return fromSpan(&.{}, 0);
    }

    /// The position the next `next` would read
    /// (`SuccCursors::pos`, `op_set2/op.rs:855-857`).
    pub fn pos(self: SuccCursors) usize {
        return self.at + self.read;
    }

    /// How many successors the row has **in total** — a property of `entries`
    /// alone, not of where this cursor stands (`SuccCursors::len`,
    /// `op_set2/op.rs:890-894`).
    ///
    /// `next` advances `read` and leaves this unchanged, so this is **not** a
    /// drain-loop bound: `while (c.len() > 0) { _ = c.next(); }` never ends.
    /// It is the total because that is what the indexed readers need —
    /// `Op.succAt(i)` indexes `entries` by absolute position, and
    /// `Op.succCount` is the count it is the bound for.
    ///
    /// The number still unread is `entries.len - read`, which is what
    /// [`SuccIncCursors.len`] answers. Upstream's `ExactSizeIterator::len`
    /// is the remaining count (`op_set2/op.rs:890-894`), so a caller ported
    /// from upstream must ask a `SuccIncCursors` — reached through
    /// [`withInc`] — for the remaining count, not this one.
    pub fn len(self: SuccCursors) usize {
        return self.entries.len;
    }

    /// The next successor's id, in ascending id order, or null at the end of
    /// the walk (`Iterator for SuccCursors`, `op_set2/op.rs:875-888`).
    ///
    /// This is the cursor half: it advances only `read`, which is the one
    /// field it owns, and it does not copy or reorder `entries`. `null` is
    /// the end of the walk and only the end — an entry's `inc == null` is a
    /// delete, not an end. The successor ids it hands out are borrowed from
    /// `entries` and are values, so they outlive the cursor.
    pub fn next(self: *SuccCursors) ?OpId {
        if (self.read >= self.entries.len) return null;
        defer self.read += 1;
        return self.entries[self.read].id;
    }

    /// The index of the next successor within `entries`.
    fn nextIndex(self: SuccCursors) usize {
        return self.read;
    }

    /// How many successors have not been read: the remaining count upstream's
    /// `len` gives (`op_set2/op.rs:890-894`). Safe because `read` is bounded
    /// by `entries.len` — `next` never passes it.
    fn remaining(self: SuccCursors) usize {
        return self.entries.len - self.read;
    }

    /// A second cursor over the same span that also yields each successor's
    /// increment (`SuccIncCursors`, `op_set2/op.rs:871`, `:896-911`).
    ///
    /// It is a *copy* of this cursor, so the two advance independently: this
    /// one at `read` and the returned one at its own `read`, both into the
    /// same borrowed `entries`. Nothing is allocated and nothing is copied out
    /// of the span.
    pub fn withInc(self: SuccCursors) SuccIncCursors {
        return .{ .inner = self };
    }
};

/// A cursor over a row's successors carrying their increments
/// (`SuccIncCursors`, `op_set2/op.rs:871`, `:896-911`).
///
/// Nothing is owned: `inner` is a [`SuccCursors`] by value, whose `entries`
/// the caller still owns, so this borrows exactly as long as the span does
/// and there is no `deinit`. It is a cursor rather than a collection — its
/// `len` counts what is left to read, which is the count a drain loop wants,
/// while the underlying [`SuccCursors.len`] counts the row's total.
///
/// Reach one with [`SuccCursors.withInc`], which is also where the
/// `has_delete` obligation the inner cursor carries is stated.
pub const SuccIncCursors = struct {
    /// The cursor this one was made from, advanced in place. Its `read` is
    /// *this* value's progress, not the `SuccCursors` it was copied from's:
    /// `withInc` takes the inner by value.
    inner: SuccCursors,

    /// The next successor and its increment, in ascending id order, or null at
    /// the end of the walk (`Iterator for SuccIncCursors`,
    /// `op_set2/op.rs:896-911`).
    ///
    /// This advances the *inner* cursor's `read` through the copy this value
    /// owns, so a `SuccIncCursors` is advanced independently of the
    /// `SuccCursors` it was made from — `withInc` copies. The entries are
    /// borrowed from the original span and are not copied.
    pub fn next(self: *SuccIncCursors) ?SuccEntry {
        if (self.inner.remaining() == 0) return null;
        defer self.inner.read += 1;
        return self.inner.entries[self.inner.nextIndex()];
    }

    /// How many successors are **left to read** (`op_set2/op.rs:927-931`) —
    /// the remaining count, not the total that [`SuccCursors.len`] answers.
    pub fn len(self: SuccIncCursors) usize {
        return self.inner.remaining();
    }
};

/// Reads row `row`'s successors from `cols` into `into` and returns a cursor
/// over them (`SuccIterIter::try_next`, `op_set2/op_set/op_iter.rs:1030-1049`).
///
/// The row's count comes from `succ_count` and its position in the flattened
/// columns from that column's running sum, which is how upstream positions
/// its three sub-iterators (`op_iter.rs:1037-1047`).
///
/// `into` is the caller's, so no allocation happens here and a reader can
/// reuse one buffer per cursor. It must hold at least
/// `succ_count.get(row)` entries; a buffer that does not is
/// `error.TooLarge` rather than a truncated read, because a short read would
/// silently drop successors and hide a delete.
pub fn loadSuccWindow(
    cols: *const SuccColumns,
    row: usize,
    into: []SuccEntry,
) ParseError!SuccCursors {
    const count = (try cols.count.get(row)) orelse return error.InvalidValue;
    const n: usize = @intCast(count);
    if (into.len < n) return error.TooLarge;
    const before = try cols.count.getPrefix(row);
    if (before < 0) return error.InvalidValue;
    const start: usize = @intCast(before);
    for (0..n) |i| {
        const at = start + i;
        const actor = (try cols.actor.get(at)) orelse return error.InvalidValue;
        const counter = (try cols.counter.get(at)) orelse return error.InvalidValue;
        // A null entry here is not "no increment", it is a sub-index the
        // increment column does not have, which is a corrupt document.
        const inc = (try cols.increment.get(at)) orelse return error.InvalidValue;
        into[i] = .{ .id = OpId.init(counter, actor), .inc = inc };
    }
    return SuccCursors.fromSpan(into[0..n], start);
}

/// Where a successor edge goes (`SuccInsert`, `op_set2/op.rs:933-940`).
///
/// Produced by [`Op.addSucc`] and consumed by `OpSet::add_succ`
/// (`op_set2/op_set.rs:259-283`) and `add_succ_with_undo` (`:285-325`).
pub const SuccInsert = struct {
    /// The successor's id.
    id: OpId,
    /// The row the successor is added to.
    pos: usize,
    /// The increment the successor carries, or null for a delete. Nulled
    /// when the row is not a counter (`op_set2/op.rs:959-961`).
    inc: ?i64,
    /// The row's count before an insertion pass (`op_set2/op.rs:962`).
    /// In `SuccUndo.succ`, the count immediately before that individual edge.
    len: u64,
    /// Where in the row's successor list the new one goes, in the flattened
    /// successor columns' coordinates (`op_set2/op.rs:963-969`).
    sub_pos: usize,

    /// Upstream derives `PartialEq` (`op_set2/op.rs:933`); the order is by
    /// position and then by the successor's place in the row's list, which
    /// is how `BatchApply` compares its own `succ` with the natural order
    /// (`op_set2/change/batch.rs:924-935`).
    pub fn eql(a: SuccInsert, b: SuccInsert) bool {
        return a.id.eql(b.id) and a.pos == b.pos and a.inc == b.inc and
            a.len == b.len and a.sub_pos == b.sub_pos;
    }
};

/// What an undone successor edge has to restore (`SuccUndo`,
/// `op_set2/op_set.rs:1587-1593`).
///
/// Carried on [`TxOp.undo`] and replayed by `OpSet::undo_succ`
/// (`op_set2/op_set.rs:327-351`). The three optional payloads identify index
/// columns this edge changed; a null inside `text` means "it was set to null".
pub const SuccUndo = struct {
    /// The edge to remove. `len` is its predecessor row's count immediately
    /// before this edge was published, including earlier edges in the same
    /// insertion pass. Keep the row and flattened coordinates valid until the
    /// complete journal is undone; resumable replay checks row ownership first.
    succ: SuccInsert,
    /// The row's `visible` flag before the edge was added, if it was
    /// cleared.
    visible: ?bool,
    /// The row's text-width index entry before the edge was added, if it was
    /// changed.
    text: ??u32,
    /// The row's `top` flag before the edge was added, if it was changed.
    top: ?bool,
};

/// What one walk of a counter row's successor edges yields
/// (`maybe_scope_counter_to_clock`, `op_set2/op_set/visible.rs:196-213`;
/// `fix_counter`, `op_set2/op.rs:979-995`).
///
/// Upstream writes that walk twice and the two copies differ only in whether
/// the null-increment arm is read, so the port runs it once and both callers
/// read the parts they want. See [`Op.foldSuccIncs`].
const CounterFold = struct {
    /// The increments the clock covered, summed.
    inc: i64,
    /// Whether a covered successor deletes the row rather than incrementing
    /// it (`op_set2/op_set/visible.rs:207-209`).
    deleted: bool,
};

/// Whether `c` covers `id`, and true for a null `c` (`vis`,
/// `op_set2/op_set/visible.rs:174-176`).
///
/// The test is [`Clock.contains`], which is upstream's
/// `Clock::covers(&OpId)` (`clock.rs:134-136`) under this port's name, so
/// there is one predicate here and not two. A null clock covers every id,
/// which is what makes an unscoped read skip the test entirely.
fn coveredBy(c: ?Clock, id: OpId) bool {
    const cover = c orelse return true;
    return cover.contains(id);
}

// ── The op interface ───────────────────────────────────────────────────────

/// The declarations an op type must carry for the generic readers to work on
/// it, by name (`op_set2/op.rs:1324-1361`).
///
/// Upstream gets this from a trait. The port gets it from a comptime check,
/// so a type that is missing one of them fails to compile rather than to
/// behave.
pub const op_like_decls = [_][]const u8{
    "id",
    "obj",
    "objId",
    "objActor",
    "objCtr",
    "objInfo",
    "action",
    "key",
    "keyStr",
    "keyActor",
    "keyCtr",
    "insert",
    "value",
    "metaValue",
    "rawValue",
    "expand",
    "markName",
    "markData",
    "markIndex",
    "width",
    "visible",
    "top",
    "elemidOrKey",
    "asStr",
    "isInc",
    "isCounter",
    "isMark",
    "isDelete",
    "getIncrementValue",
    "cursor",
    "succCount",
    "succAt",
    "succIncCount",
    "succIncAt",
    "succ",
    "succInc",
    "idActor",
    "idCtr",
    "opIdCtr",
    "predCount",
    "pred",
};

/// Fails to compile unless `O` carries every declaration in
/// [`op_like_decls`].
///
/// This is the whole of the `OpLike` check in the port. A generic reader
/// over `comptime O` (`columns.zig:503`) resolves its call sites at comptime
/// and inlines them, so nothing here is dynamic and nothing here allocates;
/// the check exists so that a reader and a writer that disagree about the
/// interface fail at build time.
pub fn assertOpLike(comptime O: type) void {
    inline for (op_like_decls) |name| {
        if (!@hasDecl(O, name)) {
            @compileError("op type " ++ @typeName(O) ++ " has no " ++ name ++
                "; it does not implement the row accessors of op_set2/op.rs:1324-1361");
        }
    }
}

// ── OpBuilder ──────────────────────────────────────────────────────────────

/// The columns of one operation, owned (`OpBuilder`, `op_set2/op.rs:177-188`).
///
/// This is what a transaction builds and what a change decodes into. Its
/// borrowed payloads — the map key in `key`, the `str`, `bytes` and `actor_id`
/// of `value`, and `mark_name` — are not copied by [`OpBuilder.init`] and are
/// not freed by [`OpBuilder.deinit`]: they point into the string table, the
/// value arena or the change the op was built from, and the owner of that
/// storage outlives the builder. `pred` is the one field the builder owns,
/// because upstream's `Vec<OpId>` is owned too (`op_set2/op.rs:187`).
///
/// Upstream reaches the same accessors through `AsBuilder`
/// (`op_set2/op.rs:16-47`); in Zig the accessors are on the type, which is
/// what `OpLike`'s four impls reduce to.
pub const OpBuilder = struct {
    /// The operation's own id (`id_actor`, `id_ctr`).
    _id: OpId,
    /// The parent object's id (`obj_actor`, `obj_ctr`).
    _obj: ObjId,
    /// What the operation does (`action`).
    _action: Action,
    /// What the operation hangs by: a map key, or the element a sequence
    /// operation is anchored to (`key_str`, `key_actor`, `key_ctr`).
    _key: KeyRef,
    /// Whether the operation inserts rather than overwrites (`insert`).
    _insert: bool,
    /// The scalar it carries (`value_meta`, `value`).
    _value: ScalarValue,
    /// Whether a mark expands before its span (`expand`).
    _expand: bool,
    /// The name a mark puts on its span, or null for a mark end
    /// (`mark_name`).
    _mark_name: ?[]const u8,
    /// The operations this one overwrites or deletes. Owned here.
    _pred: std.ArrayList(OpId),

    /// A builder holding the columns `pos`-th operation of a document,
    /// owning a copy of `pred`.
    ///
    /// Every borrowed slice is passed straight through, so the caller keeps
    /// whatever storage they name alive for as long as the builder lives.
    pub fn init(
        gpa: Allocator,
        op_id: OpId,
        op_obj: ObjId,
        op_action: Action,
        op_key: KeyRef,
        op_value: ScalarValue,
        is_insert: bool,
        expands: bool,
        mark: ?[]const u8,
        predecessors: []const OpId,
    ) Allocator.Error!OpBuilder {
        return .{
            ._id = op_id,
            ._obj = op_obj,
            ._action = op_action,
            ._key = op_key,
            ._insert = is_insert,
            ._value = op_value,
            ._expand = expands,
            ._mark_name = mark,
            ._pred = blk: {
                var preds: std.ArrayList(OpId) = .empty;
                errdefer preds.deinit(gpa);
                try preds.appendSlice(gpa, predecessors);
                break :blk preds;
            },
        };
    }

    /// Frees the predecessor list and nothing else: every borrowed payload
    /// belongs to the caller (`AGENTS.md` §Invariants, "slices returned into
    /// a document's own storage").
    ///
    /// `gpa` must be the allocator [`init`] built the list with, for the
    /// reason every resetting teardown in this file gives.
    ///
    /// Afterwards the builder is `undefined`: no accessor may be called on
    /// it, and a second call frees `undefined`, which no optimize mode
    /// diagnoses — the reset makes the mistake louder in a debug build and
    /// promises nothing in a fast one. Call it exactly once per builder. A
    /// copy taken beforehand names the same `_pred` allocation and is **not**
    /// a second owner: freeing both frees it twice.
    pub fn deinit(self: *OpBuilder, gpa: Allocator) void {
        self._pred.deinit(gpa);
        self.* = undefined;
    }

    /// The operation's own id (`OpLike::id`, `op_set2/op.rs:1328`, `:520`).
    pub fn id(self: *const OpBuilder) OpId {
        return self._id;
    }

    /// The parent object as the object columns spell it: null for the root,
    /// whose two columns are both null (`AsChangeOp for B`,
    /// `op_set2/op.rs:1276-1281`; `op_set2/columns.rs:143-148`).
    /// Named public objects must be resolved by the owning OpSet before
    /// reaching the column writer; this accessor only exposes `.id` values.
    pub fn obj(self: *const OpBuilder) ?OpId {
        return switch (self._obj) {
            .id => |object_id| object_id,
            .root, .named => null,
        };
    }

    /// The parent object as `Op::obj` holds it (`op_set2/op.rs:837`), root
    /// included.
    pub fn objId(self: *const OpBuilder) ObjId {
        return self._obj;
    }

    /// The parent object's actor, or null for the root
    /// (`OpLike::obj_actor`, `op_set2/op.rs:1332-1334`).
    pub fn objActor(self: *const OpBuilder) ?ActorIdx {
        return if (self.obj()) |object_id| object_id.actor else null;
    }

    /// The parent object's counter, or null for the root
    /// (`OpLike::obj_ctr`, `op_set2/op.rs:1335-1337`).
    pub fn objCtr(self: *const OpBuilder) ?u32 {
        return if (self.obj()) |object_id| object_id.counter else null;
    }

    /// The object this operation makes, and of what type, or null for an
    /// operation that makes nothing (`OpLike::obj_info`, `op_set2/op.rs:1360`;
    /// `Op::obj_info`, `:765-769`).
    pub fn objInfo(self: *const OpBuilder) ?ObjInfo {
        const obj_type = self._action.objType() orelse return null;
        return .{ .parent = self._obj, .obj_type = obj_type };
    }

    /// What the operation does (`OpLike::action`, `op_set2/op.rs:1338`).
    pub fn action(self: *const OpBuilder) Action {
        return self._action;
    }

    /// What the operation hangs by (`OpLike::key`, `op_set2/op.rs:1346`).
    pub fn key(self: *const OpBuilder) KeyRef {
        return self._key;
    }

    /// The map key, or null for a sequence anchor (`OpLike::key_str`,
    /// `op_set2/op.rs:1339`).
    pub fn keyStr(self: *const OpBuilder) ?[]const u8 {
        return self._key.keyStr();
    }

    /// The anchor's actor, or null for a map key (`OpLike::key_actor`,
    /// `op_set2/op.rs:1340-1342`).
    pub fn keyActor(self: *const OpBuilder) ?ActorIdx {
        return self._key.actor();
    }

    /// The anchor's counter, or null for a map key (`OpLike::key_ctr`,
    /// `op_set2/op.rs:1343-1345`).
    pub fn keyCtr(self: *const OpBuilder) ?i64 {
        return self._key.icounter();
    }

    /// Whether the operation inserts (`OpLike::insert`, `op_set2/op.rs:1349`).
    pub fn insert(self: *const OpBuilder) bool {
        return self._insert;
    }

    /// The scalar the operation carries (`OpLike::value`, `op_set2/op.rs:127-129`).
    pub fn value(self: *const OpBuilder) ScalarValue {
        return self._value;
    }

    /// The word the value column's metadata half encodes as
    /// (`OpLike::meta_value`, `op_set2/op.rs:548-550`;
    /// `op_set2/meta.rs:73-93`).
    pub fn metaValue(self: *const OpBuilder) ValueMeta {
        return opset_types.metaOf(self._value);
    }

    /// The bytes the value already holds, or null when it has none of its
    /// own and the bytes would have to be built (`opset/types.zig:340-352`,
    /// the borrowed half of `ScalarValue::as_raw`, `op_set2/types.rs:369-394`).
    ///
    /// Upstream's `as_raw` always answers, because it can return owned
    /// bytes; this half cannot. A caller that needs every value's bytes
    /// writes them with [`opset_types.appendRaw`]
    /// (`op_set2/types.rs:321-337`) and measures them with
    /// [`opset_types.rawLen`] (`:297-310`).
    pub fn rawValue(self: *const OpBuilder) ?[]const u8 {
        return opset_types.asRaw(self._value);
    }

    /// Whether a mark expands before its span (`OpLike::expand`,
    /// `op_set2/op.rs:1350`).
    pub fn expand(self: *const OpBuilder) bool {
        return self._expand;
    }

    /// The name a mark puts on its span (`OpLike::mark_name`,
    /// `op_set2/op.rs:1353`).
    pub fn markName(self: *const OpBuilder) ?[]const u8 {
        return self._mark_name;
    }

    /// The mark's name and the value it puts on the span, or null for a row
    /// with no name (`ChangeOp::mark_data`, `op_set2/op.rs:75-79`).
    ///
    /// Borrowed, as everything else on this type.
    pub fn markData(self: *const OpBuilder) ?MarkData {
        const name = self._mark_name orelse return null;
        return MarkData.init(name, self._value);
    }

    /// The mark-index word for a mark row, or null for a row that is not a
    /// mark (`OpBuilder::mark_index`, `op_set2/op.rs:191-202`; encoded by
    /// `MarkIdx::as_i64`, `op_set2/op_set/mark_index.rs:25-38`).
    ///
    /// A mark *begin* carries its name and its own id; a mark *end* carries
    /// no name and names the begin it closes at `id.prev()`.
    pub fn markIndex(self: *const OpBuilder) ?i64 {
        if (self._action != .mark) return null;
        if (self._mark_name != null) return markIdxWord(self._id);
        // A mark end is written as the operation immediately after its
        // begin, so it names it at `id.prev()` (`op_set2/op.rs:199`). The
        // port saturates rather than wrapping: a mark end at counter zero is
        // a corrupt document, and `MarkOrderValidator`
        // (`op_set2/op_set/index.rs:52-75`) reports it as an end with no
        // begin rather than this read trapping.
        return -markIdxWord(prevSaturating(self._id));
    }

    /// How wide this operation is in `seq_type` (`OpBuilder::width`,
    /// `op_set2/op.rs:204-210`).
    ///
    /// A list element is one unit wide. In text, a mark is zero wide — it
    /// rides on another operation's span — and anything else is its string's
    /// width in `text_encoding`.
    ///
    /// Upstream's inherent `OpBuilder::width` returns `usize` and
    /// `OpLike::width` casts it to `u64` (`op_set2/op.rs:1355`); the port
    /// returns one type, which the text-width index stores
    /// (`op_set2/columns.rs:38`).
    pub fn width(self: *const OpBuilder, seq_type: SequenceType, text_encoding: TextEncoding) i64 {
        return switch (seq_type) {
            .list => 1,
            .text => if (self.isMark()) 0 else @intCast(text_encoding.width(self.asStr())),
        };
    }

    /// Whether the operation is visible. A builder has no successors yet, so
    /// this is upstream's `OpLike for TxOp` answer
    /// (`op_set2/op.rs:573-575`, `:494-496`): anything but an increment.
    pub fn visible(self: *const OpBuilder) bool {
        return !self.isInc();
    }

    /// Whether the operation is the winner of its register
    /// (`OpLike::top`, `op_set2/op.rs:1357-1359`).
    pub fn top(self: *const OpBuilder) bool {
        return self.visible();
    }

    /// What the operation hangs by for ordering: the element it made, if it
    /// inserts, and its raw key otherwise (`Op::elemid_or_key`,
    /// `op_set2/op.rs:1040-1046`; `ChangeOp::elemid_or_key`, `:143-152`).
    ///
    /// This is the second half of the row-order invariant, and the reason
    /// an insert's own id is in the key column of the order rather than
    /// alongside it.
    pub fn elemidOrKey(self: *const OpBuilder) KeyRef {
        if (self._insert) return KeyRef.fromElemId(ElemId.fromOpId(self._id));
        return self._key;
    }

    /// The string this operation contributes to a text sequence, or the
    /// object replacement character (`OpBuilder::as_str`, `op_set2/op.rs:220-226`).
    pub fn asStr(self: *const OpBuilder) []const u8 {
        if (self._action == .mark) return "";
        return switch (self._value) {
            .str => |s| s,
            else => "\u{fffc}",
        };
    }

    /// Whether the operation is an increment (`op_set2/op.rs:212-214`).
    pub fn isInc(self: *const OpBuilder) bool {
        return self._action == .increment;
    }

    /// Whether the operation's value is a counter (`Op::is_counter`,
    /// `op_set2/op.rs:1126-1128`).
    pub fn isCounter(self: *const OpBuilder) bool {
        return self._value == .counter;
    }

    /// Whether the operation is a mark (`op_set2/op.rs:216-218`).
    pub fn isMark(self: *const OpBuilder) bool {
        return self._action == .mark;
    }

    /// Whether the operation deletes (`OpBuilder::is_delete`,
    /// `op_set2/op.rs:228-230`).
    pub fn isDelete(self: *const OpBuilder) bool {
        return self._action == .delete;
    }

    /// The amount an increment carries, or null for anything else
    /// (`OpBuilder::get_increment_value`, `op_set2/op.rs:232-238`).
    ///
    /// Upstream converts an unsigned increment with `as i64`
    /// (`op_set2/op.rs:157`), which truncates; so does this. A document whose
    /// increment does not fit in `i64` is corrupt, and the counter it is read
    /// into overflows on the first add anyway (`op_set2/op.rs:993`).
    pub fn getIncrementValue(self: *const OpBuilder) ?i64 {
        if (self._action != .increment) return null;
        return switch (self._value) {
            .int => |i| i,
            .uint => |u| @bitCast(u),
            else => null,
        };
    }

    /// The element this operation addresses, for an operation that is not a
    /// make or a delete (`Op::cursor`, `op_set2/op.rs:1073-1082`).
    ///
    /// An insert's cursor is the element it created; anything else on a
    /// sequence is the element it updates. A map key addresses no element,
    /// which is `error.InvalidCursorOp` upstream (`op_set2/op.rs:1079`).
    pub fn cursor(self: *const OpBuilder) Error!ElemId {
        if (self._insert) return ElemId.fromOpId(self._id);
        return switch (self._key) {
            .seq => |e| e,
            .map => error.InvalidCursorOp,
        };
    }

    /// How many successors the operation has. A builder has none yet: every
    /// successor is added by `OpSet::add_succ` after the row is written
    /// (`op_set2/op_set.rs:259-283`).
    pub fn succCount(self: *const OpBuilder) usize {
        _ = self;
        return 0;
    }

    /// The `i`-th successor. A builder has none
    /// (`OpLike::succ for TxOp`, `op_set2/op.rs:516-518`).
    pub fn succAt(self: *const OpBuilder, i: usize) OpId {
        _ = self;
        _ = i;
        std.debug.assert(false); // a builder has no successors: op.rs:516-518
        return OpId.root;
    }

    /// How many successors carry an increment. A builder has none
    /// (`OpLike::succ_inc for TxOp`, `op_set2/op.rs:511-514`).
    pub fn succIncCount(self: *const OpBuilder) usize {
        _ = self;
        return 0;
    }

    /// The `i`-th successor's increment. A builder has none
    /// (`op_set2/op.rs:511-514`).
    pub fn succIncAt(self: *const OpBuilder, i: usize) ?i64 {
        _ = self;
        _ = i;
        std.debug.assert(false); // a builder has no successors: op.rs:511-514
        return null;
    }

    /// An empty successor cursor (`OpLike::succ for TxOp`,
    /// `op_set2/op.rs:516-518`).
    pub fn succ(self: *const OpBuilder) SuccCursors {
        _ = self;
        return SuccCursors.none();
    }

    /// An empty successor cursor with increments (`op_set2/op.rs:511-514`).
    pub fn succInc(self: *const OpBuilder) SuccIncCursors {
        _ = self;
        return SuccCursors.none().withInc();
    }

    /// The actor half of the operation's id (`OpLike::id_actor`,
    /// `op_set2/op.rs:1328`; `op_set2/op.rs:504-506`).
    pub fn idActor(self: *const OpBuilder) ActorIdx {
        return self._id.actor;
    }

    /// The counter half of the operation's id, as the delta column's running
    /// value reads it (`OpLike::id_ctr`, `op_set2/op.rs:1329`).
    pub fn idCtr(self: *const OpBuilder) i64 {
        return @intCast(self._id.counter);
    }

    /// The operation's counter (`AsChangeOp::op_id_ctr`,
    /// `op_set2/op.rs:1316-1318`).
    pub fn opIdCtr(self: *const OpBuilder) u32 {
        return self._id.counter;
    }

    /// How many predecessors the operation has
    /// (`AsChangeOp::pred_count`, `op_set2/op.rs:1307-1309`).
    pub fn predCount(self: *const OpBuilder) u32 {
        return std.math.cast(u32, self._pred.items.len) orelse std.math.maxInt(u32);
    }

    /// The operations this one overwrites or deletes (`AsChangeOp::pred`,
    /// `op_set2/op.rs:1319-1321`).
    pub fn pred(self: *const OpBuilder) []const OpId {
        return self._pred.items;
    }
};

// ── TxOp ───────────────────────────────────────────────────────────────────

/// What a transaction builds around a builder (`TxOp`, `op_set2/op.rs:163-175`).
///
/// The builder is the operation; the rest is what only the transaction needs
/// — where in the sequence it landed, whether it changes what a reader sees,
/// and how to undo it.
///
/// **The accessors below this point forward.** They exist because a generic
/// reader (`columns.zig:503`) is written against one interface over all four
/// op types, and this is the second of the two types that hold a builder
/// rather than columns. Each forwards one-for-one to the [`OpBuilder`]
/// accessor of the same name, so the answer, the borrowing rules and the
/// upstream line are the builder's; each carries its own first line saying
/// what it answers, and the two whose answers differ between the op types —
/// [`TxOp.succAt`], [`TxOp.succIncAt`] — say so in full. Nothing is cached and
/// nothing is copied: every borrowed slice is the builder's, and the op is
/// `undefined` after [`TxOp.deinit`].
///
/// Not thread-safe, and not shared: one `TxOp` belongs to one transaction.
pub const TxOp = struct {
    /// The type of the parent object (`op_set2/op.rs:165`).
    obj_type: ObjType,
    /// The index in the sequence the operation landed at (`op_set2/op.rs:166`).
    index: usize,
    /// The row the operation was spliced in at (`op_set2/op.rs:167`).
    pos: usize,
    /// Whether the operation resolves a conflict without changing the
    /// document (`op_set2/op.rs:168`).
    noop: bool,
    /// The operation itself.
    bld: OpBuilder,
    /// The edges to remove if the transaction rolls back
    /// (`op_set2/op.rs:170`).
    undo: std.ArrayList(SuccUndo),
    /// The register range a scoped transaction captured before inserting, so
    /// that a rollback can undo the conflict reordering
    /// (`op_set2/op.rs:171-174`).
    reset_range: ?OpRange,

    /// An operation that overwrites or deletes an element of a sequence
    /// (`TxOp::list`, `op_set2/op.rs:261-294`).
    ///
    /// `index` is where the element is in the sequence now, `elemid` is the
    /// element it addresses, and `pred` is what it overwrites or deletes.
    pub fn list(
        gpa: Allocator,
        op_id: OpId,
        parent: ObjMeta,
        pos: usize,
        index: usize,
        resolved: ResolvedAction,
        elemid: ElemId,
        predecessors: []const OpId,
    ) Allocator.Error!TxOp {
        const noop = resolved == .conflict_resolution;
        const d = decompose(switch (resolved) {
            .conflict_resolution => |t| t,
            .visible_update => |t| t,
        });
        return .{
            .obj_type = parent.typ,
            .pos = pos,
            .index = index,
            .noop = noop,
            .undo = .empty,
            .reset_range = null,
            .bld = try OpBuilder.init(
                gpa,
                op_id,
                parent.id,
                d.action,
                KeyRef.fromElemId(elemid),
                d.value,
                false,
                d.expand,
                d.mark_name,
                predecessors,
            ),
        };
    }

    /// An operation that overwrites or deletes a map key
    /// (`TxOp::map`, `op_set2/op.rs:296-328`).
    ///
    /// The `noop` flag comes from the [`ResolvedAction`] and the columns from
    /// the same action decomposed, which is upstream's arrangement
    /// (`op_set2/op.rs:304-308`): the flag says whether to emit a patch, the
    /// columns say what was written.
    pub fn map(
        gpa: Allocator,
        op_id: OpId,
        parent: ObjMeta,
        pos: usize,
        resolved: ResolvedAction,
        map_key: []const u8,
        predecessors: []const OpId,
    ) Allocator.Error!TxOp {
        const noop = resolved == .conflict_resolution;
        const d = decompose(switch (resolved) {
            .conflict_resolution => |t| t,
            .visible_update => |t| t,
        });
        return .{
            .obj_type = parent.typ,
            .index = 0,
            .pos = pos,
            .noop = noop,
            .undo = .empty,
            .reset_range = null,
            .bld = try OpBuilder.init(
                gpa,
                op_id,
                parent.id,
                d.action,
                KeyRef.fromStr(map_key),
                d.value,
                false,
                d.expand,
                d.mark_name,
                predecessors,
            ),
        };
    }

    /// An operation that inserts into a sequence
    /// (`TxOp::insert`, `op_set2/op.rs:330-358`).
    ///
    /// An insert has no predecessors: it creates an element rather than
    /// replacing one (`op_set2/op.rs:355`).
    ///
    /// Upstream names this `TxOp::insert` (`op_set2/op.rs:330`) and also
    /// gives `TxOp` an `insert()` accessor (`OpLike::insert`,
    /// `op_set2/op.rs:630-632`). Zig has one namespace per struct, so the
    /// constructor is `insertOp` and the accessor keeps the upstream
    /// accessor name, which is the one the generic readers call.
    pub fn insertOp(
        gpa: Allocator,
        op_id: OpId,
        parent: ObjMeta,
        pos: usize,
        index: usize,
        op_type: OpType,
        elemid: ElemId,
    ) Allocator.Error!TxOp {
        const d = decompose(op_type);
        return .{
            .obj_type = parent.typ,
            .pos = pos,
            .index = index,
            .noop = false,
            .undo = .empty,
            .reset_range = null,
            .bld = try OpBuilder.init(
                gpa,
                op_id,
                parent.id,
                d.action,
                KeyRef.fromElemId(elemid),
                d.value,
                true,
                d.expand,
                d.mark_name,
                &.{},
            ),
        };
    }

    /// An operation that inserts a scalar into a sequence
    /// (`TxOp::insert_val`, `op_set2/op.rs:360-388`).
    ///
    /// `OpType::Put(value)` decomposed, with `index` left at zero: the
    /// caller has no index for an insert it has not placed yet
    /// (`op_set2/op.rs:371`).
    pub fn insertVal(
        gpa: Allocator,
        op_id: OpId,
        parent: ObjMeta,
        pos: usize,
        scalar: ScalarValue,
        elemid: ElemId,
    ) Allocator.Error!TxOp {
        const d = decompose(.{ .put = scalar });
        return .{
            .obj_type = parent.typ,
            .pos = pos,
            .index = 0,
            .noop = false,
            .undo = .empty,
            .reset_range = null,
            .bld = try OpBuilder.init(
                gpa,
                op_id,
                parent.id,
                d.action,
                KeyRef.fromElemId(elemid),
                d.value,
                true,
                d.expand,
                d.mark_name,
                &.{},
            ),
        };
    }

    /// An operation that inserts a new object into a sequence
    /// (`TxOp::insert_obj`, `op_set2/op.rs:390-419`).
    pub fn insertObj(
        gpa: Allocator,
        op_id: OpId,
        parent: ObjMeta,
        pos: usize,
        index: usize,
        made: ObjType,
        elemid: ElemId,
    ) Allocator.Error!TxOp {
        const d = decompose(.{ .make = made });
        return .{
            .obj_type = parent.typ,
            .pos = pos,
            .index = index,
            .noop = false,
            .undo = .empty,
            .reset_range = null,
            .bld = try OpBuilder.init(
                gpa,
                op_id,
                parent.id,
                d.action,
                KeyRef.fromElemId(elemid),
                d.value,
                true,
                d.expand,
                d.mark_name,
                &.{},
            ),
        };
    }

    /// An operation that deletes an element of a sequence
    /// (`TxOp::list_del`, `op_set2/op.rs:421-449`).
    ///
    /// `pos` is left at zero: a delete is never materialised as a row
    /// (`op_set2/columns.rs:426-427`), so it has no row position.
    pub fn listDel(
        gpa: Allocator,
        op_id: OpId,
        parent: ObjMeta,
        index: usize,
        elemid: ElemId,
        predecessors: []const OpId,
    ) Allocator.Error!TxOp {
        const d = decompose(.delete);
        return .{
            .obj_type = parent.typ,
            .pos = 0,
            .index = index,
            .noop = false,
            .undo = .empty,
            .reset_range = null,
            .bld = try OpBuilder.init(
                gpa,
                op_id,
                parent.id,
                d.action,
                KeyRef.fromElemId(elemid),
                d.value,
                false,
                d.expand,
                d.mark_name,
                predecessors,
            ),
        };
    }

    /// Frees the builder's predecessor list and the undo list, and nothing
    /// else: the borrowed payloads belong to the caller.
    ///
    /// `gpa` must be the allocator [`OpBuilder.init`] built both with, for the
    /// reason [`OpBuilder.deinit`] gives. Afterwards the op is `undefined`:
    /// no accessor may be called on it, and a second call frees `undefined`
    /// without any optimize mode diagnosing it, so call it exactly once. A
    /// copy taken beforehand names the same two allocations and is not a
    /// second owner.
    pub fn deinit(self: *TxOp, gpa: Allocator) void {
        self.undo.deinit(gpa);
        self.bld.deinit(gpa);
        self.* = undefined;
    }

    /// The operation's own id (`TxOp::id`, `op_set2/op.rs:256-258`).
    pub fn id(self: *const TxOp) OpId {
        return self.bld.id();
    }

    /// The property the operation addresses: the map key it writes, or the
    /// sequence index it landed at (`TxOp::prop`, `op_set2/op.rs:451-457`).
    pub fn prop(self: *const TxOp) PropRef {
        return switch (self.bld.key()) {
            .map => |s| .{ .key = s },
            .seq => .{ .index = self.index },
        };
    }

    /// Whether the operation deletes (`TxOp::is_delete`, `op_set2/op.rs:467-469`).
    pub fn isDelete(self: *const TxOp) bool {
        return self.bld.isDelete();
    }

    /// Whether the operation is a mark (`TxOp::is_mark`, `op_set2/op.rs:475-477`).
    pub fn isMark(self: *const TxOp) bool {
        return self.bld.isMark();
    }

    /// The string the operation contributes to a text sequence
    /// (`TxOp::as_str`, `op_set2/op.rs:471-473`).
    pub fn asStr(self: *const TxOp) []const u8 {
        return self.bld.asStr();
    }

    /// The amount an increment carries, or null
    /// (`TxOp::get_increment_value`, `op_set2/op.rs:463-465`).
    pub fn getIncrementValue(self: *const TxOp) ?i64 {
        return self.bld.getIncrementValue();
    }

    /// The parent object as the object columns spell it: null for the root
    /// (`OpBuilder.obj`, `op_set2/op.rs:1276-1281`).
    pub fn obj(self: *const TxOp) ?OpId {
        return self.bld.obj();
    }
    /// The parent object as `OpBuilder.objId` holds it (`op_set2/op.rs:837`),
    /// the root included.
    pub fn objId(self: *const TxOp) ObjId {
        return self.bld.objId();
    }
    /// The parent object's actor, or null for the root
    /// (`OpBuilder.objActor`, `op_set2/op.rs:1332-1334`).
    pub fn objActor(self: *const TxOp) ?ActorIdx {
        return self.bld.objActor();
    }
    /// The parent object's counter, or null for the root
    /// (`OpBuilder.objCtr`, `op_set2/op.rs:1335-1337`).
    pub fn objCtr(self: *const TxOp) ?u32 {
        return self.bld.objCtr();
    }
    /// The object this operation makes and of what type, or null for one that
    /// makes nothing (`OpBuilder.objInfo`, `op_set2/op.rs:1360`).
    pub fn objInfo(self: *const TxOp) ?ObjInfo {
        return self.bld.objInfo();
    }
    /// What the operation does (`OpBuilder.action`, `op_set2/op.rs:1338`).
    pub fn action(self: *const TxOp) Action {
        return self.bld.action();
    }
    /// What the operation hangs by: the map key it writes or the element it
    /// lands at (`OpBuilder.key`, `op_set2/op.rs:1346`).
    pub fn key(self: *const TxOp) KeyRef {
        return self.bld.key();
    }
    /// The map key, or null for a sequence anchor (`OpBuilder.keyStr`,
    /// `op_set2/op.rs:1339`). Borrowed from the builder, as everywhere here.
    pub fn keyStr(self: *const TxOp) ?[]const u8 {
        return self.bld.keyStr();
    }
    /// The anchor's actor, or null for a map key (`OpBuilder.keyActor`,
    /// `op_set2/op.rs:1340-1342`).
    pub fn keyActor(self: *const TxOp) ?ActorIdx {
        return self.bld.keyActor();
    }
    /// The anchor's counter, or null for a map key (`OpBuilder.keyCtr`,
    /// `op_set2/op.rs:1343-1345`).
    pub fn keyCtr(self: *const TxOp) ?i64 {
        return self.bld.keyCtr();
    }
    /// Whether the operation inserts rather than overwrites
    /// (`OpBuilder.insert`, `op_set2/op.rs:1349`).
    pub fn insert(self: *const TxOp) bool {
        return self.bld.insert();
    }
    /// The scalar the operation carries (`OpBuilder.value`,
    /// `op_set2/op.rs:127-129`). Every slice-bearing form is borrowed.
    pub fn value(self: *const TxOp) ScalarValue {
        return self.bld.value();
    }
    /// The metadata word this value occupies in the value column
    /// (`OpBuilder.metaValue`, `op_set2/meta.rs:73-93`). It is recomputed per
    /// call rather than stored, so it is the value's own word and not a
    /// remembered one.
    pub fn metaValue(self: *const TxOp) ValueMeta {
        return self.bld.metaValue();
    }
    /// The value's bytes as the value column would store them, or null for a
    /// value with no bytes (`OpBuilder.rawValue`, `op_set2/op.rs:806-808`).
    pub fn rawValue(self: *const TxOp) ?[]const u8 {
        return self.bld.rawValue();
    }
    /// Whether a mark's expansion passes its end (`OpBuilder.expand`,
    /// `op_set2/op.rs:1350`).
    pub fn expand(self: *const TxOp) bool {
        return self.bld.expand();
    }
    /// The mark's name, or null for a row that is not a mark
    /// (`OpBuilder.markName`, `op_set2/op.rs:1353`). Borrowed.
    pub fn markName(self: *const TxOp) ?[]const u8 {
        return self.bld.markName();
    }
    /// The mark's name with the value it puts on the span, or null for a row
    /// with no name (`OpBuilder.markData`, `op_set2/op.rs:75-79`).
    pub fn markData(self: *const TxOp) ?MarkData {
        return self.bld.markData();
    }
    /// The mark-index word for a mark operation, or null for one that is not a
    /// mark (`OpBuilder.markIndex`, `op_set2/op.rs:943-954`). An end names
    /// its begin at `id.prev()` and is the negation of its word.
    pub fn markIndex(self: *const TxOp) ?i64 {
        return self.bld.markIndex();
    }
    /// How wide the operation is in `seq_type` (`OpBuilder.width`,
    /// `op_set2/op.rs:1007-1013`).
    pub fn width(self: *const TxOp, seq_type: SequenceType, text_encoding: TextEncoding) i64 {
        return self.bld.width(seq_type, text_encoding);
    }
    /// Whether the operation is visible in the document
    /// (`OpBuilder.visible`, `op_set2/op.rs:573-575`). An operation a
    /// transaction has built has no successors yet, so only the increment arm
    /// can answer false here.
    pub fn visible(self: *const TxOp) bool {
        return self.bld.visible();
    }
    /// Whether the operation is the winner of its register (`OpBuilder.top`,
    /// `op_set2/op.rs:1357-1359`).
    pub fn top(self: *const TxOp) bool {
        return self.bld.top();
    }
    /// The element the operation made, if it inserts, and its raw key
    /// otherwise (`OpBuilder.elemidOrKey`, `op_set2/op.rs:1040-1046`).
    pub fn elemidOrKey(self: *const TxOp) KeyRef {
        return self.bld.elemidOrKey();
    }
    /// Whether the operation is an increment (`OpBuilder.isInc`,
    /// `op_set2/op.rs:212-214`).
    pub fn isInc(self: *const TxOp) bool {
        return self.bld.isInc();
    }
    /// Whether the operation's value is a counter (`OpBuilder.isCounter`,
    /// `op_set2/op.rs:1126-1128`).
    pub fn isCounter(self: *const TxOp) bool {
        return self.bld.isCounter();
    }
    /// The element the operation addresses (`OpBuilder.cursor`,
    /// `op_set2/op.rs:1073-1082`), or `error.InvalidCursorOp` for a map key.
    pub fn cursor(self: *const TxOp) Error!ElemId {
        return self.bld.cursor();
    }
    /// How many successors the operation has, which is always zero: a
    /// transaction's operation gains its successors only once it is written
    /// (`OpBuilder.succCount`, `op_set2/op.rs:516-518`).
    pub fn succCount(self: *const TxOp) usize {
        return self.bld.succCount();
    }
    /// The `i`-th successor's id — always an error in practice, because the
    /// count is always zero (`OpBuilder.succAt`, `op_set2/op.rs:516-518`).
    ///
    /// `i` must be below [`TxOp.succCount`], which means `i` must be below
    /// zero for no integer, so a correct caller never gets here. The
    /// `std.debug.assert` inside is checked in Debug and ReleaseSafe and
    /// compiled out in ReleaseFast and ReleaseSmall, where this answers
    /// `OpId.root` — a real id, the root's, which is why a caller must not
    /// reach this method at all rather than treat the answer as a row's
    /// successor.
    pub fn succAt(self: *const TxOp, i: usize) OpId {
        return self.bld.succAt(i);
    }
    /// How many successors carry an increment, which is always zero
    /// (`OpBuilder.succIncCount`, `op_set2/op.rs:511-514`).
    pub fn succIncCount(self: *const TxOp) usize {
        return self.bld.succIncCount();
    }
    /// The `i`-th successor's increment — always null in practice, because the
    /// count is always zero (`OpBuilder.succIncAt`, `op_set2/op.rs:511-514`).
    ///
    /// The same precondition as [`TxOp.succAt`]: `i` must be below
    /// [`TxOp.succIncCount`], and in an optimize mode with the assert
    /// compiled out this answers null, which a caller could not tell from a
    /// successor that deletes.
    pub fn succIncAt(self: *const TxOp, i: usize) ?i64 {
        return self.bld.succIncAt(i);
    }
    /// An empty successor cursor (`OpBuilder.succ`, `op_set2/op.rs:516-518`),
    /// so [`SuccCursors.len`] is 0 for a transaction's operation.
    pub fn succ(self: *const TxOp) SuccCursors {
        return self.bld.succ();
    }
    /// An empty successor cursor carrying increments (`OpBuilder.succInc`,
    /// `op_set2/op.rs:511-514`).
    pub fn succInc(self: *const TxOp) SuccIncCursors {
        return self.bld.succInc();
    }
    /// The actor half of the operation's id (`OpBuilder.idActor`,
    /// `op_set2/op.rs:1328`; `:504-506`).
    pub fn idActor(self: *const TxOp) ActorIdx {
        return self.bld.idActor();
    }
    /// The counter half of the operation's id, widened (`OpBuilder.idCtr`).
    pub fn idCtr(self: *const TxOp) i64 {
        return self.bld.idCtr();
    }
    /// The operation's own counter (`OpBuilder.opIdCtr`,
    /// `op_set2/op.rs:1316-1318`).
    pub fn opIdCtr(self: *const TxOp) u32 {
        return self.bld.opIdCtr();
    }
    /// How many predecessors the operation has (`OpBuilder.predCount`,
    /// `op_set2/op.rs:1307-1309`).
    pub fn predCount(self: *const TxOp) u32 {
        return self.bld.predCount();
    }
    /// The predecessor ids, borrowed from the builder's own list
    /// (`OpBuilder.pred`, `op_set2/op.rs:1319-1321`). They are valid until
    /// [`TxOp.deinit`], which frees that list.
    pub fn pred(self: *const TxOp) []const OpId {
        return self.bld.pred();
    }
};

// ── ChangeOp ───────────────────────────────────────────────────────────────

/// What a change decodes into, plus the bookkeeping the merge walks add
/// (`ChangeOp`, `op_set2/op.rs:50-57`).
///
/// Unlike [`Op`], a change op is not a row yet: it has no row position until
/// the merge walks assign one, and its successors are known rather than read.
///
/// **Most accessors after [`ChangeOp.succIncAt`] forward.** A generic reader
/// (`columns.zig:503`) uses one interface over all four op types. Successor
/// accessors read `succs`, and predecessor accessors select the owned builder
/// list or the transaction-only borrowed view. Other accessors forward to
/// [`OpBuilder`]. The op is `undefined` after [`ChangeOp.deinit`].
///
/// Not thread-safe or shared: one `ChangeOp` belongs to one change decode or
/// one pending transaction. A transaction view must not escape that journal.
pub const ChangeOp = struct {
    /// The successors its predecessors gained, in ascending id order.
    succs: std.ArrayList(SuccEntry),
    /// The row the op was placed at, or null while the walks are still
    /// placing it (`op_set2/op.rs:181`, `:180`).
    pos: ?usize,
    /// The order among the ops placed at the same `pos`
    /// (`op_set2/op.rs:182`; `Untangler`'s counter, `op_set2/change/batch.rs:53`).
    subsort: usize,
    /// Whether an earlier op at this position won the register
    /// (`op_set2/op.rs:183`).
    conflicted: bool,
    /// The operation itself.
    bld: OpBuilder,
    /// Nonempty predecessor ids borrowed only from the paired `Pending.tx`.
    /// Null uses the owned builder list. The owner must stay alive and its
    /// predecessor storage must not be mutated while this view lives.
    borrowed_pred: ?[]const OpId = null,

    /// A change op holding the columns of one decoded operation, owning a
    /// copy of `pred` and no successors yet.
    pub fn init(
        gpa: Allocator,
        op_id: OpId,
        op_obj: ObjId,
        op_action: Action,
        op_key: KeyRef,
        op_value: ScalarValue,
        is_insert: bool,
        expands: bool,
        mark: ?[]const u8,
        predecessors: []const OpId,
    ) Allocator.Error!ChangeOp {
        return .{
            .succs = .empty,
            .pos = null,
            .subsort = 0,
            .conflicted = false,
            .bld = try OpBuilder.init(
                gpa,
                op_id,
                op_obj,
                op_action,
                op_key,
                op_value,
                is_insert,
                expands,
                mark,
                predecessors,
            ),
        };
    }

    /// A transaction-only view of `tx`, without copying its predecessors.
    ///
    /// The result's builder owns an empty predecessor list; `pred()` borrows
    /// only `tx.bld._pred` storage. Keep that storage alive and unmodified
    /// until this view is disposed. Store it with its owner in `Pending`,
    /// dispose the view before the owner, and never let it escape the pending
    /// transaction. Other payloads retain `TxOp`'s existing borrow contract.
    /// This constructor allocates nothing; successor growth still takes an
    /// allocator, which must also be passed to `deinit`.
    pub fn initBorrowingTxPred(tx: *const TxOp) ChangeOp {
        const predecessors = tx.pred();
        return .{
            .succs = .empty,
            .pos = null,
            .subsort = 0,
            .conflicted = false,
            .bld = .{
                ._id = tx.id(),
                ._obj = tx.objId(),
                ._action = tx.action(),
                ._key = tx.key(),
                ._insert = tx.insert(),
                ._value = tx.value(),
                ._expand = tx.expand(),
                ._mark_name = tx.markName(),
                ._pred = .empty,
            },
            .borrowed_pred = if (predecessors.len != 0) predecessors else null,
        };
    }

    /// Frees the successor list and the builder's owned predecessor list.
    /// A transaction's borrowed predecessors are not freed here; the paired
    /// `Pending.tx` owns them and must be disposed after this view. Other
    /// borrowed payloads belong to the change, document or transaction journal.
    ///
    /// `gpa` must be the allocator used for the owned lists. Afterwards the op
    /// is `undefined`: no accessor may be called on it. Call exactly once;
    /// a copy names the same owned allocations and is not a second owner.
    pub fn deinit(self: *ChangeOp, gpa: Allocator) void {
        self.succs.deinit(gpa);
        self.bld.deinit(gpa);
        self.* = undefined;
    }

    /// Whether any successor deletes rather than increments
    /// (`ChangeOp::has_succ`, `op_set2/op.rs:109-111`).
    pub fn hasSucc(self: *const ChangeOp) bool {
        for (self.succs.items) |s| {
            if (s.inc == null) return true;
        }
        return false;
    }

    /// Whether the action makes a value visible — a set or any of the four
    /// makes (`ChangeOp::is_set_or_make`, `op_set2/op.rs:117-122`).
    pub fn isSetOrMake(self: *const ChangeOp) bool {
        return switch (self.bld.action()) {
            .set, .make_map, .make_list, .make_text, .make_table => true,
            else => false,
        };
    }

    /// The property the op addresses: the map key, or null for a sequence
    /// anchor (`ChangeOp::prop`, `op_set2/op.rs:1174-1177`).
    pub fn prop(self: *const ChangeOp) ?PropRef {
        const key_str = self.bld.key().keyStr() orelse return null;
        return .{ .key = key_str };
    }

    /// How wide the op is, and zero when it is not visible
    /// (`OpLike for ChangeOp::width`, `op_set2/op.rs:648-654`).
    ///
    /// An op that is not visible occupies no index, which is what makes the
    /// text-width index a function of visibility rather than of the value
    /// alone.
    pub fn width(self: *const ChangeOp, seq_type: SequenceType, text_encoding: TextEncoding) i64 {
        if (!self.visible()) return 0;
        return self.bld.width(seq_type, text_encoding);
    }

    /// Whether the op is visible (`OpLike for ChangeOp::visible`,
    /// `op_set2/op.rs:656-658`).
    ///
    /// Not an increment, not a delete, and no successor that deletes it. The
    /// last arm is what makes a *counter* visible while every successor
    /// increments it, and invisible as soon as one of them overwrites it.
    pub fn visible(self: *const ChangeOp) bool {
        return !(self.bld.isInc() or self.bld.isDelete() or self.hasSucc());
    }

    /// Whether the op is the winner of its register
    /// (`OpLike for ChangeOp::top`, `op_set2/op.rs:660-662`).
    pub fn top(self: *const ChangeOp) bool {
        return !self.conflicted and self.visible();
    }

    /// The `i`-th successor's id (`OpLike for ChangeOp::succ`,
    /// `op_set2/op.rs:681-683`).
    ///
    /// `i` must be below [`ChangeOp.succCount`], which is `succs.items.len`.
    /// The `std.debug.assert` is a programmer precondition, checked in Debug
    /// and ReleaseSafe and compiled out in ReleaseFast and ReleaseSmall; this
    /// is not a parser and is not reached from untrusted bytes. Unlike
    /// [`Op.succAt`] the bound really is the caller's to hold here, because
    /// `ChangeOp.succs` is a reachable field: a consumer may append to or
    /// truncate it between reading the count and reading the entry. The
    /// successor ids are values and outlive any borrow of the list.
    pub fn succAt(self: *const ChangeOp, i: usize) OpId {
        std.debug.assert(i < self.succs.items.len);
        return self.succs.items[i].id;
    }

    /// The `i`-th successor's increment, or null for one that deletes it
    /// (`OpLike for ChangeOp::succ_inc`, `op_set2/op.rs:677-679`).
    ///
    /// The same precondition as [`ChangeOp.succAt`]: `i` must be below
    /// [`ChangeOp.succIncCount`], checked only in the safety-checked optimize
    /// modes, and the caller's to hold. The increment column has one entry
    /// per successor (`op_set2/columns.rs:468-470`), which is why both counts
    /// are the same number.
    pub fn succIncAt(self: *const ChangeOp, i: usize) ?i64 {
        std.debug.assert(i < self.succs.items.len);
        return self.succs.items[i].inc;
    }

    /// The operation's own id, as assigned by the change it was decoded from
    /// (`OpBuilder.id`, `op_set2/op.rs:1328`).
    pub fn id(self: *const ChangeOp) OpId {
        return self.bld.id();
    }
    /// The parent object as the object columns spell it: null for the root
    /// (`OpBuilder.obj`, `op_set2/op.rs:1276-1281`).
    pub fn obj(self: *const ChangeOp) ?OpId {
        return self.bld.obj();
    }
    /// The parent object as `OpBuilder.objId` holds it (`op_set2/op.rs:837`),
    /// the root included.
    pub fn objId(self: *const ChangeOp) ObjId {
        return self.bld.objId();
    }
    /// The parent object's actor, or null for the root
    /// (`OpBuilder.objActor`, `op_set2/op.rs:1332-1334`).
    pub fn objActor(self: *const ChangeOp) ?ActorIdx {
        return self.bld.objActor();
    }
    /// The parent object's counter, or null for the root
    /// (`OpBuilder.objCtr`, `op_set2/op.rs:1335-1337`).
    pub fn objCtr(self: *const ChangeOp) ?u32 {
        return self.bld.objCtr();
    }
    /// The object this operation makes and of what type, or null for one that
    /// makes nothing (`OpBuilder.objInfo`, `op_set2/op.rs:1360`).
    pub fn objInfo(self: *const ChangeOp) ?ObjInfo {
        return self.bld.objInfo();
    }
    /// What the operation does (`OpBuilder.action`, `op_set2/op.rs:1338`).
    pub fn action(self: *const ChangeOp) Action {
        return self.bld.action();
    }
    /// What the operation hangs by: the map key it writes or the element it
    /// lands at (`OpBuilder.key`, `op_set2/op.rs:1346`).
    pub fn key(self: *const ChangeOp) KeyRef {
        return self.bld.key();
    }
    /// The map key, or null for a sequence anchor (`OpBuilder.keyStr`,
    /// `op_set2/op.rs:1339`). Borrowed from the decoded change.
    pub fn keyStr(self: *const ChangeOp) ?[]const u8 {
        return self.bld.keyStr();
    }
    /// The anchor's actor, or null for a map key (`OpBuilder.keyActor`,
    /// `op_set2/op.rs:1340-1342`).
    pub fn keyActor(self: *const ChangeOp) ?ActorIdx {
        return self.bld.keyActor();
    }
    /// The anchor's counter, or null for a map key (`OpBuilder.keyCtr`,
    /// `op_set2/op.rs:1343-1345`).
    pub fn keyCtr(self: *const ChangeOp) ?i64 {
        return self.bld.keyCtr();
    }
    /// Whether the operation inserts rather than overwrites
    /// (`OpBuilder.insert`, `op_set2/op.rs:1349`).
    pub fn insert(self: *const ChangeOp) bool {
        return self.bld.insert();
    }
    /// The scalar the operation carries (`OpBuilder.value`,
    /// `op_set2/op.rs:127-129`). Every slice-bearing form is borrowed.
    pub fn value(self: *const ChangeOp) ScalarValue {
        return self.bld.value();
    }
    /// The metadata word this value occupies in the value column
    /// (`OpBuilder.metaValue`, `op_set2/meta.rs:73-93`), recomputed per call.
    pub fn metaValue(self: *const ChangeOp) ValueMeta {
        return self.bld.metaValue();
    }
    /// The value's bytes as the value column would store them, or null for a
    /// value with no bytes (`OpBuilder.rawValue`, `op_set2/op.rs:806-808`).
    pub fn rawValue(self: *const ChangeOp) ?[]const u8 {
        return self.bld.rawValue();
    }
    /// Whether a mark's expansion passes its end (`OpBuilder.expand`,
    /// `op_set2/op.rs:1350`).
    pub fn expand(self: *const ChangeOp) bool {
        return self.bld.expand();
    }
    /// The mark's name, or null for a row that is not a mark
    /// (`OpBuilder.markName`, `op_set2/op.rs:1353`). Borrowed.
    pub fn markName(self: *const ChangeOp) ?[]const u8 {
        return self.bld.markName();
    }
    /// The mark's name with the value it puts on the span, or null for a row
    /// with no name (`OpBuilder.markData`, `op_set2/op.rs:75-79`).
    pub fn markData(self: *const ChangeOp) ?MarkData {
        return self.bld.markData();
    }
    /// The mark-index word for a mark operation, or null for one that is not a
    /// mark (`OpBuilder.markIndex`, `op_set2/op.rs:943-954`). An end names
    /// its begin at `id.prev()` and is the negation of its word.
    pub fn markIndex(self: *const ChangeOp) ?i64 {
        return self.bld.markIndex();
    }
    /// The element the operation made, if it inserts, and its raw key
    /// otherwise (`OpBuilder.elemidOrKey`, `op_set2/op.rs:1040-1046`).
    pub fn elemidOrKey(self: *const ChangeOp) KeyRef {
        return self.bld.elemidOrKey();
    }
    /// The string the operation contributes to a text sequence, or the object
    /// replacement character (`OpBuilder.asStr`, `op_set2/op.rs:997-1005`).
    pub fn asStr(self: *const ChangeOp) []const u8 {
        return self.bld.asStr();
    }
    /// Whether the operation is an increment (`OpBuilder.isInc`,
    /// `op_set2/op.rs:212-214`).
    pub fn isInc(self: *const ChangeOp) bool {
        return self.bld.isInc();
    }
    /// Whether the operation's value is a counter (`OpBuilder.isCounter`,
    /// `op_set2/op.rs:1126-1128`).
    pub fn isCounter(self: *const ChangeOp) bool {
        return self.bld.isCounter();
    }
    /// Whether the operation is a mark (`OpBuilder.isMark`,
    /// `op_set2/op.rs:475-477`).
    pub fn isMark(self: *const ChangeOp) bool {
        return self.bld.isMark();
    }
    /// Whether the operation deletes (`OpBuilder.isDelete`,
    /// `op_set2/op.rs:467-469`). A delete is a successor edge rather than a
    /// row, so a change op can be one before the merge writes it.
    pub fn isDelete(self: *const ChangeOp) bool {
        return self.bld.isDelete();
    }
    /// The amount an increment carries, or null for anything else
    /// (`OpBuilder.getIncrementValue`, `op_set2/op.rs:463-465`).
    pub fn getIncrementValue(self: *const ChangeOp) ?i64 {
        return self.bld.getIncrementValue();
    }
    /// The element the operation addresses (`OpBuilder.cursor`,
    /// `op_set2/op.rs:1073-1082`), or `error.InvalidCursorOp` for a map key.
    pub fn cursor(self: *const ChangeOp) Error!ElemId {
        return self.bld.cursor();
    }
    /// How many successors the change recorded for this operation
    /// (`op_set2/op.rs:681-683`).
    ///
    /// Unlike a stored row's, this is not read out of columns: a change op
    /// carries its successors as the op set hands them over
    /// (`op_set2/op.rs:681-683`), and [`ChangeOp.succAt`] indexes the same
    /// list. It is `succs.items.len`, so a consumer that appends to the
    /// reachable `succs` field changes this count.
    pub fn succCount(self: *const ChangeOp) usize {
        return self.succs.items.len;
    }
    /// How many successors carry an increment, which is the same number as
    /// [`ChangeOp.succCount`]: the increment index has one entry per
    /// successor (`op_set2/columns.rs:468-470`).
    pub fn succIncCount(self: *const ChangeOp) usize {
        return self.succs.items.len;
    }
    /// A cursor over the recorded successors, borrowing `succs.items`
    /// (`op_set2/op.rs:681-683`).
    ///
    /// `at` is 0 because a change op's successors have no position in a
    /// document's flattened successor columns yet — the merge walks assign
    /// `pos`, and until then this list is the only copy. `has_delete` is
    /// derived by [`SuccCursors.fromSpan`], as the type doc requires. The
    /// cursor borrows the list rather than the `ChangeOp`, so it is valid
    /// until the list is freed or [`ChangeOp.deinit`] runs, and appending to
    /// `succs` afterwards may reallocate it out from under the cursor — a
    /// programmer obligation rather than a guarantee.
    pub fn succ(self: *const ChangeOp) SuccCursors {
        return SuccCursors.fromSpan(self.succs.items, 0);
    }
    /// A cursor over the recorded successors carrying their increments, on the
    /// terms [`ChangeOp.succ`] gives.
    pub fn succInc(self: *const ChangeOp) SuccIncCursors {
        return SuccCursors.fromSpan(self.succs.items, 0).withInc();
    }
    /// The actor half of the operation's id (`OpBuilder.idActor`,
    /// `op_set2/op.rs:1328`; `:504-506`).
    pub fn idActor(self: *const ChangeOp) ActorIdx {
        return self.bld.idActor();
    }
    /// The counter half of the operation's id, widened (`OpBuilder.idCtr`).
    pub fn idCtr(self: *const ChangeOp) i64 {
        return self.bld.idCtr();
    }
    /// The operation's own counter (`OpBuilder.opIdCtr`,
    /// `op_set2/op.rs:1316-1318`).
    pub fn opIdCtr(self: *const ChangeOp) u32 {
        return self.bld.opIdCtr();
    }
    /// How many predecessors the operation declares (`OpBuilder.predCount`,
    /// `op_set2/op.rs:1307-1309`), including a transaction's borrowed view.
    pub fn predCount(self: *const ChangeOp) u32 {
        return std.math.cast(u32, self.pred().len) orelse std.math.maxInt(u32);
    }
    /// The predecessor ids (`OpBuilder.pred`, `op_set2/op.rs:1319-1321`).
    /// Owning views borrow their builder list until `ChangeOp.deinit`.
    /// Transaction views borrow the paired `Pending.tx` list; it must remain
    /// alive and unmodified until this view is disposed, before its owner.
    pub fn pred(self: *const ChangeOp) []const OpId {
        return self.borrowed_pred orelse self.bld.pred();
    }
};

// ── Op ─────────────────────────────────────────────────────────────────────

/// One row of the document, borrowed out of the columns
/// (`Op<'a>`, `op_set2/op.rs:831-844`).
///
/// **The storage behind an `Op` must outlive it.** `key`'s map key,
/// `value`'s `str`, `bytes` and `actor_id` payloads, `markName`'s name and
/// the successors in [`SuccCursors`] all point into a column of the document
/// or into the change the row was decoded out of. Rust states that with the
/// lifetime `'a` on the struct (`op_set2/op.rs:832`); Zig erases lifetimes,
/// so this is the statement that replaces the borrow checker, and a row read
/// out of a document cannot outlive a mutation of that document.
///
/// The column-derived values are reached through accessors and not through
/// fields: a generic reader (`columns.zig:503`) is written against those
/// names, and the underscore-prefixed fields exist so the two can be kept
/// apart.
pub const Op = struct {
    /// The row's position (`op_set2/op.rs:833`).
    pos: usize,
    /// Whether another op at this position won the register
    /// (`op_set2/op.rs:834`; set by `TopOps::next`,
    /// `op_set2/op_set/top_op.rs:62`, read by `hydrate.rs:254`).
    conflict: bool,
    _id: OpId,
    _action: Action,
    _obj: ObjId,
    _key: KeyRef,
    _insert: bool,
    _value: ScalarValue,
    _expand: bool,
    _mark_name: ?[]const u8,
    _succ: SuccCursors,

    /// A row as the columns spell it: `pos`, whether it lost its register,
    /// and one value per column. Every borrowed slice is passed straight
    /// through, so the caller keeps the storage alive.
    pub fn init(
        pos: usize,
        conflict: bool,
        op_id: OpId,
        op_action: Action,
        op_obj: ObjId,
        op_key: KeyRef,
        is_insert: bool,
        op_value: ScalarValue,
        expands: bool,
        mark: ?[]const u8,
        cursors: SuccCursors,
    ) Op {
        return .{
            .pos = pos,
            .conflict = conflict,
            ._id = op_id,
            ._action = op_action,
            ._obj = op_obj,
            ._key = op_key,
            ._insert = is_insert,
            ._value = op_value,
            ._expand = expands,
            ._mark_name = mark,
            ._succ = cursors,
        };
    }

    /// A delete op: an op that is never stored as a row and so has no
    /// successors (`Op::del`, `op_set2/op.rs:1158-1172`).
    ///
    /// A delete exists only as a successor edge on the ops it deletes
    /// (`op_set2/columns.rs:423-427`). This shape exists because the change
    /// *encoder* has to write one (`op_set2/change/collector.rs:842`,
    /// `storage/bundle/builder.rs:133`), and it goes on to
    /// [`Op.build`] into an [`OpBuilder`].
    pub fn del(op_id: OpId, parent: ObjId, at: KeyRef) Op {
        return Op.init(0, false, op_id, .delete, parent, at, false, .null_value, false, null, SuccCursors.none());
    }

    /// The row as an [`OpBuilder`] with the given predecessors
    /// (`Op::build`, `op_set2/op.rs:1134-1146`).
    ///
    /// This is the hand-off from a stored row to the shape the change
    /// encoder writes.
    pub fn build(self: Op, gpa: Allocator, predecessors: []const OpId) Allocator.Error!OpBuilder {
        return OpBuilder.init(
            gpa,
            self._id,
            self._obj,
            self._action,
            self._key,
            self._value,
            self._insert,
            self._expand,
            self._mark_name,
            predecessors,
        );
    }

    /// The operation's own id (`OpLike::id`, `op_set2/op.rs:1330`; `:778-780`).
    pub fn id(self: *const Op) OpId {
        return self._id;
    }

    /// The parent object as the object columns spell it: null for the root,
    /// whose two columns are both null (`OpSet::iter`, `op_set.rs:1318-1342`;
    /// `obj_actor`/`obj_ctr`, `op_set2/columns.rs:143-148`).
    /// Named public objects require owning-OpSet resolution before use.
    pub fn obj(self: *const Op) ?OpId {
        return switch (self._obj) {
            .id => |object_id| object_id,
            .root, .named => null,
        };
    }

    /// The parent object as `Op::obj` holds it (`op_set2/op.rs:837`).
    pub fn objId(self: *const Op) ObjId {
        return self._obj;
    }

    /// The parent object's actor, or null for the root
    /// (`OpLike::obj_actor`, `op_set2/op.rs:1332-1334`).
    pub fn objActor(self: *const Op) ?ActorIdx {
        return if (self.obj()) |object_id| object_id.actor else null;
    }

    /// The parent object's counter, or null for the root
    /// (`OpLike::obj_ctr`, `op_set2/op.rs:1335-1337`).
    pub fn objCtr(self: *const Op) ?u32 {
        return if (self.obj()) |object_id| object_id.counter else null;
    }

    /// The object this operation makes, and of what type, or null
    /// (`OpLike::obj_info`, `op_set2/op.rs:1360`; `Op::obj_info`, `:765-769`).
    pub fn objInfo(self: *const Op) ?ObjInfo {
        const obj_type = self._action.objType() orelse return null;
        return .{ .parent = self._obj, .obj_type = obj_type };
    }

    /// What the operation does (`OpLike::action`, `op_set2/op.rs:1338`; `:786-788`).
    pub fn action(self: *const Op) Action {
        return self._action;
    }

    /// What the operation hangs by (`OpLike::key`, `op_set2/op.rs:1346`; `:798-800`).
    pub fn key(self: *const Op) KeyRef {
        return self._key;
    }

    /// The map key, or null for a sequence anchor
    /// (`OpLike::key_str`, `op_set2/op.rs:1339`; `:790-796`).
    pub fn keyStr(self: *const Op) ?[]const u8 {
        return self._key.keyStr();
    }

    /// The anchor's actor, or null for a map key
    /// (`OpLike::key_actor`, `op_set2/op.rs:1340-1342`).
    pub fn keyActor(self: *const Op) ?ActorIdx {
        return self._key.actor();
    }

    /// The anchor's counter, or null for a map key
    /// (`OpLike::key_ctr`, `op_set2/op.rs:1343-1345`).
    pub fn keyCtr(self: *const Op) ?i64 {
        return self._key.icounter();
    }

    /// Whether the operation inserts (`OpLike::insert`, `op_set2/op.rs:1349`; `:818-820`).
    pub fn insert(self: *const Op) bool {
        return self._insert;
    }

    /// The scalar the operation carries (`OpLike::value`, `op_set2/op.rs:127-129`).
    pub fn value(self: *const Op) ScalarValue {
        return self._value;
    }

    /// The word the value column's metadata half encodes as
    /// (`OpLike::meta_value`, `op_set2/op.rs:806-808`; `op_set2/meta.rs:73-93`).
    pub fn metaValue(self: *const Op) ValueMeta {
        return opset_types.metaOf(self._value);
    }

    /// The bytes the value already holds, or null when it has none of its
    /// own and the bytes would have to be built (`opset/types.zig:340-352`,
    /// the borrowed half of `ScalarValue::as_raw`, `op_set2/types.rs:369-394`).
    ///
    /// See [`OpBuilder.rawValue`] for the whole of it.
    pub fn rawValue(self: *const Op) ?[]const u8 {
        return opset_types.asRaw(self._value);
    }

    /// Whether a mark expands before its span (`OpLike::expand`,
    /// `op_set2/op.rs:1350`; `:822-824`).
    pub fn expand(self: *const Op) bool {
        return self._expand;
    }

    /// The name a mark puts on its span (`OpLike::mark_name`,
    /// `op_set2/op.rs:1353`; `:826-828`).
    pub fn markName(self: *const Op) ?[]const u8 {
        return self._mark_name;
    }

    /// The mark's name and the value it puts on the span, or null for a row
    /// with no name (`ChangeOp::mark_data`, `op_set2/op.rs:75-79`).
    pub fn markData(self: *const Op) ?MarkData {
        const name = self._mark_name orelse return null;
        return MarkData.init(name, self._value);
    }

    /// The mark-index word for a mark row, or null for a row that is not a
    /// mark (`Op::mark_index`, `op_set2/op.rs:943-954`).
    ///
    /// See [`OpBuilder.markIndex`] for the word and for why the `id.prev()`
    /// on the end arm saturates.
    pub fn markIndex(self: *const Op) ?i64 {
        if (self._action != .mark) return null;
        if (self._mark_name != null) return markIdxWord(self._id);
        return -markIdxWord(prevSaturating(self._id));
    }

    /// How wide this row is in `seq_type` (`Op::width`, `op_set2/op.rs:1007-1013`).
    ///
    /// See [`OpBuilder.width`] for the rules.
    pub fn width(self: *const Op, seq_type: SequenceType, text_encoding: TextEncoding) i64 {
        return switch (seq_type) {
            .list => 1,
            .text => if (self.isMark()) 0 else @intCast(text_encoding.width(self.asStr())),
        };
    }

    /// Whether the row is visible (`Op::visible`, `op_set2/op.rs:1148-1156`).
    ///
    /// Three arms, and the middle one is the counter rule: an increment is
    /// never visible on its own, a counter is visible while every successor
    /// increments it, and anything else is visible only while it has no
    /// successors at all.
    ///
    /// **The counter arm reads a cached value, not the successors.** It is
    /// [`SuccCursors.has_delete`] — derived once by
    /// [`SuccCursors.fromSpan`] — and it is correct exactly to the extent
    /// that field agrees with the row's `entries`, which is the obligation the
    /// [`SuccCursors`] type doc states. That is the price of the arm being
    /// O(1) on a counter with many successors, and it is why the flag is
    /// derived where the entries are known rather than here.
    ///
    /// The last arm reads [`SuccCursors.len`], which is the row's total
    /// successor count and does not move as a successor cursor is walked.
    pub fn visible(self: *const Op) bool {
        if (self.isInc()) return false;
        if (self.isCounter()) return !self._succ.has_delete;
        return self._succ.len() == 0;
    }

    /// Whether the row is the winner of its register (`OpLike::top`,
    /// `op_set2/op.rs:1357-1359`).
    ///
    /// `Op` inherits the default, which is [`Op.visible`]: a row in the
    /// document is read through the index columns, which already say which
    /// register it won.
    pub fn top(self: *const Op) bool {
        return self.visible();
    }

    /// What the row hangs by for ordering: the element it made, if it
    /// inserts, and its raw key otherwise (`Op::elemid_or_key`,
    /// `op_set2/op.rs:1040-1046`).
    pub fn elemidOrKey(self: *const Op) KeyRef {
        if (self._insert) return KeyRef.fromElemId(ElemId.fromOpId(self._id));
        return self._key;
    }

    /// The string this row contributes to a text sequence, or the object
    /// replacement character (`Op::as_str`, `op_set2/op.rs:997-1005`).
    pub fn asStr(self: *const Op) []const u8 {
        if (self._action == .mark) return "";
        return switch (self._value) {
            .str => |s| s,
            else => "\u{fffc}",
        };
    }

    /// Whether the row is an increment (`Op::is_inc`, `op_set2/op.rs:1122-1124`).
    pub fn isInc(self: *const Op) bool {
        return self._action == .increment;
    }

    /// Whether the row's value is a counter (`Op::is_counter`,
    /// `op_set2/op.rs:1126-1128`).
    pub fn isCounter(self: *const Op) bool {
        return self._value == .counter;
    }

    /// Whether the row is a mark (`Op::is_mark`, `op_set2/op.rs:1130-1132`).
    pub fn isMark(self: *const Op) bool {
        return self._action == .mark;
    }

    /// Whether the row deletes. A stored row never does
    /// (`op_set2/columns.rs:423-427`); this exists so a delete op built by
    /// [`Op.del`] answers it.
    pub fn isDelete(self: *const Op) bool {
        return self._action == .delete;
    }

    /// The amount an increment carries, or null
    /// (`Op::get_increment_value`, `op_set2/op.rs:1088-1094`).
    pub fn getIncrementValue(self: *const Op) ?i64 {
        if (self._action != .increment) return null;
        return switch (self._value) {
            .int => |i| i,
            .uint => |u| @bitCast(u),
            else => null,
        };
    }

    /// The element this row addresses (`Op::cursor`, `op_set2/op.rs:1073-1082`).
    pub fn cursor(self: *const Op) Error!ElemId {
        if (self._insert) return ElemId.fromOpId(self._id);
        return switch (self._key) {
            .seq => |e| e,
            .map => error.InvalidCursorOp,
        };
    }

    /// How many successors the row has (`Op::succ`, `op_set2/op.rs:1019-1021`;
    /// `OpLike::succ`, `:814-816`).
    pub fn succCount(self: *const Op) usize {
        return self._succ.len();
    }

    /// The `i`-th successor's id (`Op::succ`, `op_set2/op.rs:1019-1021`).
    ///
    /// `i` must be below [`Op.succCount`], which is what every caller in the
    /// op set does: upstream iterates a `SuccCursors` (`op_set2/op.rs:875-888`)
    /// and `OpSet::add_succ` walks one the same way (`op_set2/op_set.rs:262`).
    /// This is not a parser and is not reached from untrusted bytes: the
    /// successors are read once, by [`loadSuccWindow`], which is total.
    pub fn succAt(self: *const Op, i: usize) OpId {
        std.debug.assert(i < self._succ.entries.len);
        return self._succ.entries[i].id;
    }

    /// How many successors carry an increment (`Op::succ_inc`,
    /// `op_set2/op.rs:1023-1025`). The same count as [`Op.succCount`]: the
    /// increment index has one entry per successor (`op_set2/columns.rs:468-470`).
    pub fn succIncCount(self: *const Op) usize {
        return self._succ.len();
    }

    /// The `i`-th successor's increment, or null for one that deletes
    /// (`Op::succ_inc`, `op_set2/op.rs:1023-1025`; `Iterator for SuccIncCursors`,
    /// `:896-911`).
    pub fn succIncAt(self: *const Op, i: usize) ?i64 {
        std.debug.assert(i < self._succ.entries.len);
        return self._succ.entries[i].inc;
    }

    /// A cursor over the row's successors (`Op::succ`, `op_set2/op.rs:1019-1021`).
    pub fn succ(self: *const Op) SuccCursors {
        return self._succ;
    }

    /// A cursor over the row's successors carrying their increments
    /// (`Op::succ_inc`, `op_set2/op.rs:1023-1025`).
    pub fn succInc(self: *const Op) SuccIncCursors {
        return self._succ.withInc();
    }

    /// The actor half of the row's id (`OpLike::id_actor`,
    /// `op_set2/op.rs:771-773`).
    pub fn idActor(self: *const Op) ActorIdx {
        return self._id.actor;
    }

    /// The counter half of the row's id (`OpLike::id_ctr`,
    /// `op_set2/op.rs:774-776`).
    pub fn idCtr(self: *const Op) i64 {
        return @intCast(self._id.counter);
    }

    /// The row's own counter (`AsChangeOp::op_id_ctr`, `op_set2/op.rs:1316-1318`).
    pub fn opIdCtr(self: *const Op) u32 {
        return self._id.counter;
    }

    /// A stored row has no predecessors: they are successor edges on the
    /// ops it replaced, read through [`Op.succAt`]
    /// (`AsChangeOp::pred for OpBuilder`, `op_set2/op.rs:1319-1321`).
    pub fn pred(self: *const Op) []const OpId {
        _ = self;
        return &.{};
    }

    /// A stored row has no predecessors (`AsChangeOp::pred_count`,
    /// `op_set2/op.rs:1307-1309`).
    pub fn predCount(self: *const Op) u32 {
        _ = self;
        return 0;
    }

    /// Plans where a successor edge on this row would go, and returns it;
    /// **nothing is written here** (`Op::add_succ`, `op_set2/op.rs:956-977`).
    ///
    /// The receiver is `*const Op` and the body mutates nothing — not the
    /// row, not its successors, not `pos`. What comes back is a
    /// [`SuccInsert`] describing the insertion; `OpSet::add_succ`
    /// (`op_set2/op_set.rs:259-283`) is what applies it, and a transaction's
    /// own delete uses `add_succ_with_undo` (`:285-325`). A caller that skips
    /// the apply step gets a [`SuccInsert`] and an unchanged row, so
    /// [`Op.visible`] still answers for the successors the row has.
    ///
    /// Successors are kept in ascending id order, so `sub_pos` is the first
    /// position past every successor at or below `id`. `inc` is dropped to
    /// null when the row is not a counter: an increment preserves a counter
    /// predecessor but acts as an ordinary overwrite for anything else
    /// (`op_set2/op.rs:959-961`, and the same normalisation on incoming ops
    /// at `op_set2/change/batch.rs:274-278`).
    ///
    /// The scan runs over a *copy* of the row's successor cursor
    /// (`var cursors = self._succ`), so walking to find the insertion point
    /// does not consume the row's own cursor.
    pub fn addSucc(self: *const Op, successor: OpId, inc_in: ?i64) SuccInsert {
        var inc = inc_in;
        if (inc != null and !self.isCounter()) inc = null;
        var cursors = self._succ;
        var sub_pos = cursors.pos();
        while (cursors.next()) |existing| {
            if (existing.order(successor) == .gt) break;
            sub_pos = cursors.pos();
        }
        return .{
            .id = successor,
            .pos = self.pos,
            .inc = inc,
            .len = @intCast(self._succ.len()),
            .sub_pos = sub_pos,
        };
    }

    /// Adds a successor's increments to a counter value, in place
    /// (`Op::fix_counter`, `op_set2/op.rs:979-995`).
    ///
    /// A counter's value in the columns is only what it was set to; every
    /// increment that has landed on it is a successor edge carrying an
    /// amount. This folds those edges into the value. With a `clock` only
    /// the edges the clock covers are folded in, which is how a read of a
    /// past state sees the counter as it stood then
    /// (`OpQuery::FixCounters`, `op_set2/op_set/op_query.rs:100-107`); with
    /// null it folds in all of them.
    ///
    /// Upstream adds with a plain `i64` add (`op_set2/op.rs:993`), which is
    /// checked in a debug build and wraps in a release one; this wraps in
    /// both, because a document whose increments overflow `i64` is corrupt
    /// and there is no value to report.
    pub fn fixCounter(self: *Op, c: ?Clock) void {
        const counter = switch (self._value) {
            .counter => |n| n.current,
            else => return,
        };
        // Upstream ignores the null-increment arm here (`op_set2/op.rs:983`)
        // because it has no scoped delete to report; this is the same walk
        // `maybeScopeToClock` runs, and this caller reads only the sum.
        const fold = self.foldSuccIncs(c);
        self._value = .{ .counter = .init(counter +% fold.inc) };
    }

    /// The walk both counter folds run: the increments `c` covers, summed,
    /// and whether one of those covered edges deletes the row instead of
    /// incrementing it (`maybe_scope_counter_to_clock`,
    /// `op_set2/op_set/visible.rs:201-211`; `fix_counter`,
    /// `op_set2/op.rs:982-992`).
    ///
    /// Upstream's two copies of this loop are the same loop: they iterate
    /// `succ_inc()`, skip an entry the clock does not cover, and add the
    /// increment. The only difference is the null-increment arm, which
    /// `fix_counter` skips (`:983`) and `maybe_scope_counter_to_clock` reads
    /// as `deleted` (`:207-209`). Sharing the walk keeps one definition of
    /// which edges a clock covers.
    fn foldSuccIncs(self: *const Op, c: ?Clock) CounterFold {
        var fold: CounterFold = .{ .inc = 0, .deleted = false };
        var it = self._succ.withInc();
        while (it.next()) |entry| {
            if (!coveredBy(c, entry.id)) continue;
            if (entry.inc) |amount| {
                fold.inc +%= amount;
            } else {
                fold.deleted = true;
            }
        }
        return fold;
    }

    /// The scoped form of a counter's successors: the folded value, and
    /// whether a covered successor deletes the row
    /// (`maybe_scope_counter_to_clock`, `op_set2/op_set/visible.rs:196-213`).
    ///
    /// `counter` is the row's stored value, not its folded one: this adds to
    /// it what the clock saw and hands both back, because the caller is the
    /// one that decides whether to write the result (`:218-220`).
    fn maybeScopeCounterToClock(
        self: *const Op,
        counter: i64,
        c: ?Clock,
    ) struct { deleted: bool, counter_value: ?i64 } {
        const fold = self.foldSuccIncs(c);
        return .{ .deleted = fold.deleted, .counter_value = counter +% fold.inc };
    }

    /// Whether the row is in view within a clock, and rewrites a counter's
    /// value to the total that clock saw (`scope_to_clock`,
    /// `op_set2/op_set/visible.rs:215-222`).
    ///
    /// This is the entry point every scoped read goes through:
    /// `InsertQuery::resolve` (`op_set2/op_set/insert.rs:103`),
    /// `OpsFoundIter::next` (`op_set2/op_set/found_op.rs:61`),
    /// `VisibleOpIter::next` (`op_set2/op_set/visible.rs:187`) and the
    /// conflict check (`op_set2/op_set.rs:1129-1134`). It is public here for
    /// the same reason it is `pub(crate)` there: nothing outside the op set
    /// module may reimplement the rule.
    ///
    /// The rewrite is a field write on the row's `_value`, which is why this
    /// takes `*Op` and not `*const Op`: the row is a by-value borrow of the
    /// document's own columns (`op_set2/op.rs:831-844`, and this file's `Op`
    /// doc comment), and upstream's `self.value = ScalarValue::Counter(v)`
    /// (`:218-220`) mutates that borrow, never the document. The storage
    /// behind an `Op` stays owned by the document, so what changes here is
    /// this one row's view of it and nothing else.
    pub fn scopeToClock(self: *Op, c: ?Clock) bool {
        const scoped = self.maybeScopeToClock(c);
        const in_view = scoped.visible();
        if (scoped.counter_value) |v| {
            self._value = .{ .counter = .init(v) };
        }
        return in_view;
    }

    /// The row's visibility within a clock, without the rewrite
    /// (`maybe_scope_to_clock`, `op_set2/op_set/visible.rs:224-242`).
    ///
    /// A row predates the clock when the clock covers its own id (`:225`),
    /// and it is deleted within the clock when a covered successor exists
    /// (`:234`) — or, for a counter, when a covered successor carries no
    /// increment (`:203-211`). A successor the clock does *not* cover
    /// deletes nothing here: that is the whole difference between a scoped
    /// read and the unscoped [`Op.visible`], which treats any delete as
    /// final (`op_set2/op.rs:1148-1156`).
    ///
    /// **A null clock is a performance dispatch, not merely "no filter".**
    /// `None` upstream means "read the present", and it is what selects the
    /// indexed fast path over a scan (`VisIter::new`,
    /// `op_set2/op_set/visible.rs:59-67`; `seek_ops_by_index`,
    /// `op_set2/op_set.rs:639-653`). A caller holding no clock must reach
    /// this method, not skip it: a null clock makes [`coveredBy`] true for
    /// every id, so the answer here is the unscoped one — `predates` is
    /// true, and `deleted` is whatever any successor says, which for a
    /// non-increment row is exactly what [`Op.visible`] reports.
    ///
    /// **An increment row is the caller's business.** Upstream's
    /// `VisibleOpIter::next` drops `Action::Increment` rows before it asks
    /// (`op_set2/op_set/visible.rs:184-186`), because an increment is not a
    /// value in its own right — [`Op.visible`] says so from the action alone
    /// (`op_set2/op.rs:1149-1150`). This method reads the value and the
    /// successors only, so a caller walking rows for their values has to
    /// skip increments itself, exactly as upstream does.
    ///
    /// Upstream takes `&mut self` (`:224`) and does not use it: the port
    /// takes `*const Op` so a reader that must not mutate a row can still
    /// ask, and a `*Op` coerces to it, so no caller loses anything.
    pub fn maybeScopeToClock(self: *const Op, c: ?Clock) ClockVisibility {
        const predates = coveredBy(c, self._id);
        if (self.isCounter()) {
            const scoped = self.maybeScopeCounterToClock(self._value.counter.current, c);
            return .{
                .predates = predates,
                .deleted = scoped.deleted,
                .counter_value = scoped.counter_value,
            };
        }
        var deleted = false;
        var it = self._succ;
        while (it.next()) |succ_id| {
            if (coveredBy(c, succ_id)) {
                deleted = true;
                break;
            }
        }
        return .{ .predates = predates, .deleted = deleted, .counter_value = null };
    }

    /// Whether this row may follow the row `stepper` describes, and advances
    /// the stepper to this row.
    ///
    /// This is the row-order invariant, in executable form, ported from
    /// `Op::step` (`op_set2/op.rs:1048-1073`). A walk calls it over every
    /// consecutive pair of the op set; `OpSet::validate_op_order`
    /// (`op_set2/op_set.rs:167-175`) is exactly that walk and is the gate the
    /// whole op set is checked against, run after every apply
    /// (`op_set2/change/batch.rs:949`) and on every loaded document
    /// (`storage/document.rs:332-344`).
    ///
    /// The order is **strict**: no two adjacent rows may tie, and a rejected
    /// pair still moves the stepper (`op_set2/op.rs:1051-1053`, `:1067-1068`),
    /// so a caller that ignores the answer still ends up on the last row it
    /// read.
    ///
    /// It is **four rules**, not one total order. Writing `K(op)` for
    /// [`Op.elemidOrKey`] — `KeyRef::Seq(ElemId(op.id))` when the op inserts,
    /// and the op's raw key otherwise (`op_set2/op.rs:1040-1046`) — they are:
    ///
    /// * **R1, object:** a row whose object differs from the previous row's
    ///   must name a *higher* object (`op_set2/op.rs:1049-1054`). The root is
    ///   the least object (`types.rs:519`, root is `OpId(0,0)`,
    ///   `types.rs:555-557`), so the root's rows always come first.
    /// * **R2, register:** within one object, rows group by `K`, and the
    ///   registers ascend: map registers by key string, sequence registers by
    ///   element id (`op_set2/op.rs:1059-1060`). A `Map` row and a `Seq` row
    ///   are **never** adjacent in one object: `KeyRef::order` has no answer
    ///   for the cross case (`op_set2/types.rs:584-592`) and `step`'s
    ///   `_ => false` arm turns that into a rejection (`op_set2/op.rs:1064`,
    ///   `:1087`). That is what makes the register order a *partial* order and
    ///   why an object is all-map or all-sequence.
    /// * **R3, id:** one register's rows are contiguous and ascend strictly in
    ///   `OpId`, which orders by counter then actor
    ///   (`op_set2/op.rs:1056-1057`; `src/types.zig:163-170`).
    /// * **R4, insertion tie-break:** an insert opening a new register is legal
    ///   iff it is anchored to the element the previous row belongs to, or its
    ///   own id sorts before that element (`op_set2/op.rs:1061-1063`). The
    ///   comparison is the insert's *raw* key against the stepper's `K`, not
    ///   `K` against `K` — which is what lets a chain of inserts pile up in
    ///   one place, each new one sorting before the element it displaces.
    ///
    /// Nothing here reads a successor: the invariant is about ids, keys and
    /// objects only, which is why `step` needs no allocator and cannot fail.
    pub fn step(self: *const Op, stepper: *OpStepper) bool {
        // Rows carry canonical table IDs. A public named ID must first be
        // resolved by the owning OpSet; this kernel cannot verify its hint.
        const object_order: ?std.math.Order = switch (self._obj) {
            .root => switch (stepper.obj) {
                .root => .eq,
                .id => .lt,
                .named => null,
            },
            .id => |object_id| switch (stepper.obj) {
                .root => .gt,
                .id => |previous_id| object_id.order(previous_id),
                .named => null,
            },
            .named => null,
        };
        if (object_order == null or object_order.? != .eq) {
            const ok = object_order != null and object_order.? == .gt;
            stepper.obj = self._obj;
            stepper.key = self.elemidOrKey();
            stepper.id = self._id;
            return ok;
        }
        const mine = self.elemidOrKey();
        // Upstream compares the row's *raw* key against the stepper's key
        // here, not the register key: `elemid_or_key()` has already decided
        // whether these are the same register, and for an insert that opens
        // one the raw key is the element it was placed after, which is the
        // whole of R4 (`op_set2/op.rs:1059`).
        const ok = if (mine.eql(stepper.key))
            // R3: one register, ascending ids.
            self._id.order(stepper.id) == .gt
        else switch (self._key) {
            // R2: map registers ascend by key string.
            .map => |s1| switch (stepper.key) {
                .map => |s2| std.mem.order(u8, s1, s2) == .gt,
                .seq => false,
            },
            .seq => |e1| switch (stepper.key) {
                // R2 and R4: a sequence register ascends by element id,
                // except that an insert opening one may sit either at the
                // element the previous row belongs to, or before it. The
                // second test is the insert's *own* id against that
                // element, not its raw key (`op_set2/op.rs:1062`).
                .seq => |e2| if (self._insert)
                    e1.eql(e2) or ElemId.fromOpId(self._id).compare(e2) == .lt
                else
                    false,
                .map => false,
            },
        };
        stepper.key = mine;
        stepper.id = self._id;
        return ok;
    }
};

comptime {
    assertOpLike(Op);
    assertOpLike(OpBuilder);
    assertOpLike(TxOp);
    assertOpLike(ChangeOp);
}

/// Whether an [`Op`] is considered visible, usually in relation to a
/// [`Clock`], if one is given (`Visibility`, `op_set2/op_set/visible.rs:245-265`).
///
/// The row is visible if it predates the given clock and is not considered
/// deleted within the clock's timeframe (`:248-249`). Produced by
/// [`Op.maybeScopeToClock`]; [`Op.scopeToClock`] reads it and also folds a
/// counter's `counter_value` back into the row.
///
/// Upstream keeps `Visibility` private to `visible.rs` and this port makes it
/// public for two reasons that are the same reason: it is the return type of
/// the public [`Op.maybeScopeToClock`], and the visibility iterators in
/// `visible.zig` have to name it. It is not the row's own unscoped
/// visibility, which is [`Op.visible`].
pub const ClockVisibility = struct {
    /// Whether the clock covers the row's own id
    /// (`op_set2/op_set/visible.rs:225`).
    predates: bool,
    /// Whether a successor the clock covers takes the row out of view —
    /// for a counter, a covered successor that carries no increment
    /// (`:207-209`); for anything else, any covered successor at all
    /// (`:234`).
    deleted: bool,
    /// If the row's value is a counter, the increments the clock covered,
    /// kept to update the row's own value (`:254-257`). Null for every
    /// other value type.
    counter_value: ?i64,

    /// Whether the row is in view (`op_set2/op_set/visible.rs:262-263`).
    pub fn visible(self: ClockVisibility) bool {
        return self.predates and !self.deleted;
    }
};

// ── The row-order invariant ────────────────────────────────────────────────

/// How far through the document's rows a walk has got
/// (`OpStepper`, `op_set2/op.rs:1363-1368`).
///
/// It holds the previous row's object, its register key and its id, and
/// [`Op.step`] compares the next row against those three and then overwrites
/// them. Running [`Op.step`] over every consecutive pair of the op set, from
/// [`OpStepper.initial`] to the end, is what
/// `OpSet::validate_op_order` does (`op_set2/op_set.rs:167-175`) — which is
/// the single gate the whole op set is checked against, run after every
/// apply (`op_set2/change/batch.rs:949`) and once on every loaded document
/// (`storage/document.rs:332-344`).
pub const OpStepper = struct {
    /// The previous row's parent object.
    obj: ObjId,
    /// The previous row's register key, `K(prev) = prev.elemid_or_key()`.
    key: KeyRef,
    /// The previous row's own id.
    id: OpId,

    /// The state a walk starts in (`Default for OpStepper`,
    /// `op_set2/op.rs:1370-1378`).
    ///
    /// The root object, the empty map key and the root op id. The root
    /// object is the least of all objects and the empty key is the least of
    /// all map keys, so the first row of the document passes whatever it
    /// is — which is what lets a document open on a made object rather than
    /// on the root map. Every later row is compared against a real row.
    pub fn initial() OpStepper {
        return .{ .obj = .root, .key = .{ .map = "" }, .id = .root };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A row as the row-order tests state it. Only the fields [`Op.step`] reads
/// are present, and every one of them is one a column supplies.
const Row = struct {
    obj: ObjId,
    id: OpId,
    /// The raw key: a map key, or the element a sequence row is anchored to.
    key: KeyRef,
    /// Whether the row inserts.
    insert: bool = false,
    action: Action = .set,
    value: ScalarValue = .null_value,
    /// Whether a delete has removed this row's element from view. A delete
    /// is not a row (`op_set2/columns.rs:423-427`); the row it removed is
    /// the one that carries the fact, which is the same information the
    /// `visible` index column holds.
    deleted: bool = false,

    fn toOp(self: Row, pos: usize) Op {
        return Op.init(pos, false, self.id, self.action, self.obj, self.key, self.insert, self.value, false, null, SuccCursors.none());
    }

    /// The register the row belongs to, `K(row)` (`op_set2/op.rs:1040-1046`).
    fn register(self: Row) KeyRef {
        return if (self.insert) KeyRef.fromElemId(ElemId.fromOpId(self.id)) else self.key;
    }

    /// The row's width in a list or a text sequence, which is what the
    /// visible-index walk in [`Model`] accumulates (`op_set2/op.rs:1007-1013`).
    fn width(self: Row) usize {
        _ = self;
        return 1;
    }

    /// The element this row addresses, as `Op::cursor` reports it
    /// (`op_set2/op.rs:1073-1082`): an insert's own element, and the element
    /// any other sequence row updates.
    fn elemId(self: Row) ElemId {
        if (self.insert) return ElemId.fromOpId(self.id);
        return switch (self.key) {
            .seq => |e| e,
            .map => ElemId.head(),
        };
    }
};

fn idOf(counter: u32) OpId {
    return OpId.init(counter, 0);
}

const root: ObjId = .root;

/// A made list object, as `put(map, "m", list)` at op 5 leaves it.
const list_obj: ObjId = .{ .id = idOf(5) };

/// Runs [`Op.step`] over every consecutive pair of `rows`, from
/// [`OpStepper.initial`], and reports whether every pair was legal.
///
/// This is `OpSet::validate_op_order` (`op_set2/op_set.rs:167-175`) over a
/// list of rows rather than over the columns.
fn stepAll(rows: []const Row) bool {
    var stepper = OpStepper.initial();
    for (rows, 0..) |r, i| {
        if (!r.toOp(i).step(&stepper)) return false;
    }
    return true;
}

test "R1: object ids ascend, so every object's rows follow the root's" {
    // Three objects in ascending order, root first.
    try testing.expect(stepAll(&.{
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "a" } },
        .{ .obj = list_obj, .id = idOf(2), .key = .{ .map = "a" } },
        .{ .obj = .{ .id = idOf(9) }, .id = idOf(3), .key = .{ .map = "a" } },
    }));

    // An object after a higher one is not ascending. `step` compares
    // objects with `self.obj > stepper.obj` (`op_set2/op.rs:1050`).
    try testing.expect(!stepAll(&.{
        .{ .obj = .{ .id = idOf(9) }, .id = idOf(3), .key = .{ .map = "a" } },
        .{ .obj = list_obj, .id = idOf(4), .key = .{ .map = "a" } },
    }));

    // A made object cannot come before the root's rows: the root is the
    // least object (`types.rs:519`, root is `OpId(0,0)`, `types.rs:555-557`).
    try testing.expect(!stepAll(&.{
        .{ .obj = list_obj, .id = idOf(2), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(3), .key = .{ .map = "a" } },
    }));

    // Two rows in the same object are R1's other half: the object-change
    // arm is not taken and R3 decides instead.
    try testing.expect(stepAll(&.{
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "a" } },
    }));
}

test "R2: registers ascend by key, and a map row never sits beside a sequence row" {
    // Map registers ascend by key string, whatever the ids do.
    try testing.expect(stepAll(&.{
        .{ .obj = root, .id = idOf(5), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "b" } },
        .{ .obj = root, .id = idOf(9), .key = .{ .map = "c" } },
    }));
    try testing.expect(!stepAll(&.{
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "b" } },
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "a" } },
    }));
    // Key strings compare as bytes, so case is part of the order.
    try testing.expect(stepAll(&.{
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "A" } },
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "a" } },
    }));
    try testing.expect(!stepAll(&.{
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "A" } },
    }));

    // A map row next to a sequence row, in both directions.
    // `KeyRef::order` has no answer for the cross case
    // (`op_set2/types.rs:584-592`), and the `_ => false` arm of `step`
    // turns that into a rejection (`op_set2/op.rs:1064`).
    try testing.expect(!stepAll(&.{
        // An insert's register is its own element id.
        .{ .obj = list_obj, .id = idOf(1), .key = .{ .seq = ElemId.head() }, .insert = true },
        .{ .obj = list_obj, .id = idOf(2), .key = .{ .map = "a" } },
    }));
    try testing.expect(!stepAll(&.{
        .{ .obj = list_obj, .id = idOf(2), .key = .{ .map = "a" } },
        .{ .obj = list_obj, .id = idOf(1), .key = .{ .seq = ElemId.head() }, .insert = true },
    }));

    // A row that is not an insert cannot open a register in a sequence
    // object, however its element id compares: the `(Seq, Seq)` arm is
    // guarded on `self.insert` (`op_set2/op.rs:1061`).
    try testing.expect(!stepAll(&.{
        .{ .obj = list_obj, .id = idOf(7), .key = .{ .seq = ElemId.fromOpId(idOf(1)) } },
        .{ .obj = list_obj, .id = idOf(8), .key = .{ .seq = ElemId.fromOpId(idOf(7)) } },
    }));
}

test "R3: a register's rows are contiguous and ascend strictly in id" {
    try testing.expect(stepAll(&.{
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(3), .key = .{ .map = "a" } },
    }));

    // Two rows with the same id: the order is strict, so a tie is refused.
    // `step` asks `self.id > stepper.id` (`op_set2/op.rs:1057`).
    try testing.expect(!stepAll(&.{
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "a" } },
    }));

    // Descending inside one register.
    try testing.expect(!stepAll(&.{
        .{ .obj = root, .id = idOf(3), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "a" } },
    }));

    // Contiguity: the same key reappearing after another key is a register
    // opening backwards, and R2 rejects it whatever the id.
    try testing.expect(!stepAll(&.{
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "b" } },
        .{ .obj = root, .id = idOf(3), .key = .{ .map = "a" } },
    }));
    // ... and with an id that would have satisfied R3 on its own.
    try testing.expect(!stepAll(&.{
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "a" } },
        .{ .obj = root, .id = idOf(2), .key = .{ .map = "b" } },
        .{ .obj = root, .id = idOf(9), .key = .{ .map = "a" } },
    }));

    // Ids order by counter first and then actor
    // (`src/types.zig:163-170`, upstream `types.rs:439-443`), so two
    // actors' rows interleave by counter and a higher actor wins a tie.
    try testing.expect(stepAll(&.{
        .{ .obj = root, .id = OpId.init(1, 1), .key = .{ .map = "a" } },
        .{ .obj = root, .id = OpId.init(1, 2), .key = .{ .map = "a" } },
    }));
    try testing.expect(!stepAll(&.{
        .{ .obj = root, .id = OpId.init(1, 2), .key = .{ .map = "a" } },
        .{ .obj = root, .id = OpId.init(1, 1), .key = .{ .map = "a" } },
    }));
}

test "R4: an insert opening a register is anchored to the previous element or sorts before it" {
    // Anchored to the element the previous row belongs to: `e1 == e2`
    // (`op_set2/op.rs:1062`). The comparison uses the insert's *raw* key,
    // which is the element it was placed after, against the previous row's
    // register key — not its own register key.
    try testing.expect(stepAll(&.{
        .{ .obj = list_obj, .id = idOf(1), .key = .{ .seq = ElemId.head() }, .insert = true },
        .{ .obj = list_obj, .id = idOf(2), .key = .{ .seq = ElemId.fromOpId(idOf(1)) }, .insert = true },
    }));

    // Its own id sorts before that element: `ElemId(self.id) < e2`.
    try testing.expect(stepAll(&.{
        .{ .obj = list_obj, .id = idOf(9), .key = .{ .seq = ElemId.fromOpId(idOf(1)) }, .insert = true },
        .{ .obj = list_obj, .id = idOf(2), .key = .{ .seq = ElemId.fromOpId(idOf(1)) }, .insert = true },
    }));

    // Anchored forward, and its id does not sort before the previous
    // element: neither arm holds.
    try testing.expect(!stepAll(&.{
        .{ .obj = list_obj, .id = idOf(9), .key = .{ .seq = ElemId.fromOpId(idOf(1)) }, .insert = true },
        .{ .obj = list_obj, .id = idOf(12), .key = .{ .seq = ElemId.fromOpId(idOf(7)) }, .insert = true },
    }));

    // Anchored at head, after a register that is already there: `e1` is
    // `head` and matches no element, and the new id is the highest, so
    // neither arm holds. Head-anchored inserts are the *first* register of
    // their object and no other, which is why the first insert of a list is
    // free and a second one is not.
    try testing.expect(!stepAll(&.{
        .{ .obj = list_obj, .id = idOf(9), .key = .{ .seq = ElemId.head() }, .insert = true },
        .{ .obj = list_obj, .id = idOf(12), .key = .{ .seq = ElemId.head() }, .insert = true },
    }));

    // The first row of a sequence object, anchored at head, is accepted: the
    // step into the object only compares objects.
    try testing.expect(stepAll(&.{
        .{ .obj = root, .id = idOf(1), .key = .{ .map = "m" } },
        .{ .obj = list_obj, .id = idOf(2), .key = .{ .seq = ElemId.head() }, .insert = true },
    }));

    // And an insert that anchors to an element two registers back reaches
    // forward only because its own id sorts before the element it passes.
    try testing.expect(stepAll(&.{
        .{ .obj = list_obj, .id = idOf(2), .key = .{ .seq = ElemId.head() }, .insert = true },
        .{ .obj = list_obj, .id = idOf(4), .key = .{ .seq = ElemId.fromOpId(idOf(2)) }, .insert = true },
        .{ .obj = list_obj, .id = idOf(3), .key = .{ .seq = ElemId.fromOpId(idOf(2)) }, .insert = true },
    }));
    try testing.expect(!stepAll(&.{
        .{ .obj = list_obj, .id = idOf(2), .key = .{ .seq = ElemId.head() }, .insert = true },
        .{ .obj = list_obj, .id = idOf(4), .key = .{ .seq = ElemId.fromOpId(idOf(2)) }, .insert = true },
        .{ .obj = list_obj, .id = idOf(5), .key = .{ .seq = ElemId.fromOpId(idOf(2)) }, .insert = true },
    }));
}

test "the stepper opens at the root object, the empty key and the root id" {
    const s = OpStepper.initial();
    try testing.expect(s.obj.eql(.root));
    try testing.expect(s.key.eql(KeyRef.fromStr("")));
    try testing.expect(s.id.eql(OpId.root));

    // Any first row passes, whatever its key, because the root is the least
    // object and the empty string is the least map key. A first row with a
    // *sequence* key does not: the cross-variant comparison has no answer.
    try testing.expect(stepAll(&.{.{ .obj = root, .id = idOf(1), .key = .{ .map = "z" } }}));
    try testing.expect(stepAll(&.{.{ .obj = root, .id = idOf(1), .key = .{ .map = "" } }}));
    try testing.expect(!stepAll(&.{.{ .obj = root, .id = idOf(1), .key = .{ .seq = ElemId.head() } }}));
    // An insert is no different: its register key is a `Seq` too, so the
    // cross-variant comparison rejects it against the empty map key. This is
    // why a document opens on the root map and never on a sequence: R2's
    // cross arm has no answer, whatever the row is.
    try testing.expect(!stepAll(&.{.{ .obj = root, .id = idOf(1), .key = .{ .seq = ElemId.head() }, .insert = true }}));
}

test "step advances the stepper even when it rejects the row" {
    // `step` writes the stepper before it answers (`op_set2/op.rs:1051-1053`,
    // `:1067-1068`), so a walk that ignores the answer still ends up on the
    // last row read.
    var stepper = OpStepper.initial();
    const first = (Row{ .obj = root, .id = idOf(1), .key = .{ .map = "a" } }).toOp(0);
    try testing.expect(first.step(&stepper));
    try testing.expect(stepper.id.eql(idOf(1)));
    try testing.expect(stepper.key.eql(KeyRef.fromStr("a")));

    // A row that is refused still moves the stepper.
    const bad = (Row{ .obj = root, .id = idOf(1), .key = .{ .map = "a" } }).toOp(1);
    try testing.expect(!bad.step(&stepper));
    try testing.expect(stepper.id.eql(idOf(1)));
}

test "row order requires canonical table IDs rather than public actor hints" {
    var stepper = OpStepper.initial();
    const named = ObjId.withActor(OpId.init(1, 999), .{ .bytes = "actor" });
    const unresolved = (Row{ .obj = named, .id = idOf(2), .key = .{ .map = "a" } }).toOp(0);
    // This kernel has no actor table with which to resolve the hint.
    try testing.expect(!unresolved.step(&stepper));
    try testing.expect(stepper.id.eql(idOf(2)));

    stepper = OpStepper.initial();
    const canonical = (Row{ .obj = .{ .id = idOf(1) }, .id = idOf(2), .key = .{ .map = "a" } }).toOp(0);
    try testing.expect(canonical.step(&stepper));
    const same_register = (Row{ .obj = .{ .id = idOf(1) }, .id = idOf(3), .key = .{ .map = "a" } }).toOp(1);
    try testing.expect(same_register.step(&stepper));
}

/// A row store that places a new op where upstream's local-insert paths put
/// it, so the session test exercises real positions rather than a hand-drawn
/// order.
///
/// The rules, each with the code that produces it:
///
/// * a map key: the end of that key's register, or — for a key the object
///   does not have yet — the point among the object's rows where the key
///   belongs in ascending order. `OpSet::seek_ops_by_map_key`
///   (`op_set2/op_set.rs:611-628`) takes `end_pos` from `prop_range`
///   (`:1268-1271`), which is `Columns::scope_to_value`
///   (`hexane/src/column.rs:1495-1506`) and answers an absent value with an
///   empty range **at the insertion point**
///   (`hexane/src/column.rs:991-1000`);
/// * a sequence insert at visible index `k`: the position of the first insert
///   row at or after `k` elements are complete, which is the first candidate
///   `InsertQuery::resolve` records (`op_set2/op_set/insert.rs:62-68`,
///   `:112-141`), and which for `k == 0` is the start of the object's rows
///   (`InsertQuery::new`, `:35-37`). When no insert row is that far on, the
///   position is one past the object's last row and the anchor is the last
///   visible row's cursor (`op_set2/op_set/insert.rs:151-157`);
/// * a sequence update at visible index `k`: the end of that element's
///   register (`OpSet::list_register_at_pos`, `op_set2/op_set.rs:688-704`);
/// * a delete: nowhere. `Columns::splice` drops every op whose action is
///   `Delete` (`op_set2/columns.rs:423-427`), so a delete adds a successor
///   edge and no row; this records the fact on the row it removed, which is
///   what the `visible` index column carries.
const Model = struct {
    rows: std.ArrayList(Row),

    fn init() Model {
        return .{ .rows = .empty };
    }

    fn deinit(self: *Model, gpa: Allocator) void {
        self.rows.deinit(gpa);
    }

    fn sameObject(a: ObjId, b: ObjId) bool {
        return switch (a) {
            .root => b == .root,
            .id => |id| b == .id and id.eql(b.id),
            .named => false,
        };
    }

    /// The first row of `obj`, or the end of the store if it has none.
    fn objStart(self: Model, obj: ObjId) usize {
        for (self.rows.items, 0..) |r, i| {
            if (sameObject(r.obj, obj)) return i;
        }
        return self.rows.items.len;
    }

    /// One past the last row of `obj`.
    fn objEnd(self: Model, obj: ObjId) usize {
        const start = self.objStart(obj);
        var i = start;
        while (i < self.rows.items.len) : (i += 1) {
            if (!sameObject(self.rows.items[i].obj, obj)) return i;
        }
        return self.rows.items.len;
    }

    /// The rows of `obj` whose element no delete has removed, in order.
    ///
    /// A sequence's visible elements are its insert rows, minus the deleted
    /// ones; an update rides on an element and so does not add one.
    fn visibleElems(self: Model, obj: ObjId, gpa: Allocator) ![]usize {
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(gpa);
        const end = self.objEnd(obj);
        var i = self.objStart(obj);
        while (i < end) : (i += 1) {
            const r = self.rows.items[i];
            if (r.insert and !r.deleted) try out.append(gpa, i);
        }
        return out.toOwnedSlice(gpa);
    }

    /// The row the object ends with, and the element a cursor there reports.
    ///
    /// `InsertQuery::resolve` falls back to "one past the object's last row"
    /// when the accumulation reached the target without passing an insert row
    /// (`op_set2/op_set/insert.rs:151-157`), which is what an append is.
    fn endOf(self: Model, obj: ObjId) struct { pos: usize, cursor: ElemId } {
        const end = self.objEnd(obj);
        var cursor: ElemId = ElemId.head();
        var i = self.objStart(obj);
        while (i < end) : (i += 1) {
            const r = self.rows.items[i];
            if (r.deleted) continue;
            cursor = r.elemId();
        }
        return .{ .pos = end, .cursor = cursor };
    }

    /// Where a write to `key` goes in `obj`.
    fn mapPos(self: Model, obj: ObjId, key: []const u8) usize {
        const want = KeyRef.fromStr(key);
        const start = self.objStart(obj);
        const end = self.objEnd(obj);
        var register_end: ?usize = null;
        var i = start;
        while (i < end) : (i += 1) {
            const r = self.rows.items[i];
            if (r.register().eql(want)) {
                register_end = i + 1;
                continue;
            }
            // Registers ascend by key, so the point where this key belongs is
            // before the first row whose key sorts after it.
            const other = r.register().keyStr() orelse continue;
            if (std.mem.order(u8, other, key) == .gt) break;
        }
        return register_end orelse i;
    }

    /// A write to `key`, or a second write to it.
    fn mapPut(
        self: *Model,
        gpa: Allocator,
        obj: ObjId,
        key: []const u8,
        id: OpId,
    ) !void {
        const at = self.mapPos(obj, key);
        try self.rows.insert(gpa, at, .{ .obj = obj, .id = id, .key = .{ .map = key } });
        try self.check();
    }

    /// A write to `key` that is not a plain put.
    fn mapPutValue(
        self: *Model,
        gpa: Allocator,
        obj: ObjId,
        key: []const u8,
        id: OpId,
        action: Action,
        v: ScalarValue,
    ) !void {
        const at = self.mapPos(obj, key);
        try self.rows.insert(gpa, at, .{
            .obj = obj,
            .id = id,
            .key = .{ .map = key },
            .action = action,
            .value = v,
        });
        try self.check();
    }

    /// A delete of `key`: no row, and the register's last row stops being
    /// visible.
    fn mapDelete(self: *Model, gpa: Allocator, obj: ObjId, key: []const u8) !void {
        _ = gpa;
        const at = self.mapPos(obj, key);
        if (at == 0) return error.OutOfRange;
        const last = self.rows.items[at - 1];
        if (!last.register().eql(KeyRef.fromStr(key))) return error.OutOfRange;
        self.rows.items[at - 1].deleted = true;
        try self.check();
    }

    /// An insert into a sequence object at visible index `index`.
    ///
    /// The position and the anchor come from a walk of the object's rows that
    /// mirrors `InsertQuery::resolve` (`op_set2/op_set/insert.rs:92-160`)
    /// exactly, because the position is not simply "the `index`-th visible
    /// element's row" and a model that computes it any other way puts inserts
    /// in the wrong place — which the row-order check then refuses.
    ///
    /// The walk, as upstream writes it:
    ///
    /// * `InsertQuery::new` seeds a candidate at the start of the object's row
    ///   range, anchored at head, when the target is index zero
    ///   (`op_set2/op_set/insert.rs:35-37`). A front insert therefore goes in
    ///   front of every row of the object, and only that.
    /// * otherwise an element's width is accumulated only when an insert row
    ///   flushes the width pending from the last visible non-mark row before
    ///   it (`op_set2/op_set/insert.rs:104-110`), so a register with several
    ///   rows counts once;
    /// * the moment the accumulation reaches the target, that insert row is
    ///   where the op goes, anchored to the cursor of the last visible row read
    ///   before it (`op_set2/op_set/insert.rs:62-68`);
    /// * and if the accumulation reaches the target without passing an insert
    ///   row, the position is one past the object's last row and the anchor is
    ///   the last visible element (`op_set2/op_set/insert.rs:151-157`), which
    ///   is what an append is.
    fn listInsert(
        self: *Model,
        gpa: Allocator,
        obj: ObjId,
        index: usize,
        id: OpId,
    ) !void {
        const start = self.objStart(obj);
        const end = self.objEnd(obj);

        if (index == 0) {
            try self.rows.insert(gpa, start, .{
                .obj = obj,
                .id = id,
                .key = .{ .seq = ElemId.head() },
                .insert = true,
            });
            return self.check();
        }

        var accumulated: usize = 0;
        var pending: usize = 0;
        var last_cursor: ElemId = ElemId.head();
        var at: ?usize = null;
        var anchor: ElemId = ElemId.head();

        var i = start;
        while (i < end) : (i += 1) {
            const r = self.rows.items[i];
            const visible = !r.deleted;
            if (r.insert) {
                accumulated += pending;
                pending = 0;
                if (accumulated >= index) {
                    at = i;
                    anchor = last_cursor;
                    break;
                }
            }
            if (visible) {
                last_cursor = r.elemId();
                pending = r.width();
            }
        }

        const tail = self.endOf(obj);
        const pos = at orelse tail.pos;
        const elem = if (at == null) tail.cursor else anchor;
        try self.rows.insert(gpa, pos, .{
            .obj = obj,
            .id = id,
            .key = .{ .seq = elem },
            .insert = true,
        });
        try self.check();
    }

    /// A write to the element at visible index `index`, which joins that
    /// element's own register.
    fn listUpdate(
        self: *Model,
        gpa: Allocator,
        obj: ObjId,
        index: usize,
        id: OpId,
    ) !void {
        const elems = try self.visibleElems(obj, gpa);
        defer gpa.free(elems);
        if (index >= elems.len) return error.OutOfRange;
        const row_at = elems[index];
        const want = KeyRef.fromElemId(ElemId.fromOpId(self.rows.items[row_at].id));
        const end = self.objEnd(obj);
        var at = row_at + 1;
        while (at < end and self.rows.items[at].register().eql(want)) at += 1;
        try self.rows.insert(gpa, at, .{
            .obj = obj,
            .id = id,
            .key = want,
        });
        try self.check();
    }

    /// A delete of the element at visible index `index`: no row, and that
    /// element stops being visible.
    fn listDelete(self: *Model, gpa: Allocator, obj: ObjId, index: usize) !void {
        const elems = try self.visibleElems(obj, gpa);
        defer gpa.free(elems);
        if (index >= elems.len) return error.OutOfRange;
        self.rows.items[elems[index]].deleted = true;
        try self.check();
    }

    /// Runs [`Op.step`] over every consecutive pair of every row, which is
    /// `OpSet::validate_op_order` (`op_set2/op_set.rs:167-175`).
    fn check(self: *const Model) !void {
        try testing.expect(stepAll(self.rows.items));
    }

    /// The rows of `obj` as `id` then `:key` for a map row and `@anchor` for
    /// a sequence row, so a session's shape is checked as well as its
    /// legality. The sequence half is the row's *raw* key — the element it
    /// was placed after — rather than its register key, so an insert reads
    /// as "id 8 was placed after element 6".
    fn shape(self: Model, gpa: Allocator, obj: ObjId) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const start = self.objStart(obj);
        const end = self.objEnd(obj);
        var buf: [64]u8 = undefined;
        for (self.rows.items[start..end], 0..) |r, i| {
            if (i != 0) try out.append(gpa, ' ');
            const text = switch (r.key) {
                .map => |k| try std.fmt.bufPrint(&buf, "{d}:{s}", .{ r.id.counter, k }),
                .seq => |e| try std.fmt.bufPrint(&buf, "{d}@{d}", .{ r.id.counter, e.icounter() }),
            };
            try out.appendSlice(gpa, text);
        }
        return out.toOwnedSlice(gpa);
    }
};

test "a scripted single-actor session keeps every consecutive pair in row order" {
    const gpa = testing.allocator;
    var m = Model.init();
    defer m.deinit(gpa);

    // `check` runs inside every operation below, so `step` is asserted on
    // every consecutive pair after *every* operation, not only at the end.

    // A map: a first key, then one that sorts before it, then a second
    // write to the first key, then a second write to the second.
    try m.mapPut(gpa, root, "b", idOf(1));
    try expectShape(gpa, m, root, "1:b");
    try m.mapPut(gpa, root, "a", idOf(2));
    try expectShape(gpa, m, root, "2:a 1:b");
    try m.mapPut(gpa, root, "b", idOf(3));
    try expectShape(gpa, m, root, "2:a 1:b 3:b");
    try m.mapPut(gpa, root, "a", idOf(4));
    try expectShape(gpa, m, root, "2:a 4:a 1:b 3:b");

    // A list made as a map value. Its own id is 5, and its rows come after
    // every root row because the objects ascend.
    try m.mapPut(gpa, root, "m", idOf(5));
    try expectShape(gpa, m, root, "2:a 4:a 1:b 3:b 5:m");
    try expectShape(gpa, m, list_obj, "");

    // The list: into an empty sequence, then appended to, then a middle
    // insert, then one at the front, then appended to again.
    try m.listInsert(gpa, list_obj, 0, idOf(6));
    try expectShape(gpa, m, list_obj, "6@0");
    try m.listInsert(gpa, list_obj, 1, idOf(7));
    try expectShape(gpa, m, list_obj, "6@0 7@6");
    try m.listInsert(gpa, list_obj, 1, idOf(8));
    try expectShape(gpa, m, list_obj, "6@0 8@6 7@6");
    try m.listInsert(gpa, list_obj, 0, idOf(9));
    try expectShape(gpa, m, list_obj, "9@0 6@0 8@6 7@6");
    try m.listInsert(gpa, list_obj, 4, idOf(10));
    try expectShape(gpa, m, list_obj, "9@0 6@0 8@6 7@6 10@7");

    // An increment is a stored row, unlike a delete, and joins the key's
    // register. A key that sorts last appends.
    try m.mapPutValue(gpa, root, "n", idOf(11), .increment, .{ .int = 3 });
    try expectShape(gpa, m, root, "2:a 4:a 1:b 3:b 5:m 11:n");

    // An update joins the element's own register, straight after its rows.
    try m.listUpdate(gpa, list_obj, 1, idOf(12));
    try expectShape(gpa, m, list_obj, "9@0 6@0 12@6 8@6 7@6 10@7");

    // A delete adds no row.
    try m.listDelete(gpa, list_obj, 2);
    try expectShape(gpa, m, list_obj, "9@0 6@0 12@6 8@6 7@6 10@7");

    // With that element gone, index 2 is the element at row `7@6`, and the
    // insert goes at the first insert row after two complete elements —
    // which is the deleted element's own row, because a delete leaves its
    // row behind (`op_set2/columns.rs:423-427`).
    try m.listInsert(gpa, list_obj, 2, idOf(13));
    try expectShape(gpa, m, list_obj, "9@0 6@0 12@6 13@6 8@6 7@6 10@7");

    // Another insert at the front, past the row that is already there.
    try m.listInsert(gpa, list_obj, 0, idOf(14));
    try expectShape(gpa, m, list_obj, "14@0 9@0 6@0 12@6 13@6 8@6 7@6 10@7");

    // Deleting the front element empties nothing: its row stays, and the
    // next front insert goes in front of it again.
    try m.listDelete(gpa, list_obj, 0);
    try m.listInsert(gpa, list_obj, 0, idOf(15));
    try expectShape(gpa, m, list_obj, "15@0 14@0 9@0 6@0 12@6 13@6 8@6 7@6 10@7");

    // A map delete removes no row either; writing the key again appends to
    // the register it never left.
    try m.mapDelete(gpa, root, "a");
    try expectShape(gpa, m, root, "2:a 4:a 1:b 3:b 5:m 11:n");
    try m.mapPut(gpa, root, "a", idOf(16));
    try expectShape(gpa, m, root, "2:a 4:a 16:a 1:b 3:b 5:m 11:n");

    // A key that sorts before every key in the object opens the object.
    try m.mapPut(gpa, root, "A", idOf(17));
    try expectShape(gpa, m, root, "17:A 2:a 4:a 16:a 1:b 3:b 5:m 11:n");

    // Appending to the list once more, with two deleted elements in it. The
    // walk reaches the target by flushing the width pending from the register
    // before the row `10@7`, so the new row goes in front of it and anchors to
    // element 7. Note that the deleted `8@6` row flushes the width pending
    // from `13@6` and then contributes none of its own
    // (`op_set2/op_set/insert.rs:104-110`): a delete removes the element, not
    // the row.
    try m.listInsert(gpa, list_obj, 5, idOf(18));
    try expectShape(gpa, m, list_obj, "15@0 14@0 9@0 6@0 12@6 13@6 8@6 7@6 18@7 10@7");

    // And one further on. The target is reached by the flush at the insert row
    // for element 10, so the new row goes in front of that row — not past the
    // end of the object — and anchors to the last visible element read before
    // it, which is the element 18 just added (`op_set2/op_set/insert.rs:112-120`
    // into `:62-68`: the anchor is `last_visible_cursor`, not the row's own
    // cursor).
    try m.listInsert(gpa, list_obj, 6, idOf(19));
    try expectShape(gpa, m, list_obj, "15@0 14@0 9@0 6@0 12@6 13@6 8@6 7@6 18@7 19@18 10@7");
}

fn expectShape(gpa: Allocator, m: Model, obj: ObjId, want: []const u8) !void {
    const got = try m.shape(gpa, obj);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

/// The successor columns, filled from a list of per-row successor lists.
///
/// Upstream's `Columns::add_succ` keeps a row's successors in ascending id
/// order (`op_set2/op_set.rs:262-276`) and `Op::add_succ` relies on it
/// (`op_set2/op.rs:964-969`); the fixture builds them that way so the test
/// is about the port's walk, not about the order.
const SuccFixture = struct {
    count: SuccCountColumn,
    actor: SuccActorColumn,
    counter: SuccCounterColumn,
    increment: IncColumn,
    cols: SuccColumns,

    fn init(gpa: Allocator, per_row: []const []const SuccEntry) !SuccFixture {
        var self = SuccFixture{
            .count = try SuccCountColumn.init(gpa),
            .actor = try SuccActorColumn.init(gpa),
            .counter = try SuccCounterColumn.init(gpa),
            .increment = try IncColumn.init(gpa),
            .cols = undefined,
        };
        errdefer self.deinit(gpa);
        for (per_row) |entries| {
            try self.count.append(gpa, @intCast(entries.len));
            for (entries) |e| {
                try self.actor.append(gpa, e.id.actor);
                try self.counter.append(gpa, e.id.counter);
                try self.increment.append(gpa, e.inc);
            }
        }
        self.cols = .{
            .count = &self.count,
            .actor = &self.actor,
            .counter = &self.counter,
            .increment = &self.increment,
        };
        return self;
    }

    fn deinit(self: *SuccFixture, gpa: Allocator) void {
        _ = gpa;
        self.count.deinit();
        self.actor.deinit();
        self.counter.deinit();
        self.increment.deinit();
    }

    /// Row `row`'s successors, read through the columns.
    fn succs(self: *const SuccFixture, row: usize, into: []SuccEntry) !SuccCursors {
        return loadSuccWindow(&self.cols, row, into);
    }
};

test "loadSuccWindow reads a row's successors out of the four columns" {
    const gpa = testing.allocator;
    var f = try SuccFixture.init(gpa, &.{
        &.{},
        &.{
            .{ .id = idOf(2), .inc = null },
            .{ .id = idOf(7), .inc = 5 },
        },
        &.{.{ .id = idOf(11), .inc = -3 }},
    });
    defer f.deinit(gpa);

    var buf: [4]SuccEntry = undefined;
    var c = try f.succs(0, &buf);
    try testing.expectEqual(@as(usize, 0), c.len());
    try testing.expectEqual(@as(usize, 0), c.pos());
    try testing.expect(c.has_delete == false);

    c = try f.succs(1, &buf);
    try testing.expectEqual(@as(usize, 2), c.len());
    // The second row's successors start after the first row's none, which is
    // the running sum of `succ_count` (`op_set2/op_set/op_iter.rs:1044-1046`).
    try testing.expectEqual(@as(usize, 0), c.pos());
    try testing.expect(c.has_delete == true);
    try testing.expect(c.entries[0].id.eql(idOf(2)));
    try testing.expect(c.entries[0].inc == null);
    try testing.expect(c.entries[1].id.eql(idOf(7)));
    try testing.expectEqual(@as(?i64, 5), c.entries[1].inc);

    // Row 2 starts after rows 0 and 1, whose counts are 0 and 2.
    c = try f.succs(2, &buf);
    try testing.expectEqual(@as(usize, 2), c.pos());
    try testing.expectEqual(@as(usize, 1), c.len());
    try testing.expect(c.has_delete == false);
    try testing.expectEqual(@as(?i64, -3), c.entries[0].inc);

    // A buffer that cannot hold the row is refused rather than truncated.
    var small: [1]SuccEntry = undefined;
    try testing.expectError(error.TooLarge, loadSuccWindow(&f.cols, 1, &small));
}

test "the successor cursors walk a row's successors in order" {
    const entries = [_]SuccEntry{
        .{ .id = idOf(2), .inc = null },
        .{ .id = idOf(7), .inc = 5 },
        .{ .id = idOf(9), .inc = null },
    };
    var c = SuccCursors.fromSpan(&entries, 4);
    try testing.expectEqual(@as(usize, 4), c.pos());
    try testing.expectEqual(@as(usize, 3), c.len());
    try testing.expect(c.has_delete == true);

    try testing.expect((c.next() orelse return error.TestUnexpectedResult).eql(idOf(2)));
    try testing.expectEqual(@as(usize, 5), c.pos());
    try testing.expect((c.next() orelse return error.TestUnexpectedResult).eql(idOf(7)));
    try testing.expect((c.next() orelse return error.TestUnexpectedResult).eql(idOf(9)));
    try testing.expect(c.next() == null);

    var with_inc = SuccCursors.fromSpan(&entries, 0).withInc();
    try testing.expectEqual(@as(usize, 3), with_inc.len());
    const first = with_inc.next() orelse return error.TestUnexpectedResult;
    try testing.expect(first.id.eql(idOf(2)));
    try testing.expect(first.inc == null);
    const second = with_inc.next() orelse return error.TestUnexpectedResult;
    try testing.expect(second.id.eql(idOf(7)));
    try testing.expectEqual(@as(?i64, 5), second.inc);
}

test "addSucc places an edge after every successor at or below it, and drops an increment off a non-counter" {
    const entries = [_]SuccEntry{
        .{ .id = idOf(2), .inc = null },
        .{ .id = idOf(7), .inc = 5 },
        .{ .id = idOf(9), .inc = null },
    };
    const succ = SuccCursors.fromSpan(&entries, 10);
    const at: usize = 4;

    const counter = Op.init(
        at,
        false,
        idOf(1),
        .set,
        root,
        KeyRef.fromStr("n"),
        false,
        .{ .counter = .init(100) },
        false,
        null,
        succ,
    );

    // Between two successors: the walk stops at the first successor above
    // `id`, and `sub_pos` is the position just past the last one at or
    // below it (`op_set2/op.rs:963-969`).
    try testing.expect(counter.addSucc(idOf(4), null).eql(.{
        .id = idOf(4),
        .pos = at,
        .inc = null,
        .len = 3,
        .sub_pos = 11,
    }));
    // Before the first: `sub_pos` is the row's own start.
    try testing.expectEqual(@as(usize, 10), counter.addSucc(idOf(1), null).sub_pos);
    // On a successor: the walk consumes it, so the position is just past it.
    try testing.expectEqual(@as(usize, 12), counter.addSucc(idOf(7), null).sub_pos);
    // After the last: the walk runs out, so the position is one past the end.
    try testing.expectEqual(@as(usize, 13), counter.addSucc(idOf(11), null).sub_pos);
    // An edge that equals an existing one lands after it, so ids stay
    // strictly ascending and a duplicate cannot appear.
    try testing.expectEqual(@as(usize, 12), counter.addSucc(idOf(7), null).sub_pos);

    // The increment survives on a counter.
    try testing.expectEqual(@as(?i64, 4), counter.addSucc(idOf(11), 4).inc);
    // ... and is dropped on anything else, because an increment preserves a
    // counter predecessor and acts as an ordinary overwrite otherwise
    // (`op_set2/op.rs:959-961`).
    const plain = Op.init(at, false, idOf(1), .set, root, KeyRef.fromStr("a"), false, .{ .str = "v" }, false, null, succ);
    try testing.expect(plain.addSucc(idOf(11), 4).inc == null);
}

test "a row is visible until something deletes it, and a counter follows its increments" {
    const no_succ = SuccCursors.none();
    const deleting = SuccCursors.fromSpan(&.{
        .{ .id = idOf(2), .inc = null },
    }, 0);
    const incrementing = SuccCursors.fromSpan(&.{
        .{ .id = idOf(2), .inc = 5 },
    }, 0);

    const str_row = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("a"), false, .{ .str = "v" }, false, null, no_succ);
    try testing.expect(str_row.visible());
    try testing.expect(str_row.top());

    const deleted_row = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("a"), false, .{ .str = "v" }, false, null, deleting);
    try testing.expect(!deleted_row.visible());

    const counter = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("n"), false, .{ .counter = .init(1) }, false, null, incrementing);
    try testing.expect(counter.visible());
    const counted_out = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("n"), false, .{ .counter = .init(1) }, false, null, deleting);
    try testing.expect(!counted_out.visible());

    // An increment is never visible on its own, whatever its successors.
    const inc = Op.init(0, false, idOf(1), .increment, root, KeyRef.fromStr("n"), false, .{ .int = 1 }, false, null, no_succ);
    try testing.expect(!inc.visible());
    try testing.expectEqual(@as(?i64, 1), inc.getIncrementValue());
}

test "fixCounter folds the increments on a counter row into its value" {
    const entries = [_]SuccEntry{
        .{ .id = OpId.init(2, 0), .inc = 5 },
        .{ .id = OpId.init(3, 1), .inc = 7 },
        .{ .id = OpId.init(4, 0), .inc = null },
    };
    const succ = SuccCursors.fromSpan(&entries, 0);

    var unscoped = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("n"), false, .{ .counter = .init(100) }, false, null, succ);
    unscoped.fixCounter(null);
    try testing.expectEqual(@as(i64, 112), unscoped.value().counter.current);

    // A clock covers only the actors it has seen, so the second increment
    // is left out (`op_set2/op.rs:984-986`).
    var cover = Clock.initEmpty(std.testing.allocator);
    defer cover.deinit();
    try cover.ensureSize(2);
    _ = cover.include(0, 4);
    var scoped = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("n"), false, .{ .counter = .init(100) }, false, null, succ);
    scoped.fixCounter(cover);
    try testing.expectEqual(@as(i64, 105), scoped.value().counter.current);

    // A row whose value is not a counter is left alone, and so is a counter
    // whose successors all delete it.
    var plain = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("a"), false, .{ .int = 42 }, false, null, succ);
    plain.fixCounter(null);
    try testing.expectEqual(@as(i64, 42), plain.value().int);
}

/// A two-actor clock, as a loaded document's is: actor 0 has seen `ctr`
/// operations and actor 1 none. The caller deinits it.
fn clockFor(ctr: u32) !Clock {
    var c = Clock.initEmpty(testing.allocator);
    errdefer c.deinit();
    try c.ensureSize(2);
    _ = c.include(0, ctr);
    return c;
}

/// A string row at op 1 of actor 0, with `succ` as its successors.
fn strRow(succ: SuccCursors) Op {
    return Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("a"), false, .{ .str = "v" }, false, null, succ);
}

/// A counter row at op 1 of actor 0, stored as 100, with `succ` as its
/// successors. 100 is not the value a reader sees: the increments are
/// separate edges until they are folded in.
fn counterRow(succ: SuccCursors) Op {
    return Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("n"), false, .{ .counter = .init(100) }, false, null, succ);
}

test "a row the clock covers, that no covered successor takes, is in view" {
    var cover = try clockFor(4);
    defer cover.deinit();

    var row = strRow(SuccCursors.none());
    const scoped = row.maybeScopeToClock(cover);
    // `predates` is the clock covering the row's own id
    // (`op_set2/op_set/visible.rs:225`), and with no successor nothing
    // deletes it.
    try testing.expect(scoped.predates);
    try testing.expect(!scoped.deleted);
    try testing.expectEqual(@as(?i64, null), scoped.counter_value);
    try testing.expect(row.scopeToClock(cover));
}

test "a row the clock does not cover is out of view, whatever its successors" {
    // An empty clock has seen nothing, so no operation predates it.
    var empty = try clockFor(0);
    defer empty.deinit();

    var row = strRow(SuccCursors.none());
    const scoped = row.maybeScopeToClock(empty);
    try testing.expect(!scoped.predates);
    try testing.expect(!scoped.deleted);
    try testing.expect(!scoped.visible());
    try testing.expect(!row.scopeToClock(empty));

    // A covered successor does not make a row visible that the clock does
    // not cover: the answer is `predates and not deleted`
    // (`op_set2/op_set/visible.rs:263`), not "either".
    const overwritten = SuccCursors.fromSpan(&.{
        .{ .id = idOf(2), .inc = null },
    }, 0);
    var later = strRow(overwritten);
    try testing.expect(!later.maybeScopeToClock(empty).predates);
    try testing.expect(!later.scopeToClock(empty));
}

test "a delete the clock covers takes a row out of view; one it does not is not a delete yet" {
    var cover = try clockFor(4);
    defer cover.deinit();

    // A covered successor, with no increment on it, is a delete within this
    // clock (`op_set2/op_set/visible.rs:234`).
    const covered_delete = SuccCursors.fromSpan(&.{
        .{ .id = idOf(2), .inc = null },
    }, 0);
    var gone = strRow(covered_delete);
    const gone_scoped = gone.maybeScopeToClock(cover);
    try testing.expect(gone_scoped.predates);
    try testing.expect(gone_scoped.deleted);
    try testing.expect(!gone_scoped.visible());
    try testing.expect(!gone.scopeToClock(cover));

    // The same delete, by an op this clock has not seen. It is a real
    // successor — the unscoped `visible` already answers false for it — but
    // it is not a delete *within this clock*, so a read of this past state
    // still sees the row. "Any delete hides it" gets this wrong, and it is
    // the whole reason the rule is scoped per edge
    // (`op_set2/op_set/visible.rs:234`).
    const uncovered_delete = SuccCursors.fromSpan(&.{
        .{ .id = OpId.init(9, 1), .inc = null },
    }, 0);
    var alive = strRow(uncovered_delete);
    try testing.expect(!alive.visible());
    const alive_scoped = alive.maybeScopeToClock(cover);
    try testing.expect(alive_scoped.predates);
    try testing.expect(!alive_scoped.deleted);
    try testing.expect(alive_scoped.visible());
    try testing.expect(alive.scopeToClock(cover));
}

test "scopeToClock folds a counter's covered increments into the row's own value" {
    const entries = [_]SuccEntry{
        .{ .id = idOf(2), .inc = 5 },
        .{ .id = idOf(3), .inc = 7 },
        // An increment from an op the clock has not seen. It is a real
        // edge and an increment, and it is left out of the sum: this is the
        // increment the clock's timeframe did not include
        // (`op_set2/op_set/visible.rs:203-206`).
        .{ .id = OpId.init(9, 1), .inc = 100 },
    };
    const succ = SuccCursors.fromSpan(&entries, 0);

    var cover = try clockFor(4);
    defer cover.deinit();

    var row = counterRow(succ);
    const scoped = row.maybeScopeToClock(cover);
    try testing.expectEqual(@as(?i64, 112), scoped.counter_value);
    // An increment never deletes a counter, covered or not
    // (`op_set2/op_set/visible.rs:205-206`).
    try testing.expect(!scoped.deleted);
    try testing.expect(row.scopeToClock(cover));
    // The fold reaches the row the caller holds, which is the point of the
    // `&mut self` on `scope_to_clock` (`op_set2/op_set/visible.rs:218-220`).
    try testing.expectEqual(@as(i64, 112), row.value().counter.current);

    // With only the uncovered increment, the sum is the stored value and not
    // the stored value plus 100.
    const later = [_]SuccEntry{.{ .id = OpId.init(9, 1), .inc = 100 }};
    var pending = counterRow(SuccCursors.fromSpan(&later, 0));
    try testing.expectEqual(@as(?i64, 100), pending.maybeScopeToClock(cover).counter_value);
    try testing.expect(pending.scopeToClock(cover));
    try testing.expectEqual(@as(i64, 100), pending.value().counter.current);

    // Once a clock has seen that increment, it folds in like any other.
    var seen = try clockFor(4);
    defer seen.deinit();
    _ = seen.include(1, 9);
    var after = counterRow(SuccCursors.fromSpan(&later, 0));
    try testing.expectEqual(@as(?i64, 200), after.maybeScopeToClock(seen).counter_value);

    // On a non-counter row an increment edge is an ordinary overwrite, so it
    // takes the row out of view like any other covered successor, and there
    // is no counter value to fold and nothing to rewrite
    // (`op_set2/op_set/visible.rs:234-237`).
    var plain = strRow(succ);
    const plain_scoped = plain.maybeScopeToClock(cover);
    try testing.expectEqual(@as(?i64, null), plain_scoped.counter_value);
    try testing.expect(plain_scoped.deleted);
    try testing.expect(!plain.scopeToClock(cover));
    try testing.expect(plain.value().eql(.{ .str = "v" }));
}

test "a covered increment that deletes a counter is a delete within that clock" {
    var cover = try clockFor(4);
    defer cover.deinit();

    // A counter whose successor increments and then deletes: the increment
    // folds in, the delete takes the row out of view
    // (`op_set2/op_set/visible.rs:203-211`).
    const entries = [_]SuccEntry{
        .{ .id = idOf(2), .inc = 5 },
        .{ .id = idOf(3), .inc = null },
    };
    var row = counterRow(SuccCursors.fromSpan(&entries, 0));
    const scoped = row.maybeScopeToClock(cover);
    try testing.expectEqual(@as(?i64, 105), scoped.counter_value);
    try testing.expect(scoped.deleted);
    try testing.expect(!scoped.visible());
    try testing.expect(!row.scopeToClock(cover));
    // The fold still happened: `scope_to_clock` writes the value before it
    // reports the row as gone (`op_set2/op_set/visible.rs:216-221`).
    try testing.expectEqual(@as(i64, 105), row.value().counter.current);

    // The same row under a clock that has seen neither edge: the delete is
    // not in this timeframe, so the row is in view and the increment is not
    // in it either.
    var early = try clockFor(1);
    defer early.deinit();
    var then = counterRow(SuccCursors.fromSpan(&entries, 0));
    const then_scoped = then.maybeScopeToClock(early);
    try testing.expectEqual(@as(?i64, 100), then_scoped.counter_value);
    try testing.expect(!then_scoped.deleted);
    try testing.expect(then.scopeToClock(early));
}

test "a null clock scopes to the present, and answers as the unscoped read does" {
    // A null clock is the dispatch to the indexed fast path, not a filter
    // that happens to let everything through (`VisIter::new`,
    // `op_set2/op_set/visible.rs:59-67`; `seek_ops_by_index`,
    // `op_set2/op_set.rs:639-653`). So it has to reach this method and
    // answer, not be short-circuited into `Op.visible`.
    const deleting = SuccCursors.fromSpan(&.{
        .{ .id = idOf(2), .inc = null },
    }, 0);
    const incrementing = SuccCursors.fromSpan(&.{
        .{ .id = idOf(2), .inc = 5 },
        .{ .id = idOf(3), .inc = 7 },
    }, 0);

    const fresh = strRow(SuccCursors.none());
    const fresh_scoped = fresh.maybeScopeToClock(null);
    try testing.expect(fresh_scoped.predates);
    try testing.expectEqual(fresh.visible(), fresh_scoped.visible());

    const gone = strRow(deleting);
    const gone_scoped = gone.maybeScopeToClock(null);
    try testing.expectEqual(gone.visible(), gone_scoped.visible());
    try testing.expectEqual(!gone.visible(), gone_scoped.deleted);

    // For a counter the unscoped answer carries the fully folded value, and
    // that is what `fixCounter` writes with no clock either — the two share
    // one walk.
    var counted = counterRow(incrementing);
    const counted_scoped = counted.maybeScopeToClock(null);
    try testing.expectEqual(counted.visible(), counted_scoped.visible());
    try testing.expectEqual(@as(?i64, 112), counted_scoped.counter_value);
    counted.fixCounter(null);
    try testing.expectEqual(counted_scoped.counter_value.?, counted.value().counter.current);
}

test "scopeToClock and ClockVisibility.visible never disagree" {
    var cover = try clockFor(4);
    defer cover.deinit();
    _ = cover.include(1, 9);

    // Every combination of value type, coverage and edge kind: the method
    // and the value it computes must answer alike, and the method's rewrite
    // must be the value the computation produced.
    const fixtures = [_]Op{
        strRow(SuccCursors.none()),
        strRow(SuccCursors.fromSpan(&.{
            .{ .id = idOf(2), .inc = null },
        }, 0)),
        strRow(SuccCursors.fromSpan(&.{
            .{ .id = OpId.init(9, 1), .inc = null },
        }, 0)),
        strRow(SuccCursors.fromSpan(&.{
            .{ .id = OpId.init(9, 1), .inc = 5 },
        }, 0)),
        counterRow(SuccCursors.none()),
        counterRow(SuccCursors.fromSpan(&.{
            .{ .id = idOf(2), .inc = 5 },
        }, 0)),
        counterRow(SuccCursors.fromSpan(&.{
            .{ .id = idOf(2), .inc = null },
        }, 0)),
        counterRow(SuccCursors.fromSpan(&.{
            .{ .id = idOf(2), .inc = 5 },
            .{ .id = OpId.init(9, 1), .inc = null },
        }, 0)),
    };

    for (fixtures) |fixture| {
        for ([_]?Clock{ cover, null }) |c| {
            const by_value = fixture.maybeScopeToClock(c);
            var by_method = fixture;
            try testing.expectEqual(by_value.visible(), by_method.scopeToClock(c));
            if (by_value.counter_value) |v| {
                try testing.expectEqual(v, by_method.value().counter.current);
            } else {
                try testing.expect(fixture.value().eql(by_method.value()));
            }
        }
    }
}

test "decompose splits an op type into the columns it is stored as" {
    const cases = [_]struct { t: OpType, d: Decomposed }{
        .{
            .t = .{ .make = .map },
            .d = .{ .action = .make_map, .value = .null_value, .expand = false, .mark_name = null },
        },
        .{
            .t = .{ .make = .list },
            .d = .{ .action = .make_list, .value = .null_value, .expand = false, .mark_name = null },
        },
        .{
            .t = .{ .make = .text },
            .d = .{ .action = .make_text, .value = .null_value, .expand = false, .mark_name = null },
        },
        .{
            .t = .{ .make = .table },
            .d = .{ .action = .make_table, .value = .null_value, .expand = false, .mark_name = null },
        },
        .{
            .t = .delete,
            .d = .{ .action = .delete, .value = .null_value, .expand = false, .mark_name = null },
        },
        .{
            .t = .{ .increment = 7 },
            .d = .{ .action = .increment, .value = .{ .int = 7 }, .expand = false, .mark_name = null },
        },
        .{
            .t = .{ .put = .{ .str = "hi" } },
            .d = .{ .action = .set, .value = .{ .str = "hi" }, .expand = false, .mark_name = null },
        },
        .{
            .t = .{ .mark_begin = .{ .expand = true, .name = "bold", .value = .{ .bool_value = true } } },
            .d = .{ .action = .mark, .value = .{ .bool_value = true }, .expand = true, .mark_name = "bold" },
        },
        .{
            .t = .{ .mark_end = .{ .expand = false } },
            .d = .{ .action = .mark, .value = .null_value, .expand = false, .mark_name = null },
        },
    };
    for (cases) |c| {
        const got = decompose(c.t);
        try testing.expectEqual(c.d.action, got.action);
        try testing.expect(c.d.value.eql(got.value));
        try testing.expectEqual(c.d.expand, got.expand);
        try testing.expectEqualSlices(u8, c.d.mark_name orelse "", got.mark_name orelse "");
        // The inverse has to agree, or a document read and written back
        // would not be the same document (`op_set2/types.rs:148-189`).
        const back = try value.opTypeFromActionAndValue(
            got.action,
            got.value,
            got.mark_name,
            got.expand,
        );
        try testing.expect(std.meta.activeTag(back) == std.meta.activeTag(c.t));
    }
}

test "a TxOp carries what its constructor sets and nothing else" {
    const gpa = testing.allocator;

    // A map put.
    var put = try TxOp.map(gpa, idOf(1), .{ .id = root, .typ = .map }, 3, .{ .visible_update = .{ .put = .{ .str = "v" } } }, "k", &.{idOf(0)});
    defer put.deinit(gpa);
    try testing.expectEqual(ObjType.map, put.obj_type);
    try testing.expectEqual(@as(usize, 3), put.pos);
    try testing.expectEqual(@as(usize, 0), put.index);
    try testing.expectEqual(false, put.noop);
    try testing.expect(put.bld.key().eql(KeyRef.fromStr("k")));
    try testing.expectEqual(false, put.insert());
    try testing.expect(put.visible());
    try testing.expect(put.bld.value().eql(.{ .str = "v" }));
    try testing.expectEqualSlices(u8, "k", put.prop().key);
    try testing.expectEqual(@as(u32, 1), put.predCount());
    try testing.expect(put.pred()[0].eql(idOf(0)));

    // A conflict resolution sets `noop` and nothing else.
    var conflict = try TxOp.map(gpa, idOf(2), .{ .id = root, .typ = .map }, 4, .{ .conflict_resolution = .{ .put = .{ .int = 9 } } }, "k", &.{});
    defer conflict.deinit(gpa);
    try testing.expect(conflict.noop);
    try testing.expect(conflict.bld.value().eql(.{ .int = 9 }));

    // A list insert carries no predecessors and its own index.
    var ins = try TxOp.insertVal(gpa, idOf(3), .{ .id = root, .typ = .list }, 5, .{ .str = "x" }, ElemId.fromOpId(idOf(2)));
    defer ins.deinit(gpa);
    try testing.expectEqual(@as(usize, 5), ins.pos);
    try testing.expectEqual(@as(usize, 0), ins.index);
    try testing.expect(ins.insert());
    try testing.expectEqual(@as(u32, 0), ins.predCount());
    try testing.expect(ins.bld.key().eql(KeyRef.fromElemId(ElemId.fromOpId(idOf(2)))));
    try testing.expect(ins.elemidOrKey().eql(KeyRef.fromElemId(ElemId.fromOpId(idOf(3)))));
    try testing.expect((try ins.cursor()).eql(ElemId.fromOpId(idOf(3))));

    // An insert of a new object reports what it made.
    var made = try TxOp.insertObj(gpa, idOf(4), .{ .id = root, .typ = .list }, 6, 1, .text, ElemId.fromOpId(idOf(3)));
    defer made.deinit(gpa);
    try testing.expectEqual(Action.make_text, made.action());
    try testing.expectEqual(ObjType.text, made.objInfo().?.obj_type);
    try testing.expect(made.objInfo().?.parent.eql(root));
    try testing.expect(made.obj() == null); // the root names no actor
    try testing.expect(made.objCtr() == null);
    try testing.expect(made.objId().eql(.root));

    // A delete of a sequence element has no row, so no position.
    var del = try TxOp.listDel(gpa, idOf(5), .{ .id = root, .typ = .list }, 2, ElemId.fromOpId(idOf(3)), &.{idOf(4)});
    defer del.deinit(gpa);
    try testing.expectEqual(Action.delete, del.action());
    try testing.expectEqual(@as(usize, 0), del.pos);
    try testing.expectEqual(@as(usize, 2), del.index);
    try testing.expect(del.isDelete());
    try testing.expect(del.bld.value().eql(.null_value));
    try testing.expect((try del.cursor()).eql(ElemId.fromOpId(idOf(3))));

    // A write to a sequence element addresses the element, not its own id.
    var upd = try TxOp.list(gpa, idOf(6), .{ .id = root, .typ = .list }, 7, 1, .{ .visible_update = .{ .put = .{ .str = "u" } } }, ElemId.fromOpId(idOf(3)), &.{});
    defer upd.deinit(gpa);
    try testing.expect((try upd.cursor()).eql(ElemId.fromOpId(idOf(3))));
    try testing.expectEqual(@as(usize, 1), upd.prop().index);
}

test "a ChangeOp's width and visibility follow its successors" {
    const gpa = testing.allocator;
    var op = try ChangeOp.init(
        gpa,
        idOf(1),
        root,
        .set,
        KeyRef.fromStr("k"),
        .{ .str = "hello" },
        false,
        false,
        null,
        &.{},
    );
    defer op.deinit(gpa);

    try testing.expect(op.pos == null);
    try testing.expectEqual(@as(usize, 0), op.subsort);
    try testing.expectEqual(false, op.conflicted);
    try testing.expect(op.visible());
    try testing.expect(op.top());
    try testing.expect(op.isSetOrMake());
    try testing.expectEqualSlices(u8, "k", op.prop().?.key);

    // A list element is one unit wide whatever its text says.
    try testing.expectEqual(@as(i64, 1), op.width(.list, .unicode_code_point));
    try testing.expectEqual(@as(i64, 5), op.width(.text, .unicode_code_point));

    // One successor that increments it leaves a counter visible.
    try op.succs.append(gpa, .{ .id = idOf(2), .inc = 3 });
    try testing.expectEqual(@as(usize, 1), op.succCount());
    try testing.expectEqual(@as(usize, 1), op.succIncCount());
    try testing.expect(op.succAt(0).eql(idOf(2)));
    try testing.expectEqual(@as(?i64, 3), op.succIncAt(0));
    try testing.expect(op.visible());

    // One that deletes it does not, and the width follows visibility.
    try op.succs.append(gpa, .{ .id = idOf(3), .inc = null });
    try testing.expect(op.hasSucc());
    try testing.expect(!op.visible());
    try testing.expect(!op.top());
    try testing.expectEqual(@as(i64, 0), op.width(.text, .unicode_code_point));

    // A conflicted op is not the register's winner even when visible.
    op.succs.clearRetainingCapacity();
    op.conflicted = true;
    try testing.expect(op.visible());
    try testing.expect(!op.top());
}

test "a mark row's index word names its begin and its end" {
    // `((actor as i64) << 32) + (counter as i64 & 0xffffffff)` for a begin and
    // its negation for an end (`op_set2/op_set/mark_index.rs:25-34`).
    const begin = Op.init(0, false, OpId.init(3, 0), .mark, root, KeyRef.fromStr("t"), true, .null_value, true, "bold", SuccCursors.none());
    try testing.expectEqual(@as(?i64, 3), begin.markIndex());
    try testing.expect(begin.markData().?.name.ptr == "bold".ptr);
    try testing.expectEqual(@as(?i64, 4294967296), Op.init(0, false, OpId.init(0, 1), .mark, root, KeyRef.fromStr("t"), true, .null_value, true, "b", SuccCursors.none()).markIndex());

    // A mark end names the begin it closes at `id.prev()`, negated so that
    // the column sorts a begin before the end that closes it.
    const end = Op.init(1, false, OpId.init(4, 0), .mark, root, KeyRef.fromStr("t"), true, .null_value, false, null, SuccCursors.none());
    try testing.expectEqual(@as(?i64, -3), end.markIndex());
    try testing.expect(end.markData() == null);
    try testing.expectEqual(@as(i64, 0), end.width(.text, .unicode_code_point));

    // A row that is not a mark has no word, and a mark end at counter zero
    // does not trap on the way to its begin.
    try testing.expect((Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("t"), true, .null_value, false, null, SuccCursors.none()).markIndex() == null));
    try testing.expectEqual(@as(?i64, 0), Op.init(0, false, OpId.root, .mark, root, KeyRef.fromStr("t"), true, .null_value, false, null, SuccCursors.none()).markIndex());
}

test "a row reports the register it belongs to and the element it addresses" {
    const ins = Op.init(0, false, idOf(4), .set, list_obj, KeyRef.fromElemId(ElemId.fromOpId(idOf(2))), true, .null_value, false, null, SuccCursors.none());
    // An insert's register is its own element id, whatever it was anchored
    // to (`op_set2/op.rs:1040-1046`).
    try testing.expect(ins.elemidOrKey().eql(KeyRef.fromElemId(ElemId.fromOpId(idOf(4)))));
    try testing.expect(ins.key().eql(KeyRef.fromElemId(ElemId.fromOpId(idOf(2)))));
    try testing.expect((try ins.cursor()).eql(ElemId.fromOpId(idOf(4))));
    try testing.expect(ins.obj() != null);
    try testing.expectEqual(@as(?ActorIdx, 0), ins.objActor());

    const upd = Op.init(1, false, idOf(5), .set, list_obj, KeyRef.fromElemId(ElemId.fromOpId(idOf(2))), false, .null_value, false, null, SuccCursors.none());
    try testing.expect(upd.elemidOrKey().eql(KeyRef.fromElemId(ElemId.fromOpId(idOf(2)))));
    try testing.expect((try upd.cursor()).eql(ElemId.fromOpId(idOf(2))));

    // A map key addresses no element and is not an object.
    const map_row = Op.init(2, false, idOf(6), .set, root, KeyRef.fromStr("k"), false, .null_value, false, null, SuccCursors.none());
    try testing.expectError(error.InvalidCursorOp, map_row.cursor());
    try testing.expect(map_row.obj() == null);
    try testing.expectEqualStrings("k", map_row.keyStr().?);
}

test "Op.del builds a delete op, which builds an OpBuilder that writes like one" {
    const gpa = testing.allocator;
    const del = Op.del(idOf(2), root, KeyRef.fromElemId(ElemId.fromOpId(idOf(1))));
    try testing.expectEqual(Action.delete, del.action());
    try testing.expectEqual(@as(usize, 0), del.pos);
    try testing.expect(del.isDelete());
    try testing.expect(del.value().eql(.null_value));
    try testing.expectEqual(@as(usize, 0), del.succCount());
    try testing.expectEqual(false, del.insert());

    var b = try del.build(gpa, &.{idOf(1)});
    defer b.deinit(gpa);
    try testing.expectEqual(Action.delete, b.action());
    try testing.expect(b.pred()[0].eql(idOf(1)));
    try testing.expectEqual(@as(u32, 1), b.predCount());
    try testing.expect(b.objInfo() == null);
}

test "every op type answers the whole accessor set" {
    // The comptime check below is the assertion; these calls are here so a
    // change that breaks one signature has a test to fail.
    comptime {
        assertOpLike(Op);
        assertOpLike(OpBuilder);
        assertOpLike(TxOp);
        assertOpLike(ChangeOp);
    }
    try testing.expectEqual(@as(u32, 1), idOf(1).counter);
}

test "a successor cursor's total is not the count of successors left" {
    const entries = [_]SuccEntry{
        .{ .id = idOf(2), .inc = 5 },
        .{ .id = idOf(3), .inc = null },
        .{ .id = OpId.init(9, 1), .inc = 7 },
    };

    // `SuccCursors.len` is the row's total successor count and
    // `SuccIncCursors.len` is what is left to read; they are different
    // numbers for the same span.
    var c = SuccCursors.fromSpan(&entries, 10);
    var with_inc = c.withInc();
    try testing.expectEqual(@as(usize, 3), c.len());
    try testing.expectEqual(@as(usize, 3), with_inc.len());
    try testing.expectEqual(@as(usize, 10), c.pos());

    // The two cursors are copies, so each advances on its own — and the
    // total does not move, which is what makes `while (c.len() > 0)` a loop
    // that never ends and a drain loop the wrong shape.
    _ = c.next();
    _ = with_inc.next();
    try testing.expectEqual(@as(usize, 3), c.len());
    try testing.expectEqual(@as(usize, 2), with_inc.len());
    try testing.expectEqual(@as(usize, 11), c.pos());

    // And the total is the bound `Op.succAt` indexes against: it is
    // `Op.succCount`.
    const row = counterRow(SuccCursors.fromSpan(&entries, 10));
    try testing.expectEqual(@as(usize, 3), row.succCount());
    try testing.expectEqual(idOf(2), row.succAt(0));
    try testing.expectEqual(OpId.init(9, 1), row.succAt(2));
    try testing.expectEqual(@as(?i64, 7), row.succIncAt(2));
}

test "a counter row's visibility follows the flag fromSpan derived, not the cursor's position" {
    const deleting = [_]SuccEntry{
        .{ .id = idOf(2), .inc = 5 },
        .{ .id = idOf(3), .inc = null },
    };
    const incrementing = [_]SuccEntry{
        .{ .id = idOf(2), .inc = 5 },
        .{ .id = idOf(3), .inc = 7 },
    };

    // `fromSpan` walks the entries once and the flag is exactly "some entry
    // deletes", which is the obligation the type doc puts on the field.
    const gone = SuccCursors.fromSpan(&deleting, 0);
    const counted = SuccCursors.fromSpan(&incrementing, 0);
    try testing.expect(gone.has_delete);
    try testing.expect(!counted.has_delete);

    // The flag is a property of the whole span, so `Op.visible` on a counter
    // answers the same before and after the cursor has been walked — which
    // is what makes that arm O(1).
    var walked = gone;
    _ = walked.next();
    try testing.expect(walked.has_delete);
    try testing.expect(!counterRow(walked).visible());
    try testing.expect(counterRow(counted).visible());

    // A struct literal that satisfies the documented obligation is
    // indistinguishable from the one `fromSpan` built, for every reader.
    const literal = SuccCursors{
        .entries = &deleting,
        .at = 0,
        .read = 0,
        .has_delete = true,
    };
    try testing.expectEqual(counterRow(gone).visible(), counterRow(literal).visible());
    try testing.expectEqual(counterRow(gone).succCount(), counterRow(literal).succCount());
}

test "a row's width is one per list element, and in text it is the string's own width with a mark at zero" {
    // `.list` counts a row whatever its value (`op_set2/op.rs:1007-1013`).
    const str_row = strRow(SuccCursors.none());
    try testing.expectEqual(@as(i64, 1), str_row.width(.list, .unicode_code_point));
    try testing.expectEqual(@as(i64, 1), counterRow(SuccCursors.none()).width(.list, .unicode_code_point));

    // `.text` measures the string the row contributes, and a mark row
    // contributes nothing at all — the boundary that matters is the empty
    // one, and a mark's empty string is where that comes from.
    const empty = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("a"), true, .{ .str = "" }, false, null, SuccCursors.none());
    try testing.expectEqual(@as(i64, 0), empty.width(.text, .unicode_code_point));

    // **One code point is not one byte.** U+20AC is a single unit under
    // `unicode_code_point` and three UTF-8 bytes under `utf8_code_unit`
    // (`types.zig:697`), so the same row is one wide in one encoding and three
    // in the other. A one-byte string cannot tell the two apart.
    const one = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("a"), true, .{ .str = "\u{20AC}" }, false, null, SuccCursors.none());
    try testing.expectEqual(@as(i64, 1), one.width(.text, .unicode_code_point));
    try testing.expectEqual(@as(i64, 3), one.width(.text, .utf8_code_unit));

    // A combining mark is its own unit under code points, so a row that
    // *looks* empty is one wide. The width index is a function of the
    // encoding, not of what a reader sees.
    const combining = Op.init(0, false, idOf(1), .set, root, KeyRef.fromStr("a"), true, .{ .str = "\u{301}" }, false, null, SuccCursors.none());
    try testing.expectEqual(@as(i64, 1), combining.width(.text, .unicode_code_point));
    try testing.expectEqual(@as(i64, 2), combining.width(.text, .utf8_code_unit));

    const mark = Op.init(0, false, idOf(1), .mark, root, KeyRef.fromStr("a"), true, .{ .bool_value = true }, false, "bold", SuccCursors.none());
    try testing.expectEqual(@as(i64, 0), mark.width(.text, .unicode_code_point));
    try testing.expectEqual(@as(i64, 0), mark.width(.text, .utf8_code_unit));
    try testing.expectEqual(@as(i64, 1), mark.width(.list, .unicode_code_point));
}
