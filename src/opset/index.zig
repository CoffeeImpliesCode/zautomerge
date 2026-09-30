//! Rebuilding the op set's derived index from an op stream.
//!
//! Upstream `op_set2/op_set/index.rs` (263 lines) holds three things:
//!
//! | what | upstream |
//! |------|----------|
//! | [`ObjIndex`] and [`ObjInfo`] — what every object in the op set is and where it hangs | `:77-148` |
//! | [`IndexBuilder`] — the full rebuild of the five index columns | `:159-255` |
//! | [`MarkOrderValidator`] — the on-load mark-begin/mark-end order check | `:22-75` |
//!
//! plus the rebuild-side [`Indexes`] (`:150-157`), which carries `obj_info` and
//! so is a different type from `columns.Indexes`, and the private
//! [`visNum`] (`:257-263`).
//!
//! # None of the five index columns is stored
//!
//! The exporter writes the sixteen data columns and has no arm for the index
//! (`op_set2/columns.rs:135-170`), and a load builds them empty
//! (`op_set2/columns.rs:252-330`). Every document that is loaded therefore has
//! its index rebuilt from the op stream, which is what this file does and why
//! it is the most load-bearing correctness path in the slice: a document that
//! loads with a wrong index reads back plausibly wrong rather than failing.
//!
//! # The rebuild is driven from the outside, in this order
//!
//! The loader (`storage/document.rs:332-344`) walks `op_set.iter()` and for
//! every row (`IndexedChangeCollector::process_ops`,
//! `op_set2/change/collector.rs:39-55`):
//!
//! 1. `flush()` when `(obj, elemid_or_key)` changes — the start of a new
//!    register (`:62-66`);
//! 2. `processOp(op)`;
//! 3. `processSucc(op.is_counter(), id)` once per successor of that row.
//!
//! and then `finish()` once, whose `MarkOrderValidator` the caller checks
//! before it calls `OpSet::set_indexes` (`storage/document.rs:343-344`).
//!
//! # `IndexBuilder` allocates only its own accumulation
//!
//! Constructing one is **five allocations and nothing else**: [`init`]
//! reserves room for the rows and the successors it is about to be handed
//! (`Vec::with_capacity`, `:163-167`), one per accumulation list. After that
//! every allocation is the growth of one of the two hash maps the builder
//! keeps — `counters` (`:10`) and `obj_info` (`:17`) — and `flush` allocates
//! nothing at all. No per-row value is copied beyond the increment index's
//! `Option<i64>` and the mark builders, which is what upstream's `Vec`s do
//! too; no iterator is constructed, and nothing here returns a borrowed slice
//! the caller has to free.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const columns = @import("columns.zig");
const markidx = @import("mark_index.zig");
const opset_op = @import("op.zig");
const optypes = @import("types.zig");

const Allocator = std.mem.Allocator;
const ParseError = err.ParseError;

const ActorIdx = types.ActorIdx;
const ObjId = types.ExId;
const ObjType = types.ObjType;
const OpId = types.OpId;
const SequenceType = types.SequenceType;
const TextEncoding = types.TextEncoding;

const Action = optypes.Action;
const MarkData = optypes.MarkData;
const MarkIndexBuilder = markidx.MarkIndexBuilder;
const MarkIndexColumn = markidx.MarkIndexColumn;
const ScalarValue = optypes.ScalarValue;
const ValueMeta = optypes.ValueMeta;

const BoolColumn = columns.BoolColumn;
const BoolPrefixColumn = columns.BoolPrefixColumn;
const IncColumn = columns.IncColumn;
const IndexLengths = columns.IndexLengths;
const TextColumn = columns.TextColumn;

const Op = opset_op.Op;
const SuccCursors = opset_op.SuccCursors;
const SuccEntry = opset_op.SuccEntry;

// ── ObjInfo and ObjIndex ───────────────────────────────────────────────────

/// What an object is and which operation made it
/// (`ObjInfo`, `op_set2/op_set/index.rs:107-110`).
///
/// Upstream declares it in the index builder and produces it from
/// `Op::obj_info` (`:128-134`), `ChangeOp::obj_info` (`:136-140`) and
/// `OpBuilder::obj_info` (`:142-148`). The port declares it once, in
/// [op.zig](op.zig), next to the three accessors that make it, and re-exports
/// it under this name because that is where the op set's own code looks for
/// it.
pub const ObjInfo = opset_op.ObjInfo;

/// Renumbers the parent as if a new actor had been inserted at `idx`
/// (`ObjInfo::with_new_actor`, `op_set2/op_set/index.rs:113-118`).
///
/// The object type cannot change, so only the parent moves.
pub fn withNewActor(self: ObjInfo, idx: ActorIdx) ObjInfo {
    return .{ .parent = self.parent.withNewActor(idx), .obj_type = self.obj_type };
}

/// Renumbers the parent as if the actor at `idx` had been removed
/// (`ObjInfo::without_actor`, `op_set2/op_set/index.rs:120-126`).
///
/// Null when the parent names the removed actor, because then the object
/// itself no longer exists and `OpSet::rewrite_without_actor` drops the entry
/// rather than keeping a wrong one (`op_set2/op_set.rs:1421-1427`).
pub fn withoutActor(self: ObjInfo, idx: ActorIdx) ?ObjInfo {
    const parent = self.parent.withoutActor(idx) orelse return null;
    return .{ .parent = parent, .obj_type = self.obj_type };
}

/// Every object the op set holds, keyed by the operation that made it
/// (`ObjIndex`, `op_set2/op_set/index.rs:77-78`).
///
/// This is what answers "what is this object and where does it hang": the
/// two questions `Automerge::object_type` and `Automerge::object_parent` ask
/// (`op_set2/op_set.rs:1171-1177`). The root has no entry and is answered
/// without one, so a document whose root is asked about needs no op to have
/// made it.
pub const ObjIndex = struct {
    gpa: Allocator,
    /// The objects, by the id of the op that made each
    /// (`index.rs:78`). Upstream's is a bare `HashMap<OpId, ObjInfo>` newtype;
    /// the allocator is the port's addition, and every entry point here takes
    /// it rather than hiding it.
    map: std.AutoHashMapUnmanaged(OpId, ObjInfo) = .empty,

    /// An index holding no objects (`ObjIndex::default`, `index.rs:78`).
    pub fn init(gpa: Allocator) ObjIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ObjIndex) void {
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    /// What kind of object `obj` is (`ObjIndex::object_type`,
    /// `op_set2/op_set/index.rs:81-87`).
    ///
    /// The root is a map and needs no entry of its own (`index.rs:82-83`);
    /// every other object has to have been made by some op, so an id the index
    /// does not hold is null rather than a guess.
    pub fn objectType(self: *const ObjIndex, obj: ObjId) ?ObjType {
        if (obj.isRoot()) return .map;
        const id = obj.opId() orelse return null;
        const info = self.map.get(id) orelse return null;
        return info.obj_type;
    }

    /// Which object `obj` hangs in (`ObjIndex::object_parent`,
    /// `op_set2/op_set/index.rs:89-95`).
    ///
    /// Null for the root, which hangs in nothing (`index.rs:90-91`), and for
    /// an object the index does not hold.
    pub fn objectParent(self: *const ObjIndex, obj: ObjId) ?ObjId {
        if (obj.isRoot()) return null;
        const id = obj.opId() orelse return null;
        const info = self.map.get(id) orelse return null;
        return info.parent;
    }

    /// Records what `id` made (`ObjIndex::insert`,
    /// `op_set2/op_set/index.rs:97-99`).
    pub fn insert(self: *ObjIndex, id: OpId, info: ObjInfo) Allocator.Error!void {
        try self.map.put(self.gpa, id, info);
    }

    /// Forgets what `id` made (`ObjIndex::remove`,
    /// `op_set2/op_set/index.rs:101-103`).
    ///
    /// Called by `OpSet::undo_op` for the op it is taking back
    /// (`op_set2/op_set.rs:251-253`).
    pub fn remove(self: *ObjIndex, id: OpId) void {
        _ = self.map.remove(id);
    }

    /// How many objects the index holds, which is how many entries a rebuild
    /// found and a test counts them.
    pub fn count(self: *const ObjIndex) usize {
        return self.map.count();
    }
};

// ── Mark order ─────────────────────────────────────────────────────────────

/// The class the reference assigns to a document whose marks are out of order.
///
/// Upstream raises `ReconstructError::InvalidMarkOrderDoc` and
/// `::InvalidMarkOrderChanges` (`storage/document.rs:410-418`), both of which
/// render "invalid mark operation order: {message}", and the fixture corpus
/// records `test/fixtures/broken_zero_width_mark.automerge` as a load that
/// must fail for exactly this reason
/// ([manifest](../test/fixtures/manifest.zig), from
/// `rust/automerge/tests/rich_text_fuzz_crash.rs:222-229`).
///
/// The name lives here rather than in [error.zig](../error.zig) because this
/// is the only error the index slice produces and the entry point that raises
/// it is [`checkMarkOrder`]. The load path that calls it lives in
/// `src/storage/document.zig`, and this name belongs in that file's `Error`
/// set beside `Load` when it lands; move it there rather than declaring it
/// twice.
pub const MarkOrderError = error{
    /// A mark end names a begin that is not open earlier in the same object
    /// (`MarkOrderValidator::check_mark_op`,
    /// `op_set2/op_set/index.rs:59-73`).
    InvalidMarkOrder,
};

/// What the validator found wrong, as the two facts the message is made of
/// (`op_set2/op_set/index.rs:59-73`).
///
/// Upstream formats a `String` here and carries it in
/// `ReconstructError::InvalidMarkOrderDoc`'s `error_message`
/// (`storage/document.rs:356-359`); the port carries the two ids instead, so
/// the check allocates nothing and the loader can render the text however it
/// already renders errors. `index.rs:63` is "mark end {id} references mark
/// begin {begin} in a different object" and `index.rs:68` is "mark end {id}
/// occurs before mark begin {begin}".
pub const MarkOrder = union(enum) {
    /// The begin has not been seen at all, so the end came first.
    end_before_begin: struct { end: OpId, begin: OpId },
    /// The begin is open, but in a different object.
    end_in_other_object: struct { end: OpId, begin: OpId },

    /// The operation whose mark is out of order.
    pub fn end(self: MarkOrder) OpId {
        return switch (self) {
            .end_before_begin => |m| m.end,
            .end_in_other_object => |m| m.end,
        };
    }

    /// The mark begin the end names.
    pub fn begin(self: MarkOrder) OpId {
        return switch (self) {
            .end_before_begin => |m| m.begin,
            .end_in_other_object => |m| m.begin,
        };
    }
};

/// Checks on load that every mark end closes a begin that came earlier **in
/// the same object** (`MarkOrderValidator`,
/// `op_set2/op_set/index.rs:23-75`).
///
/// Upstream holds a `String` and hands it to whoever asked
/// (`take_error`, `:45-47`); the port holds a [`MarkOrder`] for the same
/// reason the value form exists — the check must not allocate on the path a
/// corrupt document takes.
///
/// **The first failure is the only one.** `processMarkIndex` returns as soon
/// as one is recorded (`index.rs:39-41`), so a document with several bad
/// marks reports the first in row order.
pub const MarkOrderValidator = struct {
    gpa: Allocator,
    /// Every mark begin seen so far, and the object it began in
    /// (`index.rs:24`).
    begins: std.AutoHashMapUnmanaged(OpId, ObjId) = .empty,
    /// The first failure, or null (`index.rs:25`).
    order: ?MarkOrder = null,

    /// A validator that has seen nothing (`MarkOrderValidator::default`,
    /// `index.rs:23`).
    pub fn init(gpa: Allocator) MarkOrderValidator {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MarkOrderValidator) void {
        self.begins.deinit(self.gpa);
        self.* = undefined;
    }

    /// Checks one row (`MarkOrderValidator::process_op`,
    /// `op_set2/op_set/index.rs:29-32`).
    pub fn processOp(self: *MarkOrderValidator, op: Op) ParseError!void {
        try self.processMarkIndex(op, try markBuilderOf(op));
    }

    /// Checks one row against a mark index already read out of it
    /// (`MarkOrderValidator::process_mark_index`,
    /// `op_set2/op_set/index.rs:34-43`).
    ///
    /// Separate from [`processOp`] because [`IndexBuilder.processOp`] reads
    /// the mark index once and hands the same value to both the validator and
    /// the mark column, exactly as upstream does (`index.rs:186-188`).
    pub fn processMarkIndex(
        self: *MarkOrderValidator,
        op: Op,
        mark_index: ?MarkIndexBuilder,
    ) ParseError!void {
        // index.rs:39-41 — one failure is the whole report.
        if (self.order != null) return;
        switch (mark_index orelse return) {
            .start => |s| try self.begins.put(self.gpa, s.id, op.objId()),
            .end => |begin| self.checkEnd(op, begin),
        }
    }

    /// `End(begin)` against the begins seen so far
    /// (`check_mark_op`'s end arm, `op_set2/op_set/index.rs:58-73`).
    fn checkEnd(self: *MarkOrderValidator, op: Op, begin: OpId) void {
        const seen = self.begins.get(begin);
        if (seen == null) {
            self.order = .{ .end_before_begin = .{ .end = op.id(), .begin = begin } };
        } else if (!seen.?.eql(op.objId())) {
            self.order = .{ .end_in_other_object = .{ .end = op.id(), .begin = begin } };
        }
    }

    /// The failure, taken (`MarkOrderValidator::take_error`,
    /// `op_set2/op_set/index.rs:45-47`).
    ///
    /// Taken rather than borrowed, because upstream takes it too: the
    /// validator is handed on and the failure moves with it
    /// (`storage/document.rs:343`, `:355`).
    pub fn takeError(self: *MarkOrderValidator) ?MarkOrder {
        const out = self.order;
        self.order = null;
        return out;
    }
};

/// Refuses a document whose marks are out of order, with the class the
/// reference assigns.
///
/// This is where upstream raises `ReconstructError::InvalidMarkOrderDoc`,
/// right after `set_indexes` and `validate_top_index` have run
/// (`storage/document.rs:343-362`), and the port puts it in one function
/// because the ordering of the checks after `finish()` belongs to the loader.
pub fn checkMarkOrder(v: *MarkOrderValidator) MarkOrderError!void {
    if (v.takeError() != null) return error.InvalidMarkOrder;
}

// ── The row a mark index names ─────────────────────────────────────────────

/// The mark row a stored op occupies, as a builder rather than a word
/// (`Op::mark_index`, `op_set2/op.rs:943-951`).
///
/// Upstream clones the mark's name into an owned `String` here so that its
/// `MarkIndexBuilder` is `MarkData<'static>` (`op_set2/op.rs:944-950`); the
/// port keeps the name borrowed, which is what [`MarkIndexColumn.extend`]
/// requires of its caller (mark_index.zig:671-681) and is sound here because
/// this builder reads rows **already in the op set**
/// (`storage/document.rs:337`), whose names live in the document's own string
/// storage. `columns.splice` cannot make that claim, which is why it interns
/// the name through the document's table first (columns.zig:990-998).
fn markBuilderOf(o: Op) ParseError!?MarkIndexBuilder {
    const word = o.markIndex() orelse return null;
    return switch (markidx.MarkIdx.load(word)) {
        .start => |begin| .{
            .start = .{
                .id = begin,
                // A begin word is only produced when the row carries a name
                // (`op.zig` `Op.markIndex`), so this cannot fire; the error is
                // here so that a future change cannot turn it into a trap.
                .data = o.markData() orelse return error.InvalidValue,
            },
        },
        .end => |begin| .{ .end = begin },
    };
}

// ── The five index columns, as a rebuild produces them ─────────────────────

/// The five index columns plus `obj_info` (`Indexes`,
/// `op_set2/op_set/index.rs:150-157`).
///
/// **Not** `columns.Indexes`, and the difference is the sixth field: the
/// rebuild collects the objects it walked past, and `OpSet::set_indexes`
/// moves that collection into the op set's own `obj_info` alongside the five
/// columns (`op_set2/op_set.rs:229`). The two are otherwise the same five
/// columns in the same order.
pub const Indexes = struct {
    /// How wide a top row is, null for a row that is not top
    /// (`index.rs:151`).
    text: TextColumn,
    /// Whether a row won its register (`index.rs:152`).
    top: BoolPrefixColumn,
    /// Whether a row is visible: present and not shadowed (`index.rs:153`).
    visible: BoolColumn,
    /// The increment each counter successor carries, and null for every other
    /// successor — which is how a delete is told from a counter update
    /// (`index.rs:154`).
    inc: IncColumn,
    /// Which rows open a mark and which close one (`index.rs:155`).
    mark: MarkIndexColumn,
    /// Every object the walked rows made (`index.rs:156`).
    obj_info: ObjIndex,

    pub fn deinit(self: *Indexes) void {
        self.text.deinit();
        self.top.deinit();
        self.visible.deinit();
        self.inc.deinit();
        self.mark.deinit();
        self.obj_info.deinit();
        self.* = undefined;
    }

    /// The five lengths, in the same shape `columns.Indexes.lengths` answers
    /// (`columns.zig:390-398`) so a caller can compare the two directly.
    pub fn lengths(self: *const Indexes) IndexLengths {
        return .{
            .text = self.text.len(),
            .top = self.top.len(),
            .visible = self.visible.len(),
            .inc = self.inc.len(),
            .mark = self.mark.len(),
        };
    }

    /// That the five lengths are the ones the data columns demand
    /// (`OpSet::set_indexes`, `op_set2/op_set.rs:219-222`).
    ///
    /// Upstream asserts `text`, `mark` and `visible` against `len()` and `inc`
    /// against `sub_len()`, and checks `top` against `visible` one function
    /// away in `validate_top_index` (`op_set.rs:181`); this checks all five at
    /// once, which is the same set of facts and the place a rebuild can be
    /// caught before it is installed.
    pub fn checkLengths(self: *const Indexes, rows: usize, succs: usize) bool {
        const l = self.lengths();
        return l.text == rows and l.top == rows and l.visible == rows and
            l.mark == rows and l.inc == succs;
    }
};

// ── IndexBuilder ───────────────────────────────────────────────────────────

/// One `(incs index, row index)` pair: where a counter's successor will land
/// in the increment index, and which row it shadows (`index.rs:10`).
const SuccRef = struct {
    succ_idx: usize,
    op_idx: usize,
};

/// Rebuilds the five index columns from an op stream
/// (`IndexBuilder`, `op_set2/op_set/index.rs:9-20`, `:159-255`).
///
/// The five columns are derived state the exporter never writes
/// (`op_set2/columns.rs:135-170`) and a load builds empty
/// (`op_set2/columns.rs:252-330`), so this is what every loaded document's
/// index comes from.
///
/// # The order of the two counters is the whole trick
///
/// `succ` starts at [`visNum`], which is the row's successor count, or
/// `u32::MAX` for an increment. Each increment successor subtracts one when
/// the increment op is reached (`index.rs:198-203`), which is what leaves a
/// counter row visible while every successor increments it and invisible once
/// one does not. `incs` has one slot per successor, in row order, and
/// `processSucc` reserves it before the op that fills it is known
/// (`index.rs:217`).
pub const IndexBuilder = struct {
    gpa: Allocator,
    /// Which rows a counter points at, and where each edge's increment will go
    /// (`index.rs:10`). Entries are taken out again as the op that fills them
    /// is reached (`index.rs:196`), so the map does not grow with the stream.
    counters: std.AutoHashMapUnmanaged(OpId, std.ArrayList(SuccRef)) = .empty,
    /// A row's successor count, less the increments pointed at it, or
    /// `u32::MAX` for an increment (`index.rs:12`, `:190`).
    succ: std.ArrayList(u32) = .empty,
    /// Which row won its register (`index.rs:13`).
    top: std.ArrayList(bool) = .empty,
    /// Every row's width in the text encoding, whether or not it is top
    /// (`index.rs:14`).
    widths: std.ArrayList(u64) = .empty,
    /// One slot per successor edge (`index.rs:15`).
    incs: std.ArrayList(?i64) = .empty,
    /// One slot per row (`index.rs:16`).
    marks: std.ArrayList(?MarkIndexBuilder) = .empty,
    /// Every object the rows made (`index.rs:17`).
    obj_info: ObjIndex,
    /// The first row `flush` has not yet looked at (`index.rs:18`).
    last_flush: usize = 0,
    /// How widths are measured (`index.rs:19`).
    text_encoding: TextEncoding,
    /// The mark-order check, handed back by [`finish`] (`index.rs:20`).
    mark_order: MarkOrderValidator,

    /// A builder with room for `rows` rows and `succs` successor edges
    /// (`IndexBuilder::new`, `op_set2/op_set/index.rs:160-173`).
    ///
    /// Upstream takes the op set and reads `len()` and `sub_len()` off it to
    /// size its `Vec`s; those two counts are what it wants, and the port takes
    /// them directly because `op_set.zig` is a layer above this file.
    pub fn init(
        gpa: Allocator,
        rows: usize,
        succs: usize,
        text_encoding: TextEncoding,
    ) ParseError!IndexBuilder {
        var b = IndexBuilder{
            .gpa = gpa,
            .obj_info = ObjIndex.init(gpa),
            .text_encoding = text_encoding,
            .mark_order = MarkOrderValidator.init(gpa),
        };
        errdefer b.deinit();
        try b.succ.ensureTotalCapacity(gpa, rows);
        try b.top.ensureTotalCapacity(gpa, rows);
        try b.widths.ensureTotalCapacity(gpa, rows);
        try b.marks.ensureTotalCapacity(gpa, rows);
        try b.incs.ensureTotalCapacity(gpa, succs);
        return b;
    }

    /// Gives back everything the builder reserved, including the index and the
    /// validator. Not needed after [`finish`], which consumes it.
    pub fn deinit(self: *IndexBuilder) void {
        self.freeScratch();
        self.obj_info.deinit();
        self.mark_order.deinit();
        self.* = undefined;
    }

    /// Gives back the accumulation only, leaving `obj_info` and `mark_order`
    /// to the caller, because `finish` moves both of those into its result.
    /// It does not invalidate `self`; only [`deinit`] does.
    fn freeScratch(self: *IndexBuilder) void {
        var edges = self.counters.valueIterator();
        while (edges.next()) |list| list.*.deinit(self.gpa);
        self.counters.deinit(self.gpa);
        self.succ.deinit(self.gpa);
        self.top.deinit(self.gpa);
        self.widths.deinit(self.gpa);
        self.incs.deinit(self.gpa);
        self.marks.deinit(self.gpa);
    }

    /// Marks the winning row of the register that has just ended
    /// (`IndexBuilder::flush`, `op_set2/op_set/index.rs:175-183`).
    ///
    /// The pending rows are scanned **backwards**, and the first one with no
    /// unshadowed successor wins (`index.rs:177-181`). Backwards is the point:
    /// a register's rows ascend in id (`op_set2/op.rs:1060`), so the winner is
    /// its highest id, not its first — a forward scan would give the loser to
    /// every conflicted register.
    ///
    /// The caller flushes at every `(obj, elemid_or_key)` change, which is
    /// where one register ends and the next begins
    /// (`change/collector.rs:62-66`); flushing anywhere else would attribute
    /// a register's winner to a row of the next register.
    pub fn flush(self: *IndexBuilder) void {
        const len = self.succ.items.len;
        // `self.succ[self.last_flush..].iter().rev().enumerate()`
        // (`index.rs:177-181`): the walk is **backwards from the end of the
        // pending run**, so the row examined and the row marked are the same
        // one. Reading forwards from `self.last_flush` while still marking
        // backwards makes the first zero it finds belong to one row and the
        // `top` it sets belong to another; that is correct only when a run's
        // first and last rows coincide, which is every single-row register and
        // nothing else.
        //
        // Walking `i` down rather than computing `len - delta - 1` is the
        // same walk with no subtraction to underflow: `i > self.last_flush` is
        // what stops it.
        var i = len;
        while (i > self.last_flush) {
            i -= 1;
            if (self.succ.items[i] == 0) {
                self.top.items[i] = true;
                break;
            }
        }
        self.last_flush = len;
    }

    /// Takes one row (`IndexBuilder::process_op`,
    /// `op_set2/op_set/index.rs:185-208`).
    ///
    /// In order (`index.rs:186-207`): read the row's mark index once and give
    /// it to both the validator and the mark column; push the successor count,
    /// a `top` of false, and the row's **text** width — always measured as
    /// text, for every object, because `index.text` is only ever read on a top
    /// row of a text object (`index.rs:193-194`, and the same rule in
    /// `columns.rs:477-485`); take back whatever `counters` holds for this op
    /// and, if it is an increment, fill in each edge it closes; and record the
    /// object if the row made one.
    pub fn processOp(self: *IndexBuilder, op: Op) ParseError!void {
        const mark_index = try markBuilderOf(op);
        try self.mark_order.processMarkIndex(op, mark_index);
        try self.marks.append(self.gpa, mark_index);

        try self.succ.append(self.gpa, visNum(op));
        try self.top.append(self.gpa, false);
        // Rust's `as u64` saturates at zero, and a width is never negative.
        const w = op.width(.text, self.text_encoding);
        try self.widths.append(self.gpa, if (w < 0) 0 else @intCast(w));

        // `counters.remove` (`index.rs:196`) takes the entry whether or not
        // this op is the increment that fills it, so the map does not keep
        // edges whose op is not an increment — and the list goes back with it,
        // which dropping the removed value would not do here.
        if (self.counters.fetchRemove(op.id())) |taken| {
            var edges = taken.value;
            defer edges.deinit(self.gpa);
            if (op.getIncrementValue()) |i| {
                for (edges.items) |edge| {
                    self.incs.items[edge.succ_idx] = i;
                    self.succ.items[edge.op_idx] -= 1;
                }
            }
        }

        if (op.objInfo()) |info| try self.obj_info.insert(op.id(), info);
    }

    /// Takes one successor edge of the row just processed
    /// (`IndexBuilder::process_succ`, `op_set2/op_set/index.rs:210-218`).
    ///
    /// When the row that owns the edge is a counter, the edge is recorded
    /// under the successor's own id so that the increment op filling it can be
    /// found later (`index.rs:211-216`), and the increment index gets its
    /// slot either way (`index.rs:217`). The slot is filled in by
    /// [`processOp`] when the increment arrives, or stays null forever if the
    /// edge deletes its predecessor instead.
    ///
    /// `error.InvalidValue` if no row has been processed: upstream computes
    /// `succ.len() - 1` here (`index.rs:215`), which underflows rather than
    /// answering, and the port is total over input it does not control.
    pub fn processSucc(self: *IndexBuilder, op_is_counter: bool, id: OpId) ParseError!void {
        if (self.succ.items.len == 0) return error.InvalidValue;
        if (op_is_counter) {
            const gop = try self.counters.getOrPut(self.gpa, id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, .{
                .succ_idx = self.incs.items.len,
                .op_idx = self.succ.items.len - 1,
            });
        }
        try self.incs.append(self.gpa, null);
    }

    /// Builds the five columns and hands the mark validator back
    /// (`IndexBuilder::finish`, `op_set2/op_set/index.rs:220-255`).
    ///
    /// Consumes the builder, so there is nothing to `deinit` afterwards.
    /// [`Rebuilt.mark_order`] still has to be checked
    /// ([`checkMarkOrder`]) before the indexes are installed.
    pub fn finish(self: IndexBuilder) ParseError!Rebuilt {
        var b = self;
        // In its own name because `freeScratch` gives the accumulation back
        // below and the two scratch buffers still need the allocator when
        // their `defer`s run.
        const gpa = b.gpa;
        errdefer b.deinit();
        b.flush();

        // `text` is `widths.zip(top)` with the width kept only where the row
        // won its register (index.rs:223-228).
        var text = try TextColumn.init(gpa);
        errdefer text.deinit();
        const text_values = try gpa.alloc(?u32, b.widths.items.len);
        defer gpa.free(text_values);
        for (b.widths.items, b.top.items, text_values) |w, t, *out| {
            out.* = if (t) saturatingU32(w) else null;
        }
        try text.extend(gpa, text_values);

        // `visible` is `succ == 0` (index.rs:229-231). An increment never
        // reaches zero: it starts at `u32::MAX` and loses at most one per
        // increment successor.
        var visible = try BoolColumn.init(gpa);
        errdefer visible.deinit();
        const visible_values = try gpa.alloc(bool, b.succ.items.len);
        defer gpa.free(visible_values);
        for (b.succ.items, visible_values) |n, *out| {
            out.* = n == 0;
        }
        try visible.extend(gpa, visible_values);

        var top = try BoolPrefixColumn.init(gpa);
        errdefer top.deinit();
        try top.extend(gpa, b.top.items);

        var inc = try IncColumn.init(gpa);
        errdefer inc.deinit();
        try inc.extend(gpa, b.incs.items);

        // One `extend` over the whole column (index.rs:251-252), which is what
        // fills the mark cache as well as the rows.
        var mark = try MarkIndexColumn.init(gpa);
        errdefer mark.deinit();
        try mark.extend(gpa, 0, b.marks.items);

        // Moved out before the teardown below, which gives the accumulation
        // back; after it, only these two survive.
        const obj_info = b.obj_info;
        const mark_order = b.mark_order;
        b.freeScratch();
        return .{
            .indexes = .{
                .text = text,
                .top = top,
                .visible = visible,
                .inc = inc,
                .mark = mark,
                .obj_info = obj_info,
            },
            .mark_order = mark_order,
        };
    }
};

/// What [`IndexBuilder.finish`] produces (`index.rs:220-255`): the five index
/// columns with `obj_info`, and the validator the caller has not checked yet.
pub const Rebuilt = struct {
    /// To be moved into the op set by `Columns.setIndexes`
    /// (`op_set2/op_set.rs:216-229`).
    indexes: Indexes,
    /// To be passed to [`checkMarkOrder`] (`storage/document.rs:355`).
    mark_order: MarkOrderValidator,

    pub fn deinit(self: *Rebuilt) void {
        self.indexes.deinit();
        self.mark_order.deinit();
        self.* = undefined;
    }
};

/// A row's unshadowed successor count, or `u32::MAX` for an increment
/// (`vis_num`, `op_set2/op_set/index.rs:257-263`).
///
/// **The sentinel is load-bearing.** An increment is never a row a reader can
/// see — it only adds to a counter predecessor — so it must never count as
/// visible and must never win its register. `u32::MAX` is how that is said:
/// [`flush`] and the `visible` column both ask whether the count is zero, and
/// an increment loses one per increment successor pointed at it, so it can
/// only reach zero after `u32::MAX` of them. Rust's `u32::MAX` and Zig's
/// `std.math.maxInt(u32)` are the same 4294967295.
fn visNum(op: Op) u32 {
    if (op.isInc()) return std.math.maxInt(u32);
    const n = op.succCount();
    return std.math.cast(u32, n) orelse std.math.maxInt(u32);
}

/// Rust's `*w as u32` at `index.rs:227`, which saturates rather than wrapping
/// or trapping.
fn saturatingU32(w: u64) u32 {
    if (w > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(w);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The encoding the index tests measure widths in, so that the expected `text`
/// rows are arithmetic rather than grapheme segmentation.
const encoding: TextEncoding = .unicode_code_point;

/// The id of the operation at `ctr` made by `actor` (`types.rs:154-156`).
fn at(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

/// The object `op` made (`types.rs:200-202`).
fn made(ctr: u32, actor: ActorIdx) ObjId {
    return .{ .id = at(ctr, actor) };
}

/// A sequence row's anchor at `id` (`ElemId::from_op_id`,
/// `rust/automerge/src/types.rs:652-654`).
///
/// Upstream's `ElemId` is a wrapper around an `OpId` that exists to carry the
/// head, and the port spells it the same way (`types.zig:299-321`). Every
/// sequence anchor these tests build goes through one of the two constructors
/// the wrapper offers, so that the head stays one token here too.
fn anchor(id: OpId) types.ElemId {
    return types.ElemId.fromOpId(id);
}

/// The head of a sequence: the element id that means "inserted at the front"
/// (`ElemId::head`, `rust/automerge/src/types.rs:657-659`). It is a
/// distinguished value rather than a separate case, so `anchor(OpId.root)` and
/// this are the same thing (`types.zig:307-309`).
const head = types.ElemId.head();

/// A row as the builder reads it. `succs` must outlive the value, exactly as
/// an `Op`'s borrowed key and value must (`op.zig` module doc).
fn row(
    id: OpId,
    obj: ObjId,
    key: optypes.KeyRef,
    insert: bool,
    action: Action,
    value: ScalarValue,
    name: ?[]const u8,
    succs: []const SuccEntry,
) Op {
    return Op.init(0, false, id, action, obj, key, insert, value, false, name, SuccCursors.fromSpan(succs, 0));
}

/// The two facts that say where a row sits: its object and its register
/// (`Op::elemid_or_key`, `op_set2/op.rs:1040-1046`). A change in either starts
/// a new register, which is where the rebuild flushes.
const ObjSpan = struct {
    obj: ObjId,
    key: optypes.KeyRef,
};

/// Drives `b` over `ops` the way the loader does: a flush at every
/// `(obj, elemid_or_key)` change, then `processOp`, then one `processSucc` per
/// successor (`change/collector.rs:39-72`).
fn drive(b: *IndexBuilder, ops: []const Op) ParseError!void {
    var last: ?ObjSpan = null;
    for (ops) |o| {
        const here = ObjSpan{ .obj = o.objId(), .key = o.elemidOrKey() };
        if (last == null or !last.?.obj.eql(here.obj) or !last.?.key.eql(here.key)) {
            b.flush();
        }
        last = here;
        try b.processOp(o);
        var i: usize = 0;
        while (i < o.succCount()) : (i += 1) {
            try b.processSucc(o.isCounter(), o.succAt(i));
        }
    }
}

/// The successor edges of the stream below. File-scope so that they outlive
/// the rows that borrow them.
const succ_of_r0 = [_]SuccEntry{.{ .id = at(2, 0), .inc = 5 }};
const succ_of_r2 = [_]SuccEntry{.{ .id = at(4, 0), .inc = null }};
const succ_of_r11 = [_]SuccEntry{.{ .id = at(13, 0), .inc = null }};
const no_succ = [_]SuccEntry{};

/// The stream the index tests walk: thirteen rows in the order `Op::step`
/// enforces (`op_set2/op.rs:1048-1073`), so a rebuild of it is a rebuild of
/// something a real document can hold.
///
/// * rows 0-3 are the counter register `ROOT.a`: a set that an increment keeps
///   visible, the increment, a set an overwrite kills, and the overwrite;
/// * row 4 makes the text object the last six rows live in;
/// * rows 5 and 6 are two more map registers;
/// * rows 7-12 are the text object: two chained inserts, a bold mark beginning
///   on the second, its end in the same register, a third insert, and an
///   overwrite of the third that the last row replaces.
fn streamOps() [13]Op {
    const root: ObjId = .root;
    const text = made(5, 0);
    return .{
        row(at(1, 0), root, .{ .map = "a" }, false, .set, counter(10), null, &succ_of_r0),
        row(at(2, 0), root, .{ .map = "a" }, false, .increment, .{ .int = 5 }, null, &no_succ),
        row(at(3, 0), root, .{ .map = "a" }, false, .set, counter(100), null, &succ_of_r2),
        row(at(4, 0), root, .{ .map = "a" }, false, .set, counter(0), null, &no_succ),
        row(at(5, 0), root, .{ .map = "b" }, false, .make_text, .null_value, null, &no_succ),
        row(at(6, 0), root, .{ .map = "c" }, false, .set, .{ .str = "hi" }, null, &no_succ),
        row(at(7, 0), root, .{ .map = "d" }, false, .set, .{ .str = "z" }, null, &no_succ),
        row(at(8, 0), text, .{ .seq = head }, true, .set, .{ .str = "a" }, null, &no_succ),
        row(at(9, 0), text, .{ .seq = anchor(at(8, 0)) }, true, .mark, .{ .str = "b" }, "bold", &no_succ),
        row(at(10, 0), text, .{ .seq = anchor(at(9, 0)) }, false, .mark, .null_value, null, &no_succ),
        row(at(11, 0), text, .{ .seq = anchor(at(9, 0)) }, true, .set, .{ .str = "c" }, null, &no_succ),
        row(at(12, 0), text, .{ .seq = anchor(at(11, 0)) }, false, .set, .{ .str = "C" }, null, &succ_of_r11),
        row(at(13, 0), text, .{ .seq = anchor(at(11, 0)) }, false, .set, .{ .str = "D" }, null, &no_succ),
    };
}

/// A counter value (`value.zig:107-118`).
fn counter(v: i64) ScalarValue {
    return .{ .counter = ScalarValue.Counter.init(v) };
}

/// `streamOps` as `Columns.splice` reads it, with the `top` and `visible` the
/// splice path is *told* written out per register. They are pinned by "the
/// rebuilt index rows are the ones this stream says", which is what keeps the
/// splice comparison from being two copies of one answer.
fn streamRows() [13]Stream {
    const ops = streamOps();
    // `ROOT.a` wins at row 3 and the register `seq(11,0)` at row 12; rows 8
    // and 10 are visible inserts that the register winner displaced.
    const top = [13]bool{
        false, false, false, true,  true,  true, true,
        true,  false, true,  false, false, true,
    };
    // Row 1 is an increment and rows 2 and 11 each have a successor that
    // deletes rather than increments.
    const visible = [13]bool{
        true, false, false, true, true,  true, true,
        true, true,  true,  true, false, true,
    };
    var out: [13]Stream = undefined;
    for (&out, ops, top, visible) |*o, op, t, v| {
        o.* = .{ .op = op, .is_top = t, .is_visible = v };
    }
    return out;
}

/// One row of the stream as `Columns.splice` reads it: the [`Op`] the builder
/// reads, plus the `top` and `visible` the splice path is *told*.
///
/// They have to be separate because they are separate facts. `splice` writes
/// what `O::top` and `O::visible` answer (columns.zig:986, :989), and for a row
/// already in the document `Op::top` is the default `Op::visible` — which is
/// **not** the register winner the rebuild computes. A conflicted register is
/// exactly where the two differ, so a comparison that let `Op::top` stand in
/// for the index column would compare nothing.
const Stream = struct {
    op: Op,
    is_top: bool,
    is_visible: bool,

    pub fn top(self: Stream) bool {
        return self.is_top;
    }
    pub fn visible(self: Stream) bool {
        return self.is_visible;
    }
    pub fn id(self: Stream) OpId {
        return self.op.id();
    }
    pub fn obj(self: Stream) ?OpId {
        return self.op.obj();
    }
    pub fn key(self: Stream) optypes.KeyRef {
        return self.op.key();
    }
    pub fn insert(self: Stream) bool {
        return self.op.insert();
    }
    pub fn action(self: Stream) Action {
        return self.op.action();
    }
    pub fn expand(self: Stream) bool {
        return self.op.expand();
    }
    pub fn value(self: Stream) ScalarValue {
        return self.op.value();
    }
    pub fn metaValue(self: Stream) ValueMeta {
        return self.op.metaValue();
    }
    pub fn markName(self: Stream) ?[]const u8 {
        return self.op.markName();
    }
    pub fn markIndex(self: Stream) ?i64 {
        return self.op.markIndex();
    }
    pub fn width(self: Stream, seq_type: SequenceType, e: TextEncoding) i64 {
        return self.op.width(seq_type, e);
    }
    pub fn succCount(self: Stream) usize {
        return self.op.succCount();
    }
    pub fn succAt(self: Stream, i: usize) OpId {
        return self.op.succAt(i);
    }
    pub fn succIncCount(self: Stream) usize {
        return self.op.succIncCount();
    }
    pub fn succIncAt(self: Stream, i: usize) ?i64 {
        return self.op.succIncAt(i);
    }
};

/// A string table for the tests: the strings it has been given, in the order
/// they were first asked for, so an interned id is stable for the life of the
/// test. `columns.zig:1551-1589` is the same helper for the same reason — a
/// splice interns the map key and the mark name, and the mark cache has to
/// read the name back.
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
    fn asTable(self: *Table) columns.StringTable {
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

/// Every row of `col`, so a test can read a whole column at once.
fn rowsOf(comptime Col: type, col: *const Col, gpa: Allocator) ParseError![]Col.Value {
    return col.toSlice(gpa);
}

/// The mark index's rows, decoded, in order (`MarkIndexColumn::iter`,
/// `mark_index.rs:252-254`).
///
/// By runs, because a row that carries no mark and the end of the window are
/// the same `null` to this cursor; walking it row by row would stop at the
/// first unmarked row (mark_index.zig:503-511).
fn markRowsOf(col: *const MarkIndexColumn, gpa: Allocator) ParseError![]?markidx.MarkIdx {
    var out: std.ArrayList(?markidx.MarkIdx) = .empty;
    errdefer out.deinit(gpa);
    var it = try col.iter();
    while (try it.nextRun()) |run| {
        var left = run.count;
        while (left > 0) : (left -= 1) try out.append(gpa, run.value);
    }
    return out.toOwnedSlice(gpa);
}

/// That two column sets hold the same values, in the same order, one row at a
/// time. `expectEqual` on two slices would compare their pointers.
fn expectSameCol(comptime Col: type, a: *const Col, b: *const Col, gpa: Allocator) !void {
    const av = try rowsOf(Col, a, gpa);
    defer gpa.free(av);
    const bv = try rowsOf(Col, b, gpa);
    defer gpa.free(bv);
    try testing.expectEqual(av.len, bv.len);
    for (av, bv) |x, y| try testing.expectEqual(x, y);
}

/// That two mark indexes name the same marks on the same rows.
fn expectSameMarks(a: *const MarkIndexColumn, b: *const MarkIndexColumn, gpa: Allocator) !void {
    const av = try markRowsOf(a, gpa);
    defer gpa.free(av);
    const bv = try markRowsOf(b, gpa);
    defer gpa.free(bv);
    try testing.expectEqual(av.len, bv.len);
    for (av, bv) |x, y| {
        const xm = x orelse {
            try testing.expect(y == null);
            continue;
        };
        switch (xm) {
            .start => |begin| {
                const ym = y orelse return error.TestUnexpectedResult;
                switch (ym) {
                    .start => |other| try testing.expect(other.eql(begin)),
                    else => return error.TestUnexpectedResult,
                }
            },
            .end => |begin| {
                const ym = y orelse return error.TestUnexpectedResult;
                switch (ym) {
                    .end => |other| try testing.expect(other.eql(begin)),
                    else => return error.TestUnexpectedResult,
                }
            },
        }
    }
}

/// That two index sets agree on all five columns and on what the rows made.
///
/// Generic over the two set types because the point of the comparison is
/// between the rebuild's `Indexes` and the one `Columns` holds, and those are
/// different types by design ([`Indexes`]).
fn expectSameIndex(a: anytype, b: anytype, gpa: Allocator) !void {
    try testing.expectEqual(a.lengths(), b.lengths());
    try expectSameCol(TextColumn, &a.text, &b.text, gpa);
    try expectSameCol(BoolPrefixColumn, &a.top, &b.top, gpa);
    try expectSameCol(BoolColumn, &a.visible, &b.visible, gpa);
    try expectSameCol(IncColumn, &a.inc, &b.inc, gpa);
    try expectSameMarks(&a.mark, &b.mark, gpa);
    // `obj_info` is the one field the two `Indexes` types do not share
    // (op_set2/op_set.rs:229), so it is compared where there is one.
    if (comptime switch (@typeInfo(@TypeOf(a))) {
        .pointer => |ptr| @hasField(ptr.child, "obj_info"),
        else => false,
    }) {
        try testing.expectEqual(a.obj_info.count(), b.obj_info.count());
    }
}

/// Rebuilds `ops` and gives the result back to the caller, which frees it.
fn rebuild(gpa: Allocator, ops: []const Op, succs: usize) !Rebuilt {
    var b = try IndexBuilder.init(gpa, ops.len, succs, encoding);
    try drive(&b, ops);
    return b.finish();
}

/// The mark verdict `ops` produces, read from a validator of its own so a test
/// can look at it after `checkMarkOrder` has already taken the one a rebuild
/// handed back — `take_error` takes (`op_set2/op_set/index.rs:45-47`).
fn markVerdict(gpa: Allocator, ops: []const Op) ParseError!?MarkOrder {
    var v = MarkOrderValidator.init(gpa);
    defer v.deinit();
    for (ops) |o| try v.processOp(o);
    return v.takeError();
}

test "a rebuild over a hand-built stream reproduces the splice-built index, row for row" {
    const gpa = testing.allocator;
    const ops = streamOps();
    const rows = streamRows();

    var table = Table.init(gpa);
    defer table.deinit();
    var spliced = try columns.Columns(Stream).init(gpa);
    defer spliced.deinit();
    try testing.expectEqual(ops.len, try spliced.splice(gpa, 0, &rows, encoding, table.asTable()));

    var out = try rebuild(gpa, &ops, 3);
    defer out.deinit();

    try expectSameIndex(&spliced.index, &out.indexes, gpa);
}

test "the rebuilt index rows are the ones this stream says" {
    // The pin behind the comparison above: `splice` is handed `top` and
    // `visible`, the builder derives them, and these are the values the
    // derivation has to reach. Row 1 is an increment (never visible, never
    // top), rows 2 and 11 are shadowed by a deleting successor, and each
    // register is won by its highest row — rows 3, 9 and 12.
    const gpa = testing.allocator;
    const ops = streamOps();
    var out = try rebuild(gpa, &ops, 3);
    defer out.deinit();

    const want_top = [_]bool{
        false, false, false, true,  true,  true, true,
        true,  false, true,  false, false, true,
    };
    const want_visible = [_]bool{
        true, false, false, true, true,  true, true,
        true, true,  true,  true, false, true,
    };
    // Widths are measured as text for every row (index.rs:193-194). A value
    // that is not a string measures as the object replacement character, one
    // code point, and a mark measures as nothing (op_set2/op.rs:997-1005).
    const want_text = [_]?u32{
        null, null, null, 1,    1,    2, 1,
        1,    null, 0,    null, null, 1,
    };
    // One slot per successor edge: the increment on row 0's edge and the two
    // deleting successors, which carry none (index.rs:217, :200).
    const want_inc = [_]?i64{ 5, null, null };

    const top = try out.indexes.top.toSlice(gpa);
    defer gpa.free(top);
    const visible = try out.indexes.visible.toSlice(gpa);
    defer gpa.free(visible);
    const text = try out.indexes.text.toSlice(gpa);
    defer gpa.free(text);
    const inc = try out.indexes.inc.toSlice(gpa);
    defer gpa.free(inc);

    try testing.expectEqualSlices(bool, &want_top, top);
    try testing.expectEqualSlices(bool, &want_visible, visible);
    try testing.expectEqualSlices(?u32, &want_text, text);
    try testing.expectEqualSlices(?i64, &want_inc, inc);
}

test "a register with several rows is won only by its highest row" {
    const gpa = testing.allocator;
    const ops = streamOps();
    var out = try rebuild(gpa, &ops, 3);
    defer out.deinit();
    const top = try out.indexes.top.toSlice(gpa);
    defer gpa.free(top);

    // `ROOT.a` holds rows 0-3 and `seq(11,0)` holds rows 10-12. Exactly one
    // row of each is top, and it is the last one: a register's rows ascend in
    // id (op_set2/op.rs:1060), so the winner is the highest id and not the
    // first row or the first visible one.
    try testing.expectEqualSlices(bool, &[_]bool{ false, false, false, true }, top[0..4]);
    try testing.expectEqualSlices(bool, &[_]bool{ false, false, true }, top[10..13]);
    // Row 0 is still visible, so a scan that looked for "the first visible
    // row" would have found it and given the register the wrong winner.
    const visible = try out.indexes.visible.toSlice(gpa);
    defer gpa.free(visible);
    try testing.expect(visible[0]);
    try testing.expect(!top[0]);
}

test "an increment is never visible and a deleting successor hides its predecessor" {
    const gpa = testing.allocator;
    const ops = streamOps();
    var out = try rebuild(gpa, &ops, 3);
    defer out.deinit();
    const visible = try out.indexes.visible.toSlice(gpa);
    defer gpa.free(visible);
    const top = try out.indexes.top.toSlice(gpa);
    defer gpa.free(top);

    // Row 1 is the increment. It starts at the `u32::MAX` sentinel and loses
    // nothing, so it is neither visible nor top.
    try testing.expect(ops[1].isInc());
    try testing.expect(!visible[1]);
    try testing.expect(!top[1]);
    // Row 0's only successor increments it, so the row stays visible even
    // though it does have a successor (index.rs:198-203).
    try testing.expect(visible[0]);
    // Row 2's only successor has no increment, so it deletes rather than adds
    // and the row is not visible.
    try testing.expect(ops[2].succCount() == 1);
    try testing.expect(ops[2].succIncAt(0) == null);
    try testing.expect(!visible[2]);
    // Row 11 is the same case in a sequence register.
    try testing.expect(!visible[11]);
}

test "flush marks the highest row of the pending run, not the first" {
    const gpa = testing.allocator;
    // Successor counts `[0, 1, 0]`: the discriminating case. Scanning forwards
    // would mark row 0, because it is the first with nothing shadowing it;
    // scanning backwards marks row 2 (index.rs:177-181). Row 1's successor is
    // an op that is never processed, so it keeps its count of one.
    const never = [_]SuccEntry{.{ .id = at(9, 0), .inc = null }};
    const root: ObjId = .root;
    const ops = [_]Op{
        row(at(1, 0), root, .{ .map = "a" }, false, .set, .{ .str = "a" }, null, &no_succ),
        row(at(2, 0), root, .{ .map = "a" }, false, .set, .{ .str = "b" }, null, &never),
        row(at(3, 0), root, .{ .map = "a" }, false, .set, .{ .str = "c" }, null, &no_succ),
    };
    var b = try IndexBuilder.init(gpa, ops.len, 1, encoding);
    defer b.deinit();
    for (ops) |o| try b.processOp(o);
    b.flush();
    b.flush();

    try testing.expectEqualSlices(bool, &[_]bool{ false, false, true }, b.top.items);
}

test "the five index columns have the lengths the data columns demand" {
    const gpa = testing.allocator;
    const ops = streamOps();
    const rows = streamRows();
    var table = Table.init(gpa);
    defer table.deinit();
    var spliced = try columns.Columns(Stream).init(gpa);
    defer spliced.deinit();
    _ = try spliced.splice(gpa, 0, &rows, encoding, table.asTable());

    var out = try rebuild(gpa, &ops, 3);
    defer out.deinit();

    // `OpSet::set_indexes` asserts text, mark and visible against `len()` and
    // inc against `sub_len()` (op_set2/op_set.rs:219-222); `checkLengths`
    // checks the same five against the same two numbers, top included.
    try testing.expect(out.indexes.checkLengths(spliced.len(), spliced.subLen()));
    try testing.expectEqual(@as(usize, 13), out.indexes.lengths().text);
    try testing.expectEqual(@as(usize, 13), out.indexes.lengths().top);
    try testing.expectEqual(@as(usize, 13), out.indexes.lengths().visible);
    try testing.expectEqual(@as(usize, 13), out.indexes.lengths().mark);
    try testing.expectEqual(@as(usize, 3), out.indexes.lengths().inc);
    // `visible` is `succ == 0` and `inc` has one row per edge, so neither can
    // be off by one against the data columns.
    try testing.expectEqual(spliced.len(), out.indexes.visible.len());
    try testing.expectEqual(spliced.subLen(), out.indexes.inc.len());
}

test "a rebuild is idempotent" {
    const gpa = testing.allocator;
    const ops = streamOps();
    var once = try rebuild(gpa, &ops, 3);
    defer once.deinit();
    var twice = try rebuild(gpa, &ops, 3);
    defer twice.deinit();
    try expectSameIndex(&once.indexes, &twice.indexes, gpa);

    // Twice is also the same as no reservation at all: the builder's
    // capacity is only a hint, and a rebuild whose rows and successor counts
    // are both zero must still produce the same columns.
    var grown = try rebuild(gpa, &ops, 0);
    defer grown.deinit();
    try expectSameIndex(&once.indexes, &grown.indexes, gpa);
}

test "vis_num is u32::MAX for an increment and the successor count otherwise" {
    const root: ObjId = .root;
    const two = [_]SuccEntry{
        .{ .id = at(7, 0), .inc = null },
        .{ .id = at(8, 0), .inc = null },
    };
    const inc_op = row(at(2, 0), root, .{ .map = "a" }, false, .increment, .{ .int = 5 }, null, &two);
    const plain = row(at(3, 0), root, .{ .map = "a" }, false, .set, .{ .str = "x" }, null, &two);

    // The sentinel is what keeps an increment out of `visible` and out of
    // `top`: both ask whether the count is zero, and an increment can only
    // lose one per increment successor pointed at it.
    try testing.expectEqual(@as(u32, 4294967295), visNum(inc_op));
    try testing.expectEqual(std.math.maxInt(u32), visNum(inc_op));
    try testing.expectEqual(@as(u32, 2), visNum(plain));
    try testing.expectEqual(@as(u32, 0), visNum(row(
        at(4, 0),
        root,
        .{ .map = "a" },
        false,
        .set,
        .{ .str = "y" },
        null,
        &no_succ,
    )));
    // The sentinel is also never reached by the decrements that fill in a
    // counter's increment edges: `u32::MAX - 2` is still nowhere near zero.
    try testing.expect(visNum(inc_op) > 2);
}

test "a mark end with no earlier begin in the same object is refused" {
    // `test/fixtures/broken_zero_width_mark.automerge`: a Text object whose
    // mark end precedes its mark begin
    // (rust/automerge/tests/rich_text_fuzz_crash.rs:222-229, and the corpus
    // entry in test/fixtures/manifest.zig). The end closes the begin at its
    // own id minus one (`op_set2/op.rs:951`), so an end at (5,0) names the
    // begin at (4,0) — and here the end and the begin share an anchor, so
    // their registers sort by those ids and the end's row comes first.
    const gpa = testing.allocator;
    const text = made(1, 0);
    const ops = [_]Op{
        row(at(5, 0), text, .{ .seq = anchor(at(2, 0)) }, false, .mark, .null_value, null, &no_succ),
        row(at(4, 0), text, .{ .seq = anchor(at(2, 0)) }, true, .mark, .{ .str = "x" }, "bold", &no_succ),
    };
    var out = try rebuild(gpa, &ops, 0);
    defer out.deinit();

    // The class the reference assigns is `ReconstructError::InvalidMarkOrderDoc`
    // (`storage/document.rs:410-414`), which renders "invalid mark operation
    // order" and is what the fixture corpus says a load of this file does.
    try testing.expectError(error.InvalidMarkOrder, checkMarkOrder(&out.mark_order));

    // The verdict itself, from a validator of its own: `take_error` takes
    // (`op_set2/op_set/index.rs:45-47`), so the one the rebuild handed back
    // has been consumed by the check above.
    const bad = (try markVerdict(gpa, &ops)).?;
    try testing.expectEqual(at(5, 0), bad.end());
    try testing.expectEqual(at(4, 0), bad.begin());
    switch (bad) {
        .end_before_begin => {},
        .end_in_other_object => return error.TestUnexpectedResult,
    }
}

test "a mark end whose begin is open in another object is refused" {
    const gpa = testing.allocator;
    const one = made(1, 0);
    const two_ = made(2, 0);
    const begin = at(4, 0);
    const end = at(5, 0);

    var v = MarkOrderValidator.init(gpa);
    defer v.deinit();
    try v.processMarkIndex(
        row(begin, one, .{ .map = "t" }, false, .mark, .null_value, "bold", &no_succ),
        .{ .start = .{ .id = begin, .data = MarkData.init("bold", .{ .int = 1 }) } },
    );
    try testing.expect(v.takeError() == null);
    try v.processMarkIndex(
        row(end, two_, .{ .map = "t" }, false, .mark, .null_value, null, &no_succ),
        .{ .end = begin },
    );
    try testing.expectError(error.InvalidMarkOrder, checkMarkOrder(&v));

    var ids = MarkOrderValidator.init(gpa);
    defer ids.deinit();
    try ids.processMarkIndex(
        row(begin, one, .{ .map = "t" }, false, .mark, .null_value, "bold", &no_succ),
        .{ .start = .{ .id = begin, .data = MarkData.init("bold", .{ .int = 1 }) } },
    );
    try ids.processMarkIndex(
        row(end, two_, .{ .map = "t" }, false, .mark, .null_value, null, &no_succ),
        .{ .end = begin },
    );
    const bad = ids.takeError().?;
    switch (bad) {
        .end_in_other_object => {},
        .end_before_begin => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(end, bad.end());
    try testing.expectEqual(begin, bad.begin());
}

test "only the first mark failure is reported" {
    const gpa = testing.allocator;
    const text = made(1, 0);
    var v = MarkOrderValidator.init(gpa);
    defer v.deinit();
    try v.processMarkIndex(
        row(at(5, 0), text, .{ .map = "t" }, false, .mark, .null_value, null, &no_succ),
        .{ .end = at(4, 0) },
    );
    try v.processMarkIndex(
        row(at(9, 0), text, .{ .map = "t" }, false, .mark, .null_value, null, &no_succ),
        .{ .end = at(8, 0) },
    );
    // `process_mark_index` returns as soon as there is one
    // (`op_set2/op_set/index.rs:39-41`), so the second failure never replaces
    // the first.
    const bad = v.takeError().?;
    try testing.expectEqual(at(5, 0), bad.end());
    try testing.expect(v.takeError() == null);
}

test "the object index answers what an object is and where it hangs" {
    const gpa = testing.allocator;
    const ops = streamOps();
    var out = try rebuild(gpa, &ops, 3);
    defer out.deinit();
    const index = &out.indexes.obj_info;

    // Only row 4 makes an object, and it makes a text object in the root.
    try testing.expectEqual(@as(usize, 1), index.count());
    const text = made(5, 0);
    try testing.expectEqual(ObjType.text, index.objectType(text).?);
    try testing.expect((index.objectParent(text).?).isRoot());
    // The root is a map and hangs in nothing, without an entry of its own
    // (op_set2/op_set/index.rs:82-91).
    try testing.expectEqual(ObjType.map, index.objectType(.root).?);
    try testing.expect(index.objectParent(.root) == null);
    // An id nothing made is null rather than a guess.
    try testing.expect(index.objectType(made(6, 0)) == null);
    try testing.expect(index.objectParent(made(6, 0)) == null);
}

test "the object index follows an actor renumbering in both directions" {
    const gpa = testing.allocator;
    const parent = made(3, 1);
    const obj = made(5, 2);
    var index = ObjIndex.init(gpa);
    defer index.deinit();
    try index.insert(obj.opId().?, .{ .parent = parent, .obj_type = .text });
    try testing.expectEqual(ObjType.text, index.objectType(obj).?);
    try testing.expect((index.objectParent(obj).?).eql(parent));

    const info = ObjInfo{ .parent = parent, .obj_type = .text };
    // A new actor below the parent pushes the parent's actor up with it, and
    // the object type cannot move (`ObjInfo::with_new_actor`,
    // `op_set2/op_set/index.rs:113-118`).
    const up = withNewActor(info, 1);
    try testing.expectEqual(ObjType.text, up.obj_type);
    try testing.expectEqual(@as(ActorIdx, 2), up.parent.opId().?.actor);
    // Removing an actor below the parent only renumbers it.
    const down = withoutActor(info, 0).?;
    try testing.expectEqual(ObjType.text, down.obj_type);
    try testing.expectEqual(@as(ActorIdx, 0), down.parent.opId().?.actor);
    // Removing the actor the parent itself was made by leaves no parent, so
    // there is no object left to record (`op_set2/op_set/index.rs:120-126`,
    // and the filter that goes with it at `op_set2/op_set.rs:1421-1427`).
    try testing.expect(withoutActor(info, 1) == null);

    index.remove(obj.opId().?);
    try testing.expectEqual(@as(usize, 0), index.count());
    try testing.expect(index.objectType(obj) == null);
}

test "process_succ refuses to run before any row has been processed" {
    const gpa = testing.allocator;
    var b = try IndexBuilder.init(gpa, 0, 1, encoding);
    defer b.deinit();
    // `process_succ` records `succ.len() - 1` (`op_set2/op_set/index.rs:215`),
    // which underflows rather than answering; the port is total over input it
    // does not control.
    try testing.expectError(error.InvalidValue, b.processSucc(false, at(1, 0)));
}
